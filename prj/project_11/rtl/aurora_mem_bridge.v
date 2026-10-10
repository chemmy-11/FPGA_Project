//=============================================================================
// aurora_mem_bridge.v — prj10 第一级内存插入（派生自 prj9 aurora_udp_bridge.v）
// prj10 W3 集成 (2026-10-04)
//-----------------------------------------------------------------------------
// 数据流（相对 prj9 的唯一改动 = 拦截"泵A → pack"两根线，中间插入内存桥）:
//   PC --RJ45(GE1,RGMII)--> [以太网栈] --回显帧--> 帧泵A(CDC)
//      --> [内存桥① ING 0x0010_0000: 写DDR4/SEQ读回]                    ←W3
//      --> axis_word_pack(8→64) --> Aurora A TX --> 光纤 --> B 回显(unpack→pack)
//      --> 光纤 --> Aurora RX --> unpack(64→8)
//      --> [内存桥② EGR 0x0020_0000: 写DDR4/SEQ读回]                    ←W4
//      --> 帧泵B(CDC) --> RGMII TX --> PC
//   W4: 两级内存全环路(导师语义③④: 光回环后再存内存再读出); AXI 互联 =
//       自研 axi_arb_2to1 两主一从(S00=桥① S01=桥② M=MIG, ui_clk 同域)
//       (SmartConnect/AXI Interconnect 2023.1 均锁 IP Integrator, 实测独立
//        生成产物为空壳 -> 放弃 IP 互联, 见坑账本 #22; B/R 响应按授权
//        锁存路由, 2026-10-07 修复 —— 原 bid/rid[0] 路由在两桥同 ID 下死锁)
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
//   7. ★W5(2026-10-07) UDP 命令通道 cmd_channel: RX 总线并联 tap → 目的端口
//      1235 + magic "P10C" → 4 相握手邮箱进 user_clk → cfg_mode/cfg_rd_slot/
//      rd_req_pulse。**命令必须发往广播 IP**(官方栈按目的 IP 丢弃, 故不进回显
//      数据面/不占槽/不抬 wr_stall); 应答帧构造于 eth 域, 经 cmd_takeover mux
//      注入泵A 输入(仅当栈 TX 空闲 ≥64 拍才接管, 避免切断在途回显帧)。
//      RND 模式下 mem_rd_req 只由 rd_req_pulse 触发(不再自动读);
//      桥② 仍 SEQ。复位后 cfg_mode=0 → 行为与 W4 完全一致(安全默认)。
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
// ---- W5 命令通道：应答帧注入（同域 mux，见文件头 7）----
wire [7:0]    cmd_resp_txd;
wire          cmd_resp_tx_en;
wire          cmd_resp_busy;
wire          cmd_cfg_mode;
wire [7:0]    cmd_cfg_rd_slot;
wire          cmd_rd_req_pulse;
wire [15:0]   cmd_rx_cnt, cmd_err_cnt, cmd_exec_cnt, cmd_rd_trig_cnt;
reg  [6:0]    tx_idle_cnt = 7'd0;         // RGMII TX 空闲拍数（≥64 才允许接管）
wire          cmd_tx_idle = tx_idle_cnt[6];
reg           cmd_takeover = 1'b0;
wire [7:0]    rgmii_txd_i;                // 帧泵B 原始输出（未注入）
wire          rgmii_tx_en_i;
wire [7:0]    rgmii_txd_o;                // ★W5 末级注入后 → gmii_to_rgmii
wire          rgmii_tx_en_o;

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
// W5: SEQ = 原自动逻辑; RND = 只由命令通道的 rd_req_pulse 触发（命令通道保证单拍）
always @(posedge user_clk) begin
    if (aurora_rst)          mem_rd_req <= 1'b0;
    else if (cmd_cfg_mode)   mem_rd_req <= cmd_rd_req_pulse;
    else                     mem_rd_req <= (mem_outstanding_sync != 9'd0) && !mem_rd_busy && !mem_rd_req;
end

// W5: RGMII TX 末级空闲计数 + 接管锁存（eth_rxc 域; gmii_tx_clk ≡ gmii_rx_clk）
//  - 命令通道只在 cmd_tx_idle=1 时才允许拉 resp_busy（契约附录 v1.1）
//  - 接管一旦开始就保持到本次应答帧发完，避免 mux 在帧中途切换
//  - 空闲 ≥64 拍同时满足以太网 IFG（12B=96ns @1Gbps）
always @(posedge gmii_rx_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)             tx_idle_cnt <= 7'd0;
    else if (rgmii_tx_en_o)     tx_idle_cnt <= 7'd0;
    else if (!(&tx_idle_cnt))   tx_idle_cnt <= tx_idle_cnt + 7'd1;
end
always @(posedge gmii_rx_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)            cmd_takeover <= 1'b0;
    else if (!cmd_resp_busy)   cmd_takeover <= 1'b0;
    else if (cmd_tx_idle)      cmd_takeover <= 1'b1;
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
    .gmii_tx_en   (rgmii_tx_en_o),   // ★W5: 末级注入后（命令应答优先）
    .gmii_txd     (rgmii_txd_o  ),
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
// ★ prj10 W5: UDP 命令通道（cmd_channel）
//   RX 总线并联 tap（与 arp/icmp/udp 同结构）→ 目的端口 1235 + magic "P10C"
//   → 4 相握手邮箱跨到 user_clk → cfg_mode/cfg_rd_slot/rd_req_pulse
//   → 应答帧在 eth 域构造, 经 pump_a mux 注入栈 TX 出口（走既有环路回 PC）
//   命令必须发往广播 IP（官方栈按目的 IP 丢弃）→ 不进回显数据面、不占槽
//   官方模块零改动（契约: 操作文档/阶段三_prj10_W5命令通道接口契约_2026-10-07）
//*******************************************************************
cmd_channel u_cmd (
    // eth_rxc 域（125MHz）
    .clk_eth        (gmii_rx_clk      ),
    .rst_eth_n      (sys_rst_n        ),
    .gmii_rx_dv     (gmii_rx_dv       ),
    .gmii_rxd       (gmii_rxd         ),
    .tx_idle        (cmd_tx_idle      ),   // 栈 TX 空闲 ≥64 拍
    .resp_tx_en     (cmd_resp_tx_en   ),
    .resp_txd       (cmd_resp_txd     ),
    .resp_busy      (cmd_resp_busy    ),
    .cmd_rx_cnt     (cmd_rx_cnt       ),
    .cmd_err_cnt    (cmd_err_cnt      ),
    // user_clk 域（151.5MHz）
    .clk_user       (user_clk         ),
    .rst_user_n     (~aurora_rst      ),
    .u_wr_frame     (mem_u_wr_frame   ),
    .u_rd_frame     (mem_u_rd_frame   ),
    .u_buf_drop     (mem_u_buf_drop   ),
    .cfg_mode       (cmd_cfg_mode     ),
    .cfg_rd_slot    (cmd_cfg_rd_slot  ),
    .rd_req_pulse   (cmd_rd_req_pulse ),
    .cmd_exec_cnt   (cmd_exec_cnt     ),
    .rd_trig_cnt    (cmd_rd_trig_cnt  )
);

//*******************************************************************
// 帧泵 A：栈 TX（eth_rxc）→ user_clk —— 与 prj9 相同
// （输出不再直连 pack, 改喂内存桥写侧 —— 两根线之一）
// W5: 输入保持直连 stack_txd —— 应答不走这条路（见 pump B 末级注入）
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
    .cfg_mode(cmd_cfg_mode), .cfg_rd_slot(cmd_cfg_rd_slot),  // W5: 命令通道控制（复位后默认 SEQ）
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
// ★ W4 新增: 桥②(EGRESS 0x0020_0000) 声明 + SmartConnect 2主1从
//*******************************************************************
    wire [3:0] m2_axi_awid;
    wire [31:0] m2_axi_awaddr;
    wire [7:0] m2_axi_awlen;
    wire [2:0] m2_axi_awsize;
    wire [1:0] m2_axi_awburst;
    wire [0:0] m2_axi_awlock;
    wire [3:0] m2_axi_awcache;
    wire [2:0] m2_axi_awprot;
    wire [3:0] m2_axi_awqos;
    wire [0:0] m2_axi_awvalid;
    wire [0:0] m2_axi_awready;
    wire [511:0] m2_axi_wdata;
    wire [63:0] m2_axi_wstrb;
    wire [0:0] m2_axi_wlast;
    wire [0:0] m2_axi_wvalid;
    wire [0:0] m2_axi_wready;
    wire [1:0] m2_axi_bresp;
    wire [0:0] m2_axi_bvalid;
    wire [0:0] m2_axi_bready;
    wire [3:0] m2_axi_bid;
    wire [3:0] m2_axi_arid;
    wire [31:0] m2_axi_araddr;
    wire [7:0] m2_axi_arlen;
    wire [2:0] m2_axi_arsize;
    wire [1:0] m2_axi_arburst;
    wire [0:0] m2_axi_arlock;
    wire [3:0] m2_axi_arcache;
    wire [2:0] m2_axi_arprot;
    wire [3:0] m2_axi_arqos;
    wire [0:0] m2_axi_arvalid;
    wire [0:0] m2_axi_arready;
    wire [511:0] m2_axi_rdata;
    wire [1:0] m2_axi_rresp;
    wire [0:0] m2_axi_rlast;
    wire [0:0] m2_axi_rvalid;
    wire [0:0] m2_axi_rready;
    wire [3:0] m2_axi_rid;
    wire [3:0] sc_s_awid;
    wire [31:0] sc_s_awaddr;
    wire [7:0] sc_s_awlen;
    wire [2:0] sc_s_awsize;
    wire [1:0] sc_s_awburst;
    wire [0:0] sc_s_awlock;
    wire [3:0] sc_s_awcache;
    wire [2:0] sc_s_awprot;
    wire [3:0] sc_s_awqos;
    wire [0:0] sc_s_awvalid;
    wire [0:0] sc_s_awready;
    wire [511:0] sc_s_wdata;
    wire [63:0] sc_s_wstrb;
    wire [0:0] sc_s_wlast;
    wire [0:0] sc_s_wvalid;
    wire [0:0] sc_s_wready;
    wire [1:0] sc_s_bresp;
    wire [0:0] sc_s_bvalid;
    wire [0:0] sc_s_bready;
    wire [3:0] sc_s_bid;
    wire [3:0] sc_s_arid;
    wire [31:0] sc_s_araddr;
    wire [7:0] sc_s_arlen;
    wire [2:0] sc_s_arsize;
    wire [1:0] sc_s_arburst;
    wire [0:0] sc_s_arlock;
    wire [3:0] sc_s_arcache;
    wire [2:0] sc_s_arprot;
    wire [3:0] sc_s_arqos;
    wire [0:0] sc_s_arvalid;
    wire [0:0] sc_s_arready;
    wire [511:0] sc_s_rdata;
    wire [1:0] sc_s_rresp;
    wire [0:0] sc_s_rlast;
    wire [0:0] sc_s_rvalid;
    wire [0:0] sc_s_rready;
    wire [3:0] sc_s_rid;
    wire [7:0]  mem2_rd_data; wire mem2_rd_en;
    wire [7:0]  mem2_rd_slot_o; wire [15:0] mem2_rd_len_o;
    wire        mem2_rd_frame_done, mem2_rd_busy;
    reg         mem2_rd_req = 1'b0;
    wire        mem2_wr_hold;
    wire [15:0] mem2_wm, mem2_wr_frame, mem2_wr_stall, mem2_rd_frame;
    wire [15:0] mem2_ill_rd, mem2_noframe, mem2_bresp_err, mem2_len_err;
    wire [8:0]  mem2_outstanding;
    wire [7:0]  mem2_dbg_wr_slot, mem2_dbg_rd_slot;
    wire [31:0] mem2_dbg_wr_cycles, mem2_dbg_rd_cycles, mem2_dbg_wr_beats, mem2_dbg_rd_beats;
    wire [15:0] mem2_u_wr_frame, mem2_u_rd_frame, mem2_u_buf_drop;
    wire [31:0] mem2_u_hold_cycles;
    wire [8:0]  mem2_outstanding_sync;

    // 桥②读命令自动生成(同桥①: user 域灰码镜像 outstanding, SEQ 透传)
    always @(posedge user_clk) begin
        if (aurora_rst) mem2_rd_req <= 1'b0;
        else            mem2_rd_req <= (mem2_outstanding_sync != 9'd0) && !mem2_rd_busy && !mem2_rd_req;
    end

frame_mem_if #(.SLOT_BASE(32'h0020_0000), .MAX_LEN(16'd1538)) u_mem2 (
    // 帧侧 (user_clk)
    .user_clk(user_clk), .user_rst_n(~aurora_rst),
    .wr_data (unpack_data  ), .wr_en (unpack_en   ),   // ← W4 回程拦截点: 解包输出
    .wr_hold (mem2_wr_hold),                            // 悬空: 满时整帧拒收+计数
    .rd_data (mem2_rd_data), .rd_en (mem2_rd_en),        // → pack（帧中零气泡, 见 PRIME）
    .rd_slot_o(mem2_rd_slot_o), .rd_len_o(mem2_rd_len_o),
    .rd_frame_done(mem2_rd_frame_done),
    .rd_req (mem2_rd_req), .rd_busy (mem2_rd_busy),
    .cfg_mode(1'b0), .cfg_rd_slot(8'h00),              // SEQ 模式（模拟透传）
    .ro_u_wr_frame(mem2_u_wr_frame), .ro_u_rd_frame(mem2_u_rd_frame),
    .ro_u_buf_drop(mem2_u_buf_drop), .ro_u_hold_cycles(mem2_u_hold_cycles),
    .ro_outstanding_sync(mem2_outstanding_sync),
    // DDR 侧 (ui_clk)  —— 桥② EGRESS
    .ui_clk(ui_clk), .ui_rst_n(ui_rst_n), .calib_ok(calib),
    .ro_wm(mem2_wm), .ro_wr_frame(mem2_wr_frame), .ro_wr_stall(mem2_wr_stall),
    .ro_rd_frame(mem2_rd_frame), .ro_ill_rd(mem2_ill_rd), .ro_noframe(mem2_noframe),
    .ro_bresp_err(mem2_bresp_err), .ro_len_err(mem2_len_err),
    .ro_outstanding(mem2_outstanding),
    .ro_dbg_wr_slot(mem2_dbg_wr_slot), .ro_dbg_rd_slot(mem2_dbg_rd_slot),
    .dbg_wr_cycles(mem2_dbg_wr_cycles), .dbg_rd_cycles(mem2_dbg_rd_cycles),
    .dbg_wr_beats(mem2_dbg_wr_beats), .dbg_rd_beats(mem2_dbg_rd_beats),
    // AXI4 (ui_clk) → MIG
    .m_axi_awaddr(m2_axi_awaddr), .m_axi_awlen(m2_axi_awlen), .m_axi_awsize(m2_axi_awsize),
    .m_axi_awburst(m2_axi_awburst), .m_axi_awvalid(m2_axi_awvalid), .m_axi_awready(m2_axi_awready),
    .m_axi_wdata(m2_axi_wdata), .m_axi_wstrb(m2_axi_wstrb), .m_axi_wlast(m2_axi_wlast),
    .m_axi_wvalid(m2_axi_wvalid), .m_axi_wready(m2_axi_wready),
    .m_axi_bresp(m2_axi_bresp), .m_axi_bvalid(m2_axi_bvalid), .m_axi_bready(m2_axi_bready),
    .m_axi_araddr(m2_axi_araddr), .m_axi_arlen(m2_axi_arlen), .m_axi_arsize(m2_axi_arsize),
    .m_axi_arburst(m2_axi_arburst), .m_axi_arvalid(m2_axi_arvalid), .m_axi_arready(m2_axi_arready),
    .m_axi_rdata(m2_axi_rdata), .m_axi_rresp(m2_axi_rresp), .m_axi_rlast(m2_axi_rlast),
    .m_axi_rvalid(m2_axi_rvalid), .m_axi_rready(m2_axi_rready),
    .m_axi_awid(m2_axi_awid), .m_axi_awlock(m2_axi_awlock),
    .m_axi_awcache(m2_axi_awcache), .m_axi_awprot(m2_axi_awprot),
    .m_axi_awqos(m2_axi_awqos), .m_axi_bid(m2_axi_bid),
    .m_axi_arid(m2_axi_arid), .m_axi_arlock(m2_axi_arlock),
    .m_axi_arcache(m2_axi_arcache), .m_axi_arprot(m2_axi_arprot),
    .m_axi_arqos(m2_axi_arqos), .m_axi_rid(m2_axi_rid)
);

    // ---- 自研 AXI 仲裁器(2026-10-06): S00=桥① S01=桥② M=MIG, 事务级轮转 ----
    //   (SmartConnect/AXI Interconnect 2023.1 均锁 IP Integrator, 实测独立生成产物为空壳)
    axi_arb_2to1 u_arb (
        .s00_axi_awid(m_awid),
        .s00_axi_awaddr(m_awaddr),
        .s00_axi_awlen(m_awlen),
        .s00_axi_awsize(m_awsize),
        .s00_axi_awburst(m_awburst),
        .s00_axi_awlock(m_awlock),
        .s00_axi_awcache(m_awcache),
        .s00_axi_awprot(m_awprot),
        .s00_axi_awqos(m_awqos),
        .s00_axi_awvalid(m_awvalid),
        .s00_axi_awready(m_awready),
        .s00_axi_wdata(m_wdata),
        .s00_axi_wstrb(m_wstrb),
        .s00_axi_wlast(m_wlast),
        .s00_axi_wvalid(m_wvalid),
        .s00_axi_wready(m_wready),
        .s00_axi_bresp(m_bresp),
        .s00_axi_bvalid(m_bvalid),
        .s00_axi_bready(m_bready),
        .s00_axi_bid(m_bid),
        .s00_axi_arid(m_arid),
        .s00_axi_araddr(m_araddr),
        .s00_axi_arlen(m_arlen),
        .s00_axi_arsize(m_arsize),
        .s00_axi_arburst(m_arburst),
        .s00_axi_arlock(m_arlock),
        .s00_axi_arcache(m_arcache),
        .s00_axi_arprot(m_arprot),
        .s00_axi_arqos(m_arqos),
        .s00_axi_arvalid(m_arvalid),
        .s00_axi_arready(m_arready),
        .s00_axi_rdata(m_rdata),
        .s00_axi_rresp(m_rresp),
        .s00_axi_rlast(m_rlast),
        .s00_axi_rvalid(m_rvalid),
        .s00_axi_rready(m_rready),
        .s00_axi_rid(m_rid),
        .s01_axi_awid(m2_axi_awid),
        .s01_axi_awaddr(m2_axi_awaddr),
        .s01_axi_awlen(m2_axi_awlen),
        .s01_axi_awsize(m2_axi_awsize),
        .s01_axi_awburst(m2_axi_awburst),
        .s01_axi_awlock(m2_axi_awlock),
        .s01_axi_awcache(m2_axi_awcache),
        .s01_axi_awprot(m2_axi_awprot),
        .s01_axi_awqos(m2_axi_awqos),
        .s01_axi_awvalid(m2_axi_awvalid),
        .s01_axi_awready(m2_axi_awready),
        .s01_axi_wdata(m2_axi_wdata),
        .s01_axi_wstrb(m2_axi_wstrb),
        .s01_axi_wlast(m2_axi_wlast),
        .s01_axi_wvalid(m2_axi_wvalid),
        .s01_axi_wready(m2_axi_wready),
        .s01_axi_bresp(m2_axi_bresp),
        .s01_axi_bvalid(m2_axi_bvalid),
        .s01_axi_bready(m2_axi_bready),
        .s01_axi_bid(m2_axi_bid),
        .s01_axi_arid(m2_axi_arid),
        .s01_axi_araddr(m2_axi_araddr),
        .s01_axi_arlen(m2_axi_arlen),
        .s01_axi_arsize(m2_axi_arsize),
        .s01_axi_arburst(m2_axi_arburst),
        .s01_axi_arlock(m2_axi_arlock),
        .s01_axi_arcache(m2_axi_arcache),
        .s01_axi_arprot(m2_axi_arprot),
        .s01_axi_arqos(m2_axi_arqos),
        .s01_axi_arvalid(m2_axi_arvalid),
        .s01_axi_arready(m2_axi_arready),
        .s01_axi_rdata(m2_axi_rdata),
        .s01_axi_rresp(m2_axi_rresp),
        .s01_axi_rlast(m2_axi_rlast),
        .s01_axi_rvalid(m2_axi_rvalid),
        .s01_axi_rready(m2_axi_rready),
        .s01_axi_rid(m2_axi_rid),
        .m_axi_awid(sc_s_awid),
        .m_axi_awaddr(sc_s_awaddr),
        .m_axi_awlen(sc_s_awlen),
        .m_axi_awsize(sc_s_awsize),
        .m_axi_awburst(sc_s_awburst),
        .m_axi_awlock(sc_s_awlock),
        .m_axi_awcache(sc_s_awcache),
        .m_axi_awprot(sc_s_awprot),
        .m_axi_awqos(sc_s_awqos),
        .m_axi_awvalid(sc_s_awvalid),
        .m_axi_awready(sc_s_awready),
        .m_axi_wdata(sc_s_wdata),
        .m_axi_wstrb(sc_s_wstrb),
        .m_axi_wlast(sc_s_wlast),
        .m_axi_wvalid(sc_s_wvalid),
        .m_axi_wready(sc_s_wready),
        .m_axi_bresp(sc_s_bresp),
        .m_axi_bvalid(sc_s_bvalid),
        .m_axi_bready(sc_s_bready),
        .m_axi_bid(sc_s_bid),
        .m_axi_arid(sc_s_arid),
        .m_axi_araddr(sc_s_araddr),
        .m_axi_arlen(sc_s_arlen),
        .m_axi_arsize(sc_s_arsize),
        .m_axi_arburst(sc_s_arburst),
        .m_axi_arlock(sc_s_arlock),
        .m_axi_arcache(sc_s_arcache),
        .m_axi_arprot(sc_s_arprot),
        .m_axi_arqos(sc_s_arqos),
        .m_axi_arvalid(sc_s_arvalid),
        .m_axi_arready(sc_s_arready),
        .m_axi_rdata(sc_s_rdata),
        .m_axi_rresp(sc_s_rresp),
        .m_axi_rlast(sc_s_rlast),
        .m_axi_rvalid(sc_s_rvalid),
        .m_axi_rready(sc_s_rready),
        .m_axi_rid(sc_s_rid),
        .clk(ui_clk),
        .rst_n(ui_rst_n)
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
    .c0_ddr4_s_axi_awid(sc_s_awid),
    .c0_ddr4_s_axi_awaddr(sc_s_awaddr), .c0_ddr4_s_axi_awlen(sc_s_awlen),
    .c0_ddr4_s_axi_awsize(sc_s_awsize), .c0_ddr4_s_axi_awburst(sc_s_awburst),
    .c0_ddr4_s_axi_awlock(sc_s_awlock), .c0_ddr4_s_axi_awcache(sc_s_awcache),
    .c0_ddr4_s_axi_awprot(sc_s_awprot), .c0_ddr4_s_axi_awqos(sc_s_awqos),
    .c0_ddr4_s_axi_awvalid(sc_s_awvalid), .c0_ddr4_s_axi_awready(sc_s_awready),
    .c0_ddr4_s_axi_wdata(sc_s_wdata), .c0_ddr4_s_axi_wstrb(sc_s_wstrb),
    .c0_ddr4_s_axi_wlast(sc_s_wlast), .c0_ddr4_s_axi_wvalid(sc_s_wvalid),
    .c0_ddr4_s_axi_wready(sc_s_wready),
    .c0_ddr4_s_axi_bready(sc_s_bready),
    .c0_ddr4_s_axi_bid(sc_s_bid), .c0_ddr4_s_axi_bresp(sc_s_bresp),
    .c0_ddr4_s_axi_bvalid(sc_s_bvalid),
    .c0_ddr4_s_axi_arid(sc_s_arid),
    .c0_ddr4_s_axi_araddr(sc_s_araddr), .c0_ddr4_s_axi_arlen(sc_s_arlen),
    .c0_ddr4_s_axi_arsize(sc_s_arsize), .c0_ddr4_s_axi_arburst(sc_s_arburst),
    .c0_ddr4_s_axi_arlock(sc_s_arlock), .c0_ddr4_s_axi_arcache(sc_s_arcache),
    .c0_ddr4_s_axi_arprot(sc_s_arprot), .c0_ddr4_s_axi_arqos(sc_s_arqos),
    .c0_ddr4_s_axi_arvalid(sc_s_arvalid), .c0_ddr4_s_axi_arready(sc_s_arready),
    .c0_ddr4_s_axi_rready(sc_s_rready),
    .c0_ddr4_s_axi_rid(sc_s_rid), .c0_ddr4_s_axi_rdata(sc_s_rdata),
    .c0_ddr4_s_axi_rresp(sc_s_rresp), .c0_ddr4_s_axi_rlast(sc_s_rlast),
    .c0_ddr4_s_axi_rvalid(sc_s_rvalid),
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
    .wr_data      (mem2_rd_data  ),   // ★ W4: 原为 unpack_data(回程插桥②)
    .wr_en        (mem2_rd_en    ),
    .rd_clk       (gmii_rx_clk   ),
    .rd_rst_n     (~aurora_rst   ),
    .rd_data      (pump_rev_data ),
    .rd_en        (pump_rev_en   ),
    .wr_frame_cnt (pump_rev_wr   ),
    .wr_drop_cnt  (pump_rev_drop ),
    .rd_frame_cnt (pump_rev_rd   )
);

//*******************************************************************
// ★W5 命令通道应答注入点：RGMII TX 末级（eth_rxc 域，零 CDC）
//   为什么在这里（而非泵A 输入）：
//     泵A→桥① 是**内存写侧**。RND 模式下桥① 不再自动读，应答帧会被写进
//     槽里、要等读序轮到它才出得来 —— ACK 事实上到不了 PC（GET_WATERMARK
//     自锁）。故应答必须**绕开两级内存桥**，从网口末级直出。
//   为什么安全：
//     1) 仅在 TX 末级空闲 ≥64 拍时才允许接管（同时满足以太网 IFG）；
//     2) 接管锁存后保持到整帧发完，绝不在帧中途切换；
//     3) 命令为控制面稀疏流量，PC 侧同步流程（一条命令→等该命令的数据帧）
//        下泵B 在应答时刻为空闲，接管不与他帧竞争。
//   残余风险（已登记）：若应答发出的同一拍泵B 恰好起一帧，该帧首字节会被
//     吞掉（PC 侧表现为该数据帧损坏/缺失，**不会静默通过**）。彻底消除需把
//     注入点移到泵B 输入并引入 eth→user 字节 CDC，属后续可选项。
//*******************************************************************
assign rgmii_txd_i   = pump_rev_data;      // 泵B 原始
assign rgmii_tx_en_i = pump_rev_en;
assign rgmii_txd_o   = cmd_takeover ? cmd_resp_txd   : rgmii_txd_i;
assign rgmii_tx_en_o = cmd_takeover ? cmd_resp_tx_en : rgmii_tx_en_i;

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
// ★ W5 命令通道观测（J5 可观测性）
// user 域（ILA0）
(* mark_debug = "true" *) wire        dbg_cmd_mode    = cmd_cfg_mode;
(* mark_debug = "true" *) wire [7:0]  dbg_cmd_slot    = cmd_cfg_rd_slot;
(* mark_debug = "true" *) wire [15:0] dbg_cmd_exec    = cmd_exec_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_cmd_trig    = cmd_rd_trig_cnt;
// eth_rxc 域（ILA1）
(* mark_debug = "true" *) wire [15:0] dbg_cmd_rx      = cmd_rx_cnt;
(* mark_debug = "true" *) wire [15:0] dbg_cmd_err     = cmd_err_cnt;
(* mark_debug = "true" *) wire        dbg_cmd_respbsy = cmd_resp_busy;
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
// ★ W5 补: 非法读/无帧计数（契约 §4.3 负向轮对账）+ 读写突发数（J5「突发计数可观测」）
(* mark_debug = "true" *) wire [15:0] dbg_mem_ill     = mem_ill_rd;
(* mark_debug = "true" *) wire [15:0] dbg_mem_nofrm   = mem_noframe;
(* mark_debug = "true" *) wire [31:0] dbg_mem_wbeats  = mem_dbg_wr_beats;
(* mark_debug = "true" *) wire [31:0] dbg_mem_rbeats  = mem_dbg_rd_beats;
// ★ W4: 桥②(EGRESS)观测 —— user/ui 域分挂同桥①纪律
(* mark_debug = "true" *) wire [15:0] dbg_mem2_wm     = mem2_wm;
(* mark_debug = "true" *) wire [15:0] dbg_mem2_wr_frm = mem2_wr_frame;
(* mark_debug = "true" *) wire [15:0] dbg_mem2_rd_frm = mem2_rd_frame;
(* mark_debug = "true" *) wire [15:0] dbg_mem2_stall  = mem2_wr_stall;
(* mark_debug = "true" *) wire [15:0] dbg_mem2_len    = mem2_len_err;
(* mark_debug = "true" *) wire [8:0]  dbg_mem2_ost    = mem2_outstanding;
(* mark_debug = "true" *) wire [15:0] dbg_mem2_u_wr   = mem2_u_wr_frame;
(* mark_debug = "true" *) wire [15:0] dbg_mem2_u_rd   = mem2_u_rd_frame;

// 未观测信号聚合（防剪枝告警; 数值不使用）
wire unused = ^{mem_rd_slot_o, mem_rd_len_o, mem_rd_frame_done, mem_wr_hold,
                mem2_rd_slot_o, mem2_rd_len_o, mem2_rd_frame_done, mem2_wr_hold,
                mem2_ill_rd, mem2_noframe, mem2_dbg_wr_cycles, mem2_dbg_rd_cycles,
                mem2_dbg_wr_beats, mem2_dbg_rd_beats, mem2_u_hold_cycles,
                mem_ill_rd, mem_noframe, dbg_bus,
                mem_dbg_wr_cycles, mem_dbg_rd_cycles, mem_dbg_wr_beats, mem_dbg_rd_beats,
                mem_u_hold_cycles, sync_clk, tx_out_clk, gt_pll_lock, gt_pll_lock_b,
                link_reset_out, mmcm_not_locked_out, sys_reset_out, bufg_gt_clr_out,
                lane_up_b, init_clk_i};

endmodule
