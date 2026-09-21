# =============================================================================
# build_debug.tcl — project_9: synth + 脚本化插入 ILA（双域）+ 实现 + 位流
#
# ILA0 @ Aurora user_clk（~151.5 MHz, GT 恢复钟）
#   probe0 宽 176，拼接顺序（先列 = 低位；若波形显示位序颠倒则说明映射为"先列=高位"）
#     [63:0]   rx_tdata
#     [71:64]  rx_tkeep
#     [72]     rx_tvalid
#     [73]     rx_tlast
#     [89:74]  unpack_frames
#     [105:90] unpack_bytes
#     [106]    unpack_ovf
#     [122:107] unpack_stall
#     [138:123] pack_frames
#     [139]    pack_ovf
#     [155:140] pump_rev_wr     ← user_clk 域（pump_rev 写侧）
#     [171:156] pump_rev_drop   ← user_clk 域
#     [172]    channel_up
#     [173]    lane_up
#     [174]    hard_err
#     [175]    soft_err
#     [191:176] pk_ovf_cnt    [207:192] pfwd_rd      [223:208] hard_err_cnt
#     [239:224] soft_err_cnt  [255:240] ch_up_evt    [271:256] pfwd_stuck_cnt  [272] pfwd_stuck
#
# ILA2 @ Aurora B 通道 user_clk_b（~151.5 MHz）
#   probe0 宽 101 (6x16 计数总线 + 5 单比特; 以 llength 自适应为准)
#     [15:0]   echo_b_rx       [31:16]  echo_b_tx      [47:32] echo_b_ovf_cnt
#     [63:48]  hard_err_b_cnt  [79:64]  soft_err_b_cnt [95:80] ch_up_b_evt
#     [96]     ch_up_b         [97]     lane_up_b      [98]    echo_b_ovf
#     [99]     b_rx_tvalid     [100]    b_tx_tvalid
#
# ILA1 @ eth_rxc / gmii_rx_clk（125 MHz, PHY）
#   probe0 宽 33
#     [15:0]  pump_fwd_wr    [31:16] pump_fwd_drop    [32] stack_tx_en
#   ⚠️ 严禁把 user_clk 域信号挂到本 ILA：未同步采样既违规又只能抓到亚稳态值。
#
# 用法（务必在 ASCII 工作目录）:
#   cd D:\FPGA\project_9
#   vivado -mode batch -source scripts\build_debug.tcl -notrace
# 产物: out/aurora_udp_bridge.bit + scripts/probes.ltx
# =============================================================================
set proj  D:/FPGA/project_9
file mkdir $proj/out

open_project $proj/prj/project_9.xpr
reset_run synth_1
launch_runs synth_1 -jobs 2
wait_on_run synth_1
puts "SYNTH_STATUS: [get_property STATUS [get_runs synth_1]]"
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "synth failed" }
open_run synth_1 -name synth_1

# 单比特网严格解析: 找不到立即报错(2026-09-21: 替代 lindex[get_nets] 的静默空值)
proc one_net {name} {
    set n [get_nets -quiet [list $name]]
    if {[llength $n] == 0} { error "net not found: $name" }
    return [lindex $n 0]
}

proc bus_nets {name width} {
    set nets {}
    for {set i 0} {$i < $width} {incr i} {
        set n [get_nets -quiet "${name}\[${i}\]"]
        if {[llength $n] == 0} { error "net not found: ${name}\[${i}\]" }
        lappend nets $n
    }
    return $nets
}

# ============ ILA0 @ Aurora user_clk, probe0 宽 144 ============
create_debug_core u_ila_0 ila
set_property C_DATA_DEPTH 2048 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
# user_clk 时钟网：优先按名取；若被改名则从打包模块寄存器的 C 引脚反查
set uclk_net [get_nets -quiet [list user_clk]]
if {[llength $uclk_net] == 0} {
    set uclk_net [get_nets -quiet -of_objects [get_pins -quiet {u_pack/frame_active_reg/C}]]
}
if {[llength $uclk_net] == 0} { error "user_clk net not found (nor via u_pack/frame_active_reg/C)" }
puts "ILA0_CLK_NET: $uclk_net"
connect_debug_port u_ila_0/clk $uclk_net

