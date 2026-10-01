# =============================================================================
# eth_udp_inner_loop.xdc — project_7 (UDP stack + SFP inner-loop check)
# Pin sources: official 39_eth_udp_loop.xdc (GE1 RGMII, 表 43.5.1)
#            + official 53_sfp_eth_udp_loop.xdc (gtrefclk T6, SFPD control,
#              sys_clk AK17) — both official, merged for the hybrid design.
# =============================================================================

## ---- bitstream config (official 53) ----
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLNONE [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

## ---- clocks ----
# RGMII 125M (PHY)
create_clock -period 8.000 -name eth_rxc [get_ports eth_rxc]
# 100M board osc
create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]
# 156.25M GT refclk
create_clock -period 6.400 -name gtrefclk [get_ports gtrefclk_p]

## ---- system ----
set_property -dict {PACKAGE_PIN AC34 IOSTANDARD LVCMOS18} [get_ports sys_rst_n]
set_property -dict {PACKAGE_PIN AK17 IOSTANDARD DIFF_HSTL_I_12} [get_ports sys_clk_p]

## ---- GT refclk: MGTREFCLK1_226 (T6/T5) 156.25MHz (IBERT/Aurora 定版) ----
set_property PACKAGE_PIN T6 [get_ports gtrefclk_p]

## ---- SFPD control (VERSION A; official 53 binds channel D = X1Y8) ----
set_property -dict {PACKAGE_PIN G27 IOSTANDARD LVCMOS33} [get_ports sfp_rs0]
set_property -dict {PACKAGE_PIN H27 IOSTANDARD LVCMOS33} [get_ports sfp_rs1]
set_property -dict {PACKAGE_PIN H26 IOSTANDARD LVCMOS33} [get_ports sfp_tx_disable]

## ---- RGMII GE1 (YT8531 PHY, 表 43.5.1, all LVCMOS18) ----
set_property -dict {PACKAGE_PIN AC31 IOSTANDARD LVCMOS18} [get_ports eth_rxc]
set_property -dict {PACKAGE_PIN Y33 IOSTANDARD LVCMOS18} [get_ports eth_rx_ctl]
set_property -dict {PACKAGE_PIN W33 IOSTANDARD LVCMOS18} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN W34 IOSTANDARD LVCMOS18} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN V33 IOSTANDARD LVCMOS18} [get_ports {eth_rxd[2]}]
set_property -dict {PACKAGE_PIN AC32 IOSTANDARD LVCMOS18} [get_ports {eth_rxd[3]}]
set_property -dict {PACKAGE_PIN Y32 IOSTANDARD LVCMOS18} [get_ports eth_txc]
set_property -dict {PACKAGE_PIN AE32 IOSTANDARD LVCMOS18} [get_ports eth_tx_ctl]
set_property -dict {PACKAGE_PIN Y31 IOSTANDARD LVCMOS18} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN AF32 IOSTANDARD LVCMOS18} [get_ports {eth_txd[1]}]
set_property -dict {PACKAGE_PIN AF30 IOSTANDARD LVCMOS18} [get_ports {eth_txd[2]}]
set_property -dict {PACKAGE_PIN AG30 IOSTANDARD LVCMOS18} [get_ports {eth_txd[3]}]
set_property -dict {PACKAGE_PIN AA33 IOSTANDARD LVCMOS18} [get_ports eth_rst_n]

## ---- push button (official 39) ----
set_property -dict {PACKAGE_PIN Y30 IOSTANDARD LVCMOS18} [get_ports key]

## ---- observation LEDs (T22/T23, Aurora practice) ----
set_property -dict {PACKAGE_PIN T22 IOSTANDARD LVCMOS18} [get_ports led_loop]
set_property -dict {PACKAGE_PIN T23 IOSTANDARD LVCMOS18} [get_ports led_link]

