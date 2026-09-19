# =============================================================================
# ila_capture_run.tcl — 单会话完成：武装 ILA → 自己打流量 → 抓取 → 导出 CSV
#
# 为什么必须在一个会话里做完：
#   Vivado 批量模式退出时会**解除 ILA 武装**（日志实录：
#   "The ILA core 'hw_ila_1' trigger was stopped by user" → "No data to upload"）。
#   所以"先 arm、另外打流量、再回来读"在 batch 下无效；本脚本用 exec 在
#   **同一个会话内**把 ping / UDP 判据脚本跑起来，触发后立刻回读。
#
# 触发条件：
#   u_ila_0 @ user_clk : dbg_rx_tvalid = 1    （Aurora RX 来数据 → 回程帧到了）
#   u_ila_1 @ eth_rxc  : dbg_stack_txen = 1   （以太网栈开始发帧 → 板卡在应答）
#
# 用法:
#   cd D:\FPGA\project_8
#   vivado -mode batch -source scripts\ila_capture_run.tcl -notrace
# 产物: scripts/ila_u0.csv（user_clk 域抓取）、scripts/ila_u1.csv（eth_rxc 域抓取）
# =============================================================================
set ltx {D:/FPGA/project_8/scripts/probes.ltx}
set out {D:/FPGA/project_8/scripts}

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
puts "DEVICE = [get_property NAME $dev]"
catch { set_property PROBES.FILE      $ltx $dev }
catch { set_property FULL_PROBES.FILE $ltx $dev }
refresh_hw_device -update_hw_probes true $dev

# ---------- 1) 武装 ----------
proc arm {ila sig} {
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    set pr [get_hw_probes -of_objects $ila -filter "NAME =~ \"*$sig*\""]
    if {[llength $pr] == 0} { puts "  ($cn) 找不到探针 $sig"; return 0 }
    catch { set_property TRIGGER_COMPARE_VALUE {eq1'b1} $pr }
    catch { set_property TRIGGER_POSITION 256 $ila }
    if {[catch { run_hw_ila $ila } e]} { puts "  ($cn) 武装失败: $e"; return 0 }
    puts "  ($cn) 已武装（等 $sig = 1）"
    return 1
}
puts "== 武装 =="
foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    if {$cn eq "u_ila_1"} {
        # eth_rxc 域：抓"网线上的帧有没有进 FPGA" → 触发于 gmii_rx_dv=1
        arm $ila "dbg_gmii_rx_dv"
    } else {
        # user_clk 域：抓"Aurora 有没有把帧送回来" → 触发于 rx_tvalid=1
        arm $ila "dbg_rx_tvalid"
    }
}

# ---------- 2) 本会话内打流量（exec 调 PowerShell/系统命令）----------
puts "== 打流量：ping（触发 ARP 应答）=="
if {[catch { exec cmd /c "ping -n 3 192.168.1.10" } e]} { puts "  ping 输出:\n$e" } else { puts "  ping ok" }

puts "== 打流量：UDP 判据脚本 =="
if {[catch { exec cmd /c "cd /d D:\\FPGA\\project_8 && python scripts\\udp_verify.py" } e]} {
    puts "  udp_verify 输出:\n$e"
} else { puts "  udp_verify ok" }

after 3000

# ---------- 3) 回读并导出 ----------
puts "== 回读 =="
foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    set nm [get_property NAME $ila]
    if {[catch { set data [upload_hw_ila_data $ila] } e]} {
        puts "  $nm ($cn): 上传失败: $e"; continue
    }
    if {[llength $data] == 0} { puts "  $nm ($cn): 没有数据（未触发）"; continue }
    if {$cn eq "u_ila_1"} { set f $out/ila_u1.csv } else { set f $out/ila_u0.csv }
    if {[catch { write_hw_ila_data -force -csv_file $f $data } e]} {
        puts "  $nm ($cn): 写 CSV 失败: $e"
    } else {
        puts "  $nm ($cn): -> $f"
    }
}
puts "CAPTURE_DONE"
