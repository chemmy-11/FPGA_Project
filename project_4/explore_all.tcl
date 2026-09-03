open_project D:/FPGA/project_4/mig_ddr4_cal.xpr
set ip [get_ips ddr4_0]
set fh [open D:/FPGA/project_4/ddr4_allprops.txt w]
set props [lsort [list_property $ip]]
puts $fh "=== ALL PROPS: [llength $props] ==="
foreach p $props {
  if {[catch {set v [get_property $p $ip]} e]} { set v "ERR" }
  if {[string length $v] > 300} { set v "[string range $v 0 280] ...(len [string length $v])" }
  puts $fh "$p = $v"
}
close $fh
puts "ALLPROP_DONE"
