//=============================================================================
// axi4_ram_model.v -- behavioural AXI4 512-bit slave + RAM + protocol monitor
//                     prj10 W2 simulation stand-in for MIG ddr4_0
//-----------------------------------------------------------------------------
// WHY a behavioural model and not the MIG sim netlist:
//   W2's acceptance is about the BRIDGE (frame semantics, slot policy, burst
//   arithmetic), not about DDR timing. A RAM model with configurable read
//   latency + pseudo-random backpressure exercises exactly the parts of the AXI
//   handshake the bridge must survive (valid/ready hold rules), and it lets the
//   monitor check the 4KB rule and the beat-count arithmetic directly.
//   W3 replaces this instance with ddr4_0 (or its sim netlist), unchanged.
//=============================================================================
`timescale 1ns/1ps

module axi4_ram_model #(
    parameter MEM_BYTES = (1<<20),   // 1 MB -> covers one 256x4KB slot region
    parameter AR_LAT    = 8,         // ui cycles before the FIRST read beat (base)
    parameter W_RESP_DLY= 0,         // A2: EXTRA ui cycles before BVALID (0 = W2 baseline,
                                     //     byte-identical timing; target Lw = 2 + W_RESP_DLY)
    parameter STALL_EN  = 1
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire [31:0]  s_awaddr,
    input  wire [7:0]   s_awlen,
    input  wire [2:0]   s_awsize,
    input  wire [1:0]   s_awburst,
    input  wire         s_awvalid,
    output reg          s_awready,
    input  wire [511:0] s_wdata,
    input  wire [63:0]  s_wstrb,
    input  wire         s_wlast,
    input  wire         s_wvalid,
    output reg          s_wready,
    output reg  [1:0]   s_bresp,
    output reg          s_bvalid,
    input  wire         s_bready,
    // ---- A1: AXI4 sideband (accepts the 37-signal contract; ID is echoed) ----
    input  wire [3:0]   s_awid,
    input  wire [0:0]   s_awlock,
    input  wire [3:0]   s_awcache,
    input  wire [2:0]   s_awprot,
    input  wire [3:0]   s_awqos,
    output wire [3:0]   s_bid,

    input  wire [31:0]  s_araddr,
    input  wire [7:0]   s_arlen,
    input  wire [2:0]   s_arsize,
    input  wire [1:0]   s_arburst,
    input  wire         s_arvalid,
    output reg          s_arready,
    output reg  [511:0] s_rdata,
    output reg  [1:0]   s_rresp,
    output wire         s_rlast,     // combinational with the last beat (AXI)
    output reg          s_rvalid,
    input  wire         s_rready,
    input  wire [3:0]   s_arid,
    input  wire [0:0]   s_arlock,
    input  wire [3:0]   s_arcache,
    input  wire [2:0]   s_arprot,
    input  wire [3:0]   s_arqos,
    output wire [3:0]   s_rid,

    // ---- monitor (checked by the testbench) ----
    output reg  [31:0]  mon_4k,        // bursts crossing an AXI 4KB boundary
    output reg  [31:0]  mon_wb,        // write beats accepted
    output reg  [31:0]  mon_rb,        // read beats issued
    output reg  [31:0]  mon_err        // protocol / length errors
);

    reg [7:0] mem [0:MEM_BYTES-1];

    // ---- A1: ID echo (AXI requires bid/rid to match the request ID) ----
    reg [3:0] awid_r, arid_r;
    assign s_bid = awid_r;
    assign s_rid = arid_r;

    integer mi;
    initial begin
        for (mi = 0; mi < MEM_BYTES; mi = mi + 1) mem[mi] = 8'h00;
        mon_4k = 0; mon_wb = 0; mon_rb = 0; mon_err = 0;
    end

    // ---- pseudo-random backpressure (deterministic LFSR) ----
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hACE1;
        else        lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    end
    wire stall = STALL_EN && (lfsr[2:0] == 3'b000);

    //=========================================================================
    // write channel
    //=========================================================================
    localparam WS_IDLE=2'd0, WS_DATA=2'd1, WS_RESP=2'd2, WS_WAIT=2'd3;
    reg [1:0]  wst;
    reg [15:0] wdly;                    // A2: extra cycles before BVALID
    reg [31:0] waddr;
    reg [7:0]  wbeats, wcnt;
    reg [2:0]  wsize;
    reg [1:0]  wburst;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wst <= WS_IDLE; s_awready <= 1'b1; s_wready <= 1'b0;
            s_bvalid <= 1'b0; s_bresp <= 2'b00; wdly <= 16'd0;
            waddr <= 0; wbeats <= 0; wcnt <= 0; wsize <= 0; wburst <= 0;
        end else begin
            case (wst)
            WS_IDLE: begin
                s_awready <= 1'b1;
                s_wready  <= 1'b0;
                if (s_awvalid && s_awready) begin
                    waddr   <= s_awaddr;
                    awid_r  <= s_awid;      // A1: echo back on B
                    wbeats  <= s_awlen + 8'd1;
                    wsize   <= s_awsize;
                    wburst  <= s_awburst;
                    wcnt    <= 8'd0;
                    s_awready <= 1'b0;
                    // ---- 4KB boundary monitor ----
                    if (((s_awaddr & 32'hFFFFF000) !=
                         ((s_awaddr + (s_awlen + 32'd1) * (32'd1 << s_awsize) - 32'd1) & 32'hFFFFF000)))
                        mon_4k <= mon_4k + 32'd1;
                    if ((s_awsize != 3'b110) || (s_awburst != 2'b01))
                        mon_err <= mon_err + 32'd1;
                    wst <= WS_DATA;
                end
            end
            WS_DATA: begin
                s_wready <= ~stall;
                if (s_wvalid && s_wready) begin
                    for (mi = 0; mi < 64; mi = mi + 1)
                        if (s_wstrb[mi]) mem[(waddr[19:0] + mi) % MEM_BYTES] <= s_wdata[mi*8 +: 8];
                    waddr <= waddr + 32'd64;
                    wcnt  <= wcnt + 8'd1;
                    mon_wb <= mon_wb + 32'd1;
                    if (s_wlast) begin
                        if (wcnt != (wbeats - 8'd1)) mon_err <= mon_err + 32'd1;
                        s_wready <= 1'b0;
                        // A2: W_RESP_DLY == 0 keeps the W2 waveform EXACTLY (byte-identical
                        //     regression); > 0 inserts extra wait cycles before BVALID.
                        wdly     <= W_RESP_DLY[15:0];
                        wst      <= (W_RESP_DLY == 0) ? WS_RESP : WS_WAIT;
                    end
                end
            end
            WS_WAIT: begin                 // A2: stretched write-response latency
                if (wdly == 16'd0) wst <= WS_RESP;
                else               wdly <= wdly - 16'd1;
            end
            WS_RESP: begin
                s_bvalid <= 1'b1;
                s_bresp  <= 2'b00;
                if (s_bvalid && s_bready) begin
                    s_bvalid <= 1'b0;
                    wst      <= WS_IDLE;
                end
            end
            default: wst <= WS_IDLE;
            endcase
        end
    end

    //=========================================================================
    // read channel
    //=========================================================================

    localparam RS_IDLE=2'd0, RS_LAT=2'd1, RS_DATA=2'd2;
    reg [1:0]  rsta;
    reg [31:0] raddr;
    reg [7:0]  rbeats, rcnt;
    reg [7:0]  rlat;

    // rlast is combinational so it is asserted WITH the last beat (AXI)
    assign s_rlast = s_rvalid && (rcnt == (rbeats - 8'd1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsta <= RS_IDLE; s_arready <= 1'b1; s_rvalid <= 1'b0;
            s_rresp <= 2'b00; s_rdata <= 0;
            raddr <= 0; rbeats <= 0; rcnt <= 0; rlat <= 0;
        end else begin
            case (rsta)
            RS_IDLE: begin
                s_arready <= 1'b1;
                s_rvalid  <= 1'b0;
                if (s_arvalid && s_arready) begin
                    raddr   <= s_araddr;
                    arid_r  <= s_arid;      // A1: echo back on R
                    rbeats  <= s_arlen + 8'd1;
                    rcnt    <= 8'd0;
                    rlat    <= AR_LAT;
                    s_arready <= 1'b0;
                    if (((s_araddr & 32'hFFFFF000) !=
                         ((s_araddr + (s_arlen + 32'd1) * (32'd1 << s_arsize) - 32'd1) & 32'hFFFFF000)))
                        mon_4k <= mon_4k + 32'd1;
                    if ((s_arsize != 3'b110) || (s_arburst != 2'b01))
                        mon_err <= mon_err + 32'd1;
                    rsta <= RS_LAT;
                end
            end
            RS_LAT: begin
                if (rlat == 8'd0) rsta <= RS_DATA;
                else              rlat <= rlat - 8'd1;
            end
            RS_DATA: begin
                if (!s_rvalid && !stall) begin
                    s_rvalid <= 1'b1;
                    s_rresp  <= 2'b00;
                s_rdata  <= {mem[(raddr[19:0] + 63) % MEM_BYTES], mem[(raddr[19:0] + 62) % MEM_BYTES],
                             mem[(raddr[19:0] + 61) % MEM_BYTES], mem[(raddr[19:0] + 60) % MEM_BYTES],
                             mem[(raddr[19:0] + 59) % MEM_BYTES], mem[(raddr[19:0] + 58) % MEM_BYTES],
                             mem[(raddr[19:0] + 57) % MEM_BYTES], mem[(raddr[19:0] + 56) % MEM_BYTES],
                             mem[(raddr[19:0] + 55) % MEM_BYTES], mem[(raddr[19:0] + 54) % MEM_BYTES],
                             mem[(raddr[19:0] + 53) % MEM_BYTES], mem[(raddr[19:0] + 52) % MEM_BYTES],
                             mem[(raddr[19:0] + 51) % MEM_BYTES], mem[(raddr[19:0] + 50) % MEM_BYTES],
                             mem[(raddr[19:0] + 49) % MEM_BYTES], mem[(raddr[19:0] + 48) % MEM_BYTES],
                             mem[(raddr[19:0] + 47) % MEM_BYTES], mem[(raddr[19:0] + 46) % MEM_BYTES],
                             mem[(raddr[19:0] + 45) % MEM_BYTES], mem[(raddr[19:0] + 44) % MEM_BYTES],
                             mem[(raddr[19:0] + 43) % MEM_BYTES], mem[(raddr[19:0] + 42) % MEM_BYTES],
                             mem[(raddr[19:0] + 41) % MEM_BYTES], mem[(raddr[19:0] + 40) % MEM_BYTES],
                             mem[(raddr[19:0] + 39) % MEM_BYTES], mem[(raddr[19:0] + 38) % MEM_BYTES],
                             mem[(raddr[19:0] + 37) % MEM_BYTES], mem[(raddr[19:0] + 36) % MEM_BYTES],
                             mem[(raddr[19:0] + 35) % MEM_BYTES], mem[(raddr[19:0] + 34) % MEM_BYTES],
                             mem[(raddr[19:0] + 33) % MEM_BYTES], mem[(raddr[19:0] + 32) % MEM_BYTES],
                             mem[(raddr[19:0] + 31) % MEM_BYTES], mem[(raddr[19:0] + 30) % MEM_BYTES],
                             mem[(raddr[19:0] + 29) % MEM_BYTES], mem[(raddr[19:0] + 28) % MEM_BYTES],
                             mem[(raddr[19:0] + 27) % MEM_BYTES], mem[(raddr[19:0] + 26) % MEM_BYTES],
                             mem[(raddr[19:0] + 25) % MEM_BYTES], mem[(raddr[19:0] + 24) % MEM_BYTES],
                             mem[(raddr[19:0] + 23) % MEM_BYTES], mem[(raddr[19:0] + 22) % MEM_BYTES],
                             mem[(raddr[19:0] + 21) % MEM_BYTES], mem[(raddr[19:0] + 20) % MEM_BYTES],
                             mem[(raddr[19:0] + 19) % MEM_BYTES], mem[(raddr[19:0] + 18) % MEM_BYTES],
                             mem[(raddr[19:0] + 17) % MEM_BYTES], mem[(raddr[19:0] + 16) % MEM_BYTES],
                             mem[(raddr[19:0] + 15) % MEM_BYTES], mem[(raddr[19:0] + 14) % MEM_BYTES],
                             mem[(raddr[19:0] + 13) % MEM_BYTES], mem[(raddr[19:0] + 12) % MEM_BYTES],
                             mem[(raddr[19:0] + 11) % MEM_BYTES], mem[(raddr[19:0] + 10) % MEM_BYTES],
                             mem[(raddr[19:0] +  9) % MEM_BYTES], mem[(raddr[19:0] +  8) % MEM_BYTES],
                             mem[(raddr[19:0] +  7) % MEM_BYTES], mem[(raddr[19:0] +  6) % MEM_BYTES],
                             mem[(raddr[19:0] +  5) % MEM_BYTES], mem[(raddr[19:0] +  4) % MEM_BYTES],
                             mem[(raddr[19:0] +  3) % MEM_BYTES], mem[(raddr[19:0] +  2) % MEM_BYTES],
                             mem[(raddr[19:0] +  1) % MEM_BYTES], mem[(raddr[19:0] +  0) % MEM_BYTES]};
                end
                if (s_rvalid && s_rready) begin
                    raddr   <= raddr + 32'd64;
                    rcnt    <= rcnt + 8'd1;
                    mon_rb  <= mon_rb + 32'd1;
                    s_rvalid <= 1'b0;              // legal 1-cycle gap between beats
                    if (rcnt == (rbeats - 8'd1)) begin
                        s_arready <= 1'b1;
                        rsta      <= RS_IDLE;
                    end
                end
            end
            default: rsta <= RS_IDLE;
            endcase
        end
    end

endmodule
