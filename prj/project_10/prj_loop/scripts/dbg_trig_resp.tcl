# =============================================================================
# dbg_trig_resp.tcl v3 — 触发式捕获 resp_busy（正确的 wait API + 文件标志）
#   armed 后写 <out>/ARMED.flag; 结束写 <out>/RESULT.txt
# =============================================================================
set ltx {D:/FPGA/prj/project_10/prj_loop/scripts/probes.ltx}
set tag [lindex $argv 0]
set tmo 60
if {[llength $argv] > 1} { set tmo [lindex $argv 1] }
set out "D:/FPGA/prj/project_10/prj_loop/out/trig_$tag"
file mkdir $out
file delete -force $out/ARMED.flag $out/RESULT.txt

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
catch { set_property PROBES.FILE $ltx $dev }
catch { set_property FULL_PROBES.FILE $ltx $dev }
refresh_hw_device -update_hw_probes true $dev

set ila ""
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*cmd_respbsy*"}]] > 0} { set ila $cand }
}
if {$ila eq ""} { puts "TRIG_FAIL: no ila"; exit 1 }
set p [get_hw_probes -of_objects $ila -filter {NAME =~ "*cmd_respbsy*"}]
set_property TRIGGER_COMPARE_VALUE eq1'b1 $p
run_hw_ila $ila
set fh [open $out/ARMED.flag w]; puts $fh "armed"; close $fh
puts "TRIG_ARMED: [get_property NAME $ila]"
flush stdout

set rc [catch { wait_on_hw_ila -timeout $tmo $ila } emsg]
puts "TRIG_WAIT_RC: $rc"
puts "TRIG_WAIT_MSG: $emsg"

# 判别: 尝试上传, 若数据有效则视为已触发
set triggered 0
if {!$rc} {
    if {![catch { set d [upload_hw_ila_data $ila] } e2]} {
        if {![catch { write_hw_ila_data -force -csv_file $out/resp.csv $d } e3]} { set triggered 1 }
    }
}
set fh [open $out/RESULT.txt w]
if {$triggered} {
    puts $fh "TRIGGERED"
    puts "TRIG_RESULT: TRIGGERED (resp_busy 拉高过 -> 应答确实发出)"
} else {
    puts $fh "TIMEOUT"
    puts "TRIG_RESULT: TIMEOUT (${tmo}s 内 resp_busy 未拉高 -> 应答未发出)"
}
close $fh
puts "TRIG_DONE"