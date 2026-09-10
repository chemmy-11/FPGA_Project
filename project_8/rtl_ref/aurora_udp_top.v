//=============================================================================
// aurora_udp_top.v — Aurora-UDP 数据级桥顶层
// 数据流（数据级 64b/66b 验证）:
//   PC --RJ45(GE1,RGMII)--> [官方以太网栈] --udp echo--> RGMII --> PC  (常规回显)
//   栈 udp_rx 解析出的载荷 P (eth_rxc 域) --async FIFO--> aurora_clk 域
//   -> Aurora 64b/66b TX -> 内环 -> Aurora RX -> 解析回 P -> 状态计数器 + ILA
// 判据: ILA 中 rx2_done 上升 + payload 字节与 PC 发送一致 = 数据穿过 64b/66b 编解码
//=============================================================================
module aurora_udp_top(
    // ---- RGMII GE1 (PC front-end, official 39 port set) ----
    input              sys_rst_n ,
    input              key       ,
    input              eth_rxc   ,
    input              eth_rx_ctl,
    input       [3:0]  eth_rxd   ,
    output             eth_txc   ,
    output             eth_tx_ctl,
    output      [3:0]  eth_txd   ,
    output             eth_rst_n ,
    // ---- Aurora 64b/66b (GT X1Y8 = SFPD) ----
    input              sys_clk_p ,
    input              sys_clk_n ,
    input              gtrefclk_p,
    input              gtrefclk_n,
    input              sfp_rx_p  ,
    input              sfp_rx_n  ,
    output             sfp_tx_p  ,
    output             sfp_tx_n  ,
    output             sfp_rs0   ,
    output             sfp_rs1   ,
    output             sfp_tx_disable,
    // ---- observation LEDs ----
    output             led_loop  ,  // T22: Aurora RX payload byte count > 0 (sticky)
    output             led_link     // T23: status_vector[0] (tentative link bit)
);

//parameter define (official ch45 values)
parameter  BOARD_MAC = 48'h00_11_22_33_44_55;
parameter  BOARD_IP  = {8'd192,8'd168,8'd1,8'd10};
parameter  DES_MAC   = 48'hff_ff_ff_ff_ff_ff;
parameter  DES_IP    = {8'd192,8'd168,8'd1,8'd102};

//wires: official 39 stack (unchanged)
wire          gmii_rx_clk, gmii_rx_dv, gmii_tx_clk, gmii_tx_en;
wire [7:0]    gmii_rxd, gmii_txd;
wire          arp_gmii_tx_en; wire [7:0] arp_gmii_txd;
wire          arp_rx_done, arp_rx_type;
wire [47:0]   src_mac; wire [31:0] src_ip;
wire          arp_tx_en, arp_tx_type;
wire [47:0]   des_mac; wire [31:0] des_ip;
wire          arp_tx_done;
wire          icmp_gmii_tx_en; wire [7:0] icmp_gmii_txd;
wire          icmp_rec_pkt_done, icmp_rec_en;
wire [7:0]    icmp_rec_data;
wire [15:0]   icmp_rec_byte_num, icmp_tx_byte_num;
wire          icmp_tx_done, icmp_tx_req;
wire [7:0]    icmp_tx_data;
wire          icmp_tx_start_en;
wire          udp_gmii_tx_en; wire [7:0] udp_gmii_txd;
wire          rec_pkt_done, udp_rec_en;
wire [7:0]    udp_rec_data;
wire [15:0]   rec_byte_num, tx_byte_num;
wire          udp_tx_done, udp_tx_req;
wire [7:0]    udp_tx_data;
wire          tx_start_en;
wire [7:0]    rec_data, tx_data;
wire          rec_en, tx_req;
wire          clk_200m, locked_200m;

assign icmp_tx_start_en = icmp_rec_pkt_done;
assign icmp_tx_byte_num = icmp_rec_byte_num;
assign tx_start_en = rec_pkt_done;
assign tx_byte_num = rec_byte_num;
assign des_mac = src_mac;
assign des_ip = src_ip;
assign eth_rst_n = sys_rst_n;

// ---- SFP front-end static config (official 53 values, loopback ON) ----
assign sfp_rs0 = 1'b1;
assign sfp_rs1 = 1'b1;
assign sfp_tx_disable = 1'b0;
assign signal_detect = 1'b1;
assign an_adv_config_vector = 16'h0021;
assign an_restart_config = 1'b0;
assign configuration_vector[0] = 1'b1;  // inner loopback ON
assign configuration_vector[1] = 1'b0;
assign configuration_vector[2] = 1'b0;
assign configuration_vector[4:3] = 2'b10;

