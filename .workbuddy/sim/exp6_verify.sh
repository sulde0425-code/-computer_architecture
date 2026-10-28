#!/usr/bin/env bash
# exp6_verify.sh —— 跑 EXP6 功能回归，取实测 PASS 数据，最后切回 EXP8 并恢复 golden_trace
export PATH="/d/Xilinx/Vivado/2023.2/bin:$PATH"
ROOT="D:/Courses/Computer_organization_design/Main_project_1.1"
S="$ROOT/.workbuddy/sim"
cd "$ROOT" || exit 1

echo "==================== EXP6 ===================="
bash "$S/switch_exp.sh" 6
vivado -mode batch -source "$S/gt_expN.tcl" -tclargs 6 > "$S/exp6_gt.log" 2>&1
echo "golden_trace 行数: $(wc -l < "$ROOT/cdp_ede_local-master/mycpu_env/gettrace/golden_trace.txt")"
vivado -mode batch -source "$S/verify_expN_sim.tcl" -tclargs 6 > "$S/exp6_sim.log" 2>&1
echo "测试点 PASS 数: $(grep -c 'Functional Test Point PASS' "$S/exp6_sim.log")"
grep -oE '\-\-\-\-PASS\!\!\!' "$S/exp6_sim.log" | tail -1
grep -E 'Error' "$S/exp6_sim.log" | head -5

echo "==================== 恢复 EXP8 ===================="
bash "$S/switch_exp.sh" 8
vivado -mode batch -source "$S/gt_expN.tcl" -tclargs 8 > "$S/exp8_gt.log" 2>&1
echo "golden_trace 行数(应为 87100): $(wc -l < "$ROOT/cdp_ede_local-master/mycpu_env/gettrace/golden_trace.txt")"
echo "EXP6_VERIFY_DONE"
