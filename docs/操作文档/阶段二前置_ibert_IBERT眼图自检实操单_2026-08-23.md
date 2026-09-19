---
type: 操作文档
摘要: IBERT 光口眼图自检实操单——新建工程→IBERT IP→例程→上板→Serial I/O Links→眼图判读，逐击操作
阶段: 阶段二（前置自检，M2 第 0 步）
目标: 用 IBERT 验证 FMC 四光口物理链路（GTH + 参考时钟 + 光模块 + 光纤），产出眼图截图
created: 2026-08-23
updated: 2026-08-27
related: "[[操作文档/阶段二_SFP收发与Aurora64b66b]] · [[笔记和开发指南/光纤接口眼图]] · [[短期待办]]"
---

# 阶段二前置 · IBERT 光口眼图自检（手把手实操单）

> 🎉 **实验状态：✅ 上板验证成功（2026-08-27）**——CLK1 参考时钟定版后重建位流，板级验证通过（PLL Locked + Errors=0E0）。眼图扫描截图待归档至 `D:\FPGA\ibert_eye_test\docs\`。下一步 → [[操作文档/挂起/阶段二前置之二_8b10b环回实操单]]。

> **一句话目标**：不动 Aurora，先用官方 IBERT IP 让光口跑起 PRBS，在 Vivado 里看到 **Errors=`0E0` + PLL Locked + 张开的眼图**——证明"芯片里的 GTH → 子卡金手指 → 光模块 → 光纤"整条物理链路是好的。
> **为什么先做这个**：之后 Aurora 调不通时，你能立刻分清是**板卡/光模块问题**还是 **IP 配置问题**——这就是把硬件问题与协议问题解耦（[[操作文档/阶段二_SFP收发与Aurora64b66b]] §2.6 的展开执行版）。
> **分工**：所有点击/上板操作归你；遇到现象异常 → 把截图/报错发我，我帮你判读。
> **预计耗时**：首次全程 2~4 小时（其中综合实现约 20~40 分钟，可挂着干别的）。

---

## 0. 本板参数卡（2026-08-27 实测定版，全部闭环）

| 参数 | 值 | 来源 |
|------|-----|------|
| part | `xcku060-ffva1156-2-i`（**非 CIV！**） | M1 血泪教训，见 [[Agent 协作/M1进度总结_2026-08-11]] |
| 光口 | FMC_4SFP 子卡 ×4（SFPA~SFPD） | `D:\FPGA\FMC_4SFP_GTH引脚表.md` |
| GT Quad | **X1Y2**（IP 界面显示名 **QUAD_226**，同一事物两种叫法；通道 X1Y8~X1Y11：SFPD=Y8、SFPB=Y9、SFPC=Y10、SFPA=Y11） | 实测定案：选 226 后通道落位 X1Y8~Y11 + 引脚表 `226_TX*/RX*` 双证 |
| 参考时钟 | **MGTREFCLK1_226（T6/T5），156.25 MHz** | ✅ 实测闭环：IBERT 上板 PLL Locked 验证；手册原文"226_CLK1_P 对应光口外部输入时钟" |
| 控制信号引脚版本 | **版本 A**：TX_DIS=H26/AH12/J25/AF12，RS0=G27/AH11/M26/AF13，RS1=H27/AG11/M25/AE13（索引 0~3 = SFPD/B/C/A） | ✅ 三方一致：指南 §5.3 XDC = 板卡引脚表工作表1 = 实现落位报告 12/12 |
| PLL 选择 | **QPLL**（10G 必选 QPLL0：9.8~16.375 GHz） | GTH 架构，见 [[笔记和开发指南/光纤接口眼图]] §2.2 |

⚠️ **手册 vs 本板的差异只剩两处**（其余配置照手册走）：① 手册正文写"Quad X0Y2"是笔误，实为 Bank 226 = X1Y2；② 手册底板版与本 FMC 子卡版的**参考时钟球对一致**（都走 CLK1/T6T5），控制脚球号见上表版本 A。**手册只当方法论参考，参数一律以上表为准。**

### 📦 开工前硬件盘点

- [ ] 核心板 + FMC 子卡连接牢固（改版后的子卡），供电正常
- [ ] **10G SFP+ 光模块** ×1（单口自环）或 ×2（双口互连）——千兆模块跑不了 10G，看模块丝印速率
- [ ] **LC-LC 光纤跳线**，与模块匹配（单模模块配单模黄线，多模配多模橙线）
- [ ] FT2232H 下载线（Vivado 识别为 Digilent JTAG-HS1）
- [ ] 💡 激光安全：10G 模块发光端勿直视（好习惯，虽然 Class 1 模块一般无害）

### 📝 开工前信息回填（30 秒）

1. 控制信号引脚版本：**A**（工作表1：AF12/AH12/J25/H26…）还是 **B**（副本：AD25/AC26/F27/A27…，RS0/RS1 未列）？→ 填到上面参数卡横线处。**若确认的是 B 且拿不到 RS0/RS1 引脚号**：RS 脚悬空不接也能先做 §8 近端回环，但远端光口环回必须补齐。
2. 环回方式：**单口光纤自环**（一根跳线把同一模块的 TX/RX 口短接，推荐，最简单）或 **双口互连**（两模块两根线交叉接）。

---

## 1. 新建独立工程

> **为什么单独建**：不污染 M1 主线工程 project_1（MicroBlaze 系统）；IBERT 自检是"用完即弃"的验证工程。

1. 双击 `"D:\Xilinx\Vivado\2023.1\bin\vivado.bat"` 启动（桌面快捷方式亦可）；
2. **Quick Start → Create Project** → Next；
3. Project Name：`ibert_eye_test`；Project Location：`D:\FPGA\ibert_eye_test`（⚠️ **全英文路径**，Vivado 对中文路径乱码——开发层实测红线）；勾选 *Create project subdirectory* → Next；
4. Project Type：**RTL Project**，*Do not specify sources at this time* 打勾 → Next；
5. **Default Part**：Parts 搜索框输入 `xcku060-ffva1156-2-i`，选中它（⚠️ **不是** `xcku060_CIV` 系列——M1 曾因选 CIV 位流烧不进，实锤根因）→ Next → Finish。

✅ 检查点：Flow Navigator 左侧出现 PROJECT MANAGER，标题栏工程名正确。

---

## 2. 添加 IBERT IP 并配置

> **为什么用 IBERT**：Xilinx 官方误码测试 IP，内置 PRBS 生成器/检查器，经 JTAG 直接在 Vivado 界面看链路状态和眼图——零 RTL 代码量（除了光模块使能脚）。

### 2.1 添加 IP

1. Flow Navigator → PROJECT MANAGER → **IP Catalog**；
2. 搜索框输 `IBERT` → 在 *Debug & Verification > Bit Error Testing* 下找到 **UltraScale GTH 的 IBERT**（名称形如 *IBERT UltraScale GTH* / *IBERT UltraScale+ GTH Quad*，以你版本搜索结果为准；生成例程的顶层名应为 `example_ibert_ultrascale_gth_0`，可作对照）→ 双击添加 → 弹出的 IP 定制窗口保持默认名 → Generate/OK。

![[笔记和开发指南/assets/图56.4.1_添加IBERT_IP.png]]
> 📷 原书底板版截图，界面布局一致；你的 IP 列表项以搜到的实际名称为准。

### 2.2 配置 IP（双击刚生成的 IP 重新打开定制窗）

**Protocol Definition 页**（对照下图）：

| 配置项 | 取值 | 为什么 |
|--------|------|--------|
| Component Name | 默认 | — |
| Number of Protocols | **1** | 单协议测试足够 |
| LineRate (Gbps) | **10** | 与后续 Aurora 10G 同速率；GTH 支持 0.5~16.375G |
| Data Width | **40**（默认） | 内部数据路径位宽 |
| Refclk (MHz) | **156.25** | 你的 SFP_CLK 定版频率（待查项①已闭环） |
| Quad Count | **1** | 4 个光口共用 Quad X1Y2 |
| PLL | **QPLL** | 10G ≥ QPLL0 下限 9.8 GHz；CPLL 只到 6.25 GHz 带不动 |

![[笔记和开发指南/assets/图56.4.2_Protocol_Definition选项.png]]

**Advanced Settings 页**：全部默认（Equalization mode=Auto：插入损耗 >14dB 自动用 DFE，否则 LPM；PPM offset 默认）——首次自检不折腾均衡。

![[笔记和开发指南/assets/图56.4.3_Advanced_Settings选项.png]]

**Protocol Selection 页**（关键页，选错这里 = PLL 永远不 Lock）：

| 配置项 | 取值 | 为什么 |
|--------|------|--------|
| GTH Location | 选 **QUAD_226**（它就是 X1Y2！） | 实测定案（2026-08-26）：选 226 后通道落位 X1Y8~Y11 = FMC 四口；手册正文"Quad X0Y2"系笔误 |
| Protocol Selected | 默认 Custom1 / 10Gbps | 单协议 |
| Refclk Selection | 展开下拉**认准引脚号**：SFP_CLK 实际接哪对就选哪对（MGTREFCLK0_226=V6/V5，MGTREFCLK1_226=T6/T5；如下拉出现带 P5/P6 的项则直接选它） | 选错唯一症状 = PLL 不 Lock；IBERT 试错零成本，不 Lock 就换另一对 |

![[笔记和开发指南/assets/图56.4.4_Protocol_Selection选项.png]]

> 🔍 **命名陷阱说明（2026-08-26 定案）**：IP 界面用 **Bank 号**（QUAD_226）称呼 Quad，手册正文却把它写成"Quad X0Y2"——**后者是笔误**。实测证据：① 选 QUAD_226 后 Vivado 生成的 IP 约束把通道落在 `GTHE3_CHANNEL_X1Y8~Y11`（= FMC 四口所在，X1Y2 的通道段）；② 板卡引脚表把四口数据对标为 `226_TX0~3/RX0~3`。**结论：QUAD_226 = X1Y2 = 你的四个光口，放心选。**
> 🔍 **生成例程后的 30 秒自检**：打开例程 `imports\example_ibert_ultrascale_gth_0.xdc` 看 `gth_refclk` 的 PACKAGE_PIN——落在 **V6/V5 或 T6/T5** 都属正常（这就是 QUAD_226 仅有的两对参考时钟球）；之后 PLL 是否 Lock 会告诉你选没选对**那一对**。

**Clock Setting 页**：

| 配置项 | 取值 | 为什么 |
|--------|------|--------|
| Source | **Quad clock** | IBERT 系统时钟直接取 Quad 的参考时钟分频，省一个外部时钟输入 |

![[笔记和开发指南/assets/图56.4.5_Clock_Setting选项.png]]

点 **OK** 完成定制。

---

## 3. 生成官方例程（Open IP Example Design）

> **为什么用例程**：IBERT 例程自带完整的复位/时钟结构和 JTAG 调试接口，你只需要补光模块使能脚——从零自己搭反而容易漏。

1. Sources → IP Sources → 右键 `ibert_...` IP → **Open IP Example Design...**；

![[笔记和开发指南/assets/图56.4.6_创建官方例程.png]]

2. 路径选 **工程外** 目录：`D:\FPGA\ibert_exdes`（⚠️ 别放进工程目录内部）→ OK；

![[笔记和开发指南/assets/图56.4.7_选择路径.png]]

3. 等待自动生成并打开新工程（几十秒）。

![[笔记和开发指南/assets/图56.4.8_官方例程.png]]

---

## 4. 补光模块控制脚（唯一的代码改动）

> **为什么必须加**：SFP 光模块出厂默认 **TX_DISABLE 有效（不发激光）**；且线速率 >4.25G 时必须 **RS0/RS1 拉高**选高速率挡——不加这两组脚，光纤对端永远收不到光，IBERT 再正确也测不出远端链路。

1. 打开例程顶层 `sources_1 → example_ibert_ultrascale_gth_0.v`（Sources 窗口双击）；
2. 在端口声明区（`module ... ( ... );` 内）**追加** 12 个输出：

```verilog
    // ---- SFP module control (FMC_4SFP), added <date> ----
    output wire SFPA_TX_DIS, SFPB_TX_DIS, SFPC_TX_DIS, SFPD_TX_DIS,
    output wire SFPA_RS0, SFPA_RS1,
    output wire SFPB_RS0, SFPB_RS1,
    output wire SFPC_RS0, SFPC_RS1,
    output wire SFPD_RS0, SFPD_RS1
