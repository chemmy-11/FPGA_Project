---
type: 操作文档
tags: [毕设, FPGA, KU060, MicroBlaze, Vitis, 教学]
阶段: 阶段一
目标: Vitis 环境就绪 + MicroBlaze 软核跑通 Hello World
created: 2026-08-04
related: "[[短期待办]]"
---

# 阶段一 · Vitis 环境 + MicroBlaze 软核（教学操作指南）

> **一句话目标**：在你的 KU060 开发板上，让一个"软核 CPU"跑起来，并通过串口打印出 `Hello World`。
> **对应任务**：[[短期待办]] 阶段 1（第 1 周）· [[8.3/任务分工-2026-05-07]] 阶段一
> **成功标准（M1）**：串口终端看到 `Hello World` 输出 ✅

---

## 0. 开始之前：先花 5 分钟搞懂这套东西是什么

如果你是 Vitis 纯小白，先建立三个概念，后面每一步你都知道自己在干嘛：

| 概念                | 是什么                        | 打个比方                           |
| ----------------- | -------------------------- | ------------------------------ |
| **FPGA**          | 可以反复"重新布线"的芯片              | 一盒能按图纸随时重拼的乐高                  |
| **MicroBlaze 软核** | 用 FPGA 里的逻辑"拼"出来的 CPU      | 用乐高拼出一个能跑程序的小电脑                |
| **Vivado**        | 画硬件、生成"电路图纸"（bitstream）的工具 | 画乐高图纸 + 拼装的工具                  |
| **Vitis**         | 写 C 代码、编译、下载运行的工具          | 给那个小电脑写程序的 IDE（像 Keil/VS Code） |

**两者分工一句话**：**Vivado 管"硬件长什么样"，Vitis 管"程序怎么跑"**。中间的桥梁是一个叫 `.xsa` 的文件（硬件平台描述，Vivado 导出、Vitis 导入）。

**数据流总览**（本项目最终形态，阶段一先跑通红色部分）：

```
  你写的 C 程序（Vitis）
        │  编译成机器码
        ▼
  MicroBlaze 软核（拼出来的 CPU，跑在 FPGA 里）
        │  AXI 总线（数据高速公路）
        ▼
  UART 串口 ──────► 电脑串口终端显示 "Hello World"
```

---

## 1. 安装 Vitis 开发环境

### 1.1 版本选择（⚠️ 重要）

- **首选**：与**李旺遗留工程**使用的 Vivado 版本一致（先问清楚或用 `vivado -version` 查遗留工程的版本文件）。版本不一致会导致工程升级提示，新手阶段少找麻烦。
- **次选**：Vivado **2023.2 ~ 2024.1** 任一版本。2023.2 之后 Vitis 不再单独安装，而是**包含在 Vivado 安装器里**（勾选 Vitis 组件即可），装一次搞定两个工具。
- ⚠️ **License 注意（已确认的坑）**：KU060 属于 **UltraScale 架构**，免费的 Vivado ML Standard（WebPACK）**不支持**（免费版仅覆盖 7 系列 + 部分 Versal），必须 **Vivado ML Enterprise** 授权，否则综合 KU060 时报 `device not supported`。**拿 license 三条路**：
  - ① 最快：沿用实验室现有破解版环境（注意：破解 license 常绑定机器，直接拷 `.lic` 不一定能用，问清实验室安装方式）
  - ② 正版免费：用学校邮箱申请 **AMD University Program 学术授权**（一年期可续）
  - ③ 验证是否生效：`Help → Manage License` 看状态，或新建工程能选到 XCKU060 且综合不报错

### 1.2 安装步骤

1. 去 Xilinx/AMD 官网注册账号并下载 **Vivado ML Enterprise（含 Vitis）** 安装包（约 100+ GB 解压空间，装完约 100 GB，**确保硬盘 ≥ 200 GB**）。
2. 运行安装器（Xilinx Unified Installer），选 **Vivado** 并**勾选 Vitis** 组件。
3. 器件支持勾选 **Kintex UltraScale**（只装这个能省不少空间，也可全装）。
4. 安装完成后配置 license（校园 .lic 或服务器），打开 Vivado 确认能正常新建工程。
5. 顺手装串口终端软件：**PuTTY** 或 **MobaXterm**（后面看 Hello World 用）。

