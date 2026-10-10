# =============================================================================
# aurora_mem_bridge.xdc — prj10 第一级内存插入（合并约束）
# 组成: prj9 aurora_udp_bridge.xdc 全文(仅修 L92 行尾注释缺陷, 坑账本 #19)
#     + prj4 mig_verify_pins.xdc 的 DDR 引脚 107 行(排除 sys_clk/sys_rst_btn/led_* 三组)
# 排除原因: init_clk_p/n(=AK17/AK16, DIFF_HSTL_I_12) 已覆盖 MIG sys_clk 电气要求;
#           sys_rst_n(AC34) / led_loop/led_link(T22/T23) 由 prj9 行占用, 端口名沿用
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

## ---- SFP-B 控制脚（光口Y9 = 通道B = X1Y9；来源：官方 55_sfp_10g_loop XDC 注释）----
set_property -dict {PACKAGE_PIN AH11 IOSTANDARD LVCMOS33} [get_ports sfpb_rs0]
set_property -dict {PACKAGE_PIN AG11 IOSTANDARD LVCMOS33} [get_ports sfpb_rs1]
set_property -dict {PACKAGE_PIN AH12 IOSTANDARD LVCMOS33} [get_ports sfpb_tx_disable]

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
set_false_path -quiet -to [get_pins -quiet -hier *aurora_64b66b_*_cdc_to*/D]
# prj10 合并修正: 原行尾注释在 Tcl 中是多余参数 -> [Common 17-165] 约束失效(坑账本 #19), 已移为独立行(覆盖 _0 与 _1 双核)
set_false_path -quiet -through [get_pins -quiet -hier *bufg_gt_clr_delayed_reg*/Q]

