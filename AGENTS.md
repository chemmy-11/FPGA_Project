# AGENTS.md — FPGA_Project 工程指令（开发层，工作区 D:\FPGA）

> 本文件是 Reasonix（VSCode ACP 开发层）的**常驻指令**，每次会话自动加载。
> 你是工程状态的**唯一事实源**（契约约定，见 vault `Agent 协作/开发协作文档.md`，用户转达）。
> vault 中枢 `Agent 协作/AI协作中枢.md` 是中控维护的同步视图，**可能滞后——以你实测为准**。

## 角色定位

你是毕设 FPGA 开发层的**执行 Agent**，工程状态的**唯一事实源**。三层分工 + 中控（契约：vault 开发协作文档）：
- **Reasonian（Obsidian）＝规划层/第二大脑**：管知识库、待办、方向、成果沉淀。vault 唯一写者。
- **你（VSCode）＝开发层**：管本工程。工程目录唯一写者。状态以你实测为准，主动如实汇报。
- **Reasonix（桌面端）＝协调中控**：任务路由、同步中枢↔本文件、状态看板、复杂任务/杂活兜底。你只需向用户汇报状态，同步由中控负责。
- **多会话约定**（中枢 §5.6，2026-08-07 立）：桌面端可能多会话并存，同一时间仅**一个活跃中控**（「协调中控」topic）；多个中控会话向你问状态时如实汇报即可，状态出入一律以你实测为准

## 硬红线（必须遵守）

