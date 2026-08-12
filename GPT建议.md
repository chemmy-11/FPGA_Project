先给结论：**你现在最需要纠正的判断，是把 `M[2:0]=001 (Master SPI x1)` 和“JTAG 配置后不能完成 startup”联系起来。对 UltraScale XCKU060，这两者原则上没有这个因果关系。**

UG570 明确写了：**通过 JTAG 配置时，JTAG configure 指令与 MODE pin 的选择无关。** 也就是说，板子即使焊死在 Master SPI x1，仍然可以正常通过 JTAG 完成配置和 startup。([AMD 文档][1])

结合你给出的现象，我目前的判断是：

> **第一嫌疑：JTAG 配置数据已经基本送入 FPGA，但 JTAG → JSTART → startup 时序链没有可靠完成；第二嫌疑：FT2232H/Digilent JTAG 链路本身存在间歇性传输问题。**
>
> **不是 MODE=001 本身导致 DONE 永远无法拉高。**
>
> 置信度：**约 85%**。

尤其是这三个现象放在一起非常关键：

* `CRC_ERROR=0`
* `IDCODE_ERROR=0`
* `BAD_PACKET=0`
* `INIT_B=1`
* `PLL_LOCK=1`
* 但 `DONE=0 / EOS=0 / startup phase=0`
* 并且偶发成功，同时出现过 `FT_Write returned 0`

这更像是**配置/启动序列没有完整跑完**，而不是 bitstream 内容本身错误。

---

# 一、先把 UltraScale 的配置逻辑捋清楚

你的器件是：

`XCKU060-CIV-FFVA1156-2-I`

它有两条概念上独立的配置路径：

```text
                 ┌──────────────┐
MODE[2:0] ──────►│ Boot Mode    │
                 │ Selection    │
                 └──────┬───────┘
                        │
              上电后的 Master SPI
                        │
                        ▼
                    N25Q128
                        │
                        ▼
                    FPGA Config
```

与此同时还有：

```text
JTAG
 TCK
 TMS
 TDI
 TDO
  │
  ▼
JTAG CFG_IN
  │
  ▼
Configuration Packet Processor
  │
  ▼
Configuration Memory
  │
  ▼
Startup State Machine
  │
  ├── GWE
  ├── GTS
  ├── DONE
  └── EOS
```

**这两条路径不是“MODE=001 后 JTAG 就变成 SPI”的关系。**

UG570 明确指出：

> UltraScale FPGA 支持标准 JTAG configuration，**JTAG configuration 与 mode pin selection independent**。

([AMD 文档][1])

所以：

### `M[2:0]=001` 并不会阻止：

```text
JTAG → CFG_IN → bitstream → startup → DONE
```

反而你已经有一个非常强的实验事实证明这一点：

> **同一块板、同一个 MODE=001，上电后 N25Q128 能正常启动，并且 DONE 正常亮。**

这说明：

* DONE 硬件没有坏
* DONE pull-up 大概率正常
* INIT_B 基本正常
* FPGA configuration startup 硬件基本正常
* SPI boot 通路正常

UG570 也明确说明 DONE 是配置完成指示，而 startup sequencer 最终会 release DONE，并在之后进入 EOS。([AMD 文档][2])

---

# 二、你这个 STATUS=0x5080190C 非常有价值

UG570 的 Status Register 定义里：

* `CFG_STARTUP_STATE_MACHINE_PHASE`：bit `[20:18]`
* `DONE_PIN`：bit 14
* `DONE_INTERNAL_SIGNAL_STATUS`：bit 13
* `INIT_B_PIN`：bit 12
* `MODE_PIN_M[2:0]`
* `EOS`
* `MMCM_PLL_LOCKED`
* `CRC_ERROR`

([AMD 文档][3])

你现在：

```text
CONFIG_STATUS = 0x5080190C

DONE_PIN = 0
EOS      = 0
STARTUP  = phase 0
MODE     = 001
CRC      = 0
INIT_B   = 1
PLL_LOCK = 1
```

这和“配置数据 CRC 错了”明显不一样。

更重要的是：

## 如果真正是 bitstream 配置失败

