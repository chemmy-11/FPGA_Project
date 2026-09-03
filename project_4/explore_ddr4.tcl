open_project D:/FPGA/project_4/mig_ddr4_cal.xpr
set ip [get_ips ddr4_0]
set fh [open D:/FPGA/project_4/ddr4_props3.txt w]
# 重设全部核心参数（这次一次配平，InputClockPeriod 用合法值 9996）
foreach pair {
  {CONFIG.C0.DDR4_MemoryPart {MT40A512M16HA-083E}}
  {CONFIG.C0.DDR4_DataWidth 64}
  {CONFIG.C0.DDR4_AxiSelection true}
  {CONFIG.C0.DDR4_AxiDataWidth 512}
  {CONFIG.C0.DDR4_TimePeriod 833}
  {CONFIG.C0.DDR4_InputClockPeriod 9996}
  {CONFIG.System_Clock {Differential}}
  {CONFIG.Reference_Clock {No Buffer}}
  {CONFIG.C0.DDR4_MemoryVoltage {1.2V}}
} {
  set p [lindex $pair 0]; set v [lindex $pair 1]
  if {[catch {set_property $p $v $ip} e]} { puts $fh "SETFAIL $p = $v => $e" } else { puts $fh "SETOK   $p = $v" }
}
# 全量属性落盘（修正 get_property 参数顺序：属性在前、对象在后）
set props [lsort [list_property $ip CONFIG.*]]
puts $fh "=== TOTAL: [llength $props] ==="
foreach p $props {
  if {[catch {set v [get_property $p $ip]} e]} { set v "ERR" }
  puts $fh "$p = $v"
}
close $fh
puts "DUMP3_DONE"
