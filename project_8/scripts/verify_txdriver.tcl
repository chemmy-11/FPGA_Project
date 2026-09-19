# verify_txdriver.tcl - 查 eth_tx_ctl 端口的驱动源，确认 TX 直连是否生效
proc chk {dcp tag} {
    open_checkpoint $dcp
    set net [get_nets -quiet -of_objects [get_ports eth_tx_ctl]]
    puts "== $tag  net=[get_property NAME $net]"
    foreach p [get_pins -quiet -of_objects $net -filter {DIRECTION == OUT}] {
        puts "   driver pin: $p"
    }
    foreach p [get_pins -quiet -of_objects $net -filter {DIRECTION == IN}] {
        puts "   load   pin: $p"
    }
    close_design
}
chk D:/FPGA/project_8/scripts/post_route_txdirect.dcp TXDIRECT
chk D:/FPGA/project_8/scripts/post_route.dcp NORMAL
puts "VERIFY_DONE"
