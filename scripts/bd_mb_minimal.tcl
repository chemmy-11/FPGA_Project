# bd_mb_minimal.tcl — MicroBlaze 最小系统 Block Design
# 被 create_project.tcl source；也可单独在已有工程里 source（先打开工程）。
# 内容: MicroBlaze + Local Memory(64KB, 无缓存) + AXI UART Lite(115200)
#       + AXI Interconnect + MDM(JTAG 调试) + Clocking Wizard + Processor System Reset
# 对应: 阶段一文档 §3.2~3.6（GUI 版 Run Block Automation 的脚本等价物）

# ================= 板卡参数（⚠️ TODO: 以开发板手册为准） =================
# 板载晶振频率（MHz）与类型——Clocking Wizard 的输入
# 常见: 200MHz 单端 / 125MHz 差分；错了会综合报错或时钟不稳
set clk_in_freq_mhz 200
set clk_in_type     "single"     ;# "single" 单端 | "diff" 差分（差分需要 create_bd_pin 对）

# ================= 1. 创建 BD =================
set bd_name "bd_mb_minimal"
create_bd_design $bd_name

# ================= 2. MicroBlaze + Run Block Automation（脚本版） =================
create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze microblaze_0

# config 字段含义（对应 GUI 的 Block Automation 弹窗）:
#   local_mem    64KB   — 本地 BRAM，够跑 Hello World（后续 DMA 代码需加大）
#   cache        None   — 最小系统无缓存（阶段一文档: Cache Configuration: None）
#   debug_module Debug Only — 带 MDM，Vitis 才能通过 JTAG 下载程序（关键！）
#   axi_periph   Enabled — 需要 AXI 总线接外设（UART）
#   axi_intc     0      — 暂不接中断控制器（阶段 4 再加）
apply_bd_automation -rule xilinx.com:bd_rule:microblaze \
    -config {axi_lite_port {Auto} axi_intc {0} axi_periph {Enabled} cache {None} debug_module {Debug Only} ecc {None} local_mem {64KB} preset {None}} \
    [get_bd_cells microblaze_0]

# ===== 诊断：打印 automation 产物（正常后保留无妨）=====
puts "=== automation cells: [get_bd_cells] ==="
puts "=== automation ports: [get_bd_ports] ==="
puts "=== microblaze CLK 网络: [get_bd_nets -of_objects [get_bd_pins microblaze_0/CLK]] ==="

# ================= 3. 添加 AXI UART Lite（串口打印 Hello World 用） =================
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite axi_uartlite_0
# 波特率 115200 与阶段一文档 §4.3 PuTTY 设置一致
set_property -dict [list CONFIG.C_BAUDRATE 115200] [get_bd_cells axi_uartlite_0]

# 把 UART 的 AXI 从端口接到 microblaze_0 的外设互连（脚本版自动连线）
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/microblaze_0 (Periph)" intc_ip {Auto} Clk_xbar {Auto} Clk_master {Auto} Clk_slave {Auto}} \
    [get_bd_intf_pins axi_uartlite_0/S_AXI]

# ================= 4. UART 引脚引出为外部端口 =================
# 为什么: 串口要连到物理引脚，XDC 里按板卡原理图绑定
create_bd_port -dir I uart_rx
create_bd_port -dir O uart_tx
connect_bd_net [get_bd_pins axi_uartlite_0/rx] [get_bd_ports uart_rx]
connect_bd_net [get_bd_pins axi_uartlite_0/tx] [get_bd_ports uart_tx]

# ================= 5. 时钟配置 =================
# 无 board 时 automation 生成的 clk_wiz 名字带序号后缀（如 clk_wiz_1），
# 不硬编码，按 IP 类型动态获取。
set clk_wiz_cell [lindex [get_bd_cells -filter {VLNV =~ *clk_wiz*}] 0]
puts "=== 时钟模块: $clk_wiz_cell（输出 100MHz 给 MicroBlaze）==="
# 输入时钟设为板载晶振频率（automation 默认 100MHz，按实际板卡改）
# ⚠️ TODO: 差分晶振时 PRIM_SOURCE 改 Differential_clock_capable_pin，
#          并建 clk_in1_p/clk_in1_n 一对端口
set_property -dict [list \
    CONFIG.PRIM_SOURCE Single_ended_clock_capable_pin \
    CONFIG.PRIM_IN_FREQ ${clk_in_freq_mhz}.000 \
] [get_bd_cells $clk_wiz_cell]

# clk_in1 引出为外部端口（板载晶振入口，XDC 里绑物理引脚）
# 为什么 -freq_hz: 端口频率必须与 clk_wiz 输入一致，否则 validate 报 FREQ_HZ mismatch
create_bd_port -dir I -type clk -freq_hz [expr {$clk_in_freq_mhz * 1000000}] clk_in1_0
connect_bd_net [get_bd_pins ${clk_wiz_cell}/clk_in1] [get_bd_ports clk_in1_0]

# ================= 6. 复位引脚引出 =================
# 无 board 时 rst 模块名也带时钟后缀（rst_clk_wiz_1_100M），动态获取
set rst_cell [lindex [get_bd_cells -filter {VLNV =~ *proc_sys_reset*}] 0]
puts "=== 复位模块: $rst_cell ==="
# 若 automation 已把 ext_reset_in 连到内部网，先断开再接管为外部端口
foreach net [get_bd_nets -quiet -of_objects [get_bd_pins ${rst_cell}/ext_reset_in]] {
    disconnect_bd_net -net $net [get_bd_pins ${rst_cell}/ext_reset_in]
}
create_bd_port -dir I -type rst ext_reset_in
connect_bd_net [get_bd_pins ${rst_cell}/ext_reset_in] [get_bd_ports ext_reset_in]

# ================= 7. 校验设计 =================
# 为什么: 对应 GUI 的 Validate Design（F6），必须 0 错误才能继续
validate_bd_design

puts "=== bd_mb_minimal 创建完成 ==="
puts "外部端口: [get_bd_ports]"
