# swap_rx_fix.tcl - 文件集手术：官方 rgmii_rx.v 出列，rgmii_rx_fix.v 顶替
set proj D:/FPGA/project_8
open_project $proj/prj/project_8.xpr
set rm [list]
foreach f [get_files -quiet *rgmii_rx.v*] { lappend rm $f }
foreach f [get_files -quiet *rgmii_rx_dly.v] { lappend rm $f }
foreach f [get_files -quiet *gmii_to_rgmii_dly.v] { lappend rm $f }
foreach f $rm { puts "REMOVE: [get_property NAME $f]" ; remove_files $f }
add_files $proj/rtl/rgmii_rx_fix.v
puts "ADDED: rgmii_rx_fix.v"
update_compile_order -fileset sources_1
puts "FILES_NOW:"
foreach f [get_files -of [get_filesets sources_1] -filter {FILE_TYPE == SystemVerilog || FILE_TYPE == Verilog}] { puts "  [get_property NAME $f]" }
close_project
puts "SWAP_DONE"