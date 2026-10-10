# =============================================================================
# build_b1_resume.tcl — prj11 B1: 位流续跑（DRC PDRC-203 处置后）
# 背景: B1 首次构建实现已全过(WNS +0.021/WHS +0.004, post_route.dcp 在库),
#       位流 DRC 拦 [PDRC-203]: uart_rxd(AE33) 落在 DDR4 校准字节组的
#       BITSLICE_1 —— 校准期间该输入不可用。
# 处置: 该条件可接受(MicroBlaze 由 POR 复位释放、自测在 calib_done 后才
#       运行, UART RX 在校准期间无输入需求), 按 DRC 提示显式确认;
#       同一属性已写入 XDC(后续全量构建天然过)。
# 用法: vivado -mode batch -source scripts\build_b1_resume.tcl -notrace
# =============================================================================
set proj D:/FPGA/prj/project_11

open_checkpoint $proj/scripts/post_route.dcp

set_property UNAVAILABLE_DURING_CALIBRATION TRUE [get_ports uart_rxd]
puts "PDRC203_ACK: uart_rxd unavailable during DDR4 calibration acknowledged"

write_bitstream -force $proj/out/aurora_mem_bridge.bit
write_hw_platform -fixed -include_bit -force $proj/out/mb_ctrl.xsa

puts "DBG_BUILD_DONE: bit=$proj/out/aurora_mem_bridge.bit ltx=$proj/scripts/probes.ltx xsa=$proj/out/mb_ctrl.xsa"
puts "W5_BUILD_OK"
