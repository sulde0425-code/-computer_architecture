# 项目长期记忆 — LoongArch(LA32R) 五级流水 CPU 课设
（详细过程见 .workbuddy/memory/2026-10-15.md 与 2026-10-16.md）

## 工程路径
- RTL：`Main_project_1.1/cdp_ede_local-master/mycpu_env/myCPU/`（12 个 .v：含 divider.v、csr.v；dpic.v 已删，备份 `.workbuddy/backup/`）
- 验证环境：`soc_verify/soc_bram/`；tb=`testbench/mycpu_tb.v`+`sync_ram.v`；工程=`run_vivado/project/loongson.xpr`（xc7a200tfbg676-1）
- 测试镜像：`Main_project_1.1/for_test_obj/ex1..ex9_obj`（ex1/2/3=第1章，ex4/5=第3章算逻/转移，ex6=第4章访存，ex7=第5章乘除，ex8/9=异常）
- 黄金trace：`mycpu_env/gettrace/golden_trace.txt`；本机无交叉工具链，直接用现成镜像
- Vivado 2023.2 在 `D:\Xilinx\Vivado\2023.2\bin`
- 轻量回归：`.workbuddy/sim/run_regress.sh`（ex1~ex7 一键，行为级 sync_ram 顶替 IP；限时 run 30ms 勿用 -R）

## ★ 换镜像/出 bit 的正确流程（2026-10-16 定案）
- 仿真读 `func/obj/*.mif`（sync_ram 行为级覆盖 IP，VRFC 10-3609 warning 正常）；综合/bit 读 **IP OOC dcp**（`loongson.runs/inst_ram_synth_1/inst_ram.dcp`，Coe_File→`func/obj/inst_ram.coe`）
- **换 coe 后必须：reset_target+generate_target [get_ips inst_ram] 且 显式 reset_run+launch_runs inst_ram_synth_1**——只 generate_target 不会重烧 dcp（69 分根因，见下）
- tb `run 1000ns` 陷阱：launch_simulation 默认只跑 1000ns，复位要 2000ns，需补 `run 5 ms`
- **换章先跑 `bash .workbuddy/sim/switch_exp.sh <N>`**：一次同步三个位置
  ① `func/obj/inst_ram.coe`（综合）② `func/obj/inst_ram.mif`（仿真）③ `xilinx_ip/inst_ram/inst_ram.mif`（generate_target）；
  自动备份 `mycpu_env/.bak_<时间戳>/` + cmp 校验
- 通用脚本（`-tclargs N`）：`rebuild_bit_expN.tcl`（出 bit，自动归档
  `.workbuddy/sim/expN/looongson_remote_top_EXPN.bit` + 根目录副本，约 13 分钟）、
  `gt_expN.tcl`（重生成 golden_trace，秒级）、`verify_expN_sim.tcl`（行为仿真）
- 双击出 bit：`build_bit_exp.bat N`（根目录，无参数默认 6）
- 各章 golden_trace 行数：ex4=62377 / ex5=71332 / ex6=79750 / **ex7=86846 / ex8=87100**
  对应测试点数：ex4=29 / ex5=33 / ex6=39 / **ex7=46 / ex8=47**
- coe md5：ex6 `a76338349250a0465346deb004e4c1db`(123101字) / ex7 `91f2c1213b23600f61bf68ff32fdbaa9`(131185字)
  / ex8 `7d3f92fa78f8d350b55bdc781766e799`
- 已出 bit：EXP5 `looongson_remote_top_EXP5.bit`(16日) / EXP6 `..._EXP6.bit`(4831159B, md5 4c1e2dc1…)
  / **EXP7 `..._EXP7.bit` md5 `359768ab4014acf670538a643af189bb`**
  / **EXP9 `..._EXP9.bit`（2026-10-28 18:29, 4872875B，BRAM INIT 已验证为 ex9）**；EXP8 未出
