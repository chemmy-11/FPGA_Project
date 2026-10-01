//=============================================================================
// w3_uiclk_top.v -- W3 A4/A5 PRE-FLIGHT: bridge + REAL MIG in one project
// prj10 W3 (2026-10-01)
//-----------------------------------------------------------------------------
// WHY this top exists (and what it is NOT):
//   B2 of the W3 blocker list says "MIG timing has ZERO margin (WNS=+0.024 ns):
//   any new logic in the ui_clk domain can flip it negative".  The question can
//   be answered WITHOUT the Aurora/ethernet half, because
//      - the new logic (frame_mem_if + axi4_master_bridge) lives in ui_clk,
//      - the real ddr4_0 is instantiated with its real 37-signal s_axi,
//      - the user_clk <-> ui_clk CDC inside frame_mem_if is included.
//   So this project measures the ONLY new timing risk.  The full prj9+prj10
//   integration project (Aurora x2 + ethernet stack + pump + pack) is the
//   documented A4 follow-up; it reuses this exact IP + bridge wiring.
//
// Frame side is driven by a cheap LFSR frame generator so the bridge logic is
// NOT pruned by synthesis (constants would optimise the FSMs away).
//=============================================================================
`timescale 1ns/1ps

module w3_uiclk_top (
    // ---- DDR4 physical interface (same names as prj4 mig_verify_top) ----
    inout  [63:0] c0_ddr4_dq,
    inout  [7:0]  c0_ddr4_dqs_t,
    inout  [7:0]  c0_ddr4_dqs_c,
    inout  [7:0]  c0_ddr4_dm_dbi_n,
    output [16:0] c0_ddr4_adr,
    output [1:0]  c0_ddr4_ba,
    output [0:0]  c0_ddr4_bg,
    output [0:0]  c0_ddr4_cke,
    output [0:0]  c0_ddr4_cs_n,
    output [0:0]  c0_ddr4_odt,
    output [0:0]  c0_ddr4_ck_t,
    output [0:0]  c0_ddr4_ck_c,
    output        c0_ddr4_reset_n,
    output        c0_ddr4_act_n,
    // ---- clocks / reset / status ----
    input         sys_clk_p,        // AK17 100 MHz diff (MIG system clock)
    input         sys_clk_n,        // AK16
    input         sys_rst_btn,      // AC34 active-low board reset button
    output        led_calib,        // T22
    output        led_pass          // T23 (name kept identical to prj4 XDC)
);

    // ------------------------------------------------------------------
    // MIG
    // ------------------------------------------------------------------
    wire        calib;
    wire        ui_clk;
    wire        ui_sync_rst;
    wire [511:0] dbg_bus;

    wire sys_rst = ~sys_rst_btn;          // MIG expects active-high sys_rst
    wire ui_rst_n = ~ui_sync_rst;
    wire c0_ddr4_aresetn = ui_rst_n;

    // free-running "user" clock (~150 MHz) from the same 100 MHz reference is
    // not available here without an MMCM; the frame side is therefore driven by
    // a divided ui_clk.  This is a PRE-FLIGHT simplification: it keeps the CDC
    // FIFOs (two clock domains) real while avoiding an extra clocking IP.
    reg [1:0] udiv = 2'd0;
    always @(posedge ui_clk or negedge ui_rst_n)
        if (!ui_rst_n) udiv <= 2'd0;
        else           udiv <= udiv + 2'd1;
    wire user_clk   = udiv[1];            // ui_clk / 4  (~75 MHz)
    reg  [3:0] urst_cnt = 4'd0;
    always @(posedge user_clk) if (urst_cnt != 4'hF) urst_cnt <= urst_cnt + 4'd1;
    wire user_rst_n = (urst_cnt == 4'hF);

    // ------------------------------------------------------------------
    // frame-side traffic generator (LFSR, keeps the bridge logic alive)
    // ------------------------------------------------------------------
    reg  [15:0] lfsr = 16'hACE1;
    always @(posedge user_clk or negedge user_rst_n)
        if (!user_rst_n) lfsr <= 16'hACE1;
        else             lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    reg  [11:0] fcnt = 12'd0;             // bytes sent in the current frame
    reg  [11:0] flen = 12'd1466;          // frame length (rotates)
    reg         fen  = 1'b0;
    reg  [3:0]  fidx = 4'd0;
    always @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n) begin
            fcnt <= 12'd0; fen <= 1'b0; fidx <= 4'd0; flen <= 12'd1466;
        end else begin
            if (!fen) begin
                if (calib) fen <= 1'b1;            // start after calibration
            end else if (fcnt == flen - 12'd1) begin
                fen  <= 1'b0;
                fcnt <= 12'd0;
                fidx <= fidx + 4'd1;
                case (fidx)
                    4'd0: flen <= 12'd26;
                    4'd1: flen <= 12'd1000;
                    4'd2: flen <= 12'd1466;
                    default: flen <= 12'd1538;
                endcase
            end else begin
                fcnt <= fcnt + 12'd1;
            end
        end
    end

    wire [7:0] wr_data = lfsr[7:0];
    wire       wr_en   = fen;
    wire       wr_hold;

    wire [7:0]  rd_data;  wire rd_en;   wire rd_frame_done; wire rd_busy;
    reg         rd_req = 1'b0;
    reg  [15:0] rd_pause = 16'd0;
    always @(posedge user_clk or negedge user_rst_n)
        if (!user_rst_n) begin rd_req <= 1'b0; rd_pause <= 16'd0; end
        else if (rd_frame_done) begin rd_req <= 1'b0; rd_pause <= 16'h0800; end
        else if (rd_pause != 16'd0) rd_pause <= rd_pause - 16'd1;
        else rd_req <= 1'b1;

    // ------------------------------------------------------------------
    // bridge (user_clk <-> ui_clk)
    // ------------------------------------------------------------------
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

    wire [15:0] ro_wm, ro_wr_frame, ro_wr_stall, ro_rd_frame, ro_ill_rd, ro_noframe, ro_bresp_err, ro_len_err;
    wire [8:0]  ro_outstanding;
    wire [7:0]  ro_dbg_wr_slot, ro_dbg_rd_slot;
    wire [31:0] dbg_wr_cycles, dbg_rd_cycles, dbg_wr_beats, dbg_rd_beats;
    wire [15:0] ro_u_wr_frame, ro_u_rd_frame, ro_u_buf_drop;
    wire [31:0] ro_u_hold_cycles;
    wire [8:0]  ro_outstanding_sync;

    frame_mem_if #(.SLOT_BASE(32'h0010_0000), .MAX_LEN(16'd1538)) u_bridge (
        .user_clk(user_clk), .user_rst_n(user_rst_n),
        .wr_data(wr_data), .wr_en(wr_en), .wr_hold(wr_hold),
        .rd_data(rd_data), .rd_en(rd_en), .rd_slot_o(ro_dbg_rd_slot),
        .rd_len_o(), .rd_frame_done(rd_frame_done), .rd_req(rd_req), .rd_busy(rd_busy),
        .cfg_mode(1'b0), .cfg_rd_slot(8'h00),
        .ro_u_wr_frame(ro_u_wr_frame), .ro_u_rd_frame(ro_u_rd_frame),
        .ro_u_buf_drop(ro_u_buf_drop), .ro_u_hold_cycles(ro_u_hold_cycles),
        .ro_outstanding_sync(ro_outstanding_sync),
        .ui_clk(ui_clk), .ui_rst_n(ui_rst_n), .calib_ok(calib),
        .ro_wm(ro_wm), .ro_wr_frame(ro_wr_frame), .ro_wr_stall(ro_wr_stall),
        .ro_rd_frame(ro_rd_frame), .ro_ill_rd(ro_ill_rd), .ro_noframe(ro_noframe),
        .ro_bresp_err(ro_bresp_err), .ro_len_err(ro_len_err),
        .ro_outstanding(ro_outstanding),
        .ro_dbg_wr_slot(ro_dbg_wr_slot), .ro_dbg_rd_slot(ro_dbg_rd_slot),
        .dbg_wr_cycles(dbg_wr_cycles), .dbg_rd_cycles(dbg_rd_cycles),
        .dbg_wr_beats(dbg_wr_beats), .dbg_rd_beats(dbg_rd_beats),
        .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
        .m_axi_awid(m_awid), .m_axi_awlock(m_awlock), .m_axi_awcache(m_awcache),
        .m_axi_awprot(m_awprot), .m_axi_awqos(m_awqos), .m_axi_bid(m_bid),
        .m_axi_arid(m_arid), .m_axi_arlock(m_arlock), .m_axi_arcache(m_arcache),
        .m_axi_arprot(m_arprot), .m_axi_arqos(m_arqos), .m_axi_rid(m_rid));

    // ------------------------------------------------------------------
    // real MIG (37-signal s_axi -- the A1 port completion is what makes this
    // instantiation legal; against a 25-port bridge it does not elaborate)
    // ------------------------------------------------------------------
    ddr4_0 u_ddr4 (
        .sys_rst(sys_rst),
        .c0_sys_clk_p(sys_clk_p), .c0_sys_clk_n(sys_clk_n),
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
        .dbg_clk(), .c0_ddr4_aresetn(c0_ddr4_aresetn),
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

    // ------------------------------------------------------------------
    // LEDs + keep-alive for the read path
    // ------------------------------------------------------------------
    assign led_calib = calib;
    assign led_pass  = ro_rd_frame[0];

    // Keep the read-data path observable so it is not optimised away.
    reg [7:0] rd_seen = 8'h00;
    always @(posedge user_clk) if (rd_en) rd_seen <= rd_data;
    wire unused = ^{rd_seen, rd_busy, wr_hold, ro_outstanding_sync, ro_ill_rd,
                    ro_noframe, ro_bresp_err, ro_len_err, ro_wr_stall,
                    dbg_wr_cycles, dbg_rd_cycles, dbg_wr_beats, dbg_rd_beats,
                    ro_u_wr_frame, ro_u_rd_frame, ro_u_buf_drop, ro_u_hold_cycles,
                    ro_dbg_wr_slot, ro_outstanding, ro_wm, ro_wr_frame};

endmodule
