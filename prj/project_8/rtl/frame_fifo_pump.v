//=============================================================================
// frame_fifo_pump.v — frame-aware CDC pump (self-contained, no IP)
// Purpose : cross a GMII frame stream from clock domain A (RGMII PHY eth_rxc)
//           to domain B (PCS/PMA userclk2) with FRAME integrity: buffer one
//           full frame, then drain it gaplessly into the PCS TX.
// Policy  : handshake-gated — frames arriving while the previous frame is in
//           flight are DROPPED (wr_drop_cnt). Human-paced UDP/ARP/ping traffic
//           has huge gaps; stress mode is future work.
// CDC     : Cummings-style async FIFO — gray pointers, 2FF sync both ways.
//=============================================================================
module frame_fifo_pump(
    // write side = source frame stream (domain A)
    input               wr_clk      ,
    input               wr_rst_n    ,
    input       [7:0]   wr_data     ,   // GMII byte stream (preamble..CRC)
    input               wr_en       ,   // frame data valid
    // read side = PCS/PMA GMII TX (domain B)
    input               rd_clk      ,
    input               rd_rst_n    ,
    output  reg [7:0]   rd_data     ,   // byte out (aligned with rd_en)
    output  reg         rd_en       ,   // frame valid out
    // status (for ILA / debug)
    output  reg [15:0]  wr_frame_cnt,
    output  reg [15:0]  wr_drop_cnt ,
    output  reg [15:0]  rd_frame_cnt
);

//=============================================================================
// declarations (all up front — no use-before-declare)
//=============================================================================
localparam AW = 11;
localparam S_IDLE = 1'b0, S_PUMP = 1'b1;

reg [7:0]  ram [0:(1<<AW)-1];

reg  [AW:0] wr_bin;                     // write pointer (binary, domain A)
reg  [AW:0] rd_bin;                     // read pointer (binary, domain B)
reg  [AW:0] wr_ptr_g, rd_ptr_g;         // gray pointers
reg  [AW:0] rd_ptr_g_s1, rd_ptr_g_s2;   // rd gray synced into wr domain
reg  [AW:0] wr_ptr_g_s1, wr_ptr_g_s2;   // wr gray synced into rd domain

reg             hs_busy;                // frame in flight (handshake pending)
reg             wr_dv_d;                // wr_en delayed (frame-end detect)
reg [15:0]      wr_cnt;                 // bytes written in current frame
reg [15:0]      frame_len_mb;           // mailbox: latched frame length
reg             wr_done_t;              // toggle: frame available (crossing)
reg             rd_done_t;              // toggle: frame consumed (crossing)
reg             rd_done_t_s1, rd_done_t_s2; // rd_done sync into wr domain
reg             rd_done_t_ack;            // last acked toggle state (wr domain)
reg             wr_done_t_s1, wr_done_t_s2; // wr_done sync into rd domain

wire            wr_valid;               // write strobe (data + pointer advance)
wire [AW:0]     wr_bin_next;
wire            wr_full;
wire            wr_en_fall;             // frame end detect (write domain)

reg  [15:0]     rd_cnt_i;               // reads issued
reg  [15:0]     rd_cnt_o;               // bytes presented on output
reg  [15:0]     rd_len;                 // latched frame length
reg             rd_en_i;                // FIFO read strobe
reg             st;                     // pump FSM state
reg             ram_dout_v;             // ram_dout valid flag
reg  [7:0]      ram_dout;

wire [AW:0]     rd_bin_next;
wire            rd_empty;

function [AW:0] bin2gray(input [AW:0] b);
    bin2gray = (b >> 1) ^ b;
endfunction

//=============================================================================
// write side: pointers (advance ONLY on actual writes) + frame gather
//=============================================================================
assign wr_bin_next = wr_bin + 1'b1;
assign wr_full = (wr_bin_next[AW] != rd_ptr_g_s2[AW]) &&
                 (wr_bin_next[AW-1] != rd_ptr_g_s2[AW-1]);
assign wr_valid = wr_en && !wr_full;
assign wr_en_fall = ~wr_en & wr_dv_d;

always @(posedge wr_clk or negedge wr_rst_n) begin
    if(!wr_rst_n) begin
        wr_bin <= 0; wr_ptr_g <= 0;
        rd_ptr_g_s1 <= 0; rd_ptr_g_s2 <= 0;
    end
    else begin
        rd_ptr_g_s1 <= rd_ptr_g;
        rd_ptr_g_s2 <= rd_ptr_g_s1;
        if(wr_valid) begin
            wr_bin   <= wr_bin_next;
            wr_ptr_g <= bin2gray(wr_bin_next);
        end
    end
end

always @(posedge wr_clk) begin
    if(wr_valid)
        ram[wr_bin[AW-1:0]] <= wr_data;
end

