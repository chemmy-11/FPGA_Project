//=============================================================================
// gmii_to_rgmii.v — GMII<->RGMII 转换包装层
// 书中 43.4.2 未给包装层清单，按 eth_arp_test/eth_udp_loop 顶层例化接口 + rgmii_rx/rgmii_tx
// 端口组装（单时钟域：gmii_tx_clk = gmii_rx_clk = eth_rxc 经 BUFG）
//=============================================================================
module gmii_to_rgmii(
    //GMII 接口
    output             gmii_rx_clk,    //GMII接收时钟（RXC 经 BUFG）
    output             gmii_rx_dv ,    //GMII接收数据有效信号
    output      [7:0]  gmii_rxd   ,    //GMII接收数据
    input              gmii_tx_clk,    //GMII发送时钟（与接收同域）
    input              gmii_tx_en ,    //GMII发送数据有效信号
    input      [7:0]   gmii_txd   ,    //GMII发送数据

    //RGMII 接口
    input              rgmii_rxc   ,   //RGMII接收时钟
    input              rgmii_rx_ctl,   //RGMII接收数据有效信号
    input      [3:0]   rgmii_rxd   ,   //RGMII接收数据
    output             rgmii_txc   ,   //RGMII发送时钟
    output             rgmii_tx_ctl,   //RGMII发送数据有效信号
    output     [3:0]   rgmii_txd       //RGMII发送数据
    );

rgmii_rx u_rgmii_rx(
    .rgmii_rxc        (rgmii_rxc   ),
    .rgmii_rx_ctl     (rgmii_rx_ctl),
    .rgmii_rxd        (rgmii_rxd   ),

    .gmii_rx_clk      (gmii_rx_clk ),
    .gmii_rx_dv       (gmii_rx_dv  ),
    .gmii_rxd         (gmii_rxd    )
);

rgmii_tx u_rgmii_tx(
    .gmii_tx_clk      (gmii_tx_clk ),
    .gmii_tx_en       (gmii_tx_en  ),
    .gmii_txd         (gmii_txd    ),

    .rgmii_txc        (rgmii_txc   ),
    .rgmii_tx_ctl     (rgmii_tx_ctl),
    .rgmii_txd        (rgmii_txd   )
);

endmodule
