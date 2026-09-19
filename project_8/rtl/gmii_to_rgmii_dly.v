//=============================================================================
// gmii_to_rgmii_dly.v  --  drop-in replacement of the official gmii_to_rgmii
//                          with an adjustable RX delay (project_8, 2026-09-10)
//   RX : our rgmii_rx_dly  (IBUF -> IDELAYE3 -> IDDRE1)
//   TX : official rgmii_tx  (untouched)
//=============================================================================
module gmii_to_rgmii_dly(
    input              init_clk     ,
    input              sys_rst_n    ,
    input       [8:0]  dly_tap      ,
    input              dly_load     ,

    output             gmii_rx_clk  ,
    output             gmii_rx_dv   ,
    output      [7:0]  gmii_rxd     ,
    output             gmii_tx_clk  ,
    input              gmii_tx_en   ,
    input       [7:0]  gmii_txd     ,

    input              rgmii_rxc    ,
    input              rgmii_rx_ctl ,
    input       [3:0]  rgmii_rxd    ,
    output             rgmii_txc    ,
    output             rgmii_tx_ctl ,
    output      [3:0]  rgmii_txd    ,

    output             idelay_rdy   ,
    output             refclk_locked
);

assign gmii_tx_clk = gmii_rx_clk;

rgmii_rx_dly u_rgmii_rx_dly (
    .init_clk           (init_clk),
    .sys_rst_n          (sys_rst_n),
    .rgmii_rxc          (rgmii_rxc),
    .rgmii_rx_ctl       (rgmii_rx_ctl),
    .rgmii_rxd          (rgmii_rxd),
    .dly_tap            (dly_tap),
    .dly_load           (dly_load),
    .gmii_rx_clk        (gmii_rx_clk),
    .gmii_rx_dv         (gmii_rx_dv),
    .gmii_rxd           (gmii_rxd),
    .idelay_rdy         (idelay_rdy),
    .refclk_locked      (refclk_locked)
);

rgmii_tx u_rgmii_tx (
    .gmii_tx_clk        (gmii_tx_clk),
    .gmii_tx_en         (gmii_tx_en),
    .gmii_txd           (gmii_txd),
    .rgmii_txc          (rgmii_txc),
    .rgmii_tx_ctl       (rgmii_tx_ctl),
    .rgmii_txd          (rgmii_txd)
);

endmodule