set nets0 {}
foreach n [bus_nets dbg_rx_tdata    64] { lappend nets0 $n }
foreach n [bus_nets dbg_rx_tkeep     8] { lappend nets0 $n }
lappend nets0 [lindex [get_nets [list dbg_rx_tvalid]] 0]
lappend nets0 [lindex [get_nets [list dbg_rx_tlast ]] 0]
foreach n [bus_nets dbg_up_frames   16] { lappend nets0 $n }
foreach n [bus_nets dbg_up_bytes    16] { lappend nets0 $n }
lappend nets0 [lindex [get_nets [list dbg_up_ovf  ]] 0]
foreach n [bus_nets dbg_up_stall    16] { lappend nets0 $n }
foreach n [bus_nets dbg_pk_frames   16] { lappend nets0 $n }
lappend nets0 [lindex [get_nets [list dbg_pk_ovf  ]] 0]
foreach n [bus_nets dbg_prev_wr     16] { lappend nets0 $n }
foreach n [bus_nets dbg_prev_drop   16] { lappend nets0 $n }
lappend nets0 [lindex [get_nets [list dbg_ch_up   ]] 0]
lappend nets0 [lindex [get_nets [list dbg_lane_up ]] 0]
lappend nets0 [lindex [get_nets [list dbg_hard_err]] 0]
lappend nets0 [lindex [get_nets [list dbg_soft_err]] 0]
# ---- prj9 判决计数器（2026-09-21）----
foreach n [bus_nets dbg_pk_ovf_cnt     16] { lappend nets0 $n }
foreach n [bus_nets dbg_pfwd_rd        16] { lappend nets0 $n }
foreach n [bus_nets dbg_hard_err_cnt   16] { lappend nets0 $n }
foreach n [bus_nets dbg_soft_err_cnt   16] { lappend nets0 $n }
foreach n [bus_nets dbg_ch_up_evt      16] { lappend nets0 $n }
foreach n [bus_nets dbg_pfwd_stuck_cnt 16] { lappend nets0 $n }
lappend nets0 [lindex [get_nets [list dbg_pfwd_stuck]] 0]
set_property port_width 273 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 $nets0

# ============ ILA1 @ eth_rxc (gmii_rx_clk), probe0 宽 33 ============
create_debug_core u_ila_1 ila
set_property C_DATA_DEPTH 2048 [get_debug_cores u_ila_1]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_1]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_1]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_1]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_1]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_1]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_1]
set_property port_width 1 [get_debug_ports u_ila_1/clk]
# eth_rxc 域时钟网反查：泵写侧寄存器的 C 引脚所挂网（综合后可能改名）
set wr_clk_net [get_nets -quiet -of_objects [get_pins -quiet {u_pump_fwd/wr_dv_d_reg/C}]]
if {[llength $wr_clk_net] == 0} {
    set wr_clk_net [get_nets -quiet [list gmii_rx_clk]]
}
if {[llength $wr_clk_net] == 0} { error "pump wr clock net not found (u_pump_fwd/wr_dv_d_reg/C)" }
puts "ILA1_CLK_NET: $wr_clk_net"
connect_debug_port u_ila_1/clk $wr_clk_net

