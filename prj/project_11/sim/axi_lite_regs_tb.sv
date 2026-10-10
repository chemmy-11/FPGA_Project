`timescale 1ns/1ps
//=============================================================================
// axi_lite_regs_tb.sv -- prj11 B1 unit bench (positive + negative via define)
//
// Positive (plain DUT):
//   P1 reset defaults            P2 MODE write -> cfg_mode + one cfg_wr_pulse
//   P3 RD_SLOT write             -> cfg settles BEFORE the pulse, width == 1,
//                                   capture flop (frame_mem_if style) samples
//                                   the NEW slot at the pulse edge
//   P4 back-to-back RD_SLOT      -> two pulses, two slots, no lost write
//   P5 reads                     -> WM_WR/WM_RD/WM_DROP/SLOTMAP/STATUS/ID
//   P6 write to RO offset        -> OKAY, no cfg change, no pulse
//   P7 bvalid/rvalid held until ready
// Negative (xvlog -d AXI_LITE_REGS_DEFECT): P3 must FAIL -- the pulse fires in
//   the same cycle the slot is written, the capture flop samples the OLD slot.
//
// BFM discipline: all stimulus drives on NEGEDGE aclk, exactly one posedge
// sampling window per transaction (no "wait for ready to rise again" loops --
// a level-held valid + such a loop re-issues a transaction every mailbox
// round trip; that race was the cause of the first bench version's livelock).
// Verdict line (last): "=== prj11 B1 LITE SIM: PASS (0 errors) ==="
//=============================================================================
module axi_lite_regs_tb;

    // two asynchronous clocks, as on the board
    reg aclk = 0;      always #5.0   aclk  = ~aclk;        // 100 MHz
    reg clk_user = 0;  always #3.294 clk_user = ~clk_user; // ~151.7 MHz
    reg aresetn = 0, rst_user_n = 0;

    // lite master side (driven on negedge)
    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, arvalid = 0, bready = 1, rready = 1;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    // user side
    reg  [15:0] u_wr_frame = 16'h1234, u_rd_frame = 16'h0456, u_buf_drop = 16'd7;
    reg         ctl_owner = 1'b1;
    wire        cfg_mode, rd_req_pulse, cfg_wr_pulse;
    wire [7:0]  cfg_rd_slot;
    wire [15:0] lite_exec_cnt, lite_rd_trig_cnt;

    axi_lite_regs dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata),   .s_axi_wvalid(wvalid),   .s_axi_wready(wready),
        .s_axi_bresp(bresp),   .s_axi_bvalid(bvalid),   .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata),   .s_axi_rresp(rresp),     .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .clk_user(clk_user), .rst_user_n(rst_user_n),
        .u_wr_frame(u_wr_frame), .u_rd_frame(u_rd_frame), .u_buf_drop(u_buf_drop),
        .ctl_owner(ctl_owner),
        .cfg_mode(cfg_mode), .cfg_rd_slot(cfg_rd_slot),
        .rd_req_pulse(rd_req_pulse), .cfg_wr_pulse(cfg_wr_pulse),
        .lite_exec_cnt(lite_exec_cnt), .lite_rd_trig_cnt(lite_rd_trig_cnt)
    );

    // frame_mem_if-style capture: samples cfg at the pulse edge
    reg [7:0] cap_slot = 0;   reg cap_mode = 0;
    always @(posedge clk_user) if (rd_req_pulse) begin
        cap_slot <= cfg_rd_slot;
        cap_mode <= cfg_mode;
    end

    // pulse width + count monitors (user domain)
    integer pulse_cnt = 0, wrp_cnt = 0, max_w = 0, w_run = 0;
    always @(posedge clk_user) begin
        if (rd_req_pulse) begin
            w_run = w_run + 1;
            if (w_run > max_w) max_w = w_run;
        end
        else begin
            if (w_run > 0) pulse_cnt = pulse_cnt + 1;
            w_run = 0;
        end
        if (cfg_wr_pulse) wrp_cnt = wrp_cnt + 1;
    end

    integer errors = 0;

`ifdef AXI_LITE_REGS_DEFECT
    initial $display("[NEG] TB sees DEFECT define (negative control active)");
