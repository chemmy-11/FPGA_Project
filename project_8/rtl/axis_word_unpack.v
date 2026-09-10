//=============================================================================
// axis_word_unpack.v — 64-bit AXI4-Stream（Aurora RX）→ 8-bit 字节流
// 域：单时钟（Aurora user_clk），下游为帧泵写侧 frame_fifo_pump
//
// 字节序：tdata 端口声明 [0:63]，按位置连到本模块 [63:0] 逐位恒等。
//   lane0([7:0]) = 该拍第 1 个字节，lane7([63:56]) = 第 8 个。
//   末拍不足 8 字节时 IP 把有效字节放在**高位 lane**（keep = ~(8'hFF>>N)，
//   见 ll_to_axi.v:125-126，与打包端对称）。
//
// 【为什么必须"整帧存储转发"—— 实测踩坑 #1】
//   下游帧泵靠 wr_en 的**下降沿**判定帧尾：输出在帧中间出现哪怕 1 拍空拍，
//   一帧就会被切成多段，回显帧残破 → PC 网卡按 FCS 丢弃 → 表现为 ping 不通。
//   "边收边吐"版本（缓冲一空就插等待拍）因为 Aurora RX 有流水线延迟，
//   写侧与读侧平均速率又恰好相等（1 字/8 周期 ↔ 1 字节/周期），**必然**在帧中途
//   抽干：闭环仿真实测 34 帧收回 77 段、stall=40。
//   现改为等 wr_frames 与 rd_frames 不等（整帧已到齐）再开始吐。
//
// 【实测踩坑 #2：末拍空拍】按 lane 0..7 逐个扫、keep=0 的 lane "跳过不吐"，
//   会在帧中间留下 7 拍空拍（9 字节帧被切成 8+1 两段，仿真复现）。
//   现在改为：popcount(keep) 得有效字节数 N，最低有效 lane 为起点，
//   **连续吐 N 个字节**（哪条 lane 起、吐几个都由 keep 现算），帧内绝无空拍。
//   取"最低有效 lane"作起点还顺带兼容了另一种 keep 对齐约定（低位对齐）。
//
// 容量：AW=9 → 512 字 = 4096 字节（= 两个最大以太网帧），
//   保证"整帧缓冲 + 下一帧正在写入"也不会溢出。超限由 o_overflow 暴露。
//   o_stall_cnt 是金丝雀——整帧转发后正常应恒为 0。
//=============================================================================
`timescale 1ns / 1ps

module axis_word_unpack #(
    parameter AW = 9                                  // 512 字 = 4096 字节
)(
    input             clk          ,
    input             rst          ,   // 同步复位，高有效
    // 64-bit AXI4-Stream（← Aurora m_axi_rx，无 tready：必须永远 ready）
    input      [63:0] s_tdata      ,
    input      [7:0]  s_tkeep      ,
    input             s_tlast      ,
    input             s_tvalid     ,
    // 8-bit 字节流（→ 帧泵写侧）
    output reg [7:0]  out_data     ,
    output reg        out_valid    ,
    // 观测
    output reg [15:0] o_byte_cnt   ,
    output reg [15:0] o_frame_cnt  ,
    output reg        o_overflow   ,
    output reg [15:0] o_stall_cnt
);

    // ---- 整帧字级环形缓冲（写侧 = Aurora RX，读侧 = 逐字节展开）----
    reg [63:0] wf_data [0:(1<<AW)-1];
    reg [7:0]  wf_keep [0:(1<<AW)-1];
    reg        wf_last [0:(1<<AW)-1];
    reg [AW:0] wf_wr, wf_rd;
    reg [15:0] wr_frames, rd_frames;      // 已写全帧数 / 已吐完帧数

    wire wf_empty = (wf_wr == wf_rd);
    wire wf_full  = (wf_wr[AW] != wf_rd[AW]) && (wf_wr[AW-1:0] == wf_rd[AW-1:0]);
    wire frame_avail = (wr_frames != rd_frames);

    // ---- 有效字节数 / 首个有效 lane（两者都从 keep 现算）----
    function [3:0] popcnt8(input [7:0] v);
        popcnt8 = {3'b000, v[0]} + {3'b000, v[1]} + {3'b000, v[2]} + {3'b000, v[3]} +
                  {3'b000, v[4]} + {3'b000, v[5]} + {3'b000, v[6]} + {3'b000, v[7]};
    endfunction

    function [2:0] lowidx8(input [7:0] v);   // 最低有效 lane（v=0 时返回 7，由 n=0 兜住）
        // ⚠️ 不要写成 for 循环：实测 XSim 对函数内 for 循环按**升序**求值，
        //    结果变成"最高有效位"→ 字节顺序整帧循环移位（仿真实录：
        //    0xFF 返回 7 而非 0，导致每帧末字节跑到帧首）。优先链无歧义。
        begin
            if      (v[0]) lowidx8 = 3'd0;
            else if (v[1]) lowidx8 = 3'd1;
            else if (v[2]) lowidx8 = 3'd2;
            else if (v[3]) lowidx8 = 3'd3;
            else if (v[4]) lowidx8 = 3'd4;
            else if (v[5]) lowidx8 = 3'd5;
            else if (v[6]) lowidx8 = 3'd6;
            else           lowidx8 = 3'd7;
        end
    endfunction

    // ---- 当前字 ----
    reg [63:0] cur_word;
    reg [2:0]  cur_lane0;      // 首个有效 lane
    reg [3:0]  cur_n;          // 有效字节数 0..8
    reg        cur_last;
    reg [3:0]  byte_i;         // 本字已吐字节序号
    // ---- 预取字 ----
    reg [63:0] nf_word;
    reg [2:0]  nf_lane0;
    reg [3:0]  nf_n;
    reg        nf_last;
    reg        nf_valid;

    // ---- 输出状态 ----
    reg        emitting;
    reg        gap;            // 帧尾后的强制空拍
    reg        stall;          // 兜底金丝雀

    wire [2:0] sel_lane    = cur_lane0 + byte_i[2:0];   // 3 位算术，正常不越界
    wire       word_done   = (cur_n == 4'd0) | ((byte_i + 4'd1) == cur_n);
    wire       frame_done  = emitting & word_done & cur_last;

    wire nf_load = ~nf_valid & ~wf_empty;
    // 交接条件必须与输出侧取用条件**逐项一致**（少一项就会丢字：实测 2806→286 字节）
    wire take_nf = (!emitting & ~gap & frame_avail & nf_valid) |
                  ( emitting & word_done & ~cur_last & nf_valid);

    // ---------- 写侧：beat 入环 + 整帧计数 ----------
    always @(posedge clk) begin
        if (rst) begin
            wf_wr <= {(AW+1){1'b0}};
            wr_frames <= 16'd0;
            o_overflow <= 1'b0;
        end
        else begin
            if (s_tvalid) begin
                if (wf_full)
                    o_overflow <= 1'b1;               // 超过缓冲容量（不应发生）
                else begin
                    wf_data[wf_wr[AW-1:0]] <= s_tdata;
                    wf_keep[wf_wr[AW-1:0]] <= s_tkeep;
                    wf_last[wf_wr[AW-1:0]] <= s_tlast;
                    wf_wr <= wf_wr + 1'b1;
                    if (s_tlast) wr_frames <= wr_frames + 16'd1;
                end
            end
        end
    end

    // ---------- 预取侧 ----------
    always @(posedge clk) begin
        if (rst) begin
            wf_rd    <= {(AW+1){1'b0}};
            nf_word  <= 64'd0; nf_lane0 <= 3'd0; nf_n <= 4'd0; nf_last <= 1'b0;
            nf_valid <= 1'b0;
        end
        else begin
            if (nf_load) begin
                nf_word  <= wf_data[wf_rd[AW-1:0]];
                nf_lane0 <= lowidx8(wf_keep[wf_rd[AW-1:0]]);
                nf_n     <= popcnt8(wf_keep[wf_rd[AW-1:0]]);
                nf_last  <= wf_last[wf_rd[AW-1:0]];
                nf_valid <= 1'b1;
                wf_rd    <= wf_rd + 1'b1;
            end
            if (take_nf)
                nf_valid <= 1'b0;
        end
    end

    // ---------- 输出侧：整帧存储转发 + 连续吐字节 ----------
    always @(posedge clk) begin
        if (rst) begin
            out_data <= 8'd0; out_valid <= 1'b0;
            cur_word <= 64'd0; cur_lane0 <= 3'd0; cur_n <= 4'd0; cur_last <= 1'b0;
            byte_i <= 4'd0; emitting <= 1'b0; gap <= 1'b0; stall <= 1'b0;
            o_byte_cnt <= 16'd0; o_frame_cnt <= 16'd0; o_stall_cnt <= 16'd0;
            rd_frames <= 16'd0;
        end
        else begin
            out_valid <= 1'b0;

            if (!emitting) begin
                if (gap)
                    gap <= 1'b0;                            // 帧尾后的空拍
                else if (frame_avail && nf_valid && (nf_n != 4'd0)) begin
                    cur_word <= nf_word; cur_lane0 <= nf_lane0; cur_n <= nf_n;
                    cur_last <= nf_last;
                    byte_i <= 4'd0; emitting <= 1'b1;        // 下一拍吐 byte0
                end
            end
            else begin
                if ((cur_n != 4'd0) && !stall) begin
                    out_data   <= cur_word[sel_lane*8 +: 8];
                    out_valid  <= 1'b1;
                    o_byte_cnt <= o_byte_cnt + 16'd1;
                end

                if (word_done) begin
                    if (cur_last) begin
                        emitting    <= 1'b0;                // 帧结束
                        gap         <= 1'b1;
                        stall       <= 1'b0;
                        o_frame_cnt <= o_frame_cnt + 16'd1;
                    end
                    else if (nf_valid) begin
                        // 帧内续字：零空拍（整帧已在缓冲里）
                        cur_word <= nf_word; cur_lane0 <= nf_lane0; cur_n <= nf_n;
                        cur_last <= nf_last;
                        byte_i <= 4'd0; stall <= 1'b0;
                    end
                    else begin
                        stall       <= 1'b1;                // 金丝雀：不应发生
                        o_stall_cnt <= o_stall_cnt + 16'd1;
                    end
                end
                else
                    byte_i <= byte_i + 4'd1;
            end

            if (frame_done) rd_frames <= rd_frames + 16'd1;
        end
    end

endmodule
