//=============================================================================
// cmd_channel_tb.sv -- prj10 W5 unit testbench for prj_loop/rtl_patch/cmd_channel.v
//-----------------------------------------------------------------------------
// Input convention driven on gmii_rx_dv/gmii_rxd (same bus the official stack
// taps): a frame starts at the byte driven in the cycle gmii_rx_dv rises.
// Both conventions are exercised:
//   * WITH the 8-byte preamble (55 x7 + D5) -- what the real GMII RX bus carries
//     (official udp_rx syncs on 0x55/0xD5, so the preamble is present on board);
//     used for all normal cases;
//   * WITHOUT preamble (frame starts at dst MAC) -- one case (P6), which the
//     parser also accepts by construction.
//
// Judged criteria (each one must be able to FAIL; see run_cmd_tb.bat which also
// runs this bench with DEFECT_FIXUP=1 as a negative control):
//   C1  SET_MODE(1)      : cfg_mode -> 1, no rd_req_pulse, reply payload OK
//   C2  READ_SLOT(0x5A)  : cfg_mode=1, cfg_rd_slot=0x5A stable >=1 user clk
//                          before a single 1-clk rd_req_pulse; v16=0x5A,
//                          v16b = trigger sequence (monotonic +1)
//   C3  GET_WATERMARK    : v16/v16b/v16c == u_wr_frame/u_rd_frame/u_buf_drop
//   C4  GET_SLOT_MAP     : v16=u_wr_frame, v16b=u_wr_frame%256, v16c=1
//   C5  frame integrity  : every reply = 66 gapless bytes, eth/ip/udp header
//                          fields, IP checksum valid, FCS == independent
//                          reference CRC-32 (LE order) and residue 0x2144DF1C
//   C6  negatives        : wrong port / wrong magic / truncated payload are
//                          rejected: cmd_err_cnt +1, NO reply, NO rd_req_pulse
//   C7  non-command UDP  : port 1234 data frame is ignored (no counter change)
//   C8  tx_idle gate     : with tx_idle=0 nothing is transmitted (resp_busy
//                          never rises); after tx_idle=1 the reply goes out
//   C9  CDC random round : eth 8.0ns / user 6.6ns, 40 randomly spaced commands
//                          -> no lost command, no duplicate execution, order kept
//
// Verdict: "=== prj10 W5 CMD SIM: PASS (0 errors) ==="
//=============================================================================
`timescale 1ns/1ps

module cmd_channel_tb #(
    parameter bit DEFECT_FIXUP = 1'b0   // 1 = repair bad frames before the DUT
                                        //     (negative control: bench MUST fail)
)();

    //---------------------------------------------------------------- clocks
    logic eth_clk  = 1'b0;      // 125.0 MHz  (8.0 ns)
    logic user_clk = 1'b0;      // 151.5 MHz  (6.6 ns)
    always #4.0 eth_clk  = ~eth_clk;
    always #3.3 user_clk = ~user_clk;

    //---------------------------------------------------------------- resets
    logic eth_rst_n  = 1'b0;
    logic user_rst_n = 1'b0;

    //---------------------------------------------------------------- DUT I/O
    logic        tx_idle = 1'b0;
    logic        rx_dv   = 1'b0;
    logic [7:0]  rx_d     = 8'h00;
    wire         resp_tx_en;
    wire [7:0]   resp_txd;
    wire         resp_busy;
    wire [15:0]  cmd_rx_cnt, cmd_err_cnt, cmd_exec_cnt, rd_trig_cnt;
    wire         cfg_mode;
    wire [7:0]   cfg_rd_slot;
    wire         rd_req_pulse;
    logic [15:0] u_wr = 16'h0000, u_rd = 16'h0000, u_drop = 16'h0000;

    cmd_channel #(
        .BOARD_MAC (48'h00_11_22_33_44_55),
        .BCAST_MAC (48'hff_ff_ff_ff_ff_ff),
        .BOARD_IP  (32'hC0A8_010A),          // 192.168.1.10
        .BCAST_IP  (32'hC0A8_01FF),          // 192.168.1.255
        .CMD_PORT  (16'd1235),
        .MAGIC_CMD (32'h5031_3043),
        .MAGIC_RSP (32'h5031_3052)
    ) dut (
        .clk_eth      (eth_clk),
        .rst_eth_n    (eth_rst_n),
        .gmii_rx_dv   (rx_dv),
        .gmii_rxd     (rx_d),
        .tx_idle      (tx_idle),
        .resp_tx_en   (resp_tx_en),
        .resp_txd     (resp_txd),
        .resp_busy    (resp_busy),
        .cmd_rx_cnt   (cmd_rx_cnt),
        .cmd_err_cnt  (cmd_err_cnt),
        .clk_user     (user_clk),
        .rst_user_n   (user_rst_n),
        .u_wr_frame   (u_wr),
        .u_rd_frame   (u_rd),
        .u_buf_drop   (u_drop),
        .cfg_mode     (cfg_mode),
        .cfg_rd_slot  (cfg_rd_slot),
        .rd_req_pulse (rd_req_pulse),
        .cmd_exec_cnt (cmd_exec_cnt),
        .rd_trig_cnt  (rd_trig_cnt)
    );

    //=============================================================== scoring
    int errs = 0;
    task automatic fail(input string s);
        errs = errs + 1;
        $display("[FAIL] %s", s);
    endtask

    // reference CRC-32 (textbook reflected algorithm, independent of the DUT)
    function automatic logic [31:0] crc_byte(input logic [31:0] c, input logic [7:0] b);
        logic [31:0] cc;
        begin
            cc = c ^ {24'd0, b};
            for (int k = 0; k < 8; k++)
                cc = cc[0] ? ((cc >> 1) ^ 32'hEDB8_8320) : (cc >> 1);
            crc_byte = cc;
        end
    endfunction

    //=================================================== DUT response capture
    logic [7:0] cap    [0:127][0:255];   // captured reply frames
    int         frame_len [0:127];
    int         m_nframes = 0;
    int         m_cnt     = 0;
    logic       m_active  = 1'b0;
    int         m_gap     = 0;           // mid-frame resp_tx_en hole counter
    int         busy_rises = 0;

    logic busy_d = 1'b0;
    always @(posedge eth_clk) begin
        // ---- C8 assertion: resp_busy may only rise while tx_idle is high ----
        if (resp_busy && !busy_d) begin
            busy_rises = busy_rises + 1;
            if (!tx_idle)
                fail("PROTOCOL: resp_busy rose while tx_idle==0");
        end
        busy_d <= resp_busy;

        // ---- gapless byte stream check ----
        if (resp_busy && !resp_tx_en && (m_cnt > 0) && (m_cnt < 66))
            m_gap = m_gap + 1;
        if (resp_tx_en && !resp_busy)
            fail("PROTOCOL: resp_tx_en asserted without resp_busy");

        // ---- frame collection: a busy window = one reply frame ----
        if (resp_busy) begin
            m_active = 1'b1;
            if (resp_tx_en) begin
                if (m_cnt < 256) cap[m_nframes][m_cnt] = resp_txd;
                m_cnt = m_cnt + 1;
            end
        end
        else if (m_active) begin
            frame_len[m_nframes] = m_cnt;
            m_nframes = m_nframes + 1;
            m_cnt     = 0;
            m_active  = 1'b0;
        end
    end

    //================================================ user-domain pulse check
    int   pulse_width = 0, pulse_max = 0, pulse_events = 0;
    logic prp_d = 1'b0;
    logic [7:0] cfg_slot_d1 = 8'h00;
    logic       cfg_mode_d1 = 1'b0;

    always @(posedge user_clk) begin
        cfg_slot_d1 <= cfg_rd_slot;
        cfg_mode_d1 <= cfg_mode;
        if (rd_req_pulse) pulse_width = pulse_width + 1;
        else begin
            if (pulse_width > pulse_max) pulse_max = pulse_width;
            if (pulse_width > 0)         pulse_events = pulse_events + 1;
            pulse_width = 0;
        end
        if (rd_req_pulse && !prp_d) begin
            // cfg must already be stable for >= 1 user_clk before the pulse
            if (cfg_slot_d1 !== cfg_rd_slot)
                fail("TIMING: cfg_rd_slot changed on the rd_req_pulse cycle");
            if (cfg_mode !== 1'b1 || cfg_mode_d1 !== 1'b1)
                fail("TIMING: cfg_mode not RND before rd_req_pulse");
        end
        prp_d <= rd_req_pulse;
    end

    //=========================================================== frame builder
    logic [7:0] txbuf [0:255];
    int         txlen  = 0;
    int         tx_ip0 = 0;         // offset of the IP header in txbuf

    task automatic build_cmd(
        input logic [47:0] dmac, input logic [47:0] smac,
        input logic [31:0] sip,  input logic [31:0] dip,
        input logic [15:0] sport, input logic [15:0] dport,
        input logic [31:0] magic,
        input logic [7:0]  op,   input logic [7:0]  a0, input logic [15:0] a1,
        input int          pay_total, input int pre
    );
        int p; int i;
        logic [19:0] s0; logic [16:0] s1, s2; logic [15:0] ck, iplen, udplen;
        p = 0;
        for (i = 0; i < pre; i++)
            txbuf[p++] = (i == (pre-1)) ? 8'hD5 : 8'h55;
        // ---- eth header ----
        txbuf[p++] = dmac[47:40]; txbuf[p++] = dmac[39:32]; txbuf[p++] = dmac[31:24];
        txbuf[p++] = dmac[23:16]; txbuf[p++] = dmac[15:8];  txbuf[p++] = dmac[7:0];
        txbuf[p++] = smac[47:40]; txbuf[p++] = smac[39:32]; txbuf[p++] = smac[31:24];
        txbuf[p++] = smac[23:16]; txbuf[p++] = smac[15:8];  txbuf[p++] = smac[7:0];
        txbuf[p++] = 8'h08; txbuf[p++] = 8'h00;
        tx_ip0 = p;
        // ---- IPv4 header (IHL=5, no options) ----
        iplen = 16'd20 + 16'd8 + pay_total[15:0];
        txbuf[p++] = 8'h45; txbuf[p++] = 8'h00;
        txbuf[p++] = iplen[15:8]; txbuf[p++] = iplen[7:0];
        txbuf[p++] = 8'h12; txbuf[p++] = 8'h34;              // id (unchecked)
        txbuf[p++] = 8'h40; txbuf[p++] = 8'h00;
        txbuf[p++] = 8'h40; txbuf[p++] = 8'd17;              // TTL 64, UDP
        txbuf[p++] = 8'h00; txbuf[p++] = 8'h00;              // checksum slot
        txbuf[p++] = sip[31:24]; txbuf[p++] = sip[23:16];
        txbuf[p++] = sip[15:8];  txbuf[p++] = sip[7:0];
        txbuf[p++] = dip[31:24]; txbuf[p++] = dip[23:16];
        txbuf[p++] = dip[15:8];  txbuf[p++] = dip[7:0];
        s0 = 20'd0;
        for (i = 0; i < 10; i++)
            s0 = s0 + {txbuf[tx_ip0 + 2*i], txbuf[tx_ip0 + 2*i + 1]};
        s1 = s0[15:0] + {14'd0, s0[19:16]};
        s2 = s1[15:0] + {16'd0, s1[16]};
        ck = ~s2[15:0];
        txbuf[tx_ip0 + 10] = ck[15:8];
        txbuf[tx_ip0 + 11] = ck[7:0];
        // ---- UDP header ----
        udplen = 16'd8 + pay_total[15:0];
        txbuf[p++] = sport[15:8]; txbuf[p++] = sport[7:0];
        txbuf[p++] = dport[15:8]; txbuf[p++] = dport[7:0];
        txbuf[p++] = udplen[15:8]; txbuf[p++] = udplen[7:0];
        txbuf[p++] = 8'h00; txbuf[p++] = 8'h00;
        // ---- payload: magic | opcode | arg0 | arg1(LE) | fill ----
        txbuf[p++] = magic[31:24]; txbuf[p++] = magic[23:16];
        txbuf[p++] = magic[15:8];  txbuf[p++] = magic[7:0];
        txbuf[p++] = op;  txbuf[p++] = a0;
        txbuf[p++] = a1[7:0]; txbuf[p++] = a1[15:8];
        for (i = 8; i < pay_total; i++) txbuf[p++] = 8'hA5;
        txlen = p;
    endtask

    // negative-control repair: turn a rejected frame into an acceptable one
    task automatic repair_frame;
        txbuf[tx_ip0 + 22] = 8'h04;             // UDP dst port hi
        txbuf[tx_ip0 + 23] = 8'hD3;             // 1235
        txbuf[tx_ip0 + 28] = 8'h50;             // payload magic "P10C"
        txbuf[tx_ip0 + 29] = 8'h31;
        txbuf[tx_ip0 + 30] = 8'h30;
        txbuf[tx_ip0 + 31] = 8'h43;
    endtask

    // drive n bytes (one per eth_clk) on the RX tap bus
    task automatic send_frame(input int n);
        for (int i = 0; i < n; i++) begin
            @(negedge eth_clk); rx_dv = 1'b1; rx_d = txbuf[i];
            @(posedge eth_clk);
        end
        @(negedge eth_clk); rx_dv = 1'b0; rx_d = 8'h00;
        repeat (6) @(posedge eth_clk);
    endtask

    task automatic wait_frames(input int want, input int tmo_clk, input string tag);
        int t;
        t = 0;
        while ((m_nframes < want) && (t < tmo_clk)) begin
            @(posedge eth_clk);
            t = t + 1;
        end
        if (m_nframes < want)
            fail($sformatf("%s: expected %0d reply frame(s), got %0d (timeout)", tag, want, m_nframes));
    endtask

    task automatic idle_clks(input int n);
        repeat (n) @(posedge eth_clk);
    endtask

    //====================================================== expected reply check
    int exp_id = 1;         // IP id of the next expected reply (1,2,3,...)

    task automatic verify_reply(
        input int fi,
        input logic [7:0]  e_op, e_st,
        input logic [15:0] e_v16, e_v16b, e_v16c,
        input logic [47:0] e_dmac,
        input logic [31:0] e_dip,
        input logic [15:0] e_dport,
        input string tag
    );
        logic [31:0] c, fcs, sumw;
        logic [15:0] w;
        logic [7:0]  f0, f1, f2, f3;
        string pfx;
        pfx = $sformatf("%s/reply#%0d", tag, fi);
        if (frame_len[fi] != 66) begin
            fail($sformatf("%s: length %0d (expected 66)", pfx, frame_len[fi]));
            return;
        end
        // preamble + eth header
        for (int i = 0; i < 7; i++)
            if (cap[fi][i] !== 8'h55) fail($sformatf("%s: preamble[%0d]=%02x", pfx, i, cap[fi][i]));
        if (cap[fi][7] !== 8'hD5) fail($sformatf("%s: SFD=%02x", pfx, cap[fi][7]));
        if (cap[fi][8]  !== e_dmac[47:40] || cap[fi][9]  !== e_dmac[39:32] ||
            cap[fi][10] !== e_dmac[31:24] || cap[fi][11] !== e_dmac[23:16] ||
            cap[fi][12] !== e_dmac[15:8]  || cap[fi][13] !== e_dmac[7:0])
            fail($sformatf("%s: dst MAC mismatch (captured src MAC not used?)", pfx));
        if (cap[fi][14] !== 8'h00 || cap[fi][15] !== 8'h11 || cap[fi][16] !== 8'h22 ||
            cap[fi][17] !== 8'h33 || cap[fi][18] !== 8'h44 || cap[fi][19] !== 8'h55)
            fail($sformatf("%s: src MAC != board MAC", pfx));
        if (cap[fi][20] !== 8'h08 || cap[fi][21] !== 8'h00)
            fail($sformatf("%s: ethertype != 0800", pfx));
        // IPv4 header
        if (cap[fi][22] !== 8'h45) fail($sformatf("%s: IP ver/IHL=%02x", pfx, cap[fi][22]));
        if ({cap[fi][24], cap[fi][25]} !== 16'h0028)
            fail($sformatf("%s: IP total len=%04x (want 0028)", pfx, {cap[fi][24], cap[fi][25]}));
        if ({cap[fi][26], cap[fi][27]} !== exp_id[15:0])
            fail($sformatf("%s: IP id=%04x (want %04x)", pfx, {cap[fi][26], cap[fi][27]}, exp_id));
        if (cap[fi][30] !== 8'h40 || cap[fi][31] !== 8'd17)
            fail($sformatf("%s: TTL/proto=%02x/%02x", pfx, cap[fi][30], cap[fi][31]));
        // one's complement sum over the 20 header bytes, WITH end-around carry
        sumw = 32'h0000_0000;
        for (int i = 0; i < 10; i++) begin
            w = {cap[fi][22 + 2*i], cap[fi][23 + 2*i]};
            sumw = sumw + {16'd0, w};
        end
        sumw = (sumw & 32'h0000_FFFF) + (sumw >> 16);
        sumw = (sumw & 32'h0000_FFFF) + (sumw >> 16);
        if ((sumw & 32'h0000_FFFF) !== 32'h0000_FFFF)
            fail($sformatf("%s: IP header checksum invalid (folded sum=%04x)", pfx, sumw[15:0]));
        if (cap[fi][34] !== 8'hC0 || cap[fi][35] !== 8'hA8 ||
            cap[fi][36] !== 8'h01 || cap[fi][37] !== 8'h0A)
            fail($sformatf("%s: src IP != 192.168.1.10", pfx));
        if (cap[fi][38] !== e_dip[31:24] || cap[fi][39] !== e_dip[23:16] ||
            cap[fi][40] !== e_dip[15:8]  || cap[fi][41] !== e_dip[7:0])
            fail($sformatf("%s: dst IP mismatch", pfx));
        // UDP header
        if ({cap[fi][42], cap[fi][43]} !== 16'd1235)
            fail($sformatf("%s: src port != 1235", pfx));
        if ({cap[fi][44], cap[fi][45]} !== e_dport)
            fail($sformatf("%s: dst port=%04x (want %04x)", pfx, {cap[fi][44], cap[fi][45]}, e_dport));
        if ({cap[fi][46], cap[fi][47]} !== 16'd20)
            fail($sformatf("%s: UDP len != 20", pfx));
        if (cap[fi][48] !== 8'h00 || cap[fi][49] !== 8'h00)
            fail($sformatf("%s: UDP checksum != 0", pfx));
        // payload
        if (cap[fi][50] !== 8'h50 || cap[fi][51] !== 8'h31 ||
            cap[fi][52] !== 8'h30 || cap[fi][53] !== 8'h52)
            fail($sformatf("%s: reply magic != P10R", pfx));
        if (cap[fi][54] !== e_op) fail($sformatf("%s: opcode echo=%02x want %02x", pfx, cap[fi][54], e_op));
        if (cap[fi][55] !== e_st) fail($sformatf("%s: status=%02x want %02x", pfx, cap[fi][55], e_st));
        if ({cap[fi][57], cap[fi][56]} !== e_v16)
            fail($sformatf("%s: v16=%04x want %04x", pfx, {cap[fi][57], cap[fi][56]}, e_v16));
        if ({cap[fi][59], cap[fi][58]} !== e_v16b)
            fail($sformatf("%s: v16b=%04x want %04x", pfx, {cap[fi][59], cap[fi][58]}, e_v16b));
        if ({cap[fi][61], cap[fi][60]} !== e_v16c)
            fail($sformatf("%s: v16c=%04x want %04x", pfx, {cap[fi][61], cap[fi][60]}, e_v16c));
        // FCS: independent reference + residue
        c = 32'hFFFF_FFFF;
        for (int i = 8; i <= 61; i++) c = crc_byte(c, cap[fi][i]);
        fcs = c ^ 32'hFFFF_FFFF;
        f0 = fcs[7:0]; f1 = fcs[15:8]; f2 = fcs[23:16]; f3 = fcs[31:24];
        if (cap[fi][62] !== f0 || cap[fi][63] !== f1 ||
            cap[fi][64] !== f2 || cap[fi][65] !== f3)
            fail($sformatf("%s: FCS %02x %02x %02x %02x want %02x %02x %02x %02x",
                 pfx, cap[fi][62], cap[fi][63], cap[fi][64], cap[fi][65], f0, f1, f2, f3));
        c = 32'hFFFF_FFFF;
        for (int i = 8; i <= 65; i++) c = crc_byte(c, cap[fi][i]);
        if ((c ^ 32'hFFFF_FFFF) !== 32'h2144_DF1C)
            fail($sformatf("%s: FCS residue != 0x2144DF1C", pfx));
        exp_id = exp_id + 1;
    endtask

    //================================================================= stimulus
    localparam logic [47:0] B_MAC  = 48'hff_ff_ff_ff_ff_ff;
    localparam logic [47:0] PC_MAC = 48'h00_0c_29_ab_cd_ef;
    localparam logic [31:0] B_IP   = 32'hC0A8_01FF;   // 192.168.1.255 (broadcast)
    localparam logic [31:0] PC_IP  = 32'hC0A8_0166;   // 192.168.1.102
    localparam logic [31:0] MG     = 32'h5031_3043;   // "P10C"

    int  rx_before, err_before, pulses_before, exec_before;
    logic [15:0] trig_before;

    initial begin
        //---------------------------------------------------------- reset
        tx_idle = 1'b0; rx_dv = 1'b0; rx_d = 8'h00;
        eth_rst_n = 1'b0; user_rst_n = 1'b0;
        repeat (24) @(posedge eth_clk);
        eth_rst_n = 1'b1; user_rst_n = 1'b1;
        repeat (24) @(posedge eth_clk);

        // reference CRC self-validation ("123456789" -> 0xCBF43926)
        begin
            logic [31:0] c;
            c = 32'hFFFF_FFFF;
            c = crc_byte(c, 8'h31); c = crc_byte(c, 8'h32); c = crc_byte(c, 8'h33);
            c = crc_byte(c, 8'h34); c = crc_byte(c, 8'h35); c = crc_byte(c, 8'h36);
            c = crc_byte(c, 8'h37); c = crc_byte(c, 8'h38); c = crc_byte(c, 8'h39);
            if ((c ^ 32'hFFFF_FFFF) !== 32'hCBF4_3926)
                fail($sformatf("reference CRC broken: %08x", (c ^ 32'hFFFF_FFFF)));
        end

        //==========================================================
        // C8: tx_idle gate.  tx_idle = 0 -> the reply must not start.
        //==========================================================
        $display("[P1] tx_idle=0: command executed but no transmission");
        build_cmd(B_MAC, PC_MAC, PC_IP, B_IP, 16'd40001, 16'd1235, MG,
                  8'h01, 8'h01, 16'h0000, 8, 8);
        send_frame(txlen);
        idle_clks(1500);                                   // ~12 us
        if (m_nframes != 0)      fail("C8: reply transmitted while tx_idle==0");
        if (resp_busy !== 1'b0)  fail("C8: resp_busy high while tx_idle==0");
        if (cmd_exec_cnt !== 16'd1)
            fail($sformatf("C8: cmd_exec_cnt=%0d (want 1)", cmd_exec_cnt));
        if (resp_tx_en !== 1'b0) fail("C8: resp_tx_en high while tx_idle==0");

        $display("[P2] tx_idle=1: the pending reply goes out");
        tx_idle = 1'b1;
        wait_frames(1, 4000, "C8");
        if (m_nframes >= 1) begin
            verify_reply(0, 8'h01, 8'h00, 16'h0000, 16'h0000, 16'h0000,
                         PC_MAC, PC_IP, 16'd40001, "C8");
            if (cfg_mode !== 1'b1) fail("C1: cfg_mode != 1 after SET_MODE(1)");
            if (pulse_events != 0) fail("C1: rd_req_pulse fired for SET_MODE");
        end

        //==========================================================
        // C2: READ_SLOT(0x5A) -> cfg_rd_slot + single 1-clk pulse
        //==========================================================
        $display("[P3] READ_SLOT(0x5A)");
        u_wr = 16'h0100; u_rd = 16'h0040; u_drop = 16'h0000;
        pulses_before = pulse_events;
        trig_before   = rd_trig_cnt;
        build_cmd(B_MAC, PC_MAC, PC_IP, B_IP, 16'd40002, 16'd1235, MG,
                  8'h02, 8'h5A, 16'h0000, 8, 8);
        send_frame(txlen);
        wait_frames(2, 4000, "C2");
        idle_clks(200);
        if (m_nframes >= 2) begin
            verify_reply(1, 8'h02, 8'h00, 16'h005A, 16'h0001, 16'h0000,
                         PC_MAC, PC_IP, 16'd40002, "C2");
        end
        if (cfg_mode !== 1'b1)        fail("C2: cfg_mode != 1");
        if (cfg_rd_slot !== 8'h5A)    fail($sformatf("C2: cfg_rd_slot=%02x want 5A", cfg_rd_slot));
        if ((pulse_events - pulses_before) != 1)
            fail($sformatf("C2: %0d rd_req_pulse events (want 1)", pulse_events - pulses_before));
        if (pulse_max != 1)
            fail($sformatf("C2: rd_req_pulse width %0d user_clk (want 1)", pulse_max));
        if ((rd_trig_cnt - trig_before) != 16'd1)
            fail($sformatf("C2: rd_trig_cnt delta %0d (want 1)", rd_trig_cnt - trig_before));

        //==========================================================
        // C3: GET_WATERMARK
        //==========================================================
        $display("[P4] GET_WATERMARK");
        u_wr = 16'h1234; u_rd = 16'h0567; u_drop = 16'h0002;
        pulses_before = pulse_events;
        build_cmd(B_MAC, PC_MAC, 32'hC0A8_014D, B_IP, 16'd40003, 16'd1235, MG,
                  8'h03, 8'h00, 16'h0000, 8, 8);
        send_frame(txlen);
        wait_frames(3, 4000, "C3");
        if (m_nframes >= 3)
            verify_reply(2, 8'h03, 8'h00, 16'h1234, 16'h0567, 16'h0002,
                         48'h00_0c_29_ab_cd_ef, 32'hC0A8_014D, 16'd40003, "C3");
        if (pulse_events != pulses_before) fail("C3: rd_req_pulse fired for GET_WATERMARK");

        //==========================================================
        // C4: GET_SLOT_MAP (write slot = frame count mod 256)
        //==========================================================
        $display("[P5] GET_SLOT_MAP");
        u_wr = 16'h0123; u_rd = 16'h0100; u_drop = 16'h0000;
        build_cmd(B_MAC, PC_MAC, PC_IP, B_IP, 16'd40004, 16'd1235, MG,
                  8'h04, 8'h00, 16'h0000, 8, 8);
        send_frame(txlen);
        wait_frames(4, 4000, "C4");
        if (m_nframes >= 4)
            verify_reply(3, 8'h04, 8'h00, 16'h0123, 16'h0023, 16'h0001,
                         PC_MAC, PC_IP, 16'd40004, "C4");

        //==========================================================
        // C6: negatives -- each must be rejected and counted
        //==========================================================
        $display("[P6a] wrong destination port (1234) with correct magic");
        rx_before = m_nframes; err_before = cmd_err_cnt; pulses_before = pulse_events;
        build_cmd(B_MAC, PC_MAC, PC_IP, B_IP, 16'd40005, 16'd1234, MG,
                  8'h02, 8'h11, 16'h0000, 8, 8);
        if (DEFECT_FIXUP) repair_frame();
        send_frame(txlen);
        idle_clks(1200);
        if (m_nframes != rx_before)         fail("C6a: reply sent for wrong-port frame");
        if (cmd_err_cnt !== (err_before + 1)) fail($sformatf("C6a: cmd_err_cnt %0d->%0d (want +1)",
                                                             err_before, cmd_err_cnt));
        if (pulse_events != pulses_before)  fail("C6a: rd_req_pulse fired");
        if (cmd_rx_cnt !== 16'd4)           fail($sformatf("C6a: cmd_rx_cnt=%0d (want 4)", cmd_rx_cnt));
        if (cfg_rd_slot !== 8'h5A)          fail("C6a: cfg_rd_slot clobbered by rejected frame");

        $display("[P6b] correct port 1235 but wrong magic");
        rx_before = m_nframes; err_before = cmd_err_cnt; pulses_before = pulse_events;
        build_cmd(B_MAC, PC_MAC, PC_IP, B_IP, 16'd40006, 16'd1235, 32'h5031_3058,
                  8'h02, 8'h22, 16'h0000, 8, 8);
        if (DEFECT_FIXUP) repair_frame();
        send_frame(txlen);
        idle_clks(1200);
        if (m_nframes != rx_before)          fail("C6b: reply sent for bad-magic frame");
        if (cmd_err_cnt !== (err_before + 1)) fail($sformatf("C6b: cmd_err_cnt %0d->%0d (want +1)",
                                                              err_before, cmd_err_cnt));
        if (pulse_events != pulses_before)   fail("C6b: rd_req_pulse fired");
        if (cfg_rd_slot !== 8'h5A)           fail("C6b: cfg_rd_slot clobbered by rejected frame");

        $display("[P6c] truncated payload (6 bytes sent, header claims 8)");
        rx_before = m_nframes; err_before = cmd_err_cnt; pulses_before = pulse_events;
        build_cmd(B_MAC, PC_MAC, PC_IP, B_IP, 16'd40007, 16'd1235, MG,
                  8'h02, 8'h33, 16'h0000, 8, 8);
        if (DEFECT_FIXUP) send_frame(txlen);
        else              send_frame(txlen - 2);   // payload cut to 6 bytes
        idle_clks(1200);
        if (m_nframes != rx_before)          fail("C6c: reply sent for truncated frame");
        if (cmd_err_cnt !== (err_before + 1)) fail($sformatf("C6c: cmd_err_cnt %0d->%0d (want +1)",
                                                              err_before, cmd_err_cnt));
        if (pulse_events != pulses_before)   fail("C6c: rd_req_pulse fired");

        $display("[P6d] UDP length field says 12 (< 8 payload bytes)");
        rx_before = m_nframes; err_before = cmd_err_cnt; pulses_before = pulse_events;
        build_cmd(B_MAC, PC_MAC, PC_IP, B_IP, 16'd40008, 16'd1235, MG,
                  8'h02, 8'h44, 16'h0000, 8, 8);
        txbuf[tx_ip0 + 24] = 8'h00; txbuf[tx_ip0 + 25] = 8'h0C;   // UDP len = 12
        if (DEFECT_FIXUP) begin
            txbuf[tx_ip0 + 24] = 8'h00; txbuf[tx_ip0 + 25] = 8'h14;  // 20
        end
        send_frame(txlen);
        idle_clks(1200);
        if (m_nframes != rx_before)          fail("C6d: reply sent for short-length frame");
        if (cmd_err_cnt !== (err_before + 1)) fail($sformatf("C6d: cmd_err_cnt %0d->%0d (want +1)",
                                                              err_before, cmd_err_cnt));
        if (pulse_events != pulses_before)   fail("C6d: rd_req_pulse fired");

        //==========================================================
        // C7: ordinary data frame (port 1234, no magic) must be ignored
        //==========================================================
        $display("[P7] non-command UDP traffic is ignored (no counter change)");
        rx_before = m_nframes; err_before = cmd_err_cnt;
        build_cmd(B_MAC, PC_MAC, PC_IP, 32'hC0A8_010A, 16'd4321, 16'd1234,
                  32'hDEAD_BEEF, 8'h00, 8'h00, 16'h0000, 26, 8);
        send_frame(txlen);
        idle_clks(1000);
        if (m_nframes != rx_before)          fail("C7: reply sent for data traffic");
        if (cmd_err_cnt !== err_before)      fail("C7: cmd_err_cnt moved on data traffic");

        //==========================================================
        // C5b: preamble-free frame still accepted (documented tolerant start)
        //==========================================================
        $display("[P8] frame without preamble (dst MAC first byte)");
        pulses_before = pulse_events;
        build_cmd(B_MAC, 48'h00_50_56_c0_00_08, 32'hC0A8_0102, B_IP,
                  16'd40009, 16'd1235, MG, 8'h02, 8'h77, 16'h0000, 8, 0);
        send_frame(txlen);
        wait_frames(5, 4000, "C5b");
        if (m_nframes >= 5)
            verify_reply(4, 8'h02, 8'h00, 16'h0077, 16'h0002, 16'h0000,
                         48'h00_50_56_c0_00_08, 32'hC0A8_0102, 16'd40009, "C5b");

        //==========================================================
        // C9: CDC random round -- 40 randomly spaced commands
        //==========================================================
        $display("[P9] CDC random round (eth 8.0ns / user 6.6ns)");
        begin
            int ncmd; int nrd; int i; int gap; int rdn;
            logic [7:0]  s_op [0:63];
            logic [15:0] s_v16[0:63], s_v16b[0:63], s_v16c[0:63];
            logic [15:0] s_sport[0:63];
            logic [7:0]  s_st[0:63];
            int          s_isrd[0:63];
            int          base_frames; int last_trig;
            ncmd = 40; nrd = 0; rdn = 0;
            base_frames = m_nframes;
            rx_before = cmd_rx_cnt; err_before = cmd_err_cnt;
            exec_before = cmd_exec_cnt; trig_before = rd_trig_cnt;
            pulses_before = pulse_events;
            for (i = 0; i < ncmd; i++) begin
                u_wr   = $urandom_range(0, 65535);
                u_rd   = $urandom_range(0, 65535);
                u_drop = $urandom_range(0, 3);
                s_sport[i] = 45000 + i[15:0];
                case ($urandom_range(0, 3))
                0: begin s_op[i]=8'h01; s_st[i]=8'h00; s_v16[i]=16'h0000; s_v16b[i]=16'h0000;
                         s_v16c[i]=16'h0000; s_isrd[i]=0; end
                1: begin s_op[i]=8'h02; s_st[i]=8'h00; s_v16[i]={8'h00, $urandom_range(0,255)};
                         s_v16c[i]=16'h0000; s_isrd[i]=1; nrd++; rdn++;
                         s_v16b[i]=trig_before + rdn[15:0]; end
                2: begin s_op[i]=8'h03; s_st[i]=8'h00; s_v16[i]=u_wr; s_v16b[i]=u_rd;
                         s_v16c[i]=u_drop; s_isrd[i]=0; end
                default: begin s_op[i]=8'h04; s_st[i]=8'h00; s_v16[i]=u_wr;
                         s_v16b[i]={8'h00,u_wr[7:0]}; s_v16c[i]=16'h0001; s_isrd[i]=0; end
                endcase
                build_cmd(B_MAC, PC_MAC, PC_IP, B_IP, s_sport[i], 16'd1235, MG,
                          s_op[i], s_v16[i][7:0], 16'h0000, 8, 8);
                send_frame(txlen);
                gap = $urandom_range(400, 1600);          // 3.2 .. 12.8 us
                idle_clks(gap);
            end
            // every command must be answered, in order
            wait_frames(base_frames + ncmd, 20000, "C9");
            idle_clks(400);
            last_trig = -1;
            for (i = 0; i < ncmd; i++) begin
                if ((base_frames + i) >= m_nframes) break;
                verify_reply(base_frames + i, s_op[i], s_st[i], s_v16[i], s_v16b[i], s_v16c[i],
                             PC_MAC, PC_IP, s_sport[i], "C9");
                if (s_isrd[i]) begin
                    // v16b = trigger sequence, monotonic +1
                    if (last_trig >= 0 && ({cap[base_frames+i][59], cap[base_frames+i][58]} !== last_trig + 1))
                        fail($sformatf("C9: trigger seq not monotonic at cmd %0d", i));
                    last_trig = {cap[base_frames+i][59], cap[base_frames+i][58]};
                end
            end
            if ((int'(cmd_rx_cnt) - rx_before) != ncmd)
                fail($sformatf("C9: cmd_rx_cnt delta %0d (want %0d)",
                               int'(cmd_rx_cnt) - rx_before, ncmd));
            if ((int'(cmd_exec_cnt) - exec_before) != ncmd)
                fail($sformatf("C9: cmd_exec_cnt delta %0d (want %0d)",
                               int'(cmd_exec_cnt) - exec_before, ncmd));
            if (int'(cmd_err_cnt) != err_before)
                fail($sformatf("C9: cmd_err_cnt moved (%0d -> %0d)", err_before, cmd_err_cnt));
            if ((int'(rd_trig_cnt) - int'(trig_before)) != nrd)
                fail($sformatf("C9: rd_trig_cnt delta %0d (want %0d)",
                               int'(rd_trig_cnt) - int'(trig_before), nrd));
            if ((pulse_events - pulses_before) != nrd)
                fail($sformatf("C9: %0d rd_req_pulse events (want %0d)", pulse_events - pulses_before, nrd));
            if (pulse_max != 1)
                fail($sformatf("C9: rd_req_pulse width %0d (want 1)", pulse_max));
            if (m_nframes !== base_frames + ncmd)
                fail($sformatf("C9: %0d replies (want %0d)", m_nframes - base_frames, ncmd));
        end

        //==========================================================
        // C10: back-to-back (no PC gap) -- second command while the first
        //      reply is in flight must be DROPPED with cmd_err_cnt++
        //==========================================================
        $display("[P10] back-to-back commands: 2nd dropped, never overriding");
        begin
            int f_before; int e_before; int r_before;
            f_before = m_nframes; e_before = cmd_err_cnt; r_before = cmd_rx_cnt;
            build_cmd(B_MAC, PC_MAC, PC_IP, B_IP, 16'd40010, 16'd1235, MG,
                      8'h02, 8'h01, 16'h0000, 8, 8);
            send_frame(txlen);
            build_cmd(B_MAC, PC_MAC, PC_IP, B_IP, 16'd40011, 16'd1235, MG,
                      8'h02, 8'h02, 16'h0000, 8, 8);
            send_frame(txlen);                        // immediately after
            idle_clks(2000);
            if (m_nframes !== (f_before + 1))
                fail($sformatf("C10: %0d replies (want 1: the 2nd must be dropped)",
                               m_nframes - f_before));
            if ((cmd_err_cnt - e_before) != 1)
                fail($sformatf("C10: cmd_err_cnt delta %0d (want 1)", cmd_err_cnt - e_before));
            if ((int'(cmd_rx_cnt) - r_before) != 2)
                fail($sformatf("C10: cmd_rx_cnt delta %0d (want 2 valid frames)",
                               int'(cmd_rx_cnt) - r_before));
        end

        //==========================================================
        // global checks + verdict
        //==========================================================
        if (m_gap != 0)
            fail($sformatf("C5: %0d mid-frame resp_tx_en hole(s) - pump A would split the frame", m_gap));
        if (pulse_max > 1)
            fail($sformatf("C2: rd_req_pulse wider than 1 user_clk (%0d)", pulse_max));

        $display("STAT frames=%0d rx=%0d err=%0d exec=%0d rd_trig=%0d pulses=%0d pw=%0d busy_rises=%0d",
                 m_nframes, cmd_rx_cnt, cmd_err_cnt, cmd_exec_cnt, rd_trig_cnt,
                 pulse_events, pulse_max, busy_rises);
        if (errs == 0) $display("=== prj10 W5 CMD SIM: PASS (0 errors) ===");
        else           $display("=== prj10 W5 CMD SIM: FAIL (%0d errors) ===", errs);
        $finish;
    end

    // watchdog
    initial begin
        #3_000_000;      // 3 ms global timeout
        $display("[FAIL] GLOBAL TIMEOUT");
        $display("=== prj10 W5 CMD SIM: FAIL (timeout) ===");
        $finish;
    end

endmodule
