open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
puts "=== wait_on_hw_ila -help ==="
catch { wait_on_hw_ila -help } e
puts $e
puts "=== hw_ila 属性 ==="
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
foreach pr [list_property $ila] {
    set v "?"
    catch { set v [get_property $pr $ila] }
    puts "  $pr = $v"
}
puts "PROBE_API_DONE"