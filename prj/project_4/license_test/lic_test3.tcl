# 验证链路2：Implementation 许可（xcku060）
# 综合许可已实测 OK；实现是构建位流的另一半，同样必须过
create_project -in_memory -part xcku060-ffva1156-2-i
read_verilog D:/FPGA/prj/project_4/license_test/tiny.v
if {[catch {synth_design -top tiny -part xcku060-ffva1156-2-i} e]} {
    puts "SYNTH_RESULT: FAIL"
    puts "SYNTH_ERR: $e"
} else {
    puts "SYNTH_RESULT: OK"
    # 综合成功才试实现（opt_design 是实现链第一步，需要 Implementation 许可）
    if {[catch {opt_design} e2]} {
        puts "IMPL_RESULT: FAIL"
        puts "IMPL_ERR: $e2"
    } else {
        puts "IMPL_RESULT: OK"
    }
}
puts "LIC_TEST2_DONE"
