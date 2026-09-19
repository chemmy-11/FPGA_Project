# cmp4.tcl - 枚举 ISERDESE3 引脚找时钟网
set dcp [lindex $argv 0]
set tag [lindex $argv 1]
open_checkpoint $dcp
puts "### $tag"
foreach c [get_cells -quiet -hier -filter {NAME =~ "*rgmii_rx*" && LIB_CELL =~ "ISERDE*"}] {
    foreach p [get_pins -quiet -of_objects $c] {
        set n [get_nets -quiet -of_objects $p]
        if {![llength $n]} { continue }
        set nn [get_property NAME $n]
        if {[string match -nocase "*rxc*" $nn] || [string match -nocase "*clk*" $nn]} {
            set drv ""
            catch { set dv [lindex [get_cells -quiet -of_objects [get_pins -quiet -of_objects $n -filter {DIRECTION == OUT}]] 0]; set drv "[get_property NAME $dv]/[get_property LIB_CELL $dv]@[get_property LOC $dv]" }
            puts "DATA: [get_property NAME $p] -> $nn  (drv=$drv)"
        }
    }
}
foreach c [get_cells -quiet -hier -filter {NAME =~ "*rgmii_rx*" && LIB_CELL == IDELAYE3}] {
    set dv "?"; set vt "?"
    catch { set dv [get_property DELAY_VALUE $c] }
    catch { set vt [get_property EN_VTC $c] }
    puts "DATA: IDELAY [get_property NAME $c] DELAY=$dv VTC=$vt"
}
puts "###END"
close_design