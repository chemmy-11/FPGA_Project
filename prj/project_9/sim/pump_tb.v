//=============================================================================
// pump_tb.v — 复现 prj9 板上楔死 + 验证修复
//=============================================================================
`timescale 1ns/1ps
module pump_tb;
    reg wr_clk = 0, rd_clk = 0;
    reg wr_rst_n = 0, rd_rst_n = 0;
    reg  [7:0] wr_data = 0;
    reg        wr_en = 0;
    wire [7:0] rd_data;
    wire       rd_en;
    wire [15:0] wr_frame_cnt, wr_drop_cnt, rd_frame_cnt;

    frame_fifo_pump dut (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n),
        .wr_data(wr_data), .wr_en(wr_en),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n),
        .rd_data(rd_data), .rd_en(rd_en),
        .wr_frame_cnt(wr_frame_cnt), .wr_drop_cnt(wr_drop_cnt),
        .rd_frame_cnt(rd_frame_cnt)
    );

    always #4 wr_clk = ~wr_clk;    // 125 MHz
    always #3.1 rd_clk = ~rd_clk;  // 161 MHz

    integer fi, bi;
    task send_frame(input integer nbytes);
        begin
            for (bi = 0; bi < nbytes; bi = bi + 1) begin
                @(posedge wr_clk);
                wr_data <= bi[7:0]; wr_en <= 1'b1;
            end
            @(posedge wr_clk);
            wr_en <= 1'b0;
        end
    endtask

    integer total_frames = 40;
    initial begin
        repeat (5) @(posedge wr_clk);
        wr_rst_n = 1; rd_rst_n = 1;
        repeat (10) @(posedge wr_clk);
        for (fi = 0; fi < total_frames; fi = fi + 1) begin
            send_frame(86);
            $display("F%0d: busy=%b drop_f=%b full=%b wrcnt=%0d wrbin=%0d rdbin=%0d",
                     fi, dut.hs_busy, dut.frm_dropping, dut.wr_full, dut.wr_cnt, dut.wr_bin, dut.rd_bin);
            repeat (50) @(posedge wr_clk);
        end
        repeat (500) @(posedge wr_clk);
        $display("RESULT: wr_frame_cnt=%0d wr_drop_cnt=%0d rd_frame_cnt=%0d (sent %0d)",
                 wr_frame_cnt, wr_drop_cnt, rd_frame_cnt, total_frames);
        if (wr_frame_cnt + wr_drop_cnt != total_frames)
            $display("WEDGE_REPRODUCED: %0d frames vanished", total_frames - wr_frame_cnt - wr_drop_cnt);
        else
            $display("ALL_ACCOUNTED");
        $finish;
    end
endmodule
