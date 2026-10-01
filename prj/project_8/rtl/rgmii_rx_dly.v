//=============================================================================
// rgmii_rx_dly.v  --  RGMII RX + adjustable IDELAY (project_8, 2026-09-10)
//
// WHY:
//   The official rgmii_rx samples the pins with IDDRE1 clocked by BUFIO, so the
//   sampling instant is fixed by the PHY-side RGMII clock/data phase. If the PHY
//   does NOT add its internal RX delay (RXDLY strap off), the data transitions
//   coincide with the sampling edges -> the capture reads values from the wrong
//   side of the transition. Measured on board: whole bytes lose 1-bits (never
//   gain), constant patterns (0xFF/0x55) survive, so the official stack fails
//   every CRC and the board never answers.
//
//   This module inserts IDELAYE3 between IBUF and IDDRE1 so the sampling point
//   can be moved into the centre of the data eye.
//
// CHAIN : pin -> IBUF -> IDELAYE3(VAR_LOAD) -> IDDRE1(C=BUFIO, CB=~BUFIO) -> fabric
// REFCLK: init_clk(100MHz) -> MMCME4_ADV(10/1/5) -> 200MHz -> BUFG -> IDELAYCTRL
//
// CTRL  : dly_tap[8:0]  ~78 ps / LSB (TIME format, 200 MHz refclk)
//         dly_load      one-shot pulse, loads CNTVALUEIN into the delay line
//=============================================================================
module rgmii_rx_dly(
    input              init_clk      ,
    input              sys_rst_n     ,
    // ---- RGMII pins ----
    input              rgmii_rxc     ,
    input              rgmii_rx_ctl  ,
    input       [3:0]  rgmii_rxd     ,
    // ---- delay control ----
    input       [8:0]  dly_tap       ,
    input              dly_load      ,
    // ---- GMII out ----
    output             gmii_rx_clk   ,
    output             gmii_rx_dv    ,
    output      [7:0]  gmii_rxd      ,
    // ---- status ----
    output             idelay_rdy    ,
    output             refclk_locked
);

//------------------------------------------------------------------
// 200 MHz reference clock for IDELAYCTRL (from board 100 MHz init_clk)
//   VCO = 100MHz * 10 / 1 = 1000 MHz ; CLKOUT0 = 1000 / 5 = 200 MHz
//------------------------------------------------------------------
wire clk200_raw, clkfb, mmcm_locked;

