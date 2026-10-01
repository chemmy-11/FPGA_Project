# project_8 设计说明 — Aurora-UDP 数据级桥

> 目的：让 **PC 的实际 UDP 数据穿过 Aurora 64B/66B 编解码往返**，用脚本硬判据证明
> "上位机链路 + 64B/66B 收发"两件事同时成立。
> 短期目标对应《长期路线图》§四 验证金字塔第 ② 级（数据级），不是只亮灯。

---

## 1. 数据流（单向穿 Aurora，双向跨时钟域）

```
 PC ──RJ45(GE1,RGMII 125M)──> gmii_to_rgmii ──> 官方以太网栈(arp/icmp/udp) ──> udp 回显帧
                                                                                  │
                                                            eth_rxc 域 ───────────┘
                                                                                  ▼
                                                        frame_fifo_pump A (eth_rxc → user_clk)
                                                                                  ▼
                                                        axis_word_pack  8bit → 64bit AXIS
                                                                                  ▼
                                        u_aurora.s_axi_tx ──> 64B/66B 编码 ──> GT X1Y11
                                                                                  │
                                                      loopback=3'b010 近端 PMA 串行内环
                                                                                  │
                                        u_aurora.m_axi_rx <── 64B/66B 解码 <── GT X1Y11
                                                                                  ▼
                                                        axis_word_unpack 64bit → 8bit
                                                                                  ▼
                                                        frame_fifo_pump B (user_clk → eth_rxc)
                                                                                  ▼
 PC <──RJ45──────────── gmii_to_rgmii TX <──────────────┘
```

**关键取舍：Aurora 只插在"栈 TX → PC"这一条单向路径上。**
- PC→栈 方向直连 RGMII，不经 Aurora —— 回显帧的目的 MAC = 请求方 MAC（`des_mac=src_mac`），
  不会重新进栈，所以不存在无限回显；
- 只要能收到回显，就必然证明了数据穿过 64B/66B 编解码（这是判据成立的逻辑基础）。

## 2. 模块清单

| 来源 | 文件 | 说明 |
|---|---|---|
| 官方 39 例程（原样，未改一字节） | `rtl/arp/*`、`rtl/icmp/*`、`rtl/udp/*`、`rtl/gmii_to_rgmii/*`、`rtl/eth_ctrl.v` | 千兆以太网栈（RGMII + ARP/ICMP/UDP 回显） |
| IP | `ip/async_fifo_2048x8b` | 回显路径 8bit FIFO |
| project_7 复用 | `rtl/frame_fifo_pump.v` | 帧感知跨时钟泵（与 project_7 逐字节相同，C17 已修） |
| 新增 | `rtl/axis_word_pack.v` | 8bit 字节流 → 64bit AXIS（Aurora TX） |
| 新增 | `rtl/axis_word_unpack.v` | 64bit AXIS → 8bit 字节流（Aurora RX） |
| 新增 | `rtl/aurora_udp_bridge.v` | 顶层 |
| IP（共享逻辑在 example design） | `ip/aurora_64b66b_0`、`aurora_64b66b_0_reg_slice_0/2`、`shared_logic/*.v`（7 文件） | 必须一并加入：实例名是 `aurora_64b66b_0_support`，不是 `aurora_64b66b_0` |
| 参考不编译 | `rtl_ref/aurora_udp_top.v`（早期草案，GT X1Y8）、`rtl_ref/eth_udp_loop.v`（project_6 顶层，含 clk_wiz） | 放在 `rtl_ref/` 以免被 `rtl/*.v` 通配收进综合 |

## 3. Aurora 64B/66B AXIS 接口约定（本项目最容易踩的坑）

来源：IP 全部源码（`aurora_64b66b_v12_0_13`）+ UG576 Fig.3-7，逐条有代码行号证据，
完整报告见 vault：`Aurora64B66B_AXIS_接口约定结论.md`。

1. **字节序**：`tdata` 端口声明为 `[0:63]`（升序，下标 0 = MSB）。用普通 `[63:0]` wire
   按位置连接是逐位恒等。**第 1 个字节 → `tdata[7:0]`（lane0）**，第 8 个 → `tdata[63:56]`（lane7）；
   字内 lane 升序 = 流顺序；TX/RX 对称。
   证据：`axi_to_ll.v:131`（位保持）→ `tx_ll_datapath.v:152`（位保持）→ `sym_gen.v:181`（整字字节交换）
   → UG576 Fig.3-7（GT 先发 MSB 字节）；收侧由 `sym_dec.v:277/318` 反证。
   *自环回时 TX/RX 互逆，绝对顺序搞反也能通；但与第三方互通（uart_bridge、后续多板）时必须正确。*

