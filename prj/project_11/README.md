# project_11 — 路线 B：软核 + C 控制 + AXI DMA（MicroBlaze 控制面正式版）

> **fork 自 `prj/project_10/prj_loop`（2026-10-10）**。prj10 已**整目录冻结为路线 A 资产（只读）**；
> 本工程是路线 B 的唯一演进地。执行单：毕设 `操作文档/阶段三_prj11_路线B软核与DMA开工草案_2026-10-10.md`（实施单 v1.0）。

## 目录

| 路径 | 内容 |
|---|---|
| `rtl/` | **物理持有全部源件**（45 文件，与 prj10 终版逐字节一致，SHA 对照见 `fork_manifest.json`）：prj9 光链路全套 + prj10 内存桥四件套/顶层/仲裁器 + 三件派生副本（udp_tx / frame_fifo_pump / cmd_channel 已顶替 prj9 原位） |
| `xdc/` | 约束（prj9 全文 + L92 修正 + DDR 107 脚，与 prj_loop 逐字节一致） |
| `scripts/` | `create_project.tcl`（幂等建工程）/ `build_debug.tcl`（四域 ILA + 实现 + 位流，fork 自 prj_loop） |
| `sim/` | 回归 TB + 一键 bats：W2 六用例 / W4 联合（含负向）/ W5 命令通道（含负向）/ 泵压力（orig vs L1）/ 仲裁器 |
| `vivado/` | Vivado 工程（**不入库**，由 create_project.tcl 再生） |

## fork 完整性判据（B0⑥，2026-10-10 全过）

1. **文件级**：45 文件 SHA256 与源逐一致（`fork_manifest.json`，fork 时点快照；之后本工程的本地适配——3 个 bat 的路径改指本工程 rtl、pump_stress.bat 注释转 ASCII——不回写 manifest，以 git 历史为准）；
2. **仿真回归（用本工程 rtl 编译）**：W2 六用例 PASS 且 STAT 与 prj10 基线逐字一致（586/585、931/921 cycles、帧周期 12.30 µs）· W4 联合 PASS（A/B 各 wm=wr=rd=148 全 0 错误）· W5 命令通道 PASS · 泵压力 L1 PASS（200 帧 0 丢逐字节一致）· 仲裁器 8:8 PASS；**负向对照全部按预期失败**（W4 缺陷路由死锁检出、命令通道负向 68 错）——判据非恒真；
3. **首次构建**：create + build_debug 全绿（结论见毕设 `调试记录/阶段三_prj11_B0断点核查与fork脚手架_2026-10-10.md`）。

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
