# verify_expN_sim.tcl —— 对已装好的实验镜像跑一次真实工程行为仿真
# （镜像与 golden_trace 需已由外部脚本准备好）
# 用法：vivado -mode batch -source .workbuddy/sim/verify_expN_sim.tcl -tclargs 5
set EXP 4
if {[llength $argv] > 0} { set EXP [lindex $argv 0] }
set ROOT "D:/Courses/Computer_organization_design/Main_project_1.1"
set PROJ "$ROOT/cdp_ede_local-master/mycpu_env/soc_verify/soc_bram/run_vivado/project"

puts "================== EXP$EXP 行为仿真 =================="
open_project "$PROJ/loongson.xpr"

# 同步 myCPU 源文件：工程原始脚本是用"目录"方式 add_files 的，
# 之后新增的 .v（例如第 6 章的 csr.v）不会被自动发现，会导致
# elaborate 报 "Module <xxx> not found"。这里每跑一次都重新登记一遍。
foreach f [glob -nocomplain "$ROOT/cdp_ede_local-master/mycpu_env/myCPU/*.v"] {
    add_files -scan_for_includes -norecurse $f
}

if {[llength [get_ips -quiet inst_ram]] > 0} {
    reset_target all [get_ips inst_ram]
    generate_target all [get_ips inst_ram]
}
set_property top tb_top [get_filesets sim_1]
launch_simulation
run 5 ms
close_sim
close_project
puts "SIM_EXP${EXP}_DONE"
