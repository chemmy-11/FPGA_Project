# clk_autopsy.tcl v3 - 只输出关键缓冲/DDR单元
set dcp [lindex $argv 0]
set tag [lindex $argv 1]
open_checkpoint $dcp
puts "=== AUTOPSY $tag ==="

puts "--- IDDRE1 ---"
foreach c [get_cells -quiet -hier -filter {LIB_CELL =~ "*IDDRE*"}] {
    set cp [get_pins -quiet -of_objects $c -filter {REF_PIN_CODE == C}]
    set net [get_nets -quiet -of_objects $cp]
    set loc [get_property LOC $c]
    puts "IDDRE1 [get_property NAME $c] LOC=$loc CLK=[get_property NAME $net]"
}

puts "--- BUFIO ---"
foreach c [get_cells -quiet -hier -filter {LIB_CELL =~ "*BUFIO*"}] {
    puts "BUFIO [get_property NAME $c] LOC=[get_property LOC $c]"
}

puts "--- gmii_rx_clk driver tree ---"
set n [get_nets -quiet gmii_rx_clk]
if {[llength $n]} {
  set drv [get_cells -quiet -of_objects [get_pins -quiet -of_objects $n -filter {DIRECTION == OUT}]]
  puts "NET gmii_rx_clk drv=$drv"
  foreach d $drv { puts "  DRV [get_property NAME $d] lib=[get_property LIB_CELL $d] LOC=[get_property LOC $d]" }
}

puts "--- rgmii_rxc fanout buffers ---"
set rn [get_nets -quiet u_gmii_to_rgmii/u_rgmii_rx/rgmii_rxc]
if {![llength $rn]} { set rn [get_nets -quiet u_gmii_to_rgmii/rgmii_rxc] }
if {![llength $rn]} { set rn [get_nets -quiet rgmii_rxc] }
if {[llength $rn]} {
  puts "NET [get_property NAME $rn] loads:"
  foreach ld [get_pins -quiet -of_objects $rn -filter {DIRECTION == IN && IS_LEAF == 0}] {
    set lc [get_cells -quiet -of_objects $ld]
    puts "  LOAD $ld cell=[get_property NAME $lc] lib=[get_property LIB_CELL $lc]"
  }
}
puts "AUTOPSY_DONE $tag"
close_design