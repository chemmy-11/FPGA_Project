//=============================================================================
// repro_oversize_frame_tb.sv -- D2 REGRESSION (new file, prj10 W2 review)
//-----------------------------------------------------------------------------
// BUG REPRODUCED BEFORE THE FIX (2026-09-29, pre-fix run):
//   frame_mem_if.v pushed the descriptor length from wcnt = bytes OFFERED by the
//   upstream, while ub_wr_en could be clipped by ub_full = bytes really ENQUEUED.
//   An 8000 B frame (> MAX_LEN 1538) therefore enqueued only 4096 B but declared
//   8000 B.  The bridge took the w_bad_len path and entered W_DRAIN to pop 8000
//   bytes that did not exist -> PERMANENTLY STUCK:
//     bridge wst=6 (W_DRAIN)  w_len=8000  w_pop=4095   ... forever
//     frames committed=1, expected 3
//
// WHAT THE FIX DOES
//   frame_mem_if.v       : the descriptor length is now n_push_r = bytes REALLY
//                          written into the byte FIFO, so descriptor and byte
//                          stream can never disagree.
//   axi4_master_bridge.v : W_DRAIN additionally bails out after 16 empty ui-clk
//                          (stat_len_err++), so an unrecoverable hang is
//                          structurally impossible even if a desync reappears.
//   Expected after the fix: the 8000 B frame is refused and counted, the write
//   FSM returns to IDLE, and the NEXT frame is byte-exact.
//
// HOW TO RUN (batch tools only; no Vivado GUI / project):
//   cd D:\FPGA\prj\project_10\sim
//   xvlog  -sv ..\rtl\async_fifo.v ..\rtl\axi4_master_bridge.v ..\rtl\frame_mem_if.v axi4_ram_model.v repro_oversize_frame_tb.sv
//   xelab  -debug typical repro_oversize_frame_tb -s repro_ovs
//   xsim   repro_ovs -runall
//   Expect: "REGRESSION PASS ..." and "=== RESULT: PASS ==="
//=============================================================================
`timescale 1ns/1ps

module repro_oversize_frame_tb;
    reg user_clk = 1'b0, ui_clk = 1'b0;
    always #3.3    user_clk = ~user_clk;    // 151.5 MHz
    always #1.6665 ui_clk   = ~ui_clk;      // 300 MHz

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
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready));

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
        .mon_4k(mon_4k), .mon_wb(mon_wb), .mon_rb(mon_rb), .mon_err(mon_err));

    function automatic logic [7:0] pat(input int fid, input int i);
        pat = (fid*37 + i*11 + (i >> 4)) & 32'h000000FF;
    endfunction

    int errs = 0;
    task automatic send_frame(input int fid, input int len);
        int i;
        @(negedge user_clk);
        wr_en = 1'b1; wr_data = pat(fid,0);
        for (i = 1; i < len; i = i + 1) begin @(negedge user_clk); wr_data = pat(fid,i); end
        @(negedge user_clk);
        wr_en = 1'b0; wr_data = 8'h00;
        repeat (3) @(negedge user_clk);
    endtask

    int rlen, rslot;
    logic [7:0] rbuf [0:4095];
    task automatic do_read_check(input int exp_fid, input int exp_len, input string tag);
        int t;
        t = 0;
        while (rd_busy === 1'b1 && t < 2000) begin @(negedge user_clk); t = t + 1; end
        cfg_mode = 1'b0;
        @(negedge user_clk); rd_req = 1'b1; @(negedge user_clk); rd_req = 1'b0;
        rlen = 0; rslot = -1; t = 0;
        forever begin
            @(negedge user_clk);
            if (rd_en === 1'b1) begin if (rlen < 4096) rbuf[rlen] = rd_data; rlen = rlen + 1; end
            if (rd_frame_done === 1'b1) begin rslot = rd_slot_o; break; end
            t = t + 1;
            if (t > 400000) begin $display("[FAIL] %s read timeout", tag); errs = errs + 1; break; end
        end
        if (rlen != exp_len) begin $display("[FAIL] %s len got=%0d exp=%0d", tag, rlen, exp_len); errs = errs + 1; end
        for (t = 0; t < exp_len; t = t + 1)
            if (t < rlen && rbuf[t] !== pat(exp_fid,t)) begin
                $display("[FAIL] %s byte@%0d got=%02x exp=%02x", tag, t, rbuf[t], pat(exp_fid,t));
                errs = errs + 1; t = exp_len;
            end
        repeat (2) @(negedge user_clk);
    endtask

    int guard;
    initial begin
        $display("=== D2 regression: oversize frame must be refused, never hang ===");
        repeat (20) @(posedge user_clk);
        user_rst_n = 1'b1; ui_rst_n = 1'b1; calib_ok = 1'b1;
        repeat (20) @(posedge user_clk);

        send_frame(0, 1538);                       // legal maximum frame
        send_frame(1, 8000);                       // > MAX_LEN: must be refused

        guard = 0;                                  // pre-fix: this loop never exits
        while (!(dut.u_bridge.wst == 3'd0 && wr_hold === 1'b0) && guard < 400000) begin
            @(posedge ui_clk); guard = guard + 1;
        end
        $display("settle: guard=%0d ui-clk  wst=%0d  wf_level=%0d  len_err=%0d",
                 guard, dut.u_bridge.wst, dut.u_bridge.wf_level, ro_len_err);

        send_frame(2, 200);                        // the frame BEHIND the oversize one
        repeat (30000) @(posedge ui_clk);

        $display("after 1538 / 8000 / 200 B:");
        $display("  user side : pushed=%0d buf_drop=%0d", ro_u_wr_frame, ro_u_buf_drop);
        $display("  ui  side  : wm=%0d wr_frame=%0d wr_stall=%0d len_err=%0d outstanding=%0d",
                 ro_wm, ro_wr_frame, ro_wr_stall, ro_len_err, ro_outstanding);
        $display("  bridge    : wst=%0d (0=IDLE..6=DRAIN)  w_len=%0d w_pop=%0d",
                 dut.u_bridge.wst, dut.u_bridge.w_len, dut.u_bridge.w_pop);

        if (dut.u_bridge.wst !== 3'd0) begin
            $display("[FAIL] write FSM is NOT back in IDLE (wst=%0d)", dut.u_bridge.wst); errs = errs + 1;
        end
        if (ro_len_err == 16'd0) begin
            $display("[FAIL] the oversize frame was not counted (len_err=0)"); errs = errs + 1;
        end
        if (ro_wr_frame !== 16'd2) begin
            $display("[FAIL] wr_frame=%0d expected 2 (1538 B + 200 B)", ro_wr_frame); errs = errs + 1;
        end

        do_read_check(0, 1538, "D2-rb-frame0");
        if (rslot !== 0) begin $display("[FAIL] slot got=%0d exp=0", rslot); errs = errs + 1; end
        // frame 2 lands in slot 1: the slot index is stat_wm[7:0] (committed frame
        // count), and the refused 8000 B frame never increments wm.
        do_read_check(2, 200, "D2-rb-frame2");     // proves descriptor/byte stream in step
        if (rslot !== 1) begin $display("[FAIL] slot got=%0d exp=1", rslot); errs = errs + 1; end

        if (mon_4k != 0) begin $display("[FAIL] 4KB violation"); errs = errs + 1; end
        if (errs == 0) $display("REGRESSION PASS: oversize frame refused + counted, FSM back in IDLE, next frame byte-exact");
        else           $display("REGRESSION FAIL (%0d errors)", errs);
        $display("=== RESULT: %s ===", (errs==0) ? "PASS" : "FAIL");
        $finish;
    end

    initial begin
        #120_000_000;   // 120 ms watchdog: a hang shows up as GLOBAL TIMEOUT
        $display("[FAIL] GLOBAL TIMEOUT (write path hung)");
        $display("=== RESULT: %s ===", "FAIL");
        $finish;
    end
endmodule