通常应该优先看到诸如：

```text
CRC_ERROR
IDCODE_ERROR
BAD_PACKET
INIT_B
SECURITY_ERROR
```

而你这里这些关键错误基本都是 0。

所以目前不要再把精力主要放在：

> “bitstream 是不是坏了？”

而应该转向：

> **“为什么 startup sequencer 没有继续往后跑？”**

---

# 三、关于你尝试的 `BITSTREAM.CONFIG.CONFIG_MODE`

这里确实有一个容易踩坑的地方。

你写的是：

```tcl
set_property BITSTREAM.CONFIG.CONFIG_MODE ...
```

这个思路不对。

`CONFIG_MODE` **不是 `BITSTREAM.CONFIG.CONFIG_MODE`**。

AMD 的属性定义是：

```tcl
set_property CONFIG_MODE <value> [current_design]
```

例如：

```tcl
set_property CONFIG_MODE B_SCAN [current_design]
```

或者：

```tcl
set_property CONFIG_MODE SPIx1 [current_design]
```

UG912 明确把 `CONFIG_MODE` 定义成 **Design property**，不是 `BITSTREAM.*` property。([AMD 文档][4])

---

# 四、2023.1 建议你这样设置

如果你现在的目的只是：

> **这个 bitstream 主要拿来 JTAG 下载调试**

那么建议明确设置：

```tcl
set_property CONFIG_MODE B_SCAN [current_design]
```

然后重新：

```tcl
reset_run synth_1
reset_run impl_1

launch_runs impl_1 -to_step write_bitstream
wait_on_run impl_1
```

或者 GUI：

```text
Project Settings
    → Bitstream
```

以及 Design Configuration 相关设置。

但这里我要特别强调：

## `CONFIG_MODE B_SCAN` 不是“修复 DONE”的开关。

它告诉 Vivado：

> **我的设计预期通过 Boundary Scan/JTAG 配置。**

它主要影响：

* I/O planning
* DRC
* bitstream generation

而不是：

```text
MODE=001
       ↓
JTAG startup 被禁止
```

这种机制不存在。UG912 对 `CONFIG_MODE` 的定义也明确说明它影响的是 pin allocation、DRC 和 bitstream generation。([AMD 文档][4])

所以你可以设置：

```tcl
set_property CONFIG_MODE B_SCAN [current_design]
```

**但我不会把它当成你现在问题的根因修复。**

---

# 五、反而建议做一个非常重要的实验

你现在不要继续用完整的 MicroBlaze 设计测试。

做一个**极简 bitstream**：

```text
XCKU060
 └── 100 MHz
      └── BUFG
           └── LED/简单 FF
```

甚至：

```text
100MHz → counter → LED
```

不要：

* MicroBlaze
* AXI
* UART Lite
* MDM
* BRAM
* Debug
* ILA

全部去掉。

然后：

```tcl
set_property CONFIG_MODE B_SCAN [current_design]
```

生成最小 bitstream。

然后：

### 实验 A

Vivado Hardware Manager：

```text
Program Device
```

不要 Vitis。

观察：

```text
DONE
EOS
STARTUP_PHASE
GWE
GTS
```

### 验证标准

如果极简 bitstream：

```text
DONE = 1
EOS  = 1
```

那么：

> JTAG + FPGA + MODE=001 + startup 全部没问题。

接下来才查你的原始 bitstream。

如果**极简 bitstream 也稳定 DONE=0**：

> 基本可以把 MicroBlaze/AXI/时序设计从嫌疑名单里拿掉。

这一步的诊断价值非常高。

---

# 六、我认为现在第一优先级是查 JTAG 链路

因为你自己已经给出了一个非常醒目的证据：

> **FT_Write returned 0**

再加：

> 偶发成功
> 偶尔枚举不到
> 重开 Vivado 后曾成功一次
> 重新上电后又失败

这和“MODE 配错”并不符合。

反而非常符合：

```text
USB
 ↓
FT2232H
 ↓
Adept Runtime
 ↓
Digilent JTAG-HS1
 ↓
TCK/TMS/TDI/TDO
 ↓
XCKU060
```

