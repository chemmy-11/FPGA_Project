# project_7 进度快照（UDP + SFP 内环混合验证）

> ⏸️ **挂起（2026-09-04，架构定版决策 #10）**：C17 已修复、位流在库（含双 ILA+配置扫描器）。多端点架构下本工程定位调整为**光口承载标准以太网的前端验证件**——服务器/板间走以太网光口时直接复用。恢复入口：T22/计数器判读（二之六实操单 §4）。

> 立项：2026-09-03，用户选定"先做 UDP+SFP 内环"（路线图决策 #9）。

## 架构

```
PC --RJ45(GE1,RGMII)--> [官方 39_eth_udp_loop 栈，原样] --udp echo--> RGMII --> PC
                              |
              TAP: gmii_rxd/rx_dv (PC 原始帧, eth_rxc 域 125M#1)
                              v
                    frame_fifo_pump (自研: 双钟 FIFO + 帧握手, eth_rxc->userclk2)
                              v
                    gig_ethernet_pcs_pma_0 TX (官方 53 xci: 1000BASE-X/1G/GMII/X1Y8=SFPD)
                              |  INTERNAL LOOPBACK (configuration_vector[0]=1,
                              |    唯一配置改动 vs 官方)
                              v
                    PCS RX -> GMII (userclk2 域 125M#2) -> udp_rx 第二例(官方,仅解析)
                              -> rec_pkt_done -> T22 粘滞灯 + mark_debug ILA
```

- **自终止性**：内环回帧 = UDP 回显（目的 MAC = PC ≠ 板卡）→ udp_rx 第二跳自动过滤；udp_rx2 不回显 → 无无限回声。
- **跨钟域**：栈(eth_rxc, PHY 晶振) 与 PCS(userclk2, GT 参考钟) 为独立 125M 源——帧泵帧门控搬运，防采样违例。
- **策略限制**：握手门控写，帧在途时新帧丢弃计数（wr_drop_cnt）——人工节奏流量无影响，压测留后续。

## 文件

| 文件 | 来源 |
|---|---|
| rtl/ 官方 15 文件 | 39_eth_udp_loop（与 project_6 同源，GBK 原样） |
| rtl/sfp_udp_inner_loop.v | 自研顶层（官方 39 接线 + SFP 加性路径） |
| rtl/frame_fifo_pump.v | 自研帧泵（双钟 FIFO + 4 相握手） |
| ip/gig_ethernet_pcs_pma_0.xci | 官方 53（1000BASE-X/1G/GMII/X1Y8） |
| ip/clk_wiz_0.xci | 官方 53（100M→50M+100M，DRP 钟） |
| ip/async_fifo_2048x8b.xci | 官方 39（栈回显缓冲） |
| xdc/eth_udp_inner_loop.xdc | 官方 39 + 53 合并 + LED T22/T23 |

## 偏差记录（相对官方源码）

1. configuration_vector[0]=1（内环）——官方 2'h0（禁止）；唯一配置性偏差。
2. 官方 39 顶层内 u_clk_wiz_0（125M→200M，IO 延时预留、无功能）移除——与导入的 53 版 clk_wiz_0 同名冲突。
3. 新增 sfp_udp_inner_loop.v（顶层）+ frame_fifo_pump.v（帧泵）——纯加性，官方文件字节未动。

## 观测点

| 观测 | 位置 | PASS 判据 |
|---|---|---|
| led_loop (T22) | 内环回帧被 udp_rx2 完整解析（粘滞） | 点亮 |
| led_link (T23) | status_vector[0]（位语义待实证） | 点亮（参考） |
| mark_debug ILA | rx2 rec_data/rec_byte_num、status_vector、泵计数 | 回环帧字节与 PC 发送一致 |

## 构建记录

- 第 1 次（-jobs 8）：3 个 IP OOC 并行**内存耗尽**失败 → 降 -jobs 2。
- 第 2 次：上次的 FAILED IP run 未被 `reset_run synth_1` 覆盖 → launch 被拒 → 脚本补三条 IP run 显式 reset。
- 第 3 次：中断修复 top 双重驱动 bug（mark_debug 线用层次引用初始化 + 端口连接双驱动；泵计数线声明滞后于实例导致隐式 1-bit 线宽度冲突）→ 已修（dbg_pump_* 改为纯端口驱动、声明前置）。
- 第 4 次：帧泵 MDRV-1 多驱动（rd_bin 被指针块与读端口块双重驱动，wr_bin 无条件推进与写使能脱节）→ 指针改为仅在真实读写时推进；xvlog 预检再修 3 处（wr_full/rd_en_i 声明顺序、st 遗漏）。
- 第 5 次：XDC 行内 `#` 注释导致 3 条 create_clock 解析失败（CRITICAL）→ 注释移到独立行。
- ✅ 第 6 次构建成功（2026-09-03 19:21）：`sfp_udp_inner_loop.bit`（4.5MB），时序全绿三钟齐，GT=X1Y8（CPLL 档），**但含 C17 隐患**（见下）。
- **上板（09-04）：UDP 回显 ✅ 但 T22 不亮** → ILA 缺失（全新工程未插调试核）→ GUI Set Up Debug 发现 `dbg_pump_rd` 驱动=GND（读侧计数被常量折叠）、`dbg_pump_wr/drop` 域=eth_rxc、`dbg_mmcm`=VCC → synth 日志实锤 **C17：ram_dout/ram_dout_v 被两个不同复位风格的 always 块同时驱动**（无复位数据捕获块 + FSM 异步复位分支）→ 综合生成重复寄存器、保留 GND 常量端 → 泵读数据恒 0 → PCS 发全零流 → 回环帧前导码错 → udp_rx2 解析失败 → LED0 永不亮。
- ✅ **C17 修复**：FSM 复位分支删除 ram_dout/ram_dout_v 赋值（数据管道寄存器免复位，捕获块唯一驱动）；全文件扫描另发现 hs_busy 双块（记 **C18 竞态边缘**）→ 已根治：释放逻辑并入单一握手块（if/else 互斥分支，C18 随之消除）。
- **C19 调试核脚本化插入排障（09-04）**：① \create_debug_port\ 2023.1 签名变化且 -type 仅支持 trig_in/out → **改用单宽探针方案**：每 ILA 一个 probe0 捆绑多信号（ILA0@userclk2 宽 58 = rx2_data/num/en/done + status_r + pump_rd；ILA1@eth_rxc 宽 32 = pump_wr/drop）；② \implement_debug_core\ 要求先保存设计 → 检查点保存/重开；③ **dbg_hub 子进程在中文工作目录（vault）下综合必挂**（AGENTS.md 红线 #6 同源）→ 换 ASCII 工作目录启动即过；④ dbg_status 原始位部分常量导致时钟域 partially defined → RTL 改为寄存器快照 dbg_status_r（全 16 位变真实 FDCE）。
- ✅ **第 8 次构建成功（09-04 17:17）**：\out\\sfp_udp_inner_loop.bit\（**含双 ILA 调试核 + C19 配置扫描器**）+ \scripts\\probes.ltx\。新增：KEY 按键循环 3 组 configuration_vector（cfg0=官方[4:3]=10 / cfg1=00 / cfg2=01，切换自动 0.5s PCS 复位），T23=cfg_idx[0]（亮=cfg1，灭=cfg0/2）——**上板免重建试配置**。
- 迭代预案：三档配置扫完 T22 仍不亮 → 读 ILA dbg_status_r/pump 计数定位（二之六 §4）。
