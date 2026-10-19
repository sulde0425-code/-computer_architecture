# 项目长期记忆 — LoongArch(LA32R) 五级流水 CPU 课设
（详细过程见 .workbuddy/memory/2026-10-15.md 与 2026-10-16.md）

## 工程路径
- RTL：`Main_project_1.1/cdp_ede_local-master/mycpu_env/myCPU/`（11 个 .v 含 divider.v；dpic.v 已删，备份 `.workbuddy/backup/`）
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
- 各章 golden_trace 行数：ex4=62377 / ex5=71332 / ex6=79750；
  ex6 coe md5 `a76338349250a0465346deb004e4c1db`（123101 字）
- **验证 bit 装了哪套程序**：导出 `inst_ram_synth_1/inst_ram.dcp` 里 256 个 RAMB36E1 的
  `INIT_01`（注意剥掉 `256'h` 前缀），与 coe 推导值做 multiset 比对。
  布局模型：64 block × 4 byte-lane，每 RAMB36 存 4096 字的一个字节通道，
  `INIT_k` 覆盖 block 内字 `[32k..32k+31]`，字节序 `b[31-j] = word(base+j) 的第 lane 字节`。
  **ex4/ex5/ex6 前 8223 字相同，必须取 word[8224] 之后才判别得出**

## ★ 69 分最终根因（2026-10-16）
**所有历史 bit 里固化的是 ex1 程序**：IP OOC dcp 停在 09-22（当时 coe=出厂=ex1），换镜像后从未重跑 OOC 综合 → 平台按各章测试点判分，每章都是 69。次要因素：50MHz 时序不收敛（已修）。

## 线上评测（校内赛平台）
- 上传 bit → 远程 FPGA → 功能+性能自动评测；评分：个人 60 = 前五章 50 + 报告 10；团队 40 = 异常 20~25 + 创新 5~10 + 报告 10
- 工程按 PPT 第 7 页教程配置：remote2local.v + `cdp_ede_remote-master/mycpu_env/loongson_remote_top.v`（顶层 looongson_remote_top，3 个 o 官方拼写）+ loongson_remote.xdc（clk_50M 20ns）+ 禁用原 xdc + PLL 50in/50out（已确认）
- PPT 第 13 页：ex4=slti/sltui/andi/ori/xori/sll/srl/sra/pcaddu12i 29 点；ex5 转移 33 点；ex6 访存 39 点；ex7 乘除 46 点

## 设计约定
- 五级流水 valid/allowin/ready_go；总线：BR=33, FS_TO_DS=64, DS_TO_ES=160, ES_TO_MS=75, MS_TO_WS=70, WS_TO_RF=38
- ALU 16 位 one-hot op：0-11=算逻/lui，12-14=mul.w/mulh.w/mulh.wu（**乘法器在 EXE_stage 单独实现，不在 alu.v**，前递走 es_forward_result 不含乘法）
- 前递优先级 EXE>MEM>WB，在 ID 级做；gr_we 用"正向或"译码；访存汇总信号 inst_ld_all/inst_st_all
- LA32R 无延迟槽；SLTUI 立即数仍符号扩展；操作码已逐条核对 A01 并实测
- 时序修复四轮定案（WNS +0.896/0 违例）：①乘法器移出 ALU（只改 mux 无效，必须换数据源）②branch_load_stall+分支操作数换 ms_forward_data_alu（无 BRAM 通路）
- 除法：divider.v 恢复余数法 32 拍，接口兼容 Xilinx Divider Generator；div_stall；es_ready_go 门控
- Block RAM 320/365=87.67% 铺满器件，布线是时序瓶颈根源