`endif

    task automatic chk(input cond, input string msg);
        if (!cond) begin
            errors = errors + 1;
            $display("[FAIL] %s  (t=%0t)", msg, $time);
        end
    endtask

    // ---- negedge-driven handshake BFMs ----
    // Drive on negedge; only release valid AFTER observing ready==1 at a
    // negedge (so the next posedge accepts). A fixed one-posedge pulse loses
    // the transaction whenever ready happens to be low on that edge -- that
    // was the "alternating stale read" artifact of the first bench version.
    task automatic lite_wr(input [31:0] a, input [31:0] d);
        begin
            @(negedge aclk);
            awaddr = a; awvalid = 1;
            wdata  = d; wvalid  = 1;
            while (awready !== 1'b1 || wready !== 1'b1) @(negedge aclk);
            @(posedge aclk);          // this edge accepts AW+W
            @(negedge aclk);
            awvalid = 0; wvalid = 0;
            while (!bvalid) @(negedge aclk);
            @(negedge aclk);
        end
    endtask

    task automatic lite_rd(input [31:0] a, output [31:0] d);
        begin
            @(negedge aclk);
            araddr = a; arvalid = 1;
            while (arready !== 1'b1) @(negedge aclk);
            @(posedge aclk);          // this edge accepts AR
            @(negedge aclk);
            arvalid = 0;
            while (rvalid !== 1'b0) @(negedge aclk);  // previous fully consumed
            while (!rvalid) @(negedge aclk);          // THIS transaction's data
            d = rdata;
            @(negedge aclk);
        end
    endtask

    reg [31:0] rd;

    initial begin
        $display("=== prj11 B1 axi_lite_regs unit sim ===");
        rst_user_n = 0; aresetn = 0;
        repeat (10) @(negedge aclk);
        rst_user_n = 1; aresetn = 1;
        repeat (10) @(negedge aclk);

        // ---- P1 reset defaults
        chk(cfg_mode === 1'b0 && cfg_rd_slot === 8'd0, "P1 reset defaults");
        chk(lite_exec_cnt === 16'd0 && lite_rd_trig_cnt === 16'd0, "P1 counters");
        $display("[P1] reset defaults checked");

        // ---- P2 MODE write
        lite_wr(32'h0, 32'h1);
        repeat (12) @(negedge aclk);
        chk(cfg_mode === 1'b1, "P2 cfg_mode set");
        chk(wrp_cnt == 1, "P2 exactly one cfg_wr_pulse");
        chk(pulse_cnt == 0, "P2 no read pulse on MODE write");
        $display("[P2] MODE=1 -> cfg_mode=%0b wrp_cnt=%0d", cfg_mode, wrp_cnt);

        // ---- P3 RD_SLOT write (settle contract)
        cap_slot = 8'h00;
        lite_wr(32'h4, 32'h0000_00A5);
        repeat (12) @(negedge aclk);
        chk(cfg_rd_slot === 8'hA5, "P3 cfg_rd_slot set");
        chk(pulse_cnt == 1, "P3 exactly one rd_req_pulse");
        chk(max_w == 1, "P3 pulse width == 1 clk");
        chk(cap_slot === 8'hA5, "P3 settle contract (capture@pulse == written slot)");
`ifndef AXI_LITE_REGS_DEFECT
        chk(cap_mode === 1'b1, "P3 mode forced RND on read");
`endif
        $display("[P3] RD_SLOT=A5 -> slot=%02x pulses=%0d maxw=%0d cap=%02x",
                 cfg_rd_slot, pulse_cnt, max_w, cap_slot);

        // ---- P4 back-to-back RD_SLOT
        lite_wr(32'h4, 32'h0000_003C);
        repeat (4) @(negedge aclk);
        lite_wr(32'h4, 32'h0000_00C3);
        repeat (12) @(negedge aclk);
        chk(pulse_cnt == 3, "P4 three pulses total (no lost write)");
        chk(cfg_rd_slot === 8'hC3, "P4 last slot wins");
        chk(cap_slot === 8'hC3, "P4 capture == last slot");
        chk(lite_rd_trig_cnt === 16'd3, "P4 trigger counter");
        $display("[P4] back-to-back: pulses=%0d slot=%02x trig=%0d",
                 pulse_cnt, cfg_rd_slot, lite_rd_trig_cnt);

        // ---- P5 reads
        lite_rd(32'h08, rd); $display("[P5] rd@08=%08x", rd); chk(rd[15:0] === 16'h1234, "P5 WM_WR");
        lite_rd(32'h0C, rd); $display("[P5] rd@0C=%08x", rd); chk(rd[15:0] === 16'h0456, "P5 WM_RD");
        lite_rd(32'h10, rd); $display("[P5] rd@10=%08x", rd); chk(rd[15:0] === 16'd7,    "P5 WM_DROP");
        lite_rd(32'h14, rd); $display("[P5] rd@14=%08x", rd); chk(rd[31:24] === 8'd1 && rd[23:16] === 8'h34, "P5 SLOTMAP rule/ptr");
        lite_rd(32'h18, rd); $display("[P5] rd@18=%08x", rd); chk(rd[17:16] === 2'b10 && rd[15:0] === 16'd3, "P5 STATUS owner/trig");
        lite_rd(32'h1C, rd); $display("[P5] rd@1C=%08x", rd); chk(rd === 32'h5031_4231, "P5 ID magic");
        // change inputs, re-read (fresh snapshot, not stale)
        u_wr_frame = 16'hBEEF; u_rd_frame = 16'hCAFE; u_buf_drop = 16'd0;
        lite_rd(32'h08, rd); chk(rd[15:0] === 16'hBEEF, "P5 fresh snapshot");
        lite_rd(32'h0C, rd); chk(rd[15:0] === 16'hCAFE, "P5 fresh snapshot 2");
        $display("[P5] all reads done");

        // ---- P6 write to RO offset
        pulse_cnt = 0;
        lite_wr(32'h08, 32'hFFFF_FFFF);     // WM_WR is RO
        repeat (12) @(negedge aclk);
        chk(pulse_cnt == 0, "P6 no pulse on RO write");
        chk(cfg_rd_slot === 8'hC3, "P6 slot unchanged");
        chk(lite_exec_cnt === 16'd4, "P6 ignored write not counted");  // P2+P3+P4x2 = 4
        $display("[P6] RO write ignored (exec=%0d)", lite_exec_cnt);

        // ---- P7 response held until ready
        bready = 0;
        fork
            lite_wr(32'h0, 32'h0);          // MODE=0 (back to SEQ)
        join_none
        repeat (6) @(negedge aclk);
        chk(bvalid === 1'b1, "P7 bvalid held while !bready");
        repeat (10) @(negedge aclk);
        chk(bvalid === 1'b1, "P7 bvalid still held");
        bready = 1;
        repeat (20) @(negedge aclk);
        chk(cfg_mode === 1'b0, "P7 SEQ restored");
        $display("[P7] bvalid handshake ok, cfg_mode=%0b", cfg_mode);

        // ---- verdict
        if (errors == 0) begin
            $display("=== prj11 B1 LITE SIM: PASS (0 errors) ===");
            $finish;
        end
        else begin
            $display("=== prj11 B1 LITE SIM: FAIL (%0d errors) ===", errors);
            $finish;
        end
    end

    // watchdog (real time bounded: 50 us of sim time)
    initial begin
        #50_000;
        $display("=== prj11 B1 LITE SIM: FAIL (timeout) ===");
        $finish;
    end

endmodule
