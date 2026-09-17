# swap2.tcl - 换入 plan B (IDELAY+IDELAYCTRL)
set proj D:/FPGA/project_8
open_project $proj/prj/project_8.xpr
foreach f [get_files -quiet *rgmii_rx_fix.v] { puts "REMOVE: [get_property NAME $f]"; remove_files $f }
add_files $proj/rtl/rgmii_rx_fix2.v
puts "ADDED: rgmii_rx_fix2.v"
update_compile_order -fileset sources_1
close_project
puts "SWAP2_DONE"