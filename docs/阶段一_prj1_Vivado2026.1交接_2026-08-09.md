# MicroBlaze 最小系统 — 2026.1 工作交接文档

> 用途:记录在 Vivado/Vitis 2026.1 下完成的所有工作与踩坑结论,供迁移到 2023.1 后直接复用。
> 日期:2026-08-09 · 环境:Vivado/Vitis 2026.1(已决定卸载,换 2023.1)

---

## 1. 项目概览

| 项目 | 值 |
|---|---|
| 工程路径 | `D:\FPGA\test\project_1\project_1.xpr` |
| 器件 | `xcku060_CIV-ffva1156-2-i`(KU060 CIV 国内版,UltraScale 20nm,**非 UltraScale+**) |
| 顶层 | `design_1_wrapper`(块设计 `design_1` 自动生成) |
| 设计内容 | MicroBlaze 最小系统 |
| License | Vivado Enterprise,有效期至 2026-10-05,**版本无关,2023.1 直接可用,不需要破解** |

### 块设计组成
- `microblaze_0`(CPU 核,占 1156 LUT)
- `microblaze_0_local_memory`:LMB + 64KB BRAM(16 个 BRAM36)
- `mdm_1`:调试模块(配置为 **C_USE_BSCAN=0=INTERNAL,USER2,标准配置,不要改!**)
- `clk_wiz_1`:100MHz 差分输入 → MMCM 分频(输入时钟约束由 IP 自动生成)
- `rst_clk_wiz_1_100M`:复位同步
- `axi_interconnect_0` + `axi_uartlite_0`(地址 **0x40600000**,波特率 **9600**)+ `xlconstant_0`

---

## 2. 管脚约束(最关键的成果,来自官方 KU_IO.xdc)

**官方文件位置**:`C:\Users\***\Desktop\操作相关\3_开发板原理图及硬件相关\KU_IO.xdc`
⚠️ 该文件是 **GBK 编码**,用 Python 读取,别用 grep(Git Bash grep 会当成二进制返回空)。

### 最终管脚表(已验证正确)

| 信号 | 管脚 | IOSTANDARD | Bank |
|---|---|---|---|
| `diff_clock_rtl_0_clk_p` | **AK17** | DIFF_HSTL_I_12 | 45 |
| `diff_clock_rtl_0_clk_n` | **自动配对 AK16**(不写 PACKAGE_PIN) | DIFF_HSTL_I_12 | 45 |
| `reset_rtl_0` | **AC34** | LVCMOS18 | 48 |
| `uart_rxd` | **AE33** | LVCMOS18 | 48 |
| `uart_txd` | **AF34** | LVCMOS18 | 48 |

### 完整 pins.xdc(10 行,2026.1 实测零错误通过)

```tcl
set_property PACKAGE_PIN AK17 [get_ports diff_clock_rtl_0_clk_p]
set_property PACKAGE_PIN AC34 [get_ports reset_rtl_0]
set_property PACKAGE_PIN AE33 [get_ports uart_rxd]
set_property PACKAGE_PIN AF34 [get_ports uart_txd]

set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports diff_clock_rtl_0_clk_p]
set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports diff_clock_rtl_0_clk_n]
set_property IOSTANDARD LVCMOS18 [get_ports reset_rtl_0]
set_property IOSTANDARD LVCMOS18 [get_ports uart_rxd]
set_property IOSTANDARD LVCMOS18 [get_ports uart_txd]
```

**注意:不需要手写 `create_clock`**——clk_wiz IP 的 XDC 自动生成(手写会报 18-1055 重复定义警告,删掉即可)。

### ⚠️ 历史教训:以下管脚是错的,千万别再用
- A13 = `sd_miso`(SD 卡)
- AD8/AD9/AD10 = HDMI 视频输入(`video_rgb_in[0]` / `video_de_in` / `video_vs_in`)
- 错误来源:手册里的接口表看串行了。**管脚一律以官方 KU_IO.xdc 为准**

### 知识点(答辩用)
- Bank 48 是 1.8V HP bank → LVCMOS33 永远选不到它,要用 LVCMOS18
- 差分时钟是 1.2V HSTL 输出 → `DIFF_HSTL_I_12`,不是 LVDS
- 差分对 N 端 PACKAGE_PIN 自动配对,但 **IOSTANDARD 两端都要写**
- `clk_p`/`clk_n` 管脚名带 `_GC` = 时钟能力管脚(MRCC),和手册"全局时钟"描述一致

