# =============================================================================
# create_bd_b.tcl — prj11 B1: MicroBlaze 控制面子系统 BD（mb_ctrl）
# 基底: project_1 design_1 的导出重建 Tcl(M1 已验证配方, 2023.1 导出),
#       去掉 clk_wiz(外部 100MHz 直进), 复位改高有效(顶层 reset_pb),
#       互联换 SmartConnect, 新增 axi_lite_regs(RTL 模块引用)。
# 组成: MicroBlaze(64KB 本地内存+Debug, M_AXI_DP) + MDM + proc_sys_reset
#       + UARTLite(9600) + SmartConnect(1->2) + axi_lite_regs
# 外部: clk_100m / ext_reset_in(ACTIVE_HIGH) / uart_rxd / uart_txd
#       / clk_user + rst_user_n + u_* + ctl_owner + cfg_*(user_clk 域)
# 地址: lmb 0x00000000(64KB), UARTLite 0x40600000(M1 同款), regs 0x44A00000
# 用法: create_project.tcl 之后执行(或由其 source); 幂等(先删旧 BD)
# =============================================================================
set P D:/FPGA/prj/project_11

if {[llength [get_projects -quiet]] == 0} {
    open_project $P/vivado/prj11.xpr
}

# ---- idempotent: drop any previous BD (hard clean by path) ----
if {[llength [get_bd_designs -quiet mb_ctrl]]} {
    close_bd_design [get_bd_designs mb_ctrl]
}
foreach f [get_files -quiet *.bd] {
    remove_files -quiet $f
}
file delete -force $P/vivado/prj11.srcs/sources_1/bd/mb_ctrl
file delete -force $P/vivado/prj11.srcs/sources_1/bd/probe

# axi_lite_regs.v must be a project source for the module reference
if {[llength [get_files -quiet axi_lite_regs.v]] == 0} {
    add_files -fileset sources_1 $P/rtl/axi_lite_regs.v
}

#---- --------------------------------------------------------------------
# hierarchical cell: microblaze_0_local_memory (project_1 配方逐字复用)
#---- --------------------------------------------------------------------
proc create_hier_cell_microblaze_0_local_memory { parentCell nameHier } {
  if { $parentCell eq "" || $nameHier eq "" } { error "local_memory: empty arg" }
  set parentObj [get_bd_cells $parentCell]
  current_bd_instance $parentObj
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  create_bd_intf_pin -mode MirroredMaster -vlnv xilinx.com:interface:lmb_rtl:1.0 DLMB
  create_bd_intf_pin -mode MirroredMaster -vlnv xilinx.com:interface:lmb_rtl:1.0 ILMB
  create_bd_pin -dir I -type clk LMB_Clk
  create_bd_pin -dir I -type rst SYS_Rst

  create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:3.0 dlmb_v10
  create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:3.0 ilmb_v10
  set c [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr:4.0 dlmb_bram_if_cntlr]
  set_property CONFIG.C_ECC {0} $c
  set c [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr:4.0 ilmb_bram_if_cntlr]
  set_property CONFIG.C_ECC {0} $c
  set c [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 lmb_bram]
  set_property -dict [list CONFIG.Memory_Type {True_Dual_Port_RAM} \
      CONFIG.use_bram_block {BRAM_Controller}] $c

  connect_bd_intf_net [get_bd_intf_pins dlmb_v10/LMB_M] [get_bd_intf_pins DLMB]
  connect_bd_intf_net [get_bd_intf_pins dlmb_v10/LMB_Sl_0] [get_bd_intf_pins dlmb_bram_if_cntlr/SLMB]
  connect_bd_intf_net [get_bd_intf_pins dlmb_bram_if_cntlr/BRAM_PORT] [get_bd_intf_pins lmb_bram/BRAM_PORTA]
  connect_bd_intf_net [get_bd_intf_pins ilmb_v10/LMB_M] [get_bd_intf_pins ILMB]
  connect_bd_intf_net [get_bd_intf_pins ilmb_v10/LMB_Sl_0] [get_bd_intf_pins ilmb_bram_if_cntlr/SLMB]
  connect_bd_intf_net [get_bd_intf_pins ilmb_bram_if_cntlr/BRAM_PORT] [get_bd_intf_pins lmb_bram/BRAM_PORTB]
  connect_bd_net [get_bd_pins SYS_Rst] [get_bd_pins dlmb_v10/SYS_Rst] [get_bd_pins dlmb_bram_if_cntlr/LMB_Rst] [get_bd_pins ilmb_v10/SYS_Rst] [get_bd_pins ilmb_bram_if_cntlr/LMB_Rst]
  connect_bd_net [get_bd_pins LMB_Clk] [get_bd_pins dlmb_v10/LMB_Clk] [get_bd_pins dlmb_bram_if_cntlr/LMB_Clk] [get_bd_pins ilmb_v10/LMB_Clk] [get_bd_pins ilmb_bram_if_cntlr/LMB_Clk]
  current_bd_instance $parentObj
}

#---- --------------------------------------------------------------------
# root design
#---- --------------------------------------------------------------------
create_bd_design mb_ctrl
current_bd_design mb_ctrl

# ---- external ports ----
set clkport [create_bd_port -dir I -type clk clk_100m]
set_property CONFIG.FREQ_HZ 100000000 $clkport
set rstport [create_bd_port -dir I -type rst ext_reset_in]
set_property CONFIG.POLARITY ACTIVE_HIGH $rstport
create_bd_port -dir I uart_rxd
create_bd_port -dir O uart_txd

# ---- MicroBlaze (project_1 四参数) ----
set mb [create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze:11.0 microblaze_0]
set_property -dict [list CONFIG.C_DEBUG_ENABLED {1} CONFIG.C_D_AXI {1} \
    CONFIG.C_D_LMB {1} CONFIG.C_I_LMB {1}] $mb