### ✅ 检查点
- [ ] Vivado 能启动、能新建工程
- [ ] Vitis（或 Vivado 菜单里的 Vitis）能启动
- [ ] License 已生效（新建工程时器件列表里能看到 XCKU060）

---

## 2. 获取并研究李旺遗留的工程文件

> 对应待办：「获取并研究李旺遗留的工程文件，理解其模块设计思路」

拿到工程后，**不要急着打开**，先按这个顺序"读"：

1. **找 README / 说明文档** —— 作者自己写的工程说明最靠谱
2. **看目录结构** —— 有没有 `HW/`（硬件）、`SW/` 或 `SDK/`（软件）、`constraints/`（约束）三个大类
3. **打开 `.xpr` 工程**（Vivado 工程文件）—— 看 **Block Design**（`Sources → Design Sources → 双击 .bd`）：里面有哪些 IP、怎么连的
4. **对照 [[8.3/2026-04-30/block_diagram]]** —— 你已经有一份基线工程的 IP 端口清单，照着认模块
5. **看 `SW/SDK` 里的 C 代码** —— 找 `main.c`，看它调用了哪些驱动（`XAxiDma_*`、`XUartLite_*` 之类），先不求看懂，只求"眼熟"

> 💡 阶段一结束时，你不需要完全看懂遗留工程，只需要回答三个问题：① 它用了哪些 IP？② 数据从哪到哪？③ 控制代码在哪个文件？

---

## 3. Vivado 搭建 MicroBlaze 最小系统

> 对应待办：「Vivado 搭 MicroBlaze 最小系统（Local Memory + UART + AXI Interconnect）→ 生成 Bitstream → 导出 .xsa」

### 3.1 新建工程

1. Vivado → `Create Project` → Next → 工程名（如 `mb_hello`）→ 一路 Next 到选器件：
   - **Family**: Kintex UltraScale
   - **Part**: `xcku060-ffva1156-...`（具体封装/速度等级**以开发板手册标注为准**）
   - 📖 开发板手册 → **FPGA 芯片型号与封装**（确认丝印，如 `XCKU060-FFVA1156-2E`）
2. 不勾选 "Specify source files"，空工程即可，Finish。

### 3.2 创建 Block Design

1. 左侧 `IP INTEGRATOR → Create Block Design`，名字默认 `design_1` 即可。
2. 点画布上的 `+`（Add IP），搜索并添加 **MicroBlaze**。

### 3.3 一键搭建最小系统（关键技巧：Run Block Automation）

1. 画布顶部出现绿色横幅 **"Run Block Automation"** —— 点它！
2. 弹窗里确认勾选 `microblaze_0`，然后设置：
   - **Local Memory**: 64 KB（够跑 Hello World；后面跑 DMA 代码时再加大）
   - **Cache Configuration**: None（最小系统不需要缓存）
   - **UART**: 选择 **AXI UART Lite**（会连带自动创建 AXI Interconnect 和 Processor System Reset）
3. 点 OK —— Vivado **自动帮你把 MicroBlaze、Local Memory、UART、Interconnect、复位模块全部连好**。这就是新手最友好的地方，先靠自动连线，之后再学手动连。

> 💡 **为什么这步重要**：Run Block Automation 自动生成的就是「Local Memory + UART + AXI Interconnect」最小系统骨架，对应待办要求。你不需要手动画线，但要**认识自动生成的每个模块**（看 Diagram 里的模块名）。

### 3.4 添加时钟（Clocking Wizard）

MicroBlaze 需要一个稳定时钟（通常 100 MHz），板载晶振频率不一定是 100 MHz，所以需要时钟管理：

1. Add IP → **Clocking Wizard** → 双击配置：
   - `Input Clock` 频率 = **开发板晶振频率**（📖 开发板手册 → **板载时钟源**，常见 200 MHz / 125 MHz）
   - `Output Clock clk_out1` = **100 MHz**（MicroBlaze 系统时钟）
