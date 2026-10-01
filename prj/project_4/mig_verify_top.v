// ============================================================================
// mig_verify_top.v — MIG/DDR4 bring-up verification wrapper (2026-08-31)
// Self-written minimal AXI4 master: write 256-beat pattern burst -> read back
// -> compare -> err counter. ILA on ui_clk. LEDs: T22=init_calib, T23=pass.
// ============================================================================
`timescale 1ns/1ps

module mig_verify_top (
    // DDR4 physical interface (pass-through to u_ddr4, constrained by mig_verify_pins.xdc)
    inout  [63:0] c0_ddr4_dq,
    inout  [7:0]  c0_ddr4_dqs_t,
    inout  [7:0]  c0_ddr4_dqs_c,
    inout  [7:0]  c0_ddr4_dm_dbi_n,
    output [16:0] c0_ddr4_adr,
    output [1:0]  c0_ddr4_ba,
    output [0:0]  c0_ddr4_bg,
    output [0:0]  c0_ddr4_cke,
    output [0:0]  c0_ddr4_cs_n,
    output [0:0]  c0_ddr4_odt,
    output [0:0]  c0_ddr4_ck_t,
    output [0:0]  c0_ddr4_ck_c,
    output        c0_ddr4_reset_n,
    output        c0_ddr4_act_n,
    // clocks / reset / status
    input         sys_clk_p,        // AK17 (100MHz diff, MIG system clock)
    input         sys_clk_n,        // AK16
    input         sys_rst_btn,      // AC34, active-low board reset button
    output        led_calib,        // T22: init_calib_complete
    output        led_pass          // T23: test done & err_count==0
);

    // ------------------------------------------------------------------
    // MIG core
    // ------------------------------------------------------------------
    wire         c0_init_calib_complete;
    wire         c0_ddr4_ui_clk;
    wire         c0_ddr4_ui_clk_sync_rst;
    wire [511:0] dbg_bus;              // core output, left open at top

    wire c0_ddr4_aresetn = ~c0_ddr4_ui_clk_sync_rst;

    // ------------------------------------------------------------------
    // AXI4 master (combinational outputs from state/counters)
    // ------------------------------------------------------------------
    localparam S_IDLE=3'd0, S_WR_ADDR=3'd1, S_WR_DATA=3'd2, S_WR_RESP=3'd3,
               S_RD_ADDR=3'd4, S_RD_DATA=3'd5, S_DONE=3'd6;

    reg  [2:0]  state;
    reg  [7:0]  wbeat, rbeat;
    reg  [15:0] err_cnt;
    reg         test_done, test_pass, bresp_bad, rresp_bad;
    reg         awvalid_r, arvalid_r, bready_r;

    wire go = c0_init_calib_complete & c0_ddr4_aresetn;

    // write channel: continuous data/last from beat counter
    assign s_axi_wvalid_o = (state==S_WR_DATA);
    assign s_axi_wdata_o  = {64{wbeat}};
    assign s_axi_wlast_o  = (state==S_WR_DATA) && (wbeat==8'd255);

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    always @(posedge c0_ddr4_ui_clk) begin
        if (~c0_ddr4_aresetn) begin
            state<=S_IDLE; wbeat<=0; rbeat<=0; err_cnt<=0;
            test_done<=0; test_pass<=0; bresp_bad<=0; rresp_bad<=0;
            awvalid_r<=0; arvalid_r<=0; bready_r<=0;
        end else begin
            case (state)
            S_IDLE: if (go) state <= S_WR_ADDR;
            // ---- write address ----
            S_WR_ADDR: begin
                awvalid_r <= 1'b1;
                if (awvalid_r && awready_i) begin
                    awvalid_r <= 1'b0;
                    wbeat     <= 8'd0;
                    state     <= S_WR_DATA;
                end
            end
            // ---- write data: 256 beats then wait response ----
            S_WR_DATA: if (s_axi_wvalid_o && wready_i) begin
                if (wbeat==8'd255) begin
                    bready_r <= 1'b1;
                    state    <= S_WR_RESP;
                end else begin
                    wbeat <= wbeat + 8'd1;
                end
            end
            // ---- write response ----
            S_WR_RESP: if (bvalid_i && bready_r) begin
                bready_r  <= 1'b0;
                bresp_bad <= bresp_bad | (bresp_i!=2'b00);
                state     <= S_RD_ADDR;
            end
            // ---- read address ----
            S_RD_ADDR: begin
                arvalid_r <= 1'b1;
                if (arvalid_r && arready_i) begin
                    arvalid_r <= 1'b0;
                    rbeat     <= 8'd0;
                    state     <= S_RD_DATA;
                end
            end
            // ---- read data: compare pattern per beat ----
            S_RD_DATA: if (rvalid_i) begin
                if (rdata_i != {64{rbeat}})      err_cnt   <= err_cnt + 16'd1;
                rresp_bad <= rresp_bad | (rresp_i!=2'b00);
                if (rlast_i) begin
                    test_done <= 1'b1;
                    test_pass <= (err_cnt==16'd0) && !bresp_bad && !rresp_bad;
                    state     <= S_DONE;
                end else begin
                    rbeat <= rbeat + 8'd1;
                end
            end
            S_DONE: state <= S_DONE;
            default: state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Glue: FSM <-> core signals
    // ------------------------------------------------------------------
    wire        awready_i, arready_i, wready_i;
    wire        bvalid_i, rvalid_i, rlast_i;
    wire [1:0]  bresp_i, rresp_i;
    wire [511:0] rdata_i;
    wire        awvalid_i, arvalid_i, wvalid_i, wlast_i, bready_i, rready_i;
    wire [31:0] awaddr_i, araddr_i;
    wire [7:0]  awlen_i, arlen_i;
    wire [2:0]  awsize_i, arsize_i;
    wire [1:0]  awburst_i, arburst_i;
    wire [511:0] wdata_i;
    wire [63:0] wstrb_i;

    assign awvalid_i = awvalid_r;
    assign arvalid_i = arvalid_r;
    assign bready_i  = bready_r;
    assign awaddr_i  = 32'h0;
    assign araddr_i  = 32'h0;
    assign awlen_i   = 8'd255;
    assign arlen_i   = 8'd255;
    assign awsize_i  = 3'b110;      // 64 bytes/beat (512-bit)
    assign arsize_i  = 3'b110;
    assign awburst_i = 2'b01;       // INCR
    assign arburst_i = 2'b01;
    assign wvalid_i  = s_axi_wvalid_o;
    assign wdata_i   = s_axi_wdata_o;
    assign wlast_i   = s_axi_wlast_o;
    assign wstrb_i   = {64{1'b1}};
    assign rready_i  = 1'b1;

    // ------------------------------------------------------------------
    // LEDs (registered in ui_clk domain)
    // ------------------------------------------------------------------
    reg led_calib_r, led_pass_r;
    always @(posedge c0_ddr4_ui_clk) begin
        led_calib_r <= c0_init_calib_complete;
        led_pass_r  <= test_done & (err_cnt==16'd0) & !bresp_bad & !rresp_bad;
    end
    assign led_calib = led_calib_r;
    assign led_pass  = led_pass_r;

    // ------------------------------------------------------------------
    // ILA (directly instantiated, ui_clk domain)
    // ------------------------------------------------------------------
    wire [2:0]  probe_state = state;
    wire [15:0] probe_err   = err_cnt;
    wire [7:0]  probe_wbeat = wbeat;
    wire [7:0]  probe_rbeat = rbeat;
    wire [5:0]  probe_flags = {test_done, test_pass, c0_init_calib_complete,
                               bresp_bad, rresp_bad, rvalid_i};

    ila_mig u_ila (
        .clk    (c0_ddr4_ui_clk),
        .probe0 (probe_state),
        .probe1 (probe_err),
        .probe2 (probe_wbeat),
        .probe3 (probe_rbeat),
        .probe4 (probe_flags)
    );

    // ------------------------------------------------------------------
    // ddr4_0 core instantiation
    // ------------------------------------------------------------------
    ddr4_0 u_ddr4 (
        .c0_init_calib_complete (c0_init_calib_complete),
        .dbg_clk                (),
        .c0_sys_clk_p           (sys_clk_p),
        .c0_sys_clk_n           (sys_clk_n),
        .dbg_bus                (dbg_bus),
        .c0_ddr4_adr            (c0_ddr4_adr),
        .c0_ddr4_ba             (c0_ddr4_ba),
        .c0_ddr4_cke            (c0_ddr4_cke),
        .c0_ddr4_cs_n           (c0_ddr4_cs_n),
        .c0_ddr4_dm_dbi_n       (c0_ddr4_dm_dbi_n),
        .c0_ddr4_dq             (c0_ddr4_dq),
        .c0_ddr4_dqs_c          (c0_ddr4_dqs_c),
        .c0_ddr4_dqs_t          (c0_ddr4_dqs_t),
        .c0_ddr4_odt            (c0_ddr4_odt),
        .c0_ddr4_bg             (c0_ddr4_bg),
        .c0_ddr4_reset_n        (c0_ddr4_reset_n),
        .c0_ddr4_act_n          (c0_ddr4_act_n),
        .c0_ddr4_ck_c           (c0_ddr4_ck_c),
        .c0_ddr4_ck_t           (c0_ddr4_ck_t),
        .c0_ddr4_ui_clk         (c0_ddr4_ui_clk),
        .c0_ddr4_ui_clk_sync_rst(c0_ddr4_ui_clk_sync_rst),
        .c0_ddr4_aresetn        (c0_ddr4_aresetn),
        .c0_ddr4_s_axi_awid     (4'b0),
        .c0_ddr4_s_axi_awaddr   (awaddr_i),
        .c0_ddr4_s_axi_awlen    (awlen_i),
        .c0_ddr4_s_axi_awsize   (awsize_i),
        .c0_ddr4_s_axi_awburst  (awburst_i),
        .c0_ddr4_s_axi_awlock   (1'b0),
        .c0_ddr4_s_axi_awcache  (4'b0),
        .c0_ddr4_s_axi_awprot   (3'b0),
        .c0_ddr4_s_axi_awqos    (4'b0),
        .c0_ddr4_s_axi_awvalid  (awvalid_i),
        .c0_ddr4_s_axi_awready  (awready_i),
        .c0_ddr4_s_axi_wdata    (wdata_i),
        .c0_ddr4_s_axi_wstrb    (wstrb_i),
        .c0_ddr4_s_axi_wlast    (wlast_i),
        .c0_ddr4_s_axi_wvalid   (wvalid_i),
        .c0_ddr4_s_axi_wready   (wready_i),
        .c0_ddr4_s_axi_bready   (bready_i),
        .c0_ddr4_s_axi_bid      (),
        .c0_ddr4_s_axi_bresp    (bresp_i),
        .c0_ddr4_s_axi_bvalid   (bvalid_i),
        .c0_ddr4_s_axi_arid     (4'b0),
        .c0_ddr4_s_axi_araddr   (araddr_i),
        .c0_ddr4_s_axi_arlen    (arlen_i),
        .c0_ddr4_s_axi_arsize   (arsize_i),
        .c0_ddr4_s_axi_arburst  (arburst_i),
        .c0_ddr4_s_axi_arlock   (1'b0),
        .c0_ddr4_s_axi_arcache  (4'b0),
        .c0_ddr4_s_axi_arprot   (3'b0),
        .c0_ddr4_s_axi_arqos    (4'b0),
        .c0_ddr4_s_axi_arvalid  (arvalid_i),
        .c0_ddr4_s_axi_arready  (arready_i),
        .c0_ddr4_s_axi_rready   (rready_i),
        .c0_ddr4_s_axi_rlast    (rlast_i),
        .c0_ddr4_s_axi_rvalid   (rvalid_i),
        .c0_ddr4_s_axi_rresp    (rresp_i),
        .c0_ddr4_s_axi_rid      (),
        .c0_ddr4_s_axi_rdata    (rdata_i),
        .sys_rst                (sys_rst_btn)
    );

endmodule
