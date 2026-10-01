# buﬁo_check.tcl - BUFIO 存在性 + IDDRE1 时钟引脚网名
set dcp [lindex $argv 0]
set tag [lindex $argv 1]
open_checkpoint $dcp
puts "### $tag"
set bios [get_cells -quiet -hier -filter {LIB_CELL =~ "*BUFIO*"}]
puts "BUFIO_COUNT=[llength $bios]"
foreach b $bios { puts "BUFIO_CELL [get_property NAME $b] LOC=[get_property LOC $b]" }
set isd [get_cells -quiet u_gmii_to_rgmii/u_rgmii_rx/IDDRE1_inst]
puts "IDDRE1_TOP=[get_property LIB_CELL $isd]"
foreach p [get_pins -quiet -of_objects $isd] {
    set pn [get_property NAME $p]
    if {![string match -nocase "*CLK*" $pn] && ![string match -nocase "*C" $pn]} { continue }
    set n [get_nets -quiet -of_objects $p]
    set nn "<none>"
    if {[llength $n]} { set nn [get_property NAME $n] }
    puts "PIN $pn NET=$nn"
}
puts "###END"
close_design