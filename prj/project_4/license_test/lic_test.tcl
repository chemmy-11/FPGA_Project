# 决定性试验：显式指向 license 文件后，xcku060 能否综合
puts "LICFILE_ENV=$::env(XILINXD_LICENSE_FILE)"
create_project -in_memory -part xcku060-ffva1156-2-i
read_verilog D:/FPGA/prj/project_4/license_test/tiny.v
if {[catch {synth_design -top tiny -part xcku060-ffva1156-2-i} e]} {
    puts "SYNTH_RESULT: FAIL"
    puts "SYNTH_ERR: $e"
} else {
    puts "SYNTH_RESULT: OK"
}
puts "LIC_TEST_DONE"