这条链路存在偶发异常。

---

# 七、按照这个顺序排查 JTAG

## Priority 1：把 JTAG clock 降到最低

这是我现在最建议你做的第一个实验。

不要一上来 15/30 MHz 甚至更高。

先：

```text
JTAG Clock = 1 MHz
```

如果仍失败：

```text
500 kHz
```

甚至：

```text
100 kHz
```

然后连续：

```text
Program Device × 20~50 次
```

统计成功率。

### 判断：

| 结果                  | 意义                             |
| ------------------- | ------------------------------ |
| 1 MHz 稳定，15 MHz 不稳定 | 极强烈指向 JTAG SI/线缆/供电/FTDI       |
| 全部失败                | 继续查 startup / PROGRAM_B / 配置流程 |
| 成功率随机               | USB/FTDI/板级硬件仍然高度可疑            |
| 极低频仍偶发 FT_Write=0   | 更偏 USB/FTDI/驱动/电脑              |

**这个实验比重新综合 50 次都有价值。**

---

# 八、第二步：不要连续点击 Program，先 Reset Device

每次失败后：

```text
Hardware Manager
    → Reset Device
```

然后：

```text
refresh_hw_device
```

再：

```text
Program Device
```

必要时：

```text
关闭 Vivado
关闭 hw_server
重新插 USB
重新上电
启动 Vivado
```

因为如果 JTAG configuration sequence 在中间异常终止，TAP / configuration state 并不一定处在你以为的干净状态。

UG570 描述了 JTAG CFG_IN / CFG_OUT 的状态转换和 TAP reset 流程。([AMD 文档][5])

---

# 九、第三步：重点观察 PROGRAM_B

如果开发板能测：

```text
PROGRAM_B
INIT_B
DONE
CCLK
```

我建议示波器/逻辑分析仪直接抓。

理想 JTAG 配置过程应该看到：

```text
PROGRAM_B
───────────────┐
               └──────────────

INIT_B
───────┐
       └─────────────── HIGH

JTAG TCK
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

DONE
───────────────────────┐
                       └──── HIGH

EOS
                        └──── HIGH
```

特别是：

## DONE=0 + DONE_INTERNAL_SIGNAL_STATUS=0

说明 FPGA **内部 startup 还没有 release DONE**。

## DONE_INTERNAL_SIGNAL_STATUS=1 + DONE_PIN=0

这个就非常不一样：

说明 FPGA 内部已经 release DONE：

```text
FPGA internal DONE = released
        ↓
external DONE pin = LOW
```

那时候才应该重点怀疑：

* DONE 外部被拉低
* 板级电路
* LED
* FPGA pin connection
* 外部器件 loading

UG570 对这两个信号有明确区分。([AMD 文档][2])

---

# 十、一个很重要的实验：比较“JTAG失败”和“Flash成功”的状态

你已经有一个非常好的 A/B test。

### Case A：上电，从 N25Q128 boot

记录：

```text
STATUS
DONE
EOS
INIT_B
MODE
STARTUP_PHASE
```

应该：

```text
MODE = 001
DONE = 1
EOS = 1
```

### Case B：JTAG Program

记录完全一样的数据。

如果：

```text
MODE = 001
CRC = 0
INIT_B = 1
PLL = 1
DONE = 0
EOS = 0
PHASE = 0
```

那么：

**同一块 FPGA 的 startup 硬件已经被 Flash boot 验证过是工作的。**

因此问题几乎锁定在：

```text
JTAG configuration transaction
        ↓
startup invocation
```

而不是：

```text
FPGA startup circuitry
```

---

# 十一、关于“JTAG 烧 Flash 前置配置会不会同样失败？”

### 会。

这是你这个方案里非常重要的一点。

Vivado 的间接 Flash 编程机制并不是：

```text
JTAG → 直接操作 N25Q128
```

而是：

```text
JTAG
 ↓
先把 FPGA 配置成一个特殊的 Flash programmer
 ↓
FPGA 建立 JTAG ↔ Flash 数据通路
 ↓
Vivado 通过这个通路
 ↓
Erase / Program / Verify
 ↓
N25Q128
```

