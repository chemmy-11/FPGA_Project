##1、
**DDR 到 DDR 的 DMA 回环测试**：它不是 DMA 内部自己直接搬，而是：

1. MM2S 通道从 DDR 源地址读数据；
2. 读出的数据从 `M_AXIS_MM2S` 变成 AXI-Stream；
3. AXIS FIFO 暂存这个数据流；
4. FIFO 再把数据流送进 `S_AXIS_S2MM`；
5. S2MM 通道把流数据写到 DDR 目标地址。

##2、
axi_smc/M00_AXI 接 DDR 的 C0_DDR4_S_AXI
从 AXI 总线关系看：
```
AXI 主设备 → AXI 从设备
```
DMA 的两个内存接口是主设备：

```
M_AXI_MM2S
M_AXI_S2MM
```

DDR 控制器是从设备：

```
C0_DDR4_S_AXI
```

中间的 `axi_smc` 负责仲裁和转发。

所以整体关系是：

```
DMA M_AXI_MM2S  ┐
DMA M_AXI_S2MM  ├→ axi_smc → DDR C0_DDR4_S_AXI
MicroBlaze AXI  ┘
```

`axi_smc/M00_AXI` 是 SmartConnect 的输出主接口，它去访问 DDR 控制器的从接口 `C0_DDR4_S_AXI`。

所以这条线的含义是：

```
所有要访问 DDR 的 AXI 请求，最后都从 axi_smc/M00_AXI 进入 DDR 控制器。
```