set nets1 {}
foreach n [bus_nets dbg_pfwd_wr   16] { lappend nets1 $n }
foreach n [bus_nets dbg_pfwd_drop 16] { lappend nets1 $n }
lappend nets1 [lindex [get_nets [list dbg_stack_txen]] 0]
# ---- 接收侧（2026-09-10 加：定位"PC 发的包到底进没进 FPGA"）----
lappend nets1 [lindex [get_nets [list dbg_gmii_rx_dv   ]] 0]
foreach n [bus_nets dbg_gmii_rxd     8] { lappend nets1 $n }
lappend nets1 [lindex [get_nets [list dbg_arp_rx_done ]] 0]
lappend nets1 [lindex [get_nets [list dbg_arp_rx_type ]] 0]
lappend nets1 [lindex [get_nets [list dbg_udp_rec_done]] 0]
lappend nets1 [lindex [get_nets [list dbg_icmp_rec_done]] 0]
foreach n [bus_nets dbg_rec_byte_num 16] { lappend nets1 $n }
# ---- P8 回显目标端口 = 发送方源端口（2026-09-10 加）----
foreach n [bus_nets dbg_udp_src_port 16] { lappend nets1 $n }
set_property port_width 78 [get_debug_ports u_ila_1/probe0]
connect_debug_port u_ila_1/probe0 $nets1

# ============ ILA2 @ user_clk_b (B 通道), probe0 宽 85 ============
#   B 域信号严禁挂 ILA0(A 域)/ILA1(eth 域) —— 独立时钟域必须独立 ILA。
create_debug_core u_ila_2 ila
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_2]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_2]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_2]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_2]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_2]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_2]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_2]
set_property port_width 1 [get_debug_ports u_ila_2/clk]
set bclk_net [get_nets -quiet [list user_clk_b]]
if {[llength $bclk_net] == 0} {
    set bclk_net [get_nets -quiet -of_objects [get_pins -quiet {u_pack_b/frame_active_reg/C}]]
}
if {[llength $bclk_net] == 0} { error "user_clk_b net not found (nor via u_pack_b/frame_active_reg/C)" }
puts "ILA2_CLK_NET: $bclk_net"
connect_debug_port u_ila_2/clk $bclk_net

set nets2 {}
foreach n [bus_nets dbg_echo_b_rx      16] { lappend nets2 $n }
foreach n [bus_nets dbg_echo_b_tx      16] { lappend nets2 $n }
foreach n [bus_nets dbg_echo_b_ovf_cnt 16] { lappend nets2 $n }
foreach n [bus_nets dbg_hard_err_b_cnt 16] { lappend nets2 $n }
foreach n [bus_nets dbg_soft_err_b_cnt 16] { lappend nets2 $n }
foreach n [bus_nets dbg_ch_up_b_evt    16] { lappend nets2 $n }
lappend nets2 [lindex [get_nets [list dbg_ch_up_b    ]] 0]
lappend nets2 [lindex [get_nets [list dbg_lane_up_b  ]] 0]
lappend nets2 [one_net dbg_echo_b_ovf]
lappend nets2 [lindex [get_nets [list dbg_b_rx_tvalid]] 0]
lappend nets2 [lindex [get_nets [list dbg_b_tx_tvalid]] 0]
# 位宽按实际收集到的网数自适应(综合优化可能合并个别网, 硬编码会 12-700 拒连)
set_property port_width [llength $nets2] [get_debug_ports u_ila_2/probe0]
connect_debug_port u_ila_2/probe0 $nets2

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
phys_opt_design
route_design
phys_opt_design

# ---- 时序取证（产物落盘，便于离线定位失败路径）----
report_clocks            -file $proj/out/rpt_clocks.rpt
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
                         -max_paths 10 -file $proj/out/rpt_timing_summary.rpt
report_timing -max_paths 25 -sort_by slack -file $proj/out/rpt_timing_worst.rpt
puts "TIMING: [get_property SLACK [get_timing_paths -max_paths 1 -sort_by slack]]"

# ---- 保存布线后检查点（位流出问题时免重跑实现）----
write_checkpoint -force $proj/scripts/post_route.dcp
write_bitstream -force $proj/out/aurora_udp_bridge.bit

puts "DBG_BUILD_DONE: bit=$proj/out/aurora_udp_bridge.bit ltx=$proj/scripts/probes.ltx"