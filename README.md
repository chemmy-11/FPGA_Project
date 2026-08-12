# FPGA_Project — 毕设 FPGA 工程

多 Agent 协同推理的 FPGA 交换节点：Kintex UltraScale **XCKU060** 经 **MicroBlaze 软核** + AXI 总线族 + DDR4 + AXI DMA + Aurora 64b/66b（SFP+）实现数据交换，参考 MoA 架构（ICLR 2025）。双工作模式：缓存转发 + 直通转发。

## 里程碑

- ✅ **M1（2026-08-11）**：Vitis 导入硬件平台，Hello World 串口打印成功（COM7@9600）
- ⏳ **M2（进行中）**：AXI 总线族（协议/地址映射/自定义 IP）

## 工程结构

```
D:\FPGA\
├── project_1/             # Vivado 2023.1 GUI 工程（事实源）：BD design_1 = MicroBlaze 最小系统
│   └── project_1.srcs/    # BD + 约束 ku060_pins.xdc（英文注释）
├── KU_IO.xdc              # 官方板卡 IO 引脚表（GBK 编码）
├── KU引脚表.xlsx
├── AGENTS.md              # 工程指令/状态事实源（开发层常驻）
├── M1进度总结_2026-08-11.md
├── GPT建议.md             # 外部 AI 诊断留档
└── test/                  # 废弃测试工程（不提交）
```

## 硬件基线（实测定论）

- part = **`xcku060-ffva1156-2-i`（非 CIV）**；100MHz 差分晶振；N25Q128 Flash；CH340 UART（9600）
- JTAG：正点原子 FT2232H（Digilent JTAG-HS1）；同刻仅一个客户端占线

## 标准开发流程

1. Vivado：设计 → 综合/实现 → Generate Bitstream → Export Hardware（含 bitstream）→ .xsa
2. Hardware Manager：Program Device（成功标志 `End of startup status: HIGH`）
3. Vitis：更新 .xsa → Run Configuration **取消 Program FPGA**（保留 Reset entire system）→ Run → 串口 9600
