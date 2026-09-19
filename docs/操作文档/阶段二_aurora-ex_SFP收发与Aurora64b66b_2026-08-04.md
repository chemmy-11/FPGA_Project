---
type: 操作文档
摘要: 阶段二教学指南——SFP 收发与 Aurora 64b/66b 联调（IBERT 自检、环回、ILA）
阶段: 阶段二
目标: SFP 收发 + Aurora 64b/66b 编解码联调成功
created: 2026-08-04
updated: 2026-08-13
related: "[[短期待办]]"
---

# 阶段二 · SFP 收发 + Aurora 64b/66b 编解码（教学操作指南）

> **一句话目标**：让 KU060 的 GTH 高速收发器通过 SFP+ 光口，用 Aurora 协议收发数据，并亲眼看到链路建立信号拉高。
> **对应任务**：[[短期待办]] 阶段 2（2~3 周）· [[8.3/任务分工-2026-05-07]] 阶段五
> **前置状态**：✅ M1 已达成（2026-08-11，见 [[Agent 协作/M1进度总结_2026-08-11]]）。正式动手前，先以 design_1 的 AXI Interconnect + UART Lite（0x40600000）地址映射补 **AXI 总线族**基础（M1 总结的下一步，对应任务分工阶段二），再进入本阶段。
> **成功标准（M2）**：SFP+ 环回下 `channel_up`/`lane_up` 拉高，ILA 抓到 AXI-Stream 数据收发正常 ✅

---

## 0. 阶段二在做什么（30 秒版）

阶段一你让"软核 CPU"跑起来了。阶段二解决的是**数据怎么以万兆速度飞出芯片**：

```
  FPGA 内部（并行、慢、宽）
  ┌──────────────────────────┐
  │  AXI-Stream 数据流 64bit │
  └──────────┬───────────────┘
             │ Aurora 64b/66b IP（编码 + 串行化）
             ▼
  ┌──────────────────────────┐
  │  GTH 收发器（芯片里的高速串行电路）│
  └──────────┬───────────────┘
             │ 差分串行信号（Gbps 级）
             ▼
       SFP+ 光口 ──光纤──► 对面（或环回回来）
```

---

## 1. 概念卡片（小白必读，全懂再动手）

| 概念                                     | 通俗解释                                                                                                                                                                                          |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **GTH 收发器**                            | FPGA 里"跑极快"的专用电路，把并行数据变成高速串行差分信号（一个 Quad 含 4 个通道）。KU060 用的是 **GTHE3_CHANNEL** 原语。⚠️ 注意：KU060 属 UltraScale 架构，GTH 原语是 **GTHE3**（GTHE2 是 7 系列叫法），搜资料别按错名字 |
| **Aurora 64b/66b**                     | Xilinx 的免费高速串行协议：把 64 bit 数据 + 2 bit 同步头打包成 66 bit 传输。**为什么用 66b 而不是 8b/10b**？66b 开销小（10G 下能到 64/66 ≈ 97% 效率），且 2 bit 同步头能让接收端恢复时钟、对齐帧                                                        |
| **线速率 vs 数据速率**                        | 线速率 = 参考时钟 × 66。常用组合：156.25 MHz × 66 = **10.3125 Gbps**（即"10G"光口实际速率，10GBASE-R 也用）；125 MHz 等也可（QPLL 倍频），以 Aurora IP 界面支持列表为准；去掉编码开销后有效数据速率约 10 Gbps                                                                                         |
| **SFP+ 光口**                            | 板卡上的万兆光模块插槽（金属笼），插光模块 + 光纤通信                                                                                                                                                                  |
| **环回（Loopback）**                       | 让发送的数据绕一圈回到接收端。本阶段用**外部环回**：光纤/铜缆把 TX 和 RX 连起来                                                                                                                                                |
| **PRBS**                               | 伪随机二进制序列，用已知规律的"随机数"测链路，数出多少个 bit 出错来评估链路质量                                                                                                                                                   |
| **ILA**                                | Vivado 内置逻辑分析仪，抓 FPGA 内部信号波形（就像示波器，不过是数字的）                                                                                                                                                    |
| **channel_up / lane_up / gt_pll_lock** | Aurora 链路健康三信号：`gt_pll_lock`= 收发器时钟锁定了；`lane_up` = 物理通道建立了；`channel_up` = 整个 Aurora 通道通了。**三个全 1 才算通**                                                                                        |
| **CPLL / QPLL** | GTH 的锁相环：每个通道**私有 CPLL**（2.0~6.25 GHz）；每个 Quad **共享 QPLL0**（9.8~16.375 GHz）/ **QPLL1**（8.0~13.1 GHz）。**10G 线速率必须用 QPLL**（Aurora 10.3125G 对应 QPLL0） |
| **IBERT** | Xilinx 官方 GTH 测试 IP：内置 PRBS 生成/检查，经 JTAG 在 Vivado 界面看眼图——**不动 Aurora 就能先验证板卡光口物理链路**（本阶段 §2.6 自检用） |
| **光模块控制三件套** | SFP 座子三个关键控制脚：**TX_DISABLE 低有效**（给 0 才发光）；**RS0/RS1 速率选择**（线速率 >4.25G 必须给 1，10G 下两脚都拉高）——Aurora IP 不带这组脚，需自行处理 |
| **时钟补偿（Clock Correction）** | 收发参考时钟有微小频差，长期累积会让接收弹性缓冲溢出/下溢——发送端定期插特殊字符、接收端"满了删、空了补"。**别与 gearbox 每 32 拍背压混淆**：那是 64b/66b 编码分频比补偿，属正常现象（见 [[笔记和开发指南/光纤接口8b10b]] §三） |

