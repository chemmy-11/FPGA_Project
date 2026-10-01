# =============================================================================
# uiclk_build.tcl -- A5: synth + impl + timing for the W3 pre-flight design
# 判读三分支（W3 开工文档 §二 A5）：WNS>=0 出位流；<0 但 >-0.5ns 优化重跑；
# 仍 <0 → 停下上报（#14 BRAM v2 回退是路线决策点）。
# =============================================================================
open_project D:/FPGA/project_10/prj_uiclk/vivado/prj_uiclk.xpr

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { puts "SYNTH_FAILED"; exit 1 }
open_run synth_1 -name synth_1
report_utilization -file D:/FPGA/project_10/prj_uiclk/report_util_synth.rpt
puts "SYNTH_DONE"

launch_runs impl_1 -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} { puts "IMPL_FAILED"; exit 1 }
open_run impl_1
report_timing_summary -file D:/FPGA/project_10/prj_uiclk/report_timing.rpt
report_utilization -file D:/FPGA/project_10/prj_uiclk/report_util_impl.rpt
puts "IMPL_DONE"

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "TIMING_WNS=$wns"
puts "TIMING_WHS=$whs"
puts "A5_PREFLIGHT_DONE"