# clk_delay.tcl - 量 eth_rxc pin -> IDDRE1 CLK 的时钟路径延迟
set dcp [lindex $argv 0]
set tag [lindex $argv 1]
open_checkpoint $dcp
puts "### $tag"
set p [get_pins -quiet u_gmii_to_rgmii/u_rgmii_rx/IDDRE1_inst/CLK]
if {![llength $p]} { puts "NOPIN" } else {
  foreach mode {max min} {
    set rpt [report_timing -quiet -from [get_ports eth_rxc] -to $p -delay_type $mode -max_paths 1 -return_string]
    foreach line [split $rpt "\n"] {
      if {[string match "*data path delay*" $line] || [string match "*(source*" $line] || [string match "*(destination*" $line] || [string match "*slack*" $line]} { puts "DATA: [$mode] $line" }
    }
  }
}
puts "###END"
close_design