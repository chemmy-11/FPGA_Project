## 1. 约束差分时钟 (假设板子晶振接在 AK17 和 AK16，电平标准为 LVDS)
#set_property PACKAGE_PIN <正极引脚号> [get_ports diff_clock_rtl_0_clk_p]
#set_property IOSTANDARD LVDS [get_ports diff_clock_rtl_0_clk_p]
#set_property PACKAGE_PIN <负极引脚号> [get_ports diff_clock_rtl_0_clk_n]
#set_property IOSTANDARD LVDS [get_ports diff_clock_rtl_0_clk_n]

## 2. 约束系统复位 (假设板子上复位按键接在 AM12，电平为 1.8V)
#set_property PACKAGE_PIN <AC34> [get_ports reset_rtl_0]
#set_property IOSTANDARD LVCMOS18 [get_ports reset_rtl_0]

## 3. 约束串口 UART (假设 RX接 AL10, TX接 AL11)
#set_property PACKAGE_PIN <AE33> [get_ports uart_rtl_0_rxd]
#set_property IOSTANDARD LVCMOS18 [get_ports uart_rtl_0_rxd]
#set_property PACKAGE_PIN <AT34> [get_ports uart_rtl_0_txd]
#set_property IOSTANDARD LVCMOS18 [get_ports uart_rtl_0_txd]