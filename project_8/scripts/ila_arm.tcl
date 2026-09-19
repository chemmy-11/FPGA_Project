# =============================================================================
# ila_arm.tcl — 给两个 ILA 装触发器并"武装"，等下一帧到来
#
# 关键事实：implement_debug_core 会把连到宽 probe0 上的各条网**拆成按信号名命名的
#   独立探针**（dbg_rx_tdata(64) / dbg_rx_tvalid(1) / dbg_up_frames(16) ...），
#   所以触发器可以直接装在某个信号上，不需要手工位切片或 X 掩码。
#
# 触发条件：
#   u_ila_0 @ user_clk : dbg_rx_tvalid = 1   （Aurora RX 来了数据拍 → 抓整帧）
#   u_ila_1 @ eth_rxc  : dbg_stack_txen = 1  （以太网栈开始发帧）
#
# 用法:
#   cd D:\FPGA\project_8
#   vivado -mode batch -source scripts\ila_arm.tcl -notrace
# 然后（网线接好、链路 up）：另开窗口 ping / python scripts\udp_verify.py
# 最后：vivado -mode batch -source scripts\ila_read_capture.tcl -notrace 导出 CSV 解码
# =============================================================================
set ltx {D:/FPGA/project_8/scripts/probes.ltx}

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
puts "DEVICE: [get_property NAME $dev]"

catch { set_property PROBES.FILE      $ltx $dev }
catch { set_property FULL_PROBES.FILE $ltx $dev }
refresh_hw_device -update_hw_probes true $dev

proc arm_one {ila sig} {
    set nm [get_property NAME $ila]
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    puts "--- $nm  cell=$cn  触发信号=$sig"

    set pr [get_hw_probes -of_objects $ila -filter "NAME =~ \"*$sig*\""]
    if {[llength $pr] == 0} { puts "    [!] 找不到探针 $sig"; return 0 }
    puts "    探针 = [get_property NAME $pr]  宽 = [get_property WIDTH $pr]"

    if {[catch { set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr } e]} {
        puts "    [!] 设触发失败: $e"; return 0
    }
    catch { set_property TRIGGER_POSITION 256 $ila }
    if {[catch { run_hw_ila $ila } e]} { puts "    [!] 武装失败: $e"; return 0 }
    puts "    已武装 ✓（等 $sig = 1 触发）"
    return 1
}

foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    if {$cn eq "u_ila_1"} {
        puts "== u_ila_1 (eth_rxc 域)"
        arm_one $ila "dbg_stack_txen"
    } else {
        puts "== u_ila_0 (user_clk 域)"
        arm_one $ila "dbg_rx_tvalid"
    }
}
puts "ARM_DONE"
