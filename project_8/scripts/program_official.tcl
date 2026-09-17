set bit {D:/FPGA/project_8/out/official_39.bit}
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "OFFICIAL_PROGRAM_OK"
close_hw_target