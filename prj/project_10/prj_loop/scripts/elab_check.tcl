open_project vivado/prj_loop.xpr
synth_design -rtl -top aurora_mem_bridge -name rtl_check
puts "ELAB_OK"
exit
