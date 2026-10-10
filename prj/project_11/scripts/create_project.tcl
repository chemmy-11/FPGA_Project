# =============================================================================
# create_project.tcl — prj11 路线B: 软核 + AXI DMA 控制面（B0 冻结基线版）
# 组成: 本工程 rtl/ 物理持有全部源件（fork 自 prj10/prj_loop 2026-10-10,
#       45 文件 SHA 对照见 ../fork_manifest.json; prj10 已整目录冻结为路线A资产）
#       + prj9 五 IP(只读 import) + 真 MIG ddr4_0(xci 源自 prj4 同份)
# 本版 = B0 冻结基线: 与 prj10 终版逐文件一致, 不含任何 B 的改动;
#       B1 起新增件(BD 子系统/axi_lite_regs)在此之上叠加。
# 执行单: 毕设/操作文档/阶段三_prj11_路线B软核与DMA开工草案_2026-10-10 (实施单 v1.0)
# 用法(ASCII 工作目录):
#   vivado -mode batch -source D:\FPGA\prj\project_11\scripts\create_project.tcl -notrace
# =============================================================================
set P    D:/FPGA/prj/project_11
set P9   D:/FPGA/prj/project_9
set P10  D:/FPGA/prj/project_10
set part_name xcku060-ffva1156-2-i

create_project prj11 $P/vivado -part $part_name -force

## ---- 光链路 + 内存桥 + 派生副本: 全部本工程物理持有 ----
##   (fork 时已用 prj_loop/rtl_patch 的 udp_tx/frame_fifo_pump/cmd_channel
##    顶替 prj9 原件占位, 无需 remove_files 步骤)
add_files -fileset sources_1 [glob $P/rtl/*.v $P/rtl/*/*.v]
add_files -fileset sources_1 [glob $P/rtl/shared_logic/*.v]

## ---- IP: prj9 五个(import_ip 拷入工程 .srcs; 源件在冻结工程中不变) ----
import_ip $P9/ip/aurora_64b66b_0/aurora_64b66b_0.xci
import_ip $P9/ip/aurora_64b66b_0_reg_slice_0/aurora_64b66b_0_reg_slice_0.xci
import_ip $P9/ip/aurora_64b66b_0_reg_slice_2/aurora_64b66b_0_reg_slice_2.xci
import_ip $P9/ip/async_fifo_2048x8b/async_fifo_2048x8b.xci
import_ip $P9/ip/aurora_64b66b_1/aurora_64b66b_1.xci
## ---- 真 MIG(源与 prj_loop 同份; import 后改 System_Clock=No_Buffer) ----
##   原因见 prj_loop 同名脚本注释: 顶层已继承 init_clk IBUFDS, MIG 再挂内部
##   IBUFDS 即双输入缓冲非法 [Synth 8-5535]。
import_ip $P10/prj_uiclk/ip/ddr4_0/ddr4_0.xci
set_property CONFIG.System_Clock No_Buffer [get_ips ddr4_0]

## ---- 回显弹性 FIFO(prj9 同参数照抄; 未例化保留) ----
create_ip -name fifo_generator -vendor xilinx.com -library ip -version 13.2 -module_name fifo_80b_echo
set_property -dict [list \
    CONFIG.Fifo_Implementation {Common_Clock_Block_RAM} \
    CONFIG.Input_Data_Width {80} \
    CONFIG.Input_Depth {512} \
    CONFIG.Performance_Options {First_Word_Fall_Through} \
    CONFIG.Enable_Safety_Circuit {false} \
] [get_ips fifo_80b_echo]

generate_target all [get_ips]

## ---- 约束(prj9 全文 + L92 修正 + DDR 107 脚, 与 prj_loop 逐字节一致) ----
add_files -fileset constrs_1 $P/xdc/aurora_mem_bridge.xdc

## ---- 顶层 ----
set_property top aurora_mem_bridge [current_fileset]
update_compile_order -fileset sources_1

puts "CREATE_DONE: top=[get_property TOP [current_fileset]]"
puts "CREATE_DONE: ips=[get_ips]"
