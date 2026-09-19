proc chk {dcp tag} {
    open_checkpoint $dcp
    foreach sig {gmii_tx_en gmii_txd} {
        set pin [get_pins -quiet "u_gmii_to_rgmii/$sig"]
        if {[llength $pin] == 0} { puts "== $tag  $sig : pin not found"; continue }
        set net [get_nets -quiet -of_objects $pin]
        puts "== $tag  $sig  net=[get_property NAME $net]"
        set drvs [get_pins -quiet -of_objects $net -filter {DIRECTION == OUT}]
        foreach d $drvs { puts "     driver: $d" }
    }
    close_design
}
chk D:/FPGA/project_8/scripts/post_route_txdirect.dcp TXDIRECT
chk D:/FPGA/project_8/scripts/post_route.dcp NORMAL
puts "VERIFY2_DONE"
