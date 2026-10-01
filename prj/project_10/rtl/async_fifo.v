//=============================================================================
// async_fifo.v -- gray-pointer async FIFO (CDC primitive, prj10 W2)
//-----------------------------------------------------------------------------
// Purpose : the ONLY legal data-crossing primitive in this project besides the
//           2FF synchronizer and the 4-phase mailbox (AGENTS.md S5.1).
//           Used at the four user_clk <-> ui_clk crossings of the memory bridge.
// Why     : Cummings-style gray pointers + 2FF synchronizers. Read data is
//           first-word-fall-through (combinational from the RAM), so a consumer
//           sees rd_data valid in any cycle where rd_empty==0 and pops it by
//           asserting rd_en for one cycle. Same contract as frame_fifo_pump.v
//           (proven on board, prj9).
// NOTE W3 : depth 4096x8 / 16x512 RAMs are fine as LUTRAM in simulation; on board
//           these instances become FIFO IP to keep ui_clk timing closed. Sim
//           behaviour is identical.
//=============================================================================
`timescale 1ns/1ps

module async_fifo #(
    parameter DW = 8,          // data width
    parameter AW = 11          // address width -> depth = 2**AW
)(
    // ---- write side ----
    input  wire           wr_clk,
    input  wire           wr_rst_n,
    input  wire [DW-1:0]  wr_data,
    input  wire           wr_en,
    output wire           wr_full,
    output wire [AW:0]    wr_level,   // words inside (wr domain, conservative)
    // ---- read side ----
    input  wire           rd_clk,
    input  wire           rd_rst_n,
    output wire [DW-1:0]  rd_data,    // FWFT: valid whenever rd_empty==0
    input  wire           rd_en,
    output wire           rd_empty,
    output wire [AW:0]    rd_level    // words inside (rd domain, conservative)
);

    localparam DEPTH = (1 << AW);

    reg [DW-1:0] ram [0:DEPTH-1];

    reg [AW:0] wr_bin, wr_gray;
    reg [AW:0] rd_bin, rd_gray;
    reg [AW:0] rd_gray_s1, rd_gray_s2;   // rd pointer synced into wr domain
    reg [AW:0] wr_gray_s1, wr_gray_s2;   // wr pointer synced into rd domain

    function [AW:0] bin2gray(input [AW:0] b);
        bin2gray = (b >> 1) ^ b;
    endfunction

    function [AW:0] gray2bin(input [AW:0] g);
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [AW:0] wr_bin_nxt  = wr_bin + 1'b1;
    wire [AW:0] wr_gray_nxt = bin2gray(wr_bin_nxt);
    wire [AW:0] rd_bin_nxt  = rd_bin + 1'b1;

    // standard Cummings full / empty
    assign wr_full  = (wr_gray_nxt == {~rd_gray_s2[AW:AW-1], rd_gray_s2[AW-2:0]});
    assign rd_empty = (rd_gray == wr_gray_s2);

    assign rd_data  = ram[rd_bin[AW-1:0]];
    assign rd_level = gray2bin(wr_gray_s2) - rd_bin;
    assign wr_level = wr_bin - gray2bin(rd_gray_s2);

    // ---- write domain ----
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin <= 0; wr_gray <= 0;
            rd_gray_s1 <= 0; rd_gray_s2 <= 0;
        end else begin
            rd_gray_s1 <= rd_gray;
            rd_gray_s2 <= rd_gray_s1;
            if (wr_en && !wr_full) begin
                wr_bin  <= wr_bin_nxt;
                wr_gray <= wr_gray_nxt;
            end
        end
    end

    always @(posedge wr_clk) begin
        if (wr_en && !wr_full)
            ram[wr_bin[AW-1:0]] <= wr_data;
    end

    // ---- read domain ----
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin <= 0; rd_gray <= 0;
            wr_gray_s1 <= 0; wr_gray_s2 <= 0;
        end else begin
            wr_gray_s1 <= wr_gray;
            wr_gray_s2 <= wr_gray_s1;
            if (rd_en && !rd_empty) begin
                rd_bin  <= rd_bin_nxt;
                rd_gray <= bin2gray(rd_bin_nxt);
            end
        end
    end

endmodule
