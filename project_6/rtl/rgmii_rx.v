//=============================================================================
// rgmii_rx.v — RGMII 接收: DDR->SDR (IDDRE1 + BUFIO + BUFG)
// 来源: 开发指南第 43 章 43.4.2 (p1328-1330) 完整清单转录
//=============================================================================
module rgmii_rx(
    //以太网RGMII接口
    input              rgmii_rxc   ,    //RGMII接收时钟
    input              rgmii_rx_ctl,    //RGMII接收数据控制信号
    input       [3:0]  rgmii_rxd   ,    //RGMII接收数据

    //以太网GMII接口
    output             gmii_rx_clk ,    //GMII接收时钟
    output             gmii_rx_dv  ,    //GMII接收数据有效信号
    output      [7:0]  gmii_rxd         //GMII接收数据
    );

//wire define
wire         rgmii_rxc_bufg;             //全局时钟缓存
wire         rgmii_rxc_bufio;            //全局时钟IO缓存
wire  [1:0]  gmii_rxdv_t;                //两位GMII接收有效信号

//*************************************************************************************
//**                    main code
//*************************************************************************************

assign gmii_rx_clk = rgmii_rxc_bufg;
assign gmii_rx_dv  = gmii_rxdv_t[0] & gmii_rxdv_t[1];

//全局时钟缓存
BUFG BUFG_inst (
  .I            (rgmii_rxc),      // 1-bit input: Clock input
  .O            (rgmii_rxc_bufg)  // 1-bit output: Clock output
);

//全局时钟IO缓存
BUFIO BUFIO_inst (
  .I            (rgmii_rxc),      // 1-bit input: Clock input
  .O            (rgmii_rxc_bufio) // 1-bit output: Clock output
);

//将输入的上下边沿DDR信号，转换成两位单边沿SDR信号
 IDDRE1 #(
    .DDR_CLK_EDGE     ("SAME_EDGE_PIPELINED"), // IDDRE1 mode
    .IS_CB_INVERTED   (1'b0),                  // Optional inversion for CB
    .IS_C_INVERTED    (1'b0)                   // Optional inversion for C
 )
 IDDRE1_inst (
    .Q1    (gmii_rxdv_t[0]),              // 1-bit output: Registered parallel output 1
    .Q2    (gmii_rxdv_t[1]),              // 1-bit output: Registered parallel output 2
    .C     (rgmii_rxc_bufio),             // 1-bit input: High-speed clock
    .CB    (~rgmii_rxc_bufio),            // 1-bit input: Inversion of High-speed clock C
    .D     (rgmii_rx_ctl),                // 1-bit input: Serial Data Input
    .R     (1'b0)                         // 1-bit input: Active High Async Reset
 );

genvar i;
generate for (i=0; i<4; i=i+1)
    begin : rxdata_bus
IDDRE1 #(
  .DDR_CLK_EDGE  ("SAME_EDGE_PIPELINED"), //OPPOSITE_EDGE, SAME_EDGE,SAME_EDGE_PIPELINED)
  .IS_CB_INVERTED    (1'b0),              // Optional inversion for CB
  .IS_C_INVERTED     (1'b0)               // Optional inversion for C
        )
        IDDRE1_inst (
           .Q1       (gmii_rxd[i]),       // 1-bit output: Registered parallel output 1
           .Q2       (gmii_rxd[4+i]),     // 1-bit output: Registered parallel output 2
           .C        (rgmii_rxc_bufio),   // 1-bit input: High-speed clock
           .CB       (~rgmii_rxc_bufio),  // 1-bit input: Inversion of High-speed clock C
           .D        (rgmii_rxd[i]),      // 1-bit input: Serial Data Input
           .R        (1'b0)               // 1-bit input: Active High Async Reset
        );
    end
endgenerate

endmodule
