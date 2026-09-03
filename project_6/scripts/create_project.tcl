# =============================================================================
# create_project.tcl — 阶段二之五 网口版以太网 UDP 环回（project_6）
# 幂等：-force 重建工程；IP/文件重复添加安全
# 用法: vivado -mode batch -source create_project.tcl -notrace
# =============================================================================
set proj_dir   D:/FPGA/project_6
set part_name  xcku060-ffva1156-2-i

create_project project_6 $proj_dir -part $part_name -force

## ---- RTL 源码 ----
add_files -fileset sources_1 [glob $proj_dir/rtl/*.v]

## ---- 约束 ----
add_files -fileset constrs_1 $proj_dir/xdc/eth_udp_ge1.xdc

## ---- 异步 FIFO IP: async_fifo_2048x8b（2048 深 x 8 位，独立时钟端口，标准读模式）----
create_ip -name fifo_generator -vendor xilinx.com -library ip -module_name async_fifo_2048x8b -dir $proj_dir/srcs
set_property -dict [list \
    CONFIG.Fifo_Implementation   {Independent_Clocks_Block_RAM} \
    CONFIG.Input_Data_Width      {8} \
    CONFIG.Input_Depth           {2048} \
    CONFIG.Read_Data_Width       {8} \
    CONFIG.Read_Depth            {2048} \
    CONFIG.Write_Clock_Frequency {125} \
    CONFIG.Read_Clock_Frequency  {125} \
    CONFIG.Output_Register       {false} \
    CONFIG.Use_Extra_Logic       {false} \
    CONFIG.Full_Threshold_Assert_Value {2047} \
    CONFIG.Empty_Threshold_Assert_Value {4} \
] [get_ips async_fifo_2048x8b]

## ---- 顶层 ----
set_property top eth_udp_loop [current_fileset]
update_compile_order -fileset sources_1

puts "CREATE_DONE"
