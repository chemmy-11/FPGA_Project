# FMC_4SFP 四光口子卡 — GTH 引脚速查（2026-08-12 实测整理）

> 来源：`KU引脚表.xlsx`（工作表1/副本）+ Vivado 2023.1 器件数据库反查（GT 站点）。
> 结论：**四个 SFP 口共用同一个 GT Quad（X1Y2）**，参考时钟 P5/P6。

## 一、GT 通道（Quad X1Y2）— 不需要 XDC 约束，靠 IP 位置/封装引脚

| 光口 | 方向 | 信号 | FPGA 引脚 | GT 站点 |
|---|---|---|---|---|
| SFPA | TX | SFPA_TD_P / TD_N | R4 / R3 | GTHE3_CHANNEL_X1Y11 |
| SFPA | RX | SFPA_RD_P / RD_N | P2 / P1 | GTHE3_CHANNEL_X1Y11 |
| SFPB | TX | SFPB_TD_P / TD_N | W4 / W3 | GTHE3_CHANNEL_X1Y9 |
| SFPB | RX | SFPB_RD_P / RD_N | V2 / V1 | GTHE3_CHANNEL_X1Y9 |
| SFPC | TX | SFPC_TD_P / TD_N | U4 / U3 | GTHE3_CHANNEL_X1Y10 |
| SFPC | RX | SFPC_RD_P / RD_N | T2 / T1 | GTHE3_CHANNEL_X1Y10 |
| SFPD | TX | SFPD_TD_P / TD_N | AA4 / AA3 | GTHE3_CHANNEL_X1Y8 |
| SFPD | RX | SFPD_RD_P / RD_N | Y2 / Y1 | GTHE3_CHANNEL_X1Y8 |

通道号对应：SFPD=TX0、SFPB=TX1、SFPC=TX2、SFPA=TX3（引脚表"226_TX*"标注同义）。

## 二、参考时钟 MGTREFCLK

| 信号 | FPGA 引脚 | GT 站点 |
|---|---|---|
| SFP_CLK_P / SFP_CLK_N | **P6 / P5** | GTHE3_COMMON_X1Y3（= Quad X1Y2 的参考时钟） |

- ⚠️ **频率未知（待查）**：Aurora 10G（10.3125 Gbps）需要 **156.25 MHz** 参考时钟；频率不对 gt_pll_lock 不亮。查 FMC 子卡原理图/问黄工。
- Aurora IP 配置：GT Quad 选 **X1Y2**，参考时钟选引脚为 **P5/P6** 的那路（GUI 会显示引脚号；另一个选项 M5/M6 是第二路 refclk）。

## 三、控制信号（每口 4 个，LVCMOS33，需 XDC 约束）

⚠️ **引脚表有两个版本，映射不同——上板前必须与原理图/黄工确认用哪个**（子卡在改动中，备注"四光口的FMC子模块需要改动，黄工已经知道了"）。

| 信号 | 工作表1（老表） | 工作表2（副本） |
|---|---|---|
| SFPA_TX_DIS | AF12 | AD25 |
| SFPA_RX_LOS | AE12 | AD26 |
| SFPA_RS0 / RS1 | AF13 / AE13 | （未列） |
| SFPB_TX_DIS | AH12 | AC26 |
| SFPB_RX_LOS | AG12 | AC27 |
| SFPB_RS0 / RS1 | AH11 / AG11 | （未列） |
| SFPC_TX_DIS | J25 | F27 |
| SFPC_RX_LOS | J24 | E27 |
| SFPC_RS0 / RS1 | M26 / M25 | （未列） |
| SFPD_TX_DIS | H26 | A27 |
| SFPD_RX_LOS | J26 | A28 |
| SFPD_RS0 / RS1 | G27 / H27 | （未列） |

- TX_DIS 通常**拉低**才能让光模块发光；RX_LOS 是接收失锁指示（读回用）。
- 电平 LVCMOS33（注意：与系统 IO 的 LVCMOS18 不同 bank）。

## 四、操作要点

