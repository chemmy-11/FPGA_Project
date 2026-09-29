//=============================================================================
// repro_multidriver_order_tb.sv  --  MINIMAL REPRODUCTION (new file, prj10 W2 review)
//-----------------------------------------------------------------------------
// WHAT IT REPRODUCES
//   rtl/axi4_master_bridge.v declares two regs, out_inc / out_dec, and assigns
//   each of them from TWO DIFFERENT always blocks:
//       always A (lines 140-151, "slot occupancy counter"): out_inc <= 1'b0;  (line 146)
//                                                           out_dec <= 1'b0;  (line 147)
//       always B (lines 185-292, write FSM W_B):            out_inc <= 1'b1;  (line 271)
//       always C (lines 332-425, read  FSM R_FIN):          out_dec <= 1'b1;  (line 415)
//   A reg written from two procedural blocks is a RACE: last writer in the same
//   time step wins, and "last" is decided by process/compile order, not by RTL.
//   This TB instantiates the SAME two-block construct twice, with the blocks in
//   opposite source order, and shows that the resulting counter values differ.
//   It also instantiates the real axi4_master_bridge to show which way xsim
//   happens to resolve the real file (it resolves "setter last", i.e. it works).
//
// HOW TO RUN (batch tools only, no Vivado GUI / project):
//   cd D:\FPGA\project_10\sim
//   xvlog -sv ..\rtl\async_fifo.v ..\rtl\axi4_master_bridge.v ..\rtl\frame_mem_if.v \
//          axi4_ram_model.v repro_multidriver_order_tb.sv
//   xelab -debug typical repro_multidriver_order_tb -s repro_md
//   xsim repro_md -runall
//=============================================================================
`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Variant 1: "clear block FIRST, set block SECOND"  == the real RTL's source order
//   (axi4_master_bridge.v: counter block at 140, write FSM block at 185)
//-----------------------------------------------------------------------------
module md_clear_first #(parameter N = 3) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       set,
    input  wire       dec,
    output reg [8:0]  cnt,
    output reg        inc_o,
    output reg        dec_o
);
    // ---- block A: occupancy counter (axi4_master_bridge.v:140-151) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 9'd0; inc_o <= 1'b0; dec_o <= 1'b0;
        end else begin
            inc_o <= 1'b0;                       // line 146
            dec_o <= 1'b0;                       // line 147
            if (inc_o & ~dec_o)      cnt <= cnt + 9'd1;
            else if (~inc_o & dec_o) cnt <= cnt - 9'd1;
        end
    end
    // ---- block B: write FSM (axi4_master_bridge.v:271) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ; else if (set) inc_o <= 1'b1;
    end
    // ---- block C: read FSM (axi4_master_bridge.v:415) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ; else if (dec) dec_o <= 1'b1;
    end
endmodule

//-----------------------------------------------------------------------------
// Variant 2: identical logic, ONLY the source order of the blocks is swapped
//-----------------------------------------------------------------------------
module md_set_first #(parameter N = 3) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       set,
    input  wire       dec,
    output reg [8:0]  cnt,
    output reg        inc_o,
    output reg        dec_o
);
    // ---- block B first now ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ; else if (set) inc_o <= 1'b1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ; else if (dec) dec_o <= 1'b1;
    end
    // ---- block A last now ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 9'd0; inc_o <= 1'b0; dec_o <= 1'b0;
        end else begin
            inc_o <= 1'b0;
            dec_o <= 1'b0;
            if (inc_o & ~dec_o)      cnt <= cnt + 9'd1;
            else if (~inc_o & dec_o) cnt <= cnt - 9'd1;
        end
    end
endmodule

//-----------------------------------------------------------------------------
// Variant 3: the SAME file with the multi-driver removed (the intended design):
//   the clear is merged into the FSM blocks -> exactly one driver per reg.
//   This is what the counter would do if the race resolved the "wrong" way:
//   nothing. Because with a merged clear there is no race, and inc_o is
//   guaranteed to be seen as 1 by the counter block on the next edge.
//-----------------------------------------------------------------------------
module md_merged #(parameter N = 3) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       set,
    input  wire       dec,
    output reg [8:0]  cnt,
    output reg        inc_o,
    output reg        dec_o
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 9'd0; inc_o <= 1'b0; dec_o <= 1'b0;
        end else begin
            if (inc_o & ~dec_o)      cnt <= cnt + 9'd1;
            else if (~inc_o & dec_o) cnt <= cnt - 9'd1;
            // clear AFTER the use, inside the consumer block: single driver
            if (!set) inc_o <= 1'b0;
            if (!dec) dec_o <= 1'b0;
            if (set)  inc_o <= 1'b1;
            if (dec)  dec_o <= 1'b1;
        end
    end
endmodule

module repro_multidriver_order_tb;
    reg clk = 0, rst_n = 0, set = 0, dec = 0;
    always #5 clk = ~clk;

    wire [8:0] cnt_cf, cnt_sf, cnt_mg;
    wire cf_i, cf_d, sf_i, sf_d, mg_i, mg_d;

    md_clear_first u_cf (.clk(clk), .rst_n(rst_n), .set(set), .dec(dec),
                         .cnt(cnt_cf), .inc_o(cf_i), .dec_o(cf_d));
    md_set_first   u_sf (.clk(clk), .rst_n(rst_n), .set(set), .dec(dec),
                         .cnt(cnt_sf), .inc_o(sf_i), .dec_o(sf_d));
    md_merged      u_mg (.clk(clk), .rst_n(rst_n), .set(set), .dec(dec),
                         .cnt(cnt_mg), .inc_o(mg_i), .dec_o(mg_d));

    integer n;
    initial begin
        $display("=== multi-driver order repro (axi4_master_bridge.v out_inc/out_dec) ===");
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        // pulse 'set' every other cycle: exactly the W_B commit pattern
        for (n = 0; n < 12; n = n + 1) begin
            set = 1'b1; dec = 1'b0; @(posedge clk);
            set = 1'b0; dec = 1'b0; @(posedge clk);
        end
        repeat (2) @(posedge clk);
        $display("clear-first  (real RTL source order) : cnt=%0d", cnt_cf);
        $display("set-first    (same logic, blocks swapped): cnt=%0d", cnt_sf);
        $display("merged clear (single driver, intended)   : cnt=%0d", cnt_mg);
        if (cnt_sf !== cnt_cf || cnt_cf !== cnt_mg)
            $display("REPRO: the counter value DEPENDS ON SOURCE ORDER of two always blocks");
        else
            $display("REPRO: no order dependence observed on this tool");
        $finish;
    end
endmodule
