---
type: 调试记录
摘要: project_8 数据级桥根因——帧泵 rd_empty off-by-one 致每帧丢尾字节；整链仿真定位并修复，5 帧逐字节 PASS
created: 2026-09-17
related: "[[操作文档/阶段二之八_Aurora_UDP数据级桥上板验证单_2026-09-10]] · [[Aurora-UDP数据级桥_汇报_2026-09-04]] · [[短期待办]]"
---

# 数据级桥根因修复：帧泵 rd_empty off-by-one（2026-09-17）

> 方法：以官方例程 + 官方 XDC + 已验证的 project_6 为第一性基准；AI 生成文档仅作参考。
> 手段：不上板，先做**整链闭环仿真**（官方栈 + 双帧泵 + 打包/解包 + Aurora AXIS 模型）。

## 一、结论（一句话）

板上 ping/UDP 全不通的**机制性根因**是 `frame_fifo_pump` 的读侧判空信号 off-by-one：
每一帧的**最后一个字节**被误判为 FIFO 空而拒绝读出 → 回显帧尾部被截断 → PC 网卡按 FCS 校验丢弃 →
表现为 ARP/ping/UDP 全丢。该缺陷存在于**历代所有位流**（含 unpack 修复后的 15:07 版）。

## 二、根因定位链

1. **第一性对差**：project_8 的以太网栈（arp/icmp/udp/eth_ctrl/rgmii）与已知能通的 project_6
   **逐字节相同**；project_6 的 XDC 与官方逐字节相同；WHS 两者同级（prj6=0.025 / prj8=0.035 ns）。
   → 排除"RX 接收被采坏"为主因（此前 ILA 的"字节只丢 1"解读存疑，疑为对 Windows 广播帧的误读）。
2. **整链仿真**（`sim/tb_full_chain.v`）：注入真实 ARP 请求 + 3 个 UDP 帧，让官方栈产生回复，
   过"栈TX→泵A→打包→Aurora模型→解包→泵B"，逐字节比对。
3. **观测**：首帧正常、**第二帧起恒少 1 字节**；分级计数泵A/解包/泵B 字节数逐级递减；
   逐拍追踪 pumpA 读 FSM：输出计数停在 `len-1`，`empty=1` 永久卡死、`rd_frame_cnt=1`（应为 2）。
4. **根因**：`rd_empty = (bin2gray(rd_bin_next) == wr_ptr_g_s2)` 用了 `rd_bin_next`（**提前一拍判空**）。
   当读指针追到与写指针持平时，`rd_bin_next` 已等于写指针 → 最后一字节被挡。

## 三、修复（`rtl/frame_fifo_pump.v`，C21）

```diff
- assign rd_empty = (bin2gray(rd_bin_next) == wr_ptr_g_s2);
+ assign rd_empty = (bin2gray(rd_bin)      == wr_ptr_g_s2);
```
依据：本泵"整帧先写满、握手后再读"，读期间写指针稳定；用当前 `rd_bin` 判空安全——
读指针真正追上写指针才为空，末字节允许读出。

## 四、验证（整链仿真 PASS）

```
frame0: MATCH len=72   frame1: MATCH len=72   frame2: MATCH len=72
frame3: MATCH len=83   frame4: MATCH len=254
stage bytes: pumpA=553  unpack=553  pumpB=553   ← 三级全程零丢失
*** PASS: detour preserves stack frames byte-for-byte ***
```
- 覆盖：ARP 请求/回复 + UDP 回显 16B / 29B（非 8 倍数）/ 200B；
- 源端口回显（改动 B）同步验证：`rec_pkt_done` 抓到 src_port=5000/5001/5002。

## 五、与板上现象的吻合

- **历代 ping 全不通**：回显帧尾被截 → FCS 错 → PC 丢弃。
- **"4 个 ping 收到 1 个"**：首帧（复位后空闲）幸存、后续帧被截 → 偶发通过，与此 bug 行为一致。
- **project_6 能通**：TX 直连、不经过帧泵，天然绕开此 bug。

## 六、复跑方式

