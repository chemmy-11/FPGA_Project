# project_10 — 内存进环路（prj10 · W2 内存桥 RTL 与仿真）

> 课题：面向边缘多节点协作的 FPGA 高速互联网络平台。本工程把 **DDR4 内存读写（含随机读写）**
> 放进"以太网 ↔ 光回环"环路，使数据面从"流式直通"变为"**按地址存储转发**"。
> 工程规范见 `../AGENTS.md`；进度与决策见 `../README.md` 与 vault。

## 状态（2026-09-29）

| 工作包 | 内容 | 状态 |
|---|---|---|
| **W2** | 内存桥 RTL + xsim 仿真（含槽管理协议仿真 + 静态预算） | ✅ **本次完成，`=== prj10 W2 SIM: PASS (0 errors) ===`** |
| W0 | 复现 prj9 基线 | ⏸ 需上板（用户） |
| W1 | MIG 上板收尾（= #14 D 线 D1，两线共用） | ⏸ 未取得 `init_calib_complete` |
| W3–W6 | 两级插桥 / 随机读判据 / 命令通道 / 判决计数器 | ⏸ 待 W1 |

**本轮边界（红线）**：**未创建 Vivado 工程**（无 .xpr / 无综合 / 无实现 / 无位流），只用
`xvlog / xelab / xsim` 三个批处理命令；`project_4` 与 `project_9` **一个字节未改**；未涉及上板。
待导师 Q1–Q5 拍板后再升格为完整工程（W3 起接 MIG 与 prj9 网络资产）。

## 目录

```
rtl/
  async_fifo.v           格雷指针异步 FIFO（CDC 基元，FWFT）
  axi4_master_bridge.v   ui_clk：AXI4 512b 主机 + 槽表(valid/len) + 读/写 FSM + MIG 硬门控
  frame_mem_if.v         顶层：帧侧 8b 接口 + 5 个 CDC FIFO + 控制寄存器 + 桥实例
sim/
  axi4_ram_model.v       行为级 AXI4 从机 + 1MB RAM + 监视器（4KB / 拍数 / 协议）—— MIG 替身
  mem_bridge_tb.sv       W2 验收 TB（T1–T6，双时钟：user 151.5 MHz / ui 300 MHz）
  dbg_tb.sv              单帧全信号追迹工具（bring-up 排障）
  run_sim.bat            一键复现（推荐入口）
  run_sim.ps1            同上（PowerShell 版，需 -ExecutionPolicy Bypass）
docs/
  prj10_W2_mem_bridge_design_note_2026-09-29.md
```

## 一键复现

```bat
cd D:\FPGA\prj\project_10\sim
run_sim.bat
type xsim_run.log | findstr "SIM:"
rem 期望： === prj10 W2 SIM: PASS (0 errors) ===
```

## 槽策略（一句话）

写槽 = `wm[7:0]`，**槽仍 FULL 就拒收**（绝不覆盖未读帧）；SEQ 读最老未读槽；
RND 越界 → `ill_rd_cnt++` + clamp，非驻留槽 → **定长 0 空应答**；槽满抬 `wr_hold` 让上游可暂停。

## W2 实测（2026-09-29）

```
T6 MIG 硬门控 PASS · T1 逐字节一致 PASS · T4 乱序读 PASS
T5 非法读定长应答 PASS · T2 300 帧回绕 PASS · T3 槽满不覆盖 PASS
4KB 违规 0 · AXI 协议错 0 · wm=wr=rd=585 · 服务 wr 3.11 us / rd 3.07 us 每帧（帧周期 12.30 us）
```
