# vivado-mcp — 让 AI 直接操作 Vivado 的 MCP 服务

把 Vivado 的常用操作封装成 **32 个 MCP 工具**，供 Claude Code 等 MCP 客户端直接调用：
读工程、查时序、审约束、看波形、跑综合实现、抓 ILA——**不用在 GUI 里一步步点**。

> 本目录是本工具的**可移植副本**（随仓库发布，便于协作者复现调试环境）。
> 不含任何本机专有配置（无绝对路径、无虚拟环境、无本机凭据）。

## 它怎么工作

```
AI 客户端 ──(stdio, MCP 协议)──▶ vivado-mcp
                                    │
                          SessionManager（会话管理，可开多个 Vivado 实例）
                                    │
                          vivado -mode tcl  ◀── TCP 下发 Tcl（默认端口 9999）
```

- **默认模式**：以 `-mode tcl` 拉起 Vivado 子进程，经 TCP 端口下发 Tcl 命令、回收文本结果；
- **GUI 接管模式（可选）**：`install` 子命令把一个小 TCP server 注入 `Vivado_init.tcl`，
  这样**手动打开 Vivado GUI 时也会自动挂上服务端**，同样能被工具接管。
  首次注入会备份原文件为 `Vivado_init.tcl.vmcp_backup`，`uninstall` 可还原。

## 安装与使用

依赖：**Python 3.10+** 与 MCP SDK（`python -m pip install mcp`）。

```powershell
# 0) 把本目录加入 PYTHONPATH（或 pip install -e .）
$env:PYTHONPATH = "D:\FPGA\vivado-mcp"

# 1) 先跑只读诊断——确认能找到 Vivado、依赖齐全
python -m vivado_mcp doctor

# 2) 可选：注入 Vivado_init.tcl，让 GUI 启动的 Vivado 也能被接管
python -m vivado_mcp install          # 默认端口 9999
python -m vivado_mcp uninstall        # 撤销注入

# 3) 启动 MCP server（stdio，供 AI 客户端连接）
python -m vivado_mcp
```

**Vivado 定位顺序**：`VIVADO_PATH` 环境变量 → 系统 `PATH` → 常见安装目录
（Windows `D:/Xilinx/Vivado/*/bin/vivado.bat`、`C:/Xilinx/...`；Linux `/tools/Xilinx/...` 等，取版本号最大者）。

## 32 个工具

| 模块 | 工具 | 用途 |
|---|---|---|
| **会话** | `start_session` · `stop_session` · `list_sessions` | 开/关/列出 Vivado 会话 |
| **Tcl** | `run_tcl` · `safe_tcl` | 直接下发 Tcl（`safe_tcl` 带保护） |
| **工程** | `parse_xpr` · `get_project_info` · `get_run_progress` | 不解压工程即读工程结构/状态 |
| **流程** | `run_synthesis` · `run_implementation` · `generate_bitstream` · `program_device` | 综合/实现/出流/烧录 |
| **报告** | `get_timing_report` · `get_utilization_report` · `get_io_report` · `get_ip_status` · `check_bitstream_readiness` · `get_pre_commit_summary` · `get_next_suggestion` | 时序/资源/IO/IP 状态与出流前自检 |
| **诊断** | `get_critical_warnings` · `xdc_lint` · `xdc_auto_fix` · `verilog_compile_check` · `verify_io_placement_tool` | 关键告警、约束体检、语法/引脚核对 |
| **CDC** | `get_cdc_report` | 跨时钟域检查报告 |
| **二进制/探针** | `parse_bit_header` · `parse_ltx` | 位流头部元数据、ILA 探针文件 |
| **IP** | `inspect_ip_params` · `compare_xci` | 读 IP 配置参数、比对两份 xci |
| **波形** | `query_waveform` · `set_wave_zoom` · `set_wave_analog` | 查 VCD、调波形显示 |

其中 `parse_xpr` / `parse_bit_header` / `parse_ltx` / `xdc_lint` **属离线工具**：
不启动 Vivado、不开会话，可随时并行调用。

## 已知约束（都是踩过的坑）

