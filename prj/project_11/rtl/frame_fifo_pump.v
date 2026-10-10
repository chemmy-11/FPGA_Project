//=============================================================================
// frame_fifo_pump.v — L1 乒乓双 bank 版（prj10 派生, 2026-10-09）
//
// 为什么派生: prj9 原版是**握手门控** —— wr_valid = wr_en && !wr_full && !hs_busy,
//   即「帧在途时到达的帧整帧丢弃」。源码注释自认: "Human-paced UDP/ARP/ping
//   traffic has huge gaps; stress mode is future work"。
//
// 实测代价(2026-10-09 上板 + 背靠背压力 TB):
//   · 压力 TB: 200 帧只过 100 帧(丢 50%), 与板上首丢序列 [1,3,5,7,9] 一致;
//   · 上板帧率上限 T = 7.0us + 11.6ns/字节, 其中字节项 = 线速到达 8.0 + 本泵排出
//     3.33 -> 即「到达」与「排出」被握手串行; 1466B 帧封顶 ~41.7k fps(489 Mbps),
//     而线速口径是 81.27k fps(957 Mbps)。
//
// 修法: 乒乓双 bank —— 写 bank X 的同时读侧排 bank Y, 帧尾立即翻 bank 继续接收。
//   · 每帧独占一个 bank(2048B), 从 bank 内地址 0 写起 => 不需要环形格雷指针;
//   · 跨域只需每 bank 一对 toggle(wr_tog/rd_tog, 各 2FF 同步) => 结构比原版更简单;
//   · bank 空闲 <=> wr_tog[b] == rd_tog[b](同步后); 满 <=> 不等;
//   · 写侧只写「读侧下一个要排的 bank」=> 天然保序、无死锁;
//   · bank 仍忙时该帧整帧丢弃(沿用原语义), 但正常流水下不再丢。
//
// 兼容: 端口与 prj9 原版完全一致(含 o_hs_busy), 可原位替换。
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
module frame_fifo_pump(
    input               wr_clk      ,
    input               wr_rst_n    ,
    input       [7:0]   wr_data     ,
    input               wr_en       ,
    input               rd_clk      ,
    input               rd_rst_n    ,
    output  reg [7:0]   rd_data     ,
    output  reg         rd_en       ,
    output  reg [15:0]  wr_frame_cnt,
    output  reg [15:0]  wr_drop_cnt ,
    output  reg [15:0]  rd_frame_cnt,
    output              o_hs_busy
);

    localparam AW = 11;                       // bank 深度 2048 B (单帧最大 1538 装得下)
    localparam BD = (1 << AW);

    reg [7:0] ram [0:2*BD-1];                 // 4096 B = 2 banks

    // ---- 每 bank 一对握手 toggle ----
    reg  [1:0] wr_tog;                        // wr 域: bank 写完一帧则翻转
    reg  [1:0] rd_tog;                        // rd 域: bank 排空则翻转
    reg  [1:0] rd_tog_s1, rd_tog_s2;          // rd_tog -> wr 域 (2FF)
    reg  [1:0] wr_tog_s1, wr_tog_s2;          // wr_tog -> rd 域 (2FF)

    reg  [15:0] len0, len1;                   // 各 bank 帧长(wr 域锁存, 握手保证读侧稳定)
    reg  [15:0] wr_cnt;
    reg         wr_active;
    reg         frm_dropping;
    reg         wr_dv_d;
    reg  [AW-1:0] wr_addr;
    reg         wr_bank;                      // 当前写 bank
    reg         rd_bank;                      // rd 域: 下一个要排的 bank

    reg  [15:0] rd_cnt_i, rd_cnt_o, rd_len;
    reg  [AW-1:0] rd_addr;
    reg         st;
    reg         rd_en_i, ram_dout_v;
    reg  [7:0]  ram_dout;

    wire wr_start  = wr_en & ~wr_dv_d;
    wire wr_last   = ~wr_en &  wr_dv_d;
    wire bank_free = (wr_tog[wr_bank] == rd_tog_s2[wr_bank]);
    wire accept    = wr_start & ~wr_active & ~frm_dropping & bank_free;
    wire ovf       = (wr_cnt >= BD[15:0] - 16'd1);   // 防御: 超 bank 容量强制转丢弃
    // ★off-by-one 修复(2026-10-09): 首字节必须在 accept 的**同一拍**写入。
    //   原写法只用 wr_active 做写使能, 而 wr_active 要到下一拍才置位 -> 每帧首字节
    //   被吞(实测: 86B 帧只读出 85B 且内容左移一位; 计数型 TB 查不出, 必须查字节内容)。
    wire byte_we   = wr_en & (wr_active | accept) & ~ovf;

    assign o_hs_busy = (wr_tog != rd_tog_s2);        // 「有帧在途」= 任一 bank 未排空

    //=========================================================================
    // 写侧: bank 内顺序写; 帧尾翻 bank 立即接收下一帧(核心改动点)
    //=========================================================================
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if(!wr_rst_n) begin
            wr_tog <= 2'b00; rd_tog_s1 <= 2'b00; rd_tog_s2 <= 2'b00;
            len0 <= 16'd0; len1 <= 16'd0; wr_cnt <= 16'd0;
            wr_active <= 1'b0; frm_dropping <= 1'b0; wr_dv_d <= 1'b0;
            wr_addr <= {AW{1'b0}}; wr_bank <= 1'b0;
            wr_frame_cnt <= 16'd0; wr_drop_cnt <= 16'd0;
        end
        else begin
            wr_dv_d   <= wr_en;
            rd_tog_s1 <= rd_tog;
            rd_tog_s2 <= rd_tog_s1;

            if(byte_we) begin
                // ★关键: 指针推进必须留在**本块**。RAM 数据写拆到独立块(保证 BRAM
                //   推断), 但若指针也在那个块里推进, 就成了两个 always 块驱动 wr_addr
                //   = 多驱动(坑账本 #25: 仿真能过、DRC 直接挂)。照 prj9 原版模式:
                //   指针块管指针, RAM 块只管数据。
                wr_addr <= wr_addr + 1'b1;
                wr_cnt  <= wr_cnt + 16'd1;   // 帧首拍 wr_cnt 必为 0(上一帧尾已清)
            end

            if(wr_start) begin
                // ★不得在此清 wr_cnt/wr_addr: 与 byte_we 同拍时后写的赋值会赢,
                //   把首字节的计数清掉(正是 off-by-one 的第二个来源)。
                //   计数清零统一放在 wr_last(帧尾)。
                if(accept) wr_active    <= 1'b1;
                else       frm_dropping <= 1'b1;
            end

            if(wr_last) begin
                if(wr_active) begin
                    if(wr_bank == 1'b0) len0 <= wr_cnt; else len1 <= wr_cnt;
                    wr_tog[wr_bank] <= ~wr_tog[wr_bank];
                    wr_active       <= 1'b0;
                    wr_bank         <= ~wr_bank;      // 立即翻 bank, 不等对端排空
                    wr_frame_cnt    <= wr_frame_cnt + 16'd1;
                end
                if(frm_dropping) begin
                    wr_drop_cnt  <= wr_drop_cnt + 16'd1;
                    frm_dropping <= 1'b0;             // 丢弃帧不占 bank, 不翻
                end
                wr_cnt  <= 16'd0;
                wr_addr <= {AW{1'b0}};   // 帧尾清地址, 保证下一帧从 bank 内 0 写起
            end
        end
    end

    //=========================================================================
    // RAM 写: **独立 always 块**(照 prj9 原版模式, 不进 FSM 块)
    //   RAM 推断对代码模式极敏感: 与 FSM 合并会推断失败变 FF 阵列(实测教训)。
    //   块内无复位(单块单驱动原则, 同原版 C17)。
    //=========================================================================
    always @(posedge wr_clk) begin
        if(byte_we)
            ram[{wr_bank, wr_addr}] <= wr_data;   // 只写数据; 指针由 FSM 块唯一驱动
    end

    //=========================================================================
    // 读侧: 按 rd_bank 顺序排空(写侧只写 rd_bank 镜像, 故天然保序)
    //=========================================================================
    always @(posedge rd_clk) begin
        wr_tog_s1 <= wr_tog;
        wr_tog_s2 <= wr_tog_s1;
    end

    always @(posedge rd_clk) begin
        if(rd_en_i) ram_dout <= ram[{rd_bank, rd_addr}];
    end

    always @(posedge rd_clk) begin
        ram_dout_v <= rd_en_i;
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if(!rd_rst_n) begin
            st <= 1'b0; rd_cnt_i <= 16'd0; rd_cnt_o <= 16'd0; rd_len <= 16'd0;
            rd_en_i <= 1'b0; rd_data <= 8'd0; rd_en <= 1'b0; rd_addr <= {AW{1'b0}};
            rd_tog <= 2'b00; rd_bank <= 1'b0; rd_frame_cnt <= 16'd0;
        end
        else if(st == 1'b0) begin
            rd_en <= 1'b0;
            if(wr_tog_s2[rd_bank] != rd_tog[rd_bank]) begin
                rd_len   <= rd_bank ? len1 : len0;
                rd_cnt_i <= 16'd0;
                rd_cnt_o <= 16'd0;
                rd_addr  <= {AW{1'b0}};
                rd_en_i  <= 1'b1;
                st       <= 1'b1;
            end
        end
        else begin
            rd_data <= ram_dout;
            rd_en   <= ram_dout_v;
            if(rd_en) begin
                rd_cnt_o <= rd_cnt_o + 16'd1;
                if(rd_cnt_o == rd_len - 16'd1) begin
                    st              <= 1'b0;
                    rd_en           <= 1'b0;
                    rd_tog[rd_bank] <= ~rd_tog[rd_bank];   // 释放该 bank
                    rd_bank         <= ~rd_bank;
                    rd_frame_cnt    <= rd_frame_cnt + 16'd1;
                end
            end
            if(rd_cnt_i < rd_len - 16'd1) begin
                rd_cnt_i <= rd_cnt_i + 16'd1;
                rd_addr  <= rd_addr + 1'b1;
                rd_en_i  <= 1'b1;
            end
            else begin
                rd_addr <= {AW{1'b0}};
                rd_en_i <= 1'b0;
            end
        end
    end

endmodule