UG908 对这一点说得很明确：Vivado 间接编程 configuration memory 时，**先通过 JTAG 给 FPGA 下载一个特殊 configuration，使其提供 JTAG 到 Flash 的数据通路，然后再编程 Flash。** ([AMD 文档][6])

所以：

> **如果你现在连一个普通 bitstream 都不能可靠完成 JTAG startup，那么直接转向 “Add Configuration Memory Device → Program” 并不能绕过这个问题。**

它反而很可能在第一步就卡住。

---

# 十二、但你的最终架构仍然是正确的

你计划：

```text
N25Q128
   ↓
Power ON
   ↓
XCKU060 configuration
   ↓
DONE
   ↓
MicroBlaze running
   ↓
Vitis
   ↓
JTAG/MDM
   ↓
download ELF
```

### 我赞成这个架构。

对于你这种：

```text
MicroBlaze
+ AXI UART Lite
+ LMB
+ MDM
```

开发方式，实际上比每次：

```text
Vitis
→ Program FPGA
→ DONE
```

更合理。

稳定以后：

```text
上电
→ Flash boot FPGA
→ DONE
→ MicroBlaze
→ Vitis Download ELF
```

Vitis 就不再负责 FPGA configuration。

---

# 十三、N25Q128 在 Vivado 2023.1 应该选什么？

你的条件是：

```text
N25Q128
128 Mbit
16 MB
3.3 V
Single device
SPI x1
```

AMD 的 2023.1 UG908 列表里，Micron N25Q128 对应：

```text
mt25ql128
```

其中包含：

```text
n25q128-3.3v-qspi-x1-single
n25q128-3.3v-qspi-x1-dual_stacked
n25q128-3.3v-qspi-x2-single
...
```

([AMD 文档][7])

因此你这个板子的：

> **N25Q128 + M[2:0]=001 + Master SPI x1 + 单颗 Flash**

应选：

### `n25q128-3.3v-qspi-x1-single`

不是：

```text
dual_stacked
x2
x4
x8
```

也不是 1.8V 版本。

---

# 十四、Flash 镜像建议先做最简单版本

你这个 Flash 只有：

```text
128 Mbit = 16 MB
```

而你说 bitstream 文件约：

```text
24 MB
```

这里我建议你**特别注意**。

如果你说的“24 MB”是 `.bit` 文件的实际文件大小，那么：

> **N25Q128 只有 16 MB，理论容量是不够的。**

这一点必须先确认。

XCKU060 本身 configuration data 大小当然可能非常大，但最终你需要确认：

```text
生成的 .bin / .mcs
```

到底多大。

不要只看 `.bit`。

执行：

```tcl
write_cfgmem \
  -format bin \
  -interface SPIx1 \
  -size 16 \
  -loadbit "up 0x0 design.bit" \
  -file design.bin
```

然后：

```text
dir design.bin
```

如果：

```text
design.bin > 16 MB
```

那么 N25Q128 根本装不下。

这是 Flash 路线必须先确认的第二个硬条件。

---

# 十五、你的 Flash 路线还有一个潜在坑

因为 MODE 固定：

```text
001 = Master SPI x1
```

所以你的 Flash boot 必须和：

```text
SPIx1
```

一致。

建议 design property：

```tcl
set_property CONFIG_MODE SPIx1 [current_design]
```

然后再生成 bitstream/config memory image。

不要拿：

```text
SPIx4
```

的配置参数去匹配：

```text
M=001
```

否则 Flash boot 本身可能出问题。

---

# 十六、关于“Enable end of startup check”

你已经做了一个非常漂亮的验证：

> 关闭 check 后 Vivado 不报错，但 DONE 还是 LOW、设备仍显示未配置。

所以：

### 不要再把这个选项当 workaround。

它只是：

```text
Vivado 是否检查 startup 结果
```

不是：

```text
让 FPGA startup 继续执行
```

你实际上已经证明了这一点。

---

# 十七、为什么 `PLL_LOCKED=1` 但 phase 仍是 0？

这个信息也值得注意。

UG570 的 startup sequencer 是：

