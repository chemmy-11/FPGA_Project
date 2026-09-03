# =============================================================================
# build.tcl — project_6 综合实现出位流（幂等重跑）
# 用法: vivado -mode batch -source build.tcl -notrace
# =============================================================================
open_project D:/FPGA/project_6/project_6.xpr
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "STATUS: [get_property STATUS [get_runs impl_1]]"
puts "PROGRESS: [get_property PROGRESS [get_runs impl_1]]"
puts "BIT: [glob -nocomplaint D:/FPGA/project_6/project_6.runs/impl_1/*.bit]"
puts "BUILD_DONE"