create_debug_core u_ila_0 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets [list u_clk_wiz_sfp/inst/clk_out1]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe0]
set_property port_width 2 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {dbg_cfg_idx[0]} {dbg_cfg_idx[1]}]]
create_debug_core u_ila_1 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_1]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_1]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_1]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_1]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_1]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_1]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_1]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_1]
set_property port_width 1 [get_debug_ports u_ila_1/clk]
connect_debug_port u_ila_1/clk [get_nets [list u_gmii_to_rgmii/u_rgmii_rx/rgmii_txc]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe0]
set_property port_width 16 [get_debug_ports u_ila_1/probe0]
connect_debug_port u_ila_1/probe0 [get_nets [list {dbg_pump_drop[0]} {dbg_pump_drop[1]} {dbg_pump_drop[2]} {dbg_pump_drop[3]} {dbg_pump_drop[4]} {dbg_pump_drop[5]} {dbg_pump_drop[6]} {dbg_pump_drop[7]} {dbg_pump_drop[8]} {dbg_pump_drop[9]} {dbg_pump_drop[10]} {dbg_pump_drop[11]} {dbg_pump_drop[12]} {dbg_pump_drop[13]} {dbg_pump_drop[14]} {dbg_pump_drop[15]}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe1]
set_property port_width 16 [get_debug_ports u_ila_1/probe1]
connect_debug_port u_ila_1/probe1 [get_nets [list {dbg_pump_wr[0]} {dbg_pump_wr[1]} {dbg_pump_wr[2]} {dbg_pump_wr[3]} {dbg_pump_wr[4]} {dbg_pump_wr[5]} {dbg_pump_wr[6]} {dbg_pump_wr[7]} {dbg_pump_wr[8]} {dbg_pump_wr[9]} {dbg_pump_wr[10]} {dbg_pump_wr[11]} {dbg_pump_wr[12]} {dbg_pump_wr[13]} {dbg_pump_wr[14]} {dbg_pump_wr[15]}]]
create_debug_core u_ila_2 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_2]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_2]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_2]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_2]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_2]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_2]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_2]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_2]
set_property port_width 1 [get_debug_ports u_ila_2/clk]
connect_debug_port u_ila_2/clk [get_nets [list u_gig_ethernet_pcs_pma_0/inst/core_clocking_i/userclk2]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_2/probe0]
set_property port_width 16 [get_debug_ports u_ila_2/probe0]
connect_debug_port u_ila_2/probe0 [get_nets [list {dbg_status_r[0]} {dbg_status_r[1]} {dbg_status_r[2]} {dbg_status_r[3]} {dbg_status_r[4]} {dbg_status_r[5]} {dbg_status_r[6]} {dbg_status_r[7]} {dbg_status_r[8]} {dbg_status_r[9]} {dbg_status_r[10]} {dbg_status_r[11]} {dbg_status_r[12]} {dbg_status_r[13]} {dbg_status_r[14]} {dbg_status_r[15]}]]
create_debug_port u_ila_2 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_2/probe1]
set_property port_width 16 [get_debug_ports u_ila_2/probe1]
connect_debug_port u_ila_2/probe1 [get_nets [list {dbg_pump_rd[0]} {dbg_pump_rd[1]} {dbg_pump_rd[2]} {dbg_pump_rd[3]} {dbg_pump_rd[4]} {dbg_pump_rd[5]} {dbg_pump_rd[6]} {dbg_pump_rd[7]} {dbg_pump_rd[8]} {dbg_pump_rd[9]} {dbg_pump_rd[10]} {dbg_pump_rd[11]} {dbg_pump_rd[12]} {dbg_pump_rd[13]} {dbg_pump_rd[14]} {dbg_pump_rd[15]}]]
create_debug_port u_ila_2 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_2/probe2]
set_property port_width 16 [get_debug_ports u_ila_2/probe2]
connect_debug_port u_ila_2/probe2 [get_nets [list {dbg_rx2_num[0]} {dbg_rx2_num[1]} {dbg_rx2_num[2]} {dbg_rx2_num[3]} {dbg_rx2_num[4]} {dbg_rx2_num[5]} {dbg_rx2_num[6]} {dbg_rx2_num[7]} {dbg_rx2_num[8]} {dbg_rx2_num[9]} {dbg_rx2_num[10]} {dbg_rx2_num[11]} {dbg_rx2_num[12]} {dbg_rx2_num[13]} {dbg_rx2_num[14]} {dbg_rx2_num[15]}]]
create_debug_port u_ila_2 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_2/probe3]
set_property port_width 8 [get_debug_ports u_ila_2/probe3]
connect_debug_port u_ila_2/probe3 [get_nets [list {dbg_rx2_data[0]} {dbg_rx2_data[1]} {dbg_rx2_data[2]} {dbg_rx2_data[3]} {dbg_rx2_data[4]} {dbg_rx2_data[5]} {dbg_rx2_data[6]} {dbg_rx2_data[7]}]]
create_debug_port u_ila_2 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_2/probe4]
set_property port_width 1 [get_debug_ports u_ila_2/probe4]
connect_debug_port u_ila_2/probe4 [get_nets [list dbg_rx2_done]]
create_debug_port u_ila_2 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_2/probe5]
set_property port_width 1 [get_debug_ports u_ila_2/probe5]
connect_debug_port u_ila_2/probe5 [get_nets [list dbg_rx2_en]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets userclk2]
