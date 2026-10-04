//=============================================================================
// aurora_mem_bridge.v — prj10 第一级内存插入（派生自 prj9 aurora_udp_bridge.v）
// prj10 W3 集成 (2026-10-04)
//-----------------------------------------------------------------------------
// 数据流（相对 prj9 的唯一改动 = 拦截"泵A → pack"两根线，中间插入内存桥）:
//   PC --RJ45(GE1,RGMII)--> [以太网栈] --回显帧--> 帧泵A(CDC)
//      --> [frame_mem_if: 攒槽/写DDR4/按SEQ读回]     ←←← 本工程新增
//      --> axis_word_pack(8→64) --> Aurora A TX --> 光纤 --> B 回显(unpack→pack)
//      --> 光纤 --> Aurora RX --> unpack(64→8) --> 帧泵B(CDC) --> RGMII TX --> PC
//
// 派生原则（执行单 2026-10-04）：整份复制 prj9 顶层，只改:
//   1. u_pack 输入: pump_fwd_data/en → mem_rd_data/mem_rd_en（frame_mem_if 读侧）
//   2. 新增 frame_mem_if 实例 + ddr4_0(真 MIG) 实例 + DDR4 物理引脚
//   3. 时钟: init_clk_p/n(100M 差分) 同时喂 Aurora 与 MIG c0_sys_clk（同引脚双消费者）
//   4. 复位: MIG sys_rst 高有效 ← ~sys_rst_n 取反（prj4 例程mig_verify_top.v:248
//      极性接反的教训——松开按钮=持续复位=校准永不完成, 本顶层必须写对）
//   5. LED: T23(led_link)=链路 保持 prj9 原义; T22(led_loop)=**内存校准完成**
//      （端口名沿用 led_loop 使 XDC 零改动, 含义变更见此注释）
//   6. 读命令自动生成: outstanding(user域灰码镜像)>0 且 !rd_busy → 单拍 rd_req
//      （SEQ 模式模拟透传; 用 ro_outstanding_sync 而非 ro_wm —— 后者是 ui_clk
//       域多比特计数, 跨域直采会读到中间值; 前者是桥内已做 gray+2FF 的合法镜像）
// 以太网栈/帧泵/打包/解包/Aurora/B 回显/判决计数器: 零改动（prj9 验证资产全保留）
//
// 帧完整性契约: frame_mem_if 读侧已改"攒满整帧再发射"(PRIME 状态, 2026-10-04),
//   与原帧泵"整帧缓存无间隙泵出"同语义 → pack 输入帧中零气泡、帧间有空闲拍。
//=============================================================================
`timescale 1ns / 1ps

module aurora_mem_bridge (
    // ---- RGMII GE1 (PC front-end, 与 prj9 逐位相同) ----
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
    input              init_clk_p ,   // 100M 差分 AK17 —— 同时喂 MIG（见上 3）
    input              init_clk_n ,
    input              sfp_rx_p   ,
    input              sfp_rx_n   ,
    output             sfp_tx_p   ,
    output             sfp_tx_n   ,
    output             sfp_tx_disable,
    output             sfp_rs0    ,
    output             sfp_rs1    ,
    // ---- GT-B (Aurora 64b/66b, X1Y9 = 光口Y9 通道B) ----
    input              sfpb_rx_p  ,
    input              sfpb_rx_n  ,
    output             sfpb_tx_p  ,
    output             sfpb_tx_n  ,
    output             sfpb_tx_disable,
    output             sfpb_rs0   ,
    output             sfpb_rs1   ,
    // ---- DDR4 物理引脚（与 prj4 mig_verify_top / prj10 w3_uiclk_top 同名）----
    inout  [63:0]      c0_ddr4_dq,
    inout  [7:0]       c0_ddr4_dqs_t,
    inout  [7:0]       c0_ddr4_dqs_c,
    inout  [7:0]       c0_ddr4_dm_dbi_n,
    output [16:0]      c0_ddr4_adr,
    output [1:0]       c0_ddr4_ba,
    output [0:0]       c0_ddr4_bg,
    output [0:0]       c0_ddr4_cke,
    output [0:0]       c0_ddr4_cs_n,
    output [0:0]       c0_ddr4_odt,
    output [0:0]       c0_ddr4_ck_t,
    output [0:0]       c0_ddr4_ck_c,
    output             c0_ddr4_reset_n,
    output             c0_ddr4_act_n,
    // ---- 观测 LED（端口名沿用 prj9; T22 含义 = 内存校准完成）----
    output             led_loop   ,
    output             led_link
);

//parameter define (official values)
parameter  BOARD_MAC = 48'h00_11_22_33_44_55;
parameter  BOARD_IP  = {8'd192,8'd168,8'd1,8'd10};
parameter  DES_MAC   = 48'hff_ff_ff_ff_ff_ff;
parameter  DES_IP    = {8'd192,8'd168,8'd1,8'd102};

//*******************************************************************
// 以太网栈侧连线（eth_rxc 域）—— 与 prj9 逐位相同
//*******************************************************************
wire          gmii_rx_clk, gmii_rx_dv, gmii_tx_clk;
wire [7:0]    gmii_rxd;
wire [7:0]    stack_txd;                  // 栈 TX（eth_ctrl 输出）→ 帧泵A
wire          stack_tx_en;
wire [7:0]    rgmii_txd_i;                // 帧泵B 回来 → RGMII TX
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
wire [15:0]   udp_src_port;
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
// Aurora 侧连线（user_clk 域）—— 与 prj9 逐位相同
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
wire [7:0]    pump_fwd_data;  wire pump_fwd_en;      // 泵A 出（user_clk）→ 内存桥写侧
wire [7:0]    unpack_data;    wire unpack_en;        // 解包出（user_clk）
wire [7:0]    pump_rev_data;  wire pump_rev_en;      // 泵B 回（eth_rxc）
wire [15:0]   pump_fwd_wr, pump_fwd_drop, pump_fwd_rd;
wire          pump_fwd_hs_busy;
wire [15:0]   pump_rev_wr, pump_rev_drop, pump_rev_rd;
wire [15:0]   pack_frames;    wire pack_ovf;
wire [15:0]   unpack_bytes, unpack_frames; wire unpack_ovf; wire [15:0] unpack_stall;

// ---- prj9 双笼 B 通道连线（user_clk_b 域）—— 与 prj9 逐位相同 ----
wire sh_refclk, sh_qpllclk, sh_qpllrefclk, sh_qplllock, sh_qpllrefclklost;
wire b_qpllreset;
wire user_clk_b, sync_clk_b;
wire channel_up_b, lane_up_b, hard_err_b, soft_err_b, gt_pll_lock_b;
wire [63:0] b_rx_tdata; wire [7:0] b_rx_tkeep; wire b_rx_tlast, b_rx_tvalid;
wire [63:0] b_tx_tdata; wire [7:0] b_tx_tkeep; wire b_tx_tlast, b_tx_tvalid, b_tx_tready;
wire [7:0]  echo_byte;
wire        echo_byte_en;
wire [15:0] echo_b_rx_frames, echo_b_tx_frames, echo_b_ovf;
wire link_ok = channel_up & channel_up_b;

// 数据通路复位（user_clk 域）：系统复位 或 链路未建立 —— 与 prj9 相同
wire aurora_rst = ~sys_rst_n | ~link_ok;

// ---- SFP 控制（与 prj9 相同）----
assign sfp_tx_disable = 1'b0;
assign sfp_rs0 = 1'b1;
assign sfp_rs1 = 1'b1;
assign sfpb_tx_disable = 1'b0;
assign sfpb_rs0 = 1'b1;
assign sfpb_rs1 = 1'b1;

// ---- DRP 悬空（与 prj9 相同）----
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
// ★ prj10 新增: MIG (ddr4_0) 连线 —— ui_clk 域
//*******************************************************************
wire        calib;                     // init_calib_complete
wire        ui_clk;                    // ~300 MHz
wire        ui_sync_rst;               // MIG 同步复位(高有效, ui_clk 域)
wire [511:0] dbg_bus;
wire        mig_sys_rst = ~sys_rst_n;  // ★ 取反! prj4 教训(见文件头注释 4)
wire        ui_rst_n = ~ui_sync_rst;

// ---- 内存桥 ↔ MIG 的 AXI4（37 信号）----
wire [31:0] m_awaddr; wire [7:0] m_awlen; wire [2:0] m_awsize; wire [1:0] m_awburst;
wire        m_awvalid, m_awready;
wire [511:0] m_wdata; wire [63:0] m_wstrb; wire m_wlast, m_wvalid, m_wready;
wire [1:0]  m_bresp;  wire m_bvalid, m_bready;
wire [31:0] m_araddr; wire [7:0] m_arlen; wire [2:0] m_arsize; wire [1:0] m_arburst;
wire        m_arvalid, m_arready;
wire [511:0] m_rdata; wire [1:0] m_rresp; wire m_rlast, m_rvalid, m_rready;
wire [3:0]  m_awid, m_bid, m_arid, m_rid;
wire [0:0]  m_awlock, m_arlock;
wire [3:0]  m_awcache, m_arcache;
wire [2:0]  m_awprot, m_arprot;
wire [3:0]  m_awqos, m_arqos;

// ---- 内存桥 ↔ 帧路径（user_clk 域）----
wire [7:0]  mem_rd_data; wire mem_rd_en;              // 桥读侧 → pack（★两根线之一）
wire [7:0]  mem_rd_slot_o; wire [15:0] mem_rd_len_o;
wire        mem_rd_frame_done, mem_rd_busy;
reg         mem_rd_req = 1'b0;                        // 读命令自动生成（见文件头 6）
wire        mem_wr_hold;                              // 悬空: 帧泵不支持暂停, 满时整帧拒收计数

// 桥观测计数器（ui_clk 域输出 + user_clk 域输出, 分域挂 ILA）
wire [15:0] mem_wm, mem_wr_frame, mem_wr_stall, mem_rd_frame;
wire [15:0] mem_ill_rd, mem_noframe, mem_bresp_err, mem_len_err;
wire [8:0]  mem_outstanding;
wire [7:0]  mem_dbg_wr_slot, mem_dbg_rd_slot;
wire [31:0] mem_dbg_wr_cycles, mem_dbg_rd_cycles, mem_dbg_wr_beats, mem_dbg_rd_beats;
wire [15:0] mem_u_wr_frame, mem_u_rd_frame, mem_u_buf_drop;
wire [31:0] mem_u_hold_cycles;
wire [8:0]  mem_outstanding_sync;                     // user 域灰码镜像(合法跨域读)

// 读命令生成: 槽中有未读帧 且 桥空闲 且 上一拍没发过 → 单拍
// (ro_outstanding_sync 由桥内 gray+2FF 镜像, 单调语义; false-positive 空读
//  会被桥内 noframe 计数+定长应答兜住, false-negative 只延迟一拍重判)
always @(posedge user_clk) begin
    if (aurora_rst) mem_rd_req <= 1'b0;
    else            mem_rd_req <= (mem_outstanding_sync != 9'd0) && !mem_rd_busy && !mem_rd_req;
end

//*******************************************************************
// init clock: 100MHz 差分（AK17/AK16）—— 与 prj9 相同
// （同一对物理引脚同时是 Aurora init_clk 与 MIG sys_clk, XDC 一次约束）
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
// 复位与 PMA_INIT —— 与 prj9 相同
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
// Aurora 64b/66b 共享逻辑支撑（shared_logic/, 与 prj9 相同）
//*******************************************************************
aurora_64b66b_0_support_ext u_aurora (
    .s_axi_tx_tdata  (tx_tdata ),
    .s_axi_tx_tlast  (tx_tlast ),
    .s_axi_tx_tkeep  (tx_tkeep ),
    .s_axi_tx_tvalid (tx_tvalid),
    .s_axi_tx_tready (tx_tready),
    .m_axi_rx_tdata  (rx_tdata ),
    .m_axi_rx_tlast  (rx_tlast ),
    .m_axi_rx_tkeep  (rx_tkeep ),
    .m_axi_rx_tvalid (rx_tvalid),
    .rxp (sfp_rx_p),
    .rxn (sfp_rx_n),
    .txp (sfp_tx_p),
    .txn (sfp_tx_n),
    .gt_refclk1_p (gt_refclk_p),
    .gt_refclk1_n (gt_refclk_n),
    .hard_err   (hard_err  ),
    .soft_err   (soft_err  ),
    .channel_up (channel_up),
    .lane_up    (lane_up   ),
    .user_clk_out (user_clk),
    .sync_clk_out (sync_clk),
    .reset_pb     (reset_pb),
    .gt_rxcdrovrden_in (1'b0),
    .power_down   (1'b0),
    .loopback     (3'b000),          // 真光链路
    .pma_init     (pma_init),
    .gt_pll_lock  (gt_pll_lock),
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
    .init_clk             (init_clk),
    .link_reset_out       (link_reset_out),
    .mmcm_not_locked_out  (mmcm_not_locked_out),
    .bufg_gt_clr_out      (bufg_gt_clr_out),
    .sys_reset_out        (sys_reset_out),
    .tx_out_clk           (tx_out_clk),
    .refclk1_out                 (sh_refclk),
    .gt_qpllclk_quad1_out        (sh_qpllclk),
    .gt_qpllrefclk_quad1_out     (sh_qpllrefclk),
    .gt_qplllock_quad1_out       (sh_qplllock),
    .gt_qpllrefclklost_quad1_out (sh_qpllrefclklost),
    .ext_qpllreset_in            (b_qpllreset)
);

//*******************************************************************
// prj9 双笼 B 通道（与 prj9 相同）
//*******************************************************************
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
    .loopback     (3'b000),
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
// GMII <-> RGMII（官方原版, 与 prj9 相同）
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
// ARP / ICMP / UDP / FIFO / eth_ctrl（官方栈, 与 prj9 相同）
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
    .gmii_rx_clk   (gmii_rx_clk   ),
    .gmii_rx_dv    (gmii_rx_dv    ),
    .gmii_rxd      (gmii_rxd      ),
    .gmii_tx_clk   (gmii_tx_clk   ),
    .gmii_tx_en    (udp_gmii_tx_en),
    .gmii_txd      (udp_gmii_txd  ),
    .rec_pkt_done  (rec_pkt_done  ),
    .rec_en        (udp_rec_en    ),
    .rec_data      (udp_rec_data  ),
    .rec_byte_num  (rec_byte_num  ),
    .rec_src_port  (udp_src_port  ),
    .des_port      (udp_src_port  ),
    .tx_start_en   (tx_start_en   ),
    .tx_data       (udp_tx_data   ),
    .tx_byte_num   (tx_byte_num   ),
    .des_mac       (des_mac       ),
    .des_ip        (des_ip        ),
    .tx_done       (udp_tx_done   ),
    .tx_req        (udp_tx_req    )
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
// 帧泵 A：栈 TX（eth_rxc）→ user_clk —— 与 prj9 相同
// （输出不再直连 pack, 改喂内存桥写侧 —— 两根线之一）
//*******************************************************************
frame_fifo_pump u_pump_fwd (
    .wr_clk       (gmii_rx_clk   ),
    .wr_rst_n     (~aurora_rst   ),
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
// ★ prj10 核心: frame_mem_if —— 泵A 出 → 写 DDR4 → SEQ 读回 → pack
//*******************************************************************
frame_mem_if #(.SLOT_BASE(32'h0010_0000), .MAX_LEN(16'd1538)) u_mem (
    // 帧侧 (user_clk)
    .user_clk(user_clk), .user_rst_n(~aurora_rst),
    .wr_data (pump_fwd_data), .wr_en (pump_fwd_en),   // ← 泵A 出（原样接）
    .wr_hold (mem_wr_hold),                            // 悬空: 满时整帧拒收+计数
    .rd_data (mem_rd_data), .rd_en (mem_rd_en),        // → pack（帧中零气泡, 见 PRIME）
    .rd_slot_o(mem_rd_slot_o), .rd_len_o(mem_rd_len_o),
    .rd_frame_done(mem_rd_frame_done),
    .rd_req (mem_rd_req), .rd_busy (mem_rd_busy),
    .cfg_mode(1'b0), .cfg_rd_slot(8'h00),              // SEQ 模式（模拟透传）
    .ro_u_wr_frame(mem_u_wr_frame), .ro_u_rd_frame(mem_u_rd_frame),
    .ro_u_buf_drop(mem_u_buf_drop), .ro_u_hold_cycles(mem_u_hold_cycles),
    .ro_outstanding_sync(mem_outstanding_sync),
    // DDR 侧 (ui_clk)
    .ui_clk(ui_clk), .ui_rst_n(ui_rst_n), .calib_ok(calib),
    .ro_wm(mem_wm), .ro_wr_frame(mem_wr_frame), .ro_wr_stall(mem_wr_stall),
    .ro_rd_frame(mem_rd_frame), .ro_ill_rd(mem_ill_rd), .ro_noframe(mem_noframe),
    .ro_bresp_err(mem_bresp_err), .ro_len_err(mem_len_err),
    .ro_outstanding(mem_outstanding),
    .ro_dbg_wr_slot(mem_dbg_wr_slot), .ro_dbg_rd_slot(mem_dbg_rd_slot),
    .dbg_wr_cycles(mem_dbg_wr_cycles), .dbg_rd_cycles(mem_dbg_rd_cycles),
    .dbg_wr_beats(mem_dbg_wr_beats), .dbg_rd_beats(mem_dbg_rd_beats),
    // AXI4 (ui_clk) → MIG
    .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
    .m_axi_awburst(m_awburst), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
    .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
    .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
    .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
    .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
    .m_axi_arburst(m_arburst), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
    .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
    .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
    .m_axi_awid(m_awid), .m_axi_awlock(m_awlock),
    .m_axi_awcache(m_awcache), .m_axi_awprot(m_awprot),
    .m_axi_awqos(m_awqos), .m_axi_bid(m_bid),
    .m_axi_arid(m_arid), .m_axi_arlock(m_arlock),
    .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot),
    .m_axi_arqos(m_arqos), .m_axi_rid(m_rid)
);

//*******************************************************************
// ★ prj10: 真 MIG (ddr4_0) —— 复位取反 + 时钟经顶层 IBUFDS 单端喂入
//   时钟: System_Clock=No_Buffer(工程内 xci 已改, 不动 prj_uiclk 原件) —— 顶层
//   唯一的 IBUFDS 输出 init_clk_i 同时喂 Aurora 数字逻辑(经 BUFG)与 MIG MMCM。
//   (原差分直连 c0_sys_clk_p/n 会与顶层 IBUFDS 构成双输入缓冲, [Synth 8-5535]
//    非法 —— 2026-10-05 构建实证)
//   复位取反 mig_sys_rst = ~sys_rst_n（prj4 极性教训, 见文件头 4）
//*******************************************************************
ddr4_0 u_ddr4 (
    .sys_rst(mig_sys_rst),
    .c0_sys_clk_i(init_clk_i),
    .c0_ddr4_act_n(c0_ddr4_act_n), .c0_ddr4_adr(c0_ddr4_adr),
    .c0_ddr4_ba(c0_ddr4_ba), .c0_ddr4_bg(c0_ddr4_bg),
    .c0_ddr4_cke(c0_ddr4_cke), .c0_ddr4_odt(c0_ddr4_odt),
    .c0_ddr4_cs_n(c0_ddr4_cs_n),
    .c0_ddr4_ck_t(c0_ddr4_ck_t), .c0_ddr4_ck_c(c0_ddr4_ck_c),
    .c0_ddr4_reset_n(c0_ddr4_reset_n),
    .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n), .c0_ddr4_dq(c0_ddr4_dq),
    .c0_ddr4_dqs_c(c0_ddr4_dqs_c), .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
    .c0_init_calib_complete(calib),
    .c0_ddr4_ui_clk(ui_clk), .c0_ddr4_ui_clk_sync_rst(ui_sync_rst),
    .dbg_clk(), .c0_ddr4_aresetn(ui_rst_n),
    .c0_ddr4_s_axi_awid(m_awid),
    .c0_ddr4_s_axi_awaddr(m_awaddr), .c0_ddr4_s_axi_awlen(m_awlen),
    .c0_ddr4_s_axi_awsize(m_awsize), .c0_ddr4_s_axi_awburst(m_awburst),
    .c0_ddr4_s_axi_awlock(m_awlock), .c0_ddr4_s_axi_awcache(m_awcache),
    .c0_ddr4_s_axi_awprot(m_awprot), .c0_ddr4_s_axi_awqos(m_awqos),
    .c0_ddr4_s_axi_awvalid(m_awvalid), .c0_ddr4_s_axi_awready(m_awready),
    .c0_ddr4_s_axi_wdata(m_wdata), .c0_ddr4_s_axi_wstrb(m_wstrb),
    .c0_ddr4_s_axi_wlast(m_wlast), .c0_ddr4_s_axi_wvalid(m_wvalid),
    .c0_ddr4_s_axi_wready(m_wready),
    .c0_ddr4_s_axi_bready(m_bready),
    .c0_ddr4_s_axi_bid(m_bid), .c0_ddr4_s_axi_bresp(m_bresp),
    .c0_ddr4_s_axi_bvalid(m_bvalid),
    .c0_ddr4_s_axi_arid(m_arid),
    .c0_ddr4_s_axi_araddr(m_araddr), .c0_ddr4_s_axi_arlen(m_arlen),
    .c0_ddr4_s_axi_arsize(m_arsize), .c0_ddr4_s_axi_arburst(m_arburst),
    .c0_ddr4_s_axi_arlock(m_arlock), .c0_ddr4_s_axi_arcache(m_arcache),
    .c0_ddr4_s_axi_arprot(m_arprot), .c0_ddr4_s_axi_arqos(m_arqos),
    .c0_ddr4_s_axi_arvalid(m_arvalid), .c0_ddr4_s_axi_arready(m_arready),
    .c0_ddr4_s_axi_rready(m_rready),
    .c0_ddr4_s_axi_rid(m_rid), .c0_ddr4_s_axi_rdata(m_rdata),
    .c0_ddr4_s_axi_rresp(m_rresp), .c0_ddr4_s_axi_rlast(m_rlast),
    .c0_ddr4_s_axi_rvalid(m_rvalid),
    .dbg_bus(dbg_bus)
);

//*******************************************************************
// 打包：8bit → 64bit AXIS → Aurora TX
// ★ 输入从 pump_fwd_data/en 改为 mem_rd_data/en（两根线之一, 全单唯一拦截点）
//*******************************************************************
axis_word_pack u_pack (
    .clk         (user_clk      ),
    .rst         (aurora_rst    ),
    .in_data     (mem_rd_data   ),   // ← 原为 pump_fwd_data
    .in_valid    (mem_rd_en     ),   // ← 原为 pump_fwd_en
    .m_tdata     (tx_tdata      ),
    .m_tkeep     (tx_tkeep      ),
    .m_tlast     (tx_tlast      ),
    .m_tvalid    (tx_tvalid     ),
    .m_tready    (tx_tready     ),
    .o_frame_cnt (pack_frames   ),
    .o_overflow  (pack_ovf      )
);

//*******************************************************************
// 解包：Aurora RX 64bit → 8bit（与 prj9 相同）
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
// 帧泵 B：user_clk → eth_rxc（回 RGMII TX）—— 与 prj9 相同
//*******************************************************************
frame_fifo_pump u_pump_rev (
    .wr_clk       (user_clk      ),
    .wr_rst_n     (~aurora_rst   ),
    .wr_data      (unpack_data   ),
    .wr_en        (unpack_en     ),
    .rd_clk       (gmii_rx_clk   ),
    .rd_rst_n     (~aurora_rst   ),
    .rd_data      (pump_rev_data ),
    .rd_en        (pump_rev_en   ),
    .wr_frame_cnt (pump_rev_wr   ),
    .wr_drop_cnt  (pump_rev_drop ),
    .rd_frame_cnt (pump_rev_rd   )
);

assign rgmii_txd_i   = pump_rev_data;
assign rgmii_tx_en_i = pump_rev_en;

//*******************************************************************
// 观测 LED
//   T23 (led_link) : link_ok（prj9 原义, 上板判据硬前提）
//   T22 (led_loop) : calib（★含义变更: 内存校准完成; 端口名沿用使 XDC 零改动）
//*******************************************************************
assign led_loop = calib;
assign led_link = link_ok;

//*******************************************************************
// prj9 判决计数器（全保留, 六段差分链对账用）—— 与 prj9 相同
//   差分链(插入内存桥后): pfwd_wr → [桥 u_wr_frame → u_rd_frame]
//   → pk_frames → echo_b_rx → echo_b_tx → up_frames → prev_wr
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
// ILA 探针（脚本化调试核插入; 域归属红线——见 prj9 坑账本）
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
(* mark_debug = "true" *) wire [15:0] dbg_prev_wr   = pump_rev_wr;
(* mark_debug = "true" *) wire [15:0] dbg_prev_drop = pump_rev_drop;
// ★ prj10 user 域新增: 桥的用户侧计数 + 读侧发射使能（帧连续性观测）
(* mark_debug = "true" *) wire [15:0] dbg_mem_u_wr  = mem_u_wr_frame;
(* mark_debug = "true" *) wire [15:0] dbg_mem_u_rd  = mem_u_rd_frame;
(* mark_debug = "true" *) wire [15:0] dbg_mem_u_drop= mem_u_buf_drop;
(* mark_debug = "true" *) wire        dbg_mem_rden  = mem_rd_en;
(* mark_debug = "true" *) wire [8:0]  dbg_mem_ost_s = mem_outstanding_sync;
// eth_rxc 域
(* mark_debug = "true" *) wire [15:0] dbg_pfwd_wr   = pump_fwd_wr;
(* mark_debug = "true" *) wire [15:0] dbg_pfwd_drop = pump_fwd_drop;
(* mark_debug = "true" *) wire [7:0]  dbg_stack_txd = stack_txd;
(* mark_debug = "true" *) wire        dbg_stack_txen= stack_tx_en;
(* mark_debug = "true" *) wire        dbg_gmii_rx_dv   = gmii_rx_dv;
(* mark_debug = "true" *) wire [7:0]  dbg_gmii_rxd     = gmii_rxd;
(* mark_debug = "true" *) wire        dbg_arp_rx_done  = arp_rx_done;
(* mark_debug = "true" *) wire        dbg_arp_rx_type  = arp_rx_type;
(* mark_debug = "true" *) wire        dbg_udp_rec_done = rec_pkt_done;
(* mark_debug = "true" *) wire        dbg_icmp_rec_done= icmp_rec_pkt_done;
(* mark_debug = "true" *) wire [15:0] dbg_rec_byte_num = rec_byte_num;
(* mark_debug = "true" *) wire [15:0] dbg_udp_src_port = udp_src_port;
// prj9 双笼 B 通道（user_clk_b 域）
(* mark_debug = "true" *) wire        dbg_ch_up_b     = channel_up_b;
(* mark_debug = "true" *) wire        dbg_b_rx_tvalid = b_rx_tvalid;
(* mark_debug = "true" *) wire        dbg_b_tx_tvalid = b_tx_tvalid;
(* mark_debug = "true" *) wire [15:0] dbg_echo_b_tx   = echo_b_tx_frames;
(* mark_debug = "true" *) wire        dbg_echo_b_ovf  = echo_b_ovf;
// prj9 判决计数器（A 域）
(* mark_debug = "true" *) wire [15:0] dbg_pk_ovf_cnt     = pk_ovf_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_pfwd_rd        = pump_fwd_rd;
(* mark_debug = "true" *) wire [15:0] dbg_hard_err_cnt   = hard_err_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_soft_err_cnt   = soft_err_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_ch_up_evt      = ch_up_evt_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_pfwd_stuck_cnt = pfwd_stuck_cnt;
(* mark_debug = "true" *) wire        dbg_pfwd_stuck     = pfwd_stuck;
// B 域（user_clk_b）
(* mark_debug = "true" *) wire [15:0] dbg_echo_b_rx      = echo_b_rx_frames;
(* mark_debug = "true" *) wire [15:0] dbg_echo_b_ovf_cnt = echo_b_ovf_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_hard_err_b_cnt = hard_err_b_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_soft_err_b_cnt = soft_err_b_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_ch_up_b_evt    = ch_up_b_evt_cnt;
(* mark_debug = "true" *) wire        dbg_lane_up_b      = lane_up_b;
// ★ prj10 ui_clk 域（挂独立 ILA —— 严禁挂 user_clk/eth_rxc 域 ILA）
(* mark_debug = "true" *) wire        dbg_calib       = calib;
(* mark_debug = "true" *) wire [15:0] dbg_mem_wm      = mem_wm;
(* mark_debug = "true" *) wire [15:0] dbg_mem_wr_frm  = mem_wr_frame;
(* mark_debug = "true" *) wire [15:0] dbg_mem_rd_frm  = mem_rd_frame;
(* mark_debug = "true" *) wire [15:0] dbg_mem_stall   = mem_wr_stall;
(* mark_debug = "true" *) wire [15:0] dbg_mem_len_err = mem_len_err;
(* mark_debug = "true" *) wire [15:0] dbg_mem_bresp   = mem_bresp_err;
(* mark_debug = "true" *) wire [8:0]  dbg_mem_ost     = mem_outstanding;
(* mark_debug = "true" *) wire [7:0]  dbg_mem_wslot   = mem_dbg_wr_slot;
(* mark_debug = "true" *) wire [7:0]  dbg_mem_rslot   = mem_dbg_rd_slot;

// 未观测信号聚合（防剪枝告警; 数值不使用）
wire unused = ^{mem_rd_slot_o, mem_rd_len_o, mem_rd_frame_done, mem_wr_hold,
                mem_ill_rd, mem_noframe, dbg_bus,
                mem_dbg_wr_cycles, mem_dbg_rd_cycles, mem_dbg_wr_beats, mem_dbg_rd_beats,
                mem_u_hold_cycles, sync_clk, tx_out_clk, gt_pll_lock, gt_pll_lock_b,
                link_reset_out, mmcm_not_locked_out, sys_reset_out, bufg_gt_clr_out,
                lane_up_b, init_clk_i};

endmodule