---

## 2. 认识 KU060 的 GTH 架构（对应待办第 1 条）

在动手前先建立"地图"：

- **Quad**：GTH 按 4 个通道一组组织（UltraScale 命名如 **X1Y2**），每个 Quad 有自己的参考时钟引脚 **MGTREFCLK**（差分输入，每 Quad 两路 REFCLK0/1）。
- **通道**：每个 Quad 里 4 个 channel（GTHE3_CHANNEL），每个通道一对 TX 差分 + 一对 RX 差分，对应板卡上的一路 SFP+/ 连接器。
- **参考时钟方案（本工程）**：Aurora 10G 配置需要 **156.25 MHz** 差分参考时钟，从板卡的 **MGTREFCLK 专用引脚**输入（不能随便接普通时钟引脚）。本板实测（2026-08-12）：**SFP_CLK_P/N = P6/P5**，属 **GT Quad X1Y2**（GTHE3_COMMON_X1Y3），频率尚待确认。
- **电源与状态**：每个通道有 `gtpowergood`（收发器供电正常）。
- **PLL 分工**：**CPLL 每通道私有**（2.0~6.25 GHz）；**QPLL0**（9.8~16.375 GHz）/ **QPLL1**（8.0~13.1 GHz）整个 Quad 共享——**10G 用 QPLL0**。
- **通道内部 = PMA + PCS**：PMA 管模拟/串行（PISO/SIPO 串并转换、RX DFE、TX driver）；PCS 管数字处理（8B/10B 编解码、**64B/66B 同步变速箱 gearbox**、PRBS 生成/检查、弹性缓冲）。**Aurora 64b/66b 用的就是 PCS 里的 gearbox**。
- **回环类型**：近端 PCS / 近端 PMA / 远端 PMA / 远端 PCS 四种；本阶段光纤/铜缆环回属于**远端回环**（数据经线缆到对端收发器再回来）。详见 [[笔记和开发指南/光纤接口眼图]] §2.4-2.5。
- ⚠️ **手册版本差异（2026-08-26 修正）**：开发指南 V1.3 记录的是**底板光口版**板卡（156.25 MHz 晶振在底板、时钟球 **T6/T5 = MGTREFCLK1**）；本实验室板为 **FMC 四光口子卡版**（时钟球待定案，见下）。⚠️ 手册正文把通道写成 "X0Y11/X0Y9/…" 系**笔误**——同一颗芯片上 Bank 226 就是 Quad X1Y2（通道 X1Y8~Y11），Vivado 实测选 QUAD_226 后通道即落位 X1Y8~Y11。两板的 SFP→通道相对映射一致（SFPA=Y11、SFPB=Y9、SFPC=Y10、SFPD=Y8），真正差异在**参考时钟接的球对**与控制信号引脚；以开发层实测为准，手册只当方法论参考。

