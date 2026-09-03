# project_6 进度快照（2026-09-02 深夜 · 暂停待官方源码）

> 状态：**暂停**——等用户提供官方完整例程源码后继续。所有调查与骨架已就绪。

## 已完成

| 项 | 位置 | 说明 |
|---|---|---|
| 第 59 章光口版调查定版 | vault `操作文档/阶段二之五_以太网UDP光口环回实操单.md` | 双 IP 定版/坑位 C1-C6/不确定点 U1-U8（决策 #8：网口版先行） |
| 第 43/44/45 章全文提取 | `.claudian/ch43_arp_extract.txt` · `ch44_icmp_extract.txt` · `ch45_udp_extract.txt` | 完整清单+片段+TB 全在 |
| **官方例程镜像 15 文件** | `.claudian/alientek_ref/*.v` | ⭐ 带正点原子官方版权头（2025-10，超越者板卡例程系列）；**含书内缺失的全部 7 个**（arp_rx/arp_tx/icmp_rx/icmp_tx/udp_rx/udp_tx/crc32_d8）；来源 URL 未记录（代理中断），明天与用户官方源码互为印证 |
| RTL 转录 8/15 | `rtl/`：rgmii_rx · rgmii_tx · gmii_to_rgmii(组装) · arp · icmp · udp · eth_ctrl · eth_udp_loop | 书内完整清单，与镜像版待 diff |
| RTL 重实现 2/15 | `rtl/crc32_d8.v`(标准反射 CRC) · `rtl/udp_rx.v`(按书规格) | **待官方版整体替换** |
| XDC | `xdc/eth_udp_ge1.xdc` | 表 43.5.1 GE1 全引脚 + create_clock 8ns |
| 构建脚本 | `scripts/create_project.tcl` · `build.tcl` | 幂等；FIFO IP async_fifo_2048x8b(2048×8 独立时钟标准模式)；top=eth_udp_loop；part xcku060-ffva1156-2-i |

## 明日流程（源码到位后）

1. **用户提供官方源码**（期望：gmii_to_rgmii/rgmii_rx/rgmii_tx、arp_rx/arp_tx、icmp_rx/icmp_tx、udp_rx/udp_tx、crc32_d8、eth_ctrl、eth_udp_loop 等 .v 全集，或完整例程工程目录）
2. **diff 官方源码 vs `.claudian/alientek_ref/` 镜像**（互证；镜像头注释显示同为超越者系列）→ 以官方为准**整体替换** `rtl/` 中重实现的 crc32_d8/udp_rx，补齐 arp_rx/arp_tx/icmp_rx/icmp_tx/udp_tx
   - ⚠️ **红线：不得混用 CRC 约定**——crc32_d8 的寄存器约定与 tx 模块 st_crc 发射序强耦合，必须整包使用同一来源
3. 与书内完整清单（arp.v/icmp.v/udp.v/eth_ctrl.v/eth_udp_loop.v）核对端口一致性，如有差异以官方源码整套为准
4. `vivado -mode batch -source scripts/create_project.tcl` → 语法/elaboration 排错
5. （可选但推荐）xsim 仿真：官方 tb_arp/tb_udp + 自写 CRC 全帧比对（Python zlib.crc32）
6. `vivado -mode batch -source scripts/build.tcl` 出位流 → 上板三级验证（实操单 §7）

## 待用户确认项（不阻塞构建）

- U7：表 43.5.1 球号 vs "官方表 26 脚实测" 原理图终核
- U8：YT8531 strap（RXDLY/TXDLY 上拉）核对
- PC 网卡静态 IP 192.168.1.102/24、GE1 口网线（CAT-6）
