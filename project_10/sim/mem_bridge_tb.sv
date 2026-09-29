//=============================================================================
// mem_bridge_tb.sv -- prj10 W2 acceptance testbench (memory bridge, xsim)
//-----------------------------------------------------------------------------
// Judges the W2 exit criteria of 操作文档/阶段三_prj10_内存进环路开工草案 §8.1:
//   T6  MIG hard gate        : no AW/AR before init_calib_complete, no hang
//   T1  J2  byte-exactness   : 8 frames, lengths covering %8 remainder classes
//   T4  J3  random read      : scrambled slot commands -> read order == command
//                              order, every frame matched to ITS slot
//   T5  J5  defined illegal  : out-of-range slot -> clamp + ill_rd_cnt; replay of
//                              a retired slot / never-resident slot -> defined
//                              empty answer + ill_rd_cnt
//   T2  J4  wrap, 300 frames : slot region wraps, no stall, all byte-exact
//   T3  slot watermark       : fill all 256 slots -> unread frames are NOT
//                              overwritten, refusals are counted (wr_stall_cnt),
//                              differential chain pushed == committed + refused
// Two clock domains are really exercised: user 151.5 MHz / ui 300 MHz.
//=============================================================================
`timescale 1ns/1ps

module mem_bridge_tb;

    // ---------------- clocks ----------------
    reg user_clk = 1'b0;
    reg ui_clk   = 1'b0;
    always #3.3     user_clk = ~user_clk;   // 6.6 ns  -> 151.5 MHz
    always #1.6665  ui_clk   = ~ui_clk;     // 3.333 ns -> 300 MHz

    reg user_rst_n = 1'b0;
    reg ui_rst_n   = 1'b0;
    reg calib_ok   = 1'b0;

    // ---------------- frame side ----------------
    reg  [7:0]  wr_data = 8'h00;
    reg         wr_en   = 1'b0;
    wire        wr_hold;
    wire [7:0]  rd_data;
    wire        rd_en;
    wire [7:0]  rd_slot_o;
    wire [15:0] rd_len_o;
    wire        rd_frame_done;
    wire        rd_busy;
    reg         rd_req = 1'b0;
    reg         cfg_mode = 1'b0;
    reg  [7:0]  cfg_rd_slot = 8'h00;

    wire [15:0] ro_u_wr_frame, ro_u_rd_frame, ro_u_buf_drop;
    wire [31:0] ro_u_hold_cycles;
    wire [8:0]  ro_outstanding_sync;

    // ---------------- ui side ----------------
    wire [15:0] ro_wm, ro_wr_frame, ro_wr_stall, ro_rd_frame, ro_ill_rd, ro_noframe, ro_bresp_err;
    wire [15:0] ro_len_err;   // W2-review D2 counter (not printed: keeps the W2 verdict byte-identical)
    wire [8:0]  ro_outstanding;
    wire [7:0]  ro_dbg_wr_slot, ro_dbg_rd_slot;
    wire [31:0] dbg_wr_cycles, dbg_rd_cycles, dbg_wr_beats, dbg_rd_beats;

    wire [31:0]  m_awaddr;  wire [7:0] m_awlen;  wire [2:0] m_awsize; wire [1:0] m_awburst;
    wire         m_awvalid, m_awready;
    wire [511:0] m_wdata;   wire [63:0] m_wstrb; wire m_wlast, m_wvalid, m_wready;
    wire [1:0]   m_bresp;   wire m_bvalid, m_bready;
    wire [31:0]  m_araddr;  wire [7:0] m_arlen;  wire [2:0] m_arsize; wire [1:0] m_arburst;
    wire         m_arvalid, m_arready;
    wire [511:0] m_rdata;   wire [1:0] m_rresp;  wire m_rlast, m_rvalid, m_rready;
    wire [31:0]  mon_4k, mon_wb, mon_rb, mon_err;

    // ---------------- DUT + DDR stand-in ----------------
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

    // ---------------- test state ----------------
    int  errs = 0;
    int  rlen = 0;
    int  rslot = -1;
    bit  rnone = 1'b0;
    logic [7:0] rbuf [0:2047];
    int  flen_of [0:2047];
    int  seq_exp = 0;

    // deterministic per-frame payload so no reference buffer is needed
    function automatic logic [7:0] pat(input int fid, input int i);
        pat = (fid*37 + i*11 + (i >> 4)) & 32'h000000FF;
    endfunction

    task automatic fail(input string tag);
        $display("[FAIL] %s", tag);
        errs = errs + 1;
    endtask

    task automatic result(input string tag, input int base_errs);
        if (errs == base_errs) $display("%s PASS", tag);
        else                   $display("%s FAIL (%0d new errors)", tag, errs - base_errs);
    endtask

    // one frame on the 8-bit frame port; boundary = wr_en falling edge
    task automatic send_frame(input int fid, input int len, input bit honour_hold, output bit sent);
        int i, guard;
        sent = 1'b0;
        if (honour_hold) begin
            guard = 0;
            while (wr_hold === 1'b1) begin
                @(negedge user_clk);
                guard = guard + 1;
                if (guard > 40000) return;      // slots exhausted -> give up
            end
        end
        @(negedge user_clk);
        wr_en   = 1'b1;
        wr_data = pat(fid, 0);
        for (i = 1; i < len; i = i + 1) begin
            @(negedge user_clk);
            wr_data = pat(fid, i);
        end
        @(negedge user_clk);
        wr_en   = 1'b0;
        wr_data = 8'h00;
        repeat (3) @(negedge user_clk);
        sent = 1'b1;
    endtask

    // issue one read request and collect exactly one frame
    task automatic do_read(input bit rnd, input int slotcmd);
        int t;
        t = 0;
        while (rd_busy === 1'b1 && t < 1000) begin @(negedge user_clk); t = t + 1; end
        cfg_mode    = rnd;
        cfg_rd_slot = slotcmd[7:0];
        @(negedge user_clk);
        rd_req = 1'b1;
        @(negedge user_clk);
        rd_req = 1'b0;
        rlen = 0; rslot = -1; rnone = 1'b0; t = 0;
        forever begin
            @(negedge user_clk);
            if (rd_en === 1'b1) begin
                if (rlen < 2048) rbuf[rlen] = rd_data;
                rlen = rlen + 1;
            end
            if (rd_frame_done === 1'b1) begin
                rslot = rd_slot_o;
                break;
            end
            t = t + 1;
            if (t > 300000) begin
                $display("[FAIL] do_read timeout rnd=%0d slot=%0d", rnd, slotcmd);
                $display("   DUMP est=%0d busy=%b rdE=%b rdD=%h ucE=%b ucD=%h rbE=%b rbD=%h | rstate=%0d rslot=%0d rlen=%0d rbeats=%0d rbeat=%0d rbi=%0d rnb=%0d | rcE=%b rcD=%h wm=%0d ost=%0d seqslot=%0d full1=%b full2=%b",
                    dut.est, dut.rd_busy_r, dut.rd_empty, dut.rd_dout, dut.uc_empty, dut.uc_dout, dut.rb_empty, dut.rb_dout,
                    dut.u_bridge.rstate, dut.u_bridge.r_slot, dut.u_bridge.r_len, dut.u_bridge.r_beats,
                    dut.u_bridge.r_beat, dut.u_bridge.r_bi, dut.u_bridge.r_nbytes,
                    dut.u_bridge.rc_empty, dut.u_bridge.rc_data, ro_wm, ro_outstanding,
                    dut.u_bridge.rd_seq_slot, dut.u_bridge.full_bit[1], dut.u_bridge.full_bit[2]);
                errs = errs + 1;
                break;
            end
        end
        if (rlen == 0) rnone = 1'b1;
        repeat (2) @(negedge user_clk);
    endtask

    task automatic check_frame(input int fid, input int elen, input string tag);
        int i;
        if (rlen != elen) begin
            $display("[FAIL] %s len fid=%0d got=%0d exp=%0d", tag, fid, rlen, elen);
            errs = errs + 1;
        end
        for (i = 0; i < elen; i = i + 1) begin
            if (i < rlen && rbuf[i] !== pat(fid, i)) begin
                $display("[FAIL] %s byte fid=%0d @%0d got=%02x exp=%02x", tag, fid, i, rbuf[i], pat(fid,i));
                errs = errs + 1;
                i = elen;
            end
        end
    endtask

    task automatic wait_frames(input int target);
        int t;
        t = 0;
        while (ro_wr_frame < target && t < 400000) begin @(posedge ui_clk); t = t + 1; end
        if (t >= 400000) begin
            $display("[FAIL] wait_frames target=%0d got=%0d", target, ro_wr_frame);
            errs = errs + 1;
        end
    endtask

    // ---------------- main ----------------
    int lens [0:7];
    int fid, i, k, len, sent;
    int base, stall0, commit0, u0, wm0, e0, pushed_fill, fill_guard;
    int drop0, refused_total, commit_refuse, stall_fill, drop_fill;
    int pushed_total, committed_total;
    real wr_cpf, rd_cpf;
    bit sentb;

    initial begin
        lens[0]=26; lens[1]=33; lens[2]=40; lens[3]=63;
        lens[4]=100; lens[5]=200; lens[6]=1000; lens[7]=1466;

        $display("=== prj10 W2 memory-bridge simulation (user 151.5MHz / ui 300MHz) ===");
        repeat (20) @(posedge user_clk);
        user_rst_n = 1'b1;
        ui_rst_n   = 1'b1;
        repeat (20) @(posedge user_clk);

        // ================= T6: MIG hard gate =================
        e0 = errs;
        fid = 0; flen_of[0] = 100;
        send_frame(0, 100, 1'b1, sentb);
        if (!sentb) fail("T6 send");
        repeat (300) @(posedge ui_clk);
        if (mon_wb !== 0 || mon_rb !== 0 || mon_4k !== 0)
            fail("T6 MIG gate: AXI traffic before init_calib_complete");
        calib_ok = 1'b1;
        wait_frames(1);
        do_read(1'b0, 0);
        check_frame(0, 100, "T6-rb");
        if (rslot !== 0) fail("T6 slot 0");
        seq_exp = 1;
        fid     = 1;   // frame 0 is now committed: keep fid, wm and slot index in step
        $display("T6: calib_ok=0 -> %0d AXI beats, gate holds, no hang", mon_wb);
        result("T6 (MIG hard gate)", e0);

        // ================= T1: J2 byte-exactness =================
        e0 = errs;
        for (i = 0; i < 8; i = i + 1) begin
            len = lens[i];
            flen_of[fid] = len;
            send_frame(fid, len, 1'b1, sentb);
            if (!sentb) fail("T1 send");
            fid = fid + 1;
        end
        wait_frames(fid);
        for (i = 0; i < 8; i = i + 1) begin
            do_read(1'b0, 0);
            check_frame(seq_exp, lens[i], "T1");
            if (rslot !== (seq_exp % 256)) begin
                $display("[FAIL] T1 slot got=%0d exp=%0d", rslot, seq_exp % 256); errs = errs + 1;
            end
            seq_exp = seq_exp + 1;
        end
        result("T1 (J2 byte-exact, 8 lengths)", e0);

        // ================= T4: J3 random read (out of order) =================
        e0 = errs;
        for (k = 0; k < 16; k = k + 1) begin
            len = 50 + ((fid*137) % 1400);
            flen_of[fid] = len;
            send_frame(fid, len, 1'b1, sentb);
            if (!sentb) fail("T4 send");
            fid = fid + 1;
        end
        wait_frames(fid);
        begin
            int scrambled [0:15];
            scrambled[0]=12; scrambled[1]=9;  scrambled[2]=24; scrambled[3]=15;
            scrambled[4]=10; scrambled[5]=23; scrambled[6]=16; scrambled[7]=11;
            scrambled[8]=13; scrambled[9]=18; scrambled[10]=14; scrambled[11]=22;
            scrambled[12]=17; scrambled[13]=19; scrambled[14]=20; scrambled[15]=21;
            for (k = 0; k < 16; k = k + 1) begin
                do_read(1'b1, scrambled[k]);
                if (rslot !== scrambled[k]) begin
                    $display("[FAIL] T4 order: commanded %0d served %0d", scrambled[k], rslot);
                    errs = errs + 1;
                end
                check_frame(scrambled[k], flen_of[scrambled[k]], "T4");
            end
        end
        result("T4 (J3 random read: order == commands, contents slot-exact)", e0);

        // ================= T5: J5 defined illegal reads =================
        e0 = errs;
        for (k = 0; k < 4; k = k + 1) begin
            len = 300;
            flen_of[fid] = len;
            send_frame(fid, len, 1'b1, sentb);
            if (!sentb) fail("T5 send");
            fid = fid + 1;
        end
        wait_frames(fid);
        wm0 = ro_wm;                                     // 29
        stall0 = ro_ill_rd;
        do_read(1'b1, 200);                              // out of range -> clamp to wm-1
        if (rslot !== (wm0-1)) begin
            $display("[FAIL] T5a clamp served slot %0d exp %0d", rslot, wm0-1); errs = errs + 1;
        end
        check_frame(wm0-1, flen_of[wm0-1], "T5a");
        if (ro_ill_rd !== stall0 + 1) fail("T5a ill_rd count");
        do_read(1'b1, wm0-1);                            // retired slot -> defined empty
        if (!rnone || rlen != 0) fail("T5b retired slot must answer empty");
        if (ro_ill_rd !== stall0 + 2) fail("T5b ill_rd count");
        do_read(1'b1, 5);                                // never resident -> defined empty
        if (!rnone) fail("T5c never-resident slot must answer empty");
        if (ro_ill_rd !== stall0 + 3) fail("T5c ill_rd count");
        result("T5 (J5 defined illegal/empty reads + counters)", e0);

        // ================= T2: J4 wrap, 300 frames =================
        e0 = errs;
        seq_exp = fid - 4;                               // fids 25,26,27 still resident
        while (ro_outstanding != 0) begin
            do_read(1'b0, 0);
            check_frame(seq_exp, flen_of[seq_exp], "T2-pre");
            seq_exp = seq_exp + 1;
        end
        base = fid; seq_exp = fid;
        stall0  = ro_wr_stall;
        commit0 = ro_wr_frame;
        for (k = 0; k < 300; k = k + 1) begin
            len = 64 + (k % 8) * 100;
            flen_of[fid] = len;
            send_frame(fid, len, 1'b1, sentb);
            if (!sentb) fail("T2 send");
            fid = fid + 1;
            if ((k % 4) == 3) begin
                do_read(1'b0, 0);
                check_frame(seq_exp, flen_of[seq_exp], "T2");
                seq_exp = seq_exp + 1;
            end
        end
        while (ro_outstanding != 0) begin
            do_read(1'b0, 0);
            check_frame(seq_exp, flen_of[seq_exp], "T2-drain");
            seq_exp = seq_exp + 1;
        end
        if (ro_wr_stall !== stall0) fail("T2 unexpected slot stall");
        if (ro_wr_frame !== commit0 + 300) fail("T2 commit count");
        if (ro_u_wr_frame !== ro_wr_frame) fail("T2 differential chain (user vs ui)");
        result("T2 (J4 300 frames through a wrapping 256-slot region)", e0);

        // ================= T3: slot watermark / no overwrite =================
        e0 = errs;
        stall0  = ro_wr_stall;
        u0      = ro_u_wr_frame;
        drop0   = ro_u_buf_drop;
        base    = fid;
        commit0 = ro_wr_frame;
        k = 0; fill_guard = 0;
        while (ro_outstanding < 256 && fill_guard < 4000) begin
            fill_guard = fill_guard + 1;
            if (wr_hold === 1'b1) @(negedge user_clk);
            else begin
                flen_of[fid] = 1466;
                send_frame(fid, 1466, 1'b1, sentb);
                if (!sentb) break;
                fid = fid + 1;
                k   = k + 1;
            end
        end
        pushed_fill = ro_u_wr_frame - u0;
        stall_fill  = ro_wr_stall;
        drop_fill   = ro_u_buf_drop;
        if (ro_outstanding !== 256) begin
            $display("[FAIL] T3 fill: outstanding=%0d (frame sends=%0d)", ro_outstanding, k);
            errs = errs + 1;
        end
        $display("T3 fill: sends=%0d pushed=%0d committed=%0d outstanding=%0d",
                 k, pushed_fill, ro_wr_frame - commit0, ro_outstanding);

        commit_refuse = ro_wr_frame;
        // 8 frames sent with wr_hold deliberately ignored: they must be REFUSED.
        // Refusal is split by design between the two sides of the CDC:
        //   user side  -> u_buf_drop (no room seen before the frame started)
        //   bridge side-> wr_stall   (accepted, then found the slot still FULL)
        for (i = 0; i < 8; i = i + 1) send_frame(fid + i, 300, 1'b0, sentb);
        repeat (40000) @(posedge ui_clk);
        if (ro_wr_frame !== commit_refuse) fail("T3 refused frames must not commit");
        // Differential chain (user_clk counters vs ui_clk counters):
        //   pushed == committed + bridge-side refusals
        // buffer drops never entered the bridge, so they are counted separately.
        pushed_total    = ro_u_wr_frame - u0;
        committed_total = ro_wr_frame - commit0;
        refused_total   = (ro_wr_stall - stall0) + (ro_u_buf_drop - drop0);
        if (pushed_total !== (committed_total + (ro_wr_stall - stall0))) begin
            $display("[FAIL] T3 chain pushed=%0d committed=%0d bridge_stall=%0d",
                     pushed_total, committed_total, ro_wr_stall - stall0);
            errs = errs + 1;
        end else begin
            $display("T3 chain: pushed=%0d == committed=%0d + bridge_stall=%0d  |  refusals counted=%0d (buffer drops=%0d)",
                     pushed_total, committed_total, ro_wr_stall - stall0, refused_total, ro_u_buf_drop - drop0);
        end
        if (refused_total < 8) fail("T3 refusals with wr_hold ignored must be counted");

        seq_exp = base;
        for (i = 0; i < 256; i = i + 1) begin
            do_read(1'b0, 0);
            check_frame(seq_exp, 1466, "T3");
            seq_exp = seq_exp + 1;
        end
        if (ro_outstanding != 0) fail("T3 after drain not empty");
        if (ro_bresp_err != 0)  fail("T3 bresp errors");
        result("T3 (slot watermark: no unread frame overwritten, refusals counted)", e0);

        // ================= static budget measurement =================
        wr_cpf = dbg_wr_cycles * 1.0 / ro_wr_frame;
        rd_cpf = dbg_rd_cycles * 1.0 / ro_rd_frame;
        $display("STAT counters: wm=%0d wr_frame=%0d rd_frame=%0d wr_stall=%0d ill_rd=%0d noframe=%0d bresp_err=%0d",
                 ro_wm, ro_wr_frame, ro_rd_frame, ro_wr_stall, ro_ill_rd, ro_noframe, ro_bresp_err);
        $display("STAT axi: wr_beats=%0d rd_beats=%0d 4k_violation=%0d axi_proto_err=%0d",
                 dbg_wr_beats, dbg_rd_beats, mon_4k, mon_err);
        $display("STAT margin: user_pushed=%0d ui_committed=%0d user_drop=%0d hold_cycles=%0d",
                 ro_u_wr_frame, ro_wr_frame, ro_u_buf_drop, ro_u_hold_cycles);
        $display("STAT service: wr=%.0f ui-cycles/frame (%.2f us @300MHz)  rd=%.0f (%.2f us)  frame period 12.30 us",
                 wr_cpf, wr_cpf*3.3333/1000.0, rd_cpf, rd_cpf*3.3333/1000.0);

        if (mon_4k != 0) fail("AXI 4KB boundary crossed");
        if (mon_err != 0) fail("AXI protocol/length error");

        if (errs == 0) $display("=== prj10 W2 SIM: PASS (0 errors) ===");
        else           $display("=== prj10 W2 SIM: FAIL (%0d errors) ===", errs);
        $finish;
    end

    initial begin
        #60_000_000;   // 60 ms watchdog
        $display("[FAIL] GLOBAL TIMEOUT");
        $finish;
    end

endmodule
