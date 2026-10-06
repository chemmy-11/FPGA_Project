# 第三方组件与素材声明

> 本文件列明本仓库中**不属于作者原创**的内容及其权利归属。
> 根目录 [`LICENSE`](LICENSE)（MIT）**仅覆盖作者原创部分**；下列内容**不适用**该许可，各自遵循其原始条款。
> 本文件为第三方组件与版权素材声明（NOTICE 性质）。

## 一、随仓库分发的第三方软件

| 组件 | 位置 | 许可 | 说明 |
|---|---|---|---|
| **vivado-mcp** | `vivado-mcp/` | **Apache-2.0** | 上游 [mapleleavessssssss-wq/vivado-mcp](https://github.com/mapleleavessssssss-wq/vivado-mcp) **v0.3.26**。本仓库副本为**零代码改动的目录重组**（逐字节比对 52 文件相同 / 0 修改），许可证全文见 [`vivado-mcp/LICENSE`](vivado-mcp/LICENSE) |

## 二、AMD / Xilinx 版权素材（**不适用本仓库 MIT**）

本仓库是 FPGA 工程，相当一部分文件**由 AMD/Xilinx 官方例程与 Vivado IP 生成**，版权归 AMD/Xilinx：

| 范围 | 位置 |
|---|---|
| Aurora 64b/66b 官方例程（原样留档） | `prj/aurora_64b66b_loop_ex/` |
| IBERT 眼图官方例程 | `prj/ibert_ultrascale_gth_0/` |
| 以太网 UDP 官方例程（39 章）移植件与参考件 | `prj/project_6/rtl/eth_udp_loop.v` · `prj/project_7/rtl/eth_udp_loop.v` · `prj/project_8/rtl_ref/eth_udp_loop.v` 及同名 `.xdc` |
| 官方板卡引脚约束 | `KU_IO.xdc` · `prj/0DMA_uart2ddr/project_1/project_1.srcs/constrs_1/imports/Downloads/KU_IO.xdc` |
| Vivado IP 生成的 RTL / 网表 / 约束 | 各工程 `ip/`、`*.srcs/` 下的生成物 |
| 官方例程随附文档与图形 | `prj/project_6/doc/` 等 |

**权利归 AMD/Xilinx**，系随官方例程库与 Vivado IP 目录分发而来，仅供本课题学习与研究使用。
本仓库**不对其授予任何许可，亦不主张任何权利**；如需商用或再分发，请自行向 AMD 确认条款。

## 三、来源未考证的参考设计（**不适用本仓库 MIT**）

| 范围 | 位置 | 说明 |
|---|---|---|
| MicroBlaze + DDR4(MIG) + AXI DMA + UART 参考设计 | `prj/0DMA_uart2ddr/` | 第三方参考工程（Vivado 2019.2，已含位流），**来源未考证**；本项目**仅作技术参考骨架**，未验证其可运行性，**不主张权利、不授予许可** |

## 四、作者原创部分

除上述范围外，本仓库的自研 RTL、脚本、文档、评测工具与工具链封装等均为作者原创，
按根目录 [`LICENSE`](LICENSE)（**MIT License**，仅供学习研究使用）授权。

---

*如发现本文件中归属有误或遗漏，欢迎提 Issue 指正。*
