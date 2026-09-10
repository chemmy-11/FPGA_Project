//=============================================================================
// axis_word_unpack.v — 64-bit AXI4-Stream（Aurora RX）→ 8-bit 字节流
// 域：单时钟（Aurora user_clk），下游为帧泵写侧 frame_fifo_pump
//
// 约定：tdata[k*8 +: 8] = 帧内第 k 字节（与 axis_word_pack 严格对称）
//       tkeep[k]=1 表示该字节有效
//
// 【为什么必须"帧内无气泡"】下游帧泵靠 wr_en 下降沿判定帧尾——若在字与字之间
//   插入空拍，一个帧会被切成多个"帧"，帧长错乱、回显必错。故本模块用
//   "预取双缓冲"：当前字逐字节吐出期间，下一字已提前取到 nf_*；byte_idx==7
//   当拍直接把 nf→cur，下一拍即吐新字 byte0 —— 帧内零气泡。
//   仅当环形缓冲真被读空（理论上不发生：10G 链路 vs 125M 消费）时插等待拍
//   （stall），并用 o_stall_cnt 计数便于 ILA 观察。
//
// 为什么需要缓冲：m_axi_rx 无 tready（不可反压），而输出侧每拍最多吐 1 字节
//   ——用 64 字（512 字节）字级环形缓冲吸收 Aurora 核的突发。
//
// 帧尾处理：tlast 字吐完后插 ≥1 拍气泡（还原帧间隙，让帧泵正确判尾）。
//=============================================================================
module axis_word_unpack (
    input             clk          ,
    input             rst          ,   // 同步复位，高有效
    // 64-bit AXI4-Stream（← Aurora m_axi_rx）
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

    // ---- 字级环形缓冲：64 字 × (64bit 数据 + 8bit keep + 1bit last) ----
    localparam AW = 6;
    reg [63:0] wf_data [0:(1<<AW)-1];
    reg [7:0]  wf_keep [0:(1<<AW)-1];
    reg        wf_last [0:(1<<AW)-1];
    reg [AW:0] wf_wr, wf_rd;

    wire wf_empty = (wf_wr == wf_rd);
    wire wf_full  = (wf_wr[AW] != wf_rd[AW]) && (wf_wr[AW-1:0] == wf_rd[AW-1:0]);

    // ---- 当前吐出的字 ----
    reg [63:0] cur_word;
    reg [7:0]  cur_keep;
    reg        cur_last;
    reg [2:0]  byte_idx;
    // ---- 预取字（nf = next word from fifo）----
    reg [63:0] nf_word;
    reg [7:0]  nf_keep;
    reg        nf_last;
    reg        nf_valid;

    // ---- 输出状态 ----
    reg        emitting;    // 1 = 正在按 byte_idx 吐字节
    reg        gap;         // 帧尾后的强制空拍
    reg        stall;       // byte7 已吐、下一字未就绪 → 本拍不吐、等预取

    // 【字节序 = 线上字节序】lane0([7:0]) = 该拍第 1 个字节，lane7([63:56]) = 第 8 个。
    //   byte_idx 按流顺序递增 0..7，lane = byte_idx（升序遍历）。
    //   末拍不足 8 字节时 IP 把有效字节放在 **高位 lane**（keep = ~(8'hFF>>N)，
    //   见 ll_to_axi.v:125-126，与打包端对称）。升序遍历会先跳过无效的低位 lane
    //   （不吐字节、仅耗 1 拍），再从 lane(8-N) 起按流顺序吐完 —— 仅发生在帧尾，
    //   气泡无害。这样对"高位对齐/低位对齐"两种约定都不会吐错字节。
    wire [2:0] lane = byte_idx;

    // 预取装载条件（任何一拍都可发生）
    wire nf_load = ~nf_valid & ~wf_empty;

    // nf → cur 交接（组合，供预取侧清 nf_valid；必须在 always 之前声明）
    //   （stall 拍同样要交接并清 nf_valid，否则同一字会被反复装载 → 重复字节）
    wire take_nf = (!emitting & ~gap & nf_valid) |
                  ( emitting & (byte_idx == 3'd7) & ~cur_last & nf_valid);

    // ---------- 输入侧：beat 入队（唯一驱动 wf_wr）----------
    always @(posedge clk) begin
        if (rst) begin
            wf_wr <= {(AW+1){1'b0}};
            o_overflow <= 1'b0;
        end
        else begin
            if (s_tvalid) begin
                if (wf_full)
                    o_overflow <= 1'b1;      // 理论不发生（10G 链路 + 512B 缓冲）
                else begin
                    wf_data[wf_wr[AW-1:0]] <= s_tdata;
                    wf_keep[wf_wr[AW-1:0]] <= s_tkeep;
                    wf_last[wf_wr[AW-1:0]] <= s_tlast;
                    wf_wr <= wf_wr + 1'b1;
                end
            end
        end
    end

    // ---------- 预取侧：唯一驱动 wf_rd / nf_* ----------
    always @(posedge clk) begin
        if (rst) begin
            wf_rd   <= {(AW+1){1'b0}};
            nf_word <= 64'd0; nf_keep <= 8'd0; nf_last <= 1'b0; nf_valid <= 1'b0;
        end
        else begin
            if (nf_load) begin
                nf_word  <= wf_data[wf_rd[AW-1:0]];
                nf_keep  <= wf_keep[wf_rd[AW-1:0]];
                nf_last  <= wf_last[wf_rd[AW-1:0]];
                nf_valid <= 1'b1;
                wf_rd    <= wf_rd + 1'b1;
            end
            if (take_nf)
                nf_valid <= 1'b0;             // 本拍被 cur 取走
        end
    end

    // ---------- 输出侧：唯一驱动 out_* / cur_* / byte_idx / emitting ----------
    always @(posedge clk) begin
        if (rst) begin
            out_data <= 8'd0; out_valid <= 1'b0;
            cur_word <= 64'd0; cur_keep <= 8'd0; cur_last <= 1'b0;
            byte_idx <= 3'd0; emitting <= 1'b0; gap <= 1'b0; stall <= 1'b0;
            o_byte_cnt <= 16'd0; o_frame_cnt <= 16'd0; o_stall_cnt <= 16'd0;
        end
        else begin
            out_valid <= 1'b0;

            if (!emitting) begin
                if (gap)
                    gap <= 1'b0;                              // 帧尾后的空拍
                else if (nf_valid) begin
                    cur_word <= nf_word; cur_keep <= nf_keep; cur_last <= nf_last;
                    byte_idx <= 3'd0; emitting <= 1'b1;        // 下一拍吐 byte0
                end
            end
            else begin
                // 本拍吐 byte_idx（寄存输出 → 下一拍线上有效）；stall 拍不吐
                if (cur_keep[lane] && !stall) begin
                    out_data   <= cur_word[lane*8 +: 8];
                    out_valid  <= 1'b1;
                    o_byte_cnt <= o_byte_cnt + 16'd1;
                end

                if (byte_idx == 3'd7) begin
                    if (cur_last) begin
                        emitting    <= 1'b0;                  // 帧结束
                        gap         <= 1'b1;
                        stall       <= 1'b0;
                        o_frame_cnt <= o_frame_cnt + 16'd1;
                    end
                    else if (nf_valid) begin
                        // 帧内续字：零气泡（本拍交接，下一拍吐新字 byte0）
                        cur_word <= nf_word; cur_keep <= nf_keep; cur_last <= nf_last;
                        byte_idx <= 3'd0; stall <= 1'b0;
                    end
                    else begin
                        stall       <= 1'b1;                 // 罕见读空 → 等预取
                        o_stall_cnt <= o_stall_cnt + 16'd1;
                    end
                end
                else
                    byte_idx <= byte_idx + 3'd1;
            end
        end
    end

endmodule