- ex9 coe md5 `15c2070a17300467042640b9af0d4cec`(133249字，1199306B)；ex8 131275 字
- ex9 bit 时序：WNS **+0.083ns** / TNS 0 / 失败终点 **0/12013**（比第5章 +0.782 紧很多）
- ⚠ kill 掉带管道的 shell 不会杀掉 vivado 子进程 —— 判断构建是否真跑完要看产物时间戳
- **验证 bit 装了哪套程序**（2026-10-28 定案，`.workbuddy/sim/dump_bram_init.tcl`）：
  ① `open_checkpoint` inst_ram 的 OOC dcp → 取 256 个 RAMB36E1 的 `INIT_00`/`INIT_01`
  （值形如 `256'h<64 hex>`，**必须剥掉 `256'h` 前缀**，否则正则只吃到 "256"）
  ② Python 侧做**与布局无关的**匹配：把 coe 按 4 条字节通道拆成 strided 字节串
  （lane L = 每字第 L 字节），INIT 的 32 字节在 4 条串里做正向/反向子串查找
  → 不需要知道 block 大小 / INIT 编号 / 地址映射，比旧的 multiset 推导法稳
  ③ 判据：**"仅匹配目标镜像"的段数 > 0 且 "仅匹配其他镜像" = 0、两侧都不匹配 = 0**
  **ex4/ex5/ex6 前 8223 字相同；ex8 与 ex9 从 word 8224 起不同**

## ★ 69 分最终根因（2026-10-16）
**所有历史 bit 里固化的是 ex1 程序**：IP OOC dcp 停在 09-22（当时 coe=出厂=ex1），换镜像后从未重跑 OOC 综合 → 平台按各章测试点判分，每章都是 69。次要因素：50MHz 时序不收敛（已修）。

## 线上评测（校内赛平台）
- 上传 bit → 远程 FPGA → 功能+性能自动评测；评分：个人 60 = 前五章 50 + 报告 10；团队 40 = 异常 20~25 + 创新 5~10 + 报告 10
- 工程按 PPT 第 7 页教程配置：remote2local.v + `cdp_ede_remote-master/mycpu_env/loongson_remote_top.v`（顶层 looongson_remote_top，3 个 o 官方拼写）+ loongson_remote.xdc（clk_50M 20ns）+ 禁用原 xdc + PLL 50in/50out（已确认）
- PPT 第 13 页：ex4=slti/sltui/andi/ori/xori/sll/srl/sra/pcaddu12i 29 点；ex5 转移 33 点；ex6 访存 39 点；ex7 乘除 46 点

## ★ 章节 ↔ 指令 ↔ 测试点 映射（2026-10-23 定案，与 PPT 判分口径一致）
- 基线 20 条 = n1~n20（第 1–2 章）：lu12i.w/add.w/addi.w/sub.w/slt/sltu/and/or/xor/nor/
  slli.w/srli.w/srai.w/ld.w/st.w/beq/bne/bl/jirl/b
- **第 3 章 +13 条**：pcaddu12i(n21) slti(n22) sltui(n23) andi(n24) ori(n25) xori(n26)
  sll.w(n27) sra.w(n28) srl.w(n29) blt(n37) bge(n38) bltu(n39) bgeu(n40)
- **第 4 章 +6 条**：ld.b(n41) ld.h(n42) ld.bu(n43) ld.hu(n44) st.b(n45) st.h(n46)
- **第 5 章 +7 条 = n30~n36**：n30 div.w / n31 div.wu / n32 mul.w / n33 mulh.w /
  n34 mulh.wu / n35 mod.w / n36 mod.wu（**正好 7 条指令 7 个测试点**，向量数 122/178/159/159/142/122/178 = 1060）
- ⇒ **EXP4=29 点 / EXP5=33 点 / EXP6=39 点 / EXP7=46 点 / EXP8=47 点 / ex9=58 点**（均已实测通过）

## ★ 第 6 章扩展档 · EXP9（2026-10-27 完成，58/58 全过）
- **ex9 范围 = 46 条指令 + 12 个异常点 = 58 点**：syscall(n47)、brk(n48)、定时器中断(n49)、
  INE(n50)、软中断(n51)、ADEF(n52)、ALE×5(n53~57)、rdcnt(n58)。**不含 TLB / cache（n59+）**
- 新增 CSR：ECFG(0x4，汇编名 csr_ectl)、TID(0x40)、TCFG(0x41)、TVAL(0x42)、TICLR(0x44)
- 总线位宽（当前）：FS_TO_DS 65 / DS_TO_ES **184** / ES_TO_MS **82** / MS_TO_WS **77**
- 异常标志组 `ex_flags[5:0] = {adef, ale, sys, brk, ine, int}` 随指令走到 WB 才编码成 Ecode
  （优先级：ADEF > ALE > SYS > BRK > INE > INT，指令异常优先于中断）
- rdcnt 编码：`rdtimel.w` [15:10]=011000、`rdtimeh.w` [15:10]=011001；
  **rj≠0 时是 rdcntid，结果写 rj**；三者都复用 alu_op[11](lui) 通路，值塞进 ds_imm
