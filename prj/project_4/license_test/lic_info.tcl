puts "=== ENV ==="
foreach v {XILINXD_LICENSE_FILE LM_LICENSE_FILE XILINX_VIVADO XILINX} { if {[info exists ::env($v)]} { puts "$v = $::env($v)" } else { puts "$v = (unset)" } }
puts "=== 试综合并打印可用许可信息 ==="
catch {create_project -in_memory -part xcku060-ffva1156-2-i}
catch {synth_design -top tiny -part xcku060-ffva1156-2-i} e
puts "ERR=$e"
puts "LIC_INFO_DONE"
