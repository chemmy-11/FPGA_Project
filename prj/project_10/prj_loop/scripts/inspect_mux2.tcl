open_checkpoint D:/FPGA/prj/project_10/prj_loop/scripts/post_route.dcp
puts {=== cmd_takeover_i_1 (LUT3) 输入与 INIT ===}
set c [get_cells -hier -quiet cmd_takeover_i_1]
puts "REF=[get_property REF_NAME $c] INIT=[get_property -quiet INIT $c]"
foreach p [get_pins -quiet -of_objects $c] {
    set n [get_nets -quiet -of_objects $p]
    set dir [get_property -quiet DIRECTION $p]
    puts "  PIN [get_property REF_PIN_NAME $p] DIR=$dir NET=$n"
}
puts {=== cmd_takeover_reg D/CE/C ===}
foreach pn {D CE C Q} {
    set p [get_pins -hier -quiet cmd_takeover_reg/$pn]
    if {$p ne {}} {
        set n [get_nets -quiet -of_objects $p]
        puts "  $pn NET=$n"
    }
}
puts {=== u_cmd/tx_idle 输入脚接的网 ===}
foreach p [get_pins -hier -quiet -filter {NAME =~ *u_cmd/tx_idle*}] {
    set n [get_nets -quiet -of_objects $p]
    puts "  PIN $p NET=$n"
}
puts {=== tx_idle_cnt_reg[6]/Q 扇出 ===}
set q [get_pins -hier -quiet tx_idle_cnt_reg[6]/Q]
set n [get_nets -quiet -of_objects $q]
puts "  Q NET=$n"
foreach p [get_pins -quiet -of_objects $n -filter {DIRECTION == IN}] { puts "    -> $p" }
puts {=== cmd_resp_busy 网与其所有输入脚 ===}
foreach p [get_pins -hier -quiet -filter {NAME =~ *u_cmd/resp_busy*}] {
    set n [get_nets -quiet -of_objects $p]
    puts "  PIN $p NET=$n DIR=[get_property -quiet DIRECTION $p]"
}
puts {INSPECT2_DONE}