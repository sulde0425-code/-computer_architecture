create_project -force loongson ./project -part xc7a200tfbg676-1

# Add conventional sources
add_files -scan_for_includes [glob -nocomplain ../rtl/*.v]
add_files -scan_for_includes [glob -nocomplain ../rtl/*/*.v]

# Add IPs
add_files -quiet [glob -nocomplain ../rtl/xilinx_ip/*/*.xci]

# Add simulation files
add_files -fileset sim_1 ../testbench

# Add myCPU
# 注意：这里必须逐个 .v 显式列出，不能只给目录。只给目录时 Vivado 只在
# 首次建工程时扫描一次，之后往 myCPU/ 里新增的源文件（例如第 6 章的 csr.v）
# 不会被自动发现，仿真会报 "Module <xxx> not found"。
add_files -scan_for_includes [glob -nocomplain ../../../myCPU/*.v]
# 保险起见仍保留目录形式，便于 Vivado 自行核对
add_files -scan_for_includes ../../../myCPU

# Add constraints
add_files -fileset constrs_1 -quiet ./constraints

set_property -name "top" -value "tb_top" -objects  [get_filesets sim_1]
set_property -name "xsim.simulate.log_all_signals" -value "1" -objects [get_filesets sim_1]
