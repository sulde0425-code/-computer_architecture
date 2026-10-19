# ============================================================
# 余量优化版：在时序已达标(第四轮 WNS=+0.782ns)的基础上，
# 换用更强的 布局/物理优化/布线 策略，争取把 +0.78ns 的余量拉大。
#
# 背景：本设计 Block RAM 占用率高达 87.67%（inst_ram 256 个 RAMB36 +
#       data_ram 64 个），几乎铺满整个器件，导致 CPU -> inst_ram 的
#       地址/使能译码布线极长（关键路径 18.884ns 里布线占 15.5ns / 82%）。
#       默认布局策略在这种"块 RAM 铺满全片"的场景下往往不是最优，
#       改用 Explore 布局 + AggressiveExplore 布线 + 物理优化有望拉开余量。
#
# 注意：只重跑 impl_1（复用已综合好的 synth_1），不重新综合。
# ============================================================
set PRJ "D:/Courses/Computer_organization_design/Main_project_1.1/cdp_ede_local-master/mycpu_env/soc_verify/soc_bram/run_vivado/project/loongson.xpr"
set OUT "D:/Courses/Computer_organization_design/Main_project_1.1/.workbuddy/sim/timing_explore.rpt"

open_project $PRJ

# --- 更强的实现策略 ---
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]

# 只重跑实现阶段（synth_1 结果复用）
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set st [get_property STATUS [get_runs impl_1]]
puts "IMPL_STATUS: $st"

open_run impl_1
report_timing_summary -max_paths 20 -warn_on_violation -file $OUT
report_utilization -file "D:/Courses/Computer_organization_design/Main_project_1.1/.workbuddy/sim/util_explore.rpt"

puts "EXPLORE_DONE"
close_project
