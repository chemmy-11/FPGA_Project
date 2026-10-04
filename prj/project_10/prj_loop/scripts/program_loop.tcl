# =============================================================================
# program_loop.tcl — 烧录「光链路 + 内存桥」集成位流 + 体检（一条命令）
#
# 为什么用脚本烧：JTAG 烧录是**易失**的（掉电即失），每次上电都要重烧；
#   脚本同时指定 .ltx 探针文件，避免手动点错（本设计有 4 个调试核）。
#
# 用法（ASCII 工作目录）:
#   cd D:\FPGA\prj\project_10\prj_loop
#   vivado -mode batch -source scripts\program_loop.tcl -notrace
#
# 判据（看板子）:
#   T23 亮 = 光链路已建立（channel_up）
#   T22 亮 = 内存校准完成（本版含义已改为校准指示）
# =============================================================================
set bit {D:/FPGA/prj/project_10/prj_loop/out/aurora_mem_bridge.bit}
set ltx {D:/FPGA/prj/project_10/prj_loop/scripts/probes.ltx}

foreach f [list $bit $ltx] {
    if {![file exists $f]} { puts "MISSING_FILE: $f"; exit 1 }
}

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

# 等 Aurora 通道初始化 + PHY 自协商 + MIG 上电校准
after 10000
catch { refresh_hw_device -update_hw_probes true $dev }

puts "=============================================="
set ilas [get_hw_ilas -of_objects $dev]
puts "调试核数量 = [llength $ilas]  （期望 4：user / eth / user_b / ui 四域）"
foreach ila $ilas {
    set nm [get_property NAME $ila]
    set cn "?"
    catch { set cn [get_property CELL_NAME $ila] }
    if {[catch { run_hw_ila $ila } e]} {
        if {[string match "*clock has stopped*" $e]} {
            puts "  $nm ($cn): 时钟停了"
        } else {
            puts "  $nm ($cn): 武装失败: $e"
        }
    } else {
        puts "  $nm ($cn): 时钟在跑"
        catch { reset_hw_ila $ila }
    }
}
puts "PROGRAM_CHECK_DONE"
puts "下一步：看 T23（链路）与 T22（内存校准）；然后 ping + udp_verify。"
