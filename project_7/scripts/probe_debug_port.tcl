open_project D:/FPGA/project_7/prj/project_7.xpr
open_run synth_1 -name synth_1
create_debug_core u_ilatest ila
puts "PORTS_AFTER_CORE: [get_debug_ports -quiet u_ilatest/*]"
set r1 [catch {create_debug_port -type data u_ilatest} e1]
puts "V_data: rc=$r1 err=$e1"
puts "PORTS_AFTER_DATA: [get_debug_ports -quiet u_ilatest/*]"
set r2 [catch {create_debug_port u_ilatest} e2]
puts "V_plain: rc=$r2 err=$e2"
puts "PORTS_FINAL: [get_debug_ports -quiet u_ilatest/*]"
puts "PROBE_DONE"
