# =============================================================================
# ila_capture_rx.tcl - 一次性: 武装 ILA -> 打流量 -> 导出 CSV (2026-09-10)
#   ILA0 @ user_clk : dbg_rx_tvalid      (Aurora 有没有把帧送回来)
#   ILA1 @ eth_rxc  : dbg_gmii_rx_dv     (PC 的包有没有进 FPGA)
# 必须在同一 batch 会话内完成: 退出 batch 会解除武装 -> No data to upload
# =============================================================================
set ltx {D:/FPGA/project_8/scripts/probes.ltx}
set out {D:/FPGA/project_8/scripts}
set py  {C:\\Users\\15266\\AppData\\Local\\Python\\pythoncore-3.14-64\\python.exe}

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
    catch { set_property TRIGGER_POSITION 256 $ila }
    if {[catch { run_hw_ila $ila } e]} { puts "  $nm ($cn): ARM FAIL: $e"; return 0 }
    puts "  $nm ($cn): ARMED on $sig"
    return 1
}
puts "== ARM =="
foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    if {$cn eq "u_ila_1"} { arm_one $ila "dbg_gmii_rx_dv" } else { arm_one $ila "dbg_rx_tvalid" }
}

puts "== TRAFFIC: ping =="
if {[catch { exec cmd /c "ping -n 4 192.168.1.10" } e]} { puts "  $e" } else { puts "  ping ok" }
puts "== TRAFFIC: udp_verify =="
if {[catch { exec cmd /c "cd /d D:\\FPGA\\project_8 && \"$py\" scripts\\udp_verify.py" } e]} { puts "  $e" } else { puts "  udp ok" }
after 3000

puts "== UPLOAD =="
foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    set nm [get_property NAME $ila]
    if {[catch { set data [upload_hw_ila_data $ila] } e]} { puts "  $nm ($cn): UPLOAD FAIL: $e"; continue }
    if {[llength $data] == 0} { puts "  $nm ($cn): NO DATA (not triggered)"; continue }
    if {$cn eq "u_ila_1"} { set f $out/ila_rx_u1.csv } else { set f $out/ila_rx_u0.csv }
    if {[catch { write_hw_ila_data -force -csv_file $f $data } e]} { puts "  $nm ($cn): CSV FAIL: $e" } else { puts "  $nm ($cn): -> $f" }
}
puts "CAPTURE_RX_DONE"
