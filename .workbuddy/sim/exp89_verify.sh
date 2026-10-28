#!/usr/bin/env bash
# exp89_verify.sh —— 回归 EXP8（基础异常档）+ 最终确认 EXP9（扩展档）
# 两个 vivado 任务必须严格串行，不能重叠启动
export PATH="/d/Xilinx/Vivado/2023.2/bin:$PATH"
ROOT="D:/Courses/Computer_organization_design/Main_project_1.1"
S="$ROOT/.workbuddy/sim"
GT="$ROOT/cdp_ede_local-master/mycpu_env/gettrace/golden_trace.txt"
cd "$ROOT" || exit 1

run_one () {
  local N=$1
  echo "==================== EXP$N ===================="
  bash "$S/switch_exp.sh" "$N" > /dev/null
  vivado -mode batch -source "$S/gt_expN.tcl" -tclargs "$N" > "$S/exp${N}_gt.log" 2>&1
  echo "golden_trace 行数: $(wc -l < "$GT")"
  vivado -mode batch -source "$S/verify_expN_sim.tcl" -tclargs "$N" > "$S/exp${N}_sim.log" 2>&1
  echo "测试点 PASS 数: $(grep -c 'Functional Test Point PASS' "$S/exp${N}_sim.log")"
  grep -oE '\-\-\-\-PASS\!\!\!' "$S/exp${N}_sim.log" | tail -1
  grep -A3 'Error!!!' "$S/exp${N}_sim.log" | head -6
}

run_one 8
run_one 9
echo "EXP89_VERIFY_DONE"
