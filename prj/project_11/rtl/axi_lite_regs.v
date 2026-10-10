//=============================================================================
// axi_lite_regs.v -- prj11 B1: AXI4-Lite slave wrapping the W5 register
//                    semantics (soft-core control plane, Q3)
//-----------------------------------------------------------------------------
// What it is (one line): the SAME four command semantics as the UDP command
// channel (SET_MODE / READ_SLOT / GET_WATERMARK / GET_SLOT_MAP), exposed as a
// memory-mapped AXI4-Lite slave so MicroBlaze C code can drive the memory
// bridge instead of the PC.
//
// Register map (32-bit, word aligned):
//   offset 0x00  MODE    W   bit0: 0 = SEQ, 1 = RND            (= SET_MODE)
//   offset 0x04  RD_SLOT W   [7:0]: slot to read; the write ALSO forces
//                                  cfg_mode=1 and fires ONE rd_req_pulse
//                                  (= READ_SLOT; identical settle-then-pulse
//                                   sequence as cmd_channel U_PULSE)
//   offset 0x08  WM_WR    R   [15:0] u_wr_frame
//   offset 0x0C  WM_RD    R   [15:0] u_rd_frame
//   offset 0x10  WM_DROP  R   [15:0] u_buf_drop
//   offset 0x14  SLOTMAP  R   [31:24] rule id = 1, [23:16] wr slot ptr
//   offset 0x18  STATUS   R   [17:16] ctl_owner (0 = UDP, 1 = soft-core),
//                                  [15:0] lite rd trigger count
//   offset 0x1C  ID       R   0x50314231 ("P1B1") -- software sanity
//   Other offsets: reads return 0 (OKAY), writes ignored (OKAY).
//
// CDC (house rule, same 4-phase discipline as cmd_channel):
//   * writes : mailbox A lite->user {a_req, a_data[16]} / a_ack
//   * reads  : mailbox C lite->user {r_req, r_addr[6]}  / r_ack, then
//              mailbox D user->lite {d_req, d_data[32]} / d_ack.
//   Every side fully waits for the synchronized deassertion of the counter
//   level before raising a new request -- a quick req glitch can otherwise be
//   missed by the 2FF synchronizer and a write silently lost.
//
// Owner arbitration (at the TOP level): cfg_wr_pulse is a single user_clk
// strobe on every MODE/RD_SLOT write; the top flips ctl_owner to the most
// recent writer and muxes cfg_mode/cfg_rd_slot into frame_mem_if.  The two
// rd_req_pulse sources are OR-ed (a read trigger is idempotent w.r.t. the
// currently selected slot).
//
// Defect build for the negative control:
//   `ifdef AXI_LITE_REGS_DEFECT -- rd_req_pulse is held for 2 clocks (width
//   2) instead of the contracted single cycle; the bench pulse-width monitor
//   MUST fail on this build (proves the width check is not vacuous).
//=============================================================================
`timescale 1ns/1ps

module axi_lite_regs (
    // ------------- AXI4-Lite slave (aclk domain, 100 MHz from BD) ----------
    input  wire        aclk,
    input  wire        aresetn,          // active low, synchronous to aclk
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // ------------- user_clk domain (same as cmd_channel user side) ----------
    input  wire        clk_user,
    input  wire        rst_user_n,       // active low (~aurora_rst)
    input  wire [15:0] u_wr_frame,       // frame_mem_if.ro_u_wr_frame
    input  wire [15:0] u_rd_frame,       // frame_mem_if.ro_u_rd_frame
    input  wire [15:0] u_buf_drop,       // frame_mem_if.ro_u_buf_drop
    input  wire        ctl_owner,        // top-level owner flag (status read)
    output reg         cfg_mode,         // 0 = SEQ, 1 = RND   -> owner mux
    output reg  [7:0]  cfg_rd_slot,      //                    -> owner mux
    output reg         rd_req_pulse,     // single user_clk pulse
    output reg         cfg_wr_pulse,     // single user_clk strobe (owner flip)
    output reg  [15:0] lite_exec_cnt,    // lite commands executed (user dom)
    output reg  [15:0] lite_rd_trig_cnt  // read triggers (= RD_SLOT writes)
);

    localparam [7:0] OP_SET_MODE   = 8'h01;   // same codes as cmd_channel
    localparam [7:0] OP_READ_SLOT  = 8'h02;

    localparam [31:0] REG_ID = 32'h5031_4231;  // "P1B1"

    //=========================================================================
    // mailbox registers
    //=========================================================================
    reg        a_req;                    // A: lite -> user (write command)
    reg [15:0] a_data;                   // {opcode, arg}
    reg        a_ack;                    // A: user -> lite
    reg        r_req;                    // C: lite -> user (read request)
    reg [5:0]  r_addr;                   // word offset (awaddr[7:2])
    reg        r_ack;                    // C: user -> lite
    reg        d_req;                    // D: user -> lite (read data)
    reg [31:0] d_data;
    reg        d_ack;                    // D: lite -> user

    (* ASYNC_REG = "TRUE" *) reg [1:0] a_ack_s, r_ack_s, d_req_s;   // lite side
    (* ASYNC_REG = "TRUE" *) reg [1:0] a_req_s, r_req_s, d_ack_s;   // user side

    always @(posedge aclk) begin
        if (!aresetn) begin
            a_ack_s <= 2'b00;  r_ack_s <= 2'b00;  d_req_s <= 2'b00;
        end
        else begin
            a_ack_s <= {a_ack_s[0], a_ack};
            r_ack_s <= {r_ack_s[0], r_ack};
            d_req_s <= {d_req_s[0], d_req};
        end
    end

    always @(posedge clk_user) begin
        if (!rst_user_n) begin
            a_req_s <= 2'b00;  r_req_s <= 2'b00;  d_ack_s <= 2'b00;
        end
        else begin
            a_req_s <= {a_req_s[0], a_req};
            r_req_s <= {r_req_s[0], r_req};
            d_ack_s <= {d_ack_s[0], d_ack};
        end
    end

    //=========================================================================
    // lite domain: write channel (accept AW+W together; one mailbox cycle per
    // write; the next write waits until a_ack has fully deasserted)
    //=========================================================================
    localparam [1:0] LW_IDLE = 2'd0, LW_EXEC = 2'd1, LW_CLOSE = 2'd2;
    reg [1:0] lwst;

    always @(posedge aclk) begin
        if (!aresetn) begin
            lwst          <= LW_IDLE;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            a_req         <= 1'b0;
            a_data        <= 16'd0;
        end
        else begin
            case (lwst)
            LW_IDLE: begin
                // single-driver discipline: bvalid cleared ONLY here
                if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
                // no new acceptance while a response is still being taken
                if (!s_axi_bvalid || s_axi_bready) begin
                    s_axi_awready <= 1'b1;
                    s_axi_wready  <= 1'b1;
                    if (s_axi_awvalid && s_axi_wvalid) begin
                        if (s_axi_awaddr[7:2] == 6'h00)
                            a_data <= {OP_SET_MODE, s_axi_wdata[7:0]};
                        else if (s_axi_awaddr[7:2] == 6'h01)
                            a_data <= {OP_READ_SLOT, s_axi_wdata[7:0]};
                        else
                            a_data <= 16'd0;          // ignored offset, OKAY
                        a_req <= 1'b1;
                        lwst  <= LW_EXEC;
                    end
                end
            end
            LW_EXEC: begin
                s_axi_awready <= 1'b0;
                s_axi_wready  <= 1'b0;
                if (a_ack_s[1]) begin
                    a_req        <= 1'b0;             // user has the command
                    s_axi_bvalid <= 1'b1;
                    lwst         <= LW_CLOSE;
                end
            end
            LW_CLOSE: begin
                // full 4-phase close: wait ack deasserted before next write
                if (!a_ack_s[1]) lwst <= LW_IDLE;
            end
            default: lwst <= LW_IDLE;
            endcase
        end
    end

    //=========================================================================
    // lite domain: read channel (ar accepted at once; rvalid when the user
    // snapshot returns; Lite has no latency limit)
    //=========================================================================
    localparam [1:0] LR_IDLE = 2'd0, LR_RACK = 2'd1, LR_DRQ = 2'd2, LR_DACK = 2'd3;
    reg [1:0] lrst;

    always @(posedge aclk) begin
        if (!aresetn) begin
            lrst          <= LR_IDLE;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
            r_req         <= 1'b0;
            r_addr        <= 6'd0;
            d_ack         <= 1'b0;
        end
        else begin
            d_ack <= d_ack;                             // default hold
            case (lrst)
            LR_IDLE: begin
                // single-driver discipline: rvalid cleared ONLY here
                if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
                // strictly serialized reads: never accept a new AR while the
                // previous rvalid is still pending (a pending rvalid makes a
                // naive master sample the OLD rdata -> stale reads).
                // arready STAYS HIGH through the accept (a level-polling
                // master would otherwise never see it high while arvalid is
                // held -> endless accepts; found by the bench, 2026-10-10).
                if (!s_axi_rvalid && !r_ack_s[1]) begin
                    s_axi_arready <= 1'b1;
                    if (s_axi_arvalid) begin
                        r_addr        <= s_axi_araddr[7:2];
                        r_req         <= 1'b1;
                        lrst          <= LR_RACK;
                    end
                end
                else begin
                    s_axi_arready <= 1'b0;
                end
            end
            LR_RACK: begin
                s_axi_arready <= 1'b0;     // busy: drop ready once accepted
                                          // (held-high through the mailbox
                                          // round made level masters issue
                                          // the next AR into a busy slave)
                if (r_ack_s[1]) begin
                    r_req <= 1'b0;                      // snapshot taken
                    lrst  <= LR_DRQ;
                end
            end
            LR_DRQ: begin
                if (d_req_s[1]) begin
                    s_axi_rdata  <= d_data;
                    s_axi_rvalid <= 1'b1;
                    d_ack        <= 1'b1;
                    lrst         <= LR_DACK;
                end
            end
            LR_DACK: begin
                if (!d_req_s[1]) begin
                    d_ack <= 1'b0;                      // full 4-phase close
                    lrst  <= LR_IDLE;
                end
            end
            default: lrst <= LR_IDLE;
            endcase
        end
    end

    //=========================================================================
    // user domain: command execution (mirror of cmd_channel U_* states)
    // U_CLOSE waits for the synchronized req deassertion before re-arming --
    // without it the req LEVEL re-triggers U_IDLE once per clock during the
    // 2FF round trip and the same command executes several times.
    //=========================================================================
    localparam [1:0] U_IDLE = 2'd0, U_SETTLE = 2'd1, U_PULSE = 2'd2;
    localparam       U_CLOSE = 2'd3;
    reg [1:0] ust;

    always @(posedge clk_user) begin
        if (!rst_user_n) begin
            ust              <= U_IDLE;
            a_ack            <= 1'b0;
            cfg_mode         <= 1'b0;                  // SEQ after reset
            cfg_rd_slot      <= 8'd0;
            rd_req_pulse     <= 1'b0;
            cfg_wr_pulse     <= 1'b0;
            lite_exec_cnt    <= 16'd0;
            lite_rd_trig_cnt <= 16'd0;
        end
        else begin
            rd_req_pulse <= 1'b0;
            cfg_wr_pulse <= 1'b0;
            case (ust)
            U_IDLE: begin
`ifdef AXI_LITE_REGS_DEFECT
                // DEFECT: pulse in the same cycle the slot is written -- a
                // downstream capture flop (frame_mem_if style) samples the OLD
                // slot, violating "cfg stable >= 1 clk before the pulse".
                if (a_req_s[1]) begin
                    a_ack <= 1'b1;
                    if (a_data[15:8] == OP_SET_MODE) begin
                        cfg_mode       <= a_data[0];
                        cfg_wr_pulse   <= 1'b1;
                        lite_exec_cnt  <= lite_exec_cnt + 16'd1;
                        ust            <= U_CLOSE;
                    end
                    else if (a_data[15:8] == OP_READ_SLOT) begin
                        cfg_mode         <= 1'b1;
                        cfg_rd_slot      <= a_data[7:0];
                        rd_req_pulse     <= 1'b1;
                        cfg_wr_pulse     <= 1'b1;
                        lite_exec_cnt    <= lite_exec_cnt + 16'd1;
                        lite_rd_trig_cnt <= lite_rd_trig_cnt + 16'd1;
                        ust              <= U_PULSE;
                    end
                    else ust <= U_CLOSE;                // ignored opcode
                end
