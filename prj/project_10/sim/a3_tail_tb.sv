// ============================================================================
// a3_tail_tb.sv -- A3 (W3/B4): tail-beat WSTRB special test
// prj10 W3 Track-A step A3 (Lead, 2026-10-01)
//
// WHY: the bridge sends 64 B/beat bursts; a frame of 1466 B ends with a PARTIAL
//      tail beat (58 valid bytes) while the MIG is configured AxiNarrowBurst=false.
//      T1 (W2 TB) already covers 1000/1466 B at four latency tiers, but NOT the
//      MAX_LEN boundary 1538 B (2-byte tail, the extreme case of the prj9 frame
//      contract).  This TB closes that gap and asserts the WSTRB MASK SHAPE
//      independently of the data comparison:
//        legal mask = all-ones (full beat) or LSB-contiguous (tail beat only),
//        and a partial mask must appear on the LAST beat of the burst.
//
// Run:  xelab ... a3_tail_tb -generic_top "AR_LAT_T=.." -generic_top "W_DLY_T=.."
// ============================================================================
`timescale 1ns/1ps

module a3_tail_tb #(
    parameter integer AR_LAT_T = 8,
    parameter integer W_DLY_T  = 0
)();

    reg user_clk = 1'b0, ui_clk = 1'b0;
    always #3.3    user_clk = ~user_clk;    // 151.5 MHz
    always #1.6665 ui_clk   = ~ui_clk;      // 300 MHz
    reg user_rst_n = 1'b0, ui_rst_n = 1'b0, calib_ok = 1'b0;

    reg  [7:0] wr_data = 0; reg wr_en = 0;
    wire       wr_hold;
    wire [7:0] rd_data; wire rd_en; wire [7:0] rd_slot_o; wire [15:0] rd_len_o;
    wire       rd_frame_done, rd_busy;
    reg        rd_req = 0; reg cfg_mode = 0; reg [7:0] cfg_rd_slot = 0;
    wire [15:0] ro_wm, ro_wr_frame, ro_wr_stall, ro_rd_frame, ro_ill_rd, ro_noframe, ro_bresp_err, ro_len_err;
    wire [8:0]  ro_outstanding; wire [7:0] ro_dbg_wr_slot, ro_dbg_rd_slot;
    wire [31:0] dbg_wr_cycles, dbg_rd_cycles, dbg_wr_beats, dbg_rd_beats;
    wire [15:0] ro_u_wr_frame, ro_u_rd_frame, ro_u_buf_drop; wire [31:0] ro_u_hold_cycles;
    wire [8:0]  ro_outstanding_sync;

    wire [31:0] m_awaddr; wire [7:0] m_awlen; wire [2:0] m_awsize; wire [1:0] m_awburst;
    wire m_awvalid, m_awready;
    wire [511:0] m_wdata; wire [63:0] m_wstrb; wire m_wlast, m_wvalid, m_wready;
    wire [1:0] m_bresp; wire m_bvalid, m_bready;
    wire [31:0] m_araddr; wire [7:0] m_arlen; wire [2:0] m_arsize; wire [1:0] m_arburst;
    wire m_arvalid, m_arready;
    wire [511:0] m_rdata; wire [1:0] m_rresp; wire m_rlast, m_rvalid, m_rready;
    wire [3:0] m_awid, m_bid, m_arid, m_rid;
    wire [0:0] m_awlock, m_arlock;
    wire [3:0] m_awcache, m_arcache;
    wire [2:0] m_awprot, m_arprot;
    wire [3:0] m_awqos, m_arqos;
    wire [31:0] mon_4k, mon_wb, mon_rb, mon_err;

    frame_mem_if #(.SLOT_BASE(32'h0010_0000), .MAX_LEN(16'd1538)) dut (
        .user_clk(user_clk), .user_rst_n(user_rst_n),
        .wr_data(wr_data), .wr_en(wr_en), .wr_hold(wr_hold),
        .rd_data(rd_data), .rd_en(rd_en), .rd_slot_o(rd_slot_o), .rd_len_o(rd_len_o),
        .rd_frame_done(rd_frame_done), .rd_req(rd_req), .rd_busy(rd_busy),
        .cfg_mode(cfg_mode), .cfg_rd_slot(cfg_rd_slot),
        .ro_u_wr_frame(ro_u_wr_frame), .ro_u_rd_frame(ro_u_rd_frame),
        .ro_u_buf_drop(ro_u_buf_drop), .ro_u_hold_cycles(ro_u_hold_cycles),
        .ro_outstanding_sync(ro_outstanding_sync),
        .ui_clk(ui_clk), .ui_rst_n(ui_rst_n), .calib_ok(calib_ok),
        .ro_wm(ro_wm), .ro_wr_frame(ro_wr_frame), .ro_wr_stall(ro_wr_stall),
        .ro_rd_frame(ro_rd_frame), .ro_ill_rd(ro_ill_rd), .ro_noframe(ro_noframe),
        .ro_bresp_err(ro_bresp_err), .ro_len_err(ro_len_err), .ro_outstanding(ro_outstanding),
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

    axi4_ram_model #(.MEM_BYTES(1<<20), .AR_LAT(AR_LAT_T), .W_RESP_DLY(W_DLY_T),
                     .STALL_EN(1)) u_ram (
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

    // ---- A3 STRB shape monitor -------------------------------------------
    int strb_full = 0, strb_tail = 0, strb_bad = 0;
    int tail_mask_seen[0:3];
    always @(posedge ui_clk) begin
        if (m_wvalid && m_wready) begin
            if (m_wstrb == {64{1'b1}}) strb_full = strb_full + 1;
            else begin
                strb_tail = strb_tail + 1;
                // LSB-contiguous and non-zero?
                if (!((m_wstrb != 64'd0) && ((m_wstrb & (m_wstrb + 64'd1)) == 64'd0)))
                    strb_bad = strb_bad + 1;
                // only allowed on the burst tail
                if (!m_wlast) strb_bad = strb_bad + 1;
                else begin
                    // record popcount for the report (expected = len mod 64)
                    automatic int pc = 0;
                    for (int b = 0; b < 64; b = b + 1) if (m_wstrb[b]) pc = pc + 1;
                    $display("[A3] tail beat: awlen=%0d wstrb popcount=%0d (frame tail bytes)", m_awlen, pc);
                end
            end
        end
    end

    // ---- test --------------------------------------------------------------
    int errs = 0;
    localparam int N = 3;
    int lens[0:N-1];
    logic [7:0] refmem[0:N-1][0:1539];   // (the identifier "ref" is a SV keyword)
    int fid;

    function automatic logic [7:0] pat(input int f, input int i);
        pat = (f*53 + i*7 + (i >> 5)) & 32'hFF;
    endfunction

    task send_frame(input int f, input int len);
        for (int i = 0; i < len; i = i + 1) begin
            @(negedge user_clk); wr_data = pat(f, i); wr_en = 1'b1;
        end
        @(negedge user_clk); wr_en = 1'b0;
    endtask

    task read_frame(input int f, input int len);
        int i, guard;
        @(negedge user_clk); rd_req = 1'b1;
        @(negedge user_clk); rd_req = 1'b0;
        i = 0; guard = 0;
        // collect exactly len bytes (guard bounds the loop if the DUT misbehaves)
        while (i < len && guard < 60000) begin
            @(posedge user_clk);
            guard = guard + 1;
            if (rd_en) begin
                if (rd_data !== pat(f, i)) begin
                    errs = errs + 1;
                    $display("[A3][FAIL] frame %0d byte %0d: got %02h exp %02h",
                             f, i, rd_data, pat(f, i));
                end
                i = i + 1;
            end
        end
        if (i != len) begin
            errs = errs + 1;
            $display("[A3][FAIL] frame %0d length: got %0d exp %0d (guard=%0d)",
                     f, i, len, guard);
        end
        // no extra byte may follow
        repeat (4) begin
            @(posedge user_clk);
            if (rd_en) begin
                errs = errs + 1;
                $display("[A3][FAIL] frame %0d: extra byte after length %0d", f, len);
            end
        end
    endtask

    initial begin
        lens[0] = 1000; lens[1] = 1466; lens[2] = 1538;
        $display("[A3] tail-beat WSTRB test: W_DLY_T=%0d AR_LAT_T=%0d, lengths 1000/1466/1538",
                 W_DLY_T, AR_LAT_T);
        #100; user_rst_n = 1'b1;
        repeat (5) @(posedge ui_clk);
        ui_rst_n = 1'b1;
        repeat (5) @(posedge ui_clk);
        calib_ok = 1'b1;
        repeat (20) @(posedge ui_clk);

        for (int f = 0; f < N; f = f + 1) send_frame(f, lens[f]);
        #20000;
        if (ro_wm != N) begin
            errs = errs + 1;
            $display("[A3][FAIL] wm=%0d exp %0d", ro_wm, N);
        end
        for (int f = 0; f < N; f = f + 1) read_frame(f, lens[f]);
        #5000;

        $display("[A3] wm=%0d wr=%0d rd=%0d stall=%0d ill=%0d len_err=%0d bresp_err=%0d",
                 ro_wm, ro_wr_frame, ro_rd_frame, ro_wr_stall, ro_ill_rd, ro_len_err, ro_bresp_err);
        $display("[A3] wstrb: full=%0d tail=%0d illegal=%0d", strb_full, strb_tail, strb_bad);
        $display("[A3] service: wr=%.0f ui-cyc/frame  rd=%.0f",
                 dbg_wr_cycles*1.0/ro_wr_frame, dbg_rd_cycles*1.0/ro_rd_frame);

        if (errs == 0 && strb_bad == 0 && mon_4k == 0 && mon_err == 0 && ro_bresp_err == 0
            && ro_len_err == 0 && ro_wm == N && ro_rd_frame == N)
            $display("=== A3 TAIL-WSTRB SIM: PASS (0 errors) ===");
        else begin
            $display("=== A3 TAIL-WSTRB SIM: FAIL (errs=%0d strb_bad=%0d) ===", errs, strb_bad);
            $fatal;
        end
        $finish;
    end

    initial begin
        #40_000_000;
        $display("=== A3 TAIL-WSTRB SIM: TIMEOUT ===");
        $fatal;
    end

endmodule
