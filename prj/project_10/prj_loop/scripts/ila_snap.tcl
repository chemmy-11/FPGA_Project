# =============================================================================
# ila_snap.tcl — prj10 W4 J4 上板判据取证：四域 ILA 立即快照（一条命令）
#
# 用途（操作文档/阶段三_prj10_W4两级内存联调上板验证单_2026-10-07 第 6 步）:
#   板上跑完 ping / udp_verify_ddr / json_storm 之后, 抓当前计数器做双桥对账。
#   不依赖触发条件, 立即触发 (与 prj9 freeze_snap.tcl 同法)。
# 用法:
#   cd D:\FPGA\prj\project_10\prj_loop
#   vivado -mode batch -source scripts\ila_snap.tcl -notrace
# 产物:
#   out\j4_snap_<时间戳>\ila0..3.csv  (user / eth / user_b / ui 四域)
# 判读表见验证单第 6 步：mem_* 与 mem2_* 双桥各自闭合。
# =============================================================================
set ltx {D:/FPGA/prj/project_10/prj_loop/scripts/probes.ltx}
set ts  [clock format [clock seconds] -format {%Y%m%d_%H%M%S}]
set out "D:/FPGA/prj/project_10/prj_loop/out/j4_snap_$ts"
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
        after 600
        set d [upload_hw_ila_data $ila]
        write_hw_ila_data -force -csv_file $out/ila$i.csv $d
        puts "SNAP_OK ila$i ($nm)"
    } e]} { puts "SNAP_FAIL ila$i ($nm): $e" }
    incr i
}
puts "J4_SNAP_DONE: $out  (期望 4 个 ila*.csv; 判读: mem_*/mem2_* 双桥 wr=rd=wm 且错误计数全 0)"