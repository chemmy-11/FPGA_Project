set P D:/FPGA/prj/project_11
open_project $P/vivado/prj11.xpr
if {[llength [get_bd_designs -quiet mb_ctrl]]} { close_bd_design [get_bd_designs mb_ctrl] }
set old [get_files -quiet -filter {NAME =~ mb_ctrl.bd}]
if {[llength $old]} {
    set olddir [get_property DIRECTORY [lindex $old 0]]
    remove_files $old
    catch {file delete -force $olddir}
}
create_bd_design probe
create_bd_port -dir I -type clk clk_100m
set_property CONFIG.FREQ_HZ 100000000 [get_bd_ports clk_100m]
create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze:11.0 microblaze_0
foreach v {Debug "Basic Debug Module" "Extended Debug Module" "Debug & BIST" "Custom" "None"} {
    if {[catch {apply_bd_automation -rule xilinx.com:bd_rule:microblaze -config \
        [list local_mem "64KB" ecc "None" debug_module $v axi_periph "Disabled" axi_intc "Disabled" clk "clk_100m"] \
        [get_bd_cells microblaze_0]} emsg]} {
        puts "TRY-FAIL [$v]: $emsg"
    } else {
        puts "TRY-OK   [$v]"
        break
    }
}
exit