1. **每步标注"为什么"**：用户答辩要讲得出原理，不允许只给结论不给解释
2. **物理层归用户**：上板、SFP+ 光纤插拔、ILA 抓波形、示波器——你只写操作清单，不代劳
3. **改动可追溯**：所有改动走 git（本工程已 git init），提交信息写清意图
4. **只写本目录**：`D:\FPGA\` 是你的全部写权限；**禁止写 vault**（`C:\Users\15266\Desktop\毕设\`，那是 Reasonian 的地盘）——例外：如需给用户的知识库补充内容，写好后告诉用户转交
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

## 当前任务（2026-08-12，M2 进行中）

- 🎯 **M2 已启动（2026-08-12）**：阶段二 **AXI 总线族**——目标：搞懂 MicroBlaze 的 AXI 接口与地址映射，能在 design_1 里对照实物讲解/修改总线结构。学习路线：① AXI4/AXI4-Lite/AXI4-Stream 三种协议 + 通道与 VALID/READY 握手 → ② 对照 design_1：microblaze_0 M_AXI_DP → axi_interconnect（地址译码）→ uartlite S_AXI（0x40600000）→ ③ 地址编辑器/软件读写寄存器验证 → ④ 动手实验：自定义 AXI-Lite IP（如 LED 寄存器）全流程走一遍。硬件侧流程不变（HW Manager 烧位流 + Vitis 取消 Program FPGA）
- 🎉 **里程碑 M1 达成（2026-08-11 晚）**：Vitis 导入硬件平台 → Hello World 串口打印成功（COM7@9600）。最终流程：Vivado 出 bitstream（part=`xcku060-ffva1156-2-i`）→ HW Manager 手动烧录 → Vitis 更新 XSA 硬件规格 + **Run Configuration 取消 Program FPGA 勾选**（保留 Reset entire system）→ Run（MDM 下载程序）
- 🧩 **M1 前全部故障根因复盘**：Vitis 报 `DONE PIN is not HIGH`（2023.1）/ `End of startup status: LOW`（2026.1）的**唯一根因 = part 选错**（`xcku060_CIV` 系学长教学视频参数，本板实物为非 CIV）。对照实验链：LED 冒烟（非 CIV part，成功）vs MicroBlaze（CIV part，失败）→ 位流头部 part 字段对比 → 定性。MODE=001、链路不稳、FT_Write=0 均为干扰项（次因/无关）。教训：教学视频参数 ≠ 实物，参数以实测为准

- ✅ Vivado/Vitis **2023.1** 已装：`D:\Xilinx\Vivado\2023.1` + `D:\Xilinx\Vitis\2023.1`（2026.1 已卸载，迁移依据见 `2026.1_工作交接文档.md`）
- ✅ License：**ENTERPRISE**，有效期至 **2026-10-05**（`%APPDATA%\XilinxLicense\Xilinx.lic`，无需环境变量）
- ✅ **板卡参数已确认**（2026-08-11 晚，实测修正）：
  - part = **`xcku060-ffva1156-2-i`（非 CIV 变体）**——铁证：CIV part 位流 Program 必报 startup LOW，非 CIV 位流成功且功能正常（LED 冒烟对照，2026-08-11 晚）；此前记录的 `xcku060_CIV` 为 2026.1 时代错误假设，**作废**（丝印核对无需再做，实测已定性）
  - 板载晶振 = **100MHz 差分**（与官方 `KU_IO.xdc` 第 5 行 `create_clock -period 10.000` 一致；旧默认"200MHz 单端"作废）
- ✅ **新 GUI 工程 `D:\FPGA\project_1`**（2026-08-11 建，Vivado 2023.1）：BD `design_1` = MicroBlaze 最小系统（Local Memory 64KB + AXI UART Lite **9600 波特率** + AXI Interconnect + MDM + clk_wiz 100MHz 差分输入 + rst_clk_wiz_1_100M）；**综合已通过**（0 错误，7 个 LMB/复位未连接类无害警告）
- ✅ 约束已进工程：`project_1/project_1.srcs/constrs_1/constraints/ku060_pins.xdc`（引脚取自官方 KU_IO.xdc：clk_p=AK17 差分、reset=AC34 低有效、uart=AE33/AF34，端口名已适配 wrapper；**2026-08-11 batch 验证已注册进 constrs_1，重跑综合 0 错误**；注释为纯英文 ASCII，中文在 Vivado 编辑器会 GBK 乱码）
- ⚠️ `vivado_project/`（Tcl 骨架三件套）已移除**且无 git 历史**（`D:\FPGA\` 现非 git 仓库）——脚本不可恢复；若需脚本化重建，可从 `design_1.bd` 用 `write_bd_tcl` 重新生成
- ⛔ **原阻塞已突破（2026-08-11 晚）**：最小设计（led.v：按键取反→LED，无时钟无 IP）经 Vivado Hardware Manager Program **成功**（`xcku060 is programmed`）→ **JTAG 配置链路本身是好的**。MODE=001 理论**排除**（UG570 明文：JTAG 配置与 MODE 引脚选择无关；GPT 建议.md 亦确认）。根因方向 = **JTAG 链路/Vitis 调用路径**（偶发失败 + FT_Write=0 + 此前 Vitis Program 必败而 HW Manager 成功）。下一步：确认频率因素 → HW Manager 烧 project_1 bitstream → Vitis 取消 Program FPGA 勾选直接下载程序（MDM 路径）→ M1
- 📄 参考：`GPT建议.md`（外部 AI 诊断，2026-08-11 放根目录；含 UG570/UG908/UG912 引用与实验设计）
- ✅ **part 修正已验证**（2026-08-11 晚）：改 part 为 `xcku060-ffva1156-2-i`（非 CIV）重跑综合/实现/bitstream → **HW Manager 烧录成功**（`End of startup status: HIGH`）→ 原 CIV 假设彻底作废（源头：学长教学视频，非本板实物）
- ⏳ 待办（下一步）：
  1. 建议：`git init` 重新建立版本追踪（红线 3，M1 成果值得入档）
  2. M2 第一步：打开 design_1 的 Address Editor 与 AXI Interconnect，对照讲解 AXI 协议基础（详见"M2 已启动"条）
  3. 可选：`write_bd_tcl` 把 design_1.bd 固化成脚本（防工程丢失，vivado_project/ 的教训）
- 🎯 里程碑 M1：Vitis 导入硬件平台，**Hello World 串口打印**
- 📚 参考（vault 内，用户转述）：`操作文档/阶段一_Vitis环境与MicroBlaze软核.md`（手把手教程）、`8.3/2026-04-30/FPGA-SFP-communication-with-Aurora 项目详细介绍.md`（基线全貌）

## 工程结构

```
D:\FPGA\
├── project_1/             # Vivado 2023.1 GUI 工程（2026-08-11 建，当前事实源）
│   ├── project_1.xpr
│   ├── project_1.srcs/    # sources_1（BD design_1）+ constrs_1/constraints/ku060_pins.xdc
│   ├── project_1.runs/    # synth_1（完成）/ impl_1（待跑）
│   └── project_1.gen/     # 生成物（wrapper、IP 网表）
├── KU_IO.xdc              # 官方板卡 IO 引脚表（GBK 编码；时钟 100MHz 差分 AK17、复位 AC34、UART AE33/AF34）
├── KU引脚表.xlsx
├── test/                  # 旧测试工程（2026-08-07，已废弃）
└── *.md                   # 交接/协作文档（2026.1_工作交接文档.md 等）
```

- `vivado_project/`、`vitis_project/` 已移除（2026-08-11 前）；Vitis 阶段工作区届时 GUI 新建即可

## 常用命令（Windows）

```bash
"D:\Xilinx\Vivado\2023.1\bin\vivado.bat" D:\FPGA\project_1\project_1.xpr   # 打开工程（GUI）
"D:\Xilinx\Vitis\2023.1\bin\vitis.bat"                                     # Vitis（工作区 GUI 新建）
```

## 同步约定

- 本文件 = 工程侧**唯一**执行版；vault `Agent 协作/AI协作中枢.md` = 中控维护的**状态视图**（可能滞后，以你实测为准）
- 协作契约 = vault `Agent 协作/开发协作文档.md`（四方模型、事实源、柔性边界；变更由用户转达）
- **工程内不维护 vault 文档副本**（`docs/` 已于 2026-08 移除）：需要什么信息直接更新本文件，参考文档一律回 vault 查（`毕设\` 下：短期待办、操作文档、8.3 会议纪要等），由用户转达或中控同步要点
- **工程状态变化** → 你更新本文件"当前任务"节，并向用户报告一句"状态已更新"；**中枢同步由协调中控（桌面端 Reasonix）负责，你无需跨目录操作**
- **中枢/规划变更** → 协调中控会同步到本文件，新会话自动加载
- 两边不一致时，向用户确认后以中枢为准
