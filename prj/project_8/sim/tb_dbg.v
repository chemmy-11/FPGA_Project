//=============================================================================
// tb_dbg.v — 最小隔离测试：lowidx8 函数 + 单拍 unpack 字节顺序
//=============================================================================
`timescale 1ns / 1ps

module tb_dbg;

    reg clk = 1'b0;
    always #3.3 clk = ~clk;

    function [2:0] lowidx8(input [7:0] v);
        integer k;
        begin
            lowidx8 = 3'd0;
            for (k = 7; k >= 0; k = k - 1)
                if (v[k]) lowidx8 = k[2:0];
        end
    endfunction

    function [3:0] popcnt8(input [7:0] v);
        popcnt8 = {3'b000, v[0]} + {3'b000, v[1]} + {3'b000, v[2]} + {3'b000, v[3]} +
                  {3'b000, v[4]} + {3'b000, v[5]} + {3'b000, v[6]} + {3'b000, v[7]};
    endfunction

    reg [63:0] td = 64'h0807_0605_0403_0201;   // lane0=01 ... lane7=08
    reg [7:0]  tk = 8'hFF;
    reg        tl = 1'b1;
    reg        tv = 1'b0;
    reg        rst = 1'b1;

    wire [7:0]  od;
    wire        ov;
    wire [15:0] bc, fc, st;
    wire        of_;

    axis_word_unpack u_unpack (
        .clk(clk), .rst(rst),
        .s_tdata(td), .s_tkeep(tk), .s_tlast(tl), .s_tvalid(tv),
        .out_data(od), .out_valid(ov),
        .o_byte_cnt(bc), .o_frame_cnt(fc), .o_overflow(of_), .o_stall_cnt(st)
    );

    integer n = 0;
    initial begin
        $display("fn(lowidx8): FF->%0d  F8->%0d  E0->%0d  80->%0d  0F->%0d  01->%0d",
                 lowidx8(8'hFF), lowidx8(8'hF8), lowidx8(8'hE0),
                 lowidx8(8'h80), lowidx8(8'h0F), lowidx8(8'h01));
        $display("fn(popcnt8): FF->%0d  F8->%0d  E0->%0d  0F->%0d",
                 popcnt8(8'hFF), popcnt8(8'hF8), popcnt8(8'hE0), popcnt8(8'h0F));
    end

    initial begin
        rst = 1'b1; tv = 1'b0;
        repeat (6) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        tv = 1'b1;                 // 单个满字 beat（keep=FF, tlast=1）
        @(negedge clk);
        tv = 1'b0;
        repeat (30) begin
            @(negedge clk);
            if (ov) begin $display("  out[%0d] = %02h", n, od); n = n + 1; end
        end
        $display("  共计 %0d 字节（期望 8，顺序 01..08）  frames=%0d ovf=%b stall=%0d",
                 n, fc, of_, st);
        $finish;
    end

endmodule
