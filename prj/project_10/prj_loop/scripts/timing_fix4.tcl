set proj D:/FPGA/prj/project_10/prj_loop
open_checkpoint $proj/scripts/pre_impl_debug.dcp
implement_debug_core
opt_design
place_design -directive ExtraTimingOpt
phys_opt_design -directive ExploreWithHoldFix
route_design -directive NoTimingRelaxation
phys_opt_design -directive AggressiveExplore
report_timing_summary -delay_type min_max -max_paths 10 -file $proj/out/rpt_timing_summary_fix4.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -sort_by slack]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -sort_by slack]]
puts "WNS_FIX4: $wns"
puts "WHS_FIX4: $whs"
if {$wns >= 0 && $whs >= 0} {
    write_checkpoint -force $proj/scripts/post_route.dcp
    write_debug_probes -force $proj/scripts/probes.ltx
    write_bitstream -force $proj/out/aurora_mem_bridge.bit
    puts "BITSTREAM_OK: constraints met"
} else {
    puts "STILL_NEGATIVE: wns=$wns whs=$whs"
}