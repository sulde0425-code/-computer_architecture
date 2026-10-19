# LoongArch（LA32R）五级流水线 CPU —— 计算机组成原理课程设计

基于 **LoongArch32 Reduced（LA32R）** 指令集、采用**经典五级流水**实现的 CPU，
在 Xilinx Artix-7（`xc7a200tfbg676-1`）上完成功能验证与时序收敛，
并通过校内远程 FPGA 平台的功能/性能自动评测。

本项目为「计算机组成原理」课程设计主体工程，覆盖教材前 5 章
（流水线骨架 → 算术逻辑 → 转移 → 访存 → 乘除）。

---

## 一、完成情况

| 章节 | 内容 | 功能测试点 | 状态 |
|---|---|---|---|
| 第 1–2 章 | 流水线骨架、握手规范、数据前递、Load-Use 阻塞 | — | 完成 |
| 第 3 章（EXP4） | 算术逻辑指令 | 29 | 通过 |
| 第 3 章（EXP5） | 转移指令 | 33 | 通过 |
| 第 4 章（EXP6） | 访存指令 `ld.b/h/w/bu/hu`、`st.b/h/w` | 39 | 通过 |
| 第 5 章（EXP7） | 乘除指令 | 46 | 完成 |

**最近一次实现（EXP6）关键指标**

- 时序：**WNS +0.782 ns**，TNS 0.000 ns，违例端点 **0 / 10442**，保持时间 WHS +0.082 ns
- 布线：`Router Completed Successfully`，`write_bitstream` 成功
- 资源：Block RAM 320 / 365（87.7%），布线资源是时序收敛的主要瓶颈
- 内容级验证：已从 `inst_ram.dcp` 导出全部 256 个 `RAMB36E1` 的 `INIT_01`，
  与 `inst_ram.coe` 推导值**逐字节完全一致**，确认 BRAM 中固化的确为 EXP6 程序

> 比特流（`.bit`）为构建产物，**未纳入版本管理**，请按第五节流程自行生成。

---

## 二、工具与环境

| 项目 | 版本 / 值 |
|---|---|
| FPGA 开发工具 | Xilinx Vivado **2023.2** |
| 器件 | `xc7a200tfbg676-1`（Artix-7） |
| 仿真器 | Vivado XSim |
| 指令集 | LoongArch32 Reduced（LA32R，无延迟槽） |
| 时钟 | 板载 50 MHz 输入 → PLL 50 MHz 输出 |

---

## 三、目录结构

```
Main_project_1.1/
├── cdp_ede_local-master/mycpu_env/
│   ├── myCPU/                     ★ 核心 CPU RTL（本项目主要工作量）
│   │   ├── IF_stage.v   ID_stage.v   EXE_stage.v
│   │   ├── MEM_stage.v  WB_stage.v   RegFiles.v
│   │   ├── alu.v        divider.v    tools.v
│   │   └── mycpu_head.v mycpu_h.v    （总线位宽 / 字段定义）
│   ├── soc_verify/soc_bram/       ★ 本课设使用的 SoC（BRAM 版）
│   │   ├── rtl/soc_lite_top.v     SoC 顶层
│   │   ├── rtl/BRIDGE/bridge_1x2.v 数据地址译码片选
│   │   ├── rtl/CONFREG/confreg.v  外设（数码管 / 拨码开关 / 计数器）
│   │   ├── rtl/xilinx_ip/         IP 定义（*.xci）
│   │   ├── testbench/             mycpu_tb.v + sync_ram.v（行为级 RAM）
│   │   └── run_vivado/            create_project.tcl + soc_lite_top.xdc
│   ├── gettrace/                  黄金模型（参考实现）+ golden_trace.txt
│   ├── func/                      功能测试程序（81 个 .S 汇编用例）
│   └── module_verify/             官方 cache / tlb / mul / div 验证工程
├── for_test_obj/ex1..ex9_obj/     各章测试镜像（inst_ram.coe / data_ram.coe）
├── .workbuddy/sim/                ★ 自动化脚本（换章 / 出 bit / 仿真 / 回归）
├── build_bit_exp.bat              双击出 bit（默认 EXP6）
├── LA32R五级流水线讲义_第1-2章.html   原理讲义（含模块图与代码实例）
├── EXP4_Vivado实验指南.html       Vivado 操作流程与换章避坑指南
└── CPU实现情况分析报告.html        实现情况分析
```

---

