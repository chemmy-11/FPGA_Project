# =============================================================================
# program_mig.tcl — 烧录 DDR4 内存校准位流 + 顺带体检（一条命令）
#
# 为什么用脚本烧：JTAG 烧录是**易失**的（掉电即失，板子会转去从 SPI Flash 加载旧
#   设计），所以每次上电后都要重烧一次；脚本同时指定 .ltx 探针文件，避免手动点错。
#
# 用法（ASCII 工作目录）:
#   cd D:\FPGA\prj\project_4
#   vivado -mode batch -source scripts\program_mig.tcl -notrace
#
# 判据（看板子上的灯，脚本只负责烧对）:
#   T22 亮 = 校准完成（init_calib_complete）
#   T23 亮 = 256 拍写→读回自比对零错误
# =============================================================================
set bit {D:/FPGA/prj/project_4/mig_ddr4_cal.runs/impl_1/mig_verify_top.bit}
set ltx {D:/FPGA/prj/project_4/mig_ddr4_cal.runs/impl_1/mig_verify_top.ltx}

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

# 等 MIG 上电校准（DDR4-2400 校准通常 1~5 s，给足余量）
after 8000
catch { refresh_hw_device -update_hw_probes true $dev }

puts "=============================================="
set ilas [get_hw_ilas -of_objects $dev]
puts "调试核数量 = [llength $ilas]  （期望 1 = 内存校准设计的 ILA）"
foreach ila $ilas {
    set nm [get_property NAME $ila]
    if {[catch { run_hw_ila $ila } e]} {
        if {[string match "*clock has stopped*" $e]} {
            puts "  $nm: 时钟停了 => ui_clk 没起来（MIG 没跑起来），看 T22 是否亮"
        } else {
            puts "  $nm: 武装失败: $e"
        }
    } else {
        puts "  $nm: ui_clk 在跑（MIG 已上电工作）"
        catch { reset_hw_ila $ila }
    }
}
puts "PROGRAM_CHECK_DONE"
puts "下一步：看 T22 / T23 两盏灯；无论结果请拍照留档。"
