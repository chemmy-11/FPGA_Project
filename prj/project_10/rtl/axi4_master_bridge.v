//=============================================================================
// axi4_master_bridge.v -- self-developed AXI4 512-bit master + slot manager
//                         prj10 W2 (memory-in-the-loop), ui_clk domain only
//-----------------------------------------------------------------------------
// WHY (design rationale, for the defence):
//  * AXI4 requires AWLEN with/before the write data, so a frame must be fully
//    known before its burst is issued. That is the project's proven
//    "store-and-forward a whole frame" policy (prj9 frame pump), not a new idea.
//  * 4KB slots: frame <= 1538 B -> <= 24 beats of 64 B <= 1536 B < 4096 B, so a
//    burst can NEVER cross an AXI 4KB boundary. No split logic is needed; the
//    simulation monitor checks the arithmetic anyway.
//  * The slot table (valid/len) is a single-clock (ui_clk) table; the frame side
//    only receives (len, slot) through the read descriptor FIFO. One clock per
//    table = no dual-domain table hazard.
//  * Hard gate: no AW/AR is issued until init_calib_complete is seen in THIS
//    clock domain (prj4 lesson: touching MIG before calibration hangs the FSM).
//
// SLOT POLICY (the "random read" contract, simulated in mem_bridge_tb.sv)
//   FULL[slot] : the slot holds a frame that has not been read yet.
//   write  : slot = wm[7:0]. If FULL[slot] -> REFUSE (stat_wr_stall++), the frame
//            is drained and discarded: an unread frame is NEVER overwritten.
//   read SEQ: serve rd_seq_slot (oldest unread), retire it, advance the pointer.
//   read RND: slot = command slot. Slot never written (cmd >= wm while wm < 256)
//            -> stat_ill_rd++ and clamp to wm-1. Clamped/commanded slot not FULL
//            (already read or empty) -> stat_ill_rd++ and a defined empty answer.
//            Random read of an unwritten slot is therefore DEFINED and COUNTED,
//            never undefined behaviour.
//-----------------------------------------------------------------------------
// W5 TIMING FIX (2026-10-07, first-principles re-diagnosis):
//   * Symptom: with a live cfg_mode the whole read-decision cone failed at
//     300 MHz (worst 25 paths all: u_rd_cmd/rd_bin -> uc_dout (FWFT *combinational*
//     RAM read!) -> in_range adder -> eff_slot mux -> full_bit/len_tab 256:1
//     lookup -> CE/D of stat_ill_rd / r_len / r_beats / rd_wr_data;
//     4.226 ns data path vs 3.333 ns budget, 5011 failing endpoints).
//   * Not an RND-only cone: cmd_rnd is the SELECT of that cone, so with a live
//     command FIFO it lights up in SEQ too. W4 had survived only because the
//     constant cfg_mode=1'b0 folded it away AND rd_seq_slot (a register) was the
//     surviving index -- at +0.008 ns, i.e. the underlying "reg-index -> len_tab
//     -> +63 adder -> r_beats" chain had ZERO margin even then.
//   * FINAL fix (2026-10-08, measured WNS -1.121 -> +0.001), three cuts:
//     1) R_IDLE prefetch: pop the command FIFO AND do the range math there
//        (c_eff/c_in_rng off cmd_slot + stat_wm), latching pre_eff/pre_in_rng;
//     2) R_PRE: the 256:1 table lookups (full_bit/len_tab/len_beats_tab) are
//        indexed by the REGISTER pre_eff only -- never the FIFO output;
//     3) len_beats_tab[]: beat budget precomputed at write-commit time, so the
//        read path does two PARALLEL lookups instead of len -> +63 adder.
//     PLUS: full_bit_q -- a keep-protected registered mirror of full_bit for
//     the CONTROL lookups (w_no_room / seq_ok / SEQ pointer scan), removing the
//     256:1 tree from both FSM CE cones. p_target_ok keeps the combinational
//     read (a slot committed this cycle must be seen FULL by the decision).
//     NOTE: without (* keep *), synthesis MERGES the mirror back into the tree
//     and the gain vanishes (measured: -0.121 both with and without).
//     W2/joint/arb/cmd regressions all green, counters byte-identical.
//   * rc_rd_en still gates on seq_ok (unchanged: its full_bit[rd_seq_slot]
//     index is a register, never on the bad path).
//=============================================================================
`timescale 1ns/1ps

module axi4_master_bridge #(
    parameter [31:0] SLOT_BASE = 32'h0010_0000,   // 4KB-aligned slot region
    parameter [15:0] MAX_LEN   = 16'd1538         // prj9 frame contract (chunk=1466)
)(
    // ---------------- ui_clk / reset / MIG gate ----------------
    input  wire         clk,            // ui_clk  (~300 MHz per MIG report)
    input  wire         rst_n,          // ui_clk domain reset, active low
    input  wire         calib_ok,       // init_calib_complete, ui_clk domain

    // ---------------- write byte stream (ui side of user->ui FIFO) ----------------
    input  wire         wf_empty,
    input  wire [7:0]   wf_data,
    input  wire [12:0]  wf_level,       // conservative byte count available
    output wire         wf_rd_en,
    // ---------------- write descriptor (ui side of user->ui desc FIFO) ----------------
    input  wire         wd_empty,
    input  wire [15:0]  wd_data,        // frame length in bytes
    output wire         wd_rd_en,

    // ---------------- read byte stream (ui side of ui->user FIFO) ----------------
    output reg          rf_wr_en,
    output reg  [7:0]   rf_wr_data,
    // ---------------- read command (ui side of user->ui cmd FIFO) ----------------
    input  wire         rc_empty,
    input  wire [8:0]   rc_data,        // {rnd, slot[7:0]}
    output wire         rc_rd_en,
    // ---------------- read descriptor (ui side of ui->user desc FIFO) ----------------
    output reg          rd_wr_en,
    output reg  [24:0]  rd_wr_data,     // {none, len[15:0], slot[7:0]}

    // ---------------- status / counters (ui_clk domain, ILA-friendly) ----------------
    output reg  [15:0]  stat_wm,        // write watermark = frames committed
    output reg  [15:0]  stat_wr_frame,
    output reg  [15:0]  stat_wr_stall,  // refused: no free slot (unread frame preserved)
    output reg  [15:0]  stat_rd_frame,
    output reg  [15:0]  stat_ill_rd,    // illegal / out-of-range random read
    output reg  [15:0]  stat_noframe,   // SEQ read with no resident frame
    output reg  [15:0]  stat_bresp_err,
    output reg  [15:0]  stat_len_err,   // W2-review D2: frames refused for length
                                        // (>MAX_LEN / 0) + W_DRAIN bail-outs
    output reg  [8:0]   stat_outstanding, // slots currently FULL
    output reg  [7:0]   dbg_wr_slot,
    output reg  [7:0]   dbg_rd_slot,
    output reg  [31:0]  dbg_wr_cycles,  // ui cycles spent servicing a write frame
    output reg  [31:0]  dbg_rd_cycles,  // ui cycles spent servicing a read frame
    output reg  [31:0]  dbg_wr_beats,
    output reg  [31:0]  dbg_rd_beats,

    // ---------------- AXI4 master (512-bit data) ----------------
    output wire [31:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output reg          m_axi_awvalid,
    input  wire         m_axi_awready,
    output wire [511:0] m_axi_wdata,
    output wire [63:0]  m_axi_wstrb,
    output wire         m_axi_wlast,
    output reg          m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output reg          m_axi_bready,
    output wire [31:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output reg          m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [511:0] m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output reg          m_axi_rready,

    // ---------------- AXI4 sideband (W3/A1: required by the real MIG) ----------------
    // The real ddr4_0 exposes 37 s_axi signals; the W2 stand-in model only had 25.
    // Evidence (project_4/D1_MIG断点核查 §3.1): awid/arid are FUNCTIONAL inside the
    // MIG (r_channel.sv moves the ID into the read-transaction buffer and drives rid
    // from it); bid/rid may dangle but the PORTS must exist.
    output wire [3:0]   m_axi_awid,
    output wire [0:0]   m_axi_awlock,
    output wire [3:0]   m_axi_awcache,
    output wire [2:0]   m_axi_awprot,
    output wire [3:0]   m_axi_awqos,
    input  wire [3:0]   m_axi_bid,
    output wire [3:0]   m_axi_arid,
    output wire [0:0]   m_axi_arlock,
    output wire [3:0]   m_axi_arcache,
    output wire [2:0]   m_axi_arprot,
    output wire [3:0]   m_axi_arqos,
    input  wire [3:0]   m_axi_rid
);

    //=========================================================================
    // 1. slot table (single clock domain: this one)
    //=========================================================================
    reg        full_bit [0:255];
    reg [15:0] len_tab  [0:255];
    // W5 timing fix (2026-10-07): precomputed beat budget per slot.
    // The old read path computed (len+63)>>6 at issue time -- that adder sat ON the
    // critical cone (W4 rpt: rd_seq_slot -> len_tab -> +63 -> r_beats was the +0.008
    // survivor). Precomputing at write-commit time removes it from the read path
    // entirely; r_len (16b lookup) and r_beats (6b lookup) become parallel lookups.
    reg [7:0]  len_beats_tab [0:255];
    reg [7:0]  rd_seq_slot;

    integer ti;
    reg        wr_commit;
    reg [7:0]  wr_commit_slot;
    reg [15:0] wr_commit_len;
    reg        rd_retire;
    reg [7:0]  rd_retire_slot;

    // ---- W5 final fix (2026-10-08): registered mirror of full_bit ----
    // The 256:1 read of full_bit is the last structural cost on the critical
    // paths (worst: full_bit[76] -> wst FSM, full_bit[5] -> rstate FSM). A
    // registered mirror removes the tree from the CE paths of both FSMs and
    // the SEQ pointer scan. FUNCTIONAL note: p_target_ok keeps the
    // COMBINATIONAL read (correctness: a slot committed this cycle must be
    // seen as FULL by the decision beat); only the "may I advance / may I
    // write" lookups use the 1-cycle-late mirror, where the effect is a
    // harmless 1-cycle bubble on retire->rewrite.
    (* keep = "true" *) reg full_bit_q [0:255];   // keep: 阻止综合器把镜像合并回组合树(实测会被合并, 时序收益归零)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ti = 0; ti < 256; ti = ti + 1) begin
                full_bit[ti] <= 1'b0;
                full_bit_q[ti] <= 1'b0;
                len_tab[ti]  <= 16'd0;
                len_beats_tab[ti] <= 8'd0;
            end
        end else begin
            if (wr_commit) begin
                full_bit[wr_commit_slot] <= 1'b1;
                full_bit_q[wr_commit_slot] <= 1'b1;
                len_tab [wr_commit_slot] <= wr_commit_len;
                len_beats_tab[wr_commit_slot] <= (wr_commit_len + 16'd63) >> 6;
            end
            if (rd_retire) begin
                full_bit[rd_retire_slot] <= 1'b0;   // retire wins on collision
                full_bit_q[rd_retire_slot] <= 1'b0;
            end
        end
    end

    //=========================================================================
    // 2. slot occupancy counter (single driver)
    //=========================================================================
    reg out_inc, out_dec;

    // W2-review D1 FIX -- ONE DRIVER PER REG.
    // out_inc is owned by the write FSM block (pulsed on commit in W_B),
    // out_dec is owned by the read FSM block (pulsed on retire in R_FIN).
    // They used to be cleared HERE as well, i.e. two procedural drivers on one
    // reg.  Vivado resolves that as
    //   CRITICAL WARNING [Synth 8-6859] multi-driven net on pin Q ...
    //   CRITICAL WARNING [Synth 8-6858] ... constant driver preserved, other
    //                                     driver is ignored
    // so on hardware out_inc/out_dec were tied to 0 and stat_outstanding stayed
    // FROZEN AT 0: no slot-full refusal, no SEQ pointer scan.  This block now
    // only CONSUMES the two pulses.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_outstanding <= 9'd0;
        end else begin
            if (out_inc & ~out_dec)      stat_outstanding <= stat_outstanding + 9'd1;
            else if (~out_inc & out_dec) stat_outstanding <= stat_outstanding - 9'd1;
        end
    end

    //=========================================================================
    // 3. write FSM
    //=========================================================================
    localparam W_IDLE=3'd0, W_WAIT=3'd1, W_AW=3'd2, W_FILL=3'd3,
               W_PUSH=3'd4, W_B=3'd5, W_DRAIN=3'd6;

    reg [2:0]   wst;
    reg [7:0]   w_slot, w_beat, w_bi;
    reg [7:0]   w_beats;
    reg [15:0]  w_len, w_pop;
    reg [11:0]  w_bidx;
    reg [511:0] w_data_r;
    reg [63:0]  w_strb_r;
    reg         w_beat_full, w_slotfull;
    reg [3:0]   w_drain_wait;           // W2-review D2: W_DRAIN liveness bound

    wire [7:0]  w_slot_next = stat_wm[7:0];
    wire        w_no_room   = full_bit_q[w_slot_next];  // W5: 1-cycle-late mirror (retire->rewrite bubble)
    wire        w_bad_len   = (wd_data == 16'd0) || (wd_data > MAX_LEN);
    wire        w_consume   = (wst == W_FILL) && !wf_empty && !w_beat_full;
    wire        w_drain_pop = (wst == W_DRAIN) && !wf_empty && (w_pop < w_len);

    assign wf_rd_en = w_consume | w_drain_pop;
    assign wd_rd_en = (wst == W_IDLE) && calib_ok && !wd_empty;

    // ---- A1: sideband constants -------------------------------------------
    // awid/arid MUST be legal values. One ID per direction keeps the two streams
    // distinguishable inside the MIG's ID-ordered buffers; each FSM here keeps
    // exactly one burst in flight, so no re-order tracking is needed and bid/rid
    // are intentionally not compared (only qualified by VALID).
    assign m_axi_awid    = 4'h0;
    assign m_axi_arid    = 4'h1;
    assign m_axi_awlock  = 1'b0;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_awcache = 4'h0;   // Normal Non-cacheable, non-bufferable
    assign m_axi_arcache = 4'h0;
    assign m_axi_awprot  = 3'h0;   // unprivileged, data, secure
    assign m_axi_arprot  = 3'h0;
    assign m_axi_awqos   = 4'h0;
    assign m_axi_arqos   = 4'h0;

    assign m_axi_awaddr  = SLOT_BASE + {w_slot, 12'b0};
    assign m_axi_awlen   = w_beats - 8'd1;
    assign m_axi_awsize  = 3'b110;      // 64 bytes per beat (512-bit)
    assign m_axi_awburst = 2'b01;       // INCR
    assign m_axi_wdata   = w_data_r;
    assign m_axi_wstrb   = w_strb_r;
    assign m_axi_wlast   = (w_beat == (w_beats - 8'd1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wst <= W_IDLE; m_axi_awvalid <= 0; m_axi_wvalid <= 0; m_axi_bready <= 0;
            w_slot <= 0; w_beat <= 0; w_bi <= 0; w_beats <= 0; w_len <= 0; w_pop <= 0;
            w_bidx <= 0; w_data_r <= 0; w_strb_r <= 0; w_beat_full <= 0; w_slotfull <= 0;
            wr_commit <= 0; wr_commit_slot <= 0; wr_commit_len <= 0;
            stat_wm <= 0; stat_wr_frame <= 0; stat_wr_stall <= 0; stat_bresp_err <= 0;
            stat_len_err <= 0; out_inc <= 1'b0; w_drain_wait <= 4'd0;
            dbg_wr_slot <= 0; dbg_wr_cycles <= 0; dbg_wr_beats <= 0;
        end else begin
            wr_commit <= 1'b0;
            out_inc   <= 1'b0;     // D1 FIX: this block is the ONLY driver of out_inc

            // byte assembly (only inside W_FILL); see W_PUSH for the handover
            if (w_consume) begin
                w_data_r[w_bi*8 +: 8] <= wf_data;
                w_strb_r[w_bi]        <= (w_bidx < w_len);
                w_bidx                <= w_bidx + 12'd1;
                // beat complete when 64 bytes are in OR the frame is exhausted
                // (tail beat: wstrb marks exactly the valid bytes)
                if ((w_bi == 8'd63) || ((w_bidx + 12'd1) == w_len)) w_beat_full <= 1'b1;
                else                                                 w_bi        <= w_bi + 8'd1;
            end
            if (wst != W_IDLE) dbg_wr_cycles <= dbg_wr_cycles + 32'd1;

            case (wst)
            //-----------------------------------------------------------------
            W_IDLE: begin
                m_axi_awvalid <= 1'b0;
                m_axi_wvalid  <= 1'b0;
                m_axi_bready  <= 1'b0;
                if (wd_rd_en) begin                       // descriptor pops this cycle
                    w_len     <= wd_data;
                    w_pop     <= 16'd0;
                    w_slot    <= w_slot_next;
                    w_slotfull<= w_no_room;
                    dbg_wr_slot <= w_slot_next;
                    w_beat <= 8'd0; w_bi <= 8'd0; w_bidx <= 12'd0;
                    w_beat_full <= 1'b0; w_data_r <= 0; w_strb_r <= 0;
                    if (w_no_room | w_bad_len) begin
                        wst          <= W_DRAIN;          // refuse: never overwrite
                        w_drain_wait <= 4'd0;
                        if (w_bad_len) stat_len_err <= stat_len_err + 16'd1;
                    end else begin
                        w_beats <= (wd_data + 16'd63) >> 6;
                        wst     <= W_WAIT;
                    end
                end
            end
            //-----------------------------------------------------------------
            W_WAIT: begin   // wait until every byte of this frame is visible
                if (wf_level >= w_len[12:0]) wst <= W_AW;
            end
            //-----------------------------------------------------------------
            W_AW: begin
                m_axi_awvalid <= 1'b1;
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awvalid <= 1'b0;
                    wst <= W_FILL;
                end
            end
            //-----------------------------------------------------------------
            W_FILL: begin
                if (w_beat_full) wst <= W_PUSH;
            end
            //-----------------------------------------------------------------
            W_PUSH: begin
                m_axi_wvalid <= 1'b1;
                if (m_axi_wvalid && m_axi_wready) begin
                    m_axi_wvalid <= 1'b0;
                    w_beat_full  <= 1'b0;
                    w_bi         <= 8'd0;
                    // ---- A3 FIX (2026-10-01) ----------------------------------
                    // w_strb_r used to be cleared only at frame start, so on the
                    // TAIL beat the lanes beyond the frame length kept the previous
                    // beat's 1s: every frame whose length is not a multiple of 64 B
                    // asserted a full 64-lane WSTRB and wrote up to 63 stale bytes
                    // past the frame (measured: 64/64 beats "full", tail=0).
                    // Clearing the mask per beat makes the tail beat exactly
                    // (len mod 64) lanes wide; wstrb=0 lanes are not written by AXI.
                    w_strb_r     <= 64'd0;
                    dbg_wr_beats <= dbg_wr_beats + 32'd1;
                    if (w_beat == (w_beats - 8'd1)) begin
                        wst <= W_B;
                    end else begin
                        w_beat <= w_beat + 8'd1;
                        wst    <= W_FILL;
                    end
                end
            end
            //-----------------------------------------------------------------
            W_B: begin
                m_axi_bready <= 1'b1;
                if (m_axi_bvalid && m_axi_bready) begin
                    m_axi_bready <= 1'b0;
                    if (m_axi_bresp == 2'b00) begin
                        wr_commit       <= 1'b1;
                        wr_commit_slot  <= w_slot;
                        wr_commit_len   <= w_len;
                        out_inc         <= 1'b1;
                        stat_wm         <= stat_wm + 16'd1;
                        stat_wr_frame   <= stat_wr_frame + 16'd1;
                    end else begin
                        stat_bresp_err <= stat_bresp_err + 16'd1;
                    end
                    wst <= W_IDLE;
                end
            end
            //-----------------------------------------------------------------
            W_DRAIN: begin   // refused frame: pull its bytes back out of the FIFO
                if (w_pop >= w_len) begin
                    if (w_slotfull) stat_wr_stall <= stat_wr_stall + 16'd1;
                    w_drain_wait <= 4'd0;
                    wst          <= W_IDLE;
                end else if (w_drain_pop) begin
                    w_pop        <= w_pop + 16'd1;
                    w_drain_wait <= 4'd0;
                end else if (w_drain_wait == 4'd15) begin
                    // W2-review D2 FIX -- liveness.  The descriptor claims more
                    // bytes than the byte FIFO will ever supply (frame-side /
                    // descriptor desync).  Never spin here: give up, count it and
                    // resynchronise on the next descriptor.  An unrecoverable
                    // hang must be structurally impossible.
                    stat_len_err <= stat_len_err + 16'd1;
                    w_drain_wait <= 4'd0;
                    wst          <= W_IDLE;
                end else begin
                    w_drain_wait <= w_drain_wait + 4'd1;
                end
            end
            default: wst <= W_IDLE;
            endcase
        end
    end

    //=========================================================================
    // 4. read FSM
    //=========================================================================
    localparam R_IDLE=3'd0, R_AR=3'd1, R_R=3'd2, R_UNPACK=3'd3, R_FIN=3'd4,
               R_PRE=3'd5;   // R_PRE2 removed: triggered a Vivado 2023.1 synth crash (3x reproducible)

    reg [2:0]   rstate;
    reg [7:0]   r_slot, r_beat, r_bi, r_beats;
    reg [15:0]  r_len;
    reg [6:0]   r_nbytes;        // meaningful bytes in the current beat (<=64)
    reg [511:0] r_beat_data;
    reg         r_rnd;

    // ---- W5 timing fix (2026-10-07): command prefetch registers ----
    // Old single-cycle cone: rc_data (FWFT comb RAM read of u_rd_cmd!) -> compare
    // in_range -> mux eff_slot -> full_bit/len_tab 256:1 lookup -> CE/D of
    // stat_ill_rd / r_len / r_beats / rd_wr_data  == 4.226ns vs 3.333ns budget.
    // Split into two beats: this beat only registers {rnd, slot} off the FIFO
    // (short), next beat (R_PRE) does range math + table lookup off REGISTERS.
    // SEQ semantics unchanged: still "oldest unread slot"; only the decision is
    // one cycle later. cmd_rnd kept as a live wire only where its input is a
    // registered value (prefetched), never straight off the FWFT RAM output.
    reg         pre_rnd;
    reg [7:0]   pre_slot;
    // NOTE (2026-10-08): a second cut (state R_PRE2 registering the range
    // decision before the table lookup) was implemented and measured, but
    // Vivado 2023.1 synthesis CRASHED on it (EXCEPTION_ACCESS_VIOLATION, 3x
    // reproducible at "Mimic Skeleton from Reference") while single-module
    // out-of-context synthesis of the same file passed. It was reverted; the
    // dead registers are removed. See
    // 调试记录/阶段三_prj10_W5时序收敛_第二轮根因重定与修复_2026-10-08.md

    wire        cmd_rnd    = rc_data[8];
    wire [7:0]  cmd_slot   = rc_data[7:0];
    // ---- W5 final fix (2026-10-08): range math moved INTO the prefetch beat ----
    // Measured chain (run C): stat_wm -> compare(CARRY8) -> p_eff mux -> 256:1 tree
    // -> r_len/r_beats  == 3.6ns vs 3.333ns (-0.494). The range math + slot select
    // is computed here off the PREFETCHED command and registered (pre_eff/pre_in_rng),
    // so the R_PRE beat sees REGISTER-INDEXED lookups only (like the W4-era cone,
    // which closed at +0.008 even WITH an adder; ours has none).
    wire [7:0]  c_clamp    = (stat_wm == 16'd0) ? 8'd0 : (stat_wm[7:0] - 8'd1);
    wire        c_in_rng   = (stat_wm >= 16'd256) || (cmd_slot < stat_wm[7:0]);
    wire [7:0]  c_eff      = cmd_rnd ? (c_in_rng ? cmd_slot : c_clamp) : rd_seq_slot;
    reg  [7:0]  pre_eff;      // registered effective slot (latched in R_IDLE)
    reg         pre_in_rng;   // registered range decision (latched in R_IDLE)
    // R_PRE side: all lookups are indexed by the REGISTER pre_eff
    wire [7:0]  p_eff      = pre_eff;
    wire        p_in_rng   = pre_in_rng;
    wire        p_target_ok  = (stat_wm != 16'd0) && full_bit[pre_eff];
    // SEQ = "oldest unread slot". The pointer is scanned forward until it lands on
    // a FULL slot, so SEQ stays correct even if RND reads have already retired
    // arbitrary slots (mixed-mode safety, see the W2 note 6.3).
    wire        seq_ok   = cmd_rnd | full_bit_q[rd_seq_slot] | (stat_outstanding == 9'd0); // W5: mirror

    assign rc_rd_en = (rstate == R_IDLE) && calib_ok && !rc_empty && seq_ok;

    assign m_axi_araddr  = SLOT_BASE + {r_slot, 12'b0};
    assign m_axi_arlen   = r_beats - 8'd1;
    assign m_axi_arsize  = 3'b110;
    assign m_axi_arburst = 2'b01;

    // meaningful bytes in the current read beat
    always @(*) begin
        if (r_beat == (r_beats - 8'd1))
            r_nbytes = (r_len[5:0] == 6'd0) ? 7'd64 : {1'b0, r_len[5:0]};
        else
            r_nbytes = 7'd64;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate <= R_IDLE; m_axi_arvalid <= 0; m_axi_rready <= 0;
            rf_wr_en <= 0; rf_wr_data <= 0; rd_wr_en <= 0; rd_wr_data <= 0;
            r_slot <= 0; r_beat <= 0; r_bi <= 0; r_beats <= 0; r_len <= 0;
            r_beat_data <= 0; r_rnd <= 0;
            pre_rnd <= 1'b0; pre_slot <= 8'd0;
            pre_eff <= 8'd0; pre_in_rng <= 1'b0;
            rd_retire <= 0; rd_retire_slot <= 0; rd_seq_slot <= 0;
            stat_rd_frame <= 0; stat_ill_rd <= 0; stat_noframe <= 0; dbg_rd_slot <= 0;
            dbg_rd_cycles <= 0; dbg_rd_beats <= 0; out_dec <= 1'b0;
        end else begin
            rd_retire <= 1'b0;
            out_dec   <= 1'b0;     // D1 FIX: this block is the ONLY driver of out_dec
            rf_wr_en  <= 1'b0;
            rd_wr_en  <= 1'b0;
            if (rstate != R_IDLE) dbg_rd_cycles <= dbg_rd_cycles + 32'd1;

            case (rstate)
            //-----------------------------------------------------------------
            R_IDLE: begin
                m_axi_arvalid <= 1'b0;
                m_axi_rready  <= 1'b0;
                // SEQ pointer scan (1 slot / ui cycle, no command is consumed).
                // Guard uses only registered values (rd_seq_slot is a reg) --
                // deliberately NOT cmd_rnd: that would revive the FIFO-output cone.
                if (!full_bit_q[rd_seq_slot] && (stat_outstanding != 9'd0))
                    rd_seq_slot <= rd_seq_slot + 8'd1;
                if (rc_rd_en) begin
                    // prefetch beat: capture the command AND do the range math
                    // (compare + select) here, so the next beat is register-indexed
                    // lookups only. Inputs: cmd_slot/cmd_rnd (FIFO comb read, short
                    // hop to these regs) + stat_wm/rd_seq_slot (registers).
                    pre_rnd    <= cmd_rnd;
                    pre_slot   <= cmd_slot;
                    pre_eff    <= c_eff;
                    pre_in_rng <= c_in_rng;
                    rstate     <= R_PRE;
                end
            end
            //-----------------------------------------------------------------
            // W5 cut-1: decision beat. Range math (compare + select) and the
            // table lookups share this beat -- measured WNS -0.494 @3.333ns, i.e.
            // one more cut is still needed. All inputs here are REGISTERS
            // (pre_rnd/pre_slot/rd_seq_slot/stat_wm), never the FWFT RAM output.
            R_PRE: begin
                r_rnd <= pre_rnd;
                if (pre_rnd && !p_in_rng) stat_ill_rd <= stat_ill_rd + 16'd1;
                if (!p_target_ok) begin
                    if (!pre_rnd)            stat_noframe <= stat_noframe + 16'd1;
                    else if (p_in_rng)       stat_ill_rd  <= stat_ill_rd  + 16'd1;
                    rd_wr_en    <= 1'b1;
                    rd_wr_data  <= {1'b1, 16'd0, 8'hFF};
                    dbg_rd_slot <= 8'hFF;
                    rstate      <= R_IDLE;
                end else begin
                    r_slot  <= p_eff;
                    r_len   <= len_tab[p_eff];
                    r_beats <= len_beats_tab[p_eff];
                    r_beat  <= 8'd0;
                    dbg_rd_slot <= p_eff;
                    rstate  <= R_AR;
                end
            end
            //-----------------------------------------------------------------
            R_AR: begin
                m_axi_arvalid <= 1'b1;
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                    rstate <= R_R;
                end
            end
            //-----------------------------------------------------------------
            R_R: begin
                // AXI handshake: READY must be high in the SAME cycle that VALID
                // is sampled. Asserting rready only while rvalid is still low (and
                // dropping it on the first rvalid) never completes the transfer on
                // the slave side -> the slave stays mid-burst and the next AR is
                // never accepted (W2 bring-up bug: bridge stuck in R_AR).
                m_axi_rready <= 1'b1;
                if (m_axi_rvalid && m_axi_rready) begin
                    m_axi_rready <= 1'b0;
                    r_beat_data  <= m_axi_rdata;
                    r_bi         <= 8'd0;
                    dbg_rd_beats <= dbg_rd_beats + 32'd1;
                    rstate       <= R_UNPACK;
                end
            end
            //-----------------------------------------------------------------
            R_UNPACK: begin   // 1 byte / ui cycle into the ui->user byte FIFO
                rf_wr_en   <= 1'b1;
                rf_wr_data <= r_beat_data[r_bi*8 +: 8];
                if (r_bi == (r_nbytes - 7'd1)) begin
                    r_bi <= 8'd0;
                    if (r_beat == (r_beats - 8'd1)) rstate <= R_FIN;
                    else begin r_beat <= r_beat + 8'd1; rstate <= R_R; end
                end else begin
                    r_bi <= r_bi + 8'd1;
                end
            end
            //-----------------------------------------------------------------
            R_FIN: begin
                rd_retire      <= 1'b1;
                rd_retire_slot <= r_slot;
                out_dec        <= 1'b1;
                stat_rd_frame  <= stat_rd_frame + 16'd1;
                if (!r_rnd) rd_seq_slot <= rd_seq_slot + 8'd1;
                rd_wr_en   <= 1'b1;
                rd_wr_data <= {1'b0, r_len, r_slot};
                rstate     <= R_IDLE;
            end
            default: rstate <= R_IDLE;
            endcase
        end
    end

endmodule