### 📖 开发板手册 → 必查 4 项（先查再动手）

> 📄 **新手查原理图入门**：不会查/不知道看哪 → 先读 [[操作文档/查开发板原理图入门]]（按信号名三步查法 + 查完填写表，含常见网络名速查与避坑）。

1. ✅ **SFP+ 光口位置与数量**：**4 个**（FMC 四光口子卡 SFPA~SFPD）→ 单口光纤环回 / 双口 DAC 都可行
2. ✅ **SFP+ 对应的 GTH Quad**：四个口共用 **Quad X1Y2**（GTHE3_CHANNEL_X1Y8~X1Y11）
3. ⏳ **MGTREFCLK 参考时钟**：引脚已确认（**SFP_CLK_P/N = P6/P5**），**频率待确认**（Aurora 10G 常用 156.25 MHz；**开发指南 V1.3 底板光口版为 156.25 MHz**，FMC 子卡版以实测为准）
4. ⏳ **SFP 控制信号**（TX_DIS/RX_LOS/RS0/RS1，LVCMOS33）：引脚表两版映射冲突，**版本待确认**。信号语义已通用（开发指南确认）：**TX_DISABLE 低有效**（给 0 才发光）、**RS0/RS1 在线速率 >4.25G 时拉高**（10G 下均给 1）、电平 LVCMOS33

> ✅ **已实测确认（2026-08-12，开发层查证）**：
> - **SFP+ 数量：4 个**（FMC 四光口子卡 SFPA~SFPD，非板载）
> - **GTH Quad：四个口共用 GT Quad X1Y2**（GTHE3_CHANNEL_X1Y8~X1Y11；SFPD=TX0、SFPB=TX1、SFPC=TX2、SFPA=TX3）
> - **MGTREFCLK：SFP_CLK_P/N = P6/P5**（GTHE3_COMMON_X1Y3，即 Quad X1Y2 的参考时钟；另一路 M5/M6 为第二 refclk）
> - **GT 差分对不需要 XDC PACKAGE_PIN 约束**（引脚表备注"差分引脚不用绑定"）——Aurora IP 选对 Quad 后由封装引脚自动定位，这也是官方 KU_IO.xdc 无 GT 内容的原因
> - 完整引脚表见工程文件 `FMC_4SFP_GTH引脚表.md`
> - ⚠️ **仍待查 2 项**（动手前务必确认）：① **SFP_CLK 频率**（Aurora 10G 需 156.25 MHz，频率不对 gt_pll_lock 不亮）——查 FMC 子卡原理图/问黄工；② **控制信号版本**（TX_DIS/RX_LOS/RS0/RS1，LVCMOS33）——引脚表两版映射冲突（工作表1 vs 副本，子卡在改、黄工知情），上板前确认用哪版

---

### 🧪 2.6 动手前自检：IBERT 板卡光口测试（强烈推荐，半天完成）

> 对应开发指南第 56 章（详见 [[笔记和开发指南/光纤接口眼图]]）。**意义**：先用官方 IBERT IP 验证"板卡 GTH + SFP 座 + 光模块 + 线缆"物理链路完好，把**硬件问题与 Aurora 配置问题分离开**——否则链路不通时你分不清是板卡坏了还是 Aurora 没配对。建议作为本阶段第 0 步。
> 📋 **手把手执行版**：[[操作文档/阶段二前置_IBERT眼图自检实操单]]（2026-08-23 建，逐击操作 + 定版参数 + 本板故障速查表，直接照它做）。