MMCME3_ADV #(
    .BANDWIDTH          ("OPTIMIZED"),
    .CLKFBOUT_MULT_F    (10.0),
    .CLKFBOUT_PHASE     (0.0),
    .CLKIN1_PERIOD      (10.0),
    .DIVCLK_DIVIDE      (1),
    .CLKOUT0_DIVIDE_F   (5.0),
    .CLKOUT0_DUTY_CYCLE (0.5),
    .CLKOUT0_PHASE      (0.0),
    .REF_JITTER1        (0.010),
    .STARTUP_WAIT       ("FALSE")
) u_mmcm_200m (
    .CLKOUT0   (clk200_raw),
    .CLKOUT0B  (),
    .CLKOUT1   (), .CLKOUT1B (),
    .CLKOUT2   (), .CLKOUT2B (),
    .CLKOUT3   (), .CLKOUT3B (),
    .CLKOUT4   (),
    .CLKOUT5   (), .CLKOUT6  (),
    .CLKFBOUT  (clkfb), .CLKFBOUTB (),
    .CLKFBIN   (clkfb),
    .CLKIN1    (init_clk),
    .CLKIN2    (1'b0),
    .CLKINSEL  (1'b1),
    .LOCKED    (mmcm_locked),
    .PWRDWN    (1'b0),
    .RST       (~sys_rst_n),
    .CDDCREQ   (1'b0),
    .DADDR     (7'd0), .DCLK (1'b0), .DEN (1'b0), .DI (16'd0),
    .DO        (), .DRDY (), .DWE (1'b0),
    .PSCLK     (1'b0), .PSEN (1'b0), .PSINCDEC (1'b0), .PSDONE (),
    .CLKINSTOPPED (), .CLKFBSTOPPED ()
);

wire clk200;
BUFG u_bufg_200 (.I(clk200_raw), .O(clk200));

assign refclk_locked = mmcm_locked;

IDELAYCTRL #(
    .SIM_DEVICE ("ULTRASCALE")
) u_idelayctrl (
    .RDY    (idelay_rdy),
    .REFCLK (clk200),
    .RST    (~sys_rst_n | ~mmcm_locked)
);

//------------------------------------------------------------------
// RGMII RX : pin -> IBUF -> IDELAYE3 -> IDDRE1  (same structure as official,
//            only the IBUF/IDELAY insertion differs)
//------------------------------------------------------------------
wire        rgmii_rxc_bufg ;
wire        rgmii_rxc_bufio;
wire [1:0]  gmii_rxdv_t    ;
wire [3:0]  rxd_ibuf       ;
wire [3:0]  rxd_dly        ;
wire        ctl_ibuf       ;
wire        ctl_dly        ;

assign gmii_rx_clk = rgmii_rxc_bufg;
assign gmii_rx_dv  = gmii_rxdv_t[0] & gmii_rxdv_t[1];

BUFG  BUFG_inst  (.I(rgmii_rxc), .O(rgmii_rxc_bufg ));
BUFIO BUFIO_inst (.I(rgmii_rxc), .O(rgmii_rxc_bufio));

// ---- RX_CTL ----
IBUF u_ibuf_ctl (.I(rgmii_rx_ctl), .O(ctl_ibuf));

IDELAYE3 #(
    .CASCADE          ("NONE"),
    .DELAY_FORMAT     ("TIME"),
    .DELAY_SRC        ("IDATAIN"),
    .DELAY_TYPE       ("VAR_LOAD"),
    .DELAY_VALUE      (0),
    .IS_CLK_INVERTED  (1'b0),
    .IS_RST_INVERTED  (1'b0),
    .REFCLK_FREQUENCY (200.0),
    .SIM_DEVICE       ("ULTRASCALE"),
    .UPDATE_MODE      ("ASYNC")
) u_dly_ctl (
    .CASC_IN      (1'b0), .CASC_OUT (), .CASC_RETURN (1'b0),
    .CE           (1'b0), .CLK      (clk200),
    .CNTVALUEIN   (dly_tap), .CNTVALUEOUT (),
    .DATAIN       (1'b0), .EN_VTC   (1'b1),
    .IDATAIN      (ctl_ibuf), .INC  (1'b0),
    .LOAD         (dly_load), .RST  (1'b0),
    .DATAOUT      (ctl_dly)
);

IDDRE1 #(
    .DDR_CLK_EDGE   ("SAME_EDGE_PIPELINED"),
    .IS_CB_INVERTED (1'b0),
    .IS_C_INVERTED  (1'b0)
) u_iddr_ctl (
    .Q1 (gmii_rxdv_t[0]),
    .Q2 (gmii_rxdv_t[1]),
    .C  (rgmii_rxc_bufio),
    .CB (~rgmii_rxc_bufio),
    .D  (ctl_dly),
    .R  (1'b0)
);

// ---- RX data lanes ----
genvar i;
generate for (i=0; i<4; i=i+1)
    begin : rxdata_bus
        IBUF u_ibuf (.I(rgmii_rxd[i]), .O(rxd_ibuf[i]));

        IDELAYE3 #(
            .CASCADE          ("NONE"),
            .DELAY_FORMAT     ("TIME"),
            .DELAY_SRC        ("IDATAIN"),
            .DELAY_TYPE       ("VAR_LOAD"),
            .DELAY_VALUE      (0),
            .IS_CLK_INVERTED  (1'b0),
            .IS_RST_INVERTED  (1'b0),
            .REFCLK_FREQUENCY (200.0),
            .SIM_DEVICE       ("ULTRASCALE"),
            .UPDATE_MODE      ("ASYNC")
        ) u_dly (
            .CASC_IN      (1'b0), .CASC_OUT (), .CASC_RETURN (1'b0),
            .CE           (1'b0), .CLK      (clk200),
            .CNTVALUEIN   (dly_tap), .CNTVALUEOUT (),
            .DATAIN       (1'b0), .EN_VTC   (1'b1),
            .IDATAIN      (rxd_ibuf[i]), .INC (1'b0),
            .LOAD         (dly_load), .RST  (1'b0),
            .DATAOUT      (rxd_dly[i])
        );

        IDDRE1 #(
            .DDR_CLK_EDGE   ("SAME_EDGE_PIPELINED"),
            .IS_CB_INVERTED (1'b0),
            .IS_C_INVERTED  (1'b0)
        ) u_iddr (
            .Q1 (gmii_rxd[i]),
            .Q2 (gmii_rxd[4+i]),
            .C  (rgmii_rxc_bufio),
            .CB (~rgmii_rxc_bufio),
            .D  (rxd_dly[i]),
            .R  (1'b0)
        );
    end
endgenerate

endmodule
