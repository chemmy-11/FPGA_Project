//=============================================================================
// tb_full_chain.v — project_8 整链闭环仿真
//
// 目的：在不上板的情况下，证明（或证伪）「栈 TX → 帧泵A → 打包 → Aurora → 解包
//       → 帧泵B → RGMII TX」这条绕行对**官方栈真实产生的回复帧**逐字节保真。
//
// 结构：
//   激励(gmii_rx) -> [arp+icmp+udp+eth_ctrl+async_fifo 官方栈] -> stack_tx
//       -> frame_fifo_pump A (eth_rxc -> user_clk)
//       -> axis_word_pack  -> [Aurora AXIS 模型: tready反压 + rx_tvalid空洞]
//       -> axis_word_unpack -> frame_fifo_pump B (user_clk -> eth_rxc)
//       -> 输出比对（stack_tx 帧 == 绕行后帧，逐字节）
//
// 同时监测：
//   (1) stack_tx_en 帧内是否有空拍（有 => 帧泵会把它切成两帧 => 必坏）
//   (2) 帧泵丢帧计数 / 打包溢出 / 解包溢出 / 解包 stall
//
// 运行（ASCII 路径，工作目录 D:\FPGA\project_8）：
//   xvlog rtl\arp\*.v rtl\icmp\*.v rtl\udp\*.v rtl\eth_ctrl.v ^
//         rtl\frame_fifo_pump.v rtl\axis_word_pack.v rtl\axis_word_unpack.v ^
//         sim\async_fifo_model.v sim\tb_full_chain.v
//   xelab -debug typical tb_full_chain -s tb_fc
//   xsim tb_fc -runall
//=============================================================================
`timescale 1ns/1ps

module tb_full_chain;

    // ---- 参数 ----
    localparam BOARD_MAC = 48'h00_11_22_33_44_55;
    localparam BOARD_IP  = {8'd192,8'd168,8'd1,8'd10};
    localparam PC_MAC    = 48'h08_3c_03_a0_26_96;
    localparam PC_IP     = {8'd192,8'd168,8'd1,8'd102};

    // ---- 时钟 ----
    reg eth_clk  = 1'b0;  always #4.0 eth_clk  = ~eth_clk;   // 125 MHz
    reg user_clk = 1'b0;  always #3.3 user_clk = ~user_clk;  // ~151.5 MHz

    // ---- 复位 / 链路 ----
    reg sys_rst_n  = 1'b0;
    reg channel_up = 1'b0;
    wire aurora_rst = ~sys_rst_n | ~channel_up;

    // ---- 激励（注入到栈的 GMII RX）----
    reg        rx_dv  = 1'b0;
    reg  [7:0] rx_d   = 8'd0;

    // ---- 栈连线（与 aurora_udp_bridge.v 一致）----
    wire gmii_rx_clk = eth_clk, gmii_tx_clk = eth_clk;
    wire [7:0]  stack_txd;  wire stack_tx_en;
    wire arp_gmii_tx_en;  wire [7:0] arp_gmii_txd;
    wire arp_rx_done, arp_rx_type;  wire [47:0] src_mac; wire [31:0] src_ip;
    wire arp_tx_en, arp_tx_type;    wire [47:0] des_mac; wire [31:0] des_ip; wire arp_tx_done;
    wire icmp_gmii_tx_en; wire [7:0] icmp_gmii_txd;
    wire icmp_rec_pkt_done, icmp_rec_en; wire [7:0] icmp_rec_data;
    wire [15:0] icmp_rec_byte_num, icmp_tx_byte_num;
    wire icmp_tx_done, icmp_tx_req; wire [7:0] icmp_tx_data; wire icmp_tx_start_en;
    wire udp_gmii_tx_en; wire [7:0] udp_gmii_txd;
    wire rec_pkt_done, udp_rec_en; wire [7:0] udp_rec_data;
    wire [15:0] rec_byte_num, tx_byte_num; wire [15:0] udp_src_port;
    wire udp_tx_done, udp_tx_req; wire [7:0] udp_tx_data; wire tx_start_en;
    wire [7:0] rec_data, tx_data; wire rec_en, tx_req;
    wire key = 1'b1;  // 不触发 ARP 请求

    assign icmp_tx_start_en = icmp_rec_pkt_done;
    assign icmp_tx_byte_num = icmp_rec_byte_num;
    assign tx_start_en = rec_pkt_done;
    assign tx_byte_num = rec_byte_num;
    assign des_mac = src_mac;
    assign des_ip  = src_ip;

    // ---- 官方栈实例 ----
    arp #(.BOARD_MAC(BOARD_MAC),.BOARD_IP(BOARD_IP),.DES_MAC(48'hff_ff_ff_ff_ff_ff),.DES_IP(PC_IP))
    u_arp(.rst_n(sys_rst_n),.gmii_rx_clk(gmii_rx_clk),.gmii_rx_dv(rx_dv),.gmii_rxd(rx_d),
        .gmii_tx_clk(gmii_tx_clk),.gmii_tx_en(arp_gmii_tx_en),.gmii_txd(arp_gmii_txd),
        .arp_rx_done(arp_rx_done),.arp_rx_type(arp_rx_type),.src_mac(src_mac),.src_ip(src_ip),
        .arp_tx_en(arp_tx_en),.arp_tx_type(arp_tx_type),.des_mac(des_mac),.des_ip(des_ip),.tx_done(arp_tx_done));

    icmp #(.BOARD_MAC(BOARD_MAC),.BOARD_IP(BOARD_IP),.DES_MAC(48'hff_ff_ff_ff_ff_ff),.DES_IP(PC_IP))
    u_icmp(.rst_n(sys_rst_n),.gmii_rx_clk(gmii_rx_clk),.gmii_rx_dv(rx_dv),.gmii_rxd(rx_d),
        .gmii_tx_clk(gmii_tx_clk),.gmii_tx_en(icmp_gmii_tx_en),.gmii_txd(icmp_gmii_txd),
        .rec_pkt_done(icmp_rec_pkt_done),.rec_en(icmp_rec_en),.rec_data(icmp_rec_data),
        .rec_byte_num(icmp_rec_byte_num),.tx_start_en(icmp_tx_start_en),.tx_data(icmp_tx_data),
        .tx_byte_num(icmp_tx_byte_num),.des_mac(des_mac),.des_ip(des_ip),.tx_done(icmp_tx_done),.tx_req(icmp_tx_req));

    udp #(.BOARD_MAC(BOARD_MAC),.BOARD_IP(BOARD_IP),.DES_MAC(48'hff_ff_ff_ff_ff_ff),.DES_IP(PC_IP))
    u_udp(.rst_n(sys_rst_n),.gmii_rx_clk(gmii_rx_clk),.gmii_rx_dv(rx_dv),.gmii_rxd(rx_d),
        .gmii_tx_clk(gmii_tx_clk),.gmii_tx_en(udp_gmii_tx_en),.gmii_txd(udp_gmii_txd),
        .rec_pkt_done(rec_pkt_done),.rec_en(udp_rec_en),.rec_data(udp_rec_data),
        .rec_byte_num(rec_byte_num),.rec_src_port(udp_src_port),.des_port(udp_src_port),
        .tx_start_en(tx_start_en),.tx_data(udp_tx_data),.tx_byte_num(tx_byte_num),
        .des_mac(des_mac),.des_ip(des_ip),.tx_done(udp_tx_done),.tx_req(udp_tx_req));

    async_fifo_2048x8b u_fifo(.rst(~sys_rst_n),.wr_clk(gmii_rx_clk),.rd_clk(gmii_rx_clk),
        .din(rec_data),.wr_en(rec_en),.rd_en(tx_req),.dout(tx_data),.full(),.empty());

    eth_ctrl u_eth_ctrl(.clk(gmii_rx_clk),.rst_n(sys_rst_n),.key(key),
        .arp_rx_done(arp_rx_done),.arp_rx_type(arp_rx_type),.arp_tx_en(arp_tx_en),
        .arp_tx_type(arp_tx_type),.arp_tx_done(arp_tx_done),.arp_gmii_tx_en(arp_gmii_tx_en),.arp_gmii_txd(arp_gmii_txd),
        .icmp_tx_start_en(icmp_tx_start_en),.icmp_tx_done(icmp_tx_done),
        .icmp_gmii_tx_en(icmp_gmii_tx_en),.icmp_gmii_txd(icmp_gmii_txd),
        .icmp_rec_en(icmp_rec_en),.icmp_rec_data(icmp_rec_data),.icmp_tx_req(icmp_tx_req),.icmp_tx_data(icmp_tx_data),
        .udp_tx_start_en(tx_start_en),.udp_tx_done(udp_tx_done),
        .udp_gmii_tx_en(udp_gmii_tx_en),.udp_gmii_txd(udp_gmii_txd),
        .udp_rec_data(udp_rec_data),.udp_rec_en(udp_rec_en),.udp_tx_req(udp_tx_req),.udp_tx_data(udp_tx_data),
        .rec_data(rec_data),.rec_en(rec_en),.tx_req(tx_req),.tx_data(tx_data),
        .gmii_tx_en(stack_tx_en),.gmii_txd(stack_txd));

    // ---- 绕行链 ----
    wire [7:0] pump_fwd_data; wire pump_fwd_en;
    wire [15:0] pfwd_wr, pfwd_drop, pfwd_rd;
    frame_fifo_pump u_pump_fwd(.wr_clk(gmii_rx_clk),.wr_rst_n(sys_rst_n),
        .wr_data(stack_txd),.wr_en(stack_tx_en),
        .rd_clk(user_clk),.rd_rst_n(~aurora_rst),.rd_data(pump_fwd_data),.rd_en(pump_fwd_en),
        .wr_frame_cnt(pfwd_wr),.wr_drop_cnt(pfwd_drop),.rd_frame_cnt(pfwd_rd));

    wire [63:0] tx_tdata; wire [7:0] tx_tkeep; wire tx_tlast, tx_tvalid, tx_tready;
    wire [15:0] pk_frames; wire pk_ovf;
    axis_word_pack u_pack(.clk(user_clk),.rst(aurora_rst),.in_data(pump_fwd_data),.in_valid(pump_fwd_en),
        .m_tdata(tx_tdata),.m_tkeep(tx_tkeep),.m_tlast(tx_tlast),.m_tvalid(tx_tvalid),.m_tready(tx_tready),
        .o_frame_cnt(pk_frames),.o_overflow(pk_ovf));

    // ---- Aurora AXIS 模型：beat FIFO（绝不丢 beat）+ 随机反压 + 随机 rx_tvalid 空洞 ----
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge user_clk) lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    reg [63:0] af_data [0:15]; reg [7:0] af_keep [0:15]; reg af_last [0:15];
    reg [4:0]  af_w = 5'd0, af_r = 5'd0;
    wire af_empty = (af_w == af_r);
    wire af_full  = (af_w[4] != af_r[4]) && (af_w[3:0] == af_r[3:0]);
    assign tx_tready = ~af_full & (lfsr[1] | lfsr[2]);     // 反压 + 满则停
    wire af_push = tx_tvalid & tx_tready;
    always @(posedge user_clk) begin
        if (af_push) begin
            af_data[af_w[3:0]] <= tx_tdata; af_keep[af_w[3:0]] <= tx_tkeep;
            af_last[af_w[3:0]] <= tx_tlast; af_w <= af_w + 5'd1;
        end
    end
    wire rx_pop = ~af_empty & lfsr[0];                     // 随机空洞（不丢数据）
    wire [63:0] rx_tdata = af_data[af_r[3:0]];
    wire [7:0]  rx_tkeep = af_keep[af_r[3:0]];
    wire        rx_tlast = af_last[af_r[3:0]];
    wire        rx_tvalid = rx_pop;
    always @(posedge user_clk) if (rx_pop) af_r <= af_r + 5'd1;

    wire [7:0] unpack_data; wire unpack_en;
    wire [15:0] up_bytes, up_frames, up_stall; wire up_ovf;
    axis_word_unpack u_unpack(.clk(user_clk),.rst(aurora_rst),
        .s_tdata(rx_tdata),.s_tkeep(rx_tkeep),.s_tlast(rx_tlast),.s_tvalid(rx_tvalid),
        .out_data(unpack_data),.out_valid(unpack_en),
        .o_byte_cnt(up_bytes),.o_frame_cnt(up_frames),.o_overflow(up_ovf),.o_stall_cnt(up_stall));

    wire [7:0] pump_rev_data; wire pump_rev_en;
    wire [15:0] prev_wr, prev_drop, prev_rd;
    frame_fifo_pump u_pump_rev(.wr_clk(user_clk),.wr_rst_n(~aurora_rst),
        .wr_data(unpack_data),.wr_en(unpack_en),
        .rd_clk(gmii_rx_clk),.rd_rst_n(sys_rst_n),.rd_data(pump_rev_data),.rd_en(pump_rev_en),
        .wr_frame_cnt(prev_wr),.wr_drop_cnt(prev_drop),.rd_frame_cnt(prev_rd));

    // =====================================================================
    // 激励：帧拼装 + 发送（eth_rxc 域）
    // =====================================================================
    reg [7:0] frame [0:2047];
    integer   flen;
    integer   fi;

    task build_eth_udp(input [47:0] dm, input [47:0] sm, input [31:0] dip, input [31:0] sip,
                       input [15:0] sport, input [15:0] dport, input integer plen);
        integer i; integer tot;
        begin
            for(i=0;i<7;i=i+1) frame[i]=8'h55; frame[7]=8'hd5;
            for(i=0;i<6;i=i+1) frame[8+i]  = dm[47-8*i -: 8];
            for(i=0;i<6;i=i+1) frame[14+i] = sm[47-8*i -: 8];
            frame[20]=8'h08; frame[21]=8'h00;                 // EtherType IPv4
            frame[22]=8'h45; frame[23]=8'h00;                 // ver/ihl, tos
            tot = 20+8+plen;
            frame[24]=tot[15:8]; frame[25]=tot[7:0];          // ip tot len
            frame[26]=8'h00; frame[27]=8'h00;                 // id
            frame[28]=8'h00; frame[29]=8'h00;                 // flags/frag
            frame[30]=8'h40; frame[31]=8'h11;                 // ttl, proto=17(UDP=0x11)
            frame[32]=8'h00; frame[33]=8'h00;                 // ip checksum(不校验)
            for(i=0;i<4;i=i+1) frame[34+i]=sip[31-8*i -: 8];
            for(i=0;i<4;i=i+1) frame[38+i]=dip[31-8*i -: 8];
            frame[42]=sport[15:8]; frame[43]=sport[7:0];
            frame[44]=dport[15:8]; frame[45]=dport[7:0];
            frame[46]=(8+plen)>>8; frame[47]=(8+plen)&8'hff;  // udp len
            frame[48]=8'h00; frame[49]=8'h00;                 // udp checksum
            for(i=0;i<plen;i=i+1) frame[50+i]=8'h41+i;        // payload 'A'+i
            for(i=0;i<4;i=i+1) frame[50+plen+i]=8'h00;        // FCS 占位(不校验)
            flen = 50+plen+4;
        end
    endtask

    task build_arp_req(input [47:0] sm, input [31:0] sip, input [31:0] tip);
        integer i;
        begin
            for(i=0;i<7;i=i+1) frame[i]=8'h55; frame[7]=8'hd5;
            for(i=0;i<6;i=i+1) frame[8+i]=8'hff;              // 广播
            for(i=0;i<6;i=i+1) frame[14+i]=sm[47-8*i -: 8];
            frame[20]=8'h08; frame[21]=8'h06;                 // ARP
            frame[22]=8'h00; frame[23]=8'h01;                 // htype
            frame[24]=8'h08; frame[25]=8'h00;                 // ptype
            frame[26]=8'h06; frame[27]=8'h04;                 // hlen/plen
            frame[28]=8'h00; frame[29]=8'h01;                 // opcode=request
            for(i=0;i<6;i=i+1) frame[30+i]=sm[47-8*i -: 8];   // sender mac
            for(i=0;i<4;i=i+1) frame[36+i]=sip[31-8*i -: 8];  // sender ip
            for(i=0;i<6;i=i+1) frame[40+i]=8'h00;             // target mac
            for(i=0;i<4;i=i+1) frame[46+i]=tip[31-8*i -: 8];  // target ip
            for(i=50;i<72;i=i+1) frame[i]=8'h00;              // 补齐到 64 字节 + FCS
            flen = 72;
        end
    endtask

    task send_frame;
        begin
            for(fi=0; fi<flen; fi=fi+1) begin
                @(posedge eth_clk); rx_dv <= 1'b1; rx_d <= frame[fi];
            end
            @(posedge eth_clk); rx_dv <= 1'b0; rx_d <= 8'd0;
        end
    endtask

    // =====================================================================
    // 采集：stack_tx（绕行输入）与 pump_rev（绕行输出），分帧存储
    // =====================================================================
    reg [7:0] in_frames  [0:7][0:2047];
    integer   in_len [0:7];
    integer   in_cnt = 0;
    reg [7:0] out_frames [0:7][0:2047];
    integer   out_len [0:7];
    integer   out_cnt = 0;

    // 帧内空拍监测（stack_tx_en）
    reg stack_tx_en_d = 1'b0;
    reg pump_rev_en_d = 1'b0;
    integer mid_gap_cnt = 0;
    reg     in_frame_flag = 1'b0;
    // 帧内空拍：en 拉低后，在同一"帧"内（距上次 en <=4 拍）又重新拉高 => 帧被切
    integer gap_run = 0;

    always @(posedge eth_clk) begin
        stack_tx_en_d <= stack_tx_en;
        pump_rev_en_d <= pump_rev_en;
        // 帧内空拍统计：stack_tx_en 低但 4 拍内又高的"假帧尾"
        if (!stack_tx_en && in_frame_flag) gap_run <= gap_run + 1;
        else gap_run <= 0;
        if (stack_tx_en && gap_run >= 1 && gap_run <= 4 && in_frame_flag) begin
            mid_gap_cnt = mid_gap_cnt + 1;
            $display("[%0t] !! MID-FRAME GAP in stack_tx_en, gap=%0d cycles", $time, gap_run);
        end
        // 帧完成实时打印
        if (stack_tx_en_d && !stack_tx_en)
            $display("[%0t] >> IN frame %0d done, len=%0d (first bytes %02x %02x %02x)", $time, in_cnt, in_len[in_cnt], in_frames[in_cnt][0], in_frames[in_cnt][1], in_frames[in_cnt][2]);
        if (pump_rev_en_d && !pump_rev_en)
            $display("[%0t] << OUT frame %0d done, len=%0d (first bytes %02x %02x %02x)", $time, out_cnt, out_len[out_cnt], out_frames[out_cnt][0], out_frames[out_cnt][1], out_frames[out_cnt][2]);
        if (rec_pkt_done)   $display("[%0t] UDP rec_pkt_done byte_num=%0d src_port=%0d", $time, rec_byte_num, udp_src_port);
        if (arp_rx_done)    $display("[%0t] ARP rx_done type=%0d", $time, arp_rx_type);
        if (u_udp.u_udp_rx.error_en) $display("[%0t] !! udp_rx ERROR state=%b cnt=%0d", $time, u_udp.u_udp_rx.cur_state, u_udp.u_udp_rx.cnt);
    end

    always @(posedge eth_clk) begin
        if (stack_tx_en) begin
            in_frames[in_cnt][in_len[in_cnt]] = stack_txd;
            in_len[in_cnt] = in_len[in_cnt] + 1;
            in_frame_flag <= 1'b1;
        end
        else begin
            if (in_frame_flag) begin
                in_cnt = in_cnt + 1;
                in_frame_flag <= 1'b0;
            end
        end
    end

    always @(posedge eth_clk) begin
        if (pump_rev_en) begin
            out_frames[out_cnt][out_len[out_cnt]] = pump_rev_data;
            out_len[out_cnt] = out_len[out_cnt] + 1;
        end
        else if (out_len[out_cnt] != 0 && out_cnt < 8) begin
            out_cnt = out_cnt + 1;
        end
    end

    integer ii;
    initial begin
        for(ii=0;ii<8;ii=ii+1) begin in_len[ii]=0; out_len[ii]=0; end
    end

    // ---- 分级定位：每级每帧字节计数 ----
    integer fwd_cnt=0, upk_cnt=0, rev_cnt=0;
    always @(posedge user_clk) begin
        if (pump_fwd_en) fwd_cnt = fwd_cnt + 1;
        if (unpack_en)   upk_cnt = upk_cnt + 1;
    end
    always @(posedge eth_clk) if (pump_rev_en) rev_cnt = rev_cnt + 1;
    // 泵内部关键寄存器
    always @(posedge user_clk) begin
        if (u_pump_fwd.st==1'b0 && (u_pump_fwd.wr_done_t_s1 != u_pump_fwd.wr_done_t_s2))
            $display("[%0t] pumpA START  frame_len_mb=%0d", $time, u_pump_fwd.frame_len_mb);
        if (u_pump_rev.st==1'b0 && (u_pump_rev.wr_done_t_s1 != u_pump_rev.wr_done_t_s2))
            $display("[%0t] pumpB START  frame_len_mb=%0d", $time, u_pump_rev.frame_len_mb);
    end

    // 逐拍追踪 pumpA 读 FSM（S_PUMP 期间）
    always @(posedge user_clk) begin
        if (u_pump_fwd.st==1'b1)
            $display("[%0t] pumpA ci=%0d co=%0d len=%0d eni=%b empty=%b doutv=%b rden=%b rdbin=%0d wptrg=%0d",
                $time, u_pump_fwd.rd_cnt_i, u_pump_fwd.rd_cnt_o, u_pump_fwd.rd_len,
                u_pump_fwd.rd_en_i, u_pump_fwd.rd_empty, u_pump_fwd.ram_dout_v, u_pump_fwd.rd_en,
                u_pump_fwd.rd_bin, u_pump_fwd.wr_ptr_g_s2);
    end

    // =====================================================================
    // 主流程
    // =====================================================================
    integer e; integer ok_frames; integer bad;
    initial begin
        sys_rst_n=0; channel_up=0;
        #200; sys_rst_n=1;
        #100; channel_up=1;
        #500;

        $display("[%0t] === TEST 1: ARP request -> ARP reply through detour ===", $time);
        build_arp_req(PC_MAC, PC_IP, BOARD_IP);
        send_frame();
        #8000;

        $display("[%0t] === TEST 2: UDP frame (16B payload) -> echo through detour ===", $time);
        build_eth_udp(BOARD_MAC, PC_MAC, BOARD_IP, PC_IP, 16'd5000, 16'd1234, 16);
        send_frame();
        #12000;

        $display("[%0t] === TEST 3: UDP frame (29B payload, 非8倍数) ===", $time);
        build_eth_udp(BOARD_MAC, PC_MAC, BOARD_IP, PC_IP, 16'd5001, 16'd1234, 29);
        send_frame();
        #12000;

        $display("[%0t] === TEST 4: UDP frame (200B payload) ===", $time);
        build_eth_udp(BOARD_MAC, PC_MAC, BOARD_IP, PC_IP, 16'd5002, 16'd1234, 200);
        send_frame();
        #25000;

        // ---- 汇总 ----
        #8000;
        $display("in0[20:21]=%02x%02x in1[20:21]=%02x%02x", in_frames[0][20],in_frames[0][21], in_frames[1][20],in_frames[1][21]);
        $display("frame1 IN  bytes 64..71: %02x %02x %02x %02x %02x %02x %02x %02x",
          in_frames[1][64],in_frames[1][65],in_frames[1][66],in_frames[1][67],in_frames[1][68],in_frames[1][69],in_frames[1][70],in_frames[1][71]);
        $display("frame1 OUT bytes 62..69: %02x %02x %02x %02x %02x %02x %02x %02x",
          out_frames[1][62],out_frames[1][63],out_frames[1][64],out_frames[1][65],out_frames[1][66],out_frames[1][67],out_frames[1][68],out_frames[1][69]);
        $display("");
        $display("================ FULL-CHAIN RESULT ================");
        $display("stack_tx frames (detour input) : %0d", in_cnt);
        $display("pump_rev frames (detour output): %0d", out_cnt);
        $display("pump_fwd: wr=%0d drop=%0d rd=%0d", pfwd_wr, pfwd_drop, pfwd_rd);
        $display("pump_rev: wr=%0d drop=%0d rd=%0d", prev_wr, prev_drop, prev_rd);
        $display("pack: frames=%0d ovf=%0d | unpack: frames=%0d bytes=%0d ovf=%0d stall=%0d",
                 pk_frames, pk_ovf, up_frames, up_bytes, up_ovf, up_stall);
        $display("stage bytes: pumpA_out=%0d  unpack_out=%0d  pumpB_out=%0d", fwd_cnt, upk_cnt, rev_cnt);
        ok_frames=0;
        for(e=0; e<((in_cnt<out_cnt)?in_cnt:out_cnt); e=e+1) begin
            if(in_len[e]==out_len[e]) begin
                bad=0;
                for(fi=0; fi<in_len[e]; fi=fi+1) begin
                    if(in_frames[e][fi]!==out_frames[e][fi]) begin
                        bad=bad+1;
                        if(bad<=3) $display("  frame%0d byte%0d: in=%02x out=%02x", e, fi, in_frames[e][fi], out_frames[e][fi]);
                    end
                end
                if(bad==0) begin ok_frames=ok_frames+1; $display("frame%0d: MATCH len=%0d", e, in_len[e]); end
                else           $display("frame%0d: MISMATCH len=%0d/%0d badbytes=%0d", e, in_len[e], out_len[e], bad);
            end
            else $display("frame%0d: LEN MISMATCH in=%0d out=%0d", e, in_len[e], out_len[e]);
        end
        $display("--------------------------------------------------");
        $display("MATCHED %0d / %0d frames", ok_frames, in_cnt);
        if(ok_frames==in_cnt && in_cnt>=3 && pfwd_drop==0 && prev_drop==0 && pk_ovf==0 && up_ovf==0)
            $display("*** PASS: detour preserves stack frames byte-for-byte ***");
        else
            $display("*** FAIL ***");
        $display("===================================================");
        $finish;
    end

    // 超时兜底
    initial begin
        #500000;
        $display("TIMEOUT"); $finish;
    end

endmodule
