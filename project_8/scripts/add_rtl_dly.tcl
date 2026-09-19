# add_rtl_dly.tcl - 把改动 D 新增的 RTL 加入现有工程（一次性）
open_project D:/FPGA/project_8/prj/project_8.xpr
add_files -fileset sources_1 [list D:/FPGA/project_8/rtl/rgmii_rx_dly.v D:/FPGA/project_8/rtl/gmii_to_rgmii_dly.v]
update_compile_order -fileset sources_1
puts "SOURCES_NOW:"
foreach f [get_files -of_objects [get_filesets sources_1]] { puts "  $f" }
close_project
puts "ADD_RTL_DONE"
