set ltx {D:/FPGA/project_8/scripts/probes.ltx}
set out {D:/FPGA/project_8/scripts}
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
catch { set_property PROBES.FILE $ltx $dev }
catch { set_property FULL_PROBES.FILE $ltx $dev }
refresh_hw_device -update_hw_probes true $dev
foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    set pr [get_hw_probes -of_objects $ila -filter {NAME =~ "*arp_rx_done*"}]
    set pr2 [get_hw_probes -of_objects $ila -filter {NAME =~ "*rx_tvalid*"}]
    if {$cn eq "u_ila_1" && [llength $pr]} {
        set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr
        run_hw_ila $ila
        puts "ILA1 ARMED on arp_rx_done"
    } elseif {$cn eq "u_ila_0" && [llength $pr2]} {
        set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr2
        run_hw_ila $ila
        puts "ILA0 ARMED on rx_tvalid"
    }
}
exec cmd /c "ping -n 10 -w 1500 192.168.1.10"
after 2000
foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    set data [upload_hw_ila_data $ila]
    if {[llength $data] == 0} { puts "$cn: NOT TRIGGERED"; continue }
    set f $out/ila_arp_[string range $cn 6 8].csv
    write_hw_ila_data -force -csv_file $f $data
    puts "$cn: SAVED $f"
}
puts "ARP_CAP_DONE"