# =============================================================================
# ila_capture.tcl — 自动化 ILA 抓取：触发 dbg_rx2_done 上升沿 → 导出 CSV
# 用法（板已烧调试位流 + 加载 probes.ltx 后）:
#   vivado -mode batch -source ila_capture.tcl -notrace
# 建议在 ASCII 工作目录运行（cd D:\FPGA\project_7）
# 流程: 连 hw_server → 找含 dbg_rx2_done 的 ILA → 设触发 → 等待捕获(60s 超时)
#       → 导出 out/ila0.csv
# 捕获期间请在另一终端跑: python scripts\udp_send.py 3
# =============================================================================
set timeout_s 60
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set ila0 ""
foreach ila [get_hw_ilas -quiet] {
    if {[llength [get_hw_probes -quiet dbg_rx2_done -of_objects $ila]] > 0} { set ila0 $ila }
}
if {$ila0 eq ""} { error "未找到含 dbg_rx2_done 探针的 ILA——确认烧的是 out 目录的新位流且已加载 probes.ltx" }
puts "ILA0: $ila0"

set p_done [get_hw_probes dbg_rx2_done -of_objects $ila0]
set p_en   [get_hw_probes dbg_rx2_en   -of_objects $ila0]
set p_data [get_hw_probes dbg_rx2_data -of_objects $ila0]
set p_num  [get_hw_probes dbg_rx2_num  -of_objects $ila0]
set p_stat [get_hw_probes dbg_status_r -of_objects $ila0]
set p_prd  [get_hw_probes dbg_pump_rd  -of_objects $ila0]

set_property CONTROL.TRIGGER_MODE BASIC $ila0
set_property CONTROL.CAPTURE_MODE ALWAYS $ila0
set_property CONTROL.TRIGGER_POSITION 512 $ila0
set_property TRIGGER_COMPARE eq $p_done
set_property TRIGGER_VALUE 1'b1 $p_done

puts "ILA 已布防（等待 dbg_rx2_done 上升沿，${timeout_s}s 超时）——请现在发送 UDP 包"
run_hw_ila $ila0
set t0 [clock seconds]
while {[string first "CAPTURED" [get_property STATUS [get_hw_ilas $ila0]]] < 0} {
    if {[clock seconds] - $t0 > $timeout_s} { error "ILA 捕获超时——UDP 发送了但没有触发" }
    after 500
}
upload_hw_ila_data $ila0
write_hw_ila_data -csv_file D:/FPGA/project_7/out/ila0.csv [current_hw_ila_data]
puts "=== 捕获完成 ==="
puts "dbg_rx2_done 当前值: [get_property VALUE $p_done]"
puts "dbg_rx2_num  当前值: [get_property VALUE $p_num]"
puts "dbg_status_r 当前值: [get_property VALUE $p_stat]"
puts "dbg_pump_rd  当前值: [get_property VALUE $p_prd]"
puts "CSV: D:/FPGA/project_7/out/ila0.csv"
puts "ILA_CAPTURE_DONE"
