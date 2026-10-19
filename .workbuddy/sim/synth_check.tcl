# 仅做 RTL elaboration 检查：确认第 5 章改造后所有模块可解析、无缺失、无组合环
set RTL "D:/Courses/Computer_organization_design/Main_project_1.1/cdp_ede_local-master/mycpu_env/myCPU"
read_verilog [glob "$RTL/*.v"]
synth_design -rtl -top mycpu_top -part xc7a200tfbg676-2
report_utilization -hierarchical
puts "===== RTL ELABORATION OK ====="
