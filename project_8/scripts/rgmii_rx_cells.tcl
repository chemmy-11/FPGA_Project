# rgmii_rx_cells.tcl - 列出 rgmii_rx 模块的所有物理单元
set dcp [lindex $argv 0]
set tag [lindex $argv 1]
open_checkpoint $dcp
puts "=== CELLS_UNDER u_rgmii_rx ($tag) ==="
foreach c [get_cells -quiet u_gmii_to_rgmii/u_rgmii_rx/*] {
    puts "CELL [get_property NAME $c] lib=[get_property LIB_CELL $c] LOC=[get_property LOC $c]"
}
puts "=== CELLS_UNDER u_gmii_to_rgmii (top level only) ==="
foreach c [get_cells -quiet u_gmii_to_rgmii/*] {
    if {[get_property IS_PRIMITIVE $c]} { puts "CELL [get_property NAME $c] lib=[get_property LIB_CELL $c] LOC=[get_property LOC $c]" }
}
puts "DONE_$tag"
close_design