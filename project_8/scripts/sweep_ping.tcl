# sweep_ping.tcl - 武装 ILA1 等 arp_rx_done, 期间持续 ping; 命中即记下当时的 dly_tap
set ltx {D:/FPGA/project_8/scripts/probes.ltx}
set out {D:/FPGA/project_8/scripts}
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
catch { set_property PROBES.FILE      $ltx $dev }
catch { set_property FULL_PROBES.FILE $ltx $dev }
refresh_hw_device -update_hw_probes true $dev

foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"; catch { set cn [get_property CELL_NAME $ila] }
    if {$cn eq "u_ila_1"} {
        set pr [get_hw_probes -of_objects $ila -filter "NAME =~ \"*dbg_arp_rx_done*\""]
        if {[llength $pr] == 0} { puts "NO PROBE"; continue }
        catch { set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr }
        catch { set_property TRIGGER_POSITION 1024 $ila }
        if {[catch { run_hw_ila $ila } e]} { puts "ARM FAIL: $e" } else { puts "ARMED on dbg_arp_rx_done (等一次成功解析)" }
    }
}

set okcnt 0
for {set i 0} {$i < 400} {incr i} {
    set ok 0
    if {[catch { exec cmd /c "ping -n 1 -w 300 192.168.1.10" } e]} { } else { if {[string match "*TTL=*" $e]} { set ok 1 } }
    if {$ok} { incr okcnt; puts "PING OK   iter=$i  ok=$okcnt" }
    after 800
}
puts "ping loop done, ok=$okcnt"

foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"; catch { set cn [get_property CELL_NAME $ila] }
    if {$cn ne "u_ila_1"} { continue }
    if {[catch { set data [upload_hw_ila_data $ila] } e]} { puts "UPLOAD FAIL: $e"; continue }
    if {[llength $data] == 0} { puts "NOT TRIGGERED -> arp_rx_done 从未为 1" } else {
        write_hw_ila_data -force -csv_file $out/cap_sweep.csv $data
        puts "TRIGGERED -> cap_sweep.csv  (看 dbg_dly_tap 列 = 成功时的 tap)"
    }
}
puts "SWEEP_DONE"
