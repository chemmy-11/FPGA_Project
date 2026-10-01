# =============================================================================
# uiclk_preflight.tcl -- W3 A4/A5 pre-flight: bridge + REAL MIG, ui_clk timing
# 目的（W3 前置清单 B2）：MIG 时序零余量（WNS=+0.024 ns）——把新增的
# frame_mem_if + axi4_master_bridge 放进真 ddr4_0 的 ui_clk 域，看 WNS/WHS。
# 与完整 A4 的差别：不含 Aurora/以太网（那些在 user_clk 域，prj9 已闭环）；
# 本工程覆盖"新逻辑 + 真 MIG + 两个时钟域的 CDC"这一唯一新增时序风险。
# 用法：vivado.bat -mode batch -source uiclk_preflight.tcl -notrace
# =============================================================================
set P    D:/FPGA/project_10/prj_uiclk
set RTL  D:/FPGA/project_10/rtl
set part xcku060-ffva1156-2-i

create_project prj_uiclk $P/vivado -part $part -force

add_files -fileset sources_1 [list $RTL/async_fifo.v $RTL/axi4_master_bridge.v $RTL/frame_mem_if.v $RTL/w3_uiclk_top.v]
import_ip $P/ip/ddr4_0/ddr4_0.xci
add_files -fileset constrs_1 $P/xdc/w3_uiclk_top.xdc

set_property top w3_uiclk_top [current_fileset]
update_compile_order -fileset sources_1
generate_target all [get_ips]

puts "PREFLIGHT_CREATE_DONE top=[get_property TOP [current_fileset]] ips=[get_ips]"