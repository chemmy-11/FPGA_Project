# cmp3.tcl - IDDRE1 时钟来源 + IDELAY 值（全 catch）
set dcp [lindex $argv 0]
set tag [lindex $argv 1]
open_checkpoint $dcp
puts "### $tag"
foreach c [get_cells -quiet -hier -filter {NAME =~ "*rgmii_rx*" && IS_PRIMITIVE}] {
    set lib [get_property LIB_CELL $c]
    if {[string match "ISERDE*" $lib]} {
        set cp [get_pins -quiet -of_objects $c -filter {REF_PIN_CODE == C}]
        set cn [get_nets -quiet -of_objects $cp]
        set drv ""
        set drvloc ""
        catch { set drv [get_property NAME [lindex [get_cells -quiet -of_objects [get_pins -quiet -of_objects $cn -filter {DIRECTION == OUT}]] 0]] }
        catch { set drvloc [get_property LOC [lindex [get_cells -quiet -of_objects [get_pins -quiet -of_objects $cn -filter {DIRECTION == OUT}]] 0]] }
        set drvlib ""
        catch { set drvlib [get_property LIB_CELL [lindex [get_cells -quiet -of_objects [get_pins -quiet -of_objects $cn -filter {DIRECTION == OUT}]] 0]] }
        puts "#ISERDES [get_property NAME $c] CNET=[get_property NAME $cn] DRV=$drv($drvlib)@$drvloc"
    }
    if {$lib eq "IDELAYE3"} {
        set dv "?"; set vt "?"; set dt "?"
        catch { set dv [get_property DELAY_VALUE $c] }
        catch { set vt [get_property EN_VTC $c] }
        catch { set dt [get_property DELAY_TYPE $c] }
        puts "#IDELAY [get_property NAME $c] DELAY=$dv VTC=$vt TYPE=$dt"
    }
}
puts "###END"
close_design