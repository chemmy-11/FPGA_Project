# project_6 进度快照（2026-09-03 · 官方源码整包移植，构建中）

> 状态：**官方源码到位并整包移植**，Vivado 后台构建中（synth→impl→bitstream）。

## 2026-09-03 更新

- **官方例程源码库到位**：`D:\BaiduNetdiskDownload\1_Verilog\KU060`（正点原子超越者 KU060 全部 56 章，GBK 编码，自带 Vivado 2023.1 工程）。
- **`.claudian/alientek_ref/` 镜像集停用**：与官方 KU060 版同名但字节不同（镜像来自其它板卡版本），以官方为准；保留作参考。
- **project_6 重建为官方整包**：
  - `rtl/` 15 文件（GBK 原样）：eth_ctrl / eth_udp_loop / arp{arp,arp_rx,arp_tx,crc32_d8} / gmii_to_rgmii{...} / icmp{...} / udp{udp,udp_rx,udp_tx}——**我此前的重实现（crc32_d8/udp_rx）与书内转录全部移除，零混源**
  - `eth_udp_loop.xdc`（官方：表 43.5.1 全引脚 + key=Y30 + BITSTREAM.CONFIG.UNUSEDPIN PULLNONE）
  - `ip/`：async_fifo_2048x8b.xci + clk_wiz_0.xci（125M→200M，IO 延时预留时钟）——经 `import_ip` 导入（read_ip 会导致生成物路径漂移到 D:\ 根，已改用 import_ip 修复）
  - `sim/tb/tb_udp.v`（官方 TB，已挂 sim_1 fileset 备用）
- **与书（第 45 章）的差异**：官方顶层多 `key` 端口（按键触发 ARP 请求，逻辑并入 eth_ctrl）+ clk_wiz_0；书内顶层无此二者。以官方为准。
- **工程**：`prj/project_6.xpr`，top=eth_udp_loop，脚本 = `scripts/create_project.tcl`（幂等）+ `scripts/build.tcl`。

## 2026-09-02 的调查成果（仍有效）

| 项 | 位置 | 说明 |
|---|---|---|
| 第 59 章光口版调查定版 | vault `操作文档/阶段二之五_以太网UDP光口环回实操单.md` | 双 IP 定版/坑位 C1-C6/不确定点 U1-U8（决策 #8：网口版先行） |
| 第 43/44/45 章全文提取 | `.claudian/ch43_arp_extract.txt` · `ch44_icmp_extract.txt` · `ch45_udp_extract.txt` | 完整清单+片段+TB 全在 |
| 光口版素材 | 官方 `53_sfp_eth_udp_loop` | 光电转到位后启用（对应实操单 §2-§4 定版） |

## 构建后流程

1. 检查 build_console.log / STATUS，位流落位 `prj/project_6.runs/impl_1/*.bit`
2. 时序复核（timing summary 全绿）+ 三件套
3. 用户上板三级验证（实操单 §7）：L0 PHY 自协商（"正在识别→未识别的网络"）→ L1 ping 192.168.1.10（加分）→ L2 网口调试助手 UDP 回环（.10↔.102:1234）→ L3 Wireshark 四包链
4. 判据回填实操单 + 截图归档 `docs/`

## 待用户确认项（不阻塞）

- U7：官方 XDC 球号 vs 板卡原理图终核（官方 XDC 与表 43.5.1 完全一致，风险已降级）
- U8：YT8531 strap（RXDLY/TXDLY 上拉）核对
- PC 网卡静态 IP 192.168.1.102/24、GE1 口网线（CAT-6）
