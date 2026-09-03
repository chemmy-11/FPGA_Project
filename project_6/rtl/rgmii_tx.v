//=============================================================================
// rgmii_tx.v — RGMII 发送: SDR->DDR (ODDRE1)
// 来源: 开发指南第 43 章 43.4.2 (p1331-1332) 完整清单转录
//=============================================================================
module rgmii_tx(
    //GMII发送端口
    input              gmii_tx_clk , //GMII发送时钟
    input              gmii_tx_en  , //GMII输出数据有效信号
    input       [7:0]  gmii_txd    , //GMII输出数据

    //RGMII发送端口
    output             rgmii_txc   , //RGMII发送数据时钟
    output             rgmii_tx_ctl, //RGMII输出数据有效信号
    output      [3:0]  rgmii_txd     //RGMII输出数据
    );

//*************************************************************************************
//**                    main code
//*************************************************************************************

assign rgmii_txc = gmii_tx_clk;

//输出双沿采样寄存器 (rgmii_tx_ctl)
ODDRE1 #(
      .IS_C_INVERTED     (1'b0),            // Optional inversion for C
      .IS_D1_INVERTED    (1'b0),            // Unsupported, do not use
      .IS_D2_INVERTED    (1'b0),            // Unsupported, do not use
      .SIM_DEVICE("ULTRASCALE"),            // Set the device version
      .SRVAL(1'b0)                          // the specified value (1'b0, 1'b1)
   )
   ODDRE1_tx_ctl (
      .Q     (rgmii_tx_ctl),    // 1-bit output: Data output to IOB
      .C     (gmii_tx_clk),     // 1-bit input: High-speed clock input
      .D1    (gmii_tx_en),      // 1-bit input: Parallel data input 1
      .D2    (gmii_tx_en),      // 1-bit input: Parallel data input 2
      .SR    (1'b0)             // 1-bit input: Active High Async Reset
   );

genvar i;
generate for (i=0; i<4; i=i+1)
    begin : txdata_bus
      ODDRE1 #(
      .IS_C_INVERTED(1'b0),        // Optional inversion for C
      .IS_D1_INVERTED(1'b0),       // Unsupported, do not use
      .IS_D2_INVERTED(1'b0),       // Unsupported, do not use
      .SIM_DEVICE("ULTRASCALE"),   // Set the device version
      .SRVAL(1'b0)                 // the specified value (1'b0, 1'b1)
   )
   ODDRE1_inst (
      .Q     (rgmii_txd[i]),      // 1-bit output: Data output to IOB
      .C     (gmii_tx_clk),       // 1-bit input: High-speed clock input
      .D1    (gmii_txd[i]),       // 1-bit input: Parallel data input 1
      .D2    (gmii_txd[4+i]),     // 1-bit input: Parallel data input 2
      .SR    (1'b0)               // 1-bit input: Active High Async Reset
   );
    end
endgenerate

endmodule
