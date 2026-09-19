# cap100.tcl - 100M 下抓 RX 字节质量
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
proc arm_one {ila sig} {
    set pr [get_hw_probes -of_objects $ila -filter "NAME =~ \"*$sig*\""]
    if {[llength $pr] == 0} { return 0 }
    catch { set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr }
    catch { set_property TRIGGER_POSITION 512 $ila }
    if {[catch { run_hw_ila $ila } e]} { puts "ARM FAIL: $e"; return 0 }
    puts "ARMED $sig"
    return 1
}
foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"; catch { set cn [get_property CELL_NAME $ila] }
    if {$cn eq "u_ila_1"} { arm_one $ila "dbg_gmii_rx_dv" } else { arm_one $ila "dbg_arp_rx_done" }
}
puts "== ping =="
catch { exec cmd /c "ping -n 5 192.168.1.10" } e
puts $e
puts "== udp =="
catch { exec cmd /c "powershell -NoProfile -ExecutionPolicy Bypass -File D:\\\\FPGA\\\\project_8\\\\scripts\\\\traffic.ps1" } e2
puts $e2
after 2000
foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"; catch { set cn [get_property CELL_NAME $ila] }
    set nm [get_property NAME $ila]
    if {[catch { set data [upload_hw_ila_data $ila] } e]} { puts "  $nm ($cn): UPLOAD FAIL: $e"; continue }
    if {[llength $data] == 0} { puts "  $nm ($cn): NO DATA"; continue }
    if {$cn eq "u_ila_1"} { set f $out/cap100_u1.csv } else { set f $out/cap100_u0.csv }
    catch { write_hw_ila_data -force -csv_file $f $data }
    puts "  $nm ($cn): -> $f"
}
puts "CAP100_DONE"
