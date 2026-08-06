# env_check.tcl — 环境验证：Vivado 版本 + XCKU060 可用 part 列表
# 用法: vivado -mode batch -source scripts/env_check.tcl
# 为什么: 写 create_project.tcl 前确认 part 全名（封装/速度等级），
#         避免建工程时 part 不存在报错；同时确认 License 支持 UltraScale。
puts "=== Vivado version: [version -short] ==="
puts "=== All XCKU060 parts ==="
foreach p [lsort [get_parts -filter {NAME =~ *xcku060*}]] { puts $p }
puts "=== End ==="
