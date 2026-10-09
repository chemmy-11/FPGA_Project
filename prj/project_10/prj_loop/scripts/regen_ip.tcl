# regen_ip.tcl -- 重新生成工程内所有 IP 的输出产物
# 背景: build_l2_v3 前清理 prj_loop.gen 时, Aurora IP 的生成产物一并被删,
#       导致顶层综合找不到 module 'aurora_64b66b_0' (Synth 8-439)。
set proj D:/FPGA/prj/project_10/prj_loop
open_project $proj/vivado/prj_loop.xpr
set ips [get_ips -quiet]
puts "IP_COUNT: [llength $ips]"
foreach ip $ips {
    puts "REGEN_TARGET: $ip"
    if {[catch {generate_target all [get_ips $ip]} e]} {
        puts "REGEN_WARN: $ip -> $e"
    }
}
foreach ip $ips {
    if {[catch {synth_ip [get_ips $ip]} e]} {
        puts "SYNTH_IP_WARN: $ip -> $e"
    } else {
        puts "SYNTH_IP_OK: $ip"
    }
}
close_project
puts "REGEN_IP_DONE"