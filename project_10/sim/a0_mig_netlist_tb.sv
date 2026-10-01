// ============================================================================
// a0_mig_netlist_tb.sv -- A0: bridge <-> REAL MIG netlist <-> DDR4 model
// prj10 W3 Track-A step A0 (Lead, 2026-10-01)
//
// WHY: the W2 "PASS" ran against axi4_ram_model (instant answer, addr mod 2^20).
//      Before track-B (board) this is the ONLY path proving "the bridge and the
//      MIG speak the same language":
//        - real ddr4_0 netlist (17 MB, from project_4, 2023.1)
//        - official ddr4_model.sv memory (4x x16 = 64 bit, as on the board)
//        - our frame_mem_if bridge as the AXI master
//      Also yields sim-domain Lw/Lr (awvalid->bvalid, arvalid->rvalid first beat)
//      to calibrate the A2 latency sweep.
//
// Prerequisites (hard): A1 must be done -- the bridge must expose the 12 new
//      AXI4 ports (awid/bid/arid/rid + lock/cache/prot/qos). This TB wires ALL
//      37 s_axi signals; it will not elaborate against a 25-port bridge.
//
// NOT provable here (say it once): init_calib_complete rising in sim only shows
//      the controller logic walks calibration; physical training (write
//      leveling, read-gate) is board-only. J1 has no sim substitute.
// ============================================================================
`timescale 1ns/1ps

module a0_mig_netlist_tb;

  // ------------------------------------------------------------------
  // board geometry (from project_4 ddr4_0.xci, verified 09-29):
  //   MT40A512M16HA-083E x4 -> DQ=64, DRAM_WIDTH=16, DDR4-2400, 4:1 phy
  //   ui_clk = 300.12 MHz; sys_clk 100 MHz diff (period here = 9996 ps)
  // ------------------------------------------------------------------
  localparam DQ_WIDTH   = 64;
  localparam DRAM_WIDTH = 16;
  localparam DQS_WIDTH  = 8;    // DQ/8
  localparam DM_WIDTH   = 8;    // DQ/8, DM_NO_DBI
  localparam ADDR_WIDTH = 17;
  localparam real SYS_T = 9.996; // ns (InputClockPeriod 9996 ps)
  localparam real UI_T  = 3.331; // ns (300.12 MHz)

  // ------------------------------------------------------------------
  // clocks / reset
  // ------------------------------------------------------------------
  reg  sys_clk_i = 1'b0;
  always #(SYS_T/2.0) sys_clk_i = ~sys_clk_i;
  wire c0_sys_clk_p = sys_clk_i;
  wire c0_sys_clk_n = ~sys_clk_i;

  reg sys_rst = 1'b1;            // MIG sys_rst is ACTIVE HIGH
  initial begin #200; sys_rst = 1'b0; #100; end

  // frame-side user clock (~151.5 MHz) -- free-running
  reg user_clk = 1'b0;
  always #3.3 user_clk = ~user_clk;
  reg user_rst_n = 1'b0;
  initial begin #300; user_rst_n = 1'b1; end

  // ui_clk comes OUT of the MIG; bridge reset derived from ui_clk_sync_rst
  wire ui_clk, ui_sync_rst;
  wire calib;
  wire ui_rst_n = ~ui_sync_rst;

  // ------------------------------------------------------------------
  // DDR4 pins (between netlist and memory model)
  // ------------------------------------------------------------------
  wire [16:0] c0_ddr4_adr;  wire [1:0] c0_ddr4_ba;  wire [0:0] c0_ddr4_bg;
  wire [0:0]  c0_ddr4_cke;  wire [0:0] c0_ddr4_odt; wire [0:0] c0_ddr4_cs_n;
  wire [0:0]  c0_ddr4_ck_t; wire [0:0] c0_ddr4_ck_c;
  wire        c0_ddr4_reset_n, c0_ddr4_act_n;
  wire [7:0]  c0_ddr4_dm_dbi_n;
  wire [63:0] c0_ddr4_dq;
  wire [7:0]  c0_ddr4_dqs_t, c0_ddr4_dqs_c;

  // ------------------------------------------------------------------
  // AXI (bridge master -> MIG slave), all 37 signals
  // ------------------------------------------------------------------
  wire [3:0]  m_axi_awid;
  wire [31:0] m_axi_awaddr;  wire [7:0]  m_axi_awlen;
  wire [2:0]  m_axi_awsize;  wire [1:0]  m_axi_awburst;
  wire [0:0]  m_axi_awlock;  wire [3:0]  m_axi_awcache;
  wire [2:0]  m_axi_awprot;  wire [3:0]  m_axi_awqos;
  wire        m_axi_awvalid, m_axi_awready;
  wire [511:0] m_axi_wdata;  wire [63:0] m_axi_wstrb;
  wire        m_axi_wlast, m_axi_wvalid, m_axi_wready;
  wire        m_axi_bready, m_axi_bvalid;  wire [1:0] m_axi_bresp;
  wire [3:0]  m_axi_bid;
  wire [3:0]  m_axi_arid;
  wire [31:0] m_axi_araddr;  wire [7:0]  m_axi_arlen;
  wire [2:0]  m_axi_arsize;  wire [1:0]  m_axi_arburst;
  wire [0:0]  m_axi_arlock;  wire [3:0]  m_axi_arcache;
  wire [2:0]  m_axi_arprot;  wire [3:0]  m_axi_arqos;
  wire        m_axi_arvalid, m_axi_arready;
  wire        m_axi_rready, m_axi_rvalid, m_axi_rlast;
  wire [3:0]  m_axi_rid;     wire [1:0]  m_axi_rresp;
  wire [511:0] m_axi_rdata;

  // ------------------------------------------------------------------
  // DUT: frame_mem_if (our bridge, user_clk + ui_clk domains)
  // ------------------------------------------------------------------
  reg  [7:0] wr_data = 0;  reg wr_en = 0;
  wire       wr_hold;
  wire [7:0] rd_data;  wire rd_en;
  wire [7:0] rd_slot_o; wire [15:0] rd_len_o;
  wire       rd_frame_done; wire rd_busy;
  reg        rd_req = 0;
  reg        cfg_mode = 0;  reg [7:0] cfg_rd_slot = 0;
  wire [15:0] ro_wm, ro_wr_frame, ro_wr_stall, ro_rd_frame;
  wire [15:0] ro_ill_rd, ro_noframe, ro_bresp_err, ro_len_err;
  wire [8:0]  ro_outstanding;
  wire [7:0]  ro_dbg_wr_slot, ro_dbg_rd_slot;
  wire [31:0] dbg_wr_cycles, dbg_rd_cycles, dbg_wr_beats, dbg_rd_beats;
  wire [15:0] ro_u_wr_frame, ro_u_rd_frame, ro_u_buf_drop;
  wire [31:0] ro_u_hold_cycles; wire [8:0] ro_outstanding_sync;

  frame_mem_if #(.SLOT_BASE(32'h0010_0000), .MAX_LEN(16'd1538)) dut (
    .user_clk(user_clk), .user_rst_n(user_rst_n),
    .wr_data(wr_data), .wr_en(wr_en), .wr_hold(wr_hold),
    .rd_data(rd_data), .rd_en(rd_en), .rd_slot_o(rd_slot_o),
    .rd_len_o(rd_len_o), .rd_frame_done(rd_frame_done), .rd_req(rd_req),
    .rd_busy(rd_busy),
    .cfg_mode(cfg_mode), .cfg_rd_slot(cfg_rd_slot),
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
    .m_axi_awid(m_axi_awid),
    .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
    .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
    .m_axi_awlock(m_axi_awlock), .m_axi_awcache(m_axi_awcache),
    .m_axi_awprot(m_axi_awprot), .m_axi_awqos(m_axi_awqos),
    .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
    .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
    .m_axi_wready(m_axi_wready),
    .m_axi_bready(m_axi_bready), .m_axi_bvalid(m_axi_bvalid),
    .m_axi_bresp(m_axi_bresp), .m_axi_bid(m_axi_bid),
    .m_axi_arid(m_axi_arid),
    .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
    .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache),
    .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos),
    .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rready(m_axi_rready), .m_axi_rvalid(m_axi_rvalid),
    .m_axi_rlast(m_axi_rlast), .m_axi_rid(m_axi_rid),
    .m_axi_rresp(m_axi_rresp), .m_axi_rdata(m_axi_rdata)
  );

  // ------------------------------------------------------------------
  // MIG netlist (top module name inside ddr4_0_sim_netlist.v)
  // ------------------------------------------------------------------
  wire [511:0] dbg_bus;
  wire         c0_ddr4_aresetn = ui_rst_n;

  decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix u_mig (
    .sys_rst(sys_rst),
    .c0_sys_clk_p(c0_sys_clk_p), .c0_sys_clk_n(c0_sys_clk_n),
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
    .c0_ddr4_s_axi_awid(m_axi_awid),
    .c0_ddr4_s_axi_awaddr(m_axi_awaddr), .c0_ddr4_s_axi_awlen(m_axi_awlen),
    .c0_ddr4_s_axi_awsize(m_axi_awsize), .c0_ddr4_s_axi_awburst(m_axi_awburst),
    .c0_ddr4_s_axi_awlock(m_axi_awlock), .c0_ddr4_s_axi_awcache(m_axi_awcache),
    .c0_ddr4_s_axi_awprot(m_axi_awprot), .c0_ddr4_s_axi_awqos(m_axi_awqos),
    .c0_ddr4_s_axi_awvalid(m_axi_awvalid), .c0_ddr4_s_axi_awready(m_axi_awready),
    .c0_ddr4_s_axi_wdata(m_axi_wdata), .c0_ddr4_s_axi_wstrb(m_axi_wstrb),
    .c0_ddr4_s_axi_wlast(m_axi_wlast), .c0_ddr4_s_axi_wvalid(m_axi_wvalid),
    .c0_ddr4_s_axi_wready(m_axi_wready),
    .c0_ddr4_s_axi_bready(m_axi_bready),
    .c0_ddr4_s_axi_bid(m_axi_bid), .c0_ddr4_s_axi_bresp(m_axi_bresp),
    .c0_ddr4_s_axi_bvalid(m_axi_bvalid),
    .c0_ddr4_s_axi_arid(m_axi_arid),
    .c0_ddr4_s_axi_araddr(m_axi_araddr), .c0_ddr4_s_axi_arlen(m_axi_arlen),
    .c0_ddr4_s_axi_arsize(m_axi_arsize), .c0_ddr4_s_axi_arburst(m_axi_arburst),
    .c0_ddr4_s_axi_arlock(m_axi_arlock), .c0_ddr4_s_axi_arcache(m_axi_arcache),
    .c0_ddr4_s_axi_arprot(m_axi_arprot), .c0_ddr4_s_axi_arqos(m_axi_arqos),
    .c0_ddr4_s_axi_arvalid(m_axi_arvalid), .c0_ddr4_s_axi_arready(m_axi_arready),
    .c0_ddr4_s_axi_rready(m_axi_rready),
    .c0_ddr4_s_axi_rid(m_axi_rid), .c0_ddr4_s_axi_rdata(m_axi_rdata),
    .c0_ddr4_s_axi_rresp(m_axi_rresp), .c0_ddr4_s_axi_rlast(m_axi_rlast),
    .c0_ddr4_s_axi_rvalid(m_axi_rvalid),
    .dbg_bus(dbg_bus)
  );

  // ------------------------------------------------------------------
  // DDR4 memory model: 4x x16 (DQ=64) -- board geometry
  // (structure follows sim_tb_top_axi.sv mem_model_x16 branch)
  // ------------------------------------------------------------------
  tri model_enable = 1'b1;

  reg  wr_en_m;
  wire [DQ_WIDTH-1:0] c0_ddr4_dq_mem;
  wire [DM_WIDTH-1:0] c0_ddr4_dm_dbi_n_mem;
  wire [DQS_WIDTH-1:0] c0_ddr4_dqs_t_mem, c0_ddr4_dqs_c_mem;

  reg [ADDR_WIDTH-1:0] DDR4_ADRMOD;
  always @(*) begin
    if (c0_ddr4_act_n)
      casez (c0_ddr4_adr[16:14])
        3'b111, 3'b101: DDR4_ADRMOD = c0_ddr4_adr & 18'h1C7FF; // WR/RD mask
        default:         DDR4_ADRMOD = c0_ddr4_adr;
      endcase
    else DDR4_ADRMOD = c0_ddr4_adr;
  end

  // command decode: WR = RAS_n? CAS_n? WE_n?  => act_n=1 & ~A15(CAS) & A14(WE) & ~A16(RAS)
  wire cmd_is_wr = c0_ddr4_act_n & DDR4_ADRMOD[16] & ~DDR4_ADRMOD[15] & DDR4_ADRMOD[14];
  wire cmd_is_rd = c0_ddr4_act_n & DDR4_ADRMOD[16] & ~DDR4_ADRMOD[15] & ~DDR4_ADRMOD[14];

  always @(posedge c0_ddr4_ck_t) begin
    if (!c0_ddr4_reset_n) wr_en_m <= #0.1 1'b0;
    else if (cmd_is_wr)   wr_en_m <= #0.1 1'b1;
    else if (cmd_is_rd)   wr_en_m <= #0.1 1'b0;
  end

  // tristate plumbing between DUT pins and memory pins (x16 branch)
  assign #(0.2) c0_ddr4_dq_mem = (wr_en_m) ? c0_ddr4_dq : 'bz;
  assign        c0_ddr4_dq     = (wr_en_m) ? 'bz : c0_ddr4_dq_mem;
  assign c0_ddr4_dm_dbi_n_mem  = (wr_en_m) ? {DM_WIDTH{1'b1}} : 'bz;
  assign c0_ddr4_dm_dbi_n      = (wr_en_m) ? 'bz : c0_ddr4_dm_dbi_n_mem;
  assign #(0.1) c0_ddr4_dqs_t_mem = (wr_en_m) ? c0_ddr4_dqs_t : 'bz;
  assign         c0_ddr4_dqs_t    = (wr_en_m) ? 'bz : c0_ddr4_dqs_t_mem;
  assign #(0.1) c0_ddr4_dqs_c_mem = (wr_en_m) ? c0_ddr4_dqs_c : 'bz;
  assign         c0_ddr4_dqs_c    = (wr_en_m) ? 'bz : c0_ddr4_dqs_c_mem;

  // x16 devices: the interface must be told its configured DQ width
  DDR4_if #(DRAM_WIDTH) iDDR4[0:(DQ_WIDTH/DRAM_WIDTH)-1]();
  genvar i, j;
  generate
    for (i = 0; i < DQ_WIDTH/DRAM_WIDTH; i = i + 1) begin: memModel
      ddr4_model ddr4_model(
        .model_enable (model_enable),
        .iDDR4        (iDDR4[i])
      );
      // x16 wiring: two DQS pairs per chip
      tran bidiDQS0 (iDDR4[i].DQS_t[0], c0_ddr4_dqs_t_mem[2*i]);
      tran bidiDQS0_(iDDR4[i].DQS_c[0], c0_ddr4_dqs_c_mem[2*i]);
      tran bidiDM0  (iDDR4[i].DM_n[0],  c0_ddr4_dm_dbi_n_mem[2*i]);
      tran bidiDQS1 (iDDR4[i].DQS_t[1], c0_ddr4_dqs_t_mem[2*i+1]);
      tran bidiDQS1_(iDDR4[i].DQS_c[1], c0_ddr4_dqs_c_mem[2*i+1]);
      tran bidiDM1  (iDDR4[i].DM_n[1],  c0_ddr4_dm_dbi_n_mem[2*i+1]);
      assign iDDR4[i].CK = {c0_ddr4_ck_t, c0_ddr4_ck_c};
      assign iDDR4[i].ACT_n = c0_ddr4_act_n;
      assign iDDR4[i].RAS_n_A16 = DDR4_ADRMOD[16];
      assign iDDR4[i].CAS_n_A15 = DDR4_ADRMOD[15];
      assign iDDR4[i].WE_n_A14  = DDR4_ADRMOD[14];
      assign iDDR4[i].PARITY    = 1'b0;            // EN_PARITY=false
      assign iDDR4[i].RESET_n   = c0_ddr4_reset_n;
      assign iDDR4[i].CS_n      = c0_ddr4_cs_n[0];
      assign iDDR4[i].CKE       = c0_ddr4_cke[0];
      assign iDDR4[i].ODT       = c0_ddr4_odt[0];
      assign iDDR4[i].BG        = c0_ddr4_bg;
      assign iDDR4[i].BA        = c0_ddr4_ba;
      assign iDDR4[i].ADDR_17   = DDR4_ADRMOD[16];
      assign iDDR4[i].ADDR      = DDR4_ADRMOD[13:0];
      for (j = 0; j < DRAM_WIDTH; j = j + 1) begin: tranDQ
        tran bidiDQ(iDDR4[i].DQ[j], c0_ddr4_dq_mem[i*DRAM_WIDTH + j]);
      end
    end
  endgenerate

  // ------------------------------------------------------------------
  // Lw/Lr measurement (sim-domain calibration for A2 sweep)
  // ------------------------------------------------------------------
  time aw_t0, ar_t0;
  bit  r_beat_seen;   // per-read-burst "first beat" flag
  integer lw_cnt, lr_cnt;
  integer lw_min, lw_max, lw_sum, lr_min, lr_max, lr_sum;

  initial begin
    lw_cnt = 0; lr_cnt = 0;
    lw_min = 32'h7FFFFFFF; lw_max = 0; lw_sum = 0;
    lr_min = 32'h7FFFFFFF; lr_max = 0; lr_sum = 0;
    r_beat_seen = 1'b0;
  end

  always @(posedge ui_clk) begin
    if (m_axi_awvalid && m_axi_awready) aw_t0 <= $time;
    if (m_axi_bvalid && m_axi_bready) begin
      automatic integer d = ($time - aw_t0) / UI_T;
      lw_cnt = lw_cnt + 1;
      if (d < lw_min) lw_min = d;
      if (d > lw_max) lw_max = d;
      lw_sum = lw_sum + d;
    end
    if (m_axi_arvalid && m_axi_arready) begin
      ar_t0 <= $time;
      r_beat_seen <= 1'b0;
    end
    if (m_axi_rvalid && m_axi_rready && !r_beat_seen) begin
      automatic integer d2 = ($time - ar_t0) / UI_T;
      lr_cnt = lr_cnt + 1;
      if (d2 < lr_min) lr_min = d2;
      if (d2 > lr_max) lr_max = d2;
      lr_sum = lr_sum + d2;
      r_beat_seen <= 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // test flow: wait calib -> write 4 frames -> SEQ read back -> compare
  // ------------------------------------------------------------------
  integer errors = 0;
  integer fid;
  reg [7:0] flen_of [0:63];
  reg [7:0] mem_ref [0:63][0:1539];
  integer n_frames = 4;
  integer k;

  task send_frame(input [7:0] len);
    integer i;
    reg [7:0] pat;
    begin
      flen_of[fid] = len;
      for (i = 0; i < len; i = i + 1) begin
        pat = (fid ^ i[7:0]) & 8'hFF;
        mem_ref[fid][i] = pat;
        @(negedge user_clk);
        wr_data = pat; wr_en = 1'b1;
      end
      @(negedge user_clk); wr_en = 1'b0;
      fid = fid + 1;
    end
  endtask

  task read_one_frame;
    integer i, got;
    reg [7:0] expct;
    begin
      @(negedge user_clk); rd_req = 1'b1;
      @(negedge user_clk); rd_req = 1'b0;
      i = 0;
      while (i < 20000) begin
        @(posedge user_clk);
        if (rd_en) begin
          got   = rd_data;
          expct = mem_ref[rd_slot_o][i];
          if (got[7:0] !== expct) begin
            errors = errors + 1;
            $display("[A0][FAIL] slot=%0d byte %0d: got %02h exp %02h", rd_slot_o, i, got[7:0], expct);
          end
          i = i + 1;
        end
        if (rd_frame_done && i >= 1) i = 20000;
      end
    end
  endtask

  initial begin
    fid = 0;
    $display("[A0] === bridge <-> real MIG netlist <-> ddr4_model (x16 x4) ===");
    $display("[A0] waiting for init_calib_complete (sim calibration) ...");

    wait (calib === 1'b1);
    #1000;
    $display("[A0] calib up at %0t ns -- sending %0d frames", $time, n_frames);

    send_frame(8'd26);
    send_frame(8'd100);
    send_frame(8'd1000);
    send_frame(8'd1466);
    #20000;

    $display("[A0] after writes: wm=%0d wr_frame=%0d (expect 4)", ro_wm, ro_wr_frame);
    for (k = 0; k < n_frames; k = k + 1) read_one_frame;
    #5000;

    $display("[A0] counters: wm=%0d wr=%0d rd=%0d stall=%0d ill=%0d len_err=%0d bresp_err=%0d",
             ro_wm, ro_wr_frame, ro_rd_frame, ro_wr_stall, ro_ill_rd, ro_len_err, ro_bresp_err);
    if (lw_cnt > 0) $display("[A0] Lw (sim): n=%0d min=%0d max=%0d avg=%0d ui-cyc",
                             lw_cnt, lw_min, lw_max, lw_sum/lw_cnt);
    else $display("[A0] Lw (sim): not captured");
    if (lr_cnt > 0) $display("[A0] Lr (sim): n=%0d min=%0d max=%0d avg=%0d ui-cyc",
                             lr_cnt, lr_min, lr_max, lr_sum/lr_cnt);
    else $display("[A0] Lr (sim): not captured");

    if (errors == 0 && ro_wm == n_frames && ro_rd_frame == n_frames
        && ro_bresp_err == 0 && ro_len_err == 0)
      $display("=== A0 MIG-NETLIST SIM: PASS (0 errors) ===");
    else begin
      $display("=== A0 MIG-NETLIST SIM: FAIL (errors=%0d) ===", errors);
      $fatal;
    end
    $finish;
  end

  // watchdog
  initial begin
    #60_000_000; // 60 ms sim (calibration in netlist sim can be long)
    $display("=== A0 MIG-NETLIST SIM: TIMEOUT ===");
    $fatal;
  end

endmodule
