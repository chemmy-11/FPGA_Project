# =============================================================================
# program_board.tcl — JTAG 烧录 project_8 位流 + 立即体检（一条命令搞定）
#
# 为什么用脚本烧：JTAG 烧录是**易失**的（掉电即失，板子会转去从 SPI Flash 加载
#   旧设计），所以每次断电/重新上电后都要重新烧一次，脚本比 GUI 点击更不容易出错。
#
# 体检三项：
#   1) 调试核数量（应为 2 → 说明跑的是 project_8 的设计）
#   2) user_clk（GT/MMCM，与网线无关）是否在跑
#   3) eth_rxc（PHY 的 125M RX 时钟）是否在跑 → **等价于 PHY 链路是否建立**
#
# 用法:
#   cd D:\FPGA\project_8
#   vivado -mode batch -source scripts\program_board.tcl -notrace
# =============================================================================
set bit  {D:/FPGA/project_8/out/aurora_udp_bridge.bit}
set ltx  {D:/FPGA/project_8/scripts/probes.ltx}

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
puts "DEVICE = [get_property NAME $dev]  part = [get_property PART $dev]"

set_property PROGRAM.FILE      $bit $dev
set_property PROBES.FILE       $ltx $dev
set_property FULL_PROBES.FILE  $ltx $dev
program_hw_devices $dev
puts "PROGRAM_OK: [get_property PROGRAM.FILE $dev]"

# 等 Aurora 通道初始化 + PHY 自协商（自协商通常 1~3 s）
after 6000
catch { refresh_hw_device -update_hw_probes true $dev }

puts "=============================================="
set ilas [get_hw_ilas -of_objects $dev]
puts "调试核数量 = [llength $ilas]  （期望 2 = 确实是 project_8 的设计）"

foreach ila $ilas {
    set nm [get_property NAME $ila]
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    set dom "user_clk(Aurora/GT)"
    if {$cn eq "u_ila_1"} { set dom "eth_rxc(PHY 125M)" }
    if {[catch { run_hw_ila $ila } e]} {
        if {[string match "*clock has stopped*" $e]} {
            puts "  $nm ($cn, $dom): 时钟停了"
            if {$cn eq "u_ila_1"} { puts "      => PHY 尚未建立链路（网线/端口/PHY 复位）" }
        } else {
            puts "  $nm ($cn, $dom): 武装失败: $e"
        }
    } else {
        puts "  $nm ($cn, $dom): 时钟在跑"
        if {$cn eq "u_ila_1"} { puts "      => **PHY 链路已建立（PC 侧应能看到 1Gbps 连接）**" }
        catch { reset_hw_ila $ila }
    }
}
puts "PROGRAM_CHECK_DONE"