2. **末拍 tkeep 必须"高位 lane 对齐"**：`tkeep = ~(8'hFF >> N)`，N = 有效字节数
   （N=1→`80`, 2→`C0`, 3→`E0`, 4→`F0`, 5→`F8`, 6→`FC`, 7→`FE`, 满拍→`FF`）。
   半满拍内仍 lane 升序，**lane7 = 帧最后 1 字节**。
   **与常见 Xilinx AXIS 的低位对齐（`0F`）相反**；若喂 `0F`，IP 会按"满 8 字节"处理 → 收端多出垃圾字节。
   证据：`axi_to_ll.v:146-156`（从最高 keep 位起扫得 REM）、`ll_to_axi.v:125-126`（同式生成 keep）、
   `sym_gen.v:204-212`（SEP 只带高 6 字节）。
   本设计实现：`axis_word_pack` 常规按 lane k 装第 k 字节，帧尾余字整体左移 `8*(8-N)`，
   `tkeep = 8'hFF << (8-N)`；`axis_word_unpack` 升序遍历 lane、跳过 keep=0 的 lane。

3. **tlast**：每帧恰好一个，落在最后一拍。Framing 模式用带内 SEP/SEP7 终止，
   **不插 SCP/ECP/PAD**（那是 8B/10B 的概念）。

4. **`s_axi_tx_tready=0` 时必须冻结** `tvalid/tdata/tkeep/tlast`。本设计打包输出队列 2 深，
   而输入速率被帧泵限制为 1 字节/user_clk 周期（≈1.2 Gbps « 10 Gbps），tready 基本恒高；
   若真溢出，`pack_ovf` 会在 ILA 上暴露。

5. **RX 侧没有 `m_axi_rx_tready`**（IP 内部接 0）→ 消费端必须永远 ready、不可反压，
   且 `tvalid` 允许有空洞。本设计用 64 字（512 B）字级环形缓冲 + 逐字节展开。
   *为什么 64 字够*：RX 的平均速率被发送侧限制为 1 字/8 周期（帧泵每周期只给 1 字节），
   环缓冲能吸收 8 倍于平均速率的突发；本项目帧长 ≤ ~2 KB，实测若出现 `unpack_ovf`
   再把 `AW` 从 6 提到 8（成本很低）。

## 4. 复位 / 时钟

- `init_clk` = 板载 100 MHz 差分（AK17/AK16）→ IBUFDS + BUFG；
- `reset_pb` = `~sys_rst_n` 经 init_clk 三级同步（高有效）；
- `pma_init` = 128 级移位链上电脉冲（≈1.27 µs，与例程同款）；
- 数据通路复位 `aurora_rst = ~sys_rst_n | ~channel_up`（同步于 user_clk）；
  帧泵复位：A 泵读侧/B 泵写侧用 `~aurora_rst`，另一侧用 `sys_rst_n`；
- `loopback = 3'b010`（近端 PMA 串行内环）：**单板即闭环，无需光模块/跳线**；
- `gt_rxcdrovrden_in = 0`、`power_down = 0`、DRP AXI4-Lite 全悬空（例程同款）。
- SFP 控制脚：`TX_DISABLE=0`（开激光）、`RS0=RS1=1`（>4.25G 档）；内环模式下不敏感。

## 5. 约束（`xdc/aurora_udp_bridge.xdc`）

引脚全部来自已上板验证过的来源：官方 39 例程（GE1 RGMII，project_6 实测通过）+
project_7 的 SFP 控制脚 + IBERT 定版（GT refclk = MGTREFCLK1_226 = T6/T5）。

**两条硬教训：**

1. **XDC 文件里不能用 `if` / `puts` / `foreach`**。Vivado 的 XDC 只支持受限 Tcl 子集，
   实测会报 `CRITICAL WARNING: [Designutils 20-1307]` 并把**整段约束丢弃**（不报错、不中断）。
   时钟组那几行因此写成裸命令。

