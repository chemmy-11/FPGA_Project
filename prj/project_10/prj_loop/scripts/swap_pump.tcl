# swap_pump.tcl -- 在现有工程中把 prj9 原泵换成 rtl_patch 的 L1 乒乓泵
set P    D:/FPGA/prj/project_10/prj_loop
set P9   D:/FPGA/prj/project_9
open_project $P/vivado/prj_loop.xpr
set orig [get_files -quiet $P9/rtl/frame_fifo_pump.v]
if {[llength $orig] > 0} {
    remove_files $orig
    puts "PUMP_REMOVED: $orig"
} else {
    puts "PUMP_NOT_IN_PROJECT (可能已替换)"
}
set new [get_files -quiet $P/rtl_patch/frame_fifo_pump.v]
if {[llength $new] == 0} {
    add_files -fileset sources_1 $P/rtl_patch/frame_fifo_pump.v
    puts "PUMP_ADDED: $P/rtl_patch/frame_fifo_pump.v"
} else {
    puts "PUMP_ALREADY: $new"
}
set chk [get_files -quiet $P/rtl_patch/frame_fifo_pump.v]
puts "VERIFY_RTL_PATCH: [llength $chk] (期望 1)"
set chk2 [get_files -quiet $P9/rtl/frame_fifo_pump.v]
puts "VERIFY_P9_REMOVED: [llength $chk2] (期望 0)"
close_project
puts "SWAP_DONE"