open_project D:/FPGA/project_4/mig_ddr4_cal.xpr
# sources + constraints (idempotent)
if {[catch {add_files -fileset sources_1 D:/FPGA/project_4/mig_verify_top.v} e]} { puts "ADD_V_SKIP: $e" }
if {[catch {add_files -fileset constrs_1 D:/FPGA/project_4/mig_verify_pins.xdc} e]} { puts "ADD_XDC_SKIP: $e" }
# ILA (idempotent)
if {[catch {create_ip -name ila -vendor xilinx.com -library ip -module_name ila_mig} e]} { puts "ILA_SKIP: $e" }
set ila [get_ips ila_mig]
set_property CONFIG.C_DATA_DEPTH 1024 $ila
set_property CONFIG.C_NUM_OF_PROBES 5 $ila
set_property CONFIG.C_PROBE0_WIDTH 3 $ila
set_property CONFIG.C_PROBE1_WIDTH 16 $ila
set_property CONFIG.C_PROBE2_WIDTH 8 $ila
set_property CONFIG.C_PROBE3_WIDTH 8 $ila
set_property CONFIG.C_PROBE4_WIDTH 6 $ila
set_property CONFIG.C_TRIGIN_EN false $ila
set_property CONFIG.C_TRIGOUT_EN false $ila
set_property CONFIG.C_ADV_TRIGGER false $ila
set_property CONFIG.ALL_PROBE_SAME_MU true $ila
set_property CONFIG.ALL_PROBE_SAME_MU_CNT 1 $ila
# top + compile order
set_property top mig_verify_top [current_fileset]
update_compile_order -fileset sources_1
generate_target all [get_ips]
# build
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "IMPL_STATUS: [get_property STATUS impl_1]"
puts "IMPL_PROGRESS: [get_property PROGRESS impl_1]"
set bits [glob -nocomplaint D:/FPGA/project_4/mig_ddr4_cal.runs/impl_1/*.bit]
puts "BIT_FILES: $bits"
puts "BUILD_FLOW_DONE"
