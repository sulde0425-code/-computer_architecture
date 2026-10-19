#!/usr/bin/env bash
# switch_exp.sh —— 把验证/综合环境整体切换到第 N 套测试镜像
#
# 用法：  bash .workbuddy/sim/switch_exp.sh 6
#
# ★ 为什么必须有这个脚本（血泪教训）：
#   综合/出 bit 时 inst_ram 走的是 Xilinx blk_mem_gen 的 OOC 综合，
#   真正把程序烧进 BRAM 的是 loongson.runs/inst_ram_synth_1/inst_ram.dcp；
#   而仿真用的是 testbench/sync_ram.v（行为级 RAM）+ $readmemb 读 func/obj/*.mif。
#   两条通路吃的文件不同，任何一边漏同步都会造成"仿真对、上板错"。
#
#   本脚本一次同步三个位置：
#     ① func/obj/inst_ram.coe  —— 综合用（inst_ram.xci 的 Coe_File 指向它）
#     ② func/obj/inst_ram.mif  —— 仿真用（sync_ram.v 的 $readmemb 写死此相对路径）
#     ③ xilinx_ip/inst_ram/inst_ram.mif —— IP 目录下的副本，generate_target 会读它
#   并把旧状态备份到 mycpu_env/.bak_<时间戳>/ 便于回滚。

set -e

ROOT="D:/Courses/Computer_organization_design/Main_project_1.1"
MYENV="$ROOT/cdp_ede_local-master/mycpu_env"
SRC="$ROOT/for_test_obj/ex${1}_obj"
OBJ="$MYENV/func/obj"
IPDIR="$MYENV/soc_verify/soc_bram/rtl/xilinx_ip/inst_ram"

N="$1"
if [ -z "$N" ] || [ ! -d "$SRC" ]; then
    echo "用法: bash .workbuddy/sim/switch_exp.sh <实验号>"
    echo "可用镜像: $(ls -d "$ROOT"/for_test_obj/ex*_obj 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"
    exit 1
fi

echo "===== 切换到 EXP$N ====="
echo "源目录: for_test_obj/ex${N}_obj"

# ---- 1. 备份当前状态 ----
BAK="$MYENV/.bak_$(date +%m%d_%H%M%S)"
mkdir -p "$BAK"
cp "$OBJ"/inst_ram.coe "$OBJ"/inst_ram.mif "$OBJ"/data_ram.coe "$OBJ"/data_ram.mif \
   "$MYENV"/gettrace/golden_trace.txt "$BAK"/ 2>/dev/null || true
echo "旧状态已备份 -> $(basename "$BAK")"

# ---- 2. 同步三个位置 ----
cp "$SRC/inst_ram.coe" "$OBJ/inst_ram.coe"
cp "$SRC/inst_ram.mif" "$OBJ/inst_ram.mif"
cp "$SRC/inst_ram.mif" "$IPDIR/inst_ram.mif"
cp "$SRC/data_ram.coe" "$OBJ/data_ram.coe"  2>/dev/null || true
cp "$SRC/data_ram.mif" "$OBJ/data_ram.mif"  2>/dev/null || true

# ---- 3. 逐项校验 ----
ok=1
check() {  # check <实际文件> <期望文件> <标签>
    if cmp -s "$1" "$2"; then echo "  [OK]   $3"
    else echo "  [FAIL] $3  <-- 不同！"; ok=0; fi
}
echo "校验："
check "$OBJ/inst_ram.coe"  "$SRC/inst_ram.coe"  "func/obj/inst_ram.coe   (综合用)"
check "$OBJ/inst_ram.mif"  "$SRC/inst_ram.mif"  "func/obj/inst_ram.mif   (仿真用)"
check "$IPDIR/inst_ram.mif" "$SRC/inst_ram.mif" "IP目录/inst_ram.mif     (generate_target 读)"

# ---- 4. 提示后续 ----
echo
echo "md5 指纹（可据此确认 bit 里到底装了哪套程序）："
md5sum "$SRC/inst_ram.coe" | sed 's|^|  |'
echo
if [ "$ok" = 1 ]; then
    echo "镜像切换完成。"
    echo
    echo "接下来（按需选做）："
    echo "  A. 出 bit：   D:/Xilinx/Vivado/2023.2/bin/vivado.bat -mode batch -source .workbuddy/sim/rebuild_bit_expN.tcl -tclargs $N"
    echo "  B. 重生成黄金 trace（仿真前必做）："
    echo "                D:/Xilinx/Vivado/2023.2/bin/vivado.bat -mode batch -source .workbuddy/sim/gt_expN.tcl -tclargs $N"
    echo "  C. 跑仿真：   D:/Xilinx/Vivado/2023.2/bin/vivado.bat -mode batch -source .workbuddy/sim/verify_expN_sim.tcl -tclargs $N"
else
    echo "!! 存在不一致，请检查上面标记为 FAIL 的项"
    exit 1
fi