1. **新建独立工程**（如 `D:\FPGA\ibert_test`，part=`xcku060-ffva1156-2-i`）→ Add IP → **IBERT UltraScale GTH**。
2. **配置**（按实测板卡参数，与开发指南底板版对照）：
   - LineRate = **10 Gbps**（与 Aurora 目标一致）
   - Refclk = **以实测 SFP_CLK 频率为准**（待查项①；开发指南底板版为 156.25 MHz——**频率选错 PLL 永远不 Lock**）
   - PLL = **QPLL**（≥10G 必选）
   - GTH Location = 实测 **Quad X1Y2**（开发指南底板版写 Bank 226，是同一光口 Quad 的两种叫法）
   - Refclk Selection = 实测 **P5/P6** 那一路（IP 界面会显示 REFCLK 编号）
   - Clock Source = Quad clock
3. **Open IP Example Design** → 顶层加光模块控制三件套：`sfp_tx_disable=0`、`sfp_rs0=sfp_rs1=1`（FMC 版引脚按实测约束；**GT 差分对无需 PACKAGE_PIN 约束**）。
4. 光纤/铜缆环回 → 下载 → Hardware Manager 打开 **Serial I/O Links** 界面，看两栏：
   - **Erros = `0E0`**（无错误；上电初期不稳可点 **BERT Reset** 重测）
   - **RX/TX PLL Status = Locked**（不 Lock = 参考时钟问题，先解决再谈其他）
5. 创建**眼图**：眼睛张开、蓝色区域（低 BER）→ 板卡物理链路 OK ✅，放心进入第 3 节 Aurora 调试。
6. 拓展（开发指南 56.7）：线速率改 15G 观察**浴缸曲线**（论文实验素材）。

### 🎓 2.7 可选练手：GT Wizard 8b/10b 环回（想先吃透 GTH 再碰 Aurora）

> 对应开发指南第 57 章（详见 [[笔记和开发指南/光纤接口8b10b]]）。**与 IBERT 的区别**：IBERT 是"黑盒自检"，GT Wizard 是**你自己动手配收发器**——把"线路编码 → comma 对齐 → 时钟补偿"链路机制亲手走一遍，Aurora 的 gearbox 背压、时钟补偿在这里先见到原型。约 1 个下午，可选。

1. 新建工程 → Add IP → **Transceivers IP（GT Wizard）**，配置要点：preset **8B/10B**、10 Gbps、**QPLL0**、参考时钟按实测、用户位宽 32 / 内部 40、TXOUTCLK=**TXOUTCLKPMA**、comma 检测 **K28.5**、Clock Correction 开启（完整配置表见 8b10b 笔记 §三）。
2. Open Example Design → 顶层修改三处：① 注释 reset helper / link status 端口 ② 加 `sys_clk` 差分 → IBUFGDS 作**自由时钟** ③ 加光模块控制三件套。
3. 环回下载后跑 ILA：**`prbs_any_chk_error_int` 恒 0** 且 `rxdata_in` 持续变化 = 环回正确 ✅

---

## 3. 生成 Aurora 64b/66b IP（对照基线工程）

> 对应待办第 2 条。基线工程的 Aurora 端口清单见 [[8.3/2026-04-30/block_diagram]]（`aurora_64b66b_0` 和 `aurora_64b66b_1` 两个核，一收一发）。

### 3.1 新建一个测试工程（或复用阶段一工程）

建议**新建独立工程**（如 `D:\FPGA\aurora_test`，与 M1 工程同目录；`D:\FPGA` 目前不是 git 仓库，建议先 `git init` 再动工），先不加 MicroBlaze，专心搞链路——这就是"第二组独立验证"的思路，排除软核干扰。

⚠️ **器件 part 必须精确选择 `xcku060-ffva1156-2-i`（非 CIV 变体）**——M1 曾因选了 CIV 变体导致位流烧不进（`DONE PIN is not HIGH`），对照实验后才发现 part 选错（详见 [[Agent 协作/M1进度总结_2026-08-11]] 第五节复盘）。这是 M1 最大的坑，阶段二不要再踩。

### 3.2 添加 Aurora IP 并配置

