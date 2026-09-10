# =============================================================================
# create_project.tcl — project_7: UDP stack + SFP inner-loop check
# Base : official 39_eth_udp_loop rtl (15 files, project_6 同源)
# Add  : official 53 PCS/PMA xci (1000BASE-X/1G/GMII/X1Y8) + 53 clk_wiz (100M->50M)
#        + custom sfp_udp_inner_loop.v top + frame_fifo_pump.v (CDC pump)
# 用法: vivado -mode batch -source create_project.tcl -notrace
# =============================================================================
set proj_dir   D:/FPGA/project_7
set part_name  xcku060-ffva1156-2-i

create_project project_7 $proj_dir/prj -part $part_name -force

## ---- RTL: official 15 + pump + top ----
add_files -fileset sources_1 [glob $proj_dir/rtl/*.v $proj_dir/rtl/*/*.v]

## ---- IP (import_ip: copy into project, avoid output-path drift) ----
import_ip $proj_dir/ip/async_fifo_2048x8b/async_fifo_2048x8b.xci
import_ip $proj_dir/ip/gig_ethernet_pcs_pma_0/gig_ethernet_pcs_pma_0.xci
import_ip $proj_dir/ip/clk_wiz_0/clk_wiz_0.xci
generate_target all [get_ips]

## ---- constraints (merged official 39 + 53 + LEDs) ----
add_files -fileset constrs_1 $proj_dir/xdc/eth_udp_inner_loop.xdc

## ---- top ----
set_property top sfp_udp_inner_loop [current_fileset]
update_compile_order -fileset sources_1

puts "CREATE_DONE: top=[get_property TOP [current_fileset]]"