```text
Phase 0
   ↓
Phase 1~6
   ↓
GWE/GTS/DONE
   ↓
Phase 7
   ↓
EOS
```

并且 MMCM/PLL lock 可以被 startup wait 条件使用。([AMD 文档][2])

所以：

```text
PLL_LOCKED = 1
```

只说明 PLL 已锁。

**它并不意味着 startup state machine 已经走完。**

你的：

```text
PHASE = 0
EOS = 0
DONE = 0
```

反而说明 startup sequence 根本没有正常推进到后续阶段。

这再次把注意力拉回：

> **JTAG configuration transaction / startup clocking / JSTART / cable communication**

而不是 MicroBlaze。

---

# 十八、我会这样做你的实际排查顺序

我给你一个非常具体的执行表。

## P0 —— 先确认 bitstream 是否“极简也失败”

生成：

```text
100 MHz
→ counter
→ LED
```

不放 MicroBlaze。

然后：

```tcl
set_property CONFIG_MODE B_SCAN [current_design]
```

JTAG：

```text
1 MHz
```

连续 Program 20 次。

### 结果：

#### A. 20/20 成功

说明：

```text
FPGA
JTAG
MODE=001
DONE
startup
```

全部 OK。

→ 回头查原 MicroBlaze bitstream。

#### B. 0/20 成功

继续 P1。

#### C. 20 次里偶尔成功

**高度怀疑 JTAG 链路。**

---

# P1 —— 降 JTAG 到 100 kHz

如果：

```text
1 MHz → 失败
100 kHz → 成功
```

基本就非常接近答案了：

> **JTAG SI / cable / FT2232H / TCK integrity / power integrity。**

---

# P2 —— 换 JTAG 线

不要只重新插。

直接：

> **换另一根 USB cable。**

最好：

* 短
* 屏蔽
* USB 2.0
* 不经过 Hub

然后：

```text
PC
 ↓
USB cable
 ↓
FT2232H
```

整条链换。

---

# P3 —— 换 USB 口

优先：

```text
主板后置 USB
```

不要：

```text
USB Hub
显示器 USB
扩展坞
```

因为你已经看到：

```text
FT_Write returned 0
```

这时候我不会把它当普通的 Vivado warning。

---

# P4 —— 检查 FT2232H 电源

测：

```text
USB 5V
FT2232H VCC
JTAG VCC
FPGA VCCAUX
VCCO_0
```

特别关注：

> **JTAG VREF 是否稳定。**

UltraScale JTAG TCK 是专门的关键时钟输入，UG570 也特别强调 TCK 要按 critical clock 对待；对于 JTAG 配置，TCK 是核心信号。([AMD 文档][8])

---

# P5 —— 示波器看 TCK

这是最有价值的硬件验证之一。

在 FPGA JTAG header 附近看：

```text
TCK
TMS
TDI
TDO
```

重点看：

```text
overshoot
undershoot
ringing
rise/fall time
```

尤其：

```text
TCK
```

如果：

```text
1 MHz OK
15 MHz NG
```

基本就很有戏了。

---

# P6 —— 最后才查电源能力

你说“电源灯亮、电压正常”。

这还不够。

要看：

```text
VCCINT
VCCAUX
VCCO
```

在 JTAG 配置瞬间有没有：

```text
droop
reset
oscillation
```

如果有示波器，最好触发：

```text
PROGRAM_B falling edge
```

然后观察：

```text
VCCINT
VCCAUX
INIT_B
DONE
TCK
```

这比测静态电压有意义得多。

---

# 十九、关于 Answer Record

这里我需要特别谨慎纠正一点：

**我目前没有找到一个 AMD/Xilinx 官方 Answer Record 能支持“UltraScale 的 MODE=001 会导致 JTAG 配置 DONE 不拉高”这个结论。**

反而 AMD 官方 UG570 给出的明确结论是相反的：

> JTAG configuration occurs independent of mode pin selection.

([AMD 文档][1])

因此如果有人告诉你：

> “KU060 的 M=001，所以不能 JTAG 下载，必须改成 JTAG mode。”

这对 UltraScale 来说是**错误或至少不完整的解释**。

