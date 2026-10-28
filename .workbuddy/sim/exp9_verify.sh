#!/usr/bin/env bash
# exp9_verify.sh —— 跑 EXP9 功能回归（第 6 章扩展档）
export PATH="/d/Xilinx/Vivado/2023.2/bin:$PATH"
ROOT="D:/Courses/Computer_organization_design/Main_project_1.1"
S="$ROOT/.workbuddy/sim"
cd "$ROOT" || exit 1

echo "==================== EXP9 ===================="
bash "$S/switch_exp.sh" 9
vivado -mode batch -source "$S/gt_expN.tcl" -tclargs 9 > "$S/exp9_gt.log" 2>&1
echo "golden_trace 行数: $(wc -l < "$ROOT/cdp_ede_local-master/mycpu_env/gettrace/golden_trace.txt")"
vivado -mode batch -source "$S/verify_expN_sim.tcl" -tclargs 9 > "$S/exp9_sim.log" 2>&1
echo "测试点 PASS 数: $(grep -c 'Functional Test Point PASS' "$S/exp9_sim.log")"
echo "最后的测试点编号: $(grep -o "Number 8'd[0-9]*" "$S/exp9_sim.log" | tail -1)"
grep -oE '\-\-\-\-PASS\!\!\!' "$S/exp9_sim.log" | tail -1
echo "--- 错误信息（若有）---"
grep -E "Error|error" "$S/exp9_sim.log" | head -10
echo "EXP9_VERIFY_DONE"
