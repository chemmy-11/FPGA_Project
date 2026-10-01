# dly_cmp.tcl - 只对比 IDELAYE3 及 rgmii_rx 内部单元
set dcp [lindex $argv 0]
set tag [lindex $argv 1]
open_checkpoint $dcp
puts "### $tag"
set u [get_cells -quiet u_gmii_to_rgmii]
if {[llength $u]} { puts "#top_inst lib=[get_property LIB_CELL $u]" }
puts "#rgmii_rx cells:"
foreach c [get_cells -quiet -hier -filter {NAME =~ "*rgmii_rx*" && IS_PRIMITIVE}] {
    puts "#CELL [get_property NAME $c] lib=[get_property LIB_CELL $c]"
}
puts "#IDELAYE3 count: [llength [get_cells -quiet -hier -filter {LIB_CELL == IDELAYE3}]]"
foreach id [get_cells -quiet -hier -filter {LIB_CELL == IDELAYE3}] {
    set dv [get_property DELAY_VALUE $id]
    set vt [get_property EN_VTC $id]
    set loc [get_property LOC $id]
    set pn [get_property NAME $id]
    puts "#IDELAY $pn LOC=$loc DELAY=$dv VTC=$vt"
}
puts "###END_$tag"
close_design