## 四、核心设计要点

### 4.1 握手规范（三条公式）

```
allowin       = !valid || (ready_go && next_allowin)   // 本级能否接收
to_next_valid = valid && ready_go                      // 本级是否向后级有效
if (prev_valid && allowin)  bus_r <= bus               // 数据推进一级
```

- `ready_go` 反映**本级**是否执行完毕（内部原因），`allowin` 反映**后级**是否可接收（外部原因）
- `allowin` 中的 `!valid` 不可省略：本级为空时不应等待自身"干活完成"，否则死锁
- 阻塞沿 `allowin` 逐级回传：EXE 卡住 → `es_allowin=0` → `ds_allowin=0` → `fs_allowin=0` → 取指也停

级间总线位宽：

| 总线 | 位宽 |
|---|---|
| `BR` | 33 |
| `FS_TO_DS` | 64 |
| `DS_TO_ES` | 160 |
| `ES_TO_MS` | 75 |
| `MS_TO_WS` | 70 |
| `WS_TO_RF` | 38 |

### 4.2 存储访问与片选

```verilog
assign inst_sram_en = to_fs_valid && fs_allowin;                   // IF 级
assign inst_sram_we = 4'h0;                                        // 指令 RAM 只读
assign data_sram_en = es_valid && (es_res_from_mem || es_mem_we);  // 仅 load/store
```

`fs_allowin` 参与指令片选是关键：IF 被阻塞时手上的指令无处可去，
此时仍读 RAM 会造成无效访问并冲掉下一次取指。

数据侧真正的"片选"在 `bridge_1x2.v`，按地址在 data_ram 与 confreg 外设之间选择：

```verilog
assign sel_conf = (cpu_data_addr & 32'h1fff_0000) == 32'h1faf_0000;
assign data_sram_en = cpu_data_en & sel_sram;
```

地址译码是组合逻辑，但读数据下一拍才返回，因此选择信号需打一拍（`sel_sram_r`）才知道应采哪一路。

**BRAM 两套实现**

| 场景 | 实现 | 换程序方式 |
|---|---|---|
| 仿真 | `testbench/sync_ram.v` 行为级数组 + `$readmemb` 读 `.mif` | 换 `func/obj/inst_ram.mif` |
| 上板 | Xilinx IP 综合为 256 个 `RAMB36E1` | 换 `.coe` 并**重跑 OOC 综合**（见第六节） |

地址使用 `cpu_inst_addr[19:2]`，即字节地址转字地址。

### 4.3 数据前递与 Load-Use 阻塞

- 只处理 **RAW** 相关
- 三级前递，优先级 **EXE > MEM > WB**（越"新"的结果越优先）
- 前递源有效需同时满足：`valid` + `gr_we` + `dest != 0` + `raddr == dest` + `ds_use_rj/rkd`
- **load 最早只能从 MEM 级前递**，因此 load 后紧跟的消费者必须**阻塞 1 拍**（Load-Use 冒险）

容易遗漏的四种特殊情况：

| 情况 | 不处理的后果 |
|---|---|
| 目标为 `$r0` | 前递使 `$r0` 变为非 0，所有依赖零寄存器的指令出错 |
| 写者是 store / 分支（不写寄存器） | 把 store 的**地址**误当作结果前递 |
| 消费者不使用该源（如 `addi.w`、`slli.w`、`jirl` 的 rk 位是立即数） | 误前递且白白损失一个周期 |
| store 的第二源是 `rd` 而非 `rk` | `ld.w $r5` → `st.w $r5` 会把**旧值**写入内存 |

此外 `branch_load_stall` 用于分支操作数来自 load 的场景，
分支比较操作数改用 `ms_forward_data_alu`（避免经过 BRAM 的长通路）以满足时序。

### 4.4 时序收敛要点

乘法器从 `alu.v` 中移出、在 `EXE_stage` 单独实现（仅改数据选择器无效，必须更换数据源），
是本工程时序收敛的关键改动之一；除法器采用 32 拍恢复余数法，通过 `div_stall` 与 `es_ready_go` 门控。

---

## 五、快速开始

以下命令均在**工程根目录**执行。

### 5.1 切换实验章节

```bash
bash .workbuddy/sim/switch_exp.sh 6     # 可换为 4 / 5 / 7 ...
```

该脚本同步**三个**位置并逐项 `cmp` 校验，旧状态自动备份至 `mycpu_env/.bak_<时间戳>/`：

