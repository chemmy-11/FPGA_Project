# dly_hunt.tcl - IDELAYE3 到底在哪、接的谁
set dcp [lindex $argv 0]
open_checkpoint $dcp
puts "=== u_gmii_to_rgmii 模块绑定 ==="
set c [get_cells -quiet u_gmii_to_rgmii]
puts "LIB_CELL = [get_property LIB_CELL $c]"

puts "=== 层级中任何 *dly* 单元/层级 ==="
foreach x [get_cells -quiet -hier -filter {NAME =~ "*dly*"}] { puts "DLYCELL [get_property NAME $x] lib=[get_property LIB_CELL $x]" }

puts "=== IDELAYE3 连接详情 ==="
foreach id [get_cells -quiet -hier -filter {LIB_CELL == IDELAYE3}] {
    puts "--- [get_property NAME $id] LOC=[get_property LOC $id]"
    foreach p [get_pins -quiet -of_objects $id] {
        set dir [get_property DIRECTION $p]
        set net [get_nets -quiet -of_objects $p]
        puts "    [get_property NAME $p] ($dir) <- [get_property NAME $net]"
    }
    puts "    DELAY_FORMAT=[get_property DELAY_FORMAT $id] DELAY_VALUE=[get_property DELAY_VALUE $id] DELAY_TYPE=[get_property DELAY_TYPE $id] EN_VTC=[get_property EN_VTC $id]"
}
puts "DLY_HUNT_DONE"
close_design