```
> 注意与上一行之间补一个逗号（Verilog 语法：端口列表项之间用逗号分隔）。

3. 在模块体内（任意 `assign`/逻辑附近）**追加**常量驱动：

```verilog
    // TX_DISABLE is active-low: drive 0 to ENABLE laser
    assign SFPA_TX_DIS = 1'b0;
    assign SFPB_TX_DIS = 1'b0;
    assign SFPC_TX_DIS = 1'b0;
    assign SFPD_TX_DIS = 1'b0;
    // Rate select: high for line rate > 4.25G (10G -> both high)
    assign SFPA_RS0 = 1'b1;  assign SFPA_RS1 = 1'b1;
    assign SFPB_RS0 = 1'b1;  assign SFPB_RS1 = 1'b1;
    assign SFPC_RS0 = 1'b1;  assign SFPC_RS1 = 1'b1;
    assign SFPD_RS0 = 1'b1;  assign SFPD_RS1 = 1'b1;
```
> 只点亮要用的口也行（比如只用 SFPA：其余 TX_DIS 给 1'b1 关掉）——首跑建议全开，少一个变量。

4. `Ctrl+S` 保存。

---

## 5. 加约束文件（只约束控制脚，GT 差分对不用管）

> **为什么 GT 差分对不用约束**：IBERT 选定 Quad X1Y2 后，TX/RX 差分对由封装引脚自动落位（引脚表备注"差分引脚不用绑定"）；XDC 只需管普通 IO。

1. Flow Navigator → **Add Sources** → *Add or create constraints* → Next → **Create File** → 名字 `sfp_ctrl.xdc` → Finish → 选中它 → Finish；
2. 双击打开 `sfp_ctrl.xdc`，按你确认的**版本**粘贴其一（⚠️ **注释保持纯英文**——中文注释在 Vivado 编辑器会 GBK 乱码）：

**版本 A**（工作表1/老表；⚠️ 端口名按例程顶层的 vector 风格 `sfp_tx_disable[3:0]` 等映射——索引与丝印的对应关系本实验不敏感，四口全开时只要 12 个球都对即可）：

```tcl
# ===== FMC_4SFP control signals, VERSION A (pin sheet worksheet-1) =====
# index mapping (same as dev-guide example): [0]=SFPD [1]=SFPB [2]=SFPC [3]=SFPA
set_property -dict {PACKAGE_PIN H26  IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[0]}]
set_property -dict {PACKAGE_PIN AH12 IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[1]}]
set_property -dict {PACKAGE_PIN J25  IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[2]}]
set_property -dict {PACKAGE_PIN AF12 IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[3]}]
set_property -dict {PACKAGE_PIN G27  IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[0]}]
set_property -dict {PACKAGE_PIN AH11 IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[1]}]
set_property -dict {PACKAGE_PIN M26  IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[2]}]
set_property -dict {PACKAGE_PIN AF13 IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[3]}]
set_property -dict {PACKAGE_PIN H27  IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[0]}]
set_property -dict {PACKAGE_PIN AG11 IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[1]}]
set_property -dict {PACKAGE_PIN M25  IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[2]}]
set_property -dict {PACKAGE_PIN AE13 IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[3]}]
```

**版本 B**（子卡改版后副本；⚠️ 该版引脚表未列 RS0/RS1——若确认用 B，向黄工要 RS 引脚号后补齐，否则 RS 悬空无法保证高速率挡）：

```tcl
# ===== FMC_4SFP control signals, VERSION B (pin sheet copy) =====
set_property -dict {PACKAGE_PIN AD25 IOSTANDARD LVCMOS33} [get_ports SFPA_TX_DIS]
set_property -dict {PACKAGE_PIN AC26 IOSTANDARD LVCMOS33} [get_ports SFPB_TX_DIS]
set_property -dict {PACKAGE_PIN F27  IOSTANDARD LVCMOS33} [get_ports SFPC_TX_DIS]
set_property -dict {PACKAGE_PIN A27  IOSTANDARD LVCMOS33} [get_ports SFPD_TX_DIS]
# RS0/RS1 pins NOT listed in version-B sheet: fill after confirmation
```

💡 **DRC 就是保险丝**：如果版本粘错，实现阶段 DRC 大概率报 IO bank 电平冲突/位置冲突错误——报错了别慌，回头换另一版即可。

3. 保存。

---

## 6. 综合 → 实现 → 生成位流

1. Flow Navigator 依次点 **Run Synthesis**（弹窗直接 OK）→ 完成后 **Run Implementation** → 完成后 **Generate Bitstream**；
2. 全程约 20~40 分钟（首次含 IP 综合较慢）。挂机等即可；
3. ⚠️ 期间**不要**同时开第二个 Vivado 占用同一工程；消息窗口的 warning 里 LMB/未连接类无害警告可忽略（同 M1 经验）；
4. 三步全绿 ✅ 后进入上板。

---

## 7. 上板连线（物理层，照抄即可）

1. **断电**状态下检查 FMC 子卡插紧、光模块插入 SFPA（或你选定的口，簧片扣好）；
2. 光纤自环：把 LC 跳线两头分别插到**同一个光模块**的 TX 口和 RX 口（模块面板有 ▲发送/▼接收标识，仔细看丝印）；双口互连则 A 模块 TX → B 模块 RX、B 的 TX → A 的 RX；
3. 接 FT2232H 下载线（核心板 JTAG 座 ↔ PC USB）；
4. 上电（核心板电源 → 子卡随核心板供电）。

---

## 8. Hardware Manager：先看链路状态

> **观测顺序铁律：先 PLL 锁没锁 → 再看有没有误码 → 最后才谈眼图**（[[8.3/Aurora/d8e77ba2-c98d-4e48-bda4-6741a163625e]] 的实战经验）。

1. Flow Navigator → **Open Hardware Manager** → 顶部绿条 **Open target → Auto Connect**；
   - ⚠️ FT2232H 同一时刻只能被一个客户端占用：HW Manager 连接着就别让 Vitis 同时 Program FPGA（M1 已知坑）；
2. 右键器件 → **Program Device...** → 确认 Bitstream 路径 → Program（几秒～十几秒）；
3. Program 成功后 Hardware 窗口出现 `xcvu.../xcku060` 和 **hw_ibert_...** 核 → **双击 hw_ibert 核**打开仪表盘；
4. 切到 **Serial I/O Links** 页签，重点四栏（对照下图界面）：

| 栏目 | 期望值 | 说明 |
|------|--------|------|
| **RX/TX PLL Status** | **Locked**（两栏都要） | 不 Lock = 参考时钟问题，见下方排查树 |
| **Erros** | **`0E0`** | 0×10⁰ = 零误码（列名 Erros 是原书拼写，Vivado 里即 Errors） |
| TX Pattern / RX Pattern | PRBS-7（默认一致即可） | 收发模式必须同类才能比对 |

![[笔记和开发指南/assets/图56.5.4_Serial_IO_Links界面.png]]

5. 上电初期链路不稳属正常：工具栏点 **BERT Reset** 清零重测一次再读数。

### 🔍 PLL 不 Locked 排查树（按序执行）

1. **Refclk 选错路？** 回 IP 配置核对是否 P5/P6 那路（≠ M5/M6）；
2. **频率填错？** 确认 IP 里 Refclk=156.25 MHz；若黄工给的其实是别的值（如 125），改 IP 重生成；
3. **子卡时钟没起来？** 万用表/示波器量 SFP_CLK_P（物理层）；或回想子卡改版是否动了晶振电路——把现象记下来反馈黄工；
4. 都排除仍不锁 → 截图发我。

### 🔬 （可选但推荐）近端回环预检

> **价值**：不开光模块就能验证"GTH 本体 + 参考时钟"健康，把故障域进一步缩小到"光模块/光纤"。

- 在 IBERT 仪表盘中右键任一**收发器通道**（transceiver）→ **Create Loopback**（名称近似）→ 选 **Near-end PMA**；
- 观察该链路 Errors 是否回到 `0E0`；四个通道可轮流做一遍（顺便验证 4 个口对应的通道都活着）；
- 测完记得**删除回环**（右键 → Remove），否则远端测试会被近端短路。

---

## 9. 创建眼图

> **眼图是什么**：把接收信号按码元周期重叠扫描出来的"眼睛"。**水平张开度 = 抖动裕量，垂直张开度 = 噪声裕量**；颜色代表区域误码率（BER）：**越蓝越低、越红越高**。眼睛张得越大 = 信号质量越好。

1. 在 Serial I/O Links 页选中你要测的**链路行**（如 X1Y11/SFPA 那条）→ 右键 → **Create Eye Diagram...**（或仪表盘工具栏的 Eye Scan 按钮，名称以界面为准）；
2. 弹窗参数**默认即可**（扫描范围/分辨率/BER 目标都有合理预设）→ OK；
3. 扫描需几分钟（进度可见），完成后左侧 **Eye Diagrams** 区出现热力图；
4. **判读**：
   - ✅ 合格：眼睛明显张开、中心大片深蓝（BER 低）；
   - ⚠️ 勉强：眼偏小但仍有蓝心——能通信，记下数据留对比；
   - ❌ 不合格：满屏红/花——查光模块速率挡（RS 脚）、光纤脏污（无尘布擦 LC 头）、换线换模块对照；
5. **截图存档**：右键图像 → 导出/截图，命名 `ibert_eye_SFPA_10G_2026MMDD.png` 存入 `D:\FPGA\ibert_eye_test\docs\`（论文 5.2 节素材，也是给导师看的证据）。

![[笔记和开发指南/assets/图56.5.7_光口眼图.png]]

6. 拓展（原书 56.7，可选）：LineRate 改 15G 重扫一眼，观察眼图收窄——直观感受"速率↑ → 裕量↓"，论文对比素材。

---

## 10. 结果记录（做完立即回填，防记忆蒸发）

| 项目 | 结果 |
|------|------|
| 测试日期 / 工程路径 | |
| 引脚版本（A/B） | |
| Quad / 通道（如 X1Y11） | |
| PLL Status | Locked / Not locked |
| Erros（BERT Reset 后） | |
| 近端回环预检（做过的话） | 通过 / 未做 |
| 眼图截图路径 | |
| 结论 | 物理链路 OK，可进 Aurora ✅ |

**收尾动作（5 分钟）**：
- [ ] 结果同步给 VSCode Reasonix 更新 `D:\FPGA\AGENTS.md`（待查项①②正式闭环）+ git 提交例程工程与截图；
- [ ] [[操作文档/阶段二_SFP收发与Aurora64b66b]] §2.6 与 [[短期待办]] 对应项打勾；
- [ ] 把"实测频率/引脚版本/通道映射"回填 [[笔记和开发指南/光纤接口眼图]] §四参数表（知识沉淀）。

---

## 11. 故障速查表（本板定制版）

| 现象 | 最可能原因 → 处理 |
|------|------------------|
| PLL 不 Lock（Quad 已确认 QUAD_226） | **参考时钟选了另一对**：在 MGTREFCLK0(V6/V5)/MGTREFCLK1(T6/T5) 之间切换重试；仍不锁查子卡晶振供电/焊接 |
| Program 报 `DONE PIN is not HIGH` / startup LOW | **part 选错 CIV** → 确认 `xcku060-ffva1156-2-i`（M1 实锤） |
| PLL 永远不 Lock | 参考时钟三连查：选路（P5/P6）→ 频率值（156.25）→ 子卡晶振是否起振（§8 排查树） |
| PLL 锁了但 Errors 居高不下 | ① 先 BERT Reset；② 光模块速率挡（RS0/RS1 必须为高）；③ 光纤/模块换件对照；④ 近端回环区分 GT 问题还是光路问题 |
| 远端全无反应、近端正常 | TX_DIS 没拉低（检查 XDC 版本是否粘对/端口名拼写一致）或模块坏 |
| DRC 报 IO 冲突 | 引脚版本粘错 → 换另一版 XDC |
| Auto Connect 找不到目标 | 下载线驱动/被 Vitis 占用——关闭另一端重试（FT2232H 独占） |
| 眼图全红 | 速率挡不对（RS 脚悬空？）→ 补齐 B 版 RS 引脚约束后再扫 |
| 4 口中某口怎么测都错 | 单口硬件问题（焊接/座子），换口继续，坏口记入反馈黄工清单 |

---

## 12. 通过之后

物理链路绿灯后，带着这些**实测结论**进 [[操作文档/阶段二_SFP收发与Aurora64b66b]] §3 生成 Aurora 64b/66b：Quad=X1Y2、Refclk=P5/P6@156.25MHz、通道映射（SFPA=X1Y11…）直接照抄，Aurora 配置不再有任何猜的成分。

> 📖 理论配套：[[笔记和开发指南/光纤接口眼图]]（GTH 架构/IBERT 原理/眼图判读，图片已入库）· [[笔记和开发指南/光纤接口8b10b]]（想更深理解编码与对齐再看）
