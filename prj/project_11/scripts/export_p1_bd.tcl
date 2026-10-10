set P D:/FPGA/prj/project_11
open_project D:/FPGA/prj/project_1/project_1.xpr
open_bd_design [get_files design_1.bd]
write_bd_tcl $P/scripts/imported_p1_bd.tcl
puts "EXPORT_DONE"
exit
