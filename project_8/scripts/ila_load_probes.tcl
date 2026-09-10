# =============================================================================
# ila_load_probes.tcl — 给已烧录的板卡关联 ILA 探针文件
#
# 解决报错：
#   "Use the Refresh Device command with a valid Probes (debug_nets.ltx) file
#    before executing the command: Run Trigger"
# 原因：位流里的 ILA 已经在了，但 Vivado 不知道 probe0 各位是什么信号 ——
#       必须把生成位流时一并写出的 probes.ltx 关联到"设备"，再 Refresh Device。
#
# 用法（GUI 已开着 Hardware Manager 也可以直接跑；脚本会自己连 hw_server）:
#   cd D:\FPGA\project_8
#   vivado -mode batch -source scripts\ila_load_probes.tcl -notrace
#
# GUI 等价操作（推荐新手走一遍建立直觉）:
#   1) Hardware Manager 里选中最上面的器件（xcku060_0）
#   2) 左下 Properties 面板 → Probes File → 选 scripts\probes.ltx
#      （Full Probes File 一栏同样选它）
#   3) 右键该器件 → Refresh Device
#   4) 树里 hw_ila_1 / hw_ila_2 就能展开看到 probe0，Run Trigger 可用
# =============================================================================
set ltx {D:/FPGA/project_8/scripts/probes.ltx}

open_hw_manager
connect_hw_server
open_hw_target

set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
puts "HW_DEVICE: [get_property NAME $dev]  part=[get_property PART $dev]"

# 关联探针文件（两个属性都要设：PROBES.FILE 用于波形名，FULL_PROBES.FILE 用于完整映射）
set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device -update_hw_probes true $dev

puts "=== ILA 列表（cell 名即 RTL 里的实例名）==="
foreach ila [get_hw_ilas -of_objects $dev] {
    set cn "(unknown)"
    catch { set cn [get_property CELL_NAME $ila] }
    puts "  [get_property NAME $ila]   cell=$cn"
}

puts "=== 探针位表（与 build_debug.tcl 注释一致）==="
puts "  ILA @ user_clk (u_ila_0) probe0[175:0] ="
puts "    [63:0]rx_tdata [71:64]rx_tkeep [72]rx_tvalid [73]rx_tlast"
puts "    [89:74]unpack_frames [105:90]unpack_bytes [106]unpack_ovf [122:107]unpack_stall"
puts "    [138:123]pack_frames [139]pack_ovf [155:140]pump_rev_wr [171:156]pump_rev_drop"
puts "    [172]channel_up [173]lane_up [174]hard_err [175]soft_err"
puts "  ILA @ eth_rxc (u_ila_1) probe0[32:0] ="
puts "    [15:0]pump_fwd_wr [31:16]pump_fwd_drop [32]stack_tx_en"
puts ""
puts "提示：探针是按'先列=低位'拼的；若波形里字段位序颠倒，按上表反着解析即可。"
puts "PROBES_LOADED_OK"
