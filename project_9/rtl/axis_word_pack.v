//=============================================================================
// axis_word_pack.v — 8-bit 字节流 → 64-bit AXI4-Stream（Aurora TX 侧）
// 域：单时钟（Aurora user_clk），上游为帧泵读侧输出（frame_fifo_pump，帧内无气泡）
//
// 【字节序 = 线上字节序】Aurora 64B/66B 的 tdata 端口声明为 [0:63]（升序，下标 0 = MSB），
//   按位置连接到本模块的 [63:0] 时二者逐位恒等。IP 源码实证（aurora_64b66b_v12_0_13）：
//   axi_to_ll.v:131 位保持 → tx_ll_datapath.v:152 位保持 → sym_gen.v:181 整字字节交换，
//   再结合 UG576 Fig.3-7（GT 先发 MSB 字节），得：**第 1 个字节 → lane0 = tdata[7:0]**，
//   第 8 个字节 → lane7 = tdata[63:56]；字内 lane 升序 = 流顺序。TX/RX 对称。
//   故组装用"变址写入 lane k"。
//
// 【帧尾不足 8 字节：必须高位 lane 对齐】IP 由 tkeep 从最高位起数连续 1 得 REM
//   （axi_to_ll.v:146-156），并在收侧按 REM 生成 keep = ~(8'hFF>>N)（ll_to_axi.v:125-126）。
//   故末拍 N 个有效字节必须落在 **高位 lane**：lane(8-N)=第 1 字节 … lane7=最后 1 字节，
//   tkeep = 8'hFF << (8-N)（N=4→F0, 5→F8, 满拍→FF）。
//   ⚠️ 与常见 Xilinx AXIS 的低位对齐(0x0F)相反；喂 0x0F 会被当成满 8 字节 → 收端多出垃圾字节。
//   实现：余字按常规装好后整体左移 8*(8-N)。
//
// 【为什么需要 pend 暂存】字组装完成的那一拍还不知道该字是不是帧尾，
//   故完成的字先进 pend；下一拍若帧仍在继续 → 以 tlast=0 入队；帧结束 → 定 tlast。
//
// 【帧尾余字】帧长不是 8 的倍数时，帧尾会同时存在 pend 字 + 余字节：
//   必须入队两个 beat（pend 以 tlast=0，余字以 tlast=1）。分两拍完成：
//   第 1 拍入队 pend，第 2 拍（tail_flush）入队余字。帧间必有空拍
//   （帧泵握手保证 ≥5 拍），故不会丢输入字节；万一发生则以 o_overflow 单拍脉冲暴露
//   （2026-09-21 由粘滞电平改为脉冲，配顶层 o_overflow 计数器给出事件幅度）。
//=============================================================================
`timescale 1ns / 1ps

module axis_word_pack (
    input             clk          ,
    input             rst          ,   // 同步复位，高有效（= 系统复位 | !channel_up）
    // 8-bit 字节流（上游帧泵读侧）
    input      [7:0]  in_data      ,
    input             in_valid     ,
    // 64-bit AXI4-Stream（→ Aurora s_axi_tx）
    output     [63:0] m_tdata      ,
    output     [7:0]  m_tkeep      ,
    output            m_tlast      ,
    output            m_tvalid     ,
    input             m_tready     ,
    // 观测
    output reg [15:0] o_frame_cnt  ,
    output reg        o_overflow
);

    // ---- 组装中的字（字节自低端移入）----
    reg [63:0] asm_word;
    reg [2:0]  asm_cnt;         // 已移入字节数 0..7
    reg        frame_active;

    // ---- 刚完成、tlast 待定的字 ----
    reg [63:0] pend_word;
    reg        pend_valid;

    // ---- 帧尾余字（< 8 字节）补入队 ----
    reg [63:0] tail_word;
    reg [7:0]  tail_keep;
    reg        tail_flush;

    // ---- 输出队列（2 深，head/tail 各 1 位）----
    reg [63:0] q_word [0:1];
    reg [7:0]  q_keep [0:1];
    reg        q_last [0:1];
    reg        q_head, q_tail;
    reg [1:0]  q_cnt;

    wire q_empty = (q_cnt == 2'd0);
    wire q_full  = (q_cnt == 2'd2);

    assign m_tdata  = q_word[q_head];
    assign m_tkeep  = q_keep[q_head];
    assign m_tlast  = q_last[q_head];
    assign m_tvalid = ~q_empty;

    wire pop = m_tvalid & m_tready;

    // 左对齐辅助：asm_cnt 个余字节 → 高 asm_cnt 个 lane
    wire [2:0]  miss       = 3'd0 - asm_cnt;        // = 8 - asm_cnt（asm_cnt=1..7）
    wire [5:0]  tail_shift = {miss, 3'b000};        // = miss * 8
    wire [7:0]  tail_keep_w = 8'hFF << miss;        // 高 asm_cnt 位置 1

    // 入队候选
    reg        en;
    reg [63:0] en_word;
    reg [7:0]  en_keep;
    reg        en_last;

    always @(posedge clk) begin
        if (rst) begin
            asm_word <= 64'd0; asm_cnt <= 3'd0; frame_active <= 1'b0;
            pend_word <= 64'd0; pend_valid <= 1'b0;
            tail_word <= 64'd0; tail_keep <= 8'd0; tail_flush <= 1'b0;
            q_head <= 1'b0; q_tail <= 1'b0; q_cnt <= 2'd0;
            o_frame_cnt <= 16'd0; o_overflow <= 1'b0;
        end
        else begin
            en = 1'b0; en_word = 64'd0; en_keep = 8'd0; en_last = 1'b0;
            // prj9 判决(2026-09-21): 默认清零 + 事件置位 = 单拍脉冲(原为粘滞电平,
            // 只能回答"发生过没有"; 脉冲版配顶层计数器可给事件次数)
            o_overflow <= 1'b0;

            if (tail_flush) begin
                // 补入队帧尾余字（本拍不接收新字节：帧间必有空拍）
                en = 1'b1; en_word = tail_word; en_keep = tail_keep; en_last = 1'b1;
                tail_flush <= 1'b0;
                if (in_valid) o_overflow <= 1'b1;   // 不应发生；发生即可见
            end
            else begin
                // ---------- 输入：字节写入 lane asm_cnt ----------
                if (in_valid) begin
                    frame_active <= 1'b1;
                    if (asm_cnt == 3'd7) begin
                        // 本字节 = 第 8 字节 → lane7（合成整字存入 pend）
                        if (pend_valid) begin
                            // 前一个完成字后面还有数据 → 它不是帧尾
                            en = 1'b1; en_word = pend_word; en_keep = 8'hFF; en_last = 1'b0;
                        end
                        pend_word  <= {in_data, asm_word[55:0]};
                        pend_valid <= 1'b1;
                        asm_cnt    <= 3'd0;
                    end
                    else begin
                        asm_word[asm_cnt*8 +: 8] <= in_data;   // 第 k 字节 → lane k
                        asm_cnt  <= asm_cnt + 3'd1;
                    end
                end
                // ---------- 帧结束：定 tlast ----------
                else if (frame_active) begin
                    frame_active <= 1'b0;
                    o_frame_cnt  <= o_frame_cnt + 16'd1;
                    if (pend_valid) begin
                        pend_valid <= 1'b0;
                        en = 1'b1; en_word = pend_word; en_keep = 8'hFF;
                        en_last = (asm_cnt == 3'd0);      // 帧正好落在字边界 → pend 即帧尾
                        if (asm_cnt != 3'd0) begin
                            tail_word  <= asm_word << tail_shift;   // 余字节左对齐
                            tail_keep  <= tail_keep_w;
                            tail_flush <= 1'b1;                     // 下一拍补入队
                            asm_cnt    <= 3'd0;
                        end
                    end
                    else if (asm_cnt != 3'd0) begin
                        en = 1'b1;
                        en_word = asm_word << tail_shift;
                        en_keep = tail_keep_w;
                        en_last = 1'b1;
                        asm_cnt <= 3'd0;
                    end
                end
            end

            // ---------- 入队 / 出队（每拍至多 1 次入队）----------
            if (en) begin
                if (q_full) o_overflow <= 1'b1;
                else begin
                    q_word[q_tail] <= en_word;
                    q_keep[q_tail] <= en_keep;
                    q_last[q_tail] <= en_last;
                    q_tail <= ~q_tail;
                end
            end
            if (pop) q_head <= ~q_head;

            if (en && !q_full && pop) q_cnt <= q_cnt;          // 同时进出
            else if (en && !q_full)   q_cnt <= q_cnt + 2'd1;
            else if (pop)             q_cnt <= q_cnt - 2'd1;
        end
    end

endmodule