2. **必须显式声明异步时钟组**。三组时钟互不相关：`eth_rxc`（PHY 晶振 125M）、
   `gt_refclk`（156.25M → MMCM 出 `user_clk` ~151.5M）、`init_clk`（板载 100M）。
   Vivado 默认对无共同祖先的时钟对**也**做建立/保持与恢复/移除分析，不加声明时：
   - WNS = **-2.661 ns**，失败路径全是 Aurora IP 内部 `bufg_gt_clr_delayed → CLR`
     （`async_default` 组）和 `*cdc_to*` 同步器输入，以及帧泵跨域指针/邮箱；
   - 这些路径数据延时只有 0.3~0.4 ns，罚分几乎全部来自时钟插入延迟差
     （SCD 4.3 ns vs DCD 1.8 ns）—— 典型"缺时钟组声明"特征，不是逻辑太慢。

   采用官方 exdes 的写法（`aurora_64b66b_0_exdes.xdc`，逐字对应）：

   ```tcl
   set_clock_groups -asynchronous -group [get_clocks init_clk  -include_generated_clocks]
   set_clock_groups -asynchronous -group [get_clocks gt_refclk -include_generated_clocks]
   set_false_path -quiet -to      [get_pins -quiet -hier *aurora_64b66b_0_cdc_to*/D]
   set_false_path -quiet -through [get_pins -quiet -hier *bufg_gt_clr_delayed_reg*/Q]
   ```

   单组 `-asynchronous` 的语义 = "本组与其余所有时钟互不相关"，`-include_generated_clocks`
   把 MMCM 派生的 `user_clk/sync_clk/tx_out_clk` 一并纳入，故这一行同时覆盖
   `eth_rxc ↔ user_clk` 的全部跨域路径。
   *前提是所有跨域信号确实做了同步*：帧泵格雷码指针双向 2FF、`frame_len_mb` 4 相握手邮箱、
   `wr_done_t/rd_done_t` 翻转标志 2FF、复位同步链 —— 本项目全部满足。

## 6. 构建流程（`scripts/`）

```powershell
# 1) 建工程（幂等）——必须在 ASCII 工作目录，中文路径会让 dbg_hub 子进程崩
cd D:\FPGA\project_8
vivado -mode batch -source scripts\create_project.tcl -notrace

# 2) 综合 + 脚本化插入双 ILA + 实现 + 位流（约 12 min）
vivado -mode batch -source scripts\build_debug.tcl -notrace
```

要点（都是踩过的坑）：
- `import_ip` 而非 `read_ip`（否则生成物路径漂移）；
- `-jobs 2`（KU060 上 3 个 IP 并行 OOC 会 OOM）；
- IP 失败后 `reset_run synth_1` 不会清 IP 的 OOC 运行，要显式
  `reset_run <ip>_synth_1`；
- 脚本化插 ILA：`create_debug_core` 只自动建 `clk` + `probe0`，**多余的探针端口
  不能用 `create_debug_port -type data` 建**（只支持 trig_in/trig_out）→ 用**单个宽 probe0**；
- `implement_debug_core` 前必须 `write_checkpoint` + `close_design` + `open_checkpoint`；
- 位流输出目录要先 `file mkdir`（否则 `write_bitstream` 报目录不存在）。

**ILA 分域（必须遵守）**：`u_ila_0` 挂 `user_clk`，`u_ila_1` 挂 `eth_rxc`。
`u_pump_rev` 的**写侧**在 `user_clk` 域（只有读侧在 `eth_rxc`），所以
`pump_rev_wr/drop` 必须挂在 ILA0；挂到 ILA1 会形成未同步采样路径 —— 首轮
WNS 的元凶之一，而且抓到的也只是亚稳态值。

产物：`out/aurora_udp_bridge.bit`、`scripts/probes.ltx`、`scripts/post_route.dcp`
（布线后检查点，位流出问题时可免重跑实现）、`out/rpt_timing_*.rpt`。

## 7. 上板判据

```powershell
# PC 网卡配 192.168.1.102/24，网线接开发板 GE1(RJ45)
python scripts\udp_verify.py
```

硬判据：**PC 发 payload P → 收 P′，要求 P′ == P**。
回显帧在板上必经 `栈TX → 帧泵 → 8→64 打包 → Aurora TX → GT 内环 → Aurora RX
→ 64→8 解包 → 帧泵 → RGMII TX`，故 P′ == P 即证明数据穿过 64B/66B 编解码往返。

脚本覆盖 payload 长度 26/27/28/29/30/31/32/33/40/63/100/200 —— 覆盖 8 种
`帧长 % 8` 余数类别，专门压打包/解包的"帧尾不足 8 字节"逻辑。