2. 连线：`clk_wiz_0.clk_in1` 接到 Block Design 的对外端口（自动创建 `CLK_IN1_D_0` 之类的端口，或手动 Make External）。
3. `clk_wiz_0.locked` 接到复位模块的 `dcm_locked`（Run Block Automation 生成的 `rst_*` 模块有 `dcm_locked` 输入——这条线管"时钟稳定后软核才启动"）。

### 3.5 设置外部端口（UART 要引出到芯片引脚）

1. 在 Diagram 里找到 `axi_uartlite_0`（或自动生成的 uart 模块），把它的 **`RX`、`TX`** 两个引脚 **Make External**（右键 → Make External），得到 `uart_rx`、`uart_tx` 两个对外端口。
2. 把 `rst_*` 模块的 `ext_reset_in` 也 Make External（或接常高 `xlconstant_1`），把 `CLK_IN1_D_0` 确认存在。
3. 保存设计（Ctrl+S）。

### 3.6 校验设计并生成产物

1. Diagram 工具栏 → **Validate Design**（或 F6）—— 必须 0 错误。
2. 左侧 `Sources → design_1` 右键 → **Generate Output Products** → Generate（等 IP 全部生成）。
3. `design_1` 右键 → **Create HDL Wrapper** → 选 "Let Vivado manage wrapper and auto-update"。

### 3.7 引脚约束（把逻辑端口绑到真实芯片引脚）—— 教学重点

现在 `uart_tx`/`uart_rx` 还是"逻辑端口"，必须告诉 Vivado 它们对应芯片的哪个物理引脚：

1. 左侧 `Add Sources → Add or create constraints` → 新建 `ku060_pins.xdc`。
2. 在 XDC 里写（**引脚号必须以开发板原理图为准**，下面是示例格式）：
   ```tcl
   set_property PACKAGE_PIN AB12 [get_ports uart_tx]
   set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
   set_property PACKAGE_PIN AB11 [get_ports uart_rx]
   set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
   ```
   > 📖 开发板手册 → **UART 接口原理图 / 引脚分配表**（找到 USB 转串口芯片与 FPGA 相连的 TX、RX 引脚号；电平标准看原理图，常见 LVCMOS33）
3. 时钟引脚约束（若 3.4 中 clk 端口是差分时钟，需要 `get_ports CLK_IN1_D_0_p` / `_n` 两条约束；单端时钟直接一条）。

### 3.8 综合 → 实现 → 生成 Bitstream（首次会比较久，可先去喝杯水）

1. 左侧 Flow Navigator：**Run Synthesis** → 完成点 OK（不开弹窗直接下一步）。
2. **Run Implementation** → 完成点 OK。
3. **Generate Bitstream** → OK → 等进度条走完（首次可能 10~30 分钟）。
4. 如果某步报错：双击红色条目看错误，**最常见的两类**：约束引脚号写错、时钟约束缺失。对照手册检查。

### 3.9 导出 .xsa（Vivado → Vitis 的桥梁）

1. `File → Export Hardware` → **勾选 "Include bitstream"**（必须勾！否则 Vitis 里没法下载）→ 导出为 `mb_hello.xsa`。
2. 建议把 `.xsa` 存到工程目录或专门的 `xsa/` 文件夹，路径别带中文和空格。

### ✅ 检查点
- [ ] Validate Design 0 错误
- [ ] Bitstream 生成成功
- [ ] 拿到含 bitstream 的 `.xsa` 文件

---

## 4. Vitis 跑通 Hello World（最激动人心的一步）

### 4.1 新建硬件平台

1. 打开 **Vitis IDE**（Vivado 菜单 `Tools → Launch Vitis IDE`，或单独启动）。
2. 首次启动选工作区目录（如 `C:\vitis_ws`，**别用中文路径**）。
3. `File → New → Platform Project`：
   - 名字如 `mb_platform`
   - **Hardware Specification** 选刚才的 `mb_hello.xsa`
   - Finish → 等待平台工程构建（Vitis 会生成 BSP，即"板级支持包"——包含串口、GPIO 等外设的驱动库）。

### 4.2 新建 Hello World 应用

