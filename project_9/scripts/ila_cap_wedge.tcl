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
# ---- 阶段1: 栈侧窗口（ping 期间）----
set ila1 [lindex [get_hw_ilas -of_objects $dev -filter {CELL_NAME == u_ila_1}] 0]
if {[llength $ila1] == 0} { set ila1 [lindex [get_hw_ilas -of_objects $dev] 1] }
set pr [get_hw_probes -of_objects $ila1 -filter {NAME =~ "*stack_txen*"}]
set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr
run_hw_ila $ila1
puts "PHASE1: ILA1 armed on stack_txen"
catch { exec cmd /c "ping -n 5 -w 1200 192.168.1.10" } pout
puts "PHASE1: ping done"
after 2000
set d1 [upload_hw_ila_data $ila1]
write_hw_ila_data -force -csv_file $out/ila_wedge_phase1.csv $d1
puts "PHASE1: SAVED"
# ---- 阶段2: Aurora 侧快照（ping 之后, 触发于 ch_up——立刻采到计数器现值）----
set ila0 [lindex [get_hw_ilas -of_objects $dev -filter {CELL_NAME == u_ila_0}] 0]
if {[llength $ila0] == 0} { set ila0 [lindex [get_hw_ilas -of_objects $dev] 0] }
set pr0 [get_hw_probes -of_objects $ila0 -filter {NAME =~ "*ch_up*"}]
if {[llength $pr0] == 0} {
    set pr0 [get_hw_probes -of_objects $ila0 -filter {NAME =~ "*rx_tvalid*"}]
}
set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr0
run_hw_ila $ila0
puts "PHASE2: ILA0 armed"
after 3000
set d0 [upload_hw_ila_data $ila0]
write_hw_ila_data -force -csv_file $out/ila_wedge_phase2.csv $d0
puts "PHASE2: SAVED"
puts "WEDGE_CAP2_DONE"
