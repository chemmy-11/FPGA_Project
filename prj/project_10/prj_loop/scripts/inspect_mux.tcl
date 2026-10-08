# 查实现网表: cmd_takeover / tx_idle / RGMII TX mux 真实连接
open_checkpoint D:/FPGA/prj/project_10/prj_loop/scripts/post_route.dcp
puts {=== cmd_takeover nets/cells ===}
foreach n [get_nets -hier -quiet -filter {NAME =~ *cmd_takeover*}] { puts "NET $n" }
foreach c [get_cells -hier -quiet -filter {NAME =~ *cmd_takeover*}] { puts "CELL $c REF=[get_property REF_NAME $c]" }
puts {=== tx_idle cells ===}
foreach c [get_cells -hier -quiet -filter {NAME =~ *tx_idle*}] { puts "CELL $c REF=[get_property REF_NAME $c]" }
puts {=== rgmii tx en / pump_rev_en nets ===}
foreach pat {rgmii_tx_en_o rgmii_tx_en_i pump_rev_en cmd_resp_tx_en cmd_resp_busy} {
    foreach n [get_nets -hier -quiet -filter "NAME =~ *$pat*"] {
        set d [get_property -quiet DRIVER $n]
        puts "NET $n DRIVER=$d"
    }
}
puts {=== gmii_to_rgmii tx_en pin ===}
foreach p [get_pins -hier -quiet -filter {NAME =~ *u_gmii_to_rgmii*gmii_tx_en*}] {
    set n [get_nets -quiet -of_objects $p]
    puts "PIN $p NET=$n"
}
puts {=== gmii_to_rgmii txd pins (前 3) ===}
set i 0
foreach p [get_pins -hier -quiet -filter {NAME =~ *u_gmii_to_rgmii*gmii_txd*}] {
    if {$i < 3} { set n [get_nets -quiet -of_objects $p]; puts "PIN $p NET=$n" }
    incr i
}
puts {INSPECT_DONE}