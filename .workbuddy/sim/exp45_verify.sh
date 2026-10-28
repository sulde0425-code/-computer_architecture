#!/usr/bin/env bash
# exp45_verify.sh —— 串行跑 EXP4 / EXP5 的功能回归，取实测 PASS 数据，
#                    最后切回 EXP8 并恢复其 golden_trace
export PATH="/d/Xilinx/Vivado/2023.2/bin:$PATH"
ROOT="D:/Courses/Computer_organization_design/Main_project_1.1"
S="$ROOT/.workbuddy/sim"
cd "$ROOT" || exit 1

for N in 4 5; do
  echo "==================== EXP$N ===================="
  bash "$S/switch_exp.sh" "$N"
  vivado -mode batch -source "$S/gt_expN.tcl" -tclargs "$N" > "$S/exp${N}_gt.log" 2>&1
  echo "golden_trace 行数: $(wc -l < "$ROOT/cdp_ede_local-master/mycpu_env/gettrace/golden_trace.txt")"
  vivado -mode batch -source "$S/verify_expN_sim.tcl" -tclargs "$N" > "$S/exp${N}_sim.log" 2>&1
  echo "测试点 PASS 数: $(grep -c 'Functional Test Point PASS' "$S/exp${N}_sim.log")"
  grep -oE '\-\-\-\-PASS\!\!\!' "$S/exp${N}_sim.log" | tail -1
  grep -E 'Error' "$S/exp${N}_sim.log" | head -5
done

echo "==================== 恢复 EXP8 ===================="
bash "$S/switch_exp.sh" 8
vivado -mode batch -source "$S/gt_expN.tcl" -tclargs 8 > "$S/exp8_gt.log" 2>&1
echo "golden_trace 行数(应为 87100): $(wc -l < "$ROOT/cdp_ede_local-master/mycpu_env/gettrace/golden_trace.txt")"
echo "EXP45_VERIFY_ALL_DONE"
