# =============================================================================
# build_debug.tcl — project_7: synth + 脚本化插入 ILA（单宽探针方案）+ 实现 + 位流
# ILA0 @ userclk2 : probe0[57:0] = {pump_rd[57:42], status_r[41:26], done[25],
#                                    en[24], rx2_num[23:8], rx2_data[7:0]}
# ILA1 @ eth_rxc  : probe0[31:0] = {pump_drop[31:16], pump_wr[15:0]}
# 用法: 关闭 GUI 中的本工程 -> vivado -mode batch -source build_debug.tcl -notrace
# 产物: out/sfp_udp_inner_loop.bit + scripts/probes.ltx
# =============================================================================
set proj  D:/FPGA/project_7

open_project $proj/prj/project_7.xpr
# synth checkpoint 已是当前 RTL（config scanner 版），直接复用
open_run synth_1 -name synth_1

proc bus_nets {name width} {
    set nets {}
    for {set i 0} {$i < $width} {incr i} {
        set n [get_nets -quiet "${name}\[${i}\]"]
        if {[llength $n] == 0} { error "net not found: ${name}\[${i}\]" }
        lappend nets $n
    }
    return $nets
}

# ============ ILA0 @ userclk2 (PCS 观测域), probe0 宽 58 ============
create_debug_core u_ila_0 ila
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets [list userclk2]]

set nets0 {}
foreach n [bus_nets dbg_rx2_data 8] { lappend nets0 $n }
foreach n [bus_nets dbg_rx2_num 16] { lappend nets0 $n }
lappend nets0 [lindex [get_nets [list dbg_rx2_en]] 0]
lappend nets0 [lindex [get_nets [list dbg_rx2_done]] 0]
foreach n [bus_nets dbg_status_r 16] { lappend nets0 $n }
foreach n [bus_nets dbg_pump_rd 16] { lappend nets0 $n }
set_property port_width 58 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 $nets0

# ============ ILA1 @ eth_rxc (泵写侧观测域), probe0 宽 32 ============
create_debug_core u_ila_1 ila
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_1]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_1]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_1]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_1]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_1]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_1]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_1]
set_property port_width 1 [get_debug_ports u_ila_1/clk]
# eth_rxc 域时钟网自动反查：泵写侧寄存器的 C 引脚所挂网（综合后可能改名）
set wr_clk_net [get_nets -quiet -of_objects [get_pins -quiet {u_pump/wr_dv_d_reg/C}]]
if {[llength $wr_clk_net] == 0} { error "pump wr clock net not found (u_pump/wr_dv_d_reg/C)" }
puts "ILA1_CLK_NET: $wr_clk_net"
connect_debug_port u_ila_1/clk $wr_clk_net

set nets1 {}
foreach n [bus_nets dbg_pump_wr 16] { lappend nets1 $n }
foreach n [bus_nets dbg_pump_drop 16] { lappend nets1 $n }
set_property port_width 32 [get_debug_ports u_ila_1/probe0]
connect_debug_port u_ila_1/probe0 $nets1

# implement_debug_core 要求先保存设计 → 检查点保存/重开（论坛标准解法）
write_checkpoint -force $proj/scripts/pre_impl_debug.dcp
close_design
open_checkpoint $proj/scripts/pre_impl_debug.dcp
if {[llength [get_debug_cores -quiet]] == 0} { error "debug cores lost after checkpoint reopen" }
implement_debug_core
write_debug_probes -force $proj/scripts/probes.ltx

# ============ 同会话手动实现（调试核已入网表）============
opt_design
place_design
route_design
write_bitstream -force $proj/out/sfp_udp_inner_loop.bit

puts "DBG_BUILD_DONE: bit=$proj/out/sfp_udp_inner_loop.bit ltx=$proj/scripts/probes.ltx"