---

## 3. 综合/实现结果(2026.1,全绿)

| 阶段 | 结果 |
|---|---|
| Synthesis | **0 错误 0 关键警告**(6 个良性警告:未用端口) |
| 资源 | 1390 LUT / 1237 FF / 16 BRAM36(占 KU060 约 0.4%) |
| Implementation | **WNS = +4.724ns,0 时序违例,0 DRC 违例** |
| Bitstream | `project_1.runs\impl_1\design_1_wrapper.bit`(24MB,未压缩) |
| I/O 落位 | 与管脚表完全一致(io_placed.rpt 可查) |

**层级综合(OOC)**:块设计每个 IP 单独综合(`design_1_*_synth_1` 目录),顶层报告显示 0 LUT 是正常的。

---

## 4. 板级验证结论(2026-08-09 实测)

### JTAG 链路
- 下载器:正点原子 Xilinx 下载线 = **FT2232H 芯片(VID_0403 PID_6014)**,Vivado 识别为 "Digilent JTAG-HS1"
- **通用 FTDI 驱动即可用**(显示 "USB Serial Converter"),"Digilent USB Device" 绑定不必要——INF 名字是显示名,底层 FTDIBUS 服务一样
- 驱动签名全部有效,不需要禁用签名
- 笔记本使用:直接插自带 USB 口、接电源适配器、避开 Hub

### ⚠️ 重要:JTAG 直接编程 bitstream 失败(板子特性)
- 症状:`Labtools 27-3165 End of startup status: LOW`(数据能传、CRC 通过、DONE 不拉高)
- 诊断:CONFIG_STATUS 寄存器读 MODE 引脚 = **M[2:0]=001(SPI 启动模式,板上无模式开关,硬接)**
- Flash 启动正常:上电 DONE 灯亮(板载 QSPI Flash 有出厂固件)
- **结论:不要死磕 JTAG 直烧,走 Flash 路线**(写 QSPI Flash,上电自动加载)

### QSPI Flash
- 型号:**N25Q128(128Mb=16MB)**,Vivado 里选 **`mt25ql128-spi-x1_x2_x4`**(换代型号,兼容)
- 2026.1 的 Add Configuration Memory Device **没有 Auto Detect** 按钮(2023.1 有)
- **默认高亮的是 `28f00am29ew-bpi-x16`(BPI 并行 Flash),是错的,别选!** 要切到 SPI/QSPI 类型找
- 编程文件只收 `.mcs`/`.bin`,不收 `.bit`
- **⚠️ 24MB 的 bitstream 放不进 16MB Flash,必须压缩!**
  - 2026.1 压缩属性 API 已改(project/run/design 上都找不到 `BITSTREAM.GENERAL.COMPRESS`)
  - 2023.1 用老语法:`set_property BITSTREAM.GENERAL.COMPRESS true [current_project]` 或 GUI Settings → Bitstream → Compress
- 烧录步骤:选 `mt25ql128-spi-x1_x2_x4` → **先 Readback 备份出厂固件** → Program(选 .bin)→ 断电重上电

### MDM 配置(重要,别改!)
```
C_USE_BSCAN       = 0  → 含义是 INTERNAL(内部 BSCAN),标准配置!
C_DEBUG_INTERFACE = 0  → INTERNAL,标准
C_MB_DBG_PORTS    = 1
C_BSCANID         = 76547328(默认)
```
- **MDM v3.2(2026.1)参数语义:0=INTERNAL,2=EXTERNAL,3=NONE**——和老版本完全不同
- `set_property CONFIG.C_USE_BSCAN {1}` 会报"Value '1' out of range, valid: 0,2"——**1 不是合法值**
- 参数含义一律以 `D:\AMDDesignTools\<ver>\Vivado\data\ip\xilinx\mdm_v3_2\component.xml` 的 choice 定义为准

---

## 5. Vitis 侧结论(2026.1 Unified IDE)

