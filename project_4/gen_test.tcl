open_project D:/FPGA/project_4/mig_ddr4_cal.xpr
set ip [get_ips ddr4_0]
if {[catch {generate_target all [get_ips ddr4_0]} e]} {
  puts "GEN_FAIL: $e"
} else { puts "GEN_OK" }
# ???????? xdc ???? PACKAGE_PIN
if {[catch {
  set xdc [glob -nocomplaint D:/FPGA/project_4/mig_ddr4_cal.gen/sources_1/ip/ddr4_0/*.xdc]
  foreach f $xdc { puts "XDCFILE: $f" }
} e]} { puts "GLOB_ERR: $e" }
