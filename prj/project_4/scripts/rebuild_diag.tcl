# rebuild_diag.tcl -- prj4 D1: ILA 加读回数据探针(诊断 err=N-1)
set proj D:/FPGA/prj/project_4
open_project $proj/mig_ddr4_cal.xpr
set_property CONFIG.C_NUM_OF_PROBES 7 [get_ips ila_mig]
set_property CONFIG.C_PROBE5_WIDTH 256 [get_ips ila_mig]
set_property CONFIG.C_PROBE6_WIDTH 4 [get_ips ila_mig]
set_property CONFIG.C_ADV_TRIGGER false [get_ips ila_mig]
generate_target all [get_ips ila_mig]
if {[llength [get_runs -quiet ila_mig_synth_1]] > 0} { reset_run ila_mig_synth_1 }
reset_run synth_1
reset_run impl_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
puts "SYNTH: [get_property STATUS [get_runs synth_1]]"
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "synth failed" }
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "IMPL: [get_property STATUS [get_runs impl_1]] / [get_property PROGRESS [get_runs impl_1]]"
exit
