open_project D:/FPGA/project_4/mig_ddr4_cal.xpr
set ip [get_ips ddr4_0]
puts "CUR=[get_property CONFIG.Debug_Signal $ip]"
puts "VALS=[list_property_value CONFIG.Debug_Signal $ip]"
puts "PROBE_DONE"
