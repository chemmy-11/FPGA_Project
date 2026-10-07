//=============================================================================
// axi_arb_2to1_defect.v -- NEGATIVE CONTROL copy of the PRE-FIX arbiter (W4)
//-----------------------------------------------------------------------------
// Reproduces the 2026-10-06 routing defect EXACTLY as it shipped in the
// seventh-build bitstream: B/R responses routed by m_axi_bid[0] / m_axi_rid[0].
// Kept in sim/ only -- never instantiated by RTL. Used by w4_joint_tb.sv with
// DEFECT_ROUTING=1 to prove the joint bench FAILS on the old logic (verdict
// non-vacuous) before trusting its PASS on the fixed logic.
//=============================================================================
`timescale 1ns / 1ps

module axi_arb_2to1_defect (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [3:0]  s00_axi_awid,    input  wire [31:0] s00_axi_awaddr,
    input  wire [7:0]  s00_axi_awlen,   input  wire [2:0]  s00_axi_awsize,
    input  wire [1:0]  s00_axi_awburst, input  wire        s00_axi_awlock,
    input  wire [3:0]  s00_axi_awcache, input  wire [2:0]  s00_axi_awprot,
    input  wire [3:0]  s00_axi_awqos,   input  wire        s00_axi_awvalid,
    output wire        s00_axi_awready,
    input  wire [511:0] s00_axi_wdata,  input  wire [63:0] s00_axi_wstrb,
    input  wire        s00_axi_wlast,   input  wire        s00_axi_wvalid,
    output wire        s00_axi_wready,
    output wire [1:0]  s00_axi_bresp,   output wire        s00_axi_bvalid,
    input  wire        s00_axi_bready,  output wire [3:0]  s00_axi_bid,
    input  wire [3:0]  s00_axi_arid,    input  wire [31:0] s00_axi_araddr,
    input  wire [7:0]  s00_axi_arlen,   input  wire [2:0]  s00_axi_arsize,
    input  wire [1:0]  s00_axi_arburst, input  wire        s00_axi_arlock,
    input  wire [3:0]  s00_axi_arcache, input  wire [2:0]  s00_axi_arprot,
    input  wire [3:0]  s00_axi_arqos,   input  wire        s00_axi_arvalid,
    output wire        s00_axi_arready,
    output wire [511:0] s00_axi_rdata,  output wire [1:0]  s00_axi_rresp,
    output wire        s00_axi_rlast,   output wire        s00_axi_rvalid,
    input  wire        s00_axi_rready,  output wire [3:0]  s00_axi_rid,

    input  wire [3:0]  s01_axi_awid,    input  wire [31:0] s01_axi_awaddr,
    input  wire [7:0]  s01_axi_awlen,   input  wire [2:0]  s01_axi_awsize,
    input  wire [1:0]  s01_axi_awburst, input  wire        s01_axi_awlock,
    input  wire [3:0]  s01_axi_awcache, input  wire [2:0]  s01_axi_awprot,
    input  wire [3:0]  s01_axi_awqos,   input  wire        s01_axi_awvalid,
    output wire        s01_axi_awready,
    input  wire [511:0] s01_axi_wdata,  input  wire [63:0] s01_axi_wstrb,
    input  wire        s01_axi_wlast,   input  wire        s01_axi_wvalid,
    output wire        s01_axi_wready,
    output wire [1:0]  s01_axi_bresp,   output wire        s01_axi_bvalid,
    input  wire        s01_axi_bready,  output wire [3:0]  s01_axi_bid,
    input  wire [3:0]  s01_axi_arid,    input  wire [31:0] s01_axi_araddr,
    input  wire [7:0]  s01_axi_arlen,   input  wire [2:0]  s01_axi_arsize,
    input  wire [1:0]  s01_axi_arburst, input  wire        s01_axi_arlock,
    input  wire [3:0]  s01_axi_arcache, input  wire [2:0]  s01_axi_arprot,
    input  wire [3:0]  s01_axi_arqos,   input  wire        s01_axi_arvalid,
    output wire        s01_axi_arready,
    output wire [511:0] s01_axi_rdata,  output wire [1:0]  s01_axi_rresp,
    output wire        s01_axi_rlast,   output wire        s01_axi_rvalid,
    input  wire        s01_axi_rready,  output wire [3:0]  s01_axi_rid,

    output wire [3:0]  m_axi_awid,      output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,     output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,   output wire        m_axi_awlock,
    output wire [3:0]  m_axi_awcache,   output wire [2:0]  m_axi_awprot,
    output wire [3:0]  m_axi_awqos,     output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [511:0] m_axi_wdata,    output wire [63:0]  m_axi_wstrb,
    output wire        m_axi_wlast,     output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,     input  wire        m_axi_bvalid,
    output wire        m_axi_bready,    input  wire [3:0]  m_axi_bid,
    output wire [3:0]  m_axi_arid,      output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,     output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,   output wire        m_axi_arlock,
    output wire [3:0]  m_axi_arcache,   output wire [2:0]  m_axi_arprot,
    output wire [3:0]  m_axi_arqos,     output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [511:0] m_axi_rdata,    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,     input  wire        m_axi_rvalid,
    output wire        m_axi_rready,    input  wire [3:0]  m_axi_rid
);

    // ================= write direction (pre-fix: ID-bit routing) =================
    reg wgrant, wbusy, wturn;
    wire req0 = s00_axi_awvalid;
    wire req1 = s01_axi_awvalid;
    wire pick = wbusy ? wgrant : (wturn ? (req1 ? 1'b1 : 1'b0) : (req0 ? 1'b0 : 1'b1));

    assign s00_axi_awready = ~wbusy & req0 & (pick == 1'b0) & m_axi_awready;
    assign s01_axi_awready = ~wbusy & req1 & (pick == 1'b1) & m_axi_awready;

    assign m_axi_awvalid  = ~wbusy & ((pick == 1'b0) ? req0 : req1);
    assign m_axi_awid     = (pick == 1'b0) ? s00_axi_awid     : s01_axi_awid;
    assign m_axi_awaddr   = (pick == 1'b0) ? s00_axi_awaddr   : s01_axi_awaddr;
    assign m_axi_awlen    = (pick == 1'b0) ? s00_axi_awlen    : s01_axi_awlen;
    assign m_axi_awsize   = (pick == 1'b0) ? s00_axi_awsize   : s01_axi_awsize;
    assign m_axi_awburst  = (pick == 1'b0) ? s00_axi_awburst  : s01_axi_awburst;
    assign m_axi_awlock   = (pick == 1'b0) ? s00_axi_awlock   : s01_axi_awlock;
    assign m_axi_awcache  = (pick == 1'b0) ? s00_axi_awcache  : s01_axi_awcache;
    assign m_axi_awprot   = (pick == 1'b0) ? s00_axi_awprot   : s01_axi_awprot;
    assign m_axi_awqos    = (pick == 1'b0) ? s00_axi_awqos    : s01_axi_awqos;

    assign m_axi_wvalid   = (wgrant == 1'b0) ? s00_axi_wvalid : s01_axi_wvalid;
    assign m_axi_wdata    = (wgrant == 1'b0) ? s00_axi_wdata  : s01_axi_wdata;
    assign m_axi_wstrb    = (wgrant == 1'b0) ? s00_axi_wstrb  : s01_axi_wstrb;
    assign m_axi_wlast    = (wgrant == 1'b0) ? s00_axi_wlast  : s01_axi_wlast;
    assign s00_axi_wready = (wgrant == 1'b0) & wbusy & m_axi_wready;
    assign s01_axi_wready = (wgrant == 1'b1) & wbusy & m_axi_wready;

    // ★ DEFECT: routing by bid[0] (the pre-fix logic)
    assign s00_axi_bvalid = m_axi_bvalid & (m_axi_bid[0] == 1'b0);
    assign s01_axi_bvalid = m_axi_bvalid & (m_axi_bid[0] == 1'b1);
    assign s00_axi_bresp  = m_axi_bresp;  assign s00_axi_bid = m_axi_bid;
    assign s01_axi_bresp  = m_axi_bresp;  assign s01_axi_bid = m_axi_bid;
    assign m_axi_bready   = (m_axi_bid[0] == 1'b0) ? s00_axi_bready : s01_axi_bready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wgrant <= 1'b0; wbusy <= 1'b0; wturn <= 1'b0;
        end else begin
            if (!wbusy) begin
                if (m_axi_awvalid && m_axi_awready) begin
                    wbusy  <= 1'b1;
                    wgrant <= pick;
                    wturn  <= ~pick;
                end
            end else if (m_axi_bvalid && m_axi_bready) begin
                wbusy <= 1'b0;
            end
        end
    end

    // ================= read direction (pre-fix: ID-bit routing) =================
    reg rgrant, rbusy, rturn;
    wire rreq0 = s00_axi_arvalid;
    wire rreq1 = s01_axi_arvalid;
    wire rpick = rbusy ? rgrant : (rturn ? (rreq1 ? 1'b1 : 1'b0) : (rreq0 ? 1'b0 : 1'b1));

    assign s00_axi_arready = ~rbusy & rreq0 & (rpick == 1'b0) & m_axi_arready;
    assign s01_axi_arready = ~rbusy & rreq1 & (rpick == 1'b1) & m_axi_arready;

    assign m_axi_arvalid  = ~rbusy & ((rpick == 1'b0) ? rreq0 : rreq1);
    assign m_axi_arid     = (rpick == 1'b0) ? s00_axi_arid     : s01_axi_arid;
    assign m_axi_araddr   = (rpick == 1'b0) ? s00_axi_araddr   : s01_axi_araddr;
    assign m_axi_arlen    = (rpick == 1'b0) ? s00_axi_arlen    : s01_axi_arlen;
    assign m_axi_arsize   = (rpick == 1'b0) ? s00_axi_arsize   : s01_axi_arsize;
    assign m_axi_arburst  = (rpick == 1'b0) ? s00_axi_arburst  : s01_axi_arburst;
    assign m_axi_arlock   = (rpick == 1'b0) ? s00_axi_arlock   : s01_axi_arlock;
    assign m_axi_arcache  = (rpick == 1'b0) ? s00_axi_arcache  : s01_axi_arcache;
    assign m_axi_arprot   = (rpick == 1'b0) ? s00_axi_arprot   : s01_axi_arprot;
    assign m_axi_arqos    = (rpick == 1'b0) ? s00_axi_arqos    : s01_axi_arqos;

    // ★ DEFECT: routing by rid[0] (the pre-fix logic)
    assign s00_axi_rvalid = m_axi_rvalid & (m_axi_rid[0] == 1'b0);
    assign s01_axi_rvalid = m_axi_rvalid & (m_axi_rid[0] == 1'b1);
    assign s00_axi_rdata  = m_axi_rdata;  assign s00_axi_rresp = m_axi_rresp;
    assign s00_axi_rlast  = m_axi_rlast;  assign s00_axi_rid   = m_axi_rid;
    assign s01_axi_rdata  = m_axi_rdata;  assign s01_axi_rresp = m_axi_rresp;
    assign s01_axi_rlast  = m_axi_rlast;  assign s01_axi_rid   = m_axi_rid;
    assign m_axi_rready   = (m_axi_rid[0] == 1'b0) ? s00_axi_rready : s01_axi_rready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rgrant <= 1'b0; rbusy <= 1'b0; rturn <= 1'b0;
        end else begin
            if (!rbusy) begin
                if (m_axi_arvalid && m_axi_arready) begin
                    rbusy  <= 1'b1;
                    rgrant <= rpick;
                    rturn  <= ~rpick;
                end
            end else if (m_axi_rvalid && m_axi_rready && m_axi_rlast) begin
                rbusy <= 1'b0;
            end
        end
    end

endmodule