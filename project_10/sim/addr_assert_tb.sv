//=============================================================================
// addr_assert_tb.sv -- ADDRESS-DECODE assertion + REVERSE VERIFICATION
//                      (new file, prj10 W2 review, Lead request #5)
//-----------------------------------------------------------------------------
// WHY
//   sim/axi4_ram_model.v indexes its RAM with waddr[19:0] / raddr[19:0] only
//   (axi4_ram_model.v:113 and :182-213).  SLOT_BASE = 0x0010_0000 is exactly 1 MB
//   and MEM_BYTES = 1 MB, so the base address is DISCARDED and slot N always
//   aliases to offset N*4096.  A wrong SLOT_BASE, a wrong slot stride, or a slot
//   index >= 256 is therefore INVISIBLE in the W2 testbench: the TB never looks
//   at m_axi_awaddr / m_axi_araddr at all.  This TB adds the missing check.
//
// THE CHECK (per burst, on the VALID rising edge)
//   1. m_axi_awaddr == EXPECT_BASE + {slot[7:0], 12'b0}
//      (read / write address must equal base + slot*4096, slot taken from the
//       bridge's own dbg slot register -- a genuine relation, not a tautology)
//   2. m_axi_awaddr[11:0] == 0                     (4KB aligned slot base)
//   3. awaddr[11:0] + (awlen+1)*64 <= 4096         (burst cannot cross 4KB)
//   ... and the identical three for AR.
//
// REVERSE VERIFICATION (proves the check is not vacuous)
//   addr_assert_tb_bad         : RTL base 0x0010_0000, EXPECT_BASE 0x0020_0000
//                                -> check #1 MUST go red
//   addr_assert_tb_misaligned  : RTL base 0x0010_0800 (not 4KB aligned)
//                                -> check #2 MUST go red
//
// HOW TO RUN (batch tools only; no Vivado GUI / project):
//   cd D:\FPGA\project_10\sim
//   xvlog -sv ..\rtl\async_fifo.v ..\rtl\axi4_master_bridge.v ..\rtl\frame_mem_if.v axi4_ram_model.v addr_assert_tb.sv
//   xelab -debug typical addr_assert_tb_good       -s addr_good ; xsim addr_good -runall
//   xelab -debug typical addr_assert_tb_bad        -s addr_bad  ; xsim addr_bad  -runall
//   xelab -debug typical addr_assert_tb_misaligned -s addr_mis  ; xsim addr_mis  -runall
//=============================================================================
`timescale 1ns/1ps

module addr_check_core #(
    parameter [31:0] RTL_BASE    = 32'h0010_0000,
    parameter [31:0] EXPECT_BASE = 32'h0010_0000,
    parameter int    NFRAMES     = 3
)(
    output reg [31:0] viol_rel,     // check #1: addr != EXPECT_BASE + slot*4096
    output reg [31:0] viol_align,   // check #2: slot base not 4KB aligned
    output reg [31:0] viol_4k,      // check #3: burst crosses a 4KB boundary
    output reg [31:0] frames_done
);
    reg user_clk = 1'b0, ui_clk = 1'b0;
    always #3.3    user_clk = ~user_clk;
    always #1.6665 ui_clk   = ~ui_clk;

    reg user_rst_n = 1'b0, ui_rst_n = 1'b0, calib_ok = 1'b0;

    reg  [7:0] wr_data = 8'h00;  reg wr_en = 1'b0;  wire wr_hold;
    wire [7:0] rd_data;  wire rd_en;  wire [7:0] rd_slot_o;  wire [15:0] rd_len_o;
    wire rd_frame_done, rd_busy;
    reg  rd_req = 1'b0, cfg_mode = 1'b0;  reg [7:0] cfg_rd_slot = 8'h00;
    wire [15:0] ro_u_wr_frame, ro_u_rd_frame, ro_u_buf_drop;
    wire [31:0] ro_u_hold_cycles;  wire [8:0] ro_outstanding_sync;
    wire [15:0] ro_wm, ro_wr_frame, ro_wr_stall, ro_rd_frame, ro_ill_rd, ro_noframe, ro_bresp_err, ro_len_err;
    wire [8:0]  ro_outstanding;
    wire [7:0]  ro_dbg_wr_slot, ro_dbg_rd_slot;
    wire [31:0] dbg_wr_cycles, dbg_rd_cycles, dbg_wr_beats, dbg_rd_beats;

    wire [31:0] m_awaddr; wire [7:0] m_awlen; wire [2:0] m_awsize; wire [1:0] m_awburst;
    wire m_awvalid, m_awready;
    wire [511:0] m_wdata; wire [63:0] m_wstrb; wire m_wlast, m_wvalid, m_wready;
    wire [1:0] m_bresp; wire m_bvalid, m_bready;
    wire [31:0] m_araddr; wire [7:0] m_arlen; wire [2:0] m_arsize; wire [1:0] m_arburst;
    wire m_arvalid, m_arready;
    wire [511:0] m_rdata; wire [1:0] m_rresp; wire m_rlast, m_rvalid, m_rready;
    wire [31:0] mon_4k, mon_wb, mon_rb, mon_err;

    // A1 sideband (37-signal AXI4 contract)
    wire [3:0] m_awid, m_bid, m_arid, m_rid;
    wire [0:0] m_awlock, m_arlock;
    wire [3:0] m_awcache, m_arcache;
    wire [2:0] m_awprot,  m_arprot;
    wire [3:0] m_awqos,   m_arqos;

    frame_mem_if #(.SLOT_BASE(RTL_BASE), .MAX_LEN(16'd1538)) dut (
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

    axi4_ram_model #(.MEM_BYTES(1<<20), .AR_LAT(8), .STALL_EN(1)) u_ram (
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

    // ---------------- the three address checks ----------------
    reg awv_d, arv_d;
    wire [31:0] aw_expect = EXPECT_BASE + {12'b0, ro_dbg_wr_slot[7:0], 12'b0};
    wire [31:0] ar_expect = EXPECT_BASE + {12'b0, ro_dbg_rd_slot[7:0], 12'b0};

    initial begin viol_rel=0; viol_align=0; viol_4k=0; frames_done=0; awv_d=0; arv_d=0; end

    always @(posedge ui_clk) begin
        awv_d <= m_awvalid;
        arv_d <= m_arvalid;
        if (m_awvalid && !awv_d) begin
            if (m_awaddr !== aw_expect)               viol_rel   <= viol_rel   + 32'd1;
            if (m_awaddr[11:0] !== 12'd0)             viol_align <= viol_align + 32'd1;
            if (({20'b0, m_awaddr[11:0]} + (m_awlen + 8'd1) * 32'd64) > 32'd4096)
                                                      viol_4k    <= viol_4k    + 32'd1;
        end
        if (m_arvalid && !arv_d) begin
            if (m_araddr !== ar_expect)               viol_rel   <= viol_rel   + 32'd1;
            if (m_araddr[11:0] !== 12'd0)             viol_align <= viol_align + 32'd1;
            if (({20'b0, m_araddr[11:0]} + (m_arlen + 8'd1) * 32'd64) > 32'd4096)
                                                      viol_4k    <= viol_4k    + 32'd1;
        end
    end

    function automatic logic [7:0] pat(input int fid, input int i);
        pat = (fid*37 + i*11 + (i >> 4)) & 32'h000000FF;
    endfunction

    task automatic send_frame(input int fid, input int len);
        int i;
        @(negedge user_clk);
        wr_en = 1'b1; wr_data = pat(fid,0);
        for (i = 1; i < len; i = i + 1) begin @(negedge user_clk); wr_data = pat(fid,i); end
        @(negedge user_clk);
        wr_en = 1'b0; wr_data = 8'h00;
        repeat (3) @(negedge user_clk);
    endtask

    task automatic do_read;
        int t;
        t = 0;
        while (rd_busy === 1'b1 && t < 2000) begin @(negedge user_clk); t = t + 1; end
        cfg_mode = 1'b0;
        @(negedge user_clk); rd_req = 1'b1; @(negedge user_clk); rd_req = 1'b0;
        t = 0;
        while (rd_frame_done !== 1'b1 && t < 400000) begin @(negedge user_clk); t = t + 1; end
        repeat (2) @(negedge user_clk);
    endtask

    int k, guard;
    initial begin
        repeat (20) @(posedge user_clk);
        user_rst_n = 1'b1; ui_rst_n = 1'b1; calib_ok = 1'b1;
        repeat (20) @(posedge user_clk);
        for (k = 0; k < NFRAMES; k = k + 1) send_frame(k, 100 + k*400);
        guard = 0;
        while (ro_wr_frame < NFRAMES && guard < 400000) begin @(posedge ui_clk); guard = guard + 1; end
        for (k = 0; k < NFRAMES; k = k + 1) do_read;
        repeat (2000) @(posedge ui_clk);
        frames_done = ro_wr_frame;
    end
endmodule

//-----------------------------------------------------------------------------
// Top 1: correct expectation -> all three checks must stay at 0
//-----------------------------------------------------------------------------
module addr_assert_tb_good;
    wire [31:0] vr, va, v4, fd;
    addr_check_core #(.RTL_BASE(32'h0010_0000), .EXPECT_BASE(32'h0010_0000), .NFRAMES(3))
        u (.viol_rel(vr), .viol_align(va), .viol_4k(v4), .frames_done(fd));
    initial begin
        #4_000_000;
        $display("=== ADDR ASSERT (correct base) ===");
        $display("  frames_committed=%0d  viol_rel=%0d viol_align=%0d viol_4k=%0d", fd, vr, va, v4);
        if (fd != 32'd3)                       $display("  [FAIL] frames_committed != 3");
        else if (vr|va|v4)                     $display("  [FAIL] address checks fired on a CORRECT design");
        else                                   $display("  RESULT: PASS (addr == base+slot*4096, 4KB aligned, no 4KB cross)");
        $finish;
    end
endmodule

//-----------------------------------------------------------------------------
// Top 2: REVERSE -- wrong expected base -> check #1 must fire
//-----------------------------------------------------------------------------
module addr_assert_tb_bad;
    wire [31:0] vr, va, v4, fd;
    addr_check_core #(.RTL_BASE(32'h0010_0000), .EXPECT_BASE(32'h0020_0000), .NFRAMES(3))
        u (.viol_rel(vr), .viol_align(va), .viol_4k(v4), .frames_done(fd));
    initial begin
        #4_000_000;
        $display("=== ADDR ASSERT REVERSE #1 (EXPECT_BASE deliberately wrong: 0x0020_0000) ===");
        $display("  frames_committed=%0d  viol_rel=%0d viol_align=%0d viol_4k=%0d", fd, vr, va, v4);
        if (fd != 32'd3)   $display("  [INVALID] design did not run -- reverse test inconclusive");
        else if (vr == 0)  $display("  [FAIL] check #1 is VACUOUS (stayed 0 with a wrong base!)");
        else               $display("  RESULT: PASS -- check #1 went RED (%0d violations): the assertion is NOT vacuous", vr);
        $finish;
    end
endmodule

//-----------------------------------------------------------------------------
// Top 3: REVERSE -- misaligned RTL base -> alignment check must fire
//-----------------------------------------------------------------------------
module addr_assert_tb_misaligned;
    wire [31:0] vr, va, v4, fd;
    addr_check_core #(.RTL_BASE(32'h0010_0800), .EXPECT_BASE(32'h0010_0000), .NFRAMES(3))
        u (.viol_rel(vr), .viol_align(va), .viol_4k(v4), .frames_done(fd));
    initial begin
        #4_000_000;
        $display("=== ADDR ASSERT REVERSE #2 (RTL SLOT_BASE deliberately misaligned: 0x0010_0800) ===");
        $display("  frames_committed=%0d  viol_rel=%0d viol_align=%0d viol_4k=%0d", fd, vr, va, v4);
        if (fd != 32'd3)   $display("  [INVALID] design did not run -- reverse test inconclusive");
        else if (va == 0)  $display("  [FAIL] alignment check is VACUOUS");
        else               $display("  RESULT: PASS -- alignment check went RED (%0d violations)", va);
        $finish;
    end
endmodule