1. `Add IP` → 搜索 **Aurora 64B66B** → 双击添加。
2. 双击 IP 打开配置（对照基线工程设置）：
   - **Line Rate**: 10.3125 Gbps（= 156.25 MHz × 66，即"10G"）——如果下拉没有，先选 refclk 频率再回来看
   - **Reference Clock**: 频率**待确认后填入**（待查项①）——以 SFP_CLK 实测频率为准，且须在 IP 支持列表内（156.25/125 MHz 等组合均可；开发指南底板版为 156.25 MHz）
   - **GT 收发器**: GTH
   - **GT Quad / 参考时钟选择**（2026-08-12 已查证）：Quad 选 **X1Y2**；Reference Clock 选引脚为 **P5/P6** 的那路（IP 定制界面会显示引脚号，另一路 M5/M6 是第二 refclk，选错的表现是 gt_pll_lock 不亮）
   - **Dataflow Format**: Streaming（流式；基线工程用的帧接口要看 block_diagram 确认——本教程用 Streaming 更简单）
   - **Interface**: AXI4-Stream
   - **User Interface Data Width**: 64 bit（⚠️ 与 [[8.3/任务分工-2026-05-07]] 的"接口契约"对齐——第一组 DMA 也是 64-bit）
   - **Lanes**: 1（单通道 10G）
   - **Flow Control**: 无（None，保持简单）
3. 记下生成的端口名（和 [[8.3/2026-04-30/block_diagram]] 对照）：`USER_DATA_S_AXIS_TX`（发送输入）、`USER_DATA_M_AXIS_RX`（接收输出）、`channel_up`、`lane_up`、`gt_pll_lock`、`user_clk_out`、`gt_refclk1`、`gt_serial_tx/rx` 等。

> 💡 **为什么 156.25 MHz**：Aurora 64B66B 的线速率 = 参考时钟 × 66（64 数据 + 2 同步头）。156.25 MHz × 66 = 10.3125 Gbps，正好是万兆。参考时钟频率选错，链路必挂（`gt_pll_lock` 永远不亮）。

### 3.3 连好外部端口

在 Block Design 里把 Aurora IP 的以下端口 **Make External**（或手动连）：
- `gt_refclk1`（差分参考时钟，来自板卡 MGTREFCLK 引脚——用 **util_ds_buf 的 IBUFDS_GTE** 缓冲后接入，基线工程里就是这么做的）
- `gt_serial_tx` / `gt_serial_rx`（差分串行，直连板卡 SFP+ 引脚）
- `reset_pb`（按键复位，可先接 `xlconstant_0` 即持续复位释放）
- `pma_init`（收发器复位，**必须等参考时钟稳定后再释放**——见第 7 节坑 1）
- `init_clk`（给 IP 的初始化时钟，通常 62.5/100 MHz，可用 Clocking Wizard 产生）
- `channel_up`、`lane_up`、`gt_pll_lock`（引出便于观察，可接到 ILA 或 LED）
- `user_clk_out`（IP 输出给用户逻辑的时钟，后面连 FIFO/ILA 用）
- **SFP 控制信号（TX_DISABLE 等）**：Aurora IP 本身不带，需自行处理——**TX_DISABLE 必须拉低光模块才发光**；本板控制信号映射版本待确认（待查项②），上板前先确认

> 💡 **本板 GT 差分对无需手工 PACKAGE_PIN 约束**（2026-08-12 查证：引脚表备注"差分引脚不用绑定"）——Aurora IP 选对 Quad（X1Y2）后封装引脚自动定位，官方 KU_IO.xdc 无 GT 内容也是这个原因。XDC 只需处理控制信号等普通 IO。

**Generate Output Products → Create HDL Wrapper → 综合 → 实现 → Bitstream**（流程同阶段一 3.6~3.8）。

### ✅ 检查点
- [ ] Aurora IP 参数：10.3125 Gbps / 64-bit AXI4-Stream / **Reference Clock 频率与 SFP_CLK 实测一致（待查项①）**
- [ ] 与基线工程 block_diagram 端口能对上
- [ ] Bitstream 生成成功

---

## 4. 用 Example Design 快速验证（本阶段最省事的捷径）

> 对应待办第 3 条。**Example Design 是 Xilinx 官方自动生成的"完整可跑测试工程"**：自带 PRBS/帧生成器、帧校验器、约束文件和 testbench，你只需要改引脚约束 + 上板，就能看到链路是否打通——**强烈建议先跑通它，再碰自己的设计**。

