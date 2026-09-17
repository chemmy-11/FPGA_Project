//=============================================================================
// rgmii_rx_fix2.v -- PLAN B: BUFIO 恢复 + FIXED IDELAY(带 IDELAYCTRL)
// 备用：仅当纯 BUFIO 版(rgmii_rx_fix.v)在网表里仍被吸收时启用。
//   IDELAYCTRL 所需 200MHz 由 eth_rxc(125MHz) 本地 MMCM 倍频(×8/5)产生，
//   模块接口与官方 rgmii_rx 完全一致，无需上层改动。
//=============================================================================
module rgmii_rx(
    input              rgmii_rxc   ,
    input              rgmii_rx_ctl,
    input       [3:0]  rgmii_rxd   ,

    output             gmii_rx_clk ,
    output             gmii_rx_dv  ,
    output      [7:0]  gmii_rxd
);

parameter RX_DLY_PS = 500;          // 数据固定延迟(ps)

wire         rgmii_rxc_bufg ;
wire         rgmii_rxc_bufio;
wire  [1:0]  gmii_rxdv_t    ;
wire  [3:0]  rxd_dly        ;
wire         ctl_dly        ;

assign gmii_rx_clk = rgmii_rxc_bufg;
assign gmii_rx_dv  = gmii_rxdv_t[0] & gmii_rxdv_t[1];

BUFG  BUFG_inst  (.I(rgmii_rxc), .O(rgmii_rxc_bufg ));
BUFIO BUFIO_inst (.I(rgmii_rxc), .O(rgmii_rxc_bufio));

//------------------------------------------------------------------
// 200MHz 参考时钟（IDELAYCTRL 用）：eth_rxc 125MHz ×8 /5 = 200MHz
//   VCO = 1000MHz；链路建立后 eth_rxc 才有，MMCM 自行锁定
//------------------------------------------------------------------
wire clk200_raw, clkfb, mmcm_locked, clk200;

MMCME3_ADV #(
    .BANDWIDTH          ("OPTIMIZED"),
    .CLKFBOUT_MULT_F    (8.0),
    .CLKFBOUT_PHASE     (0.0),
    .CLKIN1_PERIOD      (8.0),
    .DIVCLK_DIVIDE      (1),
    .CLKOUT0_DIVIDE_F   (5.0),
    .CLKOUT0_DUTY_CYCLE (0.5),
    .CLKOUT0_PHASE      (0.0),
    .REF_JITTER1        (0.010),
    .STARTUP_WAIT       ("FALSE")
) u_mmcm_200m (
    .CLKOUT0   (clk200_raw), .CLKOUT0B (),
    .CLKOUT1 (), .CLKOUT1B (), .CLKOUT2 (), .CLKOUT2B (),
    .CLKOUT3 (), .CLKOUT3B (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6  (),
    .CLKFBOUT  (clkfb), .CLKFBOUTB (),
    .CLKFBIN   (clkfb),
    .CLKIN1    (rgmii_rxc_bufg), .CLKIN2 (1'b0), .CLKINSEL (1'b1),
    .LOCKED    (mmcm_locked), .PWRDWN (1'b0), .RST (1'b0),
    .CDDCREQ   (1'b0),
    .DADDR (7'd0), .DCLK (1'b0), .DEN (1'b0), .DI (16'd0),
    .DO (), .DRDY (), .DWE (1'b0),
    .PSCLK (1'b0), .PSEN (1'b0), .PSINCDEC (1'b0), .PSDONE (),
    .CLKINSTOPPED (), .CLKFBSTOPPED ()
);

BUFG u_bufg_200 (.I(clk200_raw), .O(clk200));

// REQ P-1816/1817: RST 不得接地、不得直连 LOCKED —— 用 clk200 打拍的同步链产生
reg [3:0] lock_sr = 4'h0;
always @(posedge clk200) lock_sr <= {lock_sr[2:0], mmcm_locked};
wire idelayctrl_rst = ~lock_sr[3];

IDELAYCTRL #(.SIM_DEVICE("ULTRASCALE")) u_idelayctrl (
    .RDY    (),
    .REFCLK (clk200),
    .RST    (idelayctrl_rst)
);

// ---- FIXED IDELAY ×5 ----
genvar k;
generate
    for (k = 0; k < 4; k = k + 1) begin : g_rxd_dly
        IDELAYE3 #(
            .CASCADE          ("NONE"),
            .DELAY_FORMAT     ("TIME"),
            .DELAY_SRC        ("IDATAIN"),
            .DELAY_TYPE       ("FIXED"),
            .DELAY_VALUE      (RX_DLY_PS),
            .IS_CLK_INVERTED  (1'b0),
            .IS_RST_INVERTED  (1'b0),
            .REFCLK_FREQUENCY (200.0),
            .SIM_DEVICE       ("ULTRASCALE"),
            .UPDATE_MODE      ("ASYNC")
        ) u_dly_rxd (
            .CASC_IN (1'b0), .CASC_OUT (), .CASC_RETURN (1'b0),
            .CE (1'b0), .CLK (1'b0),
            .CNTVALUEIN (5'd0), .CNTVALUEOUT (),
            .DATAIN (1'b0), .EN_VTC (1'b1),
            .IDATAIN (rgmii_rxd[k]),
            .INC (1'b0), .LOAD (1'b0), .RST (1'b0),
            .DATAOUT (rxd_dly[k])
        );
    end
endgenerate

IDELAYE3 #(
    .CASCADE          ("NONE"),
    .DELAY_FORMAT     ("TIME"),
    .DELAY_SRC        ("IDATAIN"),
    .DELAY_TYPE       ("FIXED"),
    .DELAY_VALUE      (RX_DLY_PS),
    .IS_CLK_INVERTED  (1'b0),
    .IS_RST_INVERTED  (1'b0),
    .REFCLK_FREQUENCY (200.0),
    .SIM_DEVICE       ("ULTRASCALE"),
    .UPDATE_MODE      ("ASYNC")
) u_dly_ctl (
    .CASC_IN (1'b0), .CASC_OUT (), .CASC_RETURN (1'b0),
    .CE (1'b0), .CLK (1'b0),
    .CNTVALUEIN (5'd0), .CNTVALUEOUT (),
    .DATAIN (1'b0), .EN_VTC (1'b1),
    .IDATAIN (rgmii_rx_ctl),
    .INC (1'b0), .LOAD (1'b0), .RST (1'b0),
    .DATAOUT (ctl_dly)
);

// ---- DDR 采样：BUFIO + IS_CB_INVERTED ----
IDDRE1 #(
    .DDR_CLK_EDGE     ("SAME_EDGE_PIPELINED"),
    .IS_CB_INVERTED   (1'b1),
    .IS_C_INVERTED    (1'b0)
)
IDDRE1_inst (
    .Q1 (gmii_rxdv_t[0]), .Q2 (gmii_rxdv_t[1]),
    .C  (rgmii_rxc_bufio), .CB (rgmii_rxc_bufio),
    .D  (ctl_dly), .R (1'b0)
);

generate
    for (k = 0; k < 4; k = k + 1) begin : rxdata_bus
        IDDRE1 #(
            .DDR_CLK_EDGE      ("SAME_EDGE_PIPELINED"),
            .IS_CB_INVERTED    (1'b1),
            .IS_C_INVERTED     (1'b0)
        )
        IDDRE1_inst (
            .Q1 (gmii_rxd[k]), .Q2 (gmii_rxd[4+k]),
            .C  (rgmii_rxc_bufio), .CB (rgmii_rxc_bufio),
            .D  (rxd_dly[k]), .R (1'b0)
        );
    end
endgenerate

endmodule
