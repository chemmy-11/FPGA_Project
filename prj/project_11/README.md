# project_11 — 路线 B：软核 + C 控制 + AXI DMA（MicroBlaze 控制面正式版）

> **fork 自 `prj/project_10/prj_loop`（2026-10-10）**。prj10 已**整目录冻结为路线 A 资产（只读）**；
> 本工程是路线 B 的唯一演进地。执行单：毕设 `操作文档/阶段三_prj11_路线B软核与DMA开工草案_2026-10-10.md`（实施单 v1.0）。

## 目录

| 路径 | 内容 |
|---|---|
| `rtl/` | fork 基底同 B0（45 文件，`fork_manifest.json`）+ **B1 新增/改动**：`axi_lite_regs.v`（W5 四命令语义的 AXI4-Lite 从机）、`cmd_channel.v` 增量端口 `cfg_wr_pulse`（契约纯增量）、顶层 owner 仲裁 + `mb_ctrl` BD 例化 + UART 端口 |
| `xdc/` | prj10 基底 + UART 引脚（AE33/AF34 LVCMOS18，project_1 M1 同款） |
| `scripts/` | `create_project.tcl`（幂等建工程，**末尾自动 source BD 生成**）/ `create_bd_b.tcl`（mb_ctrl BD：MicroBlaze+MDM+UARTLite+SmartConnect+axi_lite_regs 模块引用）/ `build_debug.tcl`（四域 ILA + B1 lite 探针 + XSA 导出）/ `probe_dbgcfg.tcl`、`export_p1_bd.tcl`（BD 配方导出工具） |
| `sim/` | 回归 TB + 一键 bats：W2 六用例 / W4 联合（含负向）/ W5 命令通道（含负向）/ 泵压力（orig vs L1）/ 仲裁器 / **B1 `run_lite_tb.bat`（axi_lite_regs 正负对照）** |
| `sw/` | MicroBlaze 软件：`src/main.c`（hello + 寄存器自测 + 心跳，判决行 `[B1-SELFTEST] PASS`）+ `build_sw.tcl`（xsct 一键平台+应用） |
| `vivado/` | Vivado 工程（**不入库**，由 create_project.tcl 再生） |

## fork 完整性判据（B0⑥，2026-10-10 全过）

1. **文件级**：45 文件 SHA256 与源逐一致（`fork_manifest.json`，fork 时点快照；之后本工程的本地适配——3 个 bat 的路径改指本工程 rtl、pump_stress.bat 注释转 ASCII——不回写 manifest，以 git 历史为准）；
2. **仿真回归（用本工程 rtl 编译）**：W2 六用例 PASS 且 STAT 与 prj10 基线逐字一致（586/585、931/921 cycles、帧周期 12.30 µs）· W4 联合 PASS（A/B 各 wm=wr=rd=148 全 0 错误）· W5 命令通道 PASS · 泵压力 L1 PASS（200 帧 0 丢逐字节一致）· 仲裁器 8:8 PASS；**负向对照全部按预期失败**（W4 缺陷路由死锁检出、命令通道负向 68 错）——判据非恒真；
3. **首次构建**：create + build_debug 全绿（结论见毕设 `调试记录/阶段三_prj11_B0断点核查与fork脚手架_2026-10-10.md`）。

## B1 增量（2026-10-10，软核控制面，详见毕设 `调试记录/阶段三_prj11_B1软核控制面集成_2026-10-10.md`）

- **axi_lite_regs**：W5 寄存器语义（MODE/RD_SLOT/水位/槽映射/STATUS/ID）经 AXI4-Lite 暴露，三组四相邮箱跨 100M↔151.5M，单元 TB 七项 + 负向对照（脉宽缺陷 FAIL）双绿；
- **mb_ctrl BD**：MicroBlaze(64KB LMB+Debug) + MDM + proc_sys_reset + UARTLite(9600) + SmartConnect，**axi_lite_regs 以 RTL 模块引用入 BD**（地址 0x44A00000；UART 0x40600000 与 M1 同款）；配方基底 = project_1 `write_bd_tcl` 导出（已验证 BD 导出重建脚本，比猜自动化参数可靠）；
- **owner 仲裁 = 最近写者胜**：UDP 命令通道与软核并存，任一侧写选通翻转 ctl_owner，复位后默认 UDP；读触发两路 OR；
- **六套仿真回归全绿**（W2/W4/W5/泵/仲裁器/lite，负向 ×3 按预期 FAIL）；
- 上板判据 J_B1 三项（A 基线复现 / 串口 hello / ILA 回读一致）待用户场次。

## 用法

```powershell
# 建工程（幂等；ASCII 路径）
D:\Xilinx\Vivado\2023.1\bin\vivado.bat -mode batch -source D:\FPGA\prj\project_11\scripts\create_project.tcl -notrace
# 构建（synth + 四域 ILA + 实现 + 位流，WNS 门限不过不写位流）
D:\Xilinx\Vivado\2023.1\bin\vivado.bat -mode batch -source D:\FPGA\prj\project_11\scripts\build_debug.tcl -notrace
# 仿真回归（cd sim\ 后）
run_sim.bat & run_w4_joint.bat & run_cmd_tb.bat & pump_stress.bat l1
```

## 纪律

- prj10 只读——任何"想改 prj10"的冲动都改成"改 prj11 的副本"；
- B 的新增件（BD 子系统 / axi_lite_regs / 仲裁器 3 主扩展）只在本工程叠加，每步配 TB 正负对照；
- 回退 = 烧 prj10 终版位流（SHA256 `DBE35734…017F`），判据脚本零改动。
