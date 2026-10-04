open_checkpoint scripts/post_route.dcp
write_debug_probes -force scripts/probes.ltx
write_bitstream -force out/aurora_mem_bridge.bit
puts "BIT_DONE"
exit