### 新版 IDE 特性
- **没有应用模板向导**——应用组件是空工程,手动加源文件("Add Source Files")
- **BSP 不再生成 platform.h**——旧版模板代码(`#include "platform.h"` + `init_platform()`)在新版编译不过
- 构建时选 **"Always build platform with application"**(否则 BSP 不生成,stdio.h 都找不到)

### main.c 最终版(自包含,无 platform.h)

```c
#include <stdio.h>
#include "xil_printf.h"

int main()
{
    xil_printf("Hello World\n\r");
    return 0;
}
```

要点:
- `xil_printf` 直接可用(BSP 的 stdout 自动指向 AXI UART Lite)
- `\n\r` 必须带 `\r`(终端需要回车)
- 文件**末尾必须有换行符**,否则 clangd 一直报 "no newline at end of file"
- Problems 面板的 `code_syntax` 警告来自 clangd:**`-mxl-soft-mul` 未知参数警告是噪音**,真实构建(mb-gcc)0 警告。以 Build 输出为准

### Vitis 运行配置
- Run 配置里**必须配 Bitstream File**(否则找不到 FPGA)
- 工作空间:`C:\Users\***\Desktop\FPGA_Project\vitis_project\project_1\`(应用名 hallo_world)

---

## 6. 串口(USB 转串口)

- 芯片:CH340,设备名 **COM6**(之前是 COM5,重插后变了,端口号会漂移)
- **波特率 9600-8-N-1**(AXI UART Lite IP 默认值,IP 参数固定)
- 坑:COM5 曾"拒绝访问"——重插 USB/重启电脑自愈
- 判定方法:`mode COM6` 看端口状态;Python `CreateFileW('COM6')` 测打开

---

## 7. 迁移到 2023.1 的任务清单

### 直接复用(复制粘贴)
- [ ] pins.xdc(第 2 节,10 行)——管脚表是板级事实,版本无关
- [ ] main.c(第 5 节)
- [ ] 块设计结构(第 1 节)——2023.1 有模板向导,配置照抄
- [ ] 所有"坑"清单(第 4/5/6 节)

### 需要重做
- [ ] 工程重建(Vivado 2023.1 打不开 2026.1 的 xpr;可用中枢 Tcl 三件套:`create_project.tcl` / `bd_mb_minimal.tcl` / `build.tcl`)
- [ ] XSA 导出 + Vitis 平台/应用重建
- [ ] 压缩 bitstream(2023.1 老语法,见第 4 节)
- [ ] Flash 烧录(2023.1 有 Auto Detect,直接选 Flash)

### 2023.1 预期更顺的点
- Auto Detect 选 Flash 型号(不用手动搜)
- 压缩属性老语法可用
- 模板向导恢复(Hello World 模板在)
- BSP 可能重新生成 platform.h(旧模板流程)——到时以实际为准

### 待办(未完成事项)
- [ ] 压缩 bitstream 生成(24MB→<16MB)
- [ ] Flash 烧录 + 上电验证
- [ ] microblaze#0 验证(MDM 调试目标,Flash 启动后应出现)
- [ ] Vitis Launch Hardware 跑通 Hello World(M1)
- [ ] 管脚结论同步到 `FPGA_Project\constr\ku060_pins.xdc`(中枢待办)

---

## 8. 关键文件索引

| 文件 | 位置 |
|---|---|
| 官方管脚约束(权威) | `C:\Users\***\Desktop\操作相关\3_开发板原理图及硬件相关\KU_IO.xdc`(GBK) |
| 手写管脚约束 | `D:\FPGA\test\project_1\project_1.srcs\constrs_1\pins.xdc` |
| bitstream | `D:\FPGA\test\project_1\project_1.runs\impl_1\design_1_wrapper.bit`(24MB 未压缩) |
| flash bin(未压缩,24MB 放不下) | `D:\FPGA\test\project_1\design_1_wrapper_flash.bin` / `_spix4.bin` |
| License 备份 | `D:\FPGA\Xilinx_license_backup.lic`(2023.1 激活用) |
| 应用源码 | `C:\Users\***\Desktop\FPGA_Project\vitis_project\project_1\hallo_world\main.c` |
| 协作中枢 | `C:\Users\***\Desktop\毕设\Agent 协作\AI协作中枢.md` |
| 工程侧指令 | `C:\Users\***\Desktop\FPGA_Project\AGENTS.md` |
