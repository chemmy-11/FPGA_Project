// dbg_tb.sv -- single-frame trace of the write/read FSM (W2 bring-up aid)
`timescale 1ns/1ps
module dbg_tb;
    reg user_clk = 0, ui_clk = 0;
    always #3.3    user_clk = ~user_clk;
    always #1.6665 ui_clk   = ~ui_clk;
    reg user_rst_n = 0, ui_rst_n = 0, calib_ok = 0;
    reg [7:0] wr_data = 0; reg wr_en = 0;
    wire wr_hold; wire [7:0] rd_data; wire rd_en; wire [7:0] rd_slot_o; wire [15:0] rd_len_o;
    wire rd_frame_done; reg rd_req = 0; reg cfg_mode = 0; reg [7:0] cfg_rd_slot = 0; wire rd_busy;
    wire [15:0] ro_u_wr_frame, ro_u_rd_frame, ro_u_buf_drop;
    wire [31:0] ro_u_hold_cycles; wire [8:0] ro_outstanding_sync;
    wire [15:0] ro_wm, ro_wr_frame, ro_wr_stall, ro_rd_frame, ro_ill_rd, ro_noframe, ro_bresp_err;
    wire [8:0] ro_outstanding; wire [7:0] ro_dbg_wr_slot, ro_dbg_rd_slot;
    wire [31:0] dbg_wr_cycles, dbg_rd_cycles, dbg_wr_beats, dbg_rd_beats;
    wire [31:0] m_awaddr; wire [7:0] m_awlen; wire [2:0] m_awsize; wire [1:0] m_awburst;
    wire m_awvalid, m_awready; wire [511:0] m_wdata; wire [63:0] m_wstrb;
    wire m_wlast, m_wvalid, m_wready; wire [1:0] m_bresp; wire m_bvalid, m_bready;
    wire [31:0] m_araddr; wire [7:0] m_arlen; wire [2:0] m_arsize; wire [1:0] m_arburst;
    wire m_arvalid, m_arready; wire [511:0] m_rdata; wire [1:0] m_rresp;
    wire m_rlast, m_rvalid, m_rready; wire [31:0] mon_4k, mon_wb, mon_rb, mon_err;

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
        .ro_bresp_err(ro_bresp_err), .ro_outstanding(ro_outstanding),
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

    axi4_ram_model #(.MEM_BYTES(1<<14), .AR_LAT(8), .STALL_EN(0)) u_ram (
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

    integer n;
    initial begin
        repeat (8) @(posedge user_clk);
        user_rst_n = 1; ui_rst_n = 1;
        repeat (8) @(posedge user_clk);
        calib_ok = 1;
        // drive exactly one 100-byte frame
        @(negedge user_clk);
        wr_en = 1; wr_data = 8'h00;
        for (n = 1; n < 100; n = n + 1) begin @(negedge user_clk); wr_data = n[7:0]; end
        @(negedge user_clk); wr_en = 0; wr_data = 0;
        // trace
        for (n = 0; n < 1500; n = n + 1) begin
            @(posedge ui_clk);
            $display("t=%0t wst=%0d wdE=%b wfE=%b wfL=%0d wdD=%0d wlen=%0d wbeats=%0d wbeat=%0d wbi=%0d bfull=%b awv=%b awr=%b wv=%b wr=%b bv=%b brdy=%b wm=%0d ost=%0d ubwl=%0d udf=%b udE=%b u_wr=%0d u_drop=%0d cal=%b",
              $time, dut.u_bridge.wst, dut.ud_empty, dut.ub_empty, dut.ub_rl, dut.ud_dout,
              dut.u_bridge.w_len, dut.u_bridge.w_beats, dut.u_bridge.w_beat, dut.u_bridge.w_bi,
              dut.u_bridge.w_beat_full, m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready,
              ro_wm, ro_outstanding, dut.ub_wl, dut.ud_full, dut.ud_empty, ro_u_wr_frame, ro_u_buf_drop, calib_ok);
        end
        $finish;
    end
endmodule
