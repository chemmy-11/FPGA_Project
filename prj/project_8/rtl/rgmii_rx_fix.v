//=============================================================================
// rgmii_rx_fix.v -- RGMII RX with BUFIO clock restoration (project_8, 2026-09-17)
//
// 根因（判别实验 + ILA + 双网表解剖，2026-09-17）：
//   官方 RTL 的 .CB(~rgmii_rxc_bufio) 经过 LUT 反相器，使 2023.1 映射时把 BUFIO
//   吸收掉，IDDRE1 的 C 实际挂上 BUFGCE 全局时钟（插入 ~2ns，比 BUFIO 慢 ~1.7ns）。
//   采样时刻 τ = PHY 中心延迟(2ns) + FPGA 时钟插入(Δ)：官方构建 Δ≈1.7ns 压线工作；
//   prj8（含 ILA，时钟树形态不同）Δ≈2ns，采样正好压在数据位跳变上 →
//   ILA 实测"只丢 1 不加 1"的位子集损伤，arp_rx_done 恒 0。
//
// 修复：去掉 CB 的 LUT 反相器，反相改由 IS_CB_INVERTED(1'b1) 参数承载，
//       使 BUFIO→IDDRE1 的低延迟时钟路径得以保留（τ≈2.3ns，眼图中心）。
//
// 接口与官方 rgmii_rx 完全一致（gmii_to_rgmii 无需改动）。
//=============================================================================
module rgmii_rx(
    input              rgmii_rxc   ,
    input              rgmii_rx_ctl,
    input       [3:0]  rgmii_rxd   ,

    output             gmii_rx_clk ,
    output             gmii_rx_dv  ,
    output      [7:0]  gmii_rxd
);

wire         rgmii_rxc_bufg ;
wire         rgmii_rxc_bufio;
wire  [1:0]  gmii_rxdv_t    ;

assign gmii_rx_clk = rgmii_rxc_bufg;
assign gmii_rx_dv  = gmii_rxdv_t[0] & gmii_rxdv_t[1];

BUFG  BUFG_inst  (.I(rgmii_rxc), .O(rgmii_rxc_bufg ));
BUFIO BUFIO_inst (.I(rgmii_rxc), .O(rgmii_rxc_bufio));

IDDRE1 #(
    .DDR_CLK_EDGE     ("SAME_EDGE_PIPELINED"),
    .IS_CB_INVERTED   (1'b1),
    .IS_C_INVERTED    (1'b0)
)
IDDRE1_inst (
    .Q1    (gmii_rxdv_t[0]),
    .Q2    (gmii_rxdv_t[1]),
    .C     (rgmii_rxc_bufio),
    .CB    (rgmii_rxc_bufio),
    .D     (rgmii_rx_ctl),
    .R     (1'b0)
);

genvar i;
generate
    for (i = 0; i < 4; i = i + 1) begin : rxdata_bus
        IDDRE1 #(
            .DDR_CLK_EDGE      ("SAME_EDGE_PIPELINED"),
            .IS_CB_INVERTED    (1'b1),
            .IS_C_INVERTED     (1'b0)
        )
        IDDRE1_inst (
            .Q1                (gmii_rxd[i]),
            .Q2                (gmii_rxd[4+i]),
            .C                 (rgmii_rxc_bufio),
            .CB                (rgmii_rxc_bufio),
            .D                 (rgmii_rxd[i]),
            .R                 (1'b0)
        );
    end
endgenerate

endmodule
