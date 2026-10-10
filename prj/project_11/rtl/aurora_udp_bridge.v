//=============================================================================
// aurora_udp_bridge.v — Aurora-UDP 数据级桥顶层（project_9 双笼版：A(Y11,X1Y11)↔B(Y9,X1Y9) 真光链路）
//
// 数据流（数据级 64b/66b 验证）:
//   PC --RJ45(GE1,RGMII)--> [以太网栈] --回显帧--> 帧泵(CDC) --> 打包(8→64)
//      --> Aurora 64b/66b TX --> SFP+ 真光链路(loopback=3'b000) --> Aurora RX
//      --> 解包(64→8) --> 帧泵(CDC) --> RGMII TX --> PC
//
// 判据: PC 脚本比对回显 payload == 发送 payload（数据必穿过 64b/66b 编解码才回得来）
//
// 关键设计:
//   - Aurora 仅插在「栈 TX → PC」单向路径；PC→栈 直连 RGMII（回显帧 dst=PC_MAC 不重入栈）
//   - 双向帧泵跨 eth_rxc(125M, PHY 晶振) ↔ user_clk(~151.5M, GT 恢复钟)
//   - 复位: reset_pb 同步于 init_clk；pma_init 上电脉冲（128 级移位，例程同款）
//   - DRP AXI4-Lite 悬空（例程同款，仅需常量输入）
// 来源: 官方 39 以太网栈 + aurora 例程共享逻辑（shared_logic/）+ project_7 帧泵
//=============================================================================
module aurora_udp_bridge (
    // ---- RGMII GE1 (PC front-end) ----
    input              sys_rst_n ,
    input              key       ,
    input              eth_rxc   ,
    input              eth_rx_ctl,
    input       [3:0]  eth_rxd   ,
    output             eth_txc   ,
    output             eth_tx_ctl,
    output      [3:0]  eth_txd   ,
    output             eth_rst_n ,
    // ---- GT (Aurora 64b/66b, X1Y11 = SFPA) ----
    input              gt_refclk_p,
    input              gt_refclk_n,
    input              init_clk_p ,
    input              init_clk_n ,
    input              sfp_rx_p   ,
    input              sfp_rx_n   ,
    output             sfp_tx_p   ,
    output             sfp_tx_n   ,
    output             sfp_tx_disable,
    output             sfp_rs0    ,
    output             sfp_rs1    ,
    // ---- GT-B (Aurora 64b/66b 第二通道, X1Y9 = 光口Y9 通道B) ----
    input              sfpb_rx_p  ,
    input              sfpb_rx_n  ,
    output             sfpb_tx_p  ,
    output             sfpb_tx_n  ,
    output             sfpb_tx_disable,
    output             sfpb_rs0   ,
    output             sfpb_rs1   ,
    // ---- 观测 LED ----
    output             led_loop   ,
    output             led_link
);

//parameter define (official values)
parameter  BOARD_MAC = 48'h00_11_22_33_44_55;
parameter  BOARD_IP  = {8'd192,8'd168,8'd1,8'd10};
parameter  DES_MAC   = 48'hff_ff_ff_ff_ff_ff;
parameter  DES_IP    = {8'd192,8'd168,8'd1,8'd102};

//*******************************************************************
// 以太网栈侧连线（eth_rxc 域）
//*******************************************************************
wire          gmii_rx_clk, gmii_rx_dv, gmii_tx_clk;
wire [7:0]    gmii_rxd;
wire [7:0]    stack_txd;                  // 栈 TX（eth_ctrl 输出）→ 帧泵
wire          stack_tx_en;
wire [7:0]    rgmii_txd_i;                // 帧泵回来 → RGMII TX
wire          rgmii_tx_en_i;

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
wire [15:0]   udp_src_port;               // P8: 发送方 UDP 源端口（回显目标端口）
wire          udp_tx_done, udp_tx_req;
wire [7:0]    udp_tx_data;
wire          tx_start_en;
wire [7:0]    rec_data, tx_data;
wire          rec_en, tx_req;

assign icmp_tx_start_en = icmp_rec_pkt_done;
assign icmp_tx_byte_num = icmp_rec_byte_num;
assign tx_start_en = rec_pkt_done;
assign tx_byte_num = rec_byte_num;
assign des_mac = src_mac;
assign des_ip = src_ip;
assign eth_rst_n = sys_rst_n;

//*******************************************************************
// Aurora 侧连线（user_clk 域）
//*******************************************************************
wire          init_clk, init_clk_i;
wire          user_clk, sync_clk, tx_out_clk;
wire          channel_up, lane_up, hard_err, soft_err, gt_pll_lock;
wire          reset_pb, pma_init;
wire          link_reset_out, mmcm_not_locked_out, sys_reset_out, bufg_gt_clr_out;

