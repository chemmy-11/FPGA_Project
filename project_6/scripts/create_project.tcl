# =============================================================================
# create_project.tcl — project_6 以太网 UDP 网口环回（官方 39_eth_udp_loop 例程移植）
# 源码: D:\BaiduNetdiskDownload\1_Verilog\KU060\39_eth_udp_loop（整包同源，含 IP xci）
# 器件: xcku060-ffva1156-2-i | Vivado 2023.1
# 用法: vivado -mode batch -source create_project.tcl -notrace
# =============================================================================
set proj_dir   D:/FPGA/project_6
set part_name  xcku060-ffva1156-2-i

create_project project_6 $proj_dir/prj -part $part_name -force

## ---- 官方 RTL（15 文件，GBK 编码，保持原样）----
add_files -fileset sources_1 [glob $proj_dir/rtl/*.v $proj_dir/rtl/*/*.v]

## ---- 官方 IP（xci 导入：async_fifo_2048x8b + clk_wiz_0；import_ip 拷入工程避免输出路径漂移）----
import_ip $proj_dir/ip/async_fifo_2048x8b/async_fifo_2048x8b.xci
import_ip $proj_dir/ip/clk_wiz_0/clk_wiz_0.xci
generate_target all [get_ips]

## ---- 官方约束（表 43.5.1 GE1 全引脚 + key + UNUSEDPPIN）----
add_files -fileset constrs_1 $proj_dir/eth_udp_loop.xdc

## ---- 顶层 ----
set_property top eth_udp_loop [current_fileset]
update_compile_order -fileset sources_1

## ---- 仿真 TB（备用，不参与综合）----
add_files -fileset sim_1 -norecurse $proj_dir/sim/tb/tb_udp.v
set_property top tb_udp [get_filesets sim_1]

puts "CREATE_DONE: [get_property NAME [current_project]] top=[get_property TOP [current_fileset]]"