# =============================================================================
# ---- DDR4 引脚(107 行): 来源 prj4/mig_verify_pins.xdc 原件(官方 KU_IO.xdc) ----
#      IOSTANDARD 由 MIG IP 自带 XDC 提供(IOBUFFE3 等专用 IO 无需手工标准)
# =============================================================================
set_property PACKAGE_PIN AG14 [get_ports {c0_ddr4_adr[0]}]
set_property PACKAGE_PIN AF17 [get_ports {c0_ddr4_adr[1]}]
set_property PACKAGE_PIN AF15 [get_ports {c0_ddr4_adr[2]}]
set_property PACKAGE_PIN AJ14 [get_ports {c0_ddr4_adr[3]}]
set_property PACKAGE_PIN AD18 [get_ports {c0_ddr4_adr[4]}]
set_property PACKAGE_PIN AG17 [get_ports {c0_ddr4_adr[5]}]
set_property PACKAGE_PIN AE17 [get_ports {c0_ddr4_adr[6]}]
set_property PACKAGE_PIN AK18 [get_ports {c0_ddr4_adr[7]}]
set_property PACKAGE_PIN AD16 [get_ports {c0_ddr4_adr[8]}]
set_property PACKAGE_PIN AH18 [get_ports {c0_ddr4_adr[9]}]
set_property PACKAGE_PIN AD19 [get_ports {c0_ddr4_adr[10]}]
set_property PACKAGE_PIN AD15 [get_ports {c0_ddr4_adr[11]}]
set_property PACKAGE_PIN AL17 [get_ports {c0_ddr4_adr[13]}]
set_property PACKAGE_PIN AH16 [get_ports {c0_ddr4_adr[12]}]
set_property PACKAGE_PIN AL15 [get_ports {c0_ddr4_adr[14]}]
set_property PACKAGE_PIN AL19 [get_ports {c0_ddr4_adr[15]}]
set_property PACKAGE_PIN AM19 [get_ports {c0_ddr4_adr[16]}]
set_property PACKAGE_PIN AG15 [get_ports {c0_ddr4_ba[0]}]
set_property PACKAGE_PIN AL18 [get_ports {c0_ddr4_ba[1]}]
set_property PACKAGE_PIN AJ15 [get_ports {c0_ddr4_bg[0]}]
set_property PACKAGE_PIN AE16 [get_ports {c0_ddr4_ck_t[0]}]
set_property PACKAGE_PIN AE15 [get_ports {c0_ddr4_ck_c[0]}]
set_property PACKAGE_PIN AE18 [get_ports {c0_ddr4_cs_n[0]}]
set_property PACKAGE_PIN AJ16 [get_ports {c0_ddr4_cke[0]}]
set_property PACKAGE_PIN AG19 [get_ports {c0_ddr4_odt[0]}]
set_property PACKAGE_PIN AF18 [get_ports c0_ddr4_act_n]
set_property PACKAGE_PIN AG16 [get_ports c0_ddr4_reset_n]
set_property PACKAGE_PIN AL34 [get_ports {c0_ddr4_dq[63]}]
set_property PACKAGE_PIN AN33 [get_ports {c0_ddr4_dq[62]}]
set_property PACKAGE_PIN AM34 [get_ports {c0_ddr4_dq[61]}]
set_property PACKAGE_PIN AN32 [get_ports {c0_ddr4_dq[60]}]
set_property PACKAGE_PIN AM32 [get_ports {c0_ddr4_dq[59]}]
set_property PACKAGE_PIN AP31 [get_ports {c0_ddr4_dq[58]}]
set_property PACKAGE_PIN AP33 [get_ports {c0_ddr4_dq[57]}]
set_property PACKAGE_PIN AN31 [get_ports {c0_ddr4_dq[56]}]
set_property PACKAGE_PIN AK31 [get_ports {c0_ddr4_dq[55]}]
set_property PACKAGE_PIN AJ30 [get_ports {c0_ddr4_dq[54]}]
set_property PACKAGE_PIN AJ34 [get_ports {c0_ddr4_dq[53]}]
set_property PACKAGE_PIN AH32 [get_ports {c0_ddr4_dq[52]}]
set_property PACKAGE_PIN AK32 [get_ports {c0_ddr4_dq[51]}]
set_property PACKAGE_PIN AJ31 [get_ports {c0_ddr4_dq[50]}]
set_property PACKAGE_PIN AH34 [get_ports {c0_ddr4_dq[49]}]
set_property PACKAGE_PIN AH31 [get_ports {c0_ddr4_dq[48]}]
set_property PACKAGE_PIN AN27 [get_ports {c0_ddr4_dq[47]}]
set_property PACKAGE_PIN AL30 [get_ports {c0_ddr4_dq[46]}]
set_property PACKAGE_PIN AN28 [get_ports {c0_ddr4_dq[45]}]
set_property PACKAGE_PIN AL29 [get_ports {c0_ddr4_dq[44]}]
set_property PACKAGE_PIN AP28 [get_ports {c0_ddr4_dq[43]}]
set_property PACKAGE_PIN AM29 [get_ports {c0_ddr4_dq[42]}]
set_property PACKAGE_PIN AP29 [get_ports {c0_ddr4_dq[41]}]
set_property PACKAGE_PIN AM30 [get_ports {c0_ddr4_dq[40]}]
set_property PACKAGE_PIN AH27 [get_ports {c0_ddr4_dq[39]}]
set_property PACKAGE_PIN AK28 [get_ports {c0_ddr4_dq[38]}]
set_property PACKAGE_PIN AH28 [get_ports {c0_ddr4_dq[37]}]
set_property PACKAGE_PIN AK27 [get_ports {c0_ddr4_dq[36]}]
set_property PACKAGE_PIN AJ28 [get_ports {c0_ddr4_dq[35]}]
set_property PACKAGE_PIN AM27 [get_ports {c0_ddr4_dq[34]}]
set_property PACKAGE_PIN AK26 [get_ports {c0_ddr4_dq[33]}]
set_property PACKAGE_PIN AM26 [get_ports {c0_ddr4_dq[32]}]
set_property PACKAGE_PIN AM24 [get_ports {c0_ddr4_dq[31]}]
set_property PACKAGE_PIN AP23 [get_ports {c0_ddr4_dq[30]}]
set_property PACKAGE_PIN AP25 [get_ports {c0_ddr4_dq[29]}]
set_property PACKAGE_PIN AN23 [get_ports {c0_ddr4_dq[28]}]
set_property PACKAGE_PIN AN24 [get_ports {c0_ddr4_dq[27]}]
set_property PACKAGE_PIN AN22 [get_ports {c0_ddr4_dq[26]}]
set_property PACKAGE_PIN AP24 [get_ports {c0_ddr4_dq[25]}]
set_property PACKAGE_PIN AM22 [get_ports {c0_ddr4_dq[24]}]
set_property PACKAGE_PIN AL25 [get_ports {c0_ddr4_dq[23]}]
set_property PACKAGE_PIN AK23 [get_ports {c0_ddr4_dq[22]}]
set_property PACKAGE_PIN AL24 [get_ports {c0_ddr4_dq[21]}]
set_property PACKAGE_PIN AL20 [get_ports {c0_ddr4_dq[20]}]
set_property PACKAGE_PIN AL23 [get_ports {c0_ddr4_dq[19]}]
set_property PACKAGE_PIN AL22 [get_ports {c0_ddr4_dq[18]}]
set_property PACKAGE_PIN AM20 [get_ports {c0_ddr4_dq[17]}]
set_property PACKAGE_PIN AK22 [get_ports {c0_ddr4_dq[16]}]
set_property PACKAGE_PIN AH22 [get_ports {c0_ddr4_dq[15]}]
set_property PACKAGE_PIN AG24 [get_ports {c0_ddr4_dq[14]}]
set_property PACKAGE_PIN AJ24 [get_ports {c0_ddr4_dq[13]}]
set_property PACKAGE_PIN AG25 [get_ports {c0_ddr4_dq[12]}]
set_property PACKAGE_PIN AH23 [get_ports {c0_ddr4_dq[11]}]
set_property PACKAGE_PIN AF23 [get_ports {c0_ddr4_dq[10]}]
set_property PACKAGE_PIN AJ23 [get_ports {c0_ddr4_dq[9]}]
set_property PACKAGE_PIN AF24 [get_ports {c0_ddr4_dq[8]}]
set_property PACKAGE_PIN AE23 [get_ports {c0_ddr4_dq[7]}]
set_property PACKAGE_PIN AE22 [get_ports {c0_ddr4_dq[6]}]
set_property PACKAGE_PIN AG22 [get_ports {c0_ddr4_dq[5]}]
set_property PACKAGE_PIN AD20 [get_ports {c0_ddr4_dq[4]}]
set_property PACKAGE_PIN AG20 [get_ports {c0_ddr4_dq[3]}]
set_property PACKAGE_PIN AF20 [get_ports {c0_ddr4_dq[2]}]
set_property PACKAGE_PIN AF22 [get_ports {c0_ddr4_dq[1]}]
set_property PACKAGE_PIN AE20 [get_ports {c0_ddr4_dq[0]}]
set_property PACKAGE_PIN AG21 [get_ports {c0_ddr4_dqs_t[0]}]
set_property PACKAGE_PIN AH24 [get_ports {c0_ddr4_dqs_t[1]}]
set_property PACKAGE_PIN AJ20 [get_ports {c0_ddr4_dqs_t[2]}]
set_property PACKAGE_PIN AP20 [get_ports {c0_ddr4_dqs_t[3]}]
set_property PACKAGE_PIN AL27 [get_ports {c0_ddr4_dqs_t[4]}]
set_property PACKAGE_PIN AN29 [get_ports {c0_ddr4_dqs_t[5]}]
set_property PACKAGE_PIN AH33 [get_ports {c0_ddr4_dqs_t[6]}]
set_property PACKAGE_PIN AN34 [get_ports {c0_ddr4_dqs_t[7]}]
set_property PACKAGE_PIN AL32 [get_ports {c0_ddr4_dm_dbi_n[7]}]
set_property PACKAGE_PIN AJ29 [get_ports {c0_ddr4_dm_dbi_n[6]}]
set_property PACKAGE_PIN AN26 [get_ports {c0_ddr4_dm_dbi_n[5]}]
set_property PACKAGE_PIN AH26 [get_ports {c0_ddr4_dm_dbi_n[4]}]
set_property PACKAGE_PIN AM21 [get_ports {c0_ddr4_dm_dbi_n[3]}]
set_property PACKAGE_PIN AJ21 [get_ports {c0_ddr4_dm_dbi_n[2]}]
set_property PACKAGE_PIN AE25 [get_ports {c0_ddr4_dm_dbi_n[1]}]
set_property PACKAGE_PIN AD21 [get_ports {c0_ddr4_dm_dbi_n[0]}]

## ---- prj11 B1: UART (CH340, COM7@9600; 引脚与 project_1 M1 相同) ----
set_property -dict {PACKAGE_PIN AE33 IOSTANDARD LVCMOS18} [get_ports uart_rxd]
set_property -dict {PACKAGE_PIN AF34 IOSTANDARD LVCMOS18} [get_ports uart_txd]
# prj11 B1: AE33 落在 DDR4 校准字节组的 BITSLICE_1 [DRC PDRC-203] ——
#   校准期间 uart_rxd 不可用是可接受的(MicroBlaze 由 POR 释放、自测在
#   calib_done 后才运行), 显式确认此条件(位流 DRC 放行)
set_property UNAVAILABLE_DURING_CALIBRATION TRUE [get_ports uart_rxd]
