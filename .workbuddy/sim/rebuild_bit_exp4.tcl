# rebuild_bit_exp4.tcl —— 修复"bit 里固化旧程序"问题，完整重出 EXP4 的 bit
# 核心：inst_ram IP 的 OOC 综合 dcp 停留在 09-22（当时 coe=ex1）。
# 换 coe 后必须重跑 IP 的 OOC 综合，否则 bit 里永远是旧程序。
set PROJECT "D:/Courses/Computer_organization_design/Main_project_1.1/cdp_ede_local-master/mycpu_env/soc_verify/soc_bram/run_vivado/project/loongson.xpr"
set OUTDIR  "D:/Courses/Computer_organization_design/Main_project_1.1/.workbuddy/sim"

open_project $PROJECT

# ---- PPT 第 7 页教程步骤 5：disable 工程中原有 xdc ----
# local xdc 的端口名（clk/led[..]）在 remote 顶层不存在，约束全部落空，
# 留着只会刷警告，按教程应禁用。
set local_xdc [get_files -quiet soc_lite_top.xdc]
if {[llength $local_xdc] > 0} {
    set_property IS_ENABLED false $local_xdc
    puts "STEP5: soc_lite_top.xdc 已禁用"
} else {
    puts "STEP5: 未找到 soc_lite_top.xdc（可能已禁用）"
}

# ---- 关键修复：强制重跑 inst_ram IP 的 OOC 综合 ----
puts "STEP-IP: reset_target inst_ram ..."
reset_target all [get_ips inst_ram]
puts "STEP-IP: generate_target inst_ram ..."
generate_target all [get_ips inst_ram]

set ooc_run [get_runs -quiet inst_ram_synth_1]
if {[llength $ooc_run] > 0} {
    reset_run $ooc_run
    launch_runs $ooc_run -jobs 16
    wait_on_run $ooc_run
    puts "STEP-IP: inst_ram OOC 综合完成"
} else {
    puts "STEP-IP: 未找到 inst_ram_synth_1（可能为全局综合模式，跳过）"
}

# ---- 主流程：综合 + 实现 + 出 bit ----
reset_run synth_1
launch_runs synth_1 -jobs 16
wait_on_run synth_1
puts "STEP-SYNTH: 主综合完成"

launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1
puts "STEP-IMPL: 实现与 bitstream 完成"

# ---- 验证与报告导出 ----
open_run impl_1
report_timing_summary -file $OUTDIR/timing_exp4_rerun.rpt
report_utilization    -file $OUTDIR/util_exp4_rerun.rpt
puts "==== TIMING ===="
report_timing_summary -quiet -no_header -max_paths 1 -return_string > $OUTDIR/timing_exp4_peek.rpt
set wns_line ""
foreach ln [split [report_timing_summary -quiet -no_header -return_string] "\n"] {
    if {[string match "*cpu_clk_clk_pll*" $ln] && [string match "*-20*" $ln] == 0} {
        if {[regexp {cpu_clk_clk_pll\s+.*} $ln]} { set wns_line $ln }
    }
}
puts "WNS-LINE: $wns_line"

set bit [glob -nocomplain [file dirname [get_property DIRECTORY [get_runs impl_1]]]/impl_1/*.bit]
puts "BIT-FILE: $bit"
puts "REBUILD_EXP4_DONE"
close_project