// frame gather + 4-phase handshake（含释放逻辑，单块单驱动——C18 根治）
always @(posedge wr_clk or negedge wr_rst_n) begin
    if(!wr_rst_n) begin
        hs_busy <= 1'b0; wr_dv_d <= 1'b0; wr_cnt <= 16'd0;
        frame_len_mb <= 16'd0; wr_done_t <= 1'b0;
        wr_frame_cnt <= 16'd0; wr_drop_cnt <= 16'd0;
        rd_done_t_s1 <= 1'b0; rd_done_t_s2 <= 1'b0; rd_done_t_ack <= 1'b0;
    end
    else begin
        wr_dv_d <= wr_en;
        rd_done_t_s1  <= rd_done_t;
        rd_done_t_s2  <= rd_done_t_s1;
        rd_done_t_ack <= rd_done_t_s2;
        // C20 修复(2026-09-10): wr_cnt 必须在两个分支都累加。
        // 原实现只在 !hs_busy 分支累加，而 hs_busy 拉高的同一拍已把 wr_cnt 清零，
        // 于是 busy 期间 wr_en_fall 时 wr_cnt 恒为 0 → 丢帧分支永不成立 →
        // wr_drop_cnt 成了死计数器("drop=0" 不能证明没丢帧)。
        if(wr_valid)
            wr_cnt <= wr_cnt + 16'd1;
        if(!hs_busy) begin
            if(wr_en_fall && wr_cnt != 16'd0) begin
                frame_len_mb <= wr_cnt;
                wr_done_t    <= ~wr_done_t;     // frame available -> toggle
                hs_busy      <= 1'b1;
                wr_frame_cnt <= wr_frame_cnt + 16'd1;
            end
            if(wr_en_fall)
                wr_cnt <= 16'd0;
        end
        else begin
            // handshake pending: incoming frames dropped (counted)
            if(wr_en_fall && wr_cnt != 16'd0) begin
                wr_drop_cnt <= wr_drop_cnt + 16'd1;
                wr_cnt <= 16'd0;
            end
            if(rd_done_t_s2 != rd_done_t_ack)
                hs_busy <= 1'b0;                // frame fully drained -> release
        end
    end
end

//=============================================================================
// read side: pointers (advance ONLY on actual reads) + pump FSM
//=============================================================================
assign rd_bin_next = rd_bin + 1'b1;
// C21 修复(2026-09-17): rd_empty 必须用当前 rd_bin，不能用 rd_bin_next。
//   原式 (bin2gray(rd_bin_next)==wr_ptr_g_s2) 是"提前一拍判空"：当读指针追到
//   与写指针持平（rd_bin=末字节地址）时，rd_bin_next 已等于 wr_ptr，于是把
//   **每帧最后一字节**误判为空而拒读（板上实测：第二帧恒少 1 字节、rd_frame_cnt
//   停在 1、FSM 永久卡死）。本泵是"整帧先写满再读"，读期间写指针稳定，
//   用 rd_bin 判空安全：rd_bin 追上 wr_ptr 才为空，末字节允许读出。
assign rd_empty = (bin2gray(rd_bin) == wr_ptr_g_s2);

always @(posedge rd_clk or negedge rd_rst_n) begin
    if(!rd_rst_n) begin
        rd_bin <= 0; rd_ptr_g <= 0;
        wr_ptr_g_s1 <= 0; wr_ptr_g_s2 <= 0;
    end
    else begin
        wr_ptr_g_s1 <= wr_ptr_g;
        wr_ptr_g_s2 <= wr_ptr_g_s1;
        if(rd_en_i && !rd_empty) begin
            rd_bin   <= rd_bin_next;
            rd_ptr_g <= bin2gray(rd_bin_next);
        end
    end
end

// FIFO read data capture (registered, 1-cycle latency, strobed)
always @(posedge rd_clk) begin
    if(rd_en_i && !rd_empty)
        ram_dout <= ram[rd_bin[AW-1:0]];
end

always @(posedge rd_clk) begin
    ram_dout_v <= rd_en_i && !rd_empty;
end

// pump FSM: issue exactly rd_len reads, present exactly rd_len gapless bytes
always @(posedge rd_clk or negedge rd_rst_n) begin
    if(!rd_rst_n) begin
        st <= S_IDLE; rd_cnt_i <= 16'd0; rd_cnt_o <= 16'd0; rd_len <= 16'd0;
        rd_en_i <= 1'b0;
        rd_data <= 8'd0; rd_en <= 1'b0;
        rd_frame_cnt <= 16'd0; rd_done_t <= 1'b0;
        wr_done_t_s1 <= 1'b0; wr_done_t_s2 <= 1'b0;
        // NOTE: ram_dout/ram_dout_v 故意不在本块复位——由上方无复位捕获块唯一驱动
        // （在此赋值 = 双时钟风格多驱动 → MDRV/GND 折叠，坑位 C17）
    end
    else begin
        wr_done_t_s1 <= wr_done_t;
        wr_done_t_s2 <= wr_done_t_s1;

        case(st)
            S_IDLE: begin
                rd_en <= 1'b0;
                if(wr_done_t_s1 != wr_done_t_s2) begin   // new frame available
                    rd_len   <= frame_len_mb;            // mailbox stable (4-phase)
                    rd_cnt_i <= 16'd0;
                    rd_cnt_o <= 16'd0;
                    rd_en_i  <= 1'b1;                    // prime first read
                    st       <= S_PUMP;
                end
            end
            S_PUMP: begin
                // output pipeline: (ram_dout, ram_dout_v) -> (rd_data, rd_en)
                rd_data <= ram_dout;
                rd_en   <= ram_dout_v;
                if(rd_en) begin                          // byte presented this cycle
                    rd_cnt_o <= rd_cnt_o + 16'd1;
                    if(rd_cnt_o == rd_len - 16'd1) begin // last byte out now
                        st           <= S_IDLE;
                        rd_en        <= 1'b0;            // stop after this cycle
                        rd_frame_cnt <= rd_frame_cnt + 16'd1;
                        rd_done_t    <= ~rd_done_t;      // ack -> release wr side
                    end
                end
                // read issuing: exactly rd_len strobes
                if(rd_cnt_i < rd_len - 16'd1)
                    rd_en_i <= 1'b1;
                else
                    rd_en_i <= 1'b0;
                if(rd_en_i)
                    rd_cnt_i <= rd_cnt_i + 16'd1;
            end
        endcase
    end
end

endmodule
