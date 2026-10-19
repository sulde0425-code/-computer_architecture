# ============================================================
# 重新综合 + 实现 + 生成 bit 文件（线上评测用）
# 目的：验证"乘法器退出 EXE 前递路径"后时序是否收敛
# ============================================================
set PRJ "D:/Courses/Computer_organization_design/Main_project_1.1/cdp_ede_local-master/mycpu_env/soc_verify/soc_bram/run_vivado/project/loongson.xpr"
set OUT "D:/Courses/Computer_organization_design/Main_project_1.1/.workbuddy/sim/timing_after_fix.rpt"

open_project $PRJ

# 源码已改动，强制重跑综合与实现
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set st [get_property STATUS [get_runs impl_1]]
puts "IMPL_STATUS: $st"

open_run impl_1
report_timing_summary -max_paths 20 -warn_on_violation -file $OUT
report_utilization -file "D:/Courses/Computer_organization_design/Main_project_1.1/.workbuddy/sim/util_after_fix.rpt"

puts "REBUILD_DONE"
close_project
