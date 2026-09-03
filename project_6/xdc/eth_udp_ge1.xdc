# =============================================================================
# eth_udp_ge1.xdc — 阶段二之五 网口版 UDP 环回（GE1, YT8531 PHY）
# 引脚来源：开发指南表 43.5.1（ARP 章 p1358-1359），与 08-31"官方表 26 脚实测"信号清单一致
# 待办：球号上板前原理图终核（实操单 U7）
# =============================================================================

## ===== RGMII 接收（PHY->FPGA, LVCMOS18）=====
set_property -dict {PACKAGE_PIN AC31 IOSTANDARD LVCMOS18} [get_ports eth_rxc]
set_property -dict {PACKAGE_PIN Y33  IOSTANDARD LVCMOS18} [get_ports eth_rx_ctl]
set_property -dict {PACKAGE_PIN W33  IOSTANDARD LVCMOS18} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN W34  IOSTANDARD LVCMOS18} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN V33  IOSTANDARD LVCMOS18} [get_ports {eth_rxd[2]}]
set_property -dict {PACKAGE_PIN AC32 IOSTANDARD LVCMOS18} [get_ports {eth_rxd[3]}]

## ===== RGMII 发送（FPGA->PHY, LVCMOS18）=====
set_property -dict {PACKAGE_PIN Y32  IOSTANDARD LVCMOS18} [get_ports eth_txc]
set_property -dict {PACKAGE_PIN AE32 IOSTANDARD LVCMOS18} [get_ports eth_tx_ctl]
set_property -dict {PACKAGE_PIN Y31  IOSTANDARD LVCMOS18} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN AF32 IOSTANDARD LVCMOS18} [get_ports {eth_txd[1]}]
set_property -dict {PACKAGE_PIN AF30 IOSTANDARD LVCMOS18} [get_ports {eth_txd[2]}]
set_property -dict {PACKAGE_PIN AG30 IOSTANDARD LVCMOS18} [get_ports {eth_txd[3]}]

## ===== PHY 复位（低有效，YT8531 要求低电平持续 10ms）=====
set_property -dict {PACKAGE_PIN AA33 IOSTANDARD LVCMOS18} [get_ports eth_rst_n]

## ===== 系统复位按键（低有效，M1 ku060_pins.xdc 实证）=====
set_property -dict {PACKAGE_PIN AC34 IOSTANDARD LVCMOS18} [get_ports sys_rst_n]

## ===== 时钟约束：RGMII 接收时钟 125MHz（千兆）=====
create_clock -period 8.000 -name eth_rxc [get_ports eth_rxc]
