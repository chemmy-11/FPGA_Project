# mini_synth_check.tcl — 单模块 OOC 综合（二分定位用）
# 用途: 判断某个 RTL 改动引发的综合失败是「纯 RTL 问题」还是「与全工程组合才触发」。
# 背景: 2026-10-07 夜 W5 cut-2（axi4_master_bridge 新增 R_PRE2 状态）触发 Vivado 2023.1
#       工程级综合崩溃（EXCEPTION_ACCESS_VIOLATION，3 次可复现），而本脚本对同一文件
#       综合通过 → 判定为与其它模块/IP 组合触发，而非 RTL 语法/结构非法。
# 用法: vivado -mode batch -source mini_synth_check.tcl -notrace -nojournal -nolog
# 判据: 末行 'synth_design completed successfully'（约 1 分钟）
read_verilog D:/FPGA/prj/project_10/rtl/axi4_master_bridge.v
synth_design -top axi4_master_bridge -part xcku060-ffva1156-2-i -mode out_of_context
exit