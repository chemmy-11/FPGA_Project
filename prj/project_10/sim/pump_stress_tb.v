//=============================================================================
// pump_stress_tb.v — 帧泵背靠背压力测试（L1 乒乓缓冲的验收用例）2026-10-09
//   200 帧 x 86B, 帧间仅 10 拍(80ns) —— 逼近背靠背。
//   原版(握手门控): 帧在途时到达的帧整帧丢弃 -> wr_drop_cnt 显著
//   L1(乒乓双 bank): 排出与下一帧到达重叠 -> 期望 wr_drop_cnt=0 且 rd_frame_cnt=200
//   编译时选 RTL: 原版用 ../../prj/rtl/frame_fifo_pump.v; L1 用 ../rtl_patch/frame_fifo_pump.v
//=============================================================================
`timescale 1ns/1ps
module pump_stress_tb;
    reg wr_clk = 0, rd_clk = 0;
    reg wr_rst_n = 0, rd_rst_n = 0;
    reg  [7:0] wr_data = 0;
    reg        wr_en = 0;
    wire [7:0] rd_data;
    wire       rd_en;
    wire [15:0] wr_frame_cnt, wr_drop_cnt, rd_frame_cnt;
    wire        hs_busy;

    frame_fifo_pump dut (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n),
        .wr_data(wr_data), .wr_en(wr_en),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n),
        .rd_data(rd_data), .rd_en(rd_en),
        .wr_frame_cnt(wr_frame_cnt), .wr_drop_cnt(wr_drop_cnt),
        .rd_frame_cnt(rd_frame_cnt), .o_hs_busy(hs_busy)
    );

    always #4   wr_clk = ~wr_clk;      // 125 MHz
    always #3.1 rd_clk = ~rd_clk;      // ~161 MHz (与 user_clk 同量级)

    integer fi, bi;
    integer total_frames = 200;
    integer gap = 10;                  // 帧间 10 拍
    integer flen = 86;
    integer rd_seen = 0;
    integer rd_frames = 0;
    integer byte_errs = 0;             // ★2026-10-09: 逐字节校验(计数型 TB 放行过 off-by-one)

    // 读侧: 无条件接收(模拟下游总能收), 逐字节校验内容与位置
    //   帧内容 = 生成序号 0..flen-1; 位置 = 帧内偏移; 多一拍/少一字节都会被抓住
    always @(posedge rd_clk) if (rd_en) begin
        rd_seen = rd_seen + 1;
        if (rd_data !== (rd_seen - rd_frames*flen - 1))
            byte_errs = byte_errs + 1;
        if (rd_seen == (rd_frames+1)*flen)
            rd_frames = rd_frames + 1;
    end

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

    initial begin
        repeat (5) @(posedge wr_clk);
        wr_rst_n = 1; rd_rst_n = 1;
        repeat (10) @(posedge wr_clk);
        for (fi = 0; fi < total_frames; fi = fi + 1) begin
            send_frame(flen);
            repeat (gap) @(posedge wr_clk);
        end
        repeat (2000) @(posedge wr_clk);
        $display("RESULT: sent=%0d wr_frame_cnt=%0d wr_drop_cnt=%0d rd_frame_cnt=%0d rd_bytes=%0d byte_errs=%0d",
                 total_frames, wr_frame_cnt, wr_drop_cnt, rd_frame_cnt, rd_seen, byte_errs);
        if (wr_frame_cnt + wr_drop_cnt != total_frames)
            $display("PUMP_STRESS: FAIL (帧量不守恒: 丢了 %0d)", total_frames - wr_frame_cnt - wr_drop_cnt);
        else if (wr_drop_cnt != 0)
            $display("PUMP_STRESS: DROP (%0d/%0d 帧被丢弃 —— 握手门控的固有行为)", wr_drop_cnt, total_frames);
        else if (byte_errs != 0 || rd_seen != total_frames*flen || rd_frame_cnt != total_frames)
            $display("PUMP_STRESS: FAIL (内容/字节数错误: byte_errs=%0d rd_bytes=%0d(期望 %0d) rd_frames=%0d",
                     byte_errs, rd_seen, total_frames*flen, rd_frame_cnt);
        else
            $display("PUMP_STRESS: PASS (0 丢帧, %0d 帧 x %0d B 全部逐字节一致)", total_frames, flen);
        $finish;
    end
endmodule