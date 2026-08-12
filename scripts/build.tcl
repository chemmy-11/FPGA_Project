# build.tcl — 综合 → 实现 → 生成 bitstream → 导出 .xsa
# 用法: "D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat" -mode batch -source scripts/build.tcl
# 前置: 先跑 create_project.tcl 生成工程
# 产出: hw/mb_minimal.runs/impl_1/mb_minimal.bit + hw/mb_minimal.xsa
# 为什么: 对应阶段一文档 §3.8（Run Synthesis → Run Implementation → Generate Bitstream）
#         与 §3.9（Export Hardware with bitstream）的脚本版。

# ================= 1. 打开工程 =================
open_project hw/mb_minimal.xpr

# ================= 2. 加入约束文件（若存在） =================
# 阶段一文档 §3.7: UART/时钟引脚绑定到物理引脚（板卡原理图确认后填写）
# ⚠️ 未确认板卡引脚前，XDC 留空也可综合（引脚默认未分配，不影响 bitstream 生成，
#    但下载到板卡前必须补全）
if {[file exists constr/ku060_pins.xdc]} {
    add_files -fileset constrs_1 -norecurse constr/ku060_pins.xdc
    puts "=== 已加入约束: constr/ku060_pins.xdc ==="
} else {
    puts "=== 提示: constr/ku060_pins.xdc 不存在，跳过约束（上板前必须补引脚约束） ==="
}

# ================= 3. 生成 BD 输出产物 =================
# 为什么: Block Design 需要先 generate output products（各 IP 的网表/仿真模型），
#         对应 GUI 里 Sources → design_1 右键 → Generate Output Products
generate_target all [get_files  hw/mb_minimal.srcs/sources_1/bd/bd_mb_minimal/bd_mb_minimal.bd]

# ================= 4. 综合 =================
# 为什么 -jobs: 用多核并行，快一点（核数从环境变量读）
set jobs [expr {[info exists env(NUMBER_OF_PROCESSORS)] ? $env(NUMBER_OF_PROCESSORS) : 4}]
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] != "synth_design Complete"} {
    error "综合失败，请查看 hw/mb_minimal.runs/synth_1/runme.log"
}
puts "=== 综合完成 ==="

# ================= 5. 实现（布局布线）→ bitstream =================
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] != "impl_1 write_bitstream Complete"} {
    error "实现/bitstream 失败，请查看 hw/mb_minimal.runs/impl_1/runme.log"
}
puts "=== bitstream 生成成功 ==="

# ================= 6. 导出 .xsa（含 bitstream） =================
# 为什么: .xsa 是 Vivado → Vitis 的桥梁；对应 GUI 的 File → Export Hardware
#         勾选 Include bitstream（阶段一文档 §3.9，不勾 Vitis 里没法下载）
write_hw_platform -fixed -include_bit -force -file hw/mb_minimal.xsa
puts "=== .xsa 导出成功: hw/mb_minimal.xsa ==="

close_project
puts "=== build.tcl 全部完成 ==="