// AXI4-Stream TX (user_clk)
wire [63:0]   tx_tdata; wire [7:0] tx_tkeep; wire tx_tlast, tx_tvalid, tx_tready;
// AXI4-Stream RX (user_clk)
wire [63:0]   rx_tdata; wire [7:0] rx_tkeep; wire rx_tlast, rx_tvalid;
// DRP AXI4-Lite（悬空，例程同款）
wire [31:0]   drp_awaddr;  wire drp_awvalid, drp_awready;
wire [31:0]   drp_wdata;   wire [3:0] drp_wstrb; wire drp_wvalid, drp_wready;
wire          drp_bvalid;  wire [1:0] drp_bresp; wire drp_bready;
wire [31:0]   drp_araddr;  wire drp_arvalid, drp_arready;
wire [31:0]   drp_rdata;   wire drp_rvalid; wire [1:0] drp_rresp; wire drp_rready;

// 帧泵与打包/解包
wire [7:0]    pump_fwd_data;  wire pump_fwd_en;      // 泵出（user_clk）
wire [7:0]    unpack_data;    wire unpack_en;        // 解包出（user_clk）
wire [7:0]    pump_rev_data;  wire pump_rev_en;      // 泵回（eth_rxc）
wire [15:0]   pump_fwd_wr, pump_fwd_drop, pump_fwd_rd;
wire          pump_fwd_hs_busy;              // prj9 判决: 泵A帧在途(读侧, user_clk)
wire [15:0]   pump_rev_wr, pump_rev_drop, pump_rev_rd;
wire [15:0]   pack_frames;    wire pack_ovf;
wire [15:0]   unpack_bytes, unpack_frames; wire unpack_ovf; wire [15:0] unpack_stall;

// ---- prj9 双笼 B 通道连线（光口Y9 = GT X1Y9；user_clk_b 域）----
wire sh_refclk, sh_qpllclk, sh_qpllrefclk, sh_qplllock, sh_qpllrefclklost;
wire b_qpllreset;
wire user_clk_b, sync_clk_b;
wire channel_up_b, lane_up_b, hard_err_b, soft_err_b, gt_pll_lock_b;
wire [63:0] b_rx_tdata; wire [7:0] b_rx_tkeep; wire b_rx_tlast, b_rx_tvalid;
wire [63:0] b_tx_tdata; wire [7:0] b_tx_tkeep; wire b_tx_tlast, b_tx_tvalid, b_tx_tready;
wire [7:0]  echo_byte;                 // prj9 修复: B 回显改整帧存储转发(unpack→pack)
wire        echo_byte_en;
wire [15:0] echo_b_rx_frames, echo_b_tx_frames, echo_b_ovf;
wire link_ok = channel_up & channel_up_b;   // 双通道都 up 才算真链路建立

// 数据通路复位（user_clk 域）：系统复位 或 链路未建立
wire aurora_rst = ~sys_rst_n | ~link_ok;   // prj9: A、B 双 channel_up 门控

// ---- SFP 控制（内环模式功能不敏感；开激光、>4.25G 档）----
assign sfp_tx_disable = 1'b0;
assign sfp_rs0 = 1'b1;
assign sfp_rs1 = 1'b1;
assign sfpb_tx_disable = 1'b0;   // prj9: B 笼激光开
assign sfpb_rs0 = 1'b1;
assign sfpb_rs1 = 1'b1;

// ---- DRP 悬空 ----
assign drp_awaddr  = 32'h0;
assign drp_awvalid = 1'b0;
assign drp_wdata   = 32'h0;
assign drp_wstrb   = 4'h0;
assign drp_wvalid  = 1'b0;
assign drp_bready  = 1'b0;
assign drp_araddr  = 32'h0;
assign drp_arvalid = 1'b0;
assign drp_rready  = 1'b0;

//*******************************************************************
// init clock: 100MHz 差分（AK17/AK16）
//*******************************************************************
IBUFDS u_init_clk_ibufds (
    .I  (init_clk_p),
    .IB (init_clk_n),
    .O  (init_clk_i)
);
BUFG u_init_clk_bufg (
    .I (init_clk_i),
    .O (init_clk)
);

//*******************************************************************
// 复位与 PMA_INIT
//   reset_pb : 板载复位（低有效）→ 同步后的高有效
//   pma_init : 上电脉冲（128 级移位链，例程同款）
//*******************************************************************
reg [2:0] rst_sync;
always @(posedge init_clk) begin
    rst_sync <= {rst_sync[1:0], ~sys_rst_n};
end
assign reset_pb = rst_sync[2];