1. `func/obj/inst_ram.coe` —— 综合使用（`inst_ram.xci` 的 `Coe_File` 指向它）
2. `func/obj/inst_ram.mif` —— 仿真使用（`sync_ram.v` 的 `$readmemb`）
3. `rtl/xilinx_ip/inst_ram/inst_ram.mif` —— `generate_target` 读取

> 三处缺一即出现"仿真通过、上板错误"。

### 5.2 生成黄金 trace（切换章节后、仿真前必做）

```bash
/d/Xilinx/Vivado/2023.2/bin/vivado.bat -mode batch -source .workbuddy/sim/gt_expN.tcl -tclargs 6
```

### 5.3 功能仿真

```bash
/d/Xilinx/Vivado/2023.2/bin/vivado.bat -mode batch -source .workbuddy/sim/verify_expN_sim.tcl -tclargs 6
```

轻量回归（ex1~ex7 一键，行为级 `sync_ram` 顶替 IP）：

```bash
bash .workbuddy/sim/run_regress.sh
```

### 5.4 生成比特流

```bash
/d/Xilinx/Vivado/2023.2/bin/vivado.bat -mode batch -source .workbuddy/sim/rebuild_bit_expN.tcl -tclargs 6
```

或**双击** `build_bit_exp.bat`（无参数默认 EXP6），产物自动归档为
`.workbuddy/sim/exp6/looongson_remote_top_EXP6.bit` 及根目录同名副本。全流程约 10–13 分钟。

---

## 六、避坑：更换程序后必须重跑 IP OOC 综合

这是本工程最隐蔽的坑：**`generate_target` 不会重跑 `inst_ram_synth_1`**。

真正把程序烧进 BRAM 的是 `loongson.runs/inst_ram_synth_1/inst_ram.dcp`；
仅执行 `reset_run synth_1` 会被 Vivado 判定 "already up-to-date" 而跳过，
导致生成的 bit 里固化的仍是旧章节程序（表现为各章评测分数完全一致）。

正确顺序：

```tcl
reset_target   all [get_ips inst_ram]
generate_target all [get_ips inst_ram]
reset_run      inst_ram_synth_1
launch_runs    inst_ram_synth_1
```

验证 bit 中装载的程序：导出 `inst_ram.dcp` 内 256 个 `RAMB36E1` 的 `INIT_01`，
与 `.coe` 推导值做全量比对。
BRAM 布局为 64 block × 4 byte-lane，`INIT_k` 覆盖块内字 `[32k .. 32k+31]`，
字节序 `b[31-j] = word(base+j)` 的第 lane 字节。
注意 ex4/ex5/ex6 前 8223 字完全相同，**必须取 `word[8224]` 之后**才能区分。

---

## 七、版本管理策略

仓库仅收录**人工编写**的内容：RTL 源码、约束、测试程序、脚本与文档；
一切可由工具重建的生成物均不入库。工作目录 751 MB → 仓库约 **24 MB**（243 个文件）。

被忽略的主要内容：

| 类别 | 说明 |
|---|---|
| Vivado 运行产物 | `*.runs/` `*.cache/` `*.hw/` `*.ip_user_files/` `*.sim/` `.Xil/`、`*.jou` `*.log` |
| IP 生成物 | `hdl/`、`*_sim_netlist.*` 等（`.xci` 是唯一真相，可一键重建） |
| 综合/实现产物 | `*.bit` `*.dcp` `*.rpt` `*.wdb` |
| 镜像中间物 | `test.s`、`rom.vlog`、非主用章节的 `inst_ram.mif`（与 `.coe` 等价但体积 4 倍） |
| 换章备份 | `.bak_*/` |
| 第三方教材 | `main.pdf`（版权材料，按需自行放置） |

若需把比特流一并托管，建议发布到 GitHub **Release** 而非直接提交二进制。
如需纳入 `main.pdf`，注释掉 `.gitignore` 最后一节即可。

---

## 八、参考

- 龙芯《CPU 设计实战》（LoongArch 版）—— 实验指导书与官方 SoC / 黄金模型框架
- LoongArch32 Reduced 指令集手册
- Xilinx UG473（7 系列 Block RAM 资源）

SoC 顶层框架、CONFREG 外设、黄金模型（`gettrace`）与功能测试程序（`func`）来自龙芯官方实验环境；
**五级流水 CPU 主体（`myCPU/`）为本项目实现**。