1. **安装路径必须纯 ASCII。** 中文路径经 Vivado Tcl 的 ANSI(GBK) 解码会变成乱码，`start_session` 必然失败。
   把工具放在纯英文路径下（如 `D:\FPGA\vivado-mcp`）。
2. **会话不跨进程。** CLI 壳每个子命令都是新进程，会话会丢；**多步操作必须在同一次调用/同一进程内完成**。
3. **Vivado 会话、综合、实现、仿真应全局串行。** 同一时刻只让一个客户端占用 Vivado，避免互相踩。
   仓库内约定用锁文件 `D:\FPGA\.mcp-pilot-vivado.lock` 串行化。
4. **烧板永远归人。** `program_device` 存在，但本项目约定物理操作由人执行，AI 只产出操作清单。
5. **`compare_xci` 只吃 XML 版 .xci。** Vivado 2020.1+ 默认生成 JSON 版 xci，传给它会报 XML 解析失败。

## 目录结构

```
vivado_mcp/
├─ __main__.py            入口：serve / install / uninstall / doctor / version
├─ server.py              MCP server 实例、工具注册、Prompts
├─ config.py              Vivado 路径检测（VIVADO_PATH → PATH → 默认安装目录）
├─ install.py             注入 / 移除 Vivado_init.tcl（自动备份）
├─ doctor.py              只读环境诊断
├─ workflows.py           预置工作流
├─ prompts.py             面向 AI 的提示词模板
├─ tcl_scripts.py         Tcl 脚本片段库
├─ analysis/              26 个解析器（时序 / CDC / XDC / 告警 / 波形 / LTX / 位流头 / IP 参数…）
├─ tools/                 10 个工具模块（上表 32 个工具）
├─ vivado/                会话管理（tcl 子进程 / GUI 会话 / 会话池）
├─ scripts/               vivado_mcp_server.tcl（注入 GUI 的服务端）
└─ skills/                5 份技能说明（工程 bring-up / 时序收敛 / 约束编写 / CDC 审计 / 波形调试）
```

## 与"本机桥"的区别

本机（开发者的 Windows 环境）另有一层 CLI 壳用于命令行快速调用；那是**开发者的本地便利设施**，
依赖本机路径与虚拟环境，**不在本仓库内**。本目录提供的是**与机器无关的工具本体**，
按上面的"安装与使用"即可在任意机器上复现。

## 来源、许可与改动

- **上游项目**：**[mapleleavessssssss-wq/vivado-mcp](https://github.com/mapleleavessssssss-wq/vivado-mcp)**
  * 版本 **v0.3.26**（2026-09-22）· 上游默认分支 `main` · PyPI 包名 `vivado-mcp`
  * 上游定位：让 Claude Code / Cursor / Codex 驱动本地 FPGA 全流程（30 个精选工具 + 8 个证据驱动 Prompt + GUI/Tcl/attach 会话）
- **许可**：**Apache License 2.0** —— 全文见同目录 [`LICENSE`](LICENSE)（随源码一并提供，符合 Apache-2.0 第 4 条对再分发的要求）
- **本目录所做的改动**：**零代码改动**，仅目录重组。
  * 与上游 v0.3.26 逐字节比对：**52 个文件完全相同、0 个被修改**
  * 上游布局为 `src/vivado_mcp/` + 顶层 `scripts/` + 顶层 `skills/`；本目录把包平铺为 `vivado_mcp/`，并把 `scripts/`（1 个 Tcl）与 `skills/`（5 份 SKILL.md）移入包内——这 6 个文件内容原样
- **版本适配说明**：上游作者以 **Vivado 2019** 为基准开发；本项目运行于 **Vivado 2023.1**。
  * 实测：离线工具（`parse_xpr` / `parse_bit_header` / `parse_ltx` / `xdc_lint`）与 Vivado 会话在该版本下均可用
  * 已知差异：Vivado **2020.1+ 生成的 JSON 版 `.xci`** 会让 `compare_xci` 报 XML 解析失败（上游按 XML 版 `.xci` 设计）——本项目 2023.1 的 `.xci` 全部为 JSON 版，故该工具在本项目内不可用
