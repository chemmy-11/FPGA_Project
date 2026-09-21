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
set pr [get_hw_probes -of_objects $ila1 -filter {NAME =~ "*stack_txen*"}]
set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr
run_hw_ila $ila1
catch { exec cmd /c "ping -n 1 -w 800 192.168.1.10" }
after 1500
set d1 [upload_hw_ila_data $ila1]
write_hw_ila_data -force -csv_file $out/ila_cnt1.csv $d1
set ila0 [lindex [get_hw_ilas -of_objects $dev] 0]
set pr0 [get_hw_probes -of_objects $ila0 -filter {NAME =~ "*ch_up*"}]
set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr0
run_hw_ila $ila0
after 2000
set d0 [upload_hw_ila_data $ila0]
write_hw_ila_data -force -csv_file $out/ila_cnt0.csv $d0
puts CNT_SNAP_DONE
