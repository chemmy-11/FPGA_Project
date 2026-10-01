//=============================================================================
// sfp_udp_inner_loop.v — UDP stack + SFP optical front-end INNER-LOOP check
//
// Architecture (project_7, 2026-09-03):
//   PC --RJ45(GE1,RGMII)--> [official eth_udp_loop stack, ch45/39_eth_udp_loop]
//        --udp echo--> RGMII --> PC                    (PC-side L2 verify,
//                                                       identical to project_6)
//   TAP: stack gmii_rxd/rx_dv (PC original frame, eth_rxc domain)
//        -> frame_fifo_pump (CDC eth_rxc -> userclk2, frame-gated)
//        -> gig_ethernet_pcs_pma_0 TX (1000BASE-X, GT X1Y8 = SFPD)
//        -> INTERNAL LOOPBACK (configuration_vector[0]=1, the ONLY config
//           change vs official ch59/53)
//        -> PCS RX -> gmii -> udp_rx (2nd instance, official, parse-only)
//        -> rec_pkt_done -> led_loop (T22, sticky) + ILA probes
// Self-terminating: the looped-back frame is the UDP ECHO (dst = PC MAC),
//   which udp_rx2 would reject anyway; and udp_rx2 does not echo. No loop.
// Official sources: D:\BaiduNetdiskDownload\1_Verilog\KU060\39_eth_udp_loop
//                   and ...\53_sfp_eth_udp_loop (PCS/PMA + clk_wiz IP).
// Deviation log: configuration_vector[0]=1 (inner loopback) vs official 2'h0.
//=============================================================================
module sfp_udp_inner_loop(
    // ---- RGMII GE1 (PC front-end), official 39 port set ----
    input              sys_rst_n , // system reset, active low
    input              key       , // push button (ARP request trigger, via eth_ctrl)
    input              eth_rxc   , // RGMII RX clock
    input              eth_rx_ctl, // RGMII RX data valid
    input       [3:0]  eth_rxd   , // RGMII RX data
    output             eth_txc   , // RGMII TX clock
    output             eth_tx_ctl, // RGMII TX data valid
    output      [3:0]  eth_txd   , // RGMII TX data
    output             eth_rst_n , // PHY reset, active low
    // ---- SFP optical front-end (X1Y8 = SFPD), official 53 port set ----
    input              sys_clk_p , // 100MHz diff -> clk_wiz 50M (PCS DRP clock)
    input              sys_clk_n ,
    input              gtrefclk_p, // 156.25MHz MGTREFCLK (T6/T5)
    input              gtrefclk_n,
    input              sfp_rx_p  , // SFPD RX
    input              sfp_rx_n  ,
    output             sfp_tx_p  , // SFPD TX
    output             sfp_tx_n  ,
    output             sfp_rs0   , // rate select (official drives 1)
    output             sfp_rs1   ,
    output             sfp_tx_disable, // laser enable (0 = on)
    // ---- observation LEDs ----
    output             led_loop  , // T22: sticky, a frame parsed after inner loop
    output             led_link    // T23: status_vector[0] (tentative link bit)
);

//parameter define (official ch45/59 values)
parameter  BOARD_MAC = 48'h00_11_22_33_44_55;
parameter  BOARD_IP  = {8'd192,8'd168,8'd1,8'd10};
parameter  DES_MAC   = 48'hff_ff_ff_ff_ff_ff;
parameter  DES_IP    = {8'd192,8'd168,8'd1,8'd102};

//*******************************************************************
// wires: official 39 stack (unchanged)
//*******************************************************************
wire          gmii_rx_clk         ;
wire          gmii_rx_dv          ;
wire  [7:0]   gmii_rxd            ;
wire          gmii_tx_clk         ;
wire          gmii_tx_en          ;
wire  [7:0]   gmii_txd            ;