UG570 还特别说明：

> JTAG interface 本身始终可用。([AMD 文档][9])

所以我不会为了迎合现象硬给你一个不存在的 AR。

---

# 二十、最终手段怎么排性价比？

我会这样排：

### ① 先降 JTAG 频率 + 极简 bitstream

**成本：0**

优先级最高。

---

### ② 换 USB cable / USB port / PC

**成本：0**

你已经有：

```text
FT_Write returned 0
```

所以非常值得。

---

### ③ 用另一只 JTAG Programmer 做 A/B Test

例如：

* Xilinx Platform Cable
* Digilent HS2/HS3
* SmartLynq

核心不是买设备，而是：

> **换掉 FT2232H 这一整条 JTAG host path。**

如果另一套 JTAG：

```text
100% 成功
```

那么你的 FPGA 和 bitstream 就基本洗清嫌疑了。

---

### ④ 示波器检查 JTAG + FPGA 电源

成本低，但需要设备。

这是我认为最值得的硬件定位。

---

### ⑤ 外置 SPI Flash Programmer

如果最终只是想把产品镜像写进 N25Q128：

```text
外部 SPI programmer
        ↓
N25Q128
```

这可以**完全绕开 Vivado 的 JTAG → FPGA → Flash 间接编程路径**。

然后：

```text
MODE=001
Power ON
↓
FPGA 从 N25Q128 boot
↓
DONE
↓
MicroBlaze
↓
Vitis
```

这其实是你当前硬件条件下一个非常漂亮的 workaround。

---

### ⑥ 改板

最后才考虑。

因为目前没有证据证明：

```text
MODE=001
```

本身是设计错误。

如果后续确认板级设计确实存在 JTAG SI / MODE / PROGRAM_B / 电源等问题，下一版 PCB 我会建议至少把：

```text
M2
M1
M0
PROGRAM_B
INIT_B
DONE
```

全部引到可控位置。

尤其 MODE 不应该焊死。

---

# 二十一、我对你这个问题的最终判断

目前我会把嫌疑排序成：

| 嫌疑                                   |          概率判断 |
| ------------------------------------ | ------------: |
| FT2232H / USB / JTAG transaction 不稳定 |         **高** |
| TCK 信号完整性 / JTAG 频率过高                |         **高** |
| JTAG startup/JSTART sequence 未完整完成   |         **高** |
| PROGRAM_B / INIT_B 板级时序              |             中 |
| FPGA 电源瞬态                            |             中 |
| 原始 MicroBlaze bitstream              |            中低 |
| `MODE=001` 导致 JTAG 不能 startup        | **极低 / 基本排除** |
| DONE LED/上拉硬件                        |        **极低** |

尤其你这个：

> **“偶发成功 + FT_Write returned 0 + 偶尔枚举不到设备”**

我会非常认真地对待。

因为如果真是：

```text
MODE=001 incompatible with JTAG
```

它应该表现为：

```text
100% deterministic failure
```

而不是：

```text
失败
失败
成功
失败
USB error
重新打开 Vivado
成功
又失败
```

**随机性本身就是重要诊断信息。**

---

## 我建议你现在只做 4 个实验

别再同时改十几个参数，容易把问题搅成一锅粥。

### 实验 1

**最小 counter/LED bitstream + `CONFIG_MODE=B_SCAN` + JTAG 1 MHz**

→ Program 20 次。

### 实验 2

同一个 bitstream：

```text
1 MHz
→ 500 kHz
→ 100 kHz
```

比较成功率。

### 实验 3

同一个 bitstream、同一个频率：

> **换一整套 JTAG cable/programmer**

这是最有诊断价值的 A/B test。

### 实验 4

失败后马上读：

```text
STATUS
```

尤其告诉我：

```text
DONE_PIN
DONE_INTERNAL_SIGNAL_STATUS
INIT_B_PIN
EOS
CFG_STARTUP_STATE_MACHINE_PHASE
GWE
GTS
MMCM_PLL_LOCKED
CRC_ERROR
BAD_PACKET_ERROR
IDCODE_ERROR
MODE
```

