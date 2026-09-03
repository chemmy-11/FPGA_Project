open_project D:/FPGA/aurora_64b66b_loop_ex/aurora_64b66b_0_ex/aurora_64b66b_0_ex.xpr
add_files -fileset sources_1 D:/FPGA/aurora_64b66b_loop_ex/aurora_64b66b_0_ex/imports/uart_bridge.v
set_property top aurora_64b66b_0_exdes [current_fileset]
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "STATUS: [get_property STATUS [get_runs impl_1]]"
puts "BIT: [glob -nocomplaint D:/FPGA/aurora_64b66b_loop_ex/aurora_64b66b_0_ex/aurora_64b66b_0_ex.runs/impl_1/*.bit]"
puts "DONE"
