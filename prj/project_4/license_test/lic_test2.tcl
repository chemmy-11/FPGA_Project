# 决定性试验 v2：不读环境变量，直接试综合
create_project -in_memory -part xcku060-ffva1156-2-i
read_verilog D:/FPGA/prj/project_4/license_test/tiny.v
if {[catch {synth_design -top tiny -part xcku060-ffva1156-2-i} e]} {
    puts "SYNTH_RESULT: FAIL"
} else {
    puts "SYNTH_RESULT: OK"
}
puts "DONE"
