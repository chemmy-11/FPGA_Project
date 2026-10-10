//=============================================================================
// frame_mem_if.v -- FRAME-side half of the prj10 memory bridge (W2)
//                   "以太网帧 <-> 可寻址槽" 的那一层
//-----------------------------------------------------------------------------
// Split follows the 09-28 interface reservation (draft S4):
//   frame_mem_if      : frame boundaries, 8b<->512b, slot selection, watermarks,
//                       command/status registers  (this file, user_clk + ui_clk)
//   axi4_master_bridge: bursts, 4KB rule, slot table, AXI handshake (pure ui_clk)
// -> if the mentor later mandates route B (AXI DMA), only axi4_master_bridge is
//    replaced; this layer and the frame interface survive unchanged.
//
// Clocking
//   user_clk (~151.5 MHz, Aurora user clock) : frame stream in/out, registers
//   ui_clk   (~300 MHz, MIG)                 : DDR traffic, slot table, counters
// CDC inventory (all three legal forms of AGENTS.md S5.1):
//   1) gray-pointer async FIFO  x5  (bytes, descriptors, commands)
//   2) 2FF synchronizer         x1  (gray-coded outstanding counter -> wr_hold)
//   (no 4-phase mailbox is needed here because every control path is a FIFO)
//
// WRITE POLICY (why "hold" exists):
//   The bridge accepts a frame only when a whole max-size frame still fits in the
//   byte FIFO, a descriptor slot is free and slots are not exhausted. Otherwise
//   the frame is dropped at its first byte and counted (u_buf_drop). wr_hold is
//   the level form of the same condition so an upstream that can pause (the
//   MicroBlaze control plane, or a future register-gated stack) loses nothing.
//   Dropping is NOT silent: it is counted on both sides of the CDC.
//=============================================================================
`timescale 1ns/1ps

module frame_mem_if #(
    parameter [31:0] SLOT_BASE = 32'h0010_0000,
    parameter [15:0] MAX_LEN   = 16'd1538,
    parameter        BF_AW     = 12,          // byte FIFO depth = 4096 (>=2 frames)
    parameter        DF_AW     = 3            // descriptor FIFO depth = 8
)(
    // ================= frame side (user_clk domain) =================
    input  wire         user_clk,
    input  wire         user_rst_n,
    // frame byte stream in (from 泵A / the ethernet stack output)
    input  wire [7:0]   wr_data,
    input  wire         wr_en,            // frame boundary = falling edge
    output wire         wr_hold,          // 1 = upstream should pause
    // frame byte stream out (to pack / Aurora TX)
    output reg  [7:0]   rd_data,
    output reg          rd_en,
    output reg  [7:0]   rd_slot_o,
    output reg  [15:0]  rd_len_o,
    output reg          rd_frame_done,
    input  wire         rd_req,           // 1-cycle pulse: consume one frame
    output wire         rd_busy,
    // control registers (written by the command channel of S6.4 / MicroBlaze)
    input  wire         cfg_mode,         // 0 = SEQ, 1 = RND
    input  wire [7:0]   cfg_rd_slot,
    // frame-side status (differential-chain accounting: user domain)
    output wire [15:0]  ro_u_wr_frame,
    output wire [15:0]  ro_u_rd_frame,
    output wire [15:0]  ro_u_buf_drop,
    output wire [31:0]  ro_u_hold_cycles,
    output wire [8:0]   ro_outstanding_sync,

    // ================= DDR side (ui_clk domain) =================
    input  wire         ui_clk,
    input  wire         ui_rst_n,
    input  wire         calib_ok,         // init_calib_complete (ui_clk)
    // status / counters -- MUST be probed by a ui_clk ILA (AGENTS.md S5.2)
    output wire [15:0]  ro_wm,
    output wire [15:0]  ro_wr_frame,
    output wire [15:0]  ro_wr_stall,
    output wire [15:0]  ro_rd_frame,
    output wire [15:0]  ro_ill_rd,
    output wire [15:0]  ro_noframe,
    output wire [15:0]  ro_bresp_err,
    output wire [15:0]  ro_len_err,       // W2-review D2: length refusals / drain bail-outs
    output wire [8:0]   ro_outstanding,
    output wire [7:0]   ro_dbg_wr_slot,
    output wire [7:0]   ro_dbg_rd_slot,
    output wire [31:0]  dbg_wr_cycles,
    output wire [31:0]  dbg_rd_cycles,
    output wire [31:0]  dbg_wr_beats,
    output wire [31:0]  dbg_rd_beats,

    // ================= AXI4 master (ui_clk domain) =================
    output wire [31:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,
    output wire [511:0] m_axi_wdata,
    output wire [63:0]  m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready,
    output wire [31:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [511:0] m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,

    // ---------------- AXI4 sideband (W3/A1: passthrough to the real MIG) --------
    output wire [3:0]   m_axi_awid,
    output wire [0:0]   m_axi_awlock,
    output wire [3:0]   m_axi_awcache,
    output wire [2:0]   m_axi_awprot,
    output wire [3:0]   m_axi_awqos,
    input  wire [3:0]   m_axi_bid,
    output wire [3:0]   m_axi_arid,
    output wire [0:0]   m_axi_arlock,
    output wire [3:0]   m_axi_arcache,
    output wire [2:0]   m_axi_arprot,
    output wire [3:0]   m_axi_arqos,
    input  wire [3:0]   m_axi_rid
);

    localparam BF_DEPTH = (1 << BF_AW);
    localparam [12:0] BF_ROOM = BF_DEPTH - MAX_LEN;   // 4096-1538 = 2558

    //=========================================================================
    // 1. CDC FIFOs
    //=========================================================================
    // user -> ui : frame bytes
    wire [7:0]  ub_dout;  wire ub_empty, ub_full;  wire [BF_AW:0] ub_wl, ub_rl;
    wire        ub_rd_en;  wire ub_wr_en;
    reg         rd_pop;                   // declared up front: used as a FIFO port below
    // user -> ui : frame descriptors (length)
    wire [15:0] ud_dout;  wire ud_empty, ud_full;
    wire        ud_wr_en;  wire [15:0] ud_din;
    wire        ud_rd_en;
    // user -> ui : read commands {rnd, slot}
    wire [8:0]  uc_dout;  wire uc_empty, uc_full;
    wire        uc_wr_en;  wire [8:0]  uc_din;
    wire        uc_rd_en;
    // ui -> user : frame bytes
    wire [7:0]  rb_dout;  wire rb_empty, rb_full;  wire [BF_AW:0] rb_level;
    wire        rb_wr_en;  wire [7:0]  rb_din;
    wire        rb_rd_en;
    // ui -> user : read descriptors {none, len[15:0], slot[7:0]}
    wire [24:0] rd_dout;  wire rd_empty, rd_full;
    wire        rdesc_wr_en;  wire [24:0] rdesc_din;

    async_fifo #(.DW(8), .AW(BF_AW)) u_wr_bytes (
        .wr_clk(user_clk), .wr_rst_n(user_rst_n), .wr_data(wr_data), .wr_en(ub_wr_en),
        .wr_full(ub_full), .wr_level(ub_wl),
        .rd_clk(ui_clk), .rd_rst_n(ui_rst_n), .rd_data(ub_dout), .rd_en(ub_rd_en),
        .rd_empty(ub_empty), .rd_level(ub_rl));

    async_fifo #(.DW(16), .AW(DF_AW)) u_wr_desc (
        .wr_clk(user_clk), .wr_rst_n(user_rst_n), .wr_data(ud_din), .wr_en(ud_wr_en),
        .wr_full(ud_full), .wr_level(),
        .rd_clk(ui_clk), .rd_rst_n(ui_rst_n), .rd_data(ud_dout), .rd_en(ud_rd_en),
        .rd_empty(ud_empty), .rd_level());

    async_fifo #(.DW(9), .AW(2)) u_rd_cmd (
        .wr_clk(user_clk), .wr_rst_n(user_rst_n), .wr_data(uc_din), .wr_en(uc_wr_en),
        .wr_full(uc_full), .wr_level(),
        .rd_clk(ui_clk), .rd_rst_n(ui_rst_n), .rd_data(uc_dout), .rd_en(uc_rd_en),
        .rd_empty(uc_empty), .rd_level());

    async_fifo #(.DW(8), .AW(BF_AW)) u_rd_bytes (
        .wr_clk(ui_clk), .wr_rst_n(ui_rst_n), .wr_data(rb_din), .wr_en(rb_wr_en),
        .wr_full(rb_full), .wr_level(rb_level),
        .rd_clk(user_clk), .rd_rst_n(user_rst_n), .rd_data(rb_dout), .rd_en(rb_rd_en),
        .rd_empty(rb_empty), .rd_level());

    async_fifo #(.DW(25), .AW(2)) u_rd_desc (
        .wr_clk(ui_clk), .wr_rst_n(ui_rst_n), .wr_data(rdesc_din), .wr_en(rdesc_wr_en),
        .wr_full(rd_full), .wr_level(),
        .rd_clk(user_clk), .rd_rst_n(user_rst_n), .rd_data(rd_dout), .rd_en(rd_pop),
        .rd_empty(rd_empty), .rd_level());

    //=========================================================================
    // 2. outstanding (slot occupancy) mirrored into user domain, gray + 2FF
    //=========================================================================
    function [8:0] bin2gray9(input [8:0] b); bin2gray9 = (b >> 1) ^ b; endfunction
    function [8:0] gray2bin9(input [8:0] g);
        integer i;
        begin
            gray2bin9[8] = g[8];
            for (i = 7; i >= 0; i = i - 1) gray2bin9[i] = gray2bin9[i+1] ^ g[i];
        end
    endfunction

    reg  [8:0] out_g_ui;
    reg  [8:0] out_g_s1, out_g_s2;

    always @(posedge ui_clk or negedge ui_rst_n) begin
        if (!ui_rst_n) out_g_ui <= 9'd0;
        else           out_g_ui <= bin2gray9(ro_outstanding);
    end
    always @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n) begin out_g_s1 <= 9'd0; out_g_s2 <= 9'd0; end
        else begin out_g_s1 <= out_g_ui; out_g_s2 <= out_g_s1; end
    end
    wire [8:0] outstanding_sync = gray2bin9(out_g_s2);
    assign ro_outstanding_sync = outstanding_sync;

    //=========================================================================
    // 3. write side: frame gather, acceptance policy, byte + descriptor push
    //=========================================================================
    reg  [15:0] wcnt;          // bytes of the current frame
    reg         wdv_d;
    reg         frm_drop;
    reg         ud_push;
    reg  [15:0] n_push;        // bytes of the current frame ACTUALLY enqueued
    reg  [15:0] n_push_r;      // latched value that becomes the descriptor length.
                               // W2-review D2 FIX: the descriptor length is the
                               // number of bytes REALLY written into the byte FIFO
                               // -- not wcnt, which counts bytes merely OFFERED by
                               // the upstream.  The two diverge the moment ub_full
                               // clips a frame (any frame > MAX_LEN, or an
                               // upstream that violates the 1538 B contract), and
                               // the bridge then drained w_len bytes that were not
                               // there -> W_DRAIN never terminated.
                               // MUST be its own register: n_push is cleared in the
                               // same cycle ud_push is raised (same lesson as R3).
    reg  [15:0] u_wr_frame_cnt, u_buf_drop;
    reg  [31:0] u_hold_cycles;

    wire wr_first = wr_en & ~wdv_d;
    wire wr_last  = ~wr_en &  wdv_d;

    wire byte_room_ok = (ub_wl <= BF_ROOM);
    wire desc_room_ok = ~ud_full;
    wire slot_room_ok = (outstanding_sync < 9'd256);
    wire can_accept   = byte_room_ok & desc_room_ok & slot_room_ok;

    assign wr_hold = ~can_accept;

    wire frm_drop_now = wr_first ? ~can_accept : frm_drop;
    wire push_now     = wr_en & ~frm_drop_now & ~ub_full;   // byte really enters
    assign ub_wr_en   = push_now;

    assign ud_din  = n_push_r;      // == bytes actually in the FIFO (D2 fix)
    assign ud_wr_en= ud_push;

    always @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n) begin
            wcnt <= 16'd0; wdv_d <= 1'b0; frm_drop <= 1'b0; ud_push <= 1'b0;
            n_push <= 16'd0; n_push_r <= 16'd0;
            u_wr_frame_cnt <= 16'd0; u_buf_drop <= 16'd0; u_hold_cycles <= 32'd0;
        end else begin
            wdv_d   <= wr_en;
            ud_push <= 1'b0;
            if (wr_hold) u_hold_cycles <= u_hold_cycles + 32'd1;

            if (wr_en) begin
                if (wr_first) begin
                    frm_drop <= ~can_accept;
                    wcnt     <= 16'd1;
                    n_push   <= push_now ? 16'd1 : 16'd0;
                    if (~can_accept) u_buf_drop <= u_buf_drop + 16'd1;
                end else if (wcnt != 16'd0) begin
                    wcnt <= wcnt + 16'd1;
                    if (push_now) n_push <= n_push + 16'd1;
                end
            end

            if (wr_last) begin
                if (~frm_drop && (n_push != 16'd0)) begin
                    ud_push        <= 1'b1;
                    n_push_r       <= n_push;    // D2 fix: descriptor == FIFO bytes
                    u_wr_frame_cnt <= u_wr_frame_cnt + 16'd1;
                end else if (~frm_drop) begin
                    u_buf_drop <= u_buf_drop + 16'd1;   // accepted, but no byte landed
                end
                wcnt   <= 16'd0;
                n_push <= 16'd0;
            end
        end
    end

    assign ro_u_wr_frame   = u_wr_frame_cnt;
    assign ro_u_buf_drop   = u_buf_drop;
    assign ro_u_hold_cycles= u_hold_cycles;

    //=========================================================================
    // 4. read side: command issue + byte emission
    //=========================================================================
    reg  [1:0]  est;                    // 0 idle, 3 PRIME, 1 emit, 2 done
    reg         rd_busy_r;
    reg  [15:0] rd_cnt;
    reg  [15:0] u_rd_frame_cnt;

    assign rd_busy = rd_busy_r;
    assign uc_din  = {cfg_mode, cfg_rd_slot};
    assign uc_wr_en= rd_req & ~rd_busy_r & ~uc_full;
    assign rb_rd_en= (est == 2'd1) && !rb_empty;   // FIFO pop pulse (registered rd_en below)

    always @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n) begin
            est <= 2'd0; rd_busy_r <= 1'b0; rd_cnt <= 16'd0; u_rd_frame_cnt <= 16'd0;
            rd_data <= 8'd0; rd_en <= 1'b0; rd_slot_o <= 8'd0; rd_len_o <= 16'd0;
            rd_frame_done <= 1'b0; rd_pop <= 1'b0;
        end else begin
            rd_frame_done <= 1'b0;
            rd_pop        <= 1'b0;
            rd_en         <= 1'b0;
            if (uc_wr_en) rd_busy_r <= 1'b1;   // request accepted -> busy until the
                                               // response descriptor says otherwise

            case (est)
            2'd0: begin
                if (!rd_empty) begin
                    rd_pop <= 1'b1;                    // pop this cycle
                    if (rd_dout[24]) begin             // {none, len[15:0], slot[7:0]}
                        rd_busy_r     <= 1'b0;
                        rd_len_o      <= 16'd0;
                        rd_slot_o     <= rd_dout[7:0];
                        rd_frame_done <= 1'b1;         // uniform "request finished"
                    end else begin
                        rd_len_o  <= rd_dout[23:8];
                        rd_slot_o <= rd_dout[7:0];
                        rd_cnt    <= 16'd0;
                        est       <= 2'd3;        // W3 集成: 先攒帧再发射(见 2'd3)
                    end
                end
            end
            // ---- W3 集成改动(2026-10-04): PRIME 状态 = 攒满整帧再发射 ----
            // 上游(原 prj9 帧泵)对 pack 的契约是"整帧缓存后无间隙泵出"(frame
            // integrity); 若沿用 FWFT 直通边发, DDR 读回节拍跟不上 user_clk 消费
            // 时帧中间会出现无效拍 -> Aurora 64b/66b 帧协议违例 -> TX 楔死
            // (= prj9 09-20 B 回显裸 FIFO 直通的同款根因)。rb FIFO 深 4096 >=
            // MAX_LEN 1538, 攒满一帧结构上可行; rb_level 为读域保守值(只会低估
            // 不会高估), 故 rb_level >= len 即保证帧内字节全部到达, 发射期间
            // 帧中零气泡, 且两帧间天然有空闲拍(满足 pack 帧尾/帧间隔要求)。
            2'd3: begin
                if (rb_level >= {3'b0, rd_len_o})
                    est <= 2'd1;
            end
            2'd1: begin
                if (!rb_empty) begin
                    rd_data <= rb_dout;                // FWFT capture
                    rd_en   <= 1'b1;
                    rd_cnt  <= rd_cnt + 16'd1;
                    if (rd_cnt == (rd_len_o - 16'd1)) est <= 2'd2;
                end
            end
            2'd2: begin
                rd_en         <= 1'b0;
                rd_frame_done <= 1'b1;
                rd_busy_r     <= 1'b0;
                u_rd_frame_cnt<= u_rd_frame_cnt + 16'd1;
                est           <= 2'd0;
            end
            default: est <= 2'd0;
            endcase
        end
    end

    assign ro_u_rd_frame = u_rd_frame_cnt;

    //=========================================================================
    // 5. the AXI4 master + slot table (pure ui_clk)
    //=========================================================================
    axi4_master_bridge #(.SLOT_BASE(SLOT_BASE), .MAX_LEN(MAX_LEN)) u_bridge (
        .clk(ui_clk), .rst_n(ui_rst_n), .calib_ok(calib_ok),
        .wf_empty(ub_empty), .wf_data(ub_dout), .wf_level(ub_rl), .wf_rd_en(ub_rd_en),
        .wd_empty(ud_empty), .wd_data(ud_dout), .wd_rd_en(ud_rd_en),
        .rf_wr_en(rb_wr_en), .rf_wr_data(rb_din),
        .rc_empty(uc_empty), .rc_data(uc_dout), .rc_rd_en(uc_rd_en),
        .rd_wr_en(rdesc_wr_en), .rd_wr_data(rdesc_din),
        .stat_wm(ro_wm), .stat_wr_frame(ro_wr_frame), .stat_wr_stall(ro_wr_stall),
        .stat_rd_frame(ro_rd_frame), .stat_ill_rd(ro_ill_rd), .stat_noframe(ro_noframe),
        .stat_bresp_err(ro_bresp_err), .stat_len_err(ro_len_err),
        .stat_outstanding(ro_outstanding),
        .dbg_wr_slot(ro_dbg_wr_slot), .dbg_rd_slot(ro_dbg_rd_slot),
        .dbg_wr_cycles(dbg_wr_cycles), .dbg_rd_cycles(dbg_rd_cycles),
        .dbg_wr_beats(dbg_wr_beats), .dbg_rd_beats(dbg_rd_beats),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        // A1 sideband passthrough (37-signal AXI4 contract, see W3 前置清单 §五)
        .m_axi_awid(m_axi_awid), .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot),
        .m_axi_awqos(m_axi_awqos), .m_axi_bid(m_axi_bid),
        .m_axi_arid(m_axi_arid), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos), .m_axi_rid(m_axi_rid));

endmodule