1. 在 Aurora IP 定制界面（双击 IP 弹出的窗口）左下角点 **"Open IP Example Design..."** → 选目录（工程外，如 `C:\aurora_exdes`）→ OK。
2. Vivado 会自动打开一个**独立的完整测试工程**。里面的顶层是 `aurora_64b66b_0_exdes`，自带：
   - **Frame Generator / Frame Checker**（自动发包、收包、数错包）
   - 完整的引脚约束文件 `.xdc`
   - 顶层有 `ERROR_COUNT`、`CHANNEL_UP`、`LANE_UP` 等状态输出（可接 LED 看状态）
3. **核对约束（本板 GT 引脚无需手工改）**：Example Design 的 .xdc 按所选 **Quad X1Y2** 自动生成 GT 引脚约束，逐项核对即可：
   - `gt_refclk1`：核对是否 P5/P6 那路（MGTREFCLK0/1_X1Y3）——无需手工 PACKAGE_PIN
   - `gt_serial_tx/rx`：核对对应通道（X1Y8~X1Y11 = SFPD~SFPA）——无需手工 PACKAGE_PIN
   - SFP 控制信号（`tx_disable` 等）若有：本板映射版本待确认（待查项②），确认后再补约束
4. **综合 → 实现 → Generate Bitstream**（Example Design 首次综合较久，正常）。
5. 检查 `ERROR_COUNT` 等输出端口类型（example design 顶层可能是网表化的，若不方便观察，可跳过本例直接看第 5 节的 ILA 方案）。

### ✅ 检查点
- [ ] Example Design 综合实现通过
- [ ] GT 引脚约束已改为板卡实际引脚

---

## 5. 上板：SFP+ 环回测试（对应待办第 3 条）

### 5.1 准备环回

| 环回方式 | 做法 | 适用 |
|---|---|---|
| **光纤环回**（推荐） | 光模块插进 SFP+ 笼，**一根光纤把模块的 TX 和 RX 口连起来**（或两根光纤在另一头互插） | 有光模块 + 光纤 |
| DAC 铜缆直连 | 万兆 DAC 线直接插两个 SFP+ 口（需板卡 ≥2 个光口） | 板卡有两个口 |
| 光模块短接 | 部分模块支持 RX-TX 内部环回（少见，看模块手册） | — |

> 💡 **术语对齐**：这种"数据经线缆到对端再回来"的环回在 GTH 术语里叫**远端回环**（vs IP 内部/近端回环，见 [[笔记和开发指南/光纤接口眼图]] §2.5）——IBERT 与 Example Design 默认都按远端回环验证链路。

📖 开发板手册 → **SFP+ 接口章节**（口的位置、数量、模块兼容性，供电是否需额外设置）。

> 🧩 **本板现状（2026-08-12 查证）**：SFP+ 在 **FMC 四光口子卡**上（SFPA~SFPD 共 4 口，共用 Quad X1Y2）。**光纤单口环回**（一根光纤短接 TX/RX）或 **DAC 双口环回**（任意两口插铜缆）均可；4 口也支持未来 4×10G 多通道扩展（契合课题多路径互联场景）。

### 5.2 下载并观察状态

1. Vivado → `Open Hardware Manager` → `Open Target` → 连接板卡（📖 手册 → JTAG）。⚠️ **实测**：下载线为正点原子 FT2232H（Vivado 识别为 Digilent JTAG-HS1），**同一时刻只允许一个客户端占线**——HW Manager 连着时 Vitis 的 Program FPGA 会抢不到线，务必先断开一边（M1 工作流中 Vitis 侧已取消 Program FPGA 勾选，见 [[Agent 协作/M1进度总结_2026-08-11]] 第四节）。
2. `Program Device` 选择你的 bitstream → Program。
3. 观察链路状态信号：
   - **`gt_pll_lock`** 先亮（时钟锁定，几毫秒内）
   - **`lane_up`** 再亮（物理通道建立）
   - **`channel_up`** 最后亮（协议通道建立）
   - 三灯全亮 = 链路通！🎉