`else
                if (a_req_s[1]) begin
                    a_ack <= 1'b1;
                    if (a_data[15:8] == OP_SET_MODE) begin
                        cfg_mode      <= a_data[0];     // bit0 only
                        cfg_wr_pulse  <= 1'b1;
                        lite_exec_cnt <= lite_exec_cnt + 16'd1;
                        ust           <= U_CLOSE;
                    end
                    else if (a_data[15:8] == OP_READ_SLOT) begin
                        cfg_mode      <= 1'b1;          // reads imply RND
                        cfg_rd_slot   <= a_data[7:0];
                        cfg_wr_pulse  <= 1'b1;
                        lite_exec_cnt <= lite_exec_cnt + 16'd1;
                        ust           <= U_SETTLE;      // settle first
                    end
                    else ust <= U_CLOSE;                 // ignored opcode
                end
`endif
            end
`ifndef AXI_LITE_REGS_DEFECT
            U_SETTLE: begin
                rd_req_pulse     <= 1'b1;               // cfg stable >= 1 clk
                lite_rd_trig_cnt <= lite_rd_trig_cnt + 16'd1;
                ust              <= U_PULSE;
            end
`endif
            U_PULSE: begin
`ifdef AXI_LITE_REGS_DEFECT
                // DEFECT: hold the pulse a SECOND clock (width 2) -- violates
                // the W5 "single user_clk pulse" contract; in RND mode this
                // double-triggers the read. Observable at the module boundary
                // (pulse width monitor), unlike a same-cycle cfg-write defect
                // which is invisible through register boundaries.
                rd_req_pulse <= 1'b1;
`else
                rd_req_pulse <= 1'b0;
