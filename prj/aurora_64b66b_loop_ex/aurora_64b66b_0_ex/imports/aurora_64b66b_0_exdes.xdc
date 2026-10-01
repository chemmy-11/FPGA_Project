##################################################################################
##
## Project:  Aurora 64B/66B
## Company:  Xilinx
##
##
##
## (c) Copyright 2008 - 2018 Xilinx, Inc. All rights reserved.
##
## This file contains confidential and proprietary information
## of Xilinx, Inc. and is protected under U.S. and
## international copyright and other intellectual property
## laws.
##
## DISCLAIMER
## This disclaimer is not a license and does not grant any
## rights to the materials distributed herewith. Except as
## otherwise provided in a valid license issued to you by
## Xilinx, and to the maximum extent permitted by applicable
## law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
## WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
## AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
## BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
## INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
## (2) Xilinx shall not be liable (whether in contract or tort,
## including negligence, or under any other theory of
## liability) for any loss or damage of any kind or nature
## related to, arising under or in connection with these
## materials, including for any direct, or any indirect,
## special, incidental, or consequential loss or damage
## (including loss of data, profits, goodwill, or any type of
## loss or damage suffered as a result of any action brought
## by a third party) even if such damage or loss was
## reasonably foreseeable or Xilinx had been advised of the
## possibility of the same.
##
## CRITICAL APPLICATIONS
## Xilinx products are not designed or intended to be fail-
## safe, or for use in any application requiring fail-safe
## performance, such as life-support or safety devices or
## systems, Class III medical devices, nuclear facilities,
## applications related to the deployment of airbags, or any
## other applications that could lead to death, personal
## injury, or severe property or environmental damage
## (individually and collectively, "Critical
## Applications"). Customer assumes the sole risk and
## liability of any use of Xilinx products in Critical
## Applications, subject only to applicable laws and
## regulations governing limitations on product liability.
##
## THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
## PART OF THIS FILE AT ALL TIMES.
##
###################################################################################################
##
##  aurora_64b66b_0_exdes
##
##  Description: This is the example design constraints file for a 1 lane Aurora
##               core.
##               This is example design xdc.
##               Note: User need to set proper IO standards for the LOC's mentioned below.
###################################################################################################

# create clock constraints for init_clk
create_clock -period 10.000 -name init_clk_in [get_ports INIT_CLK_P]
set_clock_groups -asynchronous -group [get_clocks init_clk_in -include_generated_clocks]

# Reference clock contraint for GTX
create_clock -period 6.400 -name gt_refclk1_in [get_ports GTHQ0_P]
set_clock_groups -asynchronous -group [get_clocks gt_refclk1_in -include_generated_clocks]

# false path constrints for example design paths
set_false_path -to [get_pins -hier *aurora_64b66b_0_cdc_to*/D]
set_false_path -through [get_pins -quiet -hier *bufg_gt_clr_delayed_reg*/Q]
# Reference clock location
set_property PACKAGE_PIN T5 [get_ports GTHQ0_N]
set_property PACKAGE_PIN T6 [get_ports GTHQ0_P]


################################################################################

#####################################################################################################

## ===== board adaptation: KU060 + FMC_4SFP (2026-08-31) =====
## init_clk: onboard 100MHz diff oscillator (AK17), replaces KC705 placeholder N24/M24
set_property -dict {PACKAGE_PIN AK17 IOSTANDARD DIFF_HSTL_I_12} [get_ports INIT_CLK_P]
set_property -dict {PACKAGE_PIN AK16 IOSTANDARD DIFF_HSTL_I_12} [get_ports INIT_CLK_N]
## status LEDs: CHANNEL_UP / LANE_UP (error counters observed via ILA instead)
set_property -dict {PACKAGE_PIN T22 IOSTANDARD LVCMOS18} [get_ports CHANNEL_UP]
set_property -dict {PACKAGE_PIN T23 IOSTANDARD LVCMOS18} [get_ports LANE_UP]

## ===== FMC_4SFP control signals, VERSION A =====
set_property -dict {PACKAGE_PIN H26 IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[0]}]
set_property -dict {PACKAGE_PIN AH12 IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[1]}]
set_property -dict {PACKAGE_PIN J25 IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[2]}]
set_property -dict {PACKAGE_PIN AF12 IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[3]}]
set_property -dict {PACKAGE_PIN G27 IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[0]}]
set_property -dict {PACKAGE_PIN AH11 IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[1]}]
set_property -dict {PACKAGE_PIN M26 IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[2]}]
set_property -dict {PACKAGE_PIN AF13 IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[3]}]
set_property -dict {PACKAGE_PIN H27 IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[0]}]
set_property -dict {PACKAGE_PIN AG11 IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[1]}]
set_property -dict {PACKAGE_PIN M25 IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[2]}]
set_property -dict {PACKAGE_PIN AE13 IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[3]}]


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
connect_debug_port u_ila_0/clk [get_nets [list aurora_64b66b_0_block_i/clock_module_i/ultrascale_tx_userclk_1/gen_gtwiz_userclk_tx_main.bufg_gt_usrclk2_inst_0]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe0]
set_property port_width 9 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {usr_clk_counter[0]} {usr_clk_counter[1]} {usr_clk_counter[2]} {usr_clk_counter[3]} {usr_clk_counter[4]} {usr_clk_counter[5]} {usr_clk_counter[6]} {usr_clk_counter[7]} {usr_clk_counter[8]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe1]
set_property port_width 8 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list {data_err_count_o[7]} {data_err_count_o[6]} {data_err_count_o[5]} {data_err_count_o[4]} {data_err_count_o[3]} {data_err_count_o[2]} {data_err_count_o[1]} {data_err_count_o[0]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe2]
set_property port_width 1 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets [list channel_up_i]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe3]
set_property port_width 1 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets [list hard_err_i]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe4]
set_property port_width 1 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets [list lane_up_i]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe5]
set_property port_width 1 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets [list rx_tvalid_r]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe6]
set_property port_width 1 [get_debug_ports u_ila_0/probe6]
connect_debug_port u_ila_0/probe6 [get_nets [list soft_err_i]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe7]
set_property port_width 1 [get_debug_ports u_ila_0/probe7]
connect_debug_port u_ila_0/probe7 [get_nets [list usr_clk_count_done]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets user_clk_i]

## ---- UART bridge (FT2232H-B channel) ----
set_property -dict {PACKAGE_PIN AE33 IOSTANDARD LVCMOS18} [get_ports uart_rxd]
set_property -dict {PACKAGE_PIN AF34 IOSTANDARD LVCMOS18} [get_ports uart_txd]
