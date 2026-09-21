open_checkpoint D:/FPGA/project_9/scripts/pre_impl_debug.dcp
foreach n {dbg_ch_up_b dbg_lane_up_b dbg_echo_b_ovf dbg_b_rx_tvalid dbg_b_tx_tvalid dbg_ch_up dbg_hard_err} {
    set r [get_nets -quiet [list $n]]
    if {[llength $r] == 0} {
        puts "NET_MISSING: $n"
        set alt [get_nets -quiet -filter "NAME =~ *${n}*"]
        foreach a $alt { puts "NET_ALT: $a" }
    } else {
        puts "NET_OK: $n -> [llength $r]"
    }
}
exit