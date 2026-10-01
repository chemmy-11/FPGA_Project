# cmp2.tcl v2
set dcp [lindex $argv 0]
set tag [lindex $argv 1]
open_checkpoint $dcp
puts "### $tag"
foreach c [get_cells -quiet -hier -filter {NAME =~ "*rgmii_rx*" && IS_PRIMITIVE}] {
    set lib [get_property LIB_CELL $c]
    set keep 0
    if {$lib eq "IDELAYE3"} { set keep 1 }
    if {$lib eq "BUFGCE"} { set keep 1 }
    if {[string match "ISERDE*" $lib]} { set keep 1 }
    if {!$keep} { continue }
    set n [get_property NAME $c]
    set loc [get_property LOC $c]
    set extra ""
    if {$lib eq "IDELAYE3"} { set extra " DELAY=[get_property DELAY_VALUE $c] VTC=[get_property EN_VTC $c] TYPE=[get_property DELAY_TYPE $c]" }
    if {[string match "ISERDE*" $lib]} {
        set cp [get_pins -quiet -of_objects $c -filter {REF_PIN_CODE == C}]
        set cn [get_nets -quiet -of_objects $cp]
        set drv [get_cells -quiet -of_objects [get_pins -quiet -of_objects $cn -filter {DIRECTION == OUT}]]
        set extra " Cnet=[get_property NAME $cn] drv=[get_property NAME $drv] drvLOC=[get_property LOC $drv]"
    }
    puts "#$lib $n LOC=$loc$extra"
}
puts "###END"
close_design