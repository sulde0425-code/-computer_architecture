# rebuild_bit_expN.tcl —— 换任意实验镜像后完整重出 bit（含 IP OOC 综合重跑）
#
# 用法：
#   vivado -mode batch -source .workbuddy/sim/rebuild_bit_expN.tcl -tclargs 5
#   （-tclargs 参数 = 实验号 N，仅用于报告命名；镜像必须先由外部脚本复制好）
#
# ★ 为什么必须重跑 inst_ram_synth_1：
#   inst_ram 是 blk_mem_gen IP，采用 OOC（out-of-context）综合。主综合 synth_1 只
#   引用它的 stub，真正把程序数据烧进 BRAM 的是 loongson.runs/inst_ram_synth_1/inst_ram.dcp。
#   换 Coe_File 后 generate_target 只更新 mif/仿真模型，不会重跑该 dcp；若只
#   reset_run synth_1，Vivado 会认为 IP "already up-to-date"，bit 里仍是旧程序。
#
set EXP 4
if {[llength $argv] > 0} { set EXP [lindex $argv 0] }

set PROJECT "D:/Courses/Computer_organization_design/Main_project_1.1/cdp_ede_local-master/mycpu_env/soc_verify/soc_bram/run_vivado/project/loongson.xpr"
set OUTDIR  "D:/Courses/Computer_organization_design/Main_project_1.1/.workbuddy/sim"

puts "===== 目标：EXP$EXP 的 bitstream ====="
open_project $PROJECT

# 顶层必须仍为 looongson_remote_top（3 个 o 为官方拼写）
puts "TOP: [get_property TOP [get_filesets sources_1]]"

# ---- PPT 第 7 页教程步骤 5：disable 工程中原有 xdc ----
set local_xdc [get_files -quiet soc_lite_top.xdc]
if {[llength $local_xdc] > 0} {
    set_property IS_ENABLED false $local_xdc
    puts "STEP5: soc_lite_top.xdc -> disabled"
}
# 确认 remote 约束生效
foreach f [get_files -quiet *.xdc] {
    puts "XDC: $f  enabled=[get_property IS_ENABLED $f]"
}

# ---- 确认 IP 的 Coe_File 指向 func/obj/inst_ram.coe，并记录源镜像指纹 ----
set inst_ip [get_ips inst_ram]
set coe [get_property CONFIG.Coe_File $inst_ip]
puts "COE_FILE: $coe"

set MYENV "D:/Courses/Computer_organization_design/Main_project_1.1/cdp_ede_local-master/mycpu_env"
foreach src [list "$MYENV/func/obj/inst_ram.coe" "$MYENV/func/obj/inst_ram.mif" \
                  "$MYENV/soc_verify/soc_bram/rtl/xilinx_ip/inst_ram/inst_ram.mif"] {
    if {[file exists $src]} {
        puts "SRC: [file tail $src]  size=[file size $src]  mtime=[clock format [file mtime $src] -format {%m-%d %H:%M}]"
    } else {
        puts "SRC: !! missing $src"
    }
}

# ---- 关键步骤：重跑 inst_ram 的 OOC 综合 ----
puts "STEP-IP: reset_target + generate_target inst_ram ..."
reset_target all $inst_ip
generate_target all $inst_ip

set ooc [get_runs -quiet inst_ram_synth_1]
if {[llength $ooc] > 0} {
    reset_run $ooc
    launch_runs $ooc -jobs 16
    wait_on_run $ooc
    puts "STEP-IP: inst_ram OOC synth DONE  ->  [get_property STATUS $ooc]"
    set dcp [get_property DIRECTORY $ooc]/inst_ram.dcp
    puts "STEP-IP: dcp = $dcp"
} else {
    puts "STEP-IP: WARN 未找到 inst_ram_synth_1"
}

# ---- 主流程 ----
reset_run synth_1
launch_runs synth_1 -jobs 16
wait_on_run synth_1
puts "STEP-SYNTH: [get_property STATUS [get_runs synth_1]]"

launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1
puts "STEP-IMPL: [get_property STATUS [get_runs impl_1]]"

# ---- 报告导出 ----
open_run impl_1
report_timing_summary -file $OUTDIR/timing_exp${EXP}.rpt
report_utilization    -file $OUTDIR/util_exp${EXP}.rpt

# ---- 归档 bit（按实验号命名，避免被下一次构建覆盖）----
set bit [glob -nocomplain [get_property DIRECTORY [get_runs impl_1]]/*.bit]
puts "BIT-FILE: $bit"

set ARCH "$OUTDIR/exp${EXP}"
file mkdir $ARCH
foreach b $bit {
    set dst "$ARCH/looongson_remote_top_EXP${EXP}.bit"
    file copy -force $b $dst
    puts "ARCHIVED-BIT: $dst"
    # 根目录也放一份，方便直接上传平台
    set root "D:/Courses/Computer_organization_design/Main_project_1.1/looongson_remote_top_EXP${EXP}.bit"
    file copy -force $b $root
    puts "ROOT-BIT: $root"
}
file copy -force $OUTDIR/timing_exp${EXP}.rpt "$ARCH/" 2>/dev/null
file copy -force $OUTDIR/util_exp${EXP}.rpt   "$ARCH/" 2>/dev/null

puts "REBUILD_EXP${EXP}_DONE"
close_project
