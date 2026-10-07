# =============================================================================
# create_project.tcl — prj10 prj_loop: 第一级内存插入集成工程
# 组成: prj9 光链路全套(只读引用) + prj10 内存桥四件套 + 派生顶层 aurora_mem_bridge
#       + prj9 五 IP(只读 import) + 真 MIG ddr4_0(xci 与 prj4 逐字节一致)
# 执行单: 操作文档/阶段三_prj10_第一级内存插入集成执行单_2026-10-04
# 用法(ASCII 工作目录):
#   vivado -mode batch -source D:\FPGA\prj\project_10\prj_loop\scripts\create_project.tcl -notrace
# =============================================================================
set P    D:/FPGA/prj/project_10/prj_loop
set P9   D:/FPGA/prj/project_9
set P10  D:/FPGA/prj/project_10
set part_name xcku060-ffva1156-2-i

create_project prj_loop $P/vivado -part $part_name -force

## ---- 光链路源(prj9, 只读): 官方栈 + 帧泵 + 打包/解包 + 双笼 ----
add_files -fileset sources_1 [glob $P9/rtl/*.v $P9/rtl/*/*.v]
## ---- prj10 过载冻结修复(2026-10-06): udp_tx 换派生副本(prj9 原件不动) ----
##   案A 忙时锁存 pending start; R4 TB 验证: 忙态帧正确补发/FIFO 清零/零错位
remove_files -quiet [get_files -quiet $P9/rtl/udp/udp_tx.v]
add_files -fileset sources_1 $P/rtl_patch/udp_tx.v
add_files -fileset sources_1 [glob $P9/shared_logic/*.v]

## ---- prj10: 内存桥三层 + 派生顶层(不含 w3_uiclk_top —— 那是前置工程专用顶层) ----
add_files -fileset sources_1 [list \
    $P10/rtl/async_fifo.v \
    $P10/rtl/axi4_master_bridge.v \
    $P10/rtl/frame_mem_if.v \
    $P10/rtl/aurora_mem_bridge.v \
    $P10/rtl/axi_arb_2to1.v]

## ---- IP: prj9 五个(import_ip 避免生成物路径漂移; reg_slice x2 与 fifo_80b_echo
##      在 prj9 RTL 中未例化 —— 历史遗留, 保真导入, 忽略 unused 告警) ----
import_ip $P9/ip/aurora_64b66b_0/aurora_64b66b_0.xci
import_ip $P9/ip/aurora_64b66b_0_reg_slice_0/aurora_64b66b_0_reg_slice_0.xci
import_ip $P9/ip/aurora_64b66b_0_reg_slice_2/aurora_64b66b_0_reg_slice_2.xci
import_ip $P9/ip/async_fifo_2048x8b/async_fifo_2048x8b.xci
import_ip $P9/ip/aurora_64b66b_1/aurora_64b66b_1.xci
## ---- 真 MIG(xci 源自 prj4 同份; import 后改 System_Clock=No_Buffer) ----
##   为什么改: 顶层继承 prj9 的 init_clk IBUFDS, MIG 若再用差分输入(内部 IBUFDS)
##   即双输入缓冲非法 [Synth 8-5535](2026-10-05 构建实证)。No_Buffer 后 MIG 端口
##   变单端 c0_sys_clk_i, 由顶层 IBUFDS 输出喂入。import_ip 会拷 xci 进工程
##   .srcs, 本配置只落在 prj_loop 工程副本, prj_uiclk/prj4 原件不动。
import_ip $P10/prj_uiclk/ip/ddr4_0/ddr4_0.xci
set_property CONFIG.System_Clock No_Buffer [get_ips ddr4_0]

## ---- 回显弹性 FIFO(prj9 同参数照抄; 现由 unpack->pack 级联承担, 属未例化保留) ----
create_ip -name fifo_generator -vendor xilinx.com -library ip -version 13.2 -module_name fifo_80b_echo
set_property -dict [list \
    CONFIG.Fifo_Implementation {Common_Clock_Block_RAM} \
    CONFIG.Input_Data_Width {80} \
    CONFIG.Input_Depth {512} \
    CONFIG.Performance_Options {First_Word_Fall_Through} \
    CONFIG.Enable_Safety_Circuit {false} \
] [get_ips fifo_80b_echo]

generate_target all [get_ips]

## ---- 合并约束(prj9 全文 + L92 修正 + prj4 DDR 107 脚) ----
add_files -fileset constrs_1 $P/xdc/aurora_mem_bridge.xdc

## ---- 顶层 ----
set_property top aurora_mem_bridge [current_fileset]
update_compile_order -fileset sources_1

puts "CREATE_DONE: top=[get_property TOP [current_fileset]]"
puts "CREATE_DONE: ips=[get_ips]"