```powershell
cd D:\FPGA\project_8
# 仿真（行为模型 async_fifo_model.v 仅供仿真；板上用真 IP）
xvlog rtl\arp\*.v rtl\icmp\*.v rtl\udp\*.v rtl\eth_ctrl.v rtl\frame_fifo_pump.v `
      rtl\axis_word_pack.v rtl\axis_word_unpack.v sim\async_fifo_model.v sim\tb_full_chain.v
xelab -timescale 1ns/1ps -debug typical tb_full_chain -s tb_fc
xsim tb_fc -runall
# 位流
vivado -mode batch -source scripts\build_debug.tcl -notrace
```

## 七、遗留 / 下一步

- 待上板跑硬判据：烧 `out/aurora_udp_bridge.bit`（本修复版）→ ping → `udp_verify.py` 应 12/12。
- 激励侧曾有两处**仿真自身**笔误（非设计问题，已改）：Aurora 模型误丢 beat；UDP 协议字节误写 0x17（应为 0x11）。
- 帧泵在"背靠背帧"（间隔 < 前排空时间）下会**丢整帧**（`wr_drop_cnt` 可见）——对人工节奏 ping/UDP 无影响，
  属已知取舍，后续压力场景再评估。

*仿真与修复：2026-09-17；位流重建见 build_fix.log。*

---

# 第二篇：上板日全记录——第三根因（RGMII RX 采样相位）定位与修复（2026-09-17 下午）

## 一、上午位流上板结果

烧 09-17 11:54 版（含泵修复）→ T23/T22 常亮，**ping 仍 100% 丢**。
PC 侧体检：以太网 1 Gbps 已连接、IP 192.168.1.102/24 正确、路由正确 → 环境无嫌疑。

## 二、板上 ILA 实证（同一 batch 会话内"武装→打流量→导 CSV"）

- **ILA1 触发 gmii_rx_dv**：帧确实进入 FPGA（72 拍 = 72 字节 ARP 请求）；
- **ILA0 未触发 rx_tvalid**：没有任何数据穿回 Aurora → 回复链死于 Aurora TX 之前；
- **帧内容**：前导码 55×7+d5 与广播目的 MAC ff×6 **完美**；源 MAC `08:3c:03:a0:26:96` 读成 `00:30:00:20:22:82`，
  EtherType `08:06` 读成 `00:00` —— **严格的位子集损伤（只丢 1、零加 1）**；
- `arp_rx_done` 始终为 0 → 栈从未解析成功。

**损伤机理**：采样沿压在数据位边界上——跳变中的上升位未越过阈值读 0（丢 1）、下降位已落阈值下读 0（碰巧正确）、
长期稳定 1 正常读出 → 恒定图案（ff/55）零损伤、跳变图案全伤。**与泵 bug 无关，是物理层采样问题**。

## 三、终极判别实验：官方 39 例程位流

烧原厂 `eth_udp_loop.bit`（2024-07-30 版）→ **ping 6/6 全通（<1ms）**。
⇒ 板子、PHY、网线、网卡、RGMII 物理层全部健康；**prj8 的实现层让 RX 读坏**。

（教训：中文路径 `KU060例程` 会让 Vivado Tcl 报 "File not found"，拷到 ASCII 路径再烧。）

## 四、双网表解剖（prj8 post_route.dcp vs 官方 routed.dcp）

逐一排除：IDELAYE3×5（工具映射 ISERDESE3/BITSLICE 时自动插入，**两边都有**，DELAY=0）、
BUFGCE 位置（**同为 BUFGCE_X1Y96**）、RTL（MD5 逐字节相同）、XDC 引脚（相同）、模块绑定（同为官方 gmii_to_rgmii）。

**真凶**：官方 RTL 的 `BUFIO BUFIO_inst` + `.CB(~rgmii_rxc_bufio)`——CB 上的 **LUT 反相器**使 2023.1
映射时**把 BUFIO 吸收掉**，IDDRE1 的 C 实际挂上了 **BUFGCE 全局时钟**（插入延迟 ~2ns，比 BUFIO 慢 ~1.7ns）：

- 采样时刻 τ = PHY 中心延迟(2ns) + FPGA 时钟插入(Δ)；
- 官方 2024 构建：Δ ≈ 1.7ns → τ ≈ 3.7ns，**压线挤进** 4ns 位窗（侥幸工作）；
- prj8：ILA 加入改变时钟树形态，Δ 再大 ~0.3ns → τ ≈ 4.0ns，**正好压在下一位跳变上** → 子集损伤。

官方例程当年在旧器件/旧流程下 BUFIO 正常保留；2023.1 + UltraScale 下这个反相器写法成了隐患。

## 五、修复（rtl/rgmii_rx_fix.v，接口与官方完全一致）

**双保险**，任一生效即恢复余量：
1. 去掉 CB 的 LUT 反相器，反相改由 `IS_CB_INVERTED(1'b1)` 参数承载 → **BUFIO 路径得以保留**（τ≈2.3ns，眼图中心）；
2. 5 根 RX 线各加 **FIXED IDELAYE3 500ps**（EN_VTC=0，无需 IDELAYCTRL）→ 即使工具仍走全局钟，
   数据窗右移后采样点仍落窗内。

工程手术：文件集移除官方 rgmii_rx.v（磁盘文件原样保留）与两个 _dly 残留，加入 rgmii_rx_fix.v（同名模块顶替）。

## 六、为什么 ds 当年的 IDELAY 扫描"无效"——证据失效声明

扫描时叠加了两个污染因素：
1. **泵 bug 未修**：即使 RX 修好，回显帧尾字节仍被截 → FCS 坏 → ping 依旧不通 → 所有 RX-delay 值"看起来都无效"；
2. 曾强制 100M 全双工测过（官方 RGMII 只支持 1000M，100M 下一帧不进）。
今日泵已修、链路 1G、官方位流判别已排除硬件 → **采样相位修复首次获得干净的验证条件**。

## 七、构建实录与验证状态

**Plan A（纯 BUFIO 恢复，IS_CB_INVERTED 去反相器）**：构建成功，但网表解剖 
BUFIO_COUNT=0——**2023.1 在 UltraScale 上无论如何都把 BUFIO 吸收掉**，结构性失败（build_rxfix2.log）。

**Plan B（FIXED IDELAY 500ps + IDELAYCTRL，rgmii_rx_fix2.v）**：
- 踩了两个 DRC 坑后成功出流：REQP-1816（RST 不得接地）→ REQP-1817（RST 不得直连 LOCKED）→
  最终用 clk200 打拍同步链产生 RST；
- **WNS = +1.179 ns，0 Error，bit = 17:54:08 版**（build_rxfix5.log）；
- 200MHz 参考由 eth_rxc(125M) 本地 MMCM ×8/5 产生，模块接口不变，gmii_to_rgmii/顶层零改动。

**验证中断**：烧录时 JTAG 消失、以太网链路 Disconnected → **板子中途掉电/断线**（非设计问题）。复电重插网线后继续。

## 八、最终结果（2026-09-18，判据全过 ✅）

**延迟扫描**：
- `RX_DLY_PS=500`：RX 字节恢复（ILA 抓到整帧完美的 ARP 请求；`arp_rx_done`/`stack_tx_en`/`rx_tvalid` 三事件全触发），
  但 ping 仅 ~50% 通 + 出现 MISCOMPARE —— 采样仍在眼图边缘（打到头部→超时；打到载荷→回显坏字节但 CRC 重算后"合法"到达）。
- `RX_DLY_PS=1250`：**眼图居中**。WNS=+1.179ns（build_dly1250.log）。

**判据结果（1250ps 版位流）**：

| 判据 | 结果 |
|---|---|
| ping ×10 | **10/10，0% 丢包，全部 <1ms** |
| udp_verify 12 长度（覆盖全部 帧长%8 余数类） | **12/12 逐字节一致** |
| udp_verify 压力（12 长度 × 3 包） | **36/36 一致** |
| ping ×20 稳定性 | **20/20，0% 丢包** |

**PASS：数据已确认穿越 Aurora 64b/66b 编解码往返 —— M2（数据级桥）判据达成。**

三个根因回顾：① unpack 帧中断流（09-10 修）→ ② 帧泵 rd_empty off-by-one（09-17 上午修）→
③ RGMII RX 采样相位（09-17 下午定位、09-18 以 IDELAY 1250ps 收敛）。三层叠加、逐一剥离，判据全绿。

复测入口：`powershell -File D:\FPGA\project_8\scripts\board_test_rxfix.ps1`