`endif
                ust          <= U_CLOSE;
            end
            U_CLOSE: begin
                if (!a_req_s[1]) begin
                    a_ack <= 1'b0;                      // close mailbox A
                    ust   <= U_IDLE;
                end
            end
            default: ust <= U_IDLE;
            endcase
        end
    end

    //=========================================================================
    // user domain: read snapshot (mailbox C ack + mailbox D data)
    //=========================================================================
    localparam [1:0] UR_IDLE = 2'd0, UR_CLOSE = 2'd1, UR_RACKCL = 2'd2;
    reg [1:0] urst;

    always @(posedge clk_user) begin
        if (!rst_user_n) begin
            urst   <= UR_IDLE;
            r_ack  <= 1'b0;
            d_req  <= 1'b0;
            d_data <= 32'd0;
        end
        else begin
            case (urst)
            UR_IDLE: begin
                if (r_req_s[1]) begin
                    r_ack <= 1'b1;
                    // snapshot ALL readable regs in ONE clock (stable copy)
                    case (r_addr)
                        6'h02: d_data <= {16'd0, u_wr_frame};
                        6'h03: d_data <= {16'd0, u_rd_frame};
                        6'h04: d_data <= {16'd0, u_buf_drop};
                        6'h05: d_data <= {8'd1, u_wr_frame[7:0], 16'd0};
                        6'h06: d_data <= {ctl_owner, 1'b0, lite_rd_trig_cnt};
                        6'h07: d_data <= REG_ID;
                        default: d_data <= 32'd0;
                    endcase
                    d_req <= 1'b1;                      // data held stable
                    urst  <= UR_CLOSE;
                end
            end
            UR_CLOSE: begin
                if (d_ack_s[1]) begin
                    d_req <= 1'b0;                      // data consumed
                    urst  <= UR_RACKCL;
                end
            end
            UR_RACKCL: begin
                if (!r_req_s[1]) begin
                    r_ack <= 1'b0;                      // close mailbox C
                    urst  <= UR_IDLE;
                end
            end
            default: urst <= UR_IDLE;
            endcase
        end
    end

endmodule
