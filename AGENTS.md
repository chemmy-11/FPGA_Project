# AGENTS.md — FPGA_Project 工程指令与规范（开发层，工作区 D:\FPGA）

> 本文件是开发 Agent 的**常驻指令 + 工程规范汇总**（2026-09-18 重构为规范手册）。
> 你对工程状态的实测结论即事实源。**多会话协同由用户自行编排**（按需加载知识库管理技能），旧三层协作契约（Reasonian/Reasonix/中控）已于 2026-09-20 废弃，`毕设\Agent 协作\` 仅作历史归档。
> 工程进度总览看 `README.md`；本文件管**怎么干活**。
> 会话若从 vault（`C:\Users\15266\Desktop\毕设\`）启动，先读其根目录 `agent.md`（会话入口，本文件的镜像+双目录协议）；规范冲突时以本文件为准。

## 一、角色与红线

### 协同方式

用户通过不同会话按需协同，无固定分工。本文件对任何在本仓库工作的 Agent 生效；文档目录（`C:\Users\15266\Desktop\毕设\`）入口为其根 `agent.md`。

### 硬红线
1. **每步标注「为什么」**——用户答辩要讲得出原理，不允许只给结论。
2. **物理层归用户**：上板、光纤插拔、看示波器——你写操作清单并给出判读表，不代劳。
3. **改动可追溯**：一切改动走 git，提交信息写清意图与证据；位流/日志不入库（.gitignore）。
4. **工程路径全英文**：Vivado 对中文路径乱码（GBK 实证）。vault 文档中文没问题，Vivado Tcl 引用的路径必须 ASCII。
5. **用户是 FPGA 新手**：首次 GUI 环节（综合/看波形）提示用户亲自走一遍建立直觉。
6. ** vault 与工程目录双向开放**：改 vault 文档可以，但 vault 为权威版本、工程内只放脱敏快照。

## 二、事实源与第一性原则（本工程最高规范）

板级参数与设计的可信度排序，**只允许从高向低采信**：

```
官方例程/官方 XDC（正点原子 KU060例程 39/50/53/55 号等）
  > 已上板验证过的 prj（prj6 网口栈 / prj8 数据级桥 M2 判据全过版）
    > 板卡手册/引脚表（KU_IO.xdc，GBK 编码）
      > AI 生成的开发文档（仅参考，不可作为实现依据）
