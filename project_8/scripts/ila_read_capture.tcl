# =============================================================================
# ila_read_capture.tcl — 导出板卡上 ILA 已抓到的数据为 CSV（再用 PowerShell 解码）
#
# 用法:
#   cd D:\FPGA\project_8
#   vivado -mode batch -source scripts\ila_read_capture.tcl -notrace
# 产物: scripts/ila_u0.csv（user_clk 域）、scripts/ila_u1.csv（eth_rxc 域）
# =============================================================================
set ltx {D:/FPGA/project_8/scripts/probes.ltx}
set out {D:/FPGA/project_8/scripts}

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
puts "DEVICE: [get_property NAME $dev] part=[get_property PART $dev]"

catch { set_property PROBES.FILE      $ltx $dev }
catch { set_property FULL_PROBES.FILE $ltx $dev }
refresh_hw_device -update_hw_probes true $dev

foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    set nm [get_property NAME $ila]
    puts "ILA $nm cell=$cn"

    set data [upload_hw_ila_data $ila]
    if {[llength $data] == 0} { puts "   (无数据)"; continue }

    if {$cn eq "u_ila_1"} { set f $out/ila_u1.csv } else { set f $out/ila_u0.csv }
    write_hw_ila_data -force -csv_file $f $data
    puts "   -> $f"
}
puts "READ_DONE"
