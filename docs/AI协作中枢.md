---
tags: [毕设, AI协作, 中枢]
type: 协作文档
created: 2026-08-06
---

# 🧭 AI 协作中枢

> 本文件是**三层 AI 协作架构的唯一沟通中枢**：
>
> - **Reasonian（Obsidian 插件）＝规划层**：管 vault 文档、待办、方向；维护本文件
> - **VSCode Reasonix（ACP）＝开发层**：管工程开发；开工前必读本文件
> - **Reasonix（桌面端）＝协调中控**：任务路由、文档同步、状态看板、杂活兜底；维护本文件
>
> 状态一变化，由当事方汇报用户，更新本文件。**保持本文件为最新事实源。**
>
> **工程侧副本**：`C:\Users\15266\Desktop\FPGA_Project\AGENTS.md`（VSCode Reasonix 自动加载的常驻指令）。工程相关变更需同步到该文件（开发层可直接更新，规划层/用户转达变更后同步）。

---

## 1. 一句话

毕设课题为 **FPGA 高速互联网络平台设计与实现**——用 FPGA 搭建多 Agent 协同推理的数据交换平台，重点在 **FPGA 网络层优化**（缓存/直通转发、Fat-Tree 多路径、拥塞感知负载分发）。

## 2. 硬件与基线（不可改）

- **板卡**：Kintex UltraScale **XCKU060**（GTH 收发器、板载 DDR4 16G、**无硬核 ARM**）
- **开发方案**：以 **MicroBlaze 软核**替代基线工程（ZCU102）的 PS 硬核
- **基线工程**：GitHub `FPGA-SFP-communication-with-Aurora`（DDR→DMA→Aurora 64b/66b→SFP+ 全链路）
- **应用场景**：多 Agent（树莓派/笔记本/服务器部署不同规模模型）经 FPGA 交换数据协同推理，参考 MoA 架构（ICLR 2025）

## 3. 技术路线（5 阶段，来自任务分工）

1. 软硬件协同流程（MicroBlaze 软核 + Vitis）
2. AXI 总线族
3. DDR4/MIG
4. AXI DMA + 中断
5. Aurora/GTH（SFP 收发 + 64b/66b 编解码）

**当前处于**：阶段 1（Vitis 环境搭建中）。

## 4. 工程目录约定（重要）

```
C:\Users\15266\Desktop\毕设\            ← Obsidian vault：知识/文档（只读）
C:\Users\15266\Desktop\FPGA_Project\     ← Vivado/Vitis 工程（VSCode Reasonix 主战场，全英文路径）
    ├── scripts\    # Tcl 脚本
    ├── src\        # HDL
    ├── constr\     # .xdc
    ├── hw\         # Vivado 工程
    └── sw\         # 软核 C 工程
```

- 工程采用 **Tcl-first 模式**：Block Design 全部用 Tcl 脚本生成（`create_bd_cell` 等），不用 GUI 拖拽
- 整个 `FPGA_Project\` 用 **git 管理**，每次改动可追溯

## 5. 协作红线（必须遵守）

1. **每步标注"为什么"**：用户答辩要讲得出原理，不允许只给结论不给解释
2. **物理层归用户**：上板、SFP+ 光纤插拔、ILA 抓波形、示波器——AI 只写操作清单，不代劳
3. **改动可追溯**：代码/Tcl 改动走 git；log 解读结论写回本文件或操作文档
4. **三层分工 + 中控（写权限严格隔离）**：
   - **Reasonian（Obsidian 插件）＝规划层**：管 vault 文档/待办（`毕设\` 唯一写者），定方向
   - **VSCode Reasonix（ACP）＝开发层**：管 `FPGA_Project\` 工程（工程目录唯一写者，跑 vivado/vitis）
   - **Reasonix（桌面端）＝协调中控**：任务路由、同步中枢↔AGENTS.md、维护状态看板、杂活兜底；可写中枢与 AGENTS.md，不写其他 vault 文档与工程实现代码
   - 状态变化由当事方汇报中控，中控负责同步两处文档
5. **用户是新手**：遇到需要 GUI 理解的环节（第一次综合、看波形），提示用户去 GUI 看一遍建立直觉

## 6. 关键参考文档（vault 内，读前先看）

| 文档 | 用途 |
|------|------|
| `8.3/讨论2026-08-03.md` | 导师会议纪要：双模式（缓存转发/直通转发）、三阶段计划 |
| `8.3/任务分工-2026-05-07.md` | 5 阶段路线 + 双组分工 + AXI4-Stream 接口契约 |
| `8.3/2026-04-30/FPGA-SFP-communication-with-Aurora 项目详细介绍.md` | 基线工程全貌（复现对象） |
| `8.3/2026-04-30/block_diagram.md` | 基线 Block Design 端口清单 |
| `操作文档/阶段一_Vitis环境与MicroBlaze软核.md` | 阶段 1 手把手教程 |
| `操作文档/阶段二_SFP收发与Aurora64b66b.md` | 阶段 2 手把手教程（环回测试 + ILA） |
| `8.3/Aurora/d8e77ba2-c98d-4e48-bda4-6741a163625e.md` | Aurora 64B/66B 实战踩坑（PMA_INIT 时序、异步 FIFO、lane_up 排查） |
| `短期待办.md` | 当前任务清单 + 里程碑（M1: Hello World / M2: SFP 环回） |

## 7. 三方状态看板（协调中控维护，每次会话更新）

| 方 | 状态 | 进行中 | 待办 |
|----|------|--------|------|
| Reasonian（规划） | 就绪 | — | 按需更新待办/规划 |
| VSCode Reasonix（开发） | 就绪（AGENTS.md 已部署） | Tcl 工程骨架 | M1: Hello World |
| Reasonix（中控，桌面端） | 运行中 | 本次架构升级落地 | 同步机制验证 |
| 用户 | 环境就绪 | Vitis 已装 + License 生效 | VSCode 插件检查 |

## 8. 当前进行中

- [x] Vitis **2026.1 已安装**：`D:\AMDDesignTools\2026.1`（Vivado + Vitis 均在）
- [x] **License 已验证生效**：Vivado Design Suite **ENTERPRISE**，有效期至 **2026-10-05**（license 文件 `%APPDATA%\XilinxLicense\Xilinx.lic`，无需环境变量）——Enterprise 版支持 KU060（UltraScale）
- [x] 工程目录已建：`C:\Users\15266\Desktop\FPGA_Project\`（git 已 init，全英文路径）
- [x] 开发层指令已部署：`FPGA_Project\AGENTS.md`（自动加载）
- [ ] 待办：写 Tcl 工程骨架 `create_project.tcl` → `bd_mb_minimal.tcl`（MicroBlaze 最小系统）→ `build.tcl`（归 VSCode Reasonix）
- [ ] 待办：VSCode 插件（Verilog/Verible/C++/Tcl）检查（归用户）

## 9. 常用命令（Windows）

```bash
"D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat" -mode batch -source scripts/create_project.tcl   # 建工程
"D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat" -mode batch -source scripts/build.tcl            # 综合→实现→bitstream
"D:\AMDDesignTools\2026.1\Vitis\bin\vitis.bat"                                                     # 软核 IDE
xsct                                                                    # 软核脚本化构建
```

---

*由 Reasonix（协调中控）创建于 2026-08-06，三方共同维护。工程状态变化时由中控更新本文件。*