4. 若 example design 有 `ERROR_COUNT`，看是否持续为 0（没数到错包）。
5. **拔掉光纤再插回**：观察信号会掉、又会重新建立——理解"链路训练"过程。

> ⚠️ 参考：[[8.3/Aurora/d8e77ba2-c98d-4e48-bda4-6741a163625e]] 的调试经验：`lane_up`/`channel_up` 代表链路/通道建立，`gt_pll_lock`/`gt_qpll_lock` 代表 PLL 锁定——**调试时先看锁没锁，再看通道通没通**。

### ✅ 检查点
- [ ] 光纤/铜缆环回接好
- [ ] `gt_pll_lock` = 1（否则查参考时钟！）
- [ ] `lane_up` = 1（否则查引脚/光模块/复位时序）
- [ ] `channel_up` = 1（链路建立 ✅）

---

## 6. 用 ILA 抓 AXI-Stream 波形（对应待办第 4 条）

链路通了，还要证明**数据真的在跑**。ILA 就是抓"内部证据"：

1. 回到你的 Block Design（3.3 的工程），Add IP → **ILA**（Integrated Logic Analyzer）。
2. 配置 ILA：
   - **Number of Probes**: 3~4 个
   - 每个 Probe 连一个信号：`USER_DATA_S_AXIS_TX`（发送接口，含 tvalid/tready/tlast/tdata）、`USER_DATA_M_AXIS_RX`（接收接口）、`channel_up`
   - **Sample Data Depth**: 1024 够用
   - **Input Clock**: 接 `user_clk_out`（Aurora 用户时钟，156.25 MHz 附近）⚠️ 各信号必须与 ILA 同时钟域，`user_clk_out` 是统一来源
3. 重新综合 → 实现 → Bitstream → Hardware Manager 下载。
4. Hardware Manager → 选中 ILA 核 → **Trigger Setup**（如 `channel_up = 1` 且 `tvalid = 1`）→ **Run Trigger**。
5. 查看波形：
   - **发送侧**：`tvalid`/`tready` 同时为高时数据在传；`tlast` 标记一帧结束
   - **接收侧**：环回数据回来，能看到和发送一致的数据模式
   - ⚠️ **预期现象**：Aurora 的 gearbox 每 32 个周期会插入 1 个周期的背压（`tready` 拉低一拍），这是**正常现象**，不是 bug（见 [[8.3/Aurora/d8e77ba2-c98d-4e48-bda4-6741a163625e]] 帧接口时序部分）
6. 数据对不上？先确认 Frame Generator 发的是什么模式，再对照接收波形逐拍检查。

### ✅ 检查点
- [ ] ILA 触发到发送波形（tvalid/tready/tlast 时序正确）
- [ ] 接收波形数据与发送一致（环回数据对）

---

## 7. 常见坑排查表（全部来自实战，务必先看）

