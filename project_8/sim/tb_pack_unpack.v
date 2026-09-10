//=============================================================================
// tb_pack_unpack.v — axis_word_pack ↔ axis_word_unpack 闭环仿真
//
// 目的：在没有板子的情况下先证明「打包/解包 + 帧边界」这套逻辑是对的。
//   · 模型：pack → 小 FIFO（模拟 Aurora RX 的缓冲）→ 随机 tvalid 空洞 → unpack
//     —— PMA 串行内环在 beat/lane 层面等价于"同一拍原样送还"，
//        而字节序/tkeep 约定对本闭环是**自洽**的（写哪条 lane 就从哪条 lane 读回），
//        故直通模型足以验证帧边界、tlast、帧尾余字、吞吐匹配。
//   · 判据：每帧逐字节比对；**输出出现"帧内断流"即判失败**
//     （断流 = 下游帧泵会把它当成两个帧 → 板上表现为回显帧被切碎）
//
// 运行（ASCII 工作目录）:
//   cd D:\FPGA\project_8
//   xvlog rtl\axis_word_pack.v rtl\axis_word_unpack.v sim\tb_pack_unpack.v
//   xelab -debug typical tb_pack_unpack -s tb_sim
//   xsim tb_sim -runall
//=============================================================================
`timescale 1ns / 1ps

module tb_pack_unpack;

    // ---------------- 时钟 / 复位 ----------------
    reg clk = 1'b0;
    always #3.3 clk = ~clk;              // ~151.5 MHz，与 Aurora user_clk 同量级

    reg rst = 1'b1;

    // ---------------- pack 侧驱动 ----------------
    reg  [7:0] in_data  = 8'd0;
    reg        in_valid = 1'b0;

    wire [63:0] tdata;
    wire [7:0]  tkeep;
    wire        tlast, tvalid, tready;
    wire [15:0] pk_frames;
    wire        pk_ovf;

    // ---------------- 模拟 Aurora RX 的 beat FIFO（深度 16）----------------
    reg [63:0] f_data [0:15];
    reg [7:0]  f_keep [0:15];
    reg        f_last [0:15];
    reg [4:0]  fw = 5'd0, fr = 5'd0;

    wire f_empty = (fw == fr);
    wire f_full  = (fw[4] != fr[4]) && (fw[3:0] == fr[3:0]);
    wire push    = tvalid & tready;
    assign tready = ~f_full;

    always @(posedge clk) begin
        if (push) begin
            f_data[fw[3:0]] <= tdata;
            f_keep[fw[3:0]] <= tkeep;
            f_last[fw[3:0]] <= tlast;
            fw <= fw + 5'd1;
        end
    end

    // 随机 tvalid 空洞（LFSR 伪随机）：模拟真实 Aurora RX 的"tvalid 允许空洞"
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};

    wire rx_pop  = ~f_empty & lfsr[0];
    wire [63:0] s_tdata = f_data[fr[3:0]];
    wire [7:0]  s_tkeep = f_keep[fr[3:0]];
    wire        s_tlast = f_last[fr[3:0]];
    wire        s_tvalid = rx_pop;

    always @(posedge clk) begin
        if (rx_pop) fr <= fr + 5'd1;
    end

    // ---------------- unpack 侧输出 ----------------
    wire [7:0]  out_data;
    wire        out_valid;
    wire [15:0] up_bytes, up_frames, up_stall;
    wire        up_ovf;

    // ---------------- DUT ----------------
    axis_word_pack u_pack (
        .clk         (clk      ),
        .rst         (rst      ),
        .in_data     (in_data  ),
        .in_valid    (in_valid ),
        .m_tdata     (tdata    ),
        .m_tkeep     (tkeep    ),
        .m_tlast     (tlast    ),
        .m_tvalid    (tvalid   ),
        .m_tready    (tready   ),
        .o_frame_cnt (pk_frames),
        .o_overflow  (pk_ovf   )
    );

    axis_word_unpack u_unpack (
        .clk         (clk      ),
        .rst         (rst      ),
        .s_tdata     (s_tdata  ),
        .s_tkeep     (s_tkeep  ),
        .s_tlast     (s_tlast  ),
        .s_tvalid    (s_tvalid ),
        .out_data    (out_data ),
        .out_valid   (out_valid),
        .o_byte_cnt  (up_bytes ),
        .o_frame_cnt (up_frames),
        .o_overflow  (up_ovf   ),
        .o_stall_cnt (up_stall )
    );

    // ---------------- 激励 / 检查 ----------------
    localparam NF = 34;
    integer LEN [0:NF-1];
    initial begin
        // 覆盖 8 种 (帧长%8) 余数 + 边界 + 长帧
        LEN[ 0]=  1; LEN[ 1]=  2; LEN[ 2]=  3; LEN[ 3]=  4;
        LEN[ 4]=  5; LEN[ 5]=  6; LEN[ 6]=  7; LEN[ 7]=  8;
        LEN[ 8]=  9; LEN[ 9]= 15; LEN[10]= 16; LEN[11]= 17;
        LEN[12]= 23; LEN[13]= 24; LEN[14]= 25; LEN[15]= 26;
        LEN[16]= 27; LEN[17]= 28; LEN[18]= 29; LEN[19]= 30;
        LEN[20]= 31; LEN[21]= 32; LEN[22]= 33; LEN[23]= 40;
        LEN[24]= 54; LEN[25]= 55; LEN[26]= 63; LEN[27]= 64;
        LEN[28]= 65; LEN[29]=100; LEN[30]=200; LEN[31]=253;
        LEN[32]=511; LEN[33]=1000;
    end

    function [7:0] exp_byte(input integer k, input integer j);
        exp_byte = ((k*7 + j) & 255);
    endfunction

    integer sent = 0, got = 0, bad = 0;
    integer rx_cnt = 0, rx_idx = 0;
    reg     in_frame = 1'b0;
    reg [7:0] rx_buf [0:2047];
    integer i, firstbad;

    initial begin
        rst = 1'b1;
        repeat (8) @(negedge clk);
        rst = 1'b0;
        repeat (8) @(negedge clk);

        for (sent = 0; sent < NF; sent = sent + 1) begin
            for (i = 0; i < LEN[sent]; i = i + 1) begin
                @(negedge clk);
                in_data  = exp_byte(sent, i);
                in_valid = 1'b1;
            end
            @(negedge clk);
            in_valid = 1'b0;
            in_data  = 8'd0;
            // 帧间空拍：模拟帧泵握手（真实系统 ≥8 拍）
            repeat (14) @(negedge clk);
        end
        // 等最后一帧吐完（整帧存储转发 → 长帧需要等整帧收全再吐，故给足时间）
        i = 0;
        while ((got < NF) && (i < 40000)) begin
            @(negedge clk);
            i = i + 1;
        end
        repeat (40) @(negedge clk);

        $display("");
        $display("=================================================");
        $display("  发出帧数 = %0d   收回帧数 = %0d   失败 = %0d", sent, got, bad);
        $display("  pack: frames=%0d ovf=%b   unpack: frames=%0d bytes=%0d ovf=%b stall=%0d",
                 pk_frames, pk_ovf, up_frames, up_bytes, up_ovf, up_stall);
        if (got == NF && bad == 0 && pk_ovf === 1'b0 && up_ovf === 1'b0)
            $display("  >>> PASS: 全部帧逐字节一致、无断流、无溢出");
        else
            $display("  >>> FAIL");
        $display("=================================================");
        $finish;
    end

    // 输出侧收帧 + 逐字节比对（帧边界 = out_valid 出现空拍，与帧泵判据一致）
    integer j;
    always @(posedge clk) begin
        if (out_valid) begin
            rx_buf[rx_cnt] = out_data;
            rx_cnt = rx_cnt + 1;
            in_frame = 1'b1;
        end
        else if (in_frame) begin
            in_frame = 1'b0;
            // 调试：打印本段收到的前 8 个字节
            $write("  [BURST #%0d] len=%0d  data=", rx_idx, rx_cnt);
            for (j = 0; j < ((rx_cnt < 8) ? rx_cnt : 8); j = j + 1)
                $write("%02h ", rx_buf[j]);
            $display("");
            if (rx_idx < NF) begin
                if (rx_cnt != LEN[rx_idx]) begin
                    bad = bad + 1;
                    $display("  [FAIL] 帧#%0d 期望 %0d 字节，收到 %0d 字节（帧被切断或长度错）",
                             rx_idx, LEN[rx_idx], rx_cnt);
                end
                else begin
                    firstbad = -1;
                    for (j = 0; j < rx_cnt; j = j + 1)
                        if (firstbad < 0 && rx_buf[j] !== exp_byte(rx_idx, j)) firstbad = j;
                    if (firstbad >= 0) begin
                        bad = bad + 1;
                        $display("  [FAIL] 帧#%0d 长度对但内容错：首差 @%0d 期望 %02h 实收 %02h",
                                 rx_idx, firstbad, exp_byte(rx_idx, firstbad), rx_buf[firstbad]);
                    end
                end
            end
            else begin
                bad = bad + 1;
                $display("  [FAIL] 多收到一帧（%0d 字节）", rx_cnt);
            end
            rx_cnt = 0;
            rx_idx = rx_idx + 1;
            got = got + 1;
        end
    end

    // 看门狗
    initial begin
        #2000000;
        $display("  [FAIL] 仿真超时（2 ms）");
        $finish;
    end

endmodule