wire          arp_gmii_tx_en      ;
wire  [7:0]   arp_gmii_txd        ;
wire          arp_rx_done         ;
wire          arp_rx_type         ;
wire  [47:0]  src_mac             ;
wire  [31:0]  src_ip              ;
wire          arp_tx_en           ;
wire          arp_tx_type         ;
wire  [47:0]  des_mac             ;
wire  [31:0]  des_ip              ;
wire          arp_tx_done         ;

wire          icmp_gmii_tx_en     ;
wire  [7:0]   icmp_gmii_txd       ;
wire          icmp_rec_pkt_done   ;
wire          icmp_rec_en         ;
wire  [ 7:0]  icmp_rec_data       ;
wire  [15:0]  icmp_rec_byte_num   ;
wire  [15:0]  icmp_tx_byte_num    ;
wire          icmp_tx_done        ;
wire          icmp_tx_req         ;
wire  [ 7:0]  icmp_tx_data        ;
wire          icmp_tx_start_en    ;

wire          udp_gmii_tx_en      ;
wire  [7:0]   udp_gmii_txd        ;
wire          rec_pkt_done        ;
wire          udp_rec_en          ;
wire  [ 7:0]  udp_rec_data        ;
wire  [15:0]  rec_byte_num        ;
wire  [15:0]  tx_byte_num         ;
wire          udp_tx_done         ;
wire          udp_tx_req          ;
wire  [ 7:0]  udp_tx_data         ;
wire          tx_start_en         ;

wire  [7:0]   rec_data            ;
wire          rec_en              ;
wire          tx_req              ;
wire  [7:0]   tx_data             ;
// DEVIATION: official 39 top's u_clk_wiz_0 (eth_rxc->200M, IO-delay reserve)
// is REMOVED here — zero functional role, and its config clashes with the
// 53-version clk_wiz_0 (100M->50M) imported for the PCS/PMA DRP clock.

//*******************************************************************
// wires: SFP inner-loop observation path
//*******************************************************************
wire          clk_50m;                // PCS independent_clock (DRP)
wire          userclk2;               // PCS GMII clock (125M, GT-derived)
wire          mmcm_locked_out;
wire  [15:0]  status_vector1;
reg  [4:0]   configuration_vector;    // C19: 扫描器过程赋值（原 wire 改 reg）
wire  [15:0]  an_adv_config_vector;
wire          an_restart_config;
wire          signal_detect;
wire  [7:0]   pcs_gmii_rxd;           // looped-back bytes (userclk2 domain)
wire          pcs_gmii_rx_dv;
wire          pcs_gmii_rx_er;
wire  [7:0]   pump_txd;               // pump -> PCS TX (userclk2 domain)
wire          pump_tx_en;
// udp_rx (2nd instance) outputs
wire          rx2_rec_pkt_done;
wire          rx2_rec_en;
wire  [ 7:0]  rx2_rec_data;
wire  [15:0]  rx2_rec_byte_num;
// LEDs
reg           led_loop_r;

//*******************************************************************
// main code
//*******************************************************************

assign icmp_tx_start_en = icmp_rec_pkt_done;
assign icmp_tx_byte_num = icmp_rec_byte_num;

assign tx_start_en = rec_pkt_done;
assign tx_byte_num = rec_byte_num;
assign des_mac = src_mac;
assign des_ip = src_ip;
assign eth_rst_n = sys_rst_n;

// ---- SFP front-end config (official 53 values + C19 live config scanner) ----
assign sfp_rs0          = 1'b1;
assign sfp_rs1          = 1'b1;
assign sfp_tx_disable   = 1'b0;                  // laser on
assign signal_detect    = 1'b1;                  // module present (forced)
assign an_adv_config_vector = 16'h0021;          // official AN advertisement
assign an_restart_config    = 1'b0;

// ---- C19 config scanner: KEY press cycles 3 config words (live, no rebuild) ----
reg  [1:0]  cfg_idx;
reg         key_d0, key_d1, key_d2;
wire        key_edge;
reg         pcs_rst;
reg  [25:0] pcs_rst_cnt;