- GT 差分对**不需要** PACKAGE_PIN 约束（表内备注"差分引脚不用绑定"），Aurora IP 选好 Quad 后由封装引脚自动定位。
- 环回测试：4 个口任选一个插光模块 + 光纤环回即可；双口互连也行（同一 Quad）。

## 五、XDC 草稿（控制信号，待定版后启用）

> ⚠️ 引脚版本未确认前**不要启用**。确认用哪版后：删掉另一版注释、按顶层端口名调整 `get_ports`、加入工程约束文件（注释保持 ASCII 英文防 GBK 乱码）。

```tcl
# ===== FMC_4SFP control signals (LVCMOS33) — VERSION A (工作表1) =====
set_property -dict {PACKAGE_PIN AF12 IOSTANDARD LVCMOS33} [get_ports SFPA_TX_DIS]
set_property -dict {PACKAGE_PIN AE12 IOSTANDARD LVCMOS33} [get_ports SFPA_RX_LOS]
set_property -dict {PACKAGE_PIN AF13 IOSTANDARD LVCMOS33} [get_ports SFPA_RS0]
set_property -dict {PACKAGE_PIN AE13 IOSTANDARD LVCMOS33} [get_ports SFPA_RS1]
set_property -dict {PACKAGE_PIN AH12 IOSTANDARD LVCMOS33} [get_ports SFPB_TX_DIS]
set_property -dict {PACKAGE_PIN AG12 IOSTANDARD LVCMOS33} [get_ports SFPB_RX_LOS]
set_property -dict {PACKAGE_PIN AH11 IOSTANDARD LVCMOS33} [get_ports SFPB_RS0]
set_property -dict {PACKAGE_PIN AG11 IOSTANDARD LVCMOS33} [get_ports SFPB_RS1]
set_property -dict {PACKAGE_PIN J25  IOSTANDARD LVCMOS33} [get_ports SFPC_TX_DIS]
set_property -dict {PACKAGE_PIN J24  IOSTANDARD LVCMOS33} [get_ports SFPC_RX_LOS]
set_property -dict {PACKAGE_PIN M26  IOSTANDARD LVCMOS33} [get_ports SFPC_RS0]
set_property -dict {PACKAGE_PIN M25  IOSTANDARD LVCMOS33} [get_ports SFPC_RS1]
set_property -dict {PACKAGE_PIN H26  IOSTANDARD LVCMOS33} [get_ports SFPD_TX_DIS]
set_property -dict {PACKAGE_PIN J26  IOSTANDARD LVCMOS33} [get_ports SFPD_RX_LOS]
set_property -dict {PACKAGE_PIN G27  IOSTANDARD LVCMOS33} [get_ports SFPD_RS0]
set_property -dict {PACKAGE_PIN H27  IOSTANDARD LVCMOS33} [get_ports SFPD_RS1]

# ===== FMC_4SFP control signals — VERSION B (工作表2/副本，RS0/RS1 未列) =====
# set_property -dict {PACKAGE_PIN AD25 IOSTANDARD LVCMOS33} [get_ports SFPA_TX_DIS]
# set_property -dict {PACKAGE_PIN AD26 IOSTANDARD LVCMOS33} [get_ports SFPA_RX_LOS]
# set_property -dict {PACKAGE_PIN AC26 IOSTANDARD LVCMOS33} [get_ports SFPB_TX_DIS]
# set_property -dict {PACKAGE_PIN AC27 IOSTANDARD LVCMOS33} [get_ports SFPB_RX_LOS]
# set_property -dict {PACKAGE_PIN F27  IOSTANDARD LVCMOS33} [get_ports SFPC_TX_DIS]
# set_property -dict {PACKAGE_PIN E27  IOSTANDARD LVCMOS33} [get_ports SFPC_RX_LOS]
# set_property -dict {PACKAGE_PIN A27  IOSTANDARD LVCMOS33} [get_ports SFPD_TX_DIS]
# set_property -dict {PACKAGE_PIN A28  IOSTANDARD LVCMOS33} [get_ports SFPD_RX_LOS]
```
