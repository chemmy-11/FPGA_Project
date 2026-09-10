# =============================================================================
# build.tcl — project_8 综合/实现/位流（幂等）
# 用法（务必在 ASCII 工作目录）: cd D:\FPGA\project_8; vivado -mode batch -source scripts\build.tcl -notrace
# =============================================================================
open_project D:/FPGA/project_8/prj/project_8.xpr
reset_run synth_1
catch { reset_run impl_1 }
launch_runs impl_1 -to_step write_bitstream -jobs 2
wait_on_run impl_1
puts "STATUS: [get_property STATUS [get_runs impl_1]]"
puts "PROGRESS: [get_property PROGRESS [get_runs impl_1]]"
puts "BIT: [glob -nocomplain D:/FPGA/project_8/prj/project_8.runs/impl_1/*.bit]"
puts "BUILD_DONE"
