# =============================================================================
# build_sw.tcl — prj11 B1: MicroBlaze software (Vitis classic via xsct)
#   platform <- out/mb_ctrl.xsa (build_debug.tcl 门限内导出)
#   app      <- "Empty Application (C)", sources from sw/src, main.c
# 产物: sw/hello_regs/Debug/hello_regs.elf
# 用法: D:\Xilinx\Vitis\2023.1\bin\xsct.bat D:\FPGA\prj\project_11\sw\build_sw.tcl
# 幂等: 平台与应用均 set -force 重建
# =============================================================================
set P D:/FPGA/prj/project_11

if {![file exists $P/out/mb_ctrl.xsa]} {
    error "XSA not found: $P/out/mb_ctrl.xsa (run build_debug.tcl first)"
}

cd $P/sw
setws $P/sw

# ---- platform ----
platform create -name mbplat -hw $P/out/mb_ctrl.xsa -proc microblaze_0 \
    -os standalone -out . -no-boot-bsp
platform generate

# ---- application ----
app create -name hello_regs -platform mbplat -domain {standalone_domain} \
    -template {Empty Application(C)}
# 导入源件(覆盖模板 main.c)
file delete -force $P/sw/hello_regs/src/main.c
file copy -force $P/sw/src/main.c $P/sw/hello_regs/src/main.c
app build -name hello_regs

puts "SW_DONE: $P/sw/hello_regs/Debug/hello_regs.elf"
