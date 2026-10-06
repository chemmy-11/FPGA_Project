# 冻结态立即快照：不依赖触发条件，抓当前计数器
set ltx {D:/FPGA/prj/project_9/scripts/probes.ltx}
set out {D:/FPGA/prj/project_9/out/freeze_20261006}
file mkdir $out
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
        after 600
        set d [upload_hw_ila_data $ila]
        write_hw_ila_data -force -csv_file $out/freeze_ila$i.csv $d
        puts "SNAP_OK ila$i ($nm)"
    } e]} { puts "SNAP_FAIL ila$i ($nm): $e" }
    incr i
}
puts FREEZE_SNAP_DONE
