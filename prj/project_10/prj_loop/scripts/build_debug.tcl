# =============================================================================
# build_debug.tcl — prj10 prj_loop: synth + 脚本化插入 ILA（四域）+ 实现 + 位流
# 派生自 prj9 build_debug.tcl; 差异:
#   ILA0 追加 prj10 桥用户侧探针(mem_u_wr/rd/drop 16x3 + mem_rden + ost_sync 9)
#   ILA3 新增 @ ui_clk(MIG ~300MHz): calib + 桥 ui 域计数器(严禁挂 user/eth 域 ILA)
# 用法(ASCII 工作目录):
#   vivado -mode batch -source D:\FPGA\prj\project_10\prj_loop\scripts\build_debug.tcl -notrace
# 产物: out/aurora_mem_bridge.bit + scripts/probes.ltx
# =============================================================================
set proj  D:/FPGA/prj/project_10/prj_loop
file mkdir $proj/out

open_project $proj/vivado/prj_loop.xpr
# ---- ddr4_0 配置已改(System_Clock=No_Buffer): 强制重建其产物与 OOC run ----
# reset_run synth_1 不级联 IP run; 不重建则顶层读到旧差分 stub -> [Synth 8-11365]
reset_target  all [get_ips ddr4_0]
generate_target all [get_ips ddr4_0]
if {[llength [get_runs -quiet ddr4_0_synth_1]] > 0} { reset_run ddr4_0_synth_1 }
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
puts "SYNTH_STATUS: [get_property STATUS [get_runs synth_1]]"
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "synth failed" }
open_run synth_1 -name synth_1

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

# ============ ILA0 @ Aurora user_clk（prj9 判决链 + prj10 桥用户侧） ============
create_debug_core u_ila_0 ila
set_property C_DATA_DEPTH 2048 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
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
lappend nets0 [one_net dbg_rx_tvalid]
lappend nets0 [one_net dbg_rx_tlast ]
foreach n [bus_nets dbg_up_frames   16] { lappend nets0 $n }
foreach n [bus_nets dbg_up_bytes    16] { lappend nets0 $n }
lappend nets0 [one_net dbg_up_ovf  ]
foreach n [bus_nets dbg_up_stall    16] { lappend nets0 $n }
foreach n [bus_nets dbg_pk_frames   16] { lappend nets0 $n }
lappend nets0 [one_net dbg_pk_ovf  ]
foreach n [bus_nets dbg_prev_wr     16] { lappend nets0 $n }
foreach n [bus_nets dbg_prev_drop   16] { lappend nets0 $n }
lappend nets0 [one_net dbg_ch_up   ]
lappend nets0 [one_net dbg_lane_up ]
lappend nets0 [one_net dbg_hard_err]
lappend nets0 [one_net dbg_soft_err]
foreach n [bus_nets dbg_pk_ovf_cnt     16] { lappend nets0 $n }
foreach n [bus_nets dbg_pfwd_rd        16] { lappend nets0 $n }
foreach n [bus_nets dbg_hard_err_cnt   16] { lappend nets0 $n }
foreach n [bus_nets dbg_soft_err_cnt   16] { lappend nets0 $n }
foreach n [bus_nets dbg_ch_up_evt      16] { lappend nets0 $n }
foreach n [bus_nets dbg_pfwd_stuck_cnt 16] { lappend nets0 $n }
lappend nets0 [one_net dbg_pfwd_stuck]
# ---- prj10: 桥用户侧计数 + 读侧发射使能(帧连续性观测) ----
foreach n [bus_nets dbg_mem_u_wr   16] { lappend nets0 $n }
foreach n [bus_nets dbg_mem_u_rd   16] { lappend nets0 $n }
foreach n [bus_nets dbg_mem_u_drop 16] { lappend nets0 $n }
lappend nets0 [one_net dbg_mem_rden]
foreach n [bus_nets dbg_mem_ost_s   9] { lappend nets0 $n }
# ---- W4: 桥② user 域观测 ----
foreach n [bus_nets dbg_mem2_u_wr  16] { lappend nets0 $n }
foreach n [bus_nets dbg_mem2_u_rd  16] { lappend nets0 $n }
# ---- W5: 命令通道 user 域观测（模式/读槽号/执行数/触发数）----
lappend nets0 [one_net dbg_cmd_mode]
foreach n [bus_nets dbg_cmd_slot   8] { lappend nets0 $n }
foreach n [bus_nets dbg_cmd_exec  16] { lappend nets0 $n }
foreach n [bus_nets dbg_cmd_trig  16] { lappend nets0 $n }
set_property port_width [llength $nets0] [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 $nets0

# ============ ILA1 @ eth_rxc (gmii_rx_clk) —— prj9 原样 ============
create_debug_core u_ila_1 ila
set_property C_DATA_DEPTH 2048 [get_debug_cores u_ila_1]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_1]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_1]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_1]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_1]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_1]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_1]
set_property port_width 1 [get_debug_ports u_ila_1/clk]
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
lappend nets1 [one_net dbg_stack_txen]
lappend nets1 [one_net dbg_gmii_rx_dv   ]
foreach n [bus_nets dbg_gmii_rxd     8] { lappend nets1 $n }
lappend nets1 [one_net dbg_arp_rx_done ]
lappend nets1 [one_net dbg_arp_rx_type ]
lappend nets1 [one_net dbg_udp_rec_done]
lappend nets1 [one_net dbg_icmp_rec_done]
foreach n [bus_nets dbg_rec_byte_num 16] { lappend nets1 $n }
foreach n [bus_nets dbg_udp_src_port 16] { lappend nets1 $n }
# ---- W5: 命令通道 eth 域观测（收命令数/错帧数/响应占用）----
foreach n [bus_nets dbg_cmd_rx   16] { lappend nets1 $n }
foreach n [bus_nets dbg_cmd_err  16] { lappend nets1 $n }
lappend nets1 [one_net dbg_cmd_respbsy]
set_property port_width [llength $nets1] [get_debug_ports u_ila_1/probe0]
connect_debug_port u_ila_1/probe0 $nets1

