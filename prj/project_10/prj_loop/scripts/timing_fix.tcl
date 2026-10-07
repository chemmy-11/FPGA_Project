set proj D:/FPGA/prj/project_10/prj_loop
open_checkpoint $proj/scripts/post_route.dcp
phys_opt_design -directive AggressiveExplore
report_timing_summary -delay_type min_max -max_paths 10 -file $proj/out/rpt_timing_summary_fix.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -sort_by slack]]
puts "WNS_AFTER_FIX: $wns"
if {$wns >= 0} {
    write_bitstream -force $proj/out/aurora_mem_bridge.bit
    puts "BITSTREAM_REWRITTEN: WNS OK"
} else {
    puts "WNS_STILL_NEGATIVE: $wns"
}