//wires: Aurora domain
wire          clk_50m;
wire          userclk2;               // 125M from Aurora GT
wire          mmcm_locked_out;
wire  [15:0]  status_vector1;
wire  [4:0]   configuration_vector;
wire  [15:0]  an_adv_config_vector;
wire          an_restart_config;
wire          signal_detect;
wire  [7:0]   aur_gmii_txd;           // Aurora TX GMII input (from pump)
wire          aur_gmii_tx_en;
wire  [7:0]   aur_gmii_rxd;           // Aurora RX GMII output (loop-back data)
wire          aur_gmii_rx_dv;
wire  [63:0]  s_axi_tx_tdata;
wire  [7:0]   s_axi_tx_tkeep;
wire          s_axi_tx_tvalid, s_axi_tx_tlast, s_axi_tx_tready;
wire  [63:0]  m_axi_rx_tdata;
wire  [7:0]   m_axi_rx_tkeep;
wire          m_axi_rx_tvalid, m_axi_rx_tlast;
wire          user_clk_out;           // ~151.5MHz Aurora user clock

//Aurora loopback payload byte counter (user_clk domain)
reg [15:0] aur_rx_byte_cnt;
always @(posedge user_clk_out or negedge sys_rst_n) begin
    if(!sys_rst_n) aur_rx_byte_cnt <= 16'd0;
    else if(aur_gmii_rx_dv) aur_rx_byte_cnt <= aur_rx_byte_cnt + 16'd1;
end

//LED0 (T22): sticky — any Aurora RX data seen
reg led_loop_r;
always @(posedge user_clk_out or negedge sys_rst_n) begin
    if(!sys_rst_n) led_loop_r <= 1'b0;
    else if(aur_gmii_rx_dv) led_loop_r <= 1'b1;
end
assign led_loop = led_loop_r;
assign led_link = status_vector1[0];

// ---- ILA probes ----
(* mark_debug = "true" *) wire [7:0]   dbg_aur_txd   = aur_gmii_txd;
(* mark_debug = "true" *) wire         dbg_aur_txen  = aur_gmii_tx_en;
(* mark_debug = "true" *) wire [7:0]   dbg_aur_rxd   = aur_gmii_rxd;
(* mark_debug = "true" *) wire         dbg_aur_rxdv  = aur_gmii_rx_dv;
(* mark_debug = "true" *) wire [15:0]  dbg_status    = status_vector1;
(* mark_debug = "true" *) wire         dbg_mmcm      = mmcm_locked_out;
(* mark_debug = "true" *) wire [15:0]  dbg_rx_cnt    = aur_rx_byte_cnt;
(* mark_debug = "true" *) wire         dbg_ch_up     = channel_up_i;
(* mark_debug = "true" *) wire         dbg_lane_up   = lane_up_i;

//*******************************************************************
// clk_wiz: 100M diff -> 50M (PCS independent_clock_bufg / DRP)
//*******************************************************************
clk_wiz_0 u_clk_wiz_sfp(
    .clk_out1           (clk_50m),
    .reset              (~sys_rst_n),
    .locked             (),
    .clk_in1_p          (sys_clk_p),
    .clk_in1_n          (sys_clk_n)
);

//*******************************************************************
// GMII <-> RGMII (official gmii_to_rgmii)
//*******************************************************************
gmii_to_rgmii u_gmii_to_rgmii(
    .gmii_rx_clk        (gmii_rx_clk ),
    .gmii_rx_dv         (gmii_rx_dv  ),
    .gmii_rxd           (gmii_rxd    ),
    .gmii_tx_clk        (gmii_tx_clk ),
    .gmii_tx_en         (gmii_tx_en  ),
    .gmii_txd           (gmii_txd    ),
    .rgmii_rxc          (eth_rxc     ),
    .rgmii_rx_ctl       (eth_rx_ctl  ),
    .rgmii_rxd          (eth_rxd     ),
    .rgmii_txc          (eth_txc     ),
    .rgmii_tx_ctl       (eth_tx_ctl  ),
    .rgmii_txd          (eth_txd     )
);

//*******************************************************************
// ARP
//*******************************************************************
arp
   #(
    .BOARD_MAC          (BOARD_MAC),
    .BOARD_IP           (BOARD_IP ),
    .DES_MAC            (DES_MAC  ),
    .DES_IP             (DES_IP   )
    )
   u_arp(
    .rst_n              (sys_rst_n     ),
    .gmii_rx_clk        (gmii_rx_clk   ),
    .gmii_rx_dv         (gmii_rx_dv    ),
    .gmii_rxd           (gmii_rxd      ),
    .gmii_tx_clk        (gmii_tx_clk   ),
    .gmii_tx_en         (arp_gmii_tx_en),
    .gmii_txd           (arp_gmii_txd  ),
    .arp_rx_done        (arp_rx_done   ),
    .arp_rx_type        (arp_rx_type   ),
    .src_mac            (src_mac       ),
    .src_ip             (src_ip        ),
    .arp_tx_en          (arp_tx_en     ),
    .arp_tx_type        (arp_tx_type   ),
    .des_mac            (des_mac       ),
    .des_ip             (des_ip        ),
    .tx_done            (arp_tx_done   )
);

