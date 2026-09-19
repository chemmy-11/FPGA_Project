# =============================================================
# ila_capture_arp.tcl - arp_rx_done 触发 + ping/UDP 流量 + 导出
# =============================================================
set ltx {D:/FPGA/project_8/scripts/probes.ltx}
set out {D:/FPGA/project_8/scripts}

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
puts "DEVICE = [get_property NAME $dev]"
catch { set_property PROBES.FILE      $ltx $dev }
catch { set_property FULL_PROBES.FILE $ltx $dev }
refresh_hw_device -update_hw_probes true $dev

proc arm_one {ila sig} {
    set nm [get_property NAME $ila]
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    set pr [get_hw_probes -of_objects $ila -filter "NAME =~ \"*$sig*\""]
    if {[llength $pr] == 0} { puts "  $nm ($cn): NO PROBE $sig"; return 0 }
    catch { set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr }
    catch { set_property TRIGGER_POSITION 1024 $ila }
    if {[catch { run_hw_ila $ila } e]} { puts "  $nm ($cn): ARM FAIL: $e"; return 0 }
    puts "  $nm ($cn): ARMED on $sig"
    return 1
}
puts "== ARM =="
foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    if {$cn eq "u_ila_1"} { arm_one $ila "dbg_arp_rx_done" } else { arm_one $ila "dbg_rx_tvalid" }
}

puts "== TRAFFIC: ping -n 6 =="
catch { exec cmd /c "ping -n 6 192.168.1.10" } e
puts "  $e"

puts "== TRAFFIC: UDP 4 packets from ephemeral port =="
catch { exec cmd /c "powershell -NoProfile -ExecutionPolicy Bypass -File D:\\FPGA\\project_8\\scripts\\traffic.ps1" } e2
puts "  $e2"
after 2000

puts "== UPLOAD =="
foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    set nm [get_property NAME $ila]
    if {[catch { set data [upload_hw_ila_data $ila] } e]} { puts "  $nm ($cn): UPLOAD FAIL: $e"; continue }
    if {[llength $data] == 0} { puts "  $nm ($cn): NO DATA (not triggered)"; continue }
    if {$cn eq "u_ila_1"} { set f $out/ila_arp_u1.csv } else { set f $out/ila_arp_u0.csv }
    if {[catch { write_hw_ila_data -force -csv_file $f $data } e]} { puts "  $nm ($cn): CSV FAIL: $e" } else { puts "  $nm ($cn): -> $f" }
}
puts "CAPTURE_ARP_DONE"
