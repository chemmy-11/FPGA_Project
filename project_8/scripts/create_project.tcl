# =============================================================================
# create_project.tcl — project_8: Aurora-UDP 数据级桥
# 组成: 官方 15 文件以太网栈 + frame_fifo_pump（project_7，C17 已修）
#       + axis_word_pack / axis_word_unpack + 顶层 aurora_udp_bridge
#       + Aurora 64b/66b（共享逻辑在 example design → 必须一并加入 shared_logic）
# 用法（务必在 ASCII 工作目录）:
#   cd D:\FPGA\project_8
#   vivado -mode batch -source scripts\create_project.tcl -notrace
# =============================================================================
set proj_dir   D:/FPGA/project_8
set part_name  xcku060-ffva1156-2-i

create_project project_8 $proj_dir/prj -part $part_name -force

## ---- RTL（官方栈 15 + 帧泵 + 打包/解包 + 顶层）----
add_files -fileset sources_1 [glob $proj_dir/rtl/*.v $proj_dir/rtl/*/*.v]

## ---- Aurora 共享逻辑（shared logic in example design → 必须显式加入）----
add_files -fileset sources_1 [glob $proj_dir/shared_logic/*.v]

## ---- IP: import_ip（避免 read_ip 的生成物路径漂移，project_7 实录）----
import_ip $proj_dir/ip/aurora_64b66b_0/aurora_64b66b_0.xci
import_ip $proj_dir/ip/aurora_64b66b_0_reg_slice_0/aurora_64b66b_0_reg_slice_0.xci
import_ip $proj_dir/ip/aurora_64b66b_0_reg_slice_2/aurora_64b66b_0_reg_slice_2.xci
import_ip $proj_dir/ip/async_fifo_2048x8b/async_fifo_2048x8b.xci
generate_target all [get_ips]

## ---- 约束 ----
add_files -fileset constrs_1 $proj_dir/xdc/aurora_udp_bridge.xdc

## ---- 顶层 ----
set_property top aurora_udp_bridge [current_fileset]
update_compile_order -fileset sources_1

puts "CREATE_DONE: top=[get_property TOP [current_fileset]]"
puts "CREATE_DONE: ips=[get_ips]"