create_hier_cell_microblaze_0_local_memory [current_bd_instance .] microblaze_0_local_memory
create_bd_cell -type ip -vlnv xilinx.com:ip:mdm:3.2 mdm_1

# ---- reset (high-active external, no clk_wiz) ----
set psr [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_100m]
# polarity: 2023.1 uses the connected PORT's polarity (ACTIVE_HIGH above)
set xl [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_1]

# ---- fabric + peripherals ----
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {1}] [get_bd_cells smartconnect_0]
set u [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 axi_uartlite_0]
set_property -dict [list CONFIG.C_BAUDRATE {9600}] $u
create_bd_cell -type module -reference axi_lite_regs axi_lite_regs_0
puts "BD_STEP: cells created"

# ---- interface connections ----
connect_bd_intf_net [get_bd_intf_pins microblaze_0/M_AXI_DP] [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] [get_bd_intf_pins axi_uartlite_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M01_AXI] [get_bd_intf_pins axi_lite_regs_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins mdm_1/MBDEBUG_0] [get_bd_intf_pins microblaze_0/DEBUG]
connect_bd_intf_net [get_bd_intf_pins microblaze_0/DLMB] [get_bd_intf_pins microblaze_0_local_memory/DLMB]
connect_bd_intf_net [get_bd_intf_pins microblaze_0/ILMB] [get_bd_intf_pins microblaze_0_local_memory/ILMB]
puts "BD_STEP: interfaces connected"

# ---- port connections ----
connect_bd_net [get_bd_ports uart_rxd] [get_bd_pins axi_uartlite_0/rx]
connect_bd_net [get_bd_pins axi_uartlite_0/tx] [get_bd_ports uart_txd]
connect_bd_net [get_bd_pins xlconstant_1/dout] [get_bd_pins rst_100m/dcm_locked]
connect_bd_net [get_bd_pins mdm_1/Debug_SYS_Rst] [get_bd_pins rst_100m/mb_debug_sys_rst]
connect_bd_net [get_bd_ports ext_reset_in] [get_bd_pins rst_100m/ext_reset_in]
connect_bd_net [get_bd_pins rst_100m/bus_struct_reset] [get_bd_pins microblaze_0_local_memory/SYS_Rst]
connect_bd_net [get_bd_pins rst_100m/mb_reset] [get_bd_pins microblaze_0/Reset]
connect_bd_net [get_bd_ports clk_100m] \
    [get_bd_pins microblaze_0/Clk] \
    [get_bd_pins microblaze_0_local_memory/LMB_Clk] \
    [get_bd_pins rst_100m/slowest_sync_clk] \
    [get_bd_pins mdm_1/CLK] \
    [get_bd_pins smartconnect_0/aclk] \
    [get_bd_pins axi_uartlite_0/s_axi_aclk] \
    [get_bd_pins axi_lite_regs_0/aclk]
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] \
    [get_bd_pins smartconnect_0/aresetn] \
    [get_bd_pins axi_uartlite_0/s_axi_aresetn] \
    [get_bd_pins axi_lite_regs_0/aresetn]
puts "BD_STEP: nets connected"

# ---- user_clk-domain side of lite_regs: all pins external ----
foreach pin {clk_user rst_user_n u_wr_frame u_rd_frame u_buf_drop ctl_owner \
             cfg_mode cfg_rd_slot rd_req_pulse cfg_wr_pulse \
             lite_exec_cnt lite_rd_trig_cnt} {
    make_bd_pins_external [get_bd_pins axi_lite_regs_0/$pin]
    set_property name $pin [get_bd_ports ${pin}_0]
}
puts "BD_STEP: user-domain pins externalized"

# ---- address map (project_1 语法) ----
assign_bd_address -offset 0x40600000 -range 0x00010000 -target_address_space [get_bd_addr_spaces microblaze_0/Data] [get_bd_addr_segs axi_uartlite_0/S_AXI/Reg] -force
assign_bd_address -offset 0x00000000 -range 0x00010000 -target_address_space [get_bd_addr_spaces microblaze_0/Data] [get_bd_addr_segs microblaze_0_local_memory/dlmb_bram_if_cntlr/SLMB/Mem] -force
assign_bd_address -offset 0x00000000 -range 0x00010000 -target_address_space [get_bd_addr_spaces microblaze_0/Instruction] [get_bd_addr_segs microblaze_0_local_memory/ilmb_bram_if_cntlr/SLMB/Mem] -force
set lite_segs [get_bd_addr_segs -quiet axi_lite_regs_0/*]
puts "BD_STEP: lite_regs addr segs = $lite_segs"
if {[llength $lite_segs] == 0} {
    set lite_segs [get_bd_addr_segs -quiet -of_objects [get_bd_cells axi_lite_regs_0]]
    puts "BD_STEP: lite_regs addr segs (alt) = $lite_segs"
}
if {[llength $lite_segs] == 0} { error "BD: no address segment found on axi_lite_regs_0" }
assign_bd_address -offset 0x44A00000 -range 0x00001000 -target_address_space [get_bd_addr_spaces microblaze_0/Data] $lite_segs -force
puts "BD_STEP: addresses assigned"

validate_bd_design
save_bd_design

# ---- wrapper as design source; top stays aurora_mem_bridge ----
set wrapper [make_wrapper -files [get_files mb_ctrl.bd] -top]
add_files -norecurse -fileset sources_1 $wrapper
set_property top aurora_mem_bridge [current_fileset]
update_compile_order -fileset sources_1

puts "BD_DONE: wrapper=$wrapper top=[get_property TOP [current_fileset]]"