reg [127:0] pma_init_stage = {128{1'b1}};
always @(posedge init_clk) begin
    pma_init_stage <= {pma_init_stage[126:0], 1'b0};
end
assign pma_init = pma_init_stage[127];

//*******************************************************************
// Aurora 64b/66b 共享逻辑支撑（shared_logic/，例程同款）
//*******************************************************************
aurora_64b66b_0_support_ext u_aurora (   // prj9: _ext 版引出 refclk/QPLL 供 B 共享
    // TX AXI4-S
    .s_axi_tx_tdata  (tx_tdata ),
    .s_axi_tx_tlast  (tx_tlast ),
    .s_axi_tx_tkeep  (tx_tkeep ),
    .s_axi_tx_tvalid (tx_tvalid),
    .s_axi_tx_tready (tx_tready),
    // RX AXI4-S
    .m_axi_rx_tdata  (rx_tdata ),
    .m_axi_rx_tlast  (rx_tlast ),
    .m_axi_rx_tkeep  (rx_tkeep ),
    .m_axi_rx_tvalid (rx_tvalid),
    // GT Serial I/O
    .rxp (sfp_rx_p),
    .rxn (sfp_rx_n),
    .txp (sfp_tx_p),
    .txn (sfp_tx_n),
    // GT Reference Clock
    .gt_refclk1_p (gt_refclk_p),
    .gt_refclk1_n (gt_refclk_n),
    // Error / Status
    .hard_err   (hard_err  ),
    .soft_err   (soft_err  ),
    .channel_up (channel_up),
    .lane_up    (lane_up   ),
    // System
    .user_clk_out (user_clk),
    .sync_clk_out (sync_clk),
    .reset_pb     (reset_pb),
    .gt_rxcdrovrden_in (1'b0),
    .power_down   (1'b0),
    .loopback     (3'b000),          // prj9: 正常模式（真光链路；10G SFP+，tx_disable=0 已开激光）
    .pma_init     (pma_init),
    .gt_pll_lock  (gt_pll_lock),
    // DRP AXI4-Lite
    .s_axi_awaddr  (drp_awaddr ),
    .s_axi_awvalid (drp_awvalid),
    .s_axi_awready (drp_awready),
    .s_axi_wdata   (drp_wdata  ),
    .s_axi_wstrb   (drp_wstrb  ),
    .s_axi_wvalid  (drp_wvalid ),
    .s_axi_wready  (drp_wready ),
    .s_axi_bvalid  (drp_bvalid ),
    .s_axi_bresp   (drp_bresp  ),
    .s_axi_bready  (drp_bready ),
    .s_axi_araddr  (drp_araddr ),
    .s_axi_arvalid (drp_arvalid),
    .s_axi_arready (drp_arready),
    .s_axi_rdata   (drp_rdata  ),
    .s_axi_rvalid  (drp_rvalid ),
    .s_axi_rresp   (drp_rresp  ),
    .s_axi_rready  (drp_rready ),
    // Misc
    .init_clk             (init_clk),
    .link_reset_out       (link_reset_out),
    .mmcm_not_locked_out  (mmcm_not_locked_out),
    .bufg_gt_clr_out      (bufg_gt_clr_out),
    .sys_reset_out        (sys_reset_out),
    .tx_out_clk           (tx_out_clk),
    // prj9 双笼共享引出（→ u_aurora_b）
    .refclk1_out                 (sh_refclk),
    .gt_qpllclk_quad1_out        (sh_qpllclk),
    .gt_qpllrefclk_quad1_out     (sh_qpllrefclk),
    .gt_qplllock_quad1_out       (sh_qplllock),
    .gt_qpllrefclklost_quad1_out (sh_qpllrefclklost),
    .ext_qpllreset_in            (b_qpllreset)
);

//*******************************************************************
// prj9 双笼 B 通道（光口Y9 = GT X1Y9）：远端镜像 + 弹性回显
//   数据渡光两次: A.TX →光→ B.RX →[FIFO 512x80]→ B.TX →光→ A.RX
//   A 侧数据通路（泵/打包/解包）零改动，全部仍在 A 的 user_clk 域。
//   B 的 TX 无应用数据时 Aurora 自动发 idle —— 维持 A 的 channel_up。
//*******************************************************************
// 根因修复(2026-09-20): 裸 FWFT FIFO 直通会在 B.RX 帧中间隙时把 B.TX 抽干
// → Aurora TX 帧中欠载 → 64b/66b 帧协议违例 → TX 楔死(实测: ping 20/20 后 UDP
//   连发 2 帧即全路径永久楔死)。改用 unpack→pack 级联: pack 整帧缓存后连续拍出,
//   保证 B.TX 每帧无间隙 —— 与 prj8 第一根因(A 侧)同解, 模块复用零新逻辑。
axis_word_unpack u_unpack_b (
    .clk         (user_clk_b      ),
    .rst         (aurora_rst      ),
    .s_tdata     (b_rx_tdata      ),
    .s_tkeep     (b_rx_tkeep      ),
    .s_tlast     (b_rx_tlast      ),
    .s_tvalid    (b_rx_tvalid     ),
    .out_data    (echo_byte       ),
    .out_valid   (echo_byte_en    ),
    .o_byte_cnt  (                ),
    .o_frame_cnt (echo_b_rx_frames),
    .o_overflow  (                ),
    .o_stall_cnt (                )
);

axis_word_pack u_pack_b (
    .clk         (user_clk_b       ),
    .rst         (aurora_rst       ),
    .in_data     (echo_byte        ),
    .in_valid    (echo_byte_en     ),
    .m_tdata     (b_tx_tdata       ),
    .m_tkeep     (b_tx_tkeep       ),
    .m_tlast     (b_tx_tlast       ),
    .m_tvalid    (b_tx_tvalid      ),
    .m_tready    (b_tx_tready      ),
    .o_frame_cnt (echo_b_tx_frames ),
    .o_overflow  (echo_b_ovf       )
);

aurora_64b66b_1_support_shared u_aurora_b (
    .s_axi_tx_tdata  (b_tx_tdata ),
    .s_axi_tx_tkeep  (b_tx_tkeep ),
    .s_axi_tx_tlast  (b_tx_tlast ),
    .s_axi_tx_tvalid (b_tx_tvalid),
    .s_axi_tx_tready (b_tx_tready),
    .m_axi_rx_tdata  (b_rx_tdata ),
    .m_axi_rx_tkeep  (b_rx_tkeep ),
    .m_axi_rx_tlast  (b_rx_tlast ),
    .m_axi_rx_tvalid (b_rx_tvalid),
    .rxp (sfpb_rx_p), .rxn (sfpb_rx_n),
    .txp (sfpb_tx_p), .txn (sfpb_tx_n),
    .hard_err   (hard_err_b  ),
    .soft_err   (soft_err_b  ),
    .channel_up (channel_up_b),
    .lane_up    (lane_up_b   ),
    .user_clk_out (user_clk_b),
    .sync_clk_out (sync_clk_b),
    .reset_pb     (reset_pb   ),
    .loopback     (3'b000),          // 正常模式（真光链路）
    .pma_init     (pma_init   ),
    .init_clk     (init_clk   ),
    .gt_pll_lock  (gt_pll_lock_b),
    .refclk1_shared           (sh_refclk),
    .gt_qpllclk_shared        (sh_qpllclk),
    .gt_qpllrefclk_shared     (sh_qpllrefclk),
    .gt_qplllock_shared       (sh_qplllock),
    .gt_qpllrefclklost_shared (sh_qpllrefclklost),
    .gt_to_common_qpllreset_out (b_qpllreset)
);


//*******************************************************************
// GMII <-> RGMII（官方原版；2026-09-10 回退"改动 D"）
//   回退理由（以官方例程 + 官方 XDC 为板级基准）：
//   阶段二之五实操单 C8 —— YT8531 的 RXD0_RXDLY / RXD1_TXDLY strap 上拉，
//   RXC 相对 RXD 已由 PHY 内部居中（~2ns），**FPGA 侧不需要、也不应再加 IDELAY**。
//   此前在 IDDRE1 前插的 IDELAYE3 一旦被按键推到非零 tap，等于给 RX 硬加延时，
//   反而把本来正确的采样点推歪 —— 故整体回退到与官方逐字节一致的接法。
//*******************************************************************
gmii_to_rgmii u_gmii_to_rgmii (
    .gmii_rx_clk  (gmii_rx_clk),
    .gmii_rx_dv   (gmii_rx_dv ),
    .gmii_rxd     (gmii_rxd   ),
    .gmii_tx_clk  (gmii_tx_clk),
    .gmii_tx_en   (rgmii_tx_en_i),
    .gmii_txd     (rgmii_txd_i  ),
    .rgmii_rxc    (eth_rxc    ),
    .rgmii_rx_ctl (eth_rx_ctl ),
    .rgmii_rxd    (eth_rxd    ),
    .rgmii_txc    (eth_txc    ),
    .rgmii_tx_ctl (eth_tx_ctl ),
    .rgmii_txd    (eth_txd    )
);

//*******************************************************************
// ARP / ICMP / UDP / FIFO / eth_ctrl（官方栈，接线同 39 顶层）
//*******************************************************************
arp #(
    .BOARD_MAC (BOARD_MAC), .BOARD_IP (BOARD_IP),
    .DES_MAC   (DES_MAC  ), .DES_IP   (DES_IP  )
) u_arp (
    .rst_n         (sys_rst_n     ),
    .gmii_rx_clk   (gmii_rx_clk   ),
    .gmii_rx_dv    (gmii_rx_dv    ),
    .gmii_rxd      (gmii_rxd      ),
    .gmii_tx_clk   (gmii_tx_clk   ),
    .gmii_tx_en    (arp_gmii_tx_en),
    .gmii_txd      (arp_gmii_txd  ),
    .arp_rx_done   (arp_rx_done   ),
    .arp_rx_type   (arp_rx_type   ),
    .src_mac       (src_mac       ),
    .src_ip        (src_ip        ),
    .arp_tx_en     (arp_tx_en     ),
    .arp_tx_type   (arp_tx_type   ),
    .des_mac       (des_mac       ),
    .des_ip        (des_ip        ),
    .tx_done       (arp_tx_done   )
);

icmp #(
    .BOARD_MAC (BOARD_MAC), .BOARD_IP (BOARD_IP),
    .DES_MAC   (DES_MAC  ), .DES_IP   (DES_IP  )
) u_icmp (
    .rst_n           (sys_rst_n        ),
    .gmii_rx_clk     (gmii_rx_clk      ),
    .gmii_rx_dv      (gmii_rx_dv       ),
    .gmii_rxd        (gmii_rxd         ),
    .gmii_tx_clk     (gmii_tx_clk      ),
    .gmii_tx_en      (icmp_gmii_tx_en  ),
    .gmii_txd        (icmp_gmii_txd    ),
    .rec_pkt_done    (icmp_rec_pkt_done),
    .rec_en          (icmp_rec_en      ),
    .rec_data        (icmp_rec_data    ),
    .rec_byte_num    (icmp_rec_byte_num),
    .tx_start_en     (icmp_tx_start_en ),
    .tx_data         (icmp_tx_data     ),
    .tx_byte_num     (icmp_tx_byte_num ),
    .des_mac         (des_mac          ),
    .des_ip          (des_ip           ),
    .tx_done         (icmp_tx_done     ),
    .tx_req          (icmp_tx_req      )
);

udp #(
    .BOARD_MAC (BOARD_MAC), .BOARD_IP (BOARD_IP),
    .DES_MAC   (DES_MAC  ), .DES_IP   (DES_IP  )
) u_udp (
    .rst_n         (sys_rst_n    ),
    .gmii_rx_clk   (gmii_rx_clk  ),
    .gmii_rx_dv    (gmii_rx_dv   ),
    .gmii_rxd      (gmii_rxd     ),
    .gmii_tx_clk   (gmii_tx_clk  ),
    .gmii_tx_en    (udp_gmii_tx_en),
    .gmii_txd      (udp_gmii_txd ),
    .rec_pkt_done  (rec_pkt_done ),
    .rec_en        (udp_rec_en   ),
    .rec_data      (udp_rec_data ),
    .rec_byte_num  (rec_byte_num ),
    .rec_src_port  (udp_src_port ),   // P8: 捕获的发送方源端口
    .des_port      (udp_src_port ),   // P8: 回显发给该端口（不再硬编码 1234）
    .tx_start_en   (tx_start_en  ),
    .tx_data       (udp_tx_data  ),
    .tx_byte_num   (tx_byte_num  ),
    .des_mac       (des_mac      ),
    .des_ip        (des_ip       ),
    .tx_done       (udp_tx_done  ),
    .tx_req        (udp_tx_req   )
);

async_fifo_2048x8b u_async_fifo_2048x8b (
    .rst     (~sys_rst_n ),
    .wr_clk  (gmii_rx_clk),
    .rd_clk  (gmii_rx_clk),
    .din     (rec_data   ),
    .wr_en   (rec_en     ),
    .rd_en   (tx_req     ),
    .dout    (tx_data    ),
    .full    (           ),
    .empty   (           )
);

eth_ctrl u_eth_ctrl (
    .clk              (gmii_rx_clk     ),
    .rst_n            (sys_rst_n       ),
    .key              (key             ),
    .arp_rx_done      (arp_rx_done     ),
    .arp_rx_type      (arp_rx_type     ),
    .arp_tx_en        (arp_tx_en       ),
    .arp_tx_type      (arp_tx_type     ),
    .arp_tx_done      (arp_tx_done     ),
    .arp_gmii_tx_en   (arp_gmii_tx_en  ),
    .arp_gmii_txd     (arp_gmii_txd    ),
    .icmp_tx_start_en (icmp_tx_start_en),
    .icmp_tx_done     (icmp_tx_done    ),
    .icmp_gmii_tx_en  (icmp_gmii_tx_en ),
    .icmp_gmii_txd    (icmp_gmii_txd   ),
    .icmp_rec_en      (icmp_rec_en     ),
    .icmp_rec_data    (icmp_rec_data   ),
    .icmp_tx_req      (icmp_tx_req     ),
    .icmp_tx_data     (icmp_tx_data    ),
    .udp_tx_start_en  (tx_start_en     ),
    .udp_tx_done      (udp_tx_done     ),
    .udp_gmii_tx_en   (udp_gmii_tx_en  ),
    .udp_gmii_txd     (udp_gmii_txd    ),
    .udp_rec_data     (udp_rec_data    ),
    .udp_rec_en       (udp_rec_en      ),
    .udp_tx_req       (udp_tx_req      ),
    .udp_tx_data      (udp_tx_data     ),
    .rec_data         (rec_data        ),
    .rec_en           (rec_en          ),
    .tx_req           (tx_req          ),
    .tx_data          (tx_data         ),
    .gmii_tx_en       (stack_tx_en     ),
    .gmii_txd         (stack_txd       )
);

//*******************************************************************
// 帧泵 A：栈 TX（eth_rxc）→ user_clk
//*******************************************************************
frame_fifo_pump u_pump_fwd (
    .wr_clk       (gmii_rx_clk   ),
    .wr_rst_n     (~aurora_rst   ),   // C22: 与读侧对称, 否则链路抖动只复位读侧 -> 指针失配
    .wr_data      (stack_txd     ),
    .wr_en        (stack_tx_en   ),
    .rd_clk       (user_clk      ),
    .rd_rst_n     (~aurora_rst   ),
    .rd_data      (pump_fwd_data ),
    .rd_en        (pump_fwd_en   ),
    .wr_frame_cnt (pump_fwd_wr   ),
    .wr_drop_cnt  (pump_fwd_drop ),
    .rd_frame_cnt (pump_fwd_rd   ),
    .o_hs_busy    (pump_fwd_hs_busy)
);

//*******************************************************************
// 打包：8bit → 64bit AXIS → Aurora TX
//*******************************************************************
axis_word_pack u_pack (
    .clk         (user_clk      ),
    .rst         (aurora_rst    ),
    .in_data     (pump_fwd_data ),
    .in_valid    (pump_fwd_en   ),
    .m_tdata     (tx_tdata      ),
    .m_tkeep     (tx_tkeep      ),
    .m_tlast     (tx_tlast      ),
    .m_tvalid    (tx_tvalid     ),
    .m_tready    (tx_tready     ),
    .o_frame_cnt (pack_frames   ),
    .o_overflow  (pack_ovf      )
);

//*******************************************************************
// 解包：Aurora RX 64bit → 8bit
//*******************************************************************
axis_word_unpack u_unpack (
    .clk         (user_clk      ),
    .rst         (aurora_rst    ),
    .s_tdata     (rx_tdata      ),
    .s_tkeep     (rx_tkeep      ),
    .s_tlast     (rx_tlast      ),
    .s_tvalid    (rx_tvalid     ),
    .out_data    (unpack_data   ),
    .out_valid   (unpack_en     ),
    .o_byte_cnt  (unpack_bytes  ),
    .o_frame_cnt (unpack_frames ),
    .o_overflow  (unpack_ovf    ),
    .o_stall_cnt (unpack_stall  )
);

//*******************************************************************
// 帧泵 B：user_clk → eth_rxc（回 RGMII TX）
//*******************************************************************
frame_fifo_pump u_pump_rev (
    .wr_clk       (user_clk      ),
    .wr_rst_n     (~aurora_rst   ),
    .wr_data      (unpack_data   ),
    .wr_en        (unpack_en     ),
    .rd_clk       (gmii_rx_clk   ),
    .rd_rst_n     (~aurora_rst   ),   // C22: 与写侧对称
    .rd_data      (pump_rev_data ),
    .rd_en        (pump_rev_en   ),
    .wr_frame_cnt (pump_rev_wr   ),
    .wr_drop_cnt  (pump_rev_drop ),
    .rd_frame_cnt (pump_rev_rd   )
);

`ifdef P8_TX_DIRECT
// ===== 交叉验证变体（P8_TX_DIRECT）=====
//   TX 直连：与官方 39 / project_6（已验证能通的"网口版"）的数据通路完全一致。
//   Aurora 仍在设计里（链路照常建立、ILA 照常可抓），只是不进数据通路。
//   判据：ping/UDP 通 => RX 侧没坏，坏在"栈TX→泵A→打包→Aurora→解包→泵B"这条绕行；
//         仍不通 => RX 侧确实坏（与 ILA 抓到的字节损坏一致），需回到板级/实现层查。
assign rgmii_txd_i   = stack_txd;
assign rgmii_tx_en_i = stack_tx_en;
`else
assign rgmii_txd_i   = pump_rev_data;
assign rgmii_tx_en_i = pump_rev_en;
`endif

//*******************************************************************
// 观测 LED
//   T22 (led_loop) : Aurora RX 收到数据（粘滞）
//   T23 (led_link) : channel_up
//*******************************************************************
reg led_loop_r;
always @(posedge user_clk) begin
    if (aurora_rst) led_loop_r <= 1'b0;
    else if (rx_tvalid) led_loop_r <= 1'b1;
end
assign led_loop = led_loop_r;
assign led_link = link_ok;   // prj9: 双通道都 up 才点亮

//*******************************************************************
// prj9 判决计数器（2026-09-21）: 0.4% 丢失定位 + 冻结看门狗
//   一次全量运行后的差分链:
//     pfwd_wr → pfwd_rd → pk_frames → [A.TX→纤→B.RX] → echo_b_rx
//     → echo_b_tx → [B.TX→纤→A.RX] → up_frames → prev_wr
//   差额落在哪一段, 丢失就在哪一段; echo_b_ovf_cnt>0 = pack_b 整帧字丢失实锤。
//   冻结看门狗: 泵A 在途 >2M 拍(~13ms, 正常帧 ~21us) = 楔死, 记事件数。
//*******************************************************************
reg [15:0] hard_err_cnt, soft_err_cnt, ch_up_evt_cnt, pk_ovf_cnt;
reg        ch_up_d;
reg [21:0] pfwd_busy_cyc;
reg        pfwd_stuck;
reg [15:0] pfwd_stuck_cnt;
reg [15:0] echo_b_ovf_cnt, hard_err_b_cnt, soft_err_b_cnt, ch_up_b_evt_cnt;
reg        ch_up_b_d;
always @(posedge user_clk) begin
    if (aurora_rst) begin
        hard_err_cnt <= 16'd0; soft_err_cnt <= 16'd0; ch_up_evt_cnt <= 16'd0;
        pk_ovf_cnt <= 16'd0;  ch_up_d <= 1'b0;
        pfwd_busy_cyc <= 22'd0; pfwd_stuck <= 1'b0; pfwd_stuck_cnt <= 16'd0;
    end else begin
        ch_up_d <= channel_up;
        if (hard_err) hard_err_cnt <= hard_err_cnt + 16'd1;
        if (soft_err) soft_err_cnt <= soft_err_cnt + 16'd1;
        if (ch_up_d & ~channel_up) ch_up_evt_cnt <= ch_up_evt_cnt + 16'd1;
        if (pack_ovf) pk_ovf_cnt <= pk_ovf_cnt + 16'd1;
        if (!pump_fwd_hs_busy) begin
            pfwd_busy_cyc <= 21'd0;
            pfwd_stuck    <= 1'b0;
        end else begin
            pfwd_busy_cyc <= pfwd_busy_cyc + 22'd1;
            if (pfwd_busy_cyc == 22'h200000) begin
                pfwd_stuck     <= 1'b1;
                pfwd_stuck_cnt <= pfwd_stuck_cnt + 16'd1;
            end
        end
    end
end
always @(posedge user_clk_b) begin
    if (aurora_rst) begin
        echo_b_ovf_cnt <= 16'd0; hard_err_b_cnt <= 16'd0;
        soft_err_b_cnt <= 16'd0; ch_up_b_evt_cnt <= 16'd0; ch_up_b_d <= 1'b0;
    end else begin
        ch_up_b_d <= channel_up_b;
        if (echo_b_ovf) echo_b_ovf_cnt <= echo_b_ovf_cnt + 16'd1;
        if (hard_err_b) hard_err_b_cnt <= hard_err_b_cnt + 16'd1;
        if (soft_err_b) soft_err_b_cnt <= soft_err_b_cnt + 16'd1;
        if (ch_up_b_d & ~channel_up_b) ch_up_b_evt_cnt <= ch_up_b_evt_cnt + 16'd1;
    end
end

//*******************************************************************
// ILA 探针（脚本化调试核插入）
//*******************************************************************
// user_clk 域
(* mark_debug = "true" *) wire [63:0] dbg_rx_tdata  = rx_tdata;
(* mark_debug = "true" *) wire [7:0]  dbg_rx_tkeep  = rx_tkeep;
(* mark_debug = "true" *) wire        dbg_rx_tvalid = rx_tvalid;
(* mark_debug = "true" *) wire        dbg_rx_tlast  = rx_tlast;
(* mark_debug = "true" *) wire [63:0] dbg_tx_tdata  = tx_tdata;
(* mark_debug = "true" *) wire        dbg_tx_tvalid = tx_tvalid;
(* mark_debug = "true" *) wire [15:0] dbg_up_bytes  = unpack_bytes;
(* mark_debug = "true" *) wire [15:0] dbg_up_frames = unpack_frames;
(* mark_debug = "true" *) wire        dbg_up_ovf    = unpack_ovf;
(* mark_debug = "true" *) wire [15:0] dbg_up_stall  = unpack_stall;
(* mark_debug = "true" *) wire [15:0] dbg_pk_frames = pack_frames;
(* mark_debug = "true" *) wire        dbg_pk_ovf    = pack_ovf;
(* mark_debug = "true" *) wire        dbg_ch_up     = channel_up;
(* mark_debug = "true" *) wire        dbg_lane_up   = lane_up;
(* mark_debug = "true" *) wire        dbg_hard_err  = hard_err;
(* mark_debug = "true" *) wire        dbg_soft_err  = soft_err;
// 注意域归属: u_pump_rev 的**写侧**在 user_clk 域（只有读侧在 eth_rxc 域），
// 故这两个计数器必须挂在 user_clk 域的 ILA 上；挂到 eth_rxc 域的 ILA 会形成
// 未同步的跨域采样路径（首轮 WNS=-2.639 ns 的元凶之一），抓到也是亚稳态值。
(* mark_debug = "true" *) wire [15:0] dbg_prev_wr   = pump_rev_wr;
(* mark_debug = "true" *) wire [15:0] dbg_prev_drop = pump_rev_drop;
// eth_rxc 域
(* mark_debug = "true" *) wire [15:0] dbg_pfwd_wr   = pump_fwd_wr;
(* mark_debug = "true" *) wire [15:0] dbg_pfwd_drop = pump_fwd_drop;
(* mark_debug = "true" *) wire [7:0]  dbg_stack_txd = stack_txd;
(* mark_debug = "true" *) wire        dbg_stack_txen= stack_tx_en;
// eth_rxc 域 · **接收侧**可见性（2026-09-10 加：排查"PC 发的包到底进没进 FPGA"）
//   gmii_rx_dv   : PHY→FPGA 的 GMII 接收有效（有它 = 网线上的帧真的进来了）
//   arp_rx_done  : 官方栈成功解析出一个 ARP 帧（有它 = 数据没被 CRC/格式判掉）
//   udp/icmp_rec_done : UDP / ICMP 解析完成
(* mark_debug = "true" *) wire        dbg_gmii_rx_dv   = gmii_rx_dv;
(* mark_debug = "true" *) wire [7:0]  dbg_gmii_rxd     = gmii_rxd;
(* mark_debug = "true" *) wire        dbg_arp_rx_done  = arp_rx_done;
(* mark_debug = "true" *) wire        dbg_arp_rx_type  = arp_rx_type;
(* mark_debug = "true" *) wire        dbg_udp_rec_done = rec_pkt_done;
(* mark_debug = "true" *) wire        dbg_icmp_rec_done= icmp_rec_pkt_done;
(* mark_debug = "true" *) wire [15:0] dbg_rec_byte_num = rec_byte_num;
(* mark_debug = "true" *) wire [15:0] dbg_udp_src_port = udp_src_port;   // P8: 回显目标端口
// prj9 双笼 B 通道（user_clk_b 域 —— 如挂 ILA 需用 B 域时钟，勿挂 A 域 ILA）
(* mark_debug = "true" *) wire        dbg_ch_up_b     = channel_up_b;
(* mark_debug = "true" *) wire        dbg_b_rx_tvalid = b_rx_tvalid;
(* mark_debug = "true" *) wire        dbg_b_tx_tvalid = b_tx_tvalid;
(* mark_debug = "true" *) wire [15:0] dbg_echo_b_tx   = echo_b_tx_frames;
(* mark_debug = "true" *) wire        dbg_echo_b_ovf  = echo_b_ovf;   // 1位脉冲(2026-09-21 修正: 原误声明16位, 综合拆网致 get_nets 落空)

// ---- prj9 判决计数器（2026-09-21）: A 域(user_clk) 挂 ILA0; B 域挂 ILA2 ----
(* mark_debug = "true" *) wire [15:0] dbg_pk_ovf_cnt     = pk_ovf_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_pfwd_rd        = pump_fwd_rd;
(* mark_debug = "true" *) wire [15:0] dbg_hard_err_cnt   = hard_err_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_soft_err_cnt   = soft_err_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_ch_up_evt      = ch_up_evt_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_pfwd_stuck_cnt = pfwd_stuck_cnt;
(* mark_debug = "true" *) wire        dbg_pfwd_stuck     = pfwd_stuck;
// ---- B 域(user_clk_b) ----
(* mark_debug = "true" *) wire [15:0] dbg_echo_b_rx      = echo_b_rx_frames;
(* mark_debug = "true" *) wire [15:0] dbg_echo_b_ovf_cnt = echo_b_ovf_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_hard_err_b_cnt = hard_err_b_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_soft_err_b_cnt = soft_err_b_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_ch_up_b_evt    = ch_up_b_evt_cnt;
(* mark_debug = "true" *) wire        dbg_lane_up_b      = lane_up_b;

endmodule