# ============ ILA2 @ user_clk_b (B 通道) —— prj9 原样 ============
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
lappend nets2 [one_net dbg_ch_up_b    ]
lappend nets2 [one_net dbg_lane_up_b  ]
lappend nets2 [one_net dbg_echo_b_ovf ]
lappend nets2 [one_net dbg_b_rx_tvalid]
lappend nets2 [one_net dbg_b_tx_tvalid]
set_property port_width [llength $nets2] [get_debug_ports u_ila_2/probe0]
connect_debug_port u_ila_2/probe0 $nets2

# ============ ILA3 @ ui_clk (MIG ~300MHz) —— prj10 新增 ============
#   ui 域信号严禁挂 ILA0/1/2; 桥的 ui 侧计数器全部在此观测
create_debug_core u_ila_3 ila
set_property C_DATA_DEPTH 2048 [get_debug_cores u_ila_3]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_3]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_3]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_3]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_3]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_3]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_3]
set_property port_width 1 [get_debug_ports u_ila_3/clk]
set uiclk_net [get_nets -quiet [list ui_clk]]
if {[llength $uiclk_net] == 0} {
    set uiclk_net [get_nets -quiet -of_objects [get_pins -quiet {u_mem/u_bridge/wst_reg[0]/C}]]
}
if {[llength $uiclk_net] == 0} { error "ui_clk net not found (nor via u_mem/u_bridge/wst_reg[0]/C)" }
puts "ILA3_CLK_NET: $uiclk_net"
connect_debug_port u_ila_3/clk $uiclk_net

