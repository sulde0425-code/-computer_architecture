# dump_bram_init.tcl —— 导出 inst_ram OOC dcp 里所有 BRAM 的 INIT 值
# 目的：确认 bit 里烧的到底是哪一套程序（换 coe 后 OOC dcp 没重跑是历史 69 分的根因）
set OUT "D:/Courses/Computer_organization_design/Main_project_1.1/.workbuddy/sim/bram_init_exp9.txt"
set DCP "D:/Courses/Computer_organization_design/Main_project_1.1/cdp_ede_local-master/mycpu_env/soc_verify/soc_bram/run_vivado/project/loongson.runs/inst_ram_synth_1/inst_ram.dcp"

open_checkpoint $DCP
set cells [get_cells -hier -filter {REF_NAME =~ RAMB*}]
puts "CELLS: [llength $cells]"
if {[llength $cells] > 0} {
    puts "SAMPLE_REF: [get_property REF_NAME [lindex $cells 0]]"
    puts "SAMPLE_NAME: [lindex $cells 0]"
}
set fp [open $OUT w]
foreach c $cells {
    set ref [get_property REF_NAME $c]
    set i1 [get_property INIT_01 $c]
    set i0 [get_property INIT_00 $c]
    puts $fp "$ref|$c|INIT00=$i0|INIT01=$i1"
}
close $fp
puts "WROTE: $OUT"
close_project
