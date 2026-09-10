# =============================================================================
# aurora_udp_bridge.xdc — project_8 Aurora-UDP 数据级桥
# 引脚来源：官方 39 例程（GE1 RGMII）+ IBERT/Aurora 定版（GT refclk/控制脚）
# =============================================================================

## ---- bitstream config（官方 39/53）----
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLNONE [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

## ---- clocks ----
# RGMII 接收时钟 125M（PHY 提供）
create_clock -period 8.000  -name eth_rxc   [get_ports eth_rxc]
# GT 参考时钟 156.25M（MGTREFCLK1_226 = T6/T5，IBERT 实测定版）
create_clock -period 6.400  -name gt_refclk [get_ports gt_refclk_p]
# Aurora init clock 100M 差分（AK17/AK16，独立于恢复时钟）
create_clock -period 10.000 -name init_clk  [get_ports init_clk_p]

## ---- GT refclk: MGTREFCLK1_226 (T6/T5) 156.25MHz ----
set_property PACKAGE_PIN T6 [get_ports gt_refclk_p]
set_property PACKAGE_PIN T5 [get_ports gt_refclk_n]

## ---- init clock: onboard 100MHz diff (AK17/AK16) ----
set_property -dict {PACKAGE_PIN AK17 IOSTANDARD DIFF_HSTL_I_12} [get_ports init_clk_p]
set_property -dict {PACKAGE_PIN AK16 IOSTANDARD DIFF_HSTL_I_12} [get_ports init_clk_n]

## ---- 系统 ----
set_property -dict {PACKAGE_PIN AC34 IOSTANDARD LVCMOS18} [get_ports sys_rst_n]
set_property -dict {PACKAGE_PIN Y30  IOSTANDARD LVCMOS18} [get_ports key]

## ---- RGMII GE1 (YT8531 PHY, 全部 LVCMOS18) ----
set_property -dict {PACKAGE_PIN AC31 IOSTANDARD LVCMOS18} [get_ports eth_rxc]
set_property -dict {PACKAGE_PIN Y33  IOSTANDARD LVCMOS18} [get_ports eth_rx_ctl]
set_property -dict {PACKAGE_PIN W33  IOSTANDARD LVCMOS18} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN W34  IOSTANDARD LVCMOS18} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN V33  IOSTANDARD LVCMOS18} [get_ports {eth_rxd[2]}]
set_property -dict {PACKAGE_PIN AC32 IOSTANDARD LVCMOS18} [get_ports {eth_rxd[3]}]
set_property -dict {PACKAGE_PIN Y32  IOSTANDARD LVCMOS18} [get_ports eth_txc]
set_property -dict {PACKAGE_PIN AE32 IOSTANDARD LVCMOS18} [get_ports eth_tx_ctl]
set_property -dict {PACKAGE_PIN Y31  IOSTANDARD LVCMOS18} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN AF32 IOSTANDARD LVCMOS18} [get_ports {eth_txd[1]}]
set_property -dict {PACKAGE_PIN AF30 IOSTANDARD LVCMOS18} [get_ports {eth_txd[2]}]
set_property -dict {PACKAGE_PIN AG30 IOSTANDARD LVCMOS18} [get_ports {eth_txd[3]}]
set_property -dict {PACKAGE_PIN AA33 IOSTANDARD LVCMOS18} [get_ports eth_rst_n]

## ---- SFP 控制脚（SFPA = X1Y11，版本 A 索引 3；内环模式功能不敏感）----
set_property -dict {PACKAGE_PIN AF12 IOSTANDARD LVCMOS33} [get_ports sfp_tx_disable]
set_property -dict {PACKAGE_PIN AF13 IOSTANDARD LVCMOS33} [get_ports sfp_rs0]
set_property -dict {PACKAGE_PIN AE13 IOSTANDARD LVCMOS33} [get_ports sfp_rs1]

## ---- 观测 LED（T22/T23）----
set_property -dict {PACKAGE_PIN T22 IOSTANDARD LVCMOS18} [get_ports led_loop]
set_property -dict {PACKAGE_PIN T23 IOSTANDARD LVCMOS18} [get_ports led_link]

# =============================================================================
# 时钟域 / 例外约束 —— 照搬官方 example design 的 aurora_64b66b_0_exdes.xdc
# -----------------------------------------------------------------------------
# 为什么必须加：Vivado 默认对"无共同祖先"的时钟对**也**做建立/保持与恢复/移除分析。
#   本设计三个时钟互不相关：
#     eth_rxc  = PHY 晶振（RGMII 125M, 8 ns）
#     gt_refclk= MGTREFCLK1_226 156.25M（6.4 ns）→ 经 MMCM 生成 user_clk(~151.5M)
#     init_clk = 板载 100M 差分（10 ns）
#   所有跨域信号都已同步（帧泵格雷码指针双向 2FF、frame_len_mb 4 相握手邮箱、
#   wr_done_t/rd_done_t 翻转标志 2FF、复位同步链），故应声明为异步。
# 不加时的实测代价（首轮实现）: WNS=-2.661 ns，失败路径全部是
#   · u_aurora/bufg_gt_clr_delayed_reg → 各 tx_active/cdc 寄存器的 CLR（async_default 组）
#   · u_aurora/support_reset_logic_i 内部 *cdc_to* 同步器输入
#   · u_pump_rev 跨域指针/邮箱
#   这些路径的数据延时仅 0.3~0.4 ns，罚分几乎全来自时钟插入延迟差（SCD 4.3 vs DCD 1.8 ns）
#   —— 典型的"缺少时钟组声明"特征，而非真实逻辑太慢。
#
# 注意：XDC 文件里不能用 if / puts / foreach（Vivado 只支持受限 Tcl 子集，
#   实测会报 CRITICAL WARNING: [Designutils 20-1307] 且约束被整段丢弃）。
# =============================================================================

# --- 单组 -asynchronous = "本组与其余所有时钟互不相关"（含其派生时钟）---
#     gt_refclk 组含 MMCM 派生的 user_clk / sync_clk / tx_out_clk，
#     故这一行同时覆盖了 eth_rxc <-> user_clk 的全部跨域路径。
set_clock_groups -asynchronous -group [get_clocks init_clk  -include_generated_clocks]
set_clock_groups -asynchronous -group [get_clocks gt_refclk -include_generated_clocks]

# --- Aurora IP 内部 CDC 与 bufg_gt_clr 的例外（与 exdes 逐字一致）---
set_false_path -quiet -to [get_pins -quiet -hier *aurora_64b66b_0_cdc_to*/D]
set_false_path -quiet -through [get_pins -quiet -hier *bufg_gt_clr_delayed_reg*/Q]