//*******************************************************************
// ICMP
//*******************************************************************
icmp
   #(
    .BOARD_MAC          (BOARD_MAC),
    .BOARD_IP           (BOARD_IP ),
    .DES_MAC            (DES_MAC  ),
    .DES_IP             (DES_IP   )
    )
   u_icmp(
    .rst_n              (sys_rst_n       ),
    .gmii_rx_clk        (gmii_rx_clk     ),
    .gmii_rx_dv         (gmii_rx_dv      ),
    .gmii_rxd           (gmii_rxd        ),
    .gmii_tx_clk        (gmii_tx_clk     ),
    .gmii_tx_en         (icmp_gmii_tx_en ),
    .gmii_txd           (icmp_gmii_txd   ),
    .rec_pkt_done       (icmp_rec_pkt_done),
    .rec_en             (icmp_rec_en      ),
    .rec_data           (icmp_rec_data    ),
    .rec_byte_num       (icmp_rec_byte_num),
    .tx_start_en        (icmp_tx_start_en ),
    .tx_data            (icmp_tx_data     ),
    .tx_byte_num        (icmp_tx_byte_num ),
    .des_mac            (des_mac         ),
    .des_ip             (des_ip          ),
    .tx_done            (icmp_tx_done    ),
    .tx_req             (icmp_tx_req     )
);

//*******************************************************************
// UDP
//*******************************************************************
udp
   #(
    .BOARD_MAC          (BOARD_MAC),
    .BOARD_IP           (BOARD_IP ),
    .DES_MAC            (DES_MAC  ),
    .DES_IP             (DES_IP   )
    )
   u_udp(
    .rst_n              (sys_rst_n   ),
    .gmii_rx_clk        (gmii_rx_clk ),
    .gmii_rx_dv         (gmii_rx_dv  ),
    .gmii_rxd           (gmii_rxd    ),
    .gmii_tx_clk        (gmii_tx_clk ),
    .gmii_tx_en         (udp_gmii_tx_en),
    .gmii_txd           (udp_gmii_txd),
    .rec_pkt_done       (rec_pkt_done),
    .rec_en             (udp_rec_en  ),
    .rec_data           (udp_rec_data),
    .rec_byte_num       (rec_byte_num),
    .tx_start_en        (tx_start_en ),
    .tx_data            (udp_tx_data ),
    .tx_byte_num        (tx_byte_num ),
    .des_mac            (des_mac     ),
    .des_ip             (des_ip      ),
    .tx_done            (udp_tx_done ),
    .tx_req             (udp_tx_req  )
);

//*******************************************************************
// async FIFO (echo buffer)
//*******************************************************************
async_fifo_2048x8b u_async_fifo_2048x8b (
    .rst                (~sys_rst_n ),
    .wr_clk             (gmii_rx_clk),
    .rd_clk             (gmii_rx_clk),
    .din                (rec_data   ),
    .wr_en              (rec_en     ),
    .rd_en              (tx_req     ),
    .dout               (tx_data    ),
    .full               (),
    .empty              ()
);

//*******************************************************************
// eth_ctrl (ARP/ICMP/UDP switch + key->ARP request)
//*******************************************************************
eth_ctrl u_eth_ctrl(
    .clk                (gmii_rx_clk     ),
    .rst_n              (sys_rst_n       ),
    .arp_rx_done        (arp_rx_done     ),
    .arp_rx_type        (arp_rx_type     ),
    .arp_tx_en          (arp_tx_en       ),
    .arp_tx_type        (arp_tx_type     ),
    .arp_tx_done        (arp_tx_done     ),
    .arp_gmii_tx_en     (arp_gmii_tx_en  ),
    .arp_gmii_txd       (arp_gmii_txd    ),
    .icmp_tx_start_en   (icmp_tx_start_en),
    .icmp_tx_done       (icmp_tx_done    ),
    .icmp_gmii_tx_en    (icmp_gmii_tx_en ),
    .icmp_gmii_txd      (icmp_gmii_txd   ),
    .icmp_rec_en        (icmp_rec_en     ),
    .icmp_rec_data      (icmp_rec_data   ),
    .icmp_tx_req        (icmp_tx_req     ),
    .icmp_tx_data       (icmp_tx_data    ),
    .udp_tx_start_en    (tx_start_en     ),
    .udp_tx_done        (udp_tx_done     ),
    .udp_gmii_tx_en     (udp_gmii_tx_en  ),
    .udp_gmii_txd       (udp_gmii_txd    ),
    .udp_rec_data       (udp_rec_data    ),
    .udp_rec_en         (udp_rec_en      ),
    .udp_tx_req         (udp_tx_req      ),
    .udp_tx_data        (udp_tx_data     ),
    .rec_data           (rec_data        ),
    .rec_en             (rec_en          ),
    .tx_req             (tx_req          ),
    .tx_data            (tx_data         ),
    .gmii_tx_en         (gmii_tx_en      ),
    .gmii_txd           (gmii_txd        )
);

endmodule