辅助证据：
- LED `T23`(led_link) = `channel_up`；`T22`(led_loop) = Aurora 收到过数据；
- ILA1：`pump_fwd_drop` / `pump_rev_drop` 应为 0（非 0 = 帧泵握手丢弃，
  降低发包速率或加大间隔）；
- ILA0：`channel_up/lane_up/soft_err/hard_err`、`unpack_frames/bytes`、`pack_frames`、
  `unpack_ovf/stall`。

## 8. 排障实录（首轮上板失败 → 闭环仿真定位 → 修复）

**首轮上板现象**：两灯亮（`channel_up=1`、Aurora 收到过数据）+ ping 不通。
LED 亮证明数据确实穿过 Aurora 回来了，故问题必在"回程出栈"这一段；
而 PC 连 ARP 都解不出来，说明**板卡发出去的帧是残破的**。

**定位手段：不依赖板子的闭环仿真**（`sim/tb_pack_unpack.v` + `sim/tb_dbg.v`）
- 模型：`pack → 小 FIFO（模拟 RX 缓冲）→ 随机 tvalid 空洞 → unpack`。
  PMA 串行内环在 beat/lane 层面等价于"原样送还"，且字节序/tkeep 约定对自环回**自洽**
  （写哪条 lane 就从哪条 lane 读回），故直通模型足以验证帧边界、tlast、帧尾余字、吞吐匹配。
- 判据与板上**同构**：输出侧出现空拍即视为一帧结束（这正是帧泵的判据），
  于是"帧被切断"这种在板上表现为 ping 不通的缺陷，在仿真里直接现形。

**三个缺陷（按发现顺序）**

| # | 缺陷 | 现象 | 修法 |
|---|---|---|---|
| 1 | "边收边吐"在 Aurora RX 流水线延迟下必然抽干缓冲 | 34 帧收回 **77 段**，`stall=40` | **整帧存储转发**：等 `wr_frames != rd_frames`（整帧到齐）再开始吐 |
| 2 | 末拍按 lane 扫描、keep=0 就跳过 → 帧中间留空拍 | 9 字节帧被切成 8+1（与首轮板上现象吻合） | `popcount(keep)` 算有效字节数，从首个有效 lane **连续吐 N 字节** |
| 3 | `lowidx8` 用 `for` 循环求最低有效位，**XSim 按升序求值** | 返回最高位 → 每帧最后 1 字节跑到帧首（`FF→7` 而非 `0`） | 改成无循环的 `if/else if` 优先链；`sim/tb_dbg.v` 留了对照 |

**修复后**：34 帧（长度 1~1000 字节，覆盖全部 `帧长%8` 余数，含随机空洞）
→ 34 帧全对、逐字节一致、无断流、无溢出（`stall=0`）。

**方法论教训（可写进论文/答辩）**
- 数字设计里"输出流的空拍"是**语义信息**（下游用它判帧尾）。凡有下游按边沿识帧的地方，
  上游必须给出**结构性保证**，不能依赖"通常不会发生"。本设计最终把保证做进结构：
  整帧缓冲 + 连续吐字节，帧内空拍在物理上不可能出现（`o_stall_cnt` 作金丝雀，常态恒 0）。
- **先把协议边界在仿真里钉死，再上板**：本轮三轮板上往返（构建 12 min + 人工烧录 + 测试）
  若能提前跑一遍 15 分钟的仿真，可全部省下。
- 工具坑留档：**不要依赖 XSim 对函数内 `for` 循环的求值顺序**（本仓库实测，见 §8 表 #3）。

## 9. 已知风险与后续

| 项 | 现状 | 处置 |
|---|---|---|
| 帧泵握手限流 | 上一帧未排空时新帧被丢弃（`*_drop` 计数） | 人工节奏够用；压力测试前需改成多帧缓冲 |
| `unpack` 环缓冲 64 字 | 平均速率下余量 8× | 若见 `unpack_ovf` → `AW` 6→8 |
| 打包队列 2 深 | tready 基本恒高，溢出即 `pack_ovf` | 同上，必要时加深 |
| 单向穿 Aurora | 只有栈 TX 过 Aurora | 双向桥属下一阶段（多板干线） |
| `key`/ARP | 与官方一致 | — |

**下一步（按路线图）**：① 上板跑通 `udp_verify.py` 并归档波形/截图；
② 把 `loopback` 改为 `3'b000` + 光模块/FC-FC 跳线做真链路；③ 双板干线。
