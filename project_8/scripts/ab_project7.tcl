# ab_project7.tcl - 烧 project_7 位流并 ping, 判定"板/PHY"还是"project_8 设计"
set bit {D:/FPGA/project_7/prj/project_7.runs/impl_1/sfp_udp_inner_loop.bit}
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
puts "DEVICE = [get_property NAME $dev]"
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "PROGRAMMED = $bit"
after 5000
puts "== PING project_7 design =="
catch { exec cmd /c "ping -n 4 192.168.1.10" } e
puts $e
puts "== ARP table =="
catch { exec cmd /c "arp -a" } a
puts $a
puts "AB7_DONE"
