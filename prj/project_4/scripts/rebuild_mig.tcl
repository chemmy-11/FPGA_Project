# rebuild_mig.tcl -- prj4 D1: reset-polarity fixed rebuild
set proj D:/FPGA/prj/project_4
open_project $proj/mig_ddr4_cal.xpr
reset_run synth_1
reset_run impl_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
puts "SYNTH: [get_property STATUS [get_runs synth_1]] / [get_property PROGRESS [get_runs synth_1]]"
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "synth failed" }
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "IMPL: [get_property STATUS [get_runs impl_1]] / [get_property PROGRESS [get_runs impl_1]]"
report_timing_summary -file $proj/rebuild_timing.rpt -quiet
puts "TIMING_SUMMARY_DONE"
exit
