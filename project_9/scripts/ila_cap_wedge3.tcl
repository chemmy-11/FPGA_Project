set ltx {D:/FPGA/project_9/scripts/probes.ltx}
set out {D:/FPGA/project_9/scripts}
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
catch { set_property PROBES.FILE $ltx $dev }
catch { set_property FULL_PROBES.FILE $ltx $dev }
refresh_hw_device -update_hw_probes true $dev
set ila1 [lindex [get_hw_ilas -of_objects $dev] 1]
set pr [get_hw_probes -of_objects $ila1 -filter {NAME =~ "*gmii_rx_dv*"}]
set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr
run_hw_ila $ila1
puts "PHASE3: ILA1 armed on gmii_rx_dv"
catch { exec cmd /c "ping -n 4 -w 1200 192.168.1.10" } pout
after 2500
set d [upload_hw_ila_data $ila1]
write_hw_ila_data -force -csv_file $out/ila_wedge_phase3.csv $d
puts "PHASE3: SAVED"
puts "WEDGE_CAP3_DONE"
