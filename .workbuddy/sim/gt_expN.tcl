# gt_expN.tcl —— 仅为指定实验重新生成 golden_trace.txt（纯 Verilog 黄金模型，秒级）
# 用法：vivado -mode batch -source .workbuddy/sim/gt_expN.tcl -tclargs 5
set EXP 4
if {[llength $argv] > 0} { set EXP [lindex $argv 0] }
set GT "D:/Courses/Computer_organization_design/Main_project_1.1/cdp_ede_local-master/mycpu_env/gettrace"

open_project "$GT/gettrace.xpr"
launch_simulation
run 5 ms
close_sim
close_project

set f "$GT/golden_trace.txt"
if {[file exists $f]} {
    set fp [open $f r]; set n 0
    while {[gets $fp line] >= 0} { incr n }
    close $fp
    puts "GOLDEN_TRACE: EXP$EXP 行数 = $n"
} else {
    puts "GOLDEN_TRACE: !! 未生成"
}
puts "GT_EXP${EXP}_DONE"