set nets3 {}
lappend nets3 [one_net dbg_calib      ]
foreach n [bus_nets dbg_mem_wm      16] { lappend nets3 $n }
foreach n [bus_nets dbg_mem_wr_frm  16] { lappend nets3 $n }
foreach n [bus_nets dbg_mem_rd_frm  16] { lappend nets3 $n }
foreach n [bus_nets dbg_mem_stall   16] { lappend nets3 $n }
foreach n [bus_nets dbg_mem_len_err 16] { lappend nets3 $n }
foreach n [bus_nets dbg_mem_bresp   16] { lappend nets3 $n }
foreach n [bus_nets dbg_mem_ost      9] { lappend nets3 $n }
foreach n [bus_nets dbg_mem_wslot    8] { lappend nets3 $n }
foreach n [bus_nets dbg_mem_rslot    8] { lappend nets3 $n }
# ---- W5: 非法读/无帧计数 + 读写突发数（J5 对账与可观测性）----
# ⚠️ 2026-10-07 实测: 这 96 bit 加在 300MHz 的 ILA3 上会把 ui 域推向拥塞
#    （WNS -0.041 → -1.142, 4040 端点失败, 平均缺口仅 0.27ns = 典型拥塞特征）。
#    RND 使能后 stat_ill_rd/full_bit 查表锥本就是零余量, 再加载即崩。
#    -> 暂不挂 ILA3, 保住 RND 时序（J5 的 ill_rd 证据改由 PC 侧空应答 + 桥语义文档 + 单元 TB/T5b 承担）
# foreach n [bus_nets dbg_mem_ill     16] { lappend nets3 $n }
# foreach n [bus_nets dbg_mem_nofrm   16] { lappend nets3 $n }
# foreach n [bus_nets dbg_mem_wbeats  32] { lappend nets3 $n }
# foreach n [bus_nets dbg_mem_rbeats  32] { lappend nets3 $n }
# ---- W4: 桥②(EGRESS) ui 域观测 ----
foreach n [bus_nets dbg_mem2_wm     16] { lappend nets3 $n }
foreach n [bus_nets dbg_mem2_wr_frm 16] { lappend nets3 $n }
foreach n [bus_nets dbg_mem2_rd_frm 16] { lappend nets3 $n }
foreach n [bus_nets dbg_mem2_ost     9] { lappend nets3 $n }
set_property port_width [llength $nets3] [get_debug_ports u_ila_3/probe0]
connect_debug_port u_ila_3/probe0 $nets3

write_checkpoint -force $proj/scripts/pre_impl_debug.dcp
close_design
open_checkpoint $proj/scripts/pre_impl_debug.dcp
if {[llength [get_debug_cores -quiet]] == 0} { error "debug cores lost after checkpoint reopen" }
implement_debug_core
write_debug_probes -force $proj/scripts/probes.ltx

# ============ 同会话手动实现（调试核已入网表）============
# W5(2026-10-07): 默认配方在 RND 活化后不收敛(-1.142), 换 W4 实测最优组合
opt_design
place_design       -directive ExtraTimingOpt
phys_opt_design    -directive AggressiveExplore
route_design       -directive NoTimingRelaxation
phys_opt_design    -directive AggressiveExplore

report_clocks            -file $proj/out/rpt_clocks.rpt
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
                         -max_paths 10 -file $proj/out/rpt_timing_summary.rpt
report_timing -max_paths 25 -sort_by slack -file $proj/out/rpt_timing_worst.rpt
puts "TIMING: [get_property SLACK [get_timing_paths -max_paths 1 -sort_by slack]]"

# W5(2026-10-07): WNS 门限 —— 不达标不写位流（W4 构建纪律: 未收敛位流不得上板）
set wns5 [get_property SLACK [get_timing_paths -max_paths 1 -sort_by slack]]
set whs5 [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -sort_by slack]]
puts "WNS_GATE: $wns5"
puts "WHS_GATE: $whs5"
if {$wns5 >= 0 && $whs5 >= 0} {
    write_checkpoint -force $proj/scripts/post_route.dcp
    write_debug_probes -force $proj/scripts/probes.ltx
    write_bitstream -force $proj/out/aurora_mem_bridge.bit
    puts "DBG_BUILD_DONE: bit=$proj/out/aurora_mem_bridge.bit ltx=$proj/scripts/probes.ltx"
    puts "W5_BUILD_OK"
} else {
    puts "W5_BUILD_TIMING_FAIL: wns=$wns5 whs=$whs5 (未写位流)"
}
