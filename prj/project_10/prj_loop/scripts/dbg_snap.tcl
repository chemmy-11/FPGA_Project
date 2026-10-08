# =============================================================================
# dbg_snap.tcl — W5 命令通道上板定位：四域 ILA 立即快照（带 tag）
# 用法: vivado -mode batch -source scripts/dbg_snap.tcl -notrace -tclargs <tag>
# 产物: out/dbg_<tag>/ila0..3.csv
# 判读: 比对 <tag> 前后两次快照的计数器增量 —— 定位命令通道断在哪一级
# =============================================================================
set ltx {D:/FPGA/prj/project_10/prj_loop/scripts/probes.ltx}
if {[llength $argv] > 0} { set tag [lindex $argv 0] } else { set tag "snap" }
set out "D:/FPGA/prj/project_10/prj_loop/out/dbg_$tag"
file mkdir $out
puts "SNAP_DIR: $out"

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
catch { set_property PROBES.FILE $ltx $dev }
catch { set_property FULL_PROBES.FILE $ltx $dev }
refresh_hw_device -update_hw_probes true $dev

set i 0
foreach ila [get_hw_ilas -of_objects $dev] {
    set nm "?"
    catch { set nm [get_property NAME $ila] }
    if {[catch {
        run_hw_ila -trigger_now $ila
        after 800
        set d [upload_hw_ila_data $ila]
        write_hw_ila_data -force -csv_file $out/ila$i.csv $d
        puts "SNAP_OK ila$i ($nm)"
    } e]} { puts "SNAP_FAIL ila$i ($nm): $e" }
    incr i
}
puts "DBG_SNAP_DONE: $out"