```

推论：
- 任何引脚/时序/IP 参数**先查官方例程 XDC 与已验证 prj 的 XDC**，找不到再问用户，最后才看 AI 文档。
- **官方 RTL 文件保持原样**（磁盘上的官方栈/Aurora 例程文件永不改）。修复手法二选一：
  ① **同名模块顶替**：新写 `xxx_fix.v`（module 名与官方一致），把官方文件从 fileset 移除、fix 加入（官方文件留在盘上）——prj8 `rgmii_rx_fix2.v` 即此法；
  ② **派生新文件**：复制官方文件→改模块名→只在派生版上动刀（`aurora_64b66b_0_support_ext.v` 即此法）。
- 判别实验优先：**怀疑实现层时先烧官方位流对照**（prj8 用官方 39 位流 ping 6/6 一举排除硬件，定位到实现层）。

## 三、硬件事实卡（实测定论，勿凭记忆改写）

| 项 | 事实 | 证据来源 |
|---|---|---|
| 器件 | `xcku060-ffva1156-2-i`（非 CIV）| 丝印+实现通过 |
| 系统时钟 | 100MHz 差分 AK17/AK16 | KU_IO.xdc |
| 复位 | AC34 低有效 LVCMOS18 | KU_IO.xdc |
| 网口 | GE1 RGMII（YT8531），栈时钟 eth_rxc 125M | 官方 39 XDC |
| ⚠️ RGMII RX | 2023.1 吸收官方 BUFIO→IDDRE1 挂全局钟，须 `rgmii_rx_fix2.v`（IDELAY **1250ps**+IDELAYCTRL） | prj8 网表解剖+延迟扫描 |
| Aurora 参考钟 | MGTREFCLK1_226（T6/T5）156.25MHz | IBERT 实测 |
| 光口映射 | **A=Y11=X1Y11 · B=Y9=X1Y9 · C=Y10=X1Y10 · D=Y8=X1Y8**（Quad X1Y2） | 官方 55 号 XDC 注释 + GT LOC 双证 |
| 光口控制脚 | A: tx_dis=AF12 rs0=AF13 rs1=AE13；B: AH12/AH11/AG11；C: J25/M26/M25；D: H26/G27/H27 | 官方 55 号 XDC |
| 光模块 | 须 10G SFP+（线速率 10G，RS0=RS1=1 高速档，tx_disable=0） | Aurora xci C_LINE_RATE=10 |
| LED | T22=观测（粘滞 rx）· T23=channel_up/link_ok（链路硬门控指示） | 各工程 XDC |
| JTAG | 调试烧录用 Digilent USB-JTAG（210512180081）；串口 FT2232H-B COM7 | hw_server 实测 |
| PC 侧 | NIC 192.168.1.102/24 静态 ↔ 板 192.168.1.10（MAC 00:11:22:33:44:55） | prj6 起 |
| Python | `C:\Users\15266\AppData\Local\Python\pythoncore-3.14-64\python.exe`，**须 `PYTHONUTF8=1`**（GBK 控制台打 ✓ 会崩） | udp_verify 实证 |

## 四、工程结构与脚本规范

```
D:\FPGA\project_N\
├── rtl/            # 设计 RTL（官方栈按子目录分 arp/ icmp/ udp/ gmii_to_rgmii/）
├── shared_logic/   # Aurora 例程共享逻辑（派生文件也放这，命名 *_ext/_shared）
├── ip/             # 只存 .xci（import_ip + generate_target 重新生成，产物不入 git）
├── xdc/            # 引脚+时钟组约束（引脚注释必须写来源）
├── scripts/        # Tcl 四件套 + py（见下）
├── out/            # 位流（gitignore）
└── docs/           # 工程级文档（设计说明/PROGRESS）
```

**脚本四件套（幂等，逐个可重跑）**：
1. `create_project.tcl`——建工程：`add_files` glob → `import_ip`（勿用 read_ip，prj7 实测路径漂移）→ `generate_target all`。
2. `build_debug.tcl`——综合+ILA 插入+实现+出流：输出 `TIMING:`（WNS）与 `DBG_BUILD_DONE:` 标记行供日志抓取。
3. `program_board.tcl`——hw_server 烧录（成功标记 `PROGRAM_OK`）。
4. `board_test_*.ps1`——一键「烧录→ping→udp_verify」判据跑。

**规范**：日志落文件再 Select-String（勿管道直取——回显行会污染）；`create_project -force` 前先杀残留 vivado 进程（锁 runs 目录是实坑）；python 一律 `PYTHONUTF8=1`。

## 五、RTL/设计规范

1. **CDC 只有三种合法形式**：帧泵式格雷指针异步 FIFO、2FF 同步器（打拍≥2）、4 相握手邮箱。新跨域路径必须三选一。
2. **mark_debug 探针标注时钟域**，ILAs 挂同名域——跨域采样探针曾是 WNS=-2.6ns 的元凶（prj8 首轮实证）。
   B 通道（user_clk_b 域）探针绝不能挂 A 域（user_clk）ILA。
3. **互不相关时钟必须声明时钟组**：`set_clock_groups -asynchronous`（eth_rxc / gt_refclk 派生 / init_clk 三组），否则跨域路径被假同步分析重罚。
4. **XDC 只用受限 Tcl**：不能 `if/foreach/puts`（实测整段丢弃，CRITICAL WARNING [Designutils 20-1307]）。参数化约束改在 Tcl 脚本里生成。
5. **判据无旁路原则**：数据通路必须被链路状态硬门控（`aurora_rst=~sys_rst_n|~channel_up`）——链路没起来板子对外静默，判据通过 ⇔ 数据真的穿过了链路。
6. **一个 quad 只允许一个 GT_COMMON**：多 Aurora 同 quad 时，第一个实例的 support 引出 refclk+QPLL 四件套（`_ext`），兄弟实例用无 common 的 `_shared` 版；各实例私有 MMCM 时钟模块与复位逻辑。
7. **Aurora 核端口方向**：`gt_pll_lock` 是核的**状态输出口**（外部 assign 驱动它 = MDRV-1）；外部锁定状态只走 `gt_qplllock_quad1_in`。
8. IP 参数不确定时**只设置有把握的**——set_property 遇到不存在的参数名是致命错（fifo_generator 实坑）。

## 六、调试方法论（按代价升序）

1. **判别实验**：换已知好的位流（官方例程）对照，先分「硬件 vs 实现」。
2. **ILA 单会话三段式**：同一 Vivado batch 会话内 arm → 起流量（ping）→ upload → CSV。arming 易失，**不能跨会话**。触发探针名要与 probes.ltx 一致；`TRIGGER_POSITION` 属性不被接受（省略或 catch）。
3. **网表解剖**：`open_checkpoint` 两份 dcp 对比元件/位置/绑定（prj8 定位 BUFIO 被吸收即此法）。
4. **延迟扫描**：时序边缘问题时改一个参数出一流（IDELAY 500→1250ps 即收敛过程），每次记录 ping 通过率。
5. 每轮调试落**调试记录**（现象→假设→实验→证据→结论五要素），入 vault `操作文档/调试记录_*.md`。

## 七、验证判据规范

**三层证明力**（每层通过才算闭环）：
| 层 | 命令 | 通过标准 | 证明 |
|---|---|---|---|
| 链路 | 看 T23 | 常亮 | channel_up（硬门控前提）|
| 通路 | `ping 192.168.1.10 -n 20` | 0% 丢包 全 <1ms | ARP+ICMP 穿 Aurora 往返 |
| 数据 | `$env:PYTHONUTF8=1; python scripts\udp_verify.py [次数]` | **回显一致 12/12** | payload 逐字节原样返回 |
| 佐证 | Wireshark 抓 `udp.port==1234` | 请求/回显成对且 payload 相同 | 帧级眼见为实 |

`udp_verify.py` 的 12 个长度（26~33/40/63/100/200）是刻意选的——**覆盖帧长%8 全部余数类**，专压打包/解包尾部处理。跑前关闭占用 1234 端口的程序。

## 八、git 与文档规范

- **每个里程碑一提交**，信息含：改了什么/为什么/WNS/判据结果。多行信息写临时文件 `git commit -F`，提交后删。
- 提交语义前缀：`project_N:`（工程主线）/ `project_N fix:`（修根因）/ `docs:`（文档）。
- vault 文档快照入 `docs/操作文档/` 须脱敏（用户名→`***`，人名→`前辈`）；命名 `[阶段]_prj标识_概要_YYYY-MM-DD`。vault（Obsidian 知识库）已于 09-19 同步采用本规范，类别扩展：汇报/规划/追踪/结论；重命名文件 frontmatter 加 `alias: 旧名` 保旧链接可达；新旧名映射见 `docs/README.md`。豁免：`README.md`、`agent.md`（vault 会话入口镜像，冲突以本文件为准并回改镜像）、非 Markdown 数据文件。
- 工程状态变化 → 更新本文件「当前工程状态」+ README「当前推进」，并向用户报告一句。

## 九、坑账本（踩过的坑 = 规范的来源）

| # | 坑 | 根因与修法 |
|---|---|---|
| 1 | 中文路径 Tcl 报 File not found | GBK 码位问题；官方位流拷到 ASCII 路径再操作 |
| 2 | XDC 里写 if/foreach 被整段丢弃 | XDC 是受限 Tcl；逻辑放 build 脚本 |
| 3 | 帧尾总丢 1 字节（FCS 坏） | 帧泵 `rd_empty` 误用 `rd_bin_next` 提前判空——用当前 `rd_bin`（prj8 commit ae40965）|
| 4 | 回显帧中段断裂 | unpack 对帧中断流敏感——改整帧存储转发（09-10）|
| 5 | RX 字节「只 1→0」子集损伤 | 2023.1 吸收 BUFIO，IDDRE1 挂 BUFGCE 全局钟压位边界——FIXED IDELAY 1250ps×5 + IDELAYCTRL（065ee78/66ff43d）|
| 6 | PLIDC-10 / REQP-1816 / 1817 | IDELAY 必须配 IDELAYCTRL，其 RST 不得接地也不得直连 LOCKED——用 clk200 打拍同步链 |
| 7 | WNS=-2.6ns 假路径罚分 | 探针跨域采样 + 缺时钟组声明——mark_debug 标域 + set_clock_groups |
| 8 | MDRV-1 QPLL1LOCK 多驱动 | Aurora 核 `gt_pll_lock` 是输出口，外部不可驱动（42f0ba2 踩坑实录）|
| 9 | create_project -force 失败 | 残留 vivado 进程锁 runs 目录——先 Stop-Process vivado |
| 10 | fifo_generator set_property 致命错 | 参数名臆造（Write_Depth_Flag 等）不存在——只设有把握的参数 |
| 11 | hw_ila 属性拒绝 | TRIGGER_POSITION 不被接受——省略或 catch 包裹 |
| 12 | python 打印 ✓ 崩溃 | GBK 控制台——`PYTHONUTF8=1` |
| 13 | IBERT 与 Aurora 抢 GT | 同一 GT 通道不能二者并存——换装位流或用同 quad 空闲通道 |
| 14 | 位流断电即失 | JTAG 烧录易失——每次上电重烧（board_test 一键脚本兜底）|

## 十、当前工程状态（一屏速览，详表见 README.md）

- ✅ prj6 网口栈（09-04）· ✅ prj8 数据级桥 M2 判据全过（09-18，git 66ff43d）
- 🔄 **prj9 双笼真光链路**（git 42f0ba2，WNS=+1.008ns，位流就绪）：双 10G 模块插 **A(Y11)/B(Y9)** + LC 跳线直连 → T23（link_ok=双 channel_up）常亮 → 判据同 M2。T23 不亮先对调一端两纤。
- ⏭️ 连通后：IBERT 眼图（空闲通道 C/D）→ 双板干线 → DDR/DMA 解冻
- ⏸️ 挂起区：project_4 MIG · 串口桥三级验证 · project_7 内环 · 8b/10b 练手（恢复触发条件见 README）

## 十一、跨目录约定

- 本文件 = 工程规范权威版；`毕设\agent.md` = 会话入口镜像（冲突以本文件为准并回改镜像）。
- 文档目录（毕设\）的任务清单/路线图随里程碑同步更新。
- 历史协作契约（三层分工、同步中枢）已废弃（2026-09-20），资料存 `毕设\Agent 协作\` 仅供追溯。