1. `File → New → Application Project` → Next → 选中 `mb_platform` → Next。
2. 名字 `hello_world` → 模板选择 **"Hello World"**（模板列表里找）→ Finish。
3. 看 `src/helloworld.c` —— 核心就是一行 `print("Hello World");`。**这就是要下载到软核里跑的 C 程序**。

### 4.3 准备串口终端（对应待办「串口打印」）

1. **硬件连接**：用 USB 线把开发板的 **UART/串口** 口连到电脑。📖 开发板手册 → **UART 接口位置与 USB 驱动**（部分板卡需装 FTDI/CP210x 驱动）。
2. 电脑上 `设备管理器 → 端口(COM和LPT)`，记下新出现的 **COM 号**（如 COM3）。
3. 打开 PuTTY（或 MobaXterm）：
   - Connection type: **Serial**
   - Serial line: `COM3`
   - Speed: **115200**
   - 其他默认（8 数据位 / 无校验 / 1 停止位，即 8N1）
   - 打开连接，先放着。

### 4.4 下载运行，见证奇迹

1. Vitis 里 `hello_world` 工程右键 → **Build Project**（或 Ctrl+B），确认编译 0 error。
2. `Run → Run Configurations` → 双击 **Single Application Debug**（或直接点 Run 图标）。
3. Vitis 会通过 **JTAG**（📖 开发板手册 → **JTAG 接口位置与连接**，通常用下载器连电脑 USB）把 bitstream 烧进 FPGA，再把程序下载到软核并运行。
4. **切到 PuTTY**——看到 `Hello World` 打印出来，M1 达成！🎉

### 4.5 小练习（可选但推荐）

改 `helloworld.c`，加一行 `print("KU060 is alive!\r\n");` 再 Run 一次，体会"改代码 → 重新编译 → 下载"的循环。这就是以后所有调试的基本节奏。

### ✅ 检查点
- [ ] 串口终端看到 `Hello World`
- [ ] 能改代码并重新下载运行

---

## 5. 常见问题排查表（新手必存）

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 串口无任何输出 | ① 串口 COM 号选错 ② 波特率不对 ③ UART 引脚约束错 ④ 程序没下载成功 | 依次检查：设备管理器 COM 号 → PuTTY 115200 → 板卡原理图核对引脚 → 看 Vitis 下载日志 |
| JTAG 连不上开发板 | 下载器驱动没装 / 线接错 / 板卡没上电 | 📖 开发板手册 → JTAG 与供电章节；重装驱动；检查电源开关 |
| Bitstream 下载时报 IDCODE 不匹配 | `.xsa` 里器件型号与板卡不符 | 确认 3.1 选的 Part 与板卡丝印一致 |
| Vivado 报 "device not supported" | License 不支持 UltraScale | 换 Enterprise/Design Edition license（见 1.1） |
| Run Block Automation 后 Validate 报错 | 常是时钟/复位没连 | 重点检查 `locked → dcm_locked`、`ext_reset_in` 是否接好 |
| 综合/实现特别慢 | 正常，UltraScale 工程首次需要时间 | 耐心等；确认没开其他大程序 |

---

## 6. 里程碑自检（M1 判定标准）

- [ ] Vitis 环境安装完成，能建工程
- [ ] 已通读李旺遗留工程结构，能说出"它用了哪些 IP、数据流走向"
- [ ] KU060 上 MicroBlaze 最小系统综合实现成功（有 bitstream）
- [ ] **串口打印出 Hello World** ✅（M1 达成）

达成后：在 [[短期待办]] 阶段 1 的复选框打勾，进入阶段二（见 [[操作文档/阶段二_SFP收发与Aurora64b66b]]）。

---

## 7. 参考资源

- 视频（保姆级）：B站《microblaze软核教程（1）创建工程》（BV1h68tz9Eg1）、B站《在VIVADO中创建MICROBLAZE软核处理器》（BV1YeC4Y2Edh）、《Xilinx VITIS IDE基本开发流程教学》（BV1q8411c7kD）——完整清单见 [[8.3/任务分工-2026-05-07]] 第 5 节
- 理论：[[8.3/任务分工-2026-05-07]] 阶段一 + 第 4 节（学习安排）
- 背景：[[8.3/讨论2026-08-03]]（任务来源）、[[8.3/README]]（平台总览）
