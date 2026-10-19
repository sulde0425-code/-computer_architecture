#!/bin/bash
# 回归验证：对参考镜像做差异测试
# ex1=第1章基础  ex2=第1章补充  ex3=前递  ex4=第3章算逻  ex5=第3章转移
# ex6=第4章访存  ex7=第5章乘除
export PATH="/d/Xilinx/Vivado/2023.2/bin:$PATH"

S="D:/Courses/Computer_organization_design/Main_project_1.1/.workbuddy/sim"
RTLC="$S/rtl_mycpu"
SRCM="D:/Courses/Computer_organization_design/Main_project_1.1/cdp_ede_local-master/mycpu_env/myCPU"
T="D:/Courses/Computer_organization_design/Main_project_1.1/for_test_obj"
GT="$S/mycpu_env/gettrace/gettrace.sim/sim_1/behav/xsim"
SB="$S/mycpu_env/soc_verify/soc_bram/run_vivado/project/loongson.sim/sim_1/behav/xsim"

# 用工程里修复后的 RTL 覆盖仿真副本（tb 与 clk_pll_stub 不在 myCPU 目录，不受影响）
cp "$SRCM"/*.v "$RTLC/"

cd "$SB" || exit 1
rm -rf xsim.dir work ./*.pb ./*.jou ./*.log
xvlog -i "$RTLC" \
  "$RTLC/mycpu_tb.v" "$RTLC/sync_ram.v" "$RTLC/bridge_1x2.v" "$RTLC/confreg.v" \
  "$RTLC/tools.v" "$RTLC/alu.v" "$RTLC/RegFiles.v" "$RTLC/divider.v" \
  "$RTLC/IF_stage.v" "$RTLC/ID_stage.v" "$RTLC/EXE_stage.v" "$RTLC/MEM_stage.v" "$RTLC/WB_stage.v" \
  "$RTLC/mycpu_head.v" "$RTLC/clk_pll_stub.v" "$RTLC/soc_lite_top.v" > xvlog.log 2>&1
if grep -q ERROR xvlog.log; then echo "xvlog 失败"; grep ERROR xvlog.log | head; exit 1; fi
xelab -debug off tb_top -s sim1 > xelab.log 2>&1
if grep -q ERROR xelab.log; then echo "xelab 失败"; grep ERROR xelab.log | head; exit 1; fi
printf 'run 10 ms\nexit\n' > stop.tcl
echo "编译完成，开始逐套回归"
echo "-----------------------------------------------"

for exp in ex1 ex2 ex3 ex4 ex5 ex6 ex7; do
  cp "$T/${exp}_obj/inst_ram.mif" "$S/mycpu_env/func/obj/inst_ram.mif"
  cp "$T/${exp}_obj/data_ram.mif" "$S/mycpu_env/func/obj/data_ram.mif"
  ( cd "$GT" && xsim sim1 -R > "gt_$exp.log" 2>&1 )
  GTOK=$(grep -c "Succeed in generating" "$GT/gt_$exp.log")
  ( cd "$SB" && xsim sim1 -tclbatch stop.tcl > "my_$exp.log" 2>&1 )
  P=$(grep -c "Functional Test Point PASS" "$SB/my_$exp.log")
  E=$(grep -c "Error\!"\!"\!" "$SB/my_$exp.log")
  R=$(grep -oE "\-\-\-\-PASS\!\!\!" "$SB/my_$exp.log" | tail -1)
  GTN=$(wc -l < "$S/mycpu_env/gettrace/golden_trace.txt")
  echo "$exp : 黄金trace生成=$GTOK  黄金trace行数=$GTN  我的CPU测试点PASS=$P  比对错误=$E  ${R:-未通过}"
done
echo "-----------------------------------------------"
echo "回归结束"
