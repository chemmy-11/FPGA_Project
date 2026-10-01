//=============================================================================
// async_fifo_model.v - async_fifo_2048x8b behavioral model (simulation only)
//   Config: Standard_FIFO + Independent_Clocks_Block_RAM (from .xci)
//   Behavior: standard read mode (NOT FWFT): dout valid 1 cycle after rd_en.
//=============================================================================
`timescale 1ns/1ps
module async_fifo_2048x8b (
    input        rst,
    input        wr_clk,
    input        rd_clk,
    input  [7:0] din,
    input        wr_en,
    input        rd_en,
    output [7:0] dout,
    output       full,
    output       empty
);
    localparam AW = 11;  // 2048
    reg [7:0] mem [0:(1<<AW)-1];
    reg [AW:0] wptr = 0, rptr = 0;
    reg [7:0]  dout_r = 0;

    assign full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
    assign empty = (wptr == rptr);
    assign dout  = dout_r;

    always @(posedge wr_clk or posedge rst) begin
        if (rst) wptr <= 0;
        else if (wr_en && !full) begin
            mem[wptr[AW-1:0]] <= din;
            wptr <= wptr + 1'b1;
        end
    end

    always @(posedge rd_clk or posedge rst) begin
        if (rst) begin rptr <= 0; dout_r <= 0; end
        else if (rd_en && !empty) begin
            dout_r <= mem[rptr[AW-1:0]];
            rptr <= rptr + 1'b1;
        end
    end
endmodule