- **异常返回 = ERA+4**（start.S 的 ex_finish 里软件加 4 再 ertn）→ 印证 ERA 填异常指令自己的 PC
- BADV 只在 ADEF/ALE 时更新；ECFG.LIE[10] 恒 0；flush 拍也要判 ADEF
- golden_trace：ex9 = 91593 行；**ex9 bit 已出并验证**（见"已出 bit"条目）

## 设计约定
- 五级流水 valid/allowin/ready_go；总线（当前最新）：BR=33, FS_TO_DS=65, DS_TO_ES=184, ES_TO_MS=82, MS_TO_WS=77, WS_TO_RF=38（括号内为初版：64/160/75/70）
- ALU 16 位 one-hot op：0-11=算逻/lui，12-14=mul.w/mulh.w/mulh.wu（**乘法器在 EXE_stage 单独实现，不在 alu.v**，前递走 es_forward_result 不含乘法）
- 前递优先级 EXE>MEM>WB，在 ID 级做；gr_we 用"正向或"译码；访存汇总信号 inst_ld_all/inst_st_all
- LA32R 无延迟槽；SLTUI 立即数仍符号扩展；操作码已逐条核对 A01 并实测
- 时序修复四轮定案（WNS +0.896/0 违例）：①乘法器移出 ALU（只改 mux 无效，必须换数据源）②branch_load_stall+分支操作数换 ms_forward_data_alu（无 BRAM 通路）
- 除法：divider.v 恢复余数法 32 拍，接口兼容 Xilinx Divider Generator；div_stall；es_ready_go 门控
- Block RAM 320/365=87.67% 铺满器件，布线是时序瓶颈根源

## ★ 第 6 章·异常与 CSR（EXP8，2026-10-22 完成，47 点全过）
- 新增 `myCPU/csr.v`（第 12 个源文件）：CRMD(0)/PRMD(1)/ESTAT(5)/ERA(6)/BADV(7)/EENTRY(C)/SAVE0~3(30-33)
  写统一 `wmask&wvalue | ~wmask&old`；复位 DA=1/PG=0；中断未做（has_int 恒 0）
- 指令编码（实测 ex8 机器码）：csrrd `[25:24]=00,[9:5]=0`；csrwr `[9:5]=1`；csrxchg `[9:5]=rj`；
  **ertn=06483800 / tlbwr=06483000 仅差 bit12，必须整体比对**；syscall `[31:16]=002B`；break `002A`
  csr_num = inst[23:10]（14 位）；Ecode: SYS=0xB BRK=0xC INE=0xD ALE=0x9 ADEF=0x8
- 总线加宽：DS_TO_ES 160→**179**、ES_TO_MS 75→**77**、MS_TO_WS 70→**72**
- CSR 读写都放 **EXE 级**（指导书 6.5 要求同级）；写仅在指令流出那拍发生一次且带 `!flush`
- CSR 结果不进 EXE 前递，改 `csr_stall` 阻塞一拍（避免长组合路径）
- 异常标志随指令带到 **WB 级**报出；`flush = wb_ex|wb_ertn_flush`，`flush_pc = wb_ex?ex_entry:era_pc`
- **EXP8 = 基础异常档；ADEF/ALE/INE/中断/rdcnt 属 EXP9 扩展档**（指导书 6.6 两档）

### ★ 第 6 章四个必踩的坑
1. **新增 .v 不会自动进工程**（create_project.tcl 用目录 add_files）→ 报 Module not found。
   已改显式 `glob *.v`，且 verify/rebuild 脚本每次重 add_files
2. **顶层漏连新端口 → X 传播卡死整条流水线**（ID 的 es_is_csr 忘连，Z&&X=X）。
   症状：debug_wb_pc 恒定。新增端口后必须 grep 顶层例化确认
3. **flush 拍没发出取指**：`inst_sram_en` 要 `flush || (...)`，且 `fs_pc` 更新要加
   `else if(flush) fs_pc<=flush_pc`。否则 PC 改了但指令是旧的 → 指令与 PC 不配对 → 跑飞
4. **精确异常破防**：syscall 走到 WB 的 3 拍里后面指令已在 EXE 发起 store。
   必须 ID 级关门：`ds_allowin` 加 `!ds_flush_inst && !exc_pending`，
   `ds_flush_inst=inst_syscall|inst_ertn`，`exc_pending` 保持到 flush（两者缺一不可）
