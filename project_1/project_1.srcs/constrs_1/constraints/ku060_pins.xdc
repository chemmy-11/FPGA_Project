# ============================================================
# ku060_pins.xdc -- KU060 board pin constraints (MicroBlaze minimal system)
# Source : official board file KU_IO.xdc (D:\FPGA\KU_IO.xdc), port names
#          adapted to this project's top-level wrapper (design_1_wrapper.v)
# Top-level ports: diff_clock_rtl_0_clk_p/n, reset_rtl_0, uart_rxd, uart_txd
# NOTE   : comments are ASCII-English on purpose -- Vivado on a Chinese
#          Windows locale opens UTF-8 Chinese comments as GBK -> mojibake.
# ============================================================

# ---------------------- System clock (100 MHz differential) -------------
# WHY: On-board oscillator is a 100 MHz differential pair (official XDC:
#      create_clock -period 10.000). The BD diff_clock_rtl_0 FREQ_HZ is
#      also 100 MHz, so clk_wiz derives frequencies correctly.
# NOTE: NO manual create_clock here -- the clk_wiz IP's generated XDC
#      (design_1_clk_wiz_1_0.xdc) already constrains the input clock from
#      the BD FREQ_HZ. A manual one would trigger the "clock override"
#      warning [Constraints 18-1055].
# WHY differential: clk_wiz CLK_IN1_D maps to the clk_p/clk_n wrapper
#      ports; pin the P side, give both sides the same IOSTANDARD.
set_property PACKAGE_PIN AK17 [get_ports diff_clock_rtl_0_clk_p]
set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports diff_clock_rtl_0_clk_p]
set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports diff_clock_rtl_0_clk_n]
# NOTE: clk_n intentionally has no PACKAGE_PIN -- same as the official
#      XDC; the placer auto-infers the diff-pair pad of AK17.

# ---------------------- System reset (active low) -----------------------
# WHY: On-board reset button pulls the pin low; BD reset_rtl_0 POLARITY
#      is ACTIVE_LOW, so pin behavior and logic must agree.
set_property -dict {PACKAGE_PIN AC34 IOSTANDARD LVCMOS18} [get_ports reset_rtl_0]

# ---------------------- UART (9600 baud) --------------------------------
# WHY: BD axi_uartlite is set to 9600 baud (not the 115200 default);
#      LVCMOS18 matches the on-board CH340 level (official XDC).
set_property -dict {PACKAGE_PIN AE33 IOSTANDARD LVCMOS18} [get_ports uart_rxd]
set_property -dict {PACKAGE_PIN AF34 IOSTANDARD LVCMOS18} [get_ports uart_txd]
