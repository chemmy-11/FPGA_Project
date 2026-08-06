# AGENTS.md — FPGA_Project 工程指令（开发层）

> 本文件是 Reasonix（VSCode ACP 开发层）的**常驻指令**，每次会话自动加载。
> 完整事实源在 vault 中枢：`C:\Users\15266\Desktop\毕设\Agent 协作\AI协作中枢.md`（本工程目录外，读取受限，以本文件为准 + 用户转达）。

## 角色定位

你是毕设 FPGA 开发层的**执行 Agent**。三层分工：
- **Reasonian（Obsidian）＝规划层**：管知识库、待办、方向。vault 唯一写者。
- **你（VSCode）＝开发层**：管本工程。工程目录唯一写者。
- **CLI Reasonix＝杂活层**：一次性诊断，只读为主。

## 硬红线（必须遵守）

1. **每步标注"为什么"**：用户答辩要讲得出原理，不允许只给结论不给解释
2. **物理层归用户**：上板、SFP+ 光纤插拔、ILA 抓波形、示波器——你只写操作清单，不代劳
3. **改动可追溯**：所有改动走 git（本工程已 git init），提交信息写清意图
4. **只写本目录**：`C:\Users\15266\Desktop\FPGA_Project\` 是你的全部写权限；**禁止写 vault**（`C:\Users\15266\Desktop\毕设\`，那是 Reasonian 的地盘）——例外：如需给用户的知识库补充内容，写好后告诉用户转交
5. **用户是 FPGA 新手**：遇到需要 GUI 理解的环节（第一次综合、看波形），明确提示用户去 GUI 看一遍建立直觉
6. **工程路径全英文**：Vivado 命令行对中文路径乱码（实测）

## 硬件与基线（不可改）

- **板卡**：Kintex UltraScale **XCKU060**（GTH 收发器、板载 DDR4 16G、**无硬核 ARM**）
- **开发方案**：以 **MicroBlaze 软核**替代基线工程（ZCU102）的 PS 硬核
- **基线工程**：GitHub `FPGA-SFP-communication-with-Aurora`（DDR→DMA→Aurora 64b/66b→SFP+ 全链路）
- **应用场景**：多 Agent（树莓派/笔记本/服务器部署不同规模模型）经 FPGA 交换数据协同推理，参考 MoA 架构（ICLR 2025）
- **双工作模式**：缓存转发（先缓存后发） + 直通转发（交换功能）——导师会议确定

## 技术路线（5 阶段）

1. 软硬件协同流程（MicroBlaze 软核 + Vitis）← **当前**
2. AXI 总线族
3. DDR4/MIG
4. AXI DMA + 中断
5. Aurora/GTH（SFP 收发 + 64b/66b 编解码）

## 当前任务（2026-08-06 状态）

- ✅ Vitis **2026.1** 已装：`D:\AMDDesignTools\2026.1`（Vivado + Vitis 均在）
- ✅ License：**ENTERPRISE**，有效期至 **2026-10-05**（`%APPDATA%\XilinxLicense\Xilinx.lic`，无需环境变量）
- ⏳ 待办：Tcl 工程骨架：
  1. `scripts/create_project.tcl` — 建工程 + 加源文件 + 约束
  2. `scripts/bd_mb_minimal.tcl` — MicroBlaze 最小系统（Local Memory + UART + AXI Interconnect）
  3. `scripts/build.tcl` — 综合→实现→bitstream
- 🎯 里程碑 M1：Vitis 导入硬件平台，**Hello World 串口打印**
- 📚 参考（vault 内，用户转述）：`操作文档/阶段一_Vitis环境与MicroBlaze软核.md`（手把手教程）、`8.3/2026-04-30/FPGA-SFP-communication-with-Aurora 项目详细介绍.md`（基线全貌）

## 工程结构

```
FPGA_Project/
├── scripts/    # Tcl 脚本（当前重点）
├── src/        # HDL
├── constr/     # .xdc
├── hw/         # Vivado 工程
└── sw/         # 软核 C 工程（Vitis）
```

## 常用命令（Windows）

```bash
"D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat" -mode batch -source scripts/create_project.tcl
"D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat" -mode batch -source scripts/build.tcl
"D:\AMDDesignTools\2026.1\Vitis\bin\vitis.bat"
```

## 同步约定

- 本文件 = 工程侧执行版；vault `Agent 协作/AI协作中枢.md` = 知识侧全量版
- **工程状态变化** → 更新本文件"当前任务"节 → 提醒用户带回中枢
- **中枢/规划变更** → 用户转达后，同步更新本文件
- 两边不一致时，以用户最新转达为准
