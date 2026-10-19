# =============================================================================
#  verify_exp4.tcl  ——  在真实 Vivado 工程里跑 EXP4（第3章·算术逻辑指令）
#
#  做三件事：
#   1) 把 for_test_obj/ex4_obj 的镜像装入 mycpu_env/func/obj/
#   2) 重新生成 golden_trace.txt（用 gettrace 黄金模型工程）
#   3) 用 soc_bram/loongson 工程跑行为仿真，输出 PASS/FAIL
# =============================================================================

set ROOT "D:/Courses/Computer_organization_design/Main_project_1.1"
set IMG  "$ROOT/for_test_obj/ex4_obj"
set OBJ  "$ROOT/cdp_ede_local-master/mycpu_env/func/obj"
set PROJ "$ROOT/cdp_ede_local-master/mycpu_env/soc_verify/soc_bram/run_vivado/project"
set GT   "$ROOT/cdp_ede_local-master/mycpu_env/gettrace"

puts "================== STEP 1 : 装 EXP4 镜像 =================="
foreach f {inst_ram.coe inst_ram.mif data_ram.coe data_ram.mif} {
    if {[file exists "$IMG/$f"]} {
        file copy -force "$IMG/$f" "$OBJ/$f"
        puts "  copied $f"
    } else {
        puts "  !! missing $IMG/$f"
    }
}

puts "================== STEP 2 : 重新生成 golden_trace =================="
open_project "$GT/gettrace.xpr"
puts "  ip status: [get_property NEEDS_REFRESH [get_filesets sim_1]]"
launch_simulation
run 5 ms
close_sim
close_project
if {[file exists "$GT/golden_trace.txt"]} {
    set fp [open "$GT/golden_trace.txt" r]
    set n 0
    while {[gets $fp line] >= 0} { incr n }
    close $fp
    puts "  golden_trace.txt 行数 = $n"
} else {
    puts "  !! golden_trace.txt 未生成"
}

puts "================== STEP 3 : 跑 EXP4 行为仿真 =================="
open_project "$PROJ/loongson.xpr"

# 换了 coe，必须重新生成 inst_ram 的输出产物（网表里嵌的是初始化数据）
if {[llength [get_ips -quiet inst_ram]] > 0} {
    puts "  reset + regenerate inst_ram IP ..."
    reset_target all [get_ips inst_ram]
    generate_target all [get_ips inst_ram]
} else {
    puts "  !! 找不到 inst_ram IP"
}

set_property top tb_top [get_filesets sim_1]
launch_simulation
run 5 ms
close_sim
close_project

puts "REBUILD_DONE"
