# create_project.tcl — 创建 Vivado 工程 + MicroBlaze 最小系统 Block Design
# 用法: "D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat" -mode batch -source scripts/create_project.tcl
# 产出: hw/mb_minimal.xpr + hw/mb_minimal.srcs/sources_1/bd/bd_mb_minimal/
# 为什么: Tcl-first 模式，整个工程可用脚本重建（可追溯、可复现），
#         对应阶段一文档 §3（Vivado GUI 建工程 + Block Design 的脚本版）。

# ================= 用户参数（⚠️ 按板卡手册确认） =================
# part 全名：用 scripts/env_check.tcl 查询，当前默认 ffva1156 封装的 -2 商业级
# ⚠️ TODO: 以开发板丝印为准（如 XCKU060-FFVA1156-2E），不一致会导致综合/下载报错
set part          "xcku060-ffva1156-2-e"
set project_name  "mb_minimal"
set project_dir   "hw"

# ================= 1. 创建工程 =================
create_project $project_name $project_dir -part $part -force
# 为什么 -force: 脚本可重复执行，重跑时直接覆盖旧工程（旧工程在 git 里可追溯）
set_property target_language Verilog [current_project]

# ================= 2. 创建 MicroBlaze 最小系统 BD =================
# BD 内容见 bd_mb_minimal.tcl（Local Memory + UART + AXI Interconnect）
source scripts/bd_mb_minimal.tcl

# ================= 3. 保存并关闭 =================
save_bd_design
close_project
puts "=== create_project.tcl 完成: ${project_dir}/${project_name}.xpr ==="
