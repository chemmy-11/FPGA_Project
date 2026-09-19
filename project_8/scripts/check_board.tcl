# =============================================================================
# check_board.tcl — 板卡体检（只读 + 临时武装再解除）
#
# 一次回答三个问题：
#   1) 板子里跑的是不是 project_8 的设计？（看有没有 u_ila_0 / u_ila_1 两个调试核）
#   2) user_clk（GT/MMCM，与网线无关）是否在跑？ → Aurora 侧是否活着
#   3) eth_rxc（PHY 提供的 125M）是否在跑？ → **等价于"PHY 链路是否建立"**
#      （RGMII 的 RX 时钟由 PHY 输出，没链路就没时钟 → 这一条比看 PC 图标更硬）
#
# 用法:
#   cd D:\FPGA\project_8
#   vivado -mode batch -source scripts\check_board.tcl -notrace
# =============================================================================
set ltx {D:/FPGA/project_8/scripts/probes.ltx}

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
puts "=============================================="
puts "DEVICE = [get_property NAME $dev]"

catch { set_property PROBES.FILE      $ltx $dev }
catch { set_property FULL_PROBES.FILE $ltx $dev }
catch { refresh_hw_device -update_hw_probes true $dev }

set ilas [get_hw_ilas -of_objects $dev]
puts "调试核数量 = [llength $ilas]"
if {[llength $ilas] == 0} {
    puts ">>> 判定：板子里不是 project_8 的设计（没有 ILA）"
    puts ">>> 处置：Hardware Manager → Program Device → 选 out\\aurora_udp_bridge.bit"
    puts "CHECK_DONE"
    return
}

foreach ila $ilas {
    set nm [get_property NAME $ila]
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    set dom "user_clk(Aurora/GT)"
    if {$cn eq "u_ila_1"} { set dom "eth_rxc(PHY 125M)" }
    if {[catch { run_hw_ila $ila } e]} {
        if {[string match "*clock has stopped*" $e]} {
            puts "  $nm ($cn, $dom): ❌ 时钟停了"
            if {$cn eq "u_ila_1"} {
                puts "      → PHY 没有建立链路（网线/端口/PHY 复位）"
            } else {
                puts "      → GT/MMCM 没在跑（设计被换掉或未配置）"
            }
        } else {
            puts "  $nm ($cn, $dom): 武装失败 $e"
        }
    } else {
        puts "  $nm ($cn, $dom): ✅ 时钟在跑（可武装）"
        if {$cn eq "u_ila_1"} { puts "      → **PHY 链路已建立**" }
        catch { reset_hw_ila $ila }   ;# 解除武装，保持干净
    }
}
puts "CHECK_DONE"
