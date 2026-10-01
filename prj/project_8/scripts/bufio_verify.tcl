set dcp [lindex $argv 0]
open_checkpoint $dcp
set bios [get_cells -quiet -hier -filter {LIB_CELL =~ "*BUFIO*"}]
puts "BUFIO_COUNT=[llength $bios]"
foreach b $bios { puts "BUFIO_CELL [get_property NAME $b] LOC=[get_property LOC $b]" }
set p [get_pins -quiet u_gmii_to_rgmii/u_rgmii_rx/IDDRE1_inst/CLK]
set n [get_nets -quiet -of_objects $p]
puts "IDDRE1_CLKNET=[get_property NAME $n]"
close_design