always @(posedge clk_50m or negedge sys_rst_n) begin
    if(!sys_rst_n) begin
        key_d0 <= 1'b1; key_d1 <= 1'b1; key_d2 <= 1'b1;  // idle high -> no boot artifact
    end
    else begin
        key_d0 <= key; key_d1 <= key_d0; key_d2 <= key_d1;
    end
end
assign key_edge = ~key_d2 & key_d1;               // pos edge = button release

always @(posedge clk_50m or negedge sys_rst_n) begin
    if(!sys_rst_n) begin
        cfg_idx     <= 2'd0;
        pcs_rst     <= 1'b1;                      // power-on: 0.5s PCS reset pulse
        pcs_rst_cnt <= 26'd25_000_000;
    end
    else if(pcs_rst_cnt != 26'd0) begin
        pcs_rst_cnt <= pcs_rst_cnt - 26'd1;
        if(pcs_rst_cnt == 26'd1)
            pcs_rst <= 1'b0;
    end
    else if(key_edge) begin
        cfg_idx     <= (cfg_idx == 2'd2) ? 2'd0 : cfg_idx + 2'd1;  // 0->1->2->0
        pcs_rst_cnt <= 26'd25_000_000;            // re-init PCS on config change
        pcs_rst     <= 1'b1;
    end
end

always @(*) begin
    configuration_vector[0] = 1'b1;              // inner loopback ON (all configs)
    configuration_vector[1] = 1'b0;              // no powerdown
    configuration_vector[2] = 1'b0;              // no isolate
    case(cfg_idx)                                 // C19: live-config scanner
        2'd0:    configuration_vector[4:3] = 2'b10;  // cfg0: official setting
        2'd1:    configuration_vector[4:3] = 2'b00;  // cfg1: AN+unidir both off
        2'd2:    configuration_vector[4:3] = 2'b01;  // cfg2: bit3=1 (AN enable per PG047)
        default: configuration_vector[4:3] = 2'b10;
    endcase
end

// ---- LED: sticky parse-complete after inner loop (userclk2 domain) ----
always @(posedge userclk2 or negedge sys_rst_n) begin
    if(!sys_rst_n)
        led_loop_r <= 1'b0;
    else if(rx2_rec_pkt_done)
        led_loop_r <= 1'b1;                      // sticky until reprogram
end
assign led_loop = led_loop_r;
assign led_link = cfg_idx[0];                    // T23 = config scanner index bit
                                                 //  (亮=cfg1, 灭=cfg0/cfg2)
// ---- ILA probes (scripted debug cores, see scripts/insert_ila.tcl) ----
(* mark_debug = "true" *) wire [7:0]   dbg_rx2_data = rx2_rec_data;
(* mark_debug = "true" *) wire         dbg_rx2_en   = rx2_rec_en;
(* mark_debug = "true" *) wire         dbg_rx2_done = rx2_rec_pkt_done;
(* mark_debug = "true" *) wire [15:0]  dbg_rx2_num  = rx2_rec_byte_num;
// registered snapshot of status_vector: all 16 bits become real userclk2 regs
// (raw alias had partially-defined clock domain due to folded constant bits)
(* mark_debug = "true" *) reg  [15:0]  dbg_status_r;
always @(posedge userclk2) dbg_status_r <= status_vector1;
(* mark_debug = "true" *) wire [15:0]  dbg_pump_wr;      // driven by u_pump port
(* mark_debug = "true" *) wire [15:0]  dbg_pump_rd;      // driven by u_pump port
(* mark_debug = "true" *) wire [15:0]  dbg_pump_drop;    // driven by u_pump port
(* mark_debug = "true" *) wire [1:0]   dbg_cfg_idx = cfg_idx;

//*******************************************************************
// clk_wiz (official 53 xci): 100M diff -> 50M (PCS independent_clock_bufg/DRP)
//*******************************************************************
clk_wiz_0 u_clk_wiz_sfp(
    .clk_out1           (clk_50m),
    .reset              (~sys_rst_n),
    .locked             (),
    .clk_in1_p          (sys_clk_p),
    .clk_in1_n          (sys_clk_n)
);

//*******************************************************************
// official 39 stack (wiring identical to official eth_udp_loop.v,
// except the unused clk_wiz_0 instance removed — see DEVIATION note)
//*******************************************************************

//GMII <-> RGMII
gmii_to_rgmii
    u_gmii_to_rgmii(
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

//ARP
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

//ICMP
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

//UDP
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

//async FIFO (echo buffer)
async_fifo_2048x8b u_async_fifo_2048x8b (
    .rst                (~sys_rst_n )   ,
    .wr_clk             (gmii_rx_clk)   ,
    .rd_clk             (gmii_rx_clk)   ,
    .din                (rec_data   )   ,
    .wr_en              (rec_en     )   ,
    .rd_en              (tx_req     )   ,
    .dout               (tx_data    )   ,
    .full               ()              ,
    .empty              ()
);

//ethernet control (ARP/ICMP/UDP switch + key->ARP request)
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

//*******************************************************************
// SFP inner-loop observation path (project_7 addition)
//*******************************************************************

//frame pump: stack GMII RX stream (eth_rxc domain) -> PCS TX (userclk2)
frame_fifo_pump u_pump(
    .wr_clk             (gmii_rx_clk   ),
    .wr_rst_n           (sys_rst_n     ),
    .wr_data            (gmii_rxd      ),  // PC original frame tap
    .wr_en              (gmii_rx_dv    ),

    .rd_clk             (userclk2      ),
    .rd_rst_n           (sys_rst_n     ),
    .rd_data            (pump_txd      ),
    .rd_en              (pump_tx_en    ),

    .wr_frame_cnt       (dbg_pump_wr   ),
    .wr_drop_cnt        (dbg_pump_drop ),
    .rd_frame_cnt       (dbg_pump_rd   )
);

//1G/2.5G Ethernet PCS/PMA or SGMII (official 53 xci: 1000BASE-X/1G/GMII/X1Y8)
gig_ethernet_pcs_pma_0 u_gig_ethernet_pcs_pma_0 (
    .gtrefclk_p             (gtrefclk_p),
    .gtrefclk_n             (gtrefclk_n),
    .gtrefclk_out           (),

    .txn                    (sfp_tx_n),
    .txp                    (sfp_tx_p),
    .rxn                    (sfp_rx_n),
    .rxp                    (sfp_rx_p),
    .independent_clock_bufg (clk_50m),
    .userclk_out            (),
    .userclk2_out           (userclk2),
    .rxuserclk_out          (),
    .rxuserclk2_out         (),
    .gtpowergood            (),
    .resetdone              (),
    .pma_reset_out          (),
    .mmcm_locked_out        (mmcm_locked_out),

    .gmii_txd               (pump_txd),
    .gmii_tx_en             (pump_tx_en),
    .gmii_tx_er             (1'b0),
    .gmii_rxd               (pcs_gmii_rxd),
    .gmii_rx_dv             (pcs_gmii_rx_dv),
    .gmii_rx_er             (pcs_gmii_rx_er),
    .gmii_isolate           (),

    .configuration_vector   (configuration_vector),
    .an_interrupt           (),
    .an_adv_config_vector   (an_adv_config_vector),
    .an_restart_config      (an_restart_config),
    .status_vector          (status_vector1),
    .reset                  (pcs_rst),               // C19: scanner pulses 0.5s on cfg change/power-on
    .signal_detect          (signal_detect)
);

//UDP RX (2nd instance, official module, parse-only observation)
udp_rx u_udp_rx_loop(
    .clk                (userclk2       ),
    .rst_n              (sys_rst_n      ),

    .gmii_rx_dv         (pcs_gmii_rx_dv ),
    .gmii_rxd           (pcs_gmii_rxd   ),

    .rec_pkt_done       (rx2_rec_pkt_done),
    .rec_en             (rx2_rec_en      ),
    .rec_data           (rx2_rec_data    ),
    .rec_byte_num       (rx2_rec_byte_num)
);

endmodule