| 现象 | 原因与处理 |
|---|---|
| `gt_pll_lock` 不亮 | **参考时钟问题**（90% 的锅）：频率不对（以 SFP_CLK 实测为准，须在 IP 支持列表内）、refclk 选错路（本板选 P5/P6 那路，别选 M5/M6）、时钟没起振。用 Vivado 的 `hw_vio`/IBERT 先确认时钟 |
| `lane_up` 不亮但 PLL 锁了 | ① 引脚约束错（TX/RX 反了或接错 Quad）② 光模块/光纤问题（换一根试试）③ `pma_init` 复位时序不对 |
| 链路通了但数据全错 | ① 64b/66b 对齐问题——检查同步头 ② 环回方向搞反 ③ 两端配置不一致（线速率/位宽） |
| `pma_init` 复位时序 | **PMA_INIT 是同步复位**：必须在 refclk 到来、PLL 锁定后释放。推荐做法（见 [[8.3/Aurora/d8e77ba2-c98d-4e48-bda4-6741a163625e]]）：refclk 经 IBUFDS_GTE 后进 PLL 产生 `init_clk`/`drp_clk`，`locked` 取反作为复位，保证同步 |
| 数据每 32 拍卡一拍 | 正常！gearbox 编码背压，见第 6 节第 5 条 |
| 跨时钟域数据乱 | 你的数据源时钟和 Aurora 用户时钟不同域时，**必须在中间加异步 FIFO**（AXI4-Stream Data FIFO，基线工程的 `axis_data_fifo_0/1` 就是干这个的） |
| 拔插光纤后链路不回 | 重新触发复位（`reset_pb`）或重新 program |
| 光模块不发光 / LOS 报警 | **控制三件套没配好**：① TX_DISABLE 没拉低（低有效，给 0 才发光）② **RS0/RS1 没拉高**——线速率 >4.25G 必须给 1，10G 下两脚都拉高，否则模块按低速工作；本板控制信号引脚版本待确认（待查项②） |
| 报 GT 资源冲突 | 两个 IP 用了同一个 Quad 的同一通道，改约束到不同通道 |
| 下载后 `DONE PIN is not HIGH` / startup LOW | **part 选错**（CIV vs 非 CIV）——M1 实锤根因：必须 `xcku060-ffva1156-2-i`（非 CIV），见 [[Agent 协作/M1进度总结_2026-08-11]] |
| IBERT 界面 Erros ≠ `0E0` | 链路有误码：先 **BERT Reset** 重测（上电初期链路不稳常见）；仍错则查光模块/线缆/参考时钟——**PLL Status 必须 Locked** 测试才有意义 |
| 参考时钟没起振 | 先确认时钟来源（FMC 子卡晶振 or 底板晶振，以原理图为准）。开发指南底板版板卡的 156.25 MHz 晶振在**底板**、经**板间连接器**才到核心板 GTH BANK——连接器接触不良也会表现为"没时钟" |

---

## 8. 里程碑自检（M2 判定标准）

- [ ] 能说出 KU060 GTH 架构（Quad X1Y2 / GTHE3 / MGTREFCLK P5-P6 方案）
- [ ] （推荐前置）**IBERT 板卡自检通过**：Erros=`0E0`、PLL Status=Locked、眼图张开（§2.6）
- [ ] Aurora 64b/66b IP 配置与基线工程对齐（10.3125 Gbps / 156.25 MHz / 64-bit）
- [ ] Example Design 或自己的设计上板，**三信号全亮**（pll_lock → lane_up → channel_up）
- [ ] ILA 抓到 AXI-Stream 收发波形，环回数据一致
- [ ] **SFP 收发 + 64b/66b 编解码联调成功** ✅（M2 达成）

达成后在 [[短期待办]] 阶段 2 打勾，进入中期任务（MIG/DDR4、AXI DMA，见 [[8.3/任务分工-2026-05-07]] 阶段三/四）。

📌 **注意体系区分**：任务分工的"阶段二＝AXI 总线族"与本待办的"阶段 2＝SFP 收发"是两个体系；M1 达成后先补 AXI 总线族（任务分工阶段二）作为本阶段前置，已写入 [[短期待办]]。

---

## 9. 参考资源

- **板卡手册笔记**（正点原子 KU060 开发指南 V1.3 第 56/57 章，2026-08-13 提取整理）：[[笔记和开发指南/光纤接口眼图]]（GTH 架构 + IBERT 眼图测试 + 板载 4 光口引脚/BANK/通道映射）、[[笔记和开发指南/光纤接口8b10b]]（8b/10b 编码原理 + GT Wizard 裸调 GTH 配置模板）——动手前可先按 IBERT 章节跑一遍板卡光口自检
- 实战文章：[[8.3/Aurora/d8e77ba2-c98d-4e48-bda4-6741a163625e]]（PMA_INIT 复位时序、跨时钟域 FIFO、链路信号排查——**必读**）、[[8.3/Aurora/article_107400764]] 等
- 基线工程对照：[[8.3/2026-04-30/FPGA-SFP-communication-with-Aurora 项目详细介绍]]、[[8.3/2026-04-30/block_diagram]]
- 分工与接口契约：[[8.3/任务分工-2026-05-07]]（阶段五 + AXI4-Stream 接口契约）
- 平台总览：[[8.3/README]]、[[8.3/讨论2026-08-03]]
