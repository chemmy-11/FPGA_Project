#=============================================================================
# synth_d1_scratch.tcl -- ONE-SHOT scratch synthesis for the W2 review (D1)
# Purpose: decide whether the double procedural driver on out_inc/out_dec in
#          rtl/axi4_master_bridge.v is accepted by Vivado (silent / warning)
#          or rejected (CRITICAL WARNING / ERROR).
# No project is created (-mode batch, non-project flow). Nothing under
# project_10 is modified except this script + its log.
#=============================================================================
set part_name xcku060-ffva1156-2-i
puts "=== D1 SCRATCH SYNTH START (part $part_name) ==="
read_verilog -sv {D:/FPGA/prj/project_10/rtl/axi4_master_bridge.v}
synth_design -top axi4_master_bridge -part $part_name -mode out_of_context
puts "=== D1 SCRATCH SYNTH DONE ==="
puts "MSGCOUNT [llength [get_msg_config -severity {CRITICAL WARNING} -count]]"
exit
