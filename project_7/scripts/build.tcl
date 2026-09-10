# =============================================================================
# build.tcl — project_7 synth/impl/bitstream (idempotent)
# 用法: vivado -mode batch -source build.tcl -notrace
# =============================================================================
open_project D:/FPGA/project_7/prj/project_7.xpr
# IP OOC runs are Complete; reset top-level runs only
reset_run synth_1
catch { reset_run impl_1 }
launch_runs impl_1 -to_step write_bitstream -jobs 2
wait_on_run impl_1
puts "STATUS: [get_property STATUS [get_runs impl_1]]"
puts "PROGRESS: [get_property PROGRESS [get_runs impl_1]]"
puts "BIT: [glob -nocomplain D:/FPGA/project_7/prj/project_7.runs/impl_1/*.bit]"
puts "BUILD_DONE"
