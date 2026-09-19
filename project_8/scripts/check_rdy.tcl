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
  if {$cn ne "u_ila_1"} { continue }
  set pr [get_hw_probes -of_objects $ila -filter "NAME =~ \"*dbg_idelay_rdy*\""]
  puts "probe: $pr"
  catch { set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr }
  catch { set_property TRIGGER_POSITION 1024 $ila }
  if {[catch { run_hw_ila $ila } e]} { puts "ARM FAIL: $e" } else { puts "ARMED on dbg_idelay_rdy" }
}
after 3000
foreach ila [get_hw_ilas -of_objects $dev] {
  set cn "?"; catch { set cn [get_property CELL_NAME $ila] }
  if {$cn ne "u_ila_1"} { continue }
  if {[catch { set data [upload_hw_ila_data $ila] } e]} { puts "UPLOAD FAIL: $e"; continue }
  if {[llength $data] == 0} { puts "NO DATA (idelay_rdy never 1)" } else {
    write_hw_ila_data -force -csv_file $out/cap_rdy.csv $data
    puts "-> cap_rdy.csv (IDELAYCTRL READY)"
  }
}
puts "RDYCHK_DONE"
