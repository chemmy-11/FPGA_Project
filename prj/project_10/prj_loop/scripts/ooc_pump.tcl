set P D:/FPGA/prj/project_10/prj_loop
create_project -force ooc_pump D:/FPGA/prj/project_10/prj_loop/out/ooc_pump -part xcku060-ffva1156-2-i
read_verilog $P/rtl_patch/frame_fifo_pump.v
synth_design -top frame_fifo_pump -part xcku060-ffva1156-2-i -mode out_of_context
set rams [get_cells -hierarchical -quiet -filter {PRIMITIVE_TYPE =~ BMEM.*}]
puts "OOC_BRAM_COUNT: [llength $rams]"
foreach c [lrange $rams 0 3] { puts "  BRAM_CELL: $c" }
set ffs [get_cells -hierarchical -quiet -filter {PRIMITIVE_TYPE =~ CLB.*FF.*}]
puts "OOC_FF_COUNT: [llength $ffs]"
close_project
puts "OOC_DONE"