**这几个值一出来，基本就能把“JTAG传输没完成”和“startup内部卡住”进一步分开。**

---

### 官方资料

* [AMD UG570 — UltraScale Architecture Configuration User Guide](https://docs.amd.com/r/en-US/ug570-ultrascale-configuration?utm_source=chatgpt.com)：尤其看 **Using Boundary-Scan Configuration in UltraScale FPGAs、Status Register、Start-up Sequence、Configuration Pins**。UG570 明确说明 JTAG 配置独立于 MODE pin。([AMD 文档][1])
* [AMD UG908 2023.1 — Vivado Programming and Debugging](https://docs.amd.com/r/2023.1-English/ug908-vivado-programming-debugging/Programming-Configuration-Memory-Devices?utm_source=chatgpt.com)：Configuration Memory Device 的间接 JTAG 编程流程。([AMD 文档][6])
* [AMD UG912 — Vivado Properties Reference](https://docs.amd.com/r/en-US/2026.1/ug912-vivado-properties/CONFIG_MODE?contentId=E3K6f0PM3Xazvd~hp4kAXA&utm_source=chatgpt.com)：`CONFIG_MODE` 的正确属性形式是 `set_property CONFIG_MODE ... [current_design]`，不是 `BITSTREAM.CONFIG.CONFIG_MODE`。([AMD 文档][4])

**一句话总结：先别改 MODE，也别急着烧 Flash。先用最小 bitstream + `CONFIG_MODE=B_SCAN` + 1 MHz JTAG 做 20 次重复测试；如果成功率不是 100%，直接把调查重点转向 FT2232H/JTAG/USB/TCK。**

[1]: https://docs.amd.com/r/en-US/ug570-ultrascale-configuration/Using-Boundary-Scan-Configuration-in-UltraScale-FPGAs?utm_source=chatgpt.com "Using Boundary-Scan Configuration in UltraScale FPGAs - Using Boundary-Scan Configuration in UltraScale FPGAs - UG570"
[2]: https://docs.amd.com/r/en-US/ug570-ultrascale-configuration/Start-up-Sequence-Step-8?utm_source=chatgpt.com "Start-up Sequence (Step 8) - Start-up Sequence (Step 8) - UG570"
[3]: https://docs.amd.com/r/en-US/ug570-ultrascale-configuration/Status-Register-00111?utm_source=chatgpt.com "Status Register (00111) - Status Register (00111) - UG570"
[4]: https://docs.amd.com/r/en-US/2026.1/ug912-vivado-properties/CONFIG_MODE?contentId=E3K6f0PM3Xazvd~hp4kAXA&utm_source=chatgpt.com "CONFIG_MODE - CONFIG_MODE - 2026.1 English - UG912"
[5]: https://docs.amd.com/r/en-US/ug570-ultrascale-configuration/Accessing-Configuration-Registers-through-the-JTAG-Interface?contentId=o_DDATEof985yWvlnHXLgw&utm_source=chatgpt.com "Accessing Configuration Registers through the JTAG Interface - Accessing Configuration Registers through the JTAG Interface - UG570"
[6]: https://docs.amd.com/r/2023.1-English/ug908-vivado-programming-debugging/Programming-Configuration-Memory-Devices?utm_source=chatgpt.com "Programming Configuration Memory Devices - Programming Configuration Memory Devices - 2023.1 English - UG908"
[7]: https://docs.amd.com/r/2023.1-English/ug908-vivado-programming-debugging/Zynq-UltraScale-RFSoC-Configuration-Memory-Devices?utm_source=chatgpt.com "Zynq UltraScale+ RFSoC Configuration Memory Devices - Zynq UltraScale+ RFSoC Configuration Memory Devices - 2023.1 English - UG908"
[8]: https://docs.amd.com/r/en-US/ug570-ultrascale-configuration/Configuration-Pin-Definitions?utm_source=chatgpt.com "Configuration Pin Definitions - Configuration Pin Definitions - UG570"
[9]: https://docs.amd.com/r/en-US/ug570-ultrascale-configuration/Overview?utm_source=chatgpt.com "Overview - Overview - UG570"
