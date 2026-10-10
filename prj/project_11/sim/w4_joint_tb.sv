//=============================================================================
// w4_joint_tb.sv -- prj10 W4 joint testbench (two bridges + arbiter + RAM, xsim)
//-----------------------------------------------------------------------------
// Purpose: system-level gate the W3/W4 unit benches cannot cover --
//   bridge-1 and bridge-2 share ONE AXI4 slave (RAM stand-in for MIG) through
//   axi_arb_2to1. The 2026-10-07 routing defect (B/R responses routed by
//   bid/rid[0] while both bridges drive constant IDs awid=0/arid=1) is exactly
//   the class of bug only a joint bench sees: every write response went to
//   bridge-1 and every read response to bridge-2, deadlocking both FSMs.
//
// Judged criteria:
//   J-A  interleave byte-exactness : N frames pushed into EACH bridge
//                                    (alternating), all 2N read back SEQ,
//                                    byte-exact, bridge-tagged frames never
//                                    cross between bridges
//   J-B  concurrent service        : both bridges have in-flight AXI traffic
//                                    in the same ui_clk window (observed via
//                                    both bridges' ro_outstanding != 0 at once,
//                                    and monitor beat counters advancing for
//                                    both address regions)
//   J-C  account closure           : per bridge wr_frame == rd_frame == wm
//                                    after drain; bresp_err/len_err == 0
//   J-D  protocol                  : 4k_violation == 0, axi_proto_err == 0
//   J-X  negative control (defect) : elaborated with DEFECT_ROUTING=1 the OLD
//          (bid/0, rid/0) routing is restored and the bench MUST fail/timeout
//          -- proves the pass verdict is not vacuous.
//
// Clocks: user 151.5 MHz, ui 300 MHz (same as W2 bench, two real domains).
//=============================================================================
`timescale 1ns / 1ps

module w4_joint_tb #(
    parameter integer AR_LAT_T     = 8,    // read first-beat latency (ui cycles)
    parameter integer W_DLY_T      = 0,    // extra write-response delay
    parameter bit     DEFECT_ROUTING = 0   // J-X: 1 = restore pre-fix routing
)();

    // ---------------- clocks ----------------
    reg user_clk = 1'b0;
    reg ui_clk   = 1'b0;
    always #3.3     user_clk = ~user_clk;   // 151.5 MHz
    always #1.6665  ui_clk   = ~ui_clk;     // 300 MHz

    reg user_rst_n = 1'b0;
    reg ui_rst_n   = 1'b0;
    reg calib_ok   = 1'b0;

    // ============ bridge A (INGRESS 0x0010_0000) frame side ============
    reg  [7:0]  wrA_data = 8'h00;
    reg         wrA_en   = 1'b0;
    wire        wrA_hold;
    wire [7:0]  rdA_data;
    wire        rdA_en;
    wire [7:0]  rdA_slot_o;
    wire [15:0] rdA_len_o;
    wire        rdA_frame_done, rdA_busy;
    reg         rdA_req = 1'b0;
    wire [15:0] A_u_wr, A_u_rd, A_u_drop;
    wire [31:0] A_u_hold;
    wire [8:0]  A_ost_sync;
    wire [15:0] A_wm, A_wr_frm, A_stall, A_rd_frm, A_ill, A_noframe, A_bresp, A_len_err;
    wire [8:0]  A_ost;
    wire [7:0]  A_wslot, A_rslot;
    wire [31:0] A_wcyc, A_rcyc, A_wbeats, A_rbeats;

    wire [3:0]   a_awid, a_bid, a_arid, a_rid;
    wire [0:0]   a_awlock, a_arlock;
    wire [3:0]   a_awcache, a_arcache;
    wire [2:0]   a_awprot, a_arprot;
    wire [3:0]   a_awqos, a_arqos;
    wire [31:0]  a_awaddr, a_araddr;
    wire [7:0]   a_awlen, a_arlen;
    wire [2:0]   a_awsize, a_arsize;
    wire [1:0]   a_awburst, a_arburst;
    wire         a_awvalid, a_awready, a_arvalid, a_arready;
    wire [511:0] a_wdata, a_rdata;
    wire [63:0]  a_wstrb;
    wire         a_wlast, a_wvalid, a_wready;
    wire [1:0]   a_bresp, a_rresp;
    wire         a_bvalid, a_bready, a_rlast, a_rvalid, a_rready;

    // ============ bridge B (EGRESS 0x0020_0000) frame side ============
    reg  [7:0]  wrB_data = 8'h00;
    reg         wrB_en   = 1'b0;
    wire        wrB_hold;
    wire [7:0]  rdB_data;
    wire        rdB_en;
    wire [7:0]  rdB_slot_o;
    wire [15:0] rdB_len_o;
    wire        rdB_frame_done, rdB_busy;
    reg         rdB_req = 1'b0;
    wire [15:0] B_u_wr, B_u_rd, B_u_drop;
    wire [31:0] B_u_hold;
    wire [8:0]  B_ost_sync;
    wire [15:0] B_wm, B_wr_frm, B_stall, B_rd_frm, B_ill, B_noframe, B_bresp, B_len_err;
    wire [8:0]  B_ost;
    wire [7:0]  B_wslot, B_rslot;
    wire [31:0] B_wcyc, B_rcyc, B_wbeats, B_rbeats;

    wire [3:0]   b_awid, b_bid, b_arid, b_rid;
    wire [0:0]   b_awlock, b_arlock;
    wire [3:0]   b_awcache, b_arcache;
    wire [2:0]   b_awprot, b_arprot;
    wire [3:0]   b_awqos, b_arqos;
    wire [31:0]  b_awaddr, b_araddr;
    wire [7:0]   b_awlen, b_arlen;
    wire [2:0]   b_awsize, b_arsize;
    wire [1:0]   b_awburst, b_arburst;
    wire         b_awvalid, b_awready, b_arvalid, b_arready;
    wire [511:0] b_wdata, b_rdata;
    wire [63:0]  b_wstrb;
    wire         b_wlast, b_wvalid, b_wready;
    wire [1:0]   b_bresp, b_rresp;
    wire         b_bvalid, b_bready, b_rlast, b_rvalid, b_rready;

    // ============ arbiter -> RAM (M-side) ============
    wire [3:0]   m_awid, m_bid, m_arid, m_rid;
    wire [0:0]   m_awlock, m_arlock;
    wire [3:0]   m_awcache, m_arcache;
    wire [2:0]   m_awprot, m_arprot;
    wire [3:0]   m_awqos, m_arqos;
    wire [31:0]  m_awaddr, m_araddr;
    wire [7:0]   m_awlen, m_arlen;
    wire [2:0]   m_awsize, m_arsize;
    wire [1:0]   m_awburst, m_arburst;
    wire         m_awvalid, m_awready, m_arvalid, m_arready;
    wire [511:0] m_wdata, m_rdata;
    wire [63:0]  m_wstrb;
    wire         m_wlast, m_wvalid, m_wready;
    wire [1:0]   m_bresp, m_rresp;
    wire         m_bvalid, m_bready, m_rlast, m_rvalid, m_rready;
    wire [31:0]  mon_4k, mon_wb, mon_rb, mon_err;

    // per-bridge AXI activity observers (region split: A writes land at
    // 0x0010_xxxx, B writes at 0x0020_xxxx -> AWADDR[24:20] tells who)
    int a_beats = 0, b_beats = 0;
    always @(posedge ui_clk) begin
        if (m_wvalid && m_wready) begin
            if (m_awaddr[24:20] == 5'h01) a_beats = a_beats + 1;
            else if (m_awaddr[24:20] == 5'h02) b_beats = b_beats + 1;
        end
    end

    // ============ DUTs ============
    frame_mem_if #(.SLOT_BASE(32'h0010_0000), .MAX_LEN(16'd1538)) u_memA (
        .user_clk(user_clk), .user_rst_n(user_rst_n),
        .wr_data(wrA_data), .wr_en(wrA_en), .wr_hold(wrA_hold),
        .rd_data(rdA_data), .rd_en(rdA_en), .rd_slot_o(rdA_slot_o), .rd_len_o(rdA_len_o),
        .rd_frame_done(rdA_frame_done), .rd_req(rdA_req), .rd_busy(rdA_busy),
        .cfg_mode(1'b0), .cfg_rd_slot(8'h00),
        .ro_u_wr_frame(A_u_wr), .ro_u_rd_frame(A_u_rd), .ro_u_buf_drop(A_u_drop),
        .ro_u_hold_cycles(A_u_hold), .ro_outstanding_sync(A_ost_sync),
        .ui_clk(ui_clk), .ui_rst_n(ui_rst_n), .calib_ok(calib_ok),
        .ro_wm(A_wm), .ro_wr_frame(A_wr_frm), .ro_wr_stall(A_stall),
        .ro_rd_frame(A_rd_frm), .ro_ill_rd(A_ill), .ro_noframe(A_noframe),
        .ro_bresp_err(A_bresp), .ro_len_err(A_len_err), .ro_outstanding(A_ost),
        .ro_dbg_wr_slot(A_wslot), .ro_dbg_rd_slot(A_rslot),
        .dbg_wr_cycles(A_wcyc), .dbg_rd_cycles(A_rcyc),
        .dbg_wr_beats(A_wbeats), .dbg_rd_beats(A_rbeats),
        .m_axi_awid(a_awid), .m_axi_awaddr(a_awaddr), .m_axi_awlen(a_awlen),
        .m_axi_awsize(a_awsize), .m_axi_awburst(a_awburst),
        .m_axi_awlock(a_awlock), .m_axi_awcache(a_awcache), .m_axi_awprot(a_awprot),
        .m_axi_awqos(a_awqos), .m_axi_awvalid(a_awvalid), .m_axi_awready(a_awready),
        .m_axi_wdata(a_wdata), .m_axi_wstrb(a_wstrb), .m_axi_wlast(a_wlast),
        .m_axi_wvalid(a_wvalid), .m_axi_wready(a_wready),
        .m_axi_bresp(a_bresp), .m_axi_bvalid(a_bvalid), .m_axi_bready(a_bready),
        .m_axi_bid(a_bid),
        .m_axi_arid(a_arid), .m_axi_araddr(a_araddr), .m_axi_arlen(a_arlen),
        .m_axi_arsize(a_arsize), .m_axi_arburst(a_arburst),
        .m_axi_arlock(a_arlock), .m_axi_arcache(a_arcache), .m_axi_arprot(a_arprot),
        .m_axi_arqos(a_arqos), .m_axi_arvalid(a_arvalid), .m_axi_arready(a_arready),
        .m_axi_rdata(a_rdata), .m_axi_rresp(a_rresp), .m_axi_rlast(a_rlast),
        .m_axi_rvalid(a_rvalid), .m_axi_rready(a_rready), .m_axi_rid(a_rid));

    frame_mem_if #(.SLOT_BASE(32'h0020_0000), .MAX_LEN(16'd1538)) u_memB (
        .user_clk(user_clk), .user_rst_n(user_rst_n),
        .wr_data(wrB_data), .wr_en(wrB_en), .wr_hold(wrB_hold),
        .rd_data(rdB_data), .rd_en(rdB_en), .rd_slot_o(rdB_slot_o), .rd_len_o(rdB_len_o),
        .rd_frame_done(rdB_frame_done), .rd_req(rdB_req), .rd_busy(rdB_busy),
        .cfg_mode(1'b0), .cfg_rd_slot(8'h00),
        .ro_u_wr_frame(B_u_wr), .ro_u_rd_frame(B_u_rd), .ro_u_buf_drop(B_u_drop),
        .ro_u_hold_cycles(B_u_hold), .ro_outstanding_sync(B_ost_sync),
        .ui_clk(ui_clk), .ui_rst_n(ui_rst_n), .calib_ok(calib_ok),
        .ro_wm(B_wm), .ro_wr_frame(B_wr_frm), .ro_wr_stall(B_stall),
        .ro_rd_frame(B_rd_frm), .ro_ill_rd(B_ill), .ro_noframe(B_noframe),
        .ro_bresp_err(B_bresp), .ro_len_err(B_len_err), .ro_outstanding(B_ost),
        .ro_dbg_wr_slot(B_wslot), .ro_dbg_rd_slot(B_rslot),
        .dbg_wr_cycles(B_wcyc), .dbg_rd_cycles(B_rcyc),
        .dbg_wr_beats(B_wbeats), .dbg_rd_beats(B_rbeats),
        .m_axi_awid(b_awid), .m_axi_awaddr(b_awaddr), .m_axi_awlen(b_awlen),
        .m_axi_awsize(b_awsize), .m_axi_awburst(b_awburst),
        .m_axi_awlock(b_awlock), .m_axi_awcache(b_awcache), .m_axi_awprot(b_awprot),
        .m_axi_awqos(b_awqos), .m_axi_awvalid(b_awvalid), .m_axi_awready(b_awready),
        .m_axi_wdata(b_wdata), .m_axi_wstrb(b_wstrb), .m_axi_wlast(b_wlast),
        .m_axi_wvalid(b_wvalid), .m_axi_wready(b_wready),
        .m_axi_bresp(b_bresp), .m_axi_bvalid(b_bvalid), .m_axi_bready(b_bready),
        .m_axi_bid(b_bid),
        .m_axi_arid(b_arid), .m_axi_araddr(b_araddr), .m_axi_arlen(b_arlen),
        .m_axi_arsize(b_arsize), .m_axi_arburst(b_arburst),
        .m_axi_arlock(b_arlock), .m_axi_arcache(b_arcache), .m_axi_arprot(b_arprot),
        .m_axi_arqos(b_arqos), .m_axi_arvalid(b_arvalid), .m_axi_arready(b_arready),
        .m_axi_rdata(b_rdata), .m_axi_rresp(b_rresp), .m_axi_rlast(b_rlast),
        .m_axi_rvalid(b_rvalid), .m_axi_rready(b_rready), .m_axi_rid(b_rid));

    generate
        if (DEFECT_ROUTING) begin : g_defect
            // J-X negative control: the PRE-FIX router (responses by bid/rid bit0)
            axi_arb_2to1_defect u_arb (
                .clk(ui_clk), .rst_n(ui_rst_n),
                .s00_axi_awid(a_awid), .s00_axi_awaddr(a_awaddr), .s00_axi_awlen(a_awlen),
                .s00_axi_awsize(a_awsize), .s00_axi_awburst(a_awburst), .s00_axi_awlock(a_awlock),
                .s00_axi_awcache(a_awcache), .s00_axi_awprot(a_awprot), .s00_axi_awqos(a_awqos),
                .s00_axi_awvalid(a_awvalid), .s00_axi_awready(a_awready),
                .s00_axi_wdata(a_wdata), .s00_axi_wstrb(a_wstrb), .s00_axi_wlast(a_wlast),
                .s00_axi_wvalid(a_wvalid), .s00_axi_wready(a_wready),
                .s00_axi_bresp(a_bresp), .s00_axi_bvalid(a_bvalid), .s00_axi_bready(a_bready), .s00_axi_bid(a_bid),
                .s00_axi_arid(a_arid), .s00_axi_araddr(a_araddr), .s00_axi_arlen(a_arlen),
                .s00_axi_arsize(a_arsize), .s00_axi_arburst(a_arburst), .s00_axi_arlock(a_arlock),
                .s00_axi_arcache(a_arcache), .s00_axi_arprot(a_arprot), .s00_axi_arqos(a_arqos),
                .s00_axi_arvalid(a_arvalid), .s00_axi_arready(a_arready),
                .s00_axi_rdata(a_rdata), .s00_axi_rresp(a_rresp), .s00_axi_rlast(a_rlast),
                .s00_axi_rvalid(a_rvalid), .s00_axi_rready(a_rready), .s00_axi_rid(a_rid),
                .s01_axi_awid(b_awid), .s01_axi_awaddr(b_awaddr), .s01_axi_awlen(b_awlen),
                .s01_axi_awsize(b_awsize), .s01_axi_awburst(b_awburst), .s01_axi_awlock(b_awlock),
                .s01_axi_awcache(b_awcache), .s01_axi_awprot(b_awprot), .s01_axi_awqos(b_awqos),
                .s01_axi_awvalid(b_awvalid), .s01_axi_awready(b_awready),
                .s01_axi_wdata(b_wdata), .s01_axi_wstrb(b_wstrb), .s01_axi_wlast(b_wlast),
                .s01_axi_wvalid(b_wvalid), .s01_axi_wready(b_wready),
                .s01_axi_bresp(b_bresp), .s01_axi_bvalid(b_bvalid), .s01_axi_bready(b_bready), .s01_axi_bid(b_bid),
                .s01_axi_arid(b_arid), .s01_axi_araddr(b_araddr), .s01_axi_arlen(b_arlen),
                .s01_axi_arsize(b_arsize), .s01_axi_arburst(b_arburst), .s01_axi_arlock(b_arlock),
                .s01_axi_arcache(b_arcache), .s01_axi_arprot(b_arprot), .s01_axi_arqos(b_arqos),
                .s01_axi_arvalid(b_arvalid), .s01_axi_arready(b_arready),
                .s01_axi_rdata(b_rdata), .s01_axi_rresp(b_rresp), .s01_axi_rlast(b_rlast),
                .s01_axi_rvalid(b_rvalid), .s01_axi_rready(b_rready), .s01_axi_rid(b_rid),
                .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen),
                .m_axi_awsize(m_awsize), .m_axi_awburst(m_awburst), .m_axi_awlock(m_awlock),
                .m_axi_awcache(m_awcache), .m_axi_awprot(m_awprot), .m_axi_awqos(m_awqos),
                .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
                .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
                .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
                .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready), .m_axi_bid(m_bid),
                .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
                .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst), .m_axi_arlock(m_arlock),
                .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot), .m_axi_arqos(m_arqos),
                .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
                .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
                .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready), .m_axi_rid(m_rid));
        end else begin : g_fixed
            axi_arb_2to1 u_arb (
                .clk(ui_clk), .rst_n(ui_rst_n),
                .s00_axi_awid(a_awid), .s00_axi_awaddr(a_awaddr), .s00_axi_awlen(a_awlen),
                .s00_axi_awsize(a_awsize), .s00_axi_awburst(a_awburst), .s00_axi_awlock(a_awlock),
                .s00_axi_awcache(a_awcache), .s00_axi_awprot(a_awprot), .s00_axi_awqos(a_awqos),
                .s00_axi_awvalid(a_awvalid), .s00_axi_awready(a_awready),
                .s00_axi_wdata(a_wdata), .s00_axi_wstrb(a_wstrb), .s00_axi_wlast(a_wlast),
                .s00_axi_wvalid(a_wvalid), .s00_axi_wready(a_wready),
                .s00_axi_bresp(a_bresp), .s00_axi_bvalid(a_bvalid), .s00_axi_bready(a_bready), .s00_axi_bid(a_bid),
                .s00_axi_arid(a_arid), .s00_axi_araddr(a_araddr), .s00_axi_arlen(a_arlen),
                .s00_axi_arsize(a_arsize), .s00_axi_arburst(a_arburst), .s00_axi_arlock(a_arlock),
                .s00_axi_arcache(a_arcache), .s00_axi_arprot(a_arprot), .s00_axi_arqos(a_arqos),
                .s00_axi_arvalid(a_arvalid), .s00_axi_arready(a_arready),
                .s00_axi_rdata(a_rdata), .s00_axi_rresp(a_rresp), .s00_axi_rlast(a_rlast),
                .s00_axi_rvalid(a_rvalid), .s00_axi_rready(a_rready), .s00_axi_rid(a_rid),
                .s01_axi_awid(b_awid), .s01_axi_awaddr(b_awaddr), .s01_axi_awlen(b_awlen),
                .s01_axi_awsize(b_awsize), .s01_axi_awburst(b_awburst), .s01_axi_awlock(b_awlock),
                .s01_axi_awcache(b_awcache), .s01_axi_awprot(b_awprot), .s01_axi_awqos(b_awqos),
                .s01_axi_awvalid(b_awvalid), .s01_axi_awready(b_awready),
                .s01_axi_wdata(b_wdata), .s01_axi_wstrb(b_wstrb), .s01_axi_wlast(b_wlast),
                .s01_axi_wvalid(b_wvalid), .s01_axi_wready(b_wready),
                .s01_axi_bresp(b_bresp), .s01_axi_bvalid(b_bvalid), .s01_axi_bready(b_bready), .s01_axi_bid(b_bid),
                .s01_axi_arid(b_arid), .s01_axi_araddr(b_araddr), .s01_axi_arlen(b_arlen),
                .s01_axi_arsize(b_arsize), .s01_axi_arburst(b_arburst), .s01_axi_arlock(b_arlock),
                .s01_axi_arcache(b_arcache), .s01_axi_arprot(b_arprot), .s01_axi_arqos(b_arqos),
                .s01_axi_arvalid(b_arvalid), .s01_axi_arready(b_arready),
                .s01_axi_rdata(b_rdata), .s01_axi_rresp(b_rresp), .s01_axi_rlast(b_rlast),
                .s01_axi_rvalid(b_rvalid), .s01_axi_rready(b_rready), .s01_axi_rid(b_rid),
                .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen),
                .m_axi_awsize(m_awsize), .m_axi_awburst(m_awburst), .m_axi_awlock(m_awlock),
                .m_axi_awcache(m_awcache), .m_axi_awprot(m_awprot), .m_axi_awqos(m_awqos),
                .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
                .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
                .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
                .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready), .m_axi_bid(m_bid),
                .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
                .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst), .m_axi_arlock(m_arlock),
                .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot), .m_axi_arqos(m_arqos),
                .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
                .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
                .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready), .m_axi_rid(m_rid));
        end
    endgenerate

    // 2 MB covers both slot regions (0x0010_0000 + 0x0020_0000, AW=21)
    axi4_ram_model #(.MEM_BYTES(1<<21), .AW(21), .AR_LAT(AR_LAT_T),
                     .W_RESP_DLY(W_DLY_T), .STALL_EN(1)) u_ram (
        .clk(ui_clk), .rst_n(ui_rst_n),
        .s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awsize(m_awsize), .s_awburst(m_awburst),
        .s_awvalid(m_awvalid), .s_awready(m_awready),
        .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast),
        .s_wvalid(m_wvalid), .s_wready(m_wready),
        .s_bresp(m_bresp), .s_bvalid(m_bvalid), .s_bready(m_bready),
        .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arsize(m_arsize), .s_arburst(m_arburst),
        .s_arvalid(m_arvalid), .s_arready(m_arready),
        .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rlast(m_rlast),
        .s_rvalid(m_rvalid), .s_rready(m_rready),
        .s_awid(m_awid), .s_awlock(m_awlock), .s_awcache(m_awcache),
        .s_awprot(m_awprot), .s_awqos(m_awqos), .s_bid(m_bid),
        .s_arid(m_arid), .s_arlock(m_arlock), .s_arcache(m_arcache),
        .s_arprot(m_arprot), .s_arqos(m_arqos), .s_rid(m_rid),
        .mon_4k(mon_4k), .mon_wb(mon_wb), .mon_rb(mon_rb), .mon_err(mon_err));

    // ============ helpers ============
    int errs = 0;

    function automatic logic [7:0] patA(input int fid, input int i);
        patA = (16'hA500 + fid*37 + i*11 + (i >> 4)) & 32'h000000FF;
    endfunction
    function automatic logic [7:0] patB(input int fid, input int i);
        patB = (16'hB700 + fid*53 + i*13 + (i >> 3)) & 32'h000000FF;
    endfunction

    task automatic fail(input string tag);
        $display("[FAIL] %s", tag);
        errs = errs + 1;
    endtask

    // push one frame into bridge A (or B); frame boundary = wr_en falling edge
    task automatic sendA(input int fid, input int len);
        int i;
        @(negedge user_clk);
        wrA_en = 1'b1; wrA_data = patA(fid, 0);
        for (i = 1; i < len; i = i + 1) begin
            @(negedge user_clk);
            wrA_data = patA(fid, i);
        end
        @(negedge user_clk);
        wrA_en = 1'b0; wrA_data = 8'h00;
        repeat (2) @(negedge user_clk);
    endtask
    task automatic sendB(input int fid, input int len);
        int i;
        @(negedge user_clk);
        wrB_en = 1'b1; wrB_data = patB(fid, 0);
        for (i = 1; i < len; i = i + 1) begin
            @(negedge user_clk);
            wrB_data = patB(fid, i);
        end
        @(negedge user_clk);
        wrB_en = 1'b0; wrB_data = 8'h00;
        repeat (2) @(negedge user_clk);
    endtask

    // collect one frame from bridge A (or B); returns length via output
    task automatic recvA(output int rlen);
        int t = 0;
        rlen = 0;
        forever begin
            @(negedge user_clk);
            if (rdA_en === 1'b1) rlen = rlen + 1;
            if (rdA_frame_done === 1'b1) break;
            t = t + 1;
            if (t > 60000) begin fail("recvA timeout"); break; end
        end
        repeat (2) @(negedge user_clk);
    endtask
    task automatic recvB(output int rlen);
        int t = 0;
        rlen = 0;
        forever begin
            @(negedge user_clk);
            if (rdB_en === 1'b1) rlen = rlen + 1;
            if (rdB_frame_done === 1'b1) break;
            t = t + 1;
            if (t > 60000) begin fail("recvB timeout"); break; end
        end
        repeat (2) @(negedge user_clk);
    endtask

    // per-frame byte capture into a shadow buffer (called during recv)
    int capA_len = 0; logic [7:0] capA [0:2047];
    int capB_len = 0; logic [7:0] capB [0:2047];
    always @(posedge user_clk) begin
        if (rdA_en) begin
            if (capA_len < 2048) capA[capA_len] <= rdA_data;
            capA_len <= capA_len + 1;
        end
    end
    always @(posedge user_clk) begin
        if (rdB_en) begin
            if (capB_len < 2048) capB[capB_len] <= rdB_data;
            capB_len <= capB_len + 1;
        end
    end

    task automatic checkA(input int fid, input int elen, input string tag);
        int i;
        if (capA_len != elen) begin
            $display("[FAIL] %s len fid=%0d got=%0d exp=%0d", tag, fid, capA_len, elen);
            errs = errs + 1;
        end
        for (i = 0; i < elen && i < capA_len; i = i + 1)
            if (capA[i] !== patA(fid, i)) begin
                $display("[FAIL] %s byte fid=%0d @%0d got=%02x exp=%02x", tag, fid, i, capA[i], patA(fid,i));
                errs = errs + 1; i = elen;
            end
    endtask
    task automatic checkB(input int fid, input int elen, input string tag);
        int i;
        if (capB_len != elen) begin
            $display("[FAIL] %s len fid=%0d got=%0d exp=%0d", tag, fid, capB_len, elen);
            errs = errs + 1;
        end
        for (i = 0; i < elen && i < capB_len; i = i + 1)
            if (capB[i] !== patB(fid, i)) begin
                $display("[FAIL] %s byte fid=%0d @%0d got=%02x exp=%02x", tag, fid, i, capB[i], patB(fid,i));
                errs = errs + 1; i = elen;
            end
    endtask

    task automatic wait_commit(input int targetA, input int targetB);
        int t = 0;
        while ((A_wr_frm < targetA || B_wr_frm < targetB) && t < 400000) begin
            @(posedge ui_clk); t = t + 1;
        end
        if (t >= 400000) fail("wait_commit timeout (bridge stalled?)");
    endtask

    // read request control: TB-issued pulses in controlled phases (P1..P4);
    // in the final pipeline phase (P5) a free-running generator mirrors the
    // real top level and only account closure is judged (byte capture cannot
    // follow a free-running stream -- that is by design, not a coverage gap:
    // byte-exactness is fully judged in P1..P4).
    reg pipeline_mode = 1'b0;
    always @(posedge user_clk) begin
        if (!user_rst_n) begin
            rdA_req <= 1'b0; rdB_req <= 1'b0;
        end else if (pipeline_mode) begin
            rdA_req <= (A_ost_sync != 9'd0) && !rdA_busy && !rdA_req;
            rdB_req <= (B_ost_sync != 9'd0) && !rdB_busy && !rdB_req;
        end else begin
            rdA_req <= 1'b0; rdB_req <= 1'b0;
        end
    end

    task automatic issue_rdA;
        int t = 0;
        while ((rdA_busy === 1'b1 || A_ost_sync === 9'd0) && t < 20000) begin
            @(negedge user_clk); t = t + 1;
        end
        if (t >= 20000) begin fail("issue_rdA: no outstanding frame / busy stuck"); return; end
        @(negedge user_clk); rdA_req = 1'b1;
        @(negedge user_clk); rdA_req = 1'b0;
    endtask
    task automatic issue_rdB;
        int t = 0;
        while ((rdB_busy === 1'b1 || B_ost_sync === 9'd0) && t < 20000) begin
            @(negedge user_clk); t = t + 1;
        end
        if (t >= 20000) begin fail("issue_rdB: no outstanding frame / busy stuck"); return; end
        @(negedge user_clk); rdB_req = 1'b1;
        @(negedge user_clk); rdB_req = 1'b0;
    endtask

    // ============ main ============
    int N = 12;               // frames per bridge
    int lensA [0:11];
    int lensB [0:11];
    int k, rl;
    int e0;
    bit both_busy_seen;       // J-B: concurrency witness (latched, see monitor below)
    // free-running J-B monitor: latches 1 the first time both bridges carry
    // outstanding DDR transactions in the same ui cycle (true concurrency of
    // the shared arbiter, impossible to witness by point-sampling between reads)
    always @(posedge ui_clk) begin
        if (A_ost != 0 && B_ost != 0) both_busy_seen = 1'b1;
    end
    int a_beats0, b_beats0;

    initial begin
        // deterministic mixed lengths, %8 remainders varied per bridge
        lensA[0]=26;  lensA[1]=33;  lensA[2]=40;  lensA[3]=63;
        lensA[4]=100; lensA[5]=200; lensA[6]=1000; lensA[7]=1466;
        lensA[8]=1472; lensA[9]=77; lensA[10]=129; lensA[11]=1538;
        lensB[0]=31;  lensB[1]=64;  lensB[2]=97;  lensB[3]=128;
        lensB[4]=256; lensB[5]=512; lensB[6]=900; lensB[7]=1200;
        lensB[8]=1400; lensB[9]=88; lensB[10]=166; lensB[11]=1530;

        $display("=== prj10 W4 joint sim (two bridges + arbiter + 2MB RAM) DEFECT=%0b ===", DEFECT_ROUTING);
        repeat (20) @(posedge user_clk);
        user_rst_n = 1'b1;
        ui_rst_n   = 1'b1;
        repeat (20) @(posedge user_clk);
        calib_ok = 1'b1;
        repeat (50) @(posedge ui_clk);

        // ---------- phase 1+2: interleaved push AND read, byte-exact ----------
        // (interleaving keeps each bridge's 4096-B byte FIFO below the refusal
        //  threshold, same discipline as the W2 single-bridge bench; every
        //  frame is read back and byte-checked the moment it is committed)
        e0 = errs;
        both_busy_seen = 0;
        a_beats0 = a_beats; b_beats0 = b_beats;
        for (k = 0; k < N; k = k + 1) begin
            sendA(k, lensA[k]);
            sendB(k, lensB[k]);
            if ((k % 4) == 3) begin
                // concurrency round: read BOTH bridges back-to-back; the two AXI
                // read transactions overlap in the arbiter (J-B witness).
                // capture buffers are armed BEFORE the requests -- arming after
                // issue_rd* races the bridge's read latency and loses head bytes.
                capA_len = 0; capB_len = 0;
                issue_rdA; issue_rdB;
                fork
                    recvA(rl);
                    recvB(rl);
                join
                checkA(k, lensA[k], "J-A A");
                checkB(k, lensB[k], "J-A B");
            end else begin
                capA_len = 0; issue_rdA; recvA(rl); checkA(k, lensA[k], "J-A A");
                capB_len = 0; issue_rdB; recvB(rl); checkB(k, lensB[k], "J-A B");
            end
        end
        if (A_wr_frm < N || B_wr_frm < N) begin
            $display("[FAIL] P1 commit shortfall A=%0d/%0d B=%0d/%0d", A_wr_frm, N, B_wr_frm, N);
            errs = errs + 1;
        end
        $display("[P1] interleaved push+read %0d+%0d frames, committed A=%0d B=%0d",
                 N, N, A_wr_frm, B_wr_frm);
        if (both_busy_seen) $display("[J-B] both-bridges-busy witnessed (latched during P1/P2)");
        else $display("[J-B] note: both-busy not yet witnessed (re-checked in P3)");
        result("P1/P2 (interleaved push+read, byte-exact, fork/join concurrency)", e0);

        // ---------- phase 3: account closure (mid-run) ----------
        e0 = errs;
        if (!both_busy_seen) fail("J-B: never observed both bridges with outstanding frames");
        if (A_wr_frm !== N) fail("A wr_frame count");
        if (A_rd_frm !== N) fail("A rd_frame count");
        if (A_wm     !== N) fail("A watermark");
        if (B_wr_frm !== N) fail("B wr_frame count");
        if (B_rd_frm !== N) fail("B rd_frame count");
        if (B_wm     !== N) fail("B watermark");
        if (A_bresp  !== 0) fail("A bresp_err != 0");
        if (A_len_err!== 0) fail("A len_err != 0");
        if (B_bresp  !== 0) fail("B bresp_err != 0");
        if (B_len_err!== 0) fail("B len_err != 0");
        if (mon_4k   !== 0) fail("4KB boundary violation");
        if (mon_err  !== 0) fail("AXI protocol error");
        $display("[P3] A: wr=%0d rd=%0d wm=%0d | B: wr=%0d rd=%0d wm=%0d | 4k=%0d proto=%0d",
                 A_wr_frm, A_rd_frm, A_wm, B_wr_frm, B_rd_frm, B_wm, mon_4k, mon_err);
        $display("[P3] beats: A-region=%0d B-region=%0d (both must be >0)",
                 a_beats - a_beats0, b_beats - b_beats0);
        if (a_beats == a_beats0) fail("no AXI write beats in A region");
        if (b_beats == b_beats0) fail("no AXI write beats in B region");
        result("P3 (account closure + protocol)", e0);

        // ---------- phase 4: sustained volume (96 more frames each, still
        // interleaved push+read; 108 total per bridge < 256 slots so wrap
        // semantics stay with the W2 bench -- here we stress the SHARED
        // arbiter under sustained two-master load) ----------
        e0 = errs;
        for (k = 0; k < 96; k = k + 1) begin
            sendA(N + k, 64 + (k % 5) * 200);
            sendB(N + k, 70 + (k % 7) * 180);
            issue_rdA; capA_len = 0; recvA(rl); checkA(N + k, 64 + (k % 5) * 200, "P4 A");
            issue_rdB; capB_len = 0; recvB(rl); checkB(N + k, 70 + (k % 7) * 180, "P4 B");
        end
        if (A_rd_frm !== N + 96) fail("P4 A total read count");
        if (B_rd_frm !== N + 96) fail("P4 B total read count");
        result("P4 (sustained volume, 96 more frames each, still byte-exact)", e0);

        // ---------- phase 5: pipeline mode (free-running reads, closure only) ----------
        // mirrors the real top level: rd_req self-generated; pushes continue
        // while reads drain in parallel. Judged: final account closure and
        // protocol counters (byte capture is not meaningful for a free-
        // running stream; byte-exactness was fully judged in P1..P4).
        e0 = errs;
        pipeline_mode = 1'b1;
        for (k = 0; k < 40; k = k + 1) begin
            sendA(2*N + k, 100 + (k % 9) * 130);
            sendB(2*N + k, 120 + (k % 11) * 110);
        end
        // drain: wait until both bridges are fully idle
        k = 0;
        while ((A_ost != 0 || B_ost != 0 || A_u_wr != A_wr_frm || B_u_wr != B_wr_frm) && k < 400000) begin
            @(posedge ui_clk); k = k + 1;
        end
        if (k >= 400000) fail("P5 drain timeout (pipeline stall?)");
        repeat (2000) @(posedge ui_clk);   // let the last reads retire
        $display("[P5] pipeline drain: A wr=%0d rd=%0d wm=%0d | B wr=%0d rd=%0d wm=%0d",
                 A_wr_frm, A_rd_frm, A_wm, B_wr_frm, B_rd_frm, B_wm);
        if (A_rd_frm !== A_wr_frm) fail("P5 A rd_frame != wr_frame");
        if (B_rd_frm !== B_wr_frm) fail("P5 B rd_frame != wr_frame");
        result("P5 (pipeline mode: free-running reads, account closure)", e0);

        // ---------- verdict ----------
        $display("STAT A: wm=%0d wr=%0d rd=%0d stall=%0d ill=%0d drop=%0d bresp=%0d len_err=%0d",
                 A_wm, A_wr_frm, A_rd_frm, A_stall, A_ill, A_u_drop, A_bresp, A_len_err);
        $display("STAT B: wm=%0d wr=%0d rd=%0d stall=%0d ill=%0d drop=%0d bresp=%0d len_err=%0d",
                 B_wm, B_wr_frm, B_rd_frm, B_stall, B_ill, B_u_drop, B_bresp, B_len_err);
        if (errs == 0) $display("=== prj10 W4 JOINT SIM: PASS (0 errors) ===");
        else           $display("=== prj10 W4 JOINT SIM: FAIL (%0d errors) ===", errs);
        $finish;
    end

    task automatic result(input string tag, input int base_errs);
        if (errs == base_errs) $display("%s PASS", tag);
        else                   $display("%s FAIL (%0d new errors)", tag, errs - base_errs);
    endtask

    // deadlock watchdog: bridge stuck with outstanding frames and no AXI
    // activity for a long window -> declare deadlock (this is what the J-X
    // negative control must trip)
    int last_act = 0, quiet = 0;
    always @(posedge ui_clk) begin
        if ((mon_wb + mon_rb) != last_act) quiet <= 0;
        else if (A_ost != 0 || B_ost != 0) quiet <= quiet + 1;
        else quiet <= 0;
        last_act <= mon_wb + mon_rb;
        if (quiet > 200000) begin
            $display("[FAIL] DEADLOCK: A_ost=%0d B_ost=%0d mon_wb=%0d mon_rb=%0d (quiet window tripped)",
                     A_ost, B_ost, mon_wb, mon_rb);
            $display("=== prj10 W4 JOINT SIM: FAIL (deadlock) ===");
            $finish;
        end
    end

    initial begin
        #120_000_000;   // 120 ms global timeout
        $display("[FAIL] GLOBAL TIMEOUT");
        $display("=== prj10 W4 JOINT SIM: FAIL (timeout) ===");
        $finish;
    end

endmodule
