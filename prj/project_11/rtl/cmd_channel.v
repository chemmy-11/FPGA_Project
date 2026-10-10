//=============================================================================
// cmd_channel.v -- prj10 W5: UDP command channel (RX tap -> 4-phase mailbox ->
//                  user-domain execution -> response frame injection)
//-----------------------------------------------------------------------------
// Contract (frozen 2026-10-07, vault "prj10 W5 command channel interface
// contract v1"; the file name is kept out of this source to keep it ASCII):
//   section 2 PC<->FPGA protocol : cmd dst port 1235 + magic "P10C";
//                                  12-byte response payload with magic "P10R"
//   section 3 RTL port contract  : ports below (names/widths/domains unchanged)
//   Appendix v1.1 (Lead)   : +tx_idle input (eth domain) + resp_busy send gate
//                            + drop-with-cmd_err_cnt when a new command arrives
//                            while the previous response is still in flight
//
// Why this shape (rationale for the defense):
//   * The RX tap is PARALLEL to the official arp/icmp/udp parsers (same bus, no
//     official module touched). The official udp_rx does not look at the
//     destination port, so commands are sent to the BROADCAST IP: the official
//     stack drops them at its IP check (no echo into the data plane, no slot
//     consumed, no wr_stall).
//   * Response bytes are injected into the pump-A input mux, so the reply rides
//     the existing loop (pumpA -> bridge1 -> DDR -> bridge2 -> pumpB -> RGMII).
//     The frame must therefore be a COMPLETE Ethernet frame (preamble + eth +
//     ip + udp + payload + FCS), gapless, exactly like the official stack TX
//     byte stream captured by frame_fifo_pump.
//   * FCS: the crc32_d8 equations of the official stack are reused verbatim
//     (register = bitrev32(C), data input bit-reversed) and the four FCS bytes
//     use the same output mapping as the official udp_tx, so the reply is
//     bit-identical in convention to the W3/W4 verified data plane.
//     Equivalent standard statement (checked numerically, residue 0x2144DF1C):
//     FCS = ~C, wire byte order LSB-first, C = reflected CRC-32
//     (poly 0xEDB88320, init 0xFFFFFFFF) over frame bytes [dst MAC .. last
//     payload byte].
//   * CDC: two independent 4-phase handshakes (req/ack level + payload held
//     stable for the whole phase); no multi-bit signal is ever sampled
//     directly across domains (AGENTS.md section 5.1 legal form).
//
// Frame produced by this module (66 bytes, gapless, 1 byte/clk):
//   [0..7]   55 55 55 55 55 55 55 D5              preamble
//   [8..13]  dst MAC  = command frame src MAC     (captured)
//   [14..19] src MAC  = BOARD_MAC
//   [20..21] 08 00
//   [22..41] IPv4 header (20B, IHL=5): 45 00 | len=40 | id++ | 40 00 | 40 11 |
//            hdr cksum | 192.168.1.10 | captured src IP
//   [42..49] UDP header: src port 1235 | dst port = captured src port |
//            len 20 | cksum 0000 (IPv4 allows 0 = not computed)
//   [50..61] 12-byte payload: "P10R" | opcode | status | v16 | v16b | v16c (LE)
//   [62..67] 6-byte Ethernet PADDING (00)  <-- ★必需
//   [68..71] FCS (covers bytes 8..67)
//
// ★ 为什么必须有填充（2026-10-08 上板实证的 runt 缺陷）：
//   以太网最小帧 = 64 字节（不含前导码/SFD）。本应答帧在加填充前
//   线路上只有 58 字节（6+6+2 以太头 + 20 IP + 8 UDP + 12 载荷 + 4 FCS），
//   **网卡在硬件层直接丢弃 runt 帧** —— 板内一切正常（ILA 实测 resp_busy
//   高 68 拍、FCS 经独立参考校验），PC 却收不到任何包且网卡错误计数为 0。
//   按 RFC 894，填充**不计入** IP total length（保持 40）与 UDP length（保持 20），
//   仅参与 FCS 计算。填充后线路长度 = 8+14+20+8+12+6+4 = 72B = 8 前导 + 64B 帧 ✓
//
// TX takeover timing (Appendix v1.1): resp_busy is raised only after tx_idle,
// then ONE settling cycle is spent before the first byte so that the
// top-level registered mux (cmd_takeover) is already pointing at this module
// when the preamble starts.  resp_busy stays high until one clk after the last
// resp_tx_en cycle.
//=============================================================================
`timescale 1ns/1ps

module cmd_channel #(
    parameter [47:0] BOARD_MAC = 48'h00_11_22_33_44_55,
    parameter [47:0] BCAST_MAC = 48'hff_ff_ff_ff_ff_ff,
    parameter [31:0] BOARD_IP  = {8'd192,8'd168,8'd1,8'd10},
    parameter [31:0] BCAST_IP  = {8'd192,8'd168,8'd1,8'd255},
    parameter [15:0] CMD_PORT  = 16'd1235,
    parameter [31:0] MAGIC_CMD = 32'h5031_3043,   // "P10C"
    parameter [31:0] MAGIC_RSP = 32'h5031_3052    // "P10R"
)(
    // ---------------- eth_rxc domain (gmii_rx_clk, 125 MHz) ----------------
    input  wire        clk_eth,
    input  wire        rst_eth_n,      // sys_rst_n (active low)
    input  wire        gmii_rx_dv,     // RX bus parallel tap
    input  wire [7:0]  gmii_rxd,
    input  wire        tx_idle,        // stack TX (stack_tx_en) idle >= 64 clk
    output reg         resp_tx_en,     // response byte stream (muxed into pumpA)
    output reg  [7:0]  resp_txd,
    output reg         resp_busy,      // 1 = this module owns the TX mux
    output reg  [15:0] cmd_rx_cnt,     // valid command frames received
    output reg  [15:0] cmd_err_cnt,    // rejected / dropped command frames

    // ---------------- user_clk domain (151.5 MHz) ----------------
    input  wire        clk_user,
    input  wire        rst_user_n,     // ~aurora_rst (active low)
    input  wire [15:0] u_wr_frame,     // frame_mem_if.ro_u_wr_frame
    input  wire [15:0] u_rd_frame,     // frame_mem_if.ro_u_rd_frame
    input  wire [15:0] u_buf_drop,     // frame_mem_if.ro_u_buf_drop
    output reg         cfg_mode,       // 0 = SEQ, 1 = RND  -> u_mem.cfg_mode
    output reg  [7:0]  cfg_rd_slot,    //                  -> u_mem.cfg_rd_slot
    output reg         rd_req_pulse,   // single user_clk pulse: trigger one read
    output reg         cfg_wr_pulse,   // prj11 B1 additive: 1-clk strobe on
                                       // SET_MODE(ok)/READ_SLOT -- top-level
                                       // owner arbitration uses it (W5 port
                                       // contract unchanged, pure extension)
    output reg  [15:0] cmd_exec_cnt,   // commands executed in the user domain
    output reg  [15:0] rd_trig_cnt     // read triggers (= successful READ_SLOT)
);

//=============================================================================
// constants
//=============================================================================
localparam [7:0]  OP_SET_MODE   = 8'h01;
localparam [7:0]  OP_READ_SLOT  = 8'h02;
localparam [7:0]  OP_GET_WM     = 8'h03;
localparam [7:0]  OP_GET_MAP    = 8'h04;

localparam [7:0]  ST_OK         = 8'd0;    // status: OK
localparam [7:0]  ST_BADARG     = 8'd1;    // status: illegal parameter

localparam [15:0] IP_TOTAL_LEN  = 16'd40;  // 20 (IP) + 8 (UDP) + 12 (payload)
localparam [15:0] UDP_LEN       = 16'd20;  // 8 (UDP hdr) + 12 (payload)

// parser states (eth domain)
localparam [2:0] P_IDLE  = 3'd0, P_PRE   = 3'd1, P_ETH = 3'd2, P_IP = 3'd3,
                 P_UDPCHK = 3'd4, P_UDP  = 3'd5, P_PAY = 3'd6, P_END = 3'd7;

// eth-domain command FSM states
localparam [3:0] E_IDLE  = 4'd0, E_ACKW = 4'd1, E_ACKL = 4'd2, E_BW   = 4'd3,
                 E_BL    = 4'd4, E_CHK  = 4'd5, E_CRC  = 4'd6, E_TXW  = 4'd7,
                 E_TXPRE = 4'd8, E_TX   = 4'd9, E_TXE  = 4'd10;

// user-domain execution FSM states
localparam [2:0] U_IDLE  = 3'd0, U_PULSE = 3'd1, U_PULSE2 = 3'd2, U_RESP = 3'd3,
                 U_WREQL = 3'd4, U_WBACK = 3'd5, U_WBACKL = 3'd6;

// frame geometry
localparam [6:0] FRM_BODY_END = 7'd67;     // last body byte index (incl. 6B pad)
localparam [6:0] FRM_LAST     = 7'd71;     // last byte index (4th FCS byte)
localparam [6:0] CRC_FIRST    = 7'd8;      // FCS covers bytes 8..67 (60 B >= min frame)

//=============================================================================
// CRC32 helper: identical equations to the official crc32_d8.v (official file
// untouched -- reused inline so cmd_channel.v is self-contained).
//   crc  : register = bitrev32(C), C = reflected CRC-32 of the input bytes
//   data : byte, bit-reversed internally (matches official data_t)
//=============================================================================
function [31:0] crc_step(input [31:0] crc, input [7:0] data);
    reg [7:0] t;
    begin
        t = {data[0],data[1],data[2],data[3],data[4],data[5],data[6],data[7]};
        crc_step[0]  = crc[24]^crc[30]^t[0]^t[6];
        crc_step[1]  = crc[24]^crc[25]^crc[30]^crc[31]^t[0]^t[1]^t[6]^t[7];
        crc_step[2]  = crc[24]^crc[25]^crc[26]^crc[30]^crc[31]^t[0]^t[1]^t[2]^t[6]^t[7];
        crc_step[3]  = crc[25]^crc[26]^crc[27]^crc[31]^t[1]^t[2]^t[3]^t[7];
        crc_step[4]  = crc[24]^crc[26]^crc[27]^crc[28]^crc[30]^t[0]^t[2]^t[3]^t[4]^t[6];
        crc_step[5]  = crc[24]^crc[25]^crc[27]^crc[28]^crc[29]^crc[30]^crc[31]
                      ^t[0]^t[1]^t[3]^t[4]^t[5]^t[6]^t[7];
        crc_step[6]  = crc[25]^crc[26]^crc[28]^crc[29]^crc[30]^crc[31]
                      ^t[1]^t[2]^t[4]^t[5]^t[6]^t[7];
        crc_step[7]  = crc[24]^crc[26]^crc[27]^crc[29]^crc[31]^t[0]^t[2]^t[3]^t[5]^t[7];
        crc_step[8]  = crc[0]^crc[24]^crc[25]^crc[27]^crc[28]^t[0]^t[1]^t[3]^t[4];
        crc_step[9]  = crc[1]^crc[25]^crc[26]^crc[28]^crc[29]^t[1]^t[2]^t[4]^t[5];
        crc_step[10] = crc[2]^crc[24]^crc[26]^crc[27]^crc[29]^t[0]^t[2]^t[3]^t[5];
        crc_step[11] = crc[3]^crc[24]^crc[25]^crc[27]^crc[28]^t[0]^t[1]^t[3]^t[4];
        crc_step[12] = crc[4]^crc[24]^crc[25]^crc[26]^crc[28]^crc[29]^crc[30]
                      ^t[0]^t[1]^t[2]^t[4]^t[5]^t[6];
        crc_step[13] = crc[5]^crc[25]^crc[26]^crc[27]^crc[29]^crc[30]^crc[31]
                      ^t[1]^t[2]^t[3]^t[5]^t[6]^t[7];
        crc_step[14] = crc[6]^crc[26]^crc[27]^crc[28]^crc[30]^crc[31]
                      ^t[2]^t[3]^t[4]^t[6]^t[7];
        crc_step[15] = crc[7]^crc[27]^crc[28]^crc[29]^crc[31]^t[3]^t[4]^t[5]^t[7];
        crc_step[16] = crc[8]^crc[24]^crc[28]^crc[29]^t[0]^t[4]^t[5];
        crc_step[17] = crc[9]^crc[25]^crc[29]^crc[30]^t[1]^t[5]^t[6];
        crc_step[18] = crc[10]^crc[26]^crc[30]^crc[31]^t[2]^t[6]^t[7];
        crc_step[19] = crc[11]^crc[27]^crc[31]^t[3]^t[7];
        crc_step[20] = crc[12]^crc[28]^t[4];
        crc_step[21] = crc[13]^crc[29]^t[5];
        crc_step[22] = crc[14]^crc[24]^t[0];
        crc_step[23] = crc[15]^crc[24]^crc[25]^crc[30]^t[0]^t[1]^t[6];
        crc_step[24] = crc[16]^crc[25]^crc[26]^crc[31]^t[1]^t[2]^t[7];
        crc_step[25] = crc[17]^crc[26]^crc[27]^t[2]^t[3];
        crc_step[26] = crc[18]^crc[24]^crc[27]^crc[28]^crc[30]^t[0]^t[3]^t[4]^t[6];
        crc_step[27] = crc[19]^crc[25]^crc[28]^crc[29]^crc[31]^t[1]^t[4]^t[5]^t[7];
        crc_step[28] = crc[20]^crc[26]^crc[29]^crc[30]^t[2]^t[5]^t[6];
        crc_step[29] = crc[21]^crc[27]^crc[30]^crc[31]^t[3]^t[6]^t[7];
        crc_step[30] = crc[22]^crc[28]^crc[31]^t[4]^t[7];
        crc_step[31] = crc[23]^crc[29]^t[5];
    end
endfunction

function [7:0] bitrev8(input [7:0] b);
    begin
        bitrev8 = {b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7]};
    end
endfunction

//=============================================================================
// CDC: 2FF synchronizers.  Every crossing is a level (handshake) signal; the
// payload of each mailbox phase is held stable until the phase completes, so
// no multi-bit value is ever sampled while it can change.
//   mailbox A : eth  -> user : a_req / a_data[31:0]  (opcode,arg0,arg1)
//   mailbox A' : user -> eth : a_ack
//   mailbox B : user -> eth : b_req / b_data[55:0]  (status,v16,v16b,v16c)
//   mailbox B' : eth -> user : b_ack
//=============================================================================
(* ASYNC_REG = "TRUE" *) reg [1:0] a_req_s;
(* ASYNC_REG = "TRUE" *) reg [1:0] a_ack_s;
(* ASYNC_REG = "TRUE" *) reg [1:0] b_req_s;
(* ASYNC_REG = "TRUE" *) reg [1:0] b_ack_s;

reg        a_req;
reg [31:0] a_data;
reg        b_ack;

reg        a_ack;
reg        b_req;
reg [55:0] b_data;

always @(posedge clk_user or negedge rst_user_n) begin
    if(!rst_user_n) begin
        a_req_s <= 2'b00;
        b_ack_s <= 2'b00;
    end
    else begin
        a_req_s <= {a_req_s[0], a_req};
        b_ack_s <= {b_ack_s[0], b_ack};
    end
end

always @(posedge clk_eth or negedge rst_eth_n) begin
    if(!rst_eth_n) begin
        a_ack_s <= 2'b00;
        b_req_s <= 2'b00;
    end
    else begin
        a_ack_s <= {a_ack_s[0], a_ack};
        b_req_s <= {b_req_s[0], b_req};
    end
end

//=============================================================================
// eth domain: RX tap parser
//   claim = UDP & dst port == CMD_PORT & payload[0..3] == "P10C" & payload>=8B
//   error = exactly one of {port match, magic match}  (wrong port / wrong
//           magic), or both matched but the payload is short (truncated).
//   Normal data traffic (port 1234, no magic) matches neither -> ignored, so
//   the on-board counter stays clean.
//=============================================================================
reg [2:0]  pst;
reg [4:0]  pcnt;
reg [47:0] dst_mac_r, src_mac_r;
reg [15:0] eth_type_r;
reg [7:0]  ip_hlen_r;
reg        ip_ver_ok, ip_proto_ok, dst_ip_ok_r;
reg [31:0] dst_ip_r, src_ip_r;
reg [15:0] dst_port_r, src_port_r, udp_len_r;
reg        port_match, magic_ok, magic_pref;
reg [31:0] magic_r;
reg [7:0]  pay_op, pay_a0, pay_a1l, pay_a1h;
reg        pay_seen;

// cmd_hold 只由解析块(block A)写; 执行块(block B)用 cmd_take 单拍交回清零
// (2026-10-07 修: 原两块同时写 cmd_hold -> DRC MDRV-1 多驱动, 单元仿真未暴露)
reg        cmd_hold, cmd_claim, cmd_take;
reg [47:0] cmd_smac;
reg [31:0] cmd_sip;
reg [15:0] cmd_sport;
reg [7:0]  cmd_op, cmd_a0;
reg [15:0] cmd_a1;

reg [3:0]  est;                    // eth command FSM state

// response header fields latched from the command frame
reg [7:0]  x_op, status_r;
reg [15:0] v16_r, v16b_r, v16c_r;
reg [47:0] x_smac;
reg [31:0] x_sip;
reg [15:0] x_sport;
reg [15:0] ip_id_r, ip_ck_r;
reg [31:0] crc_data;
reg [6:0]  ci;                     // CRC pass index
reg [6:0]  ti;                     // TX byte index

function [7:0] magic_byte(input [1:0] k);
    begin
        case(k)
            2'd0: magic_byte = MAGIC_CMD[31:24];
            2'd1: magic_byte = MAGIC_CMD[23:16];
            2'd2: magic_byte = MAGIC_CMD[15:8];
            default: magic_byte = MAGIC_CMD[7:0];
        endcase
    end
endfunction

wire dw_ok      = (dst_mac_r == BOARD_MAC) || (dst_mac_r == BCAST_MAC);
wire pay_len_ok = (udp_len_r >= 16'd16);   // 8 (UDP hdr) + 8 (min payload)

//=============================================================================
// IP header checksum over the 20 header bytes emitted by this module
//=============================================================================
wire [15:0] ck_w0 = 16'h4500;
wire [15:0] ck_w1 = IP_TOTAL_LEN;
wire [15:0] ck_w2 = ip_id_r + 16'd1;              // id used by this response
wire [15:0] ck_w3 = 16'h4000;
wire [15:0] ck_w4 = {8'h40, 8'd17};
wire [15:0] ck_w5 = 16'h0000;                     // checksum field itself
wire [15:0] ck_w6 = BOARD_IP[31:16];
wire [15:0] ck_w7 = BOARD_IP[15:0];
wire [15:0] ck_w8 = x_sip[31:16];
wire [15:0] ck_w9 = x_sip[15:0];
wire [19:0] ck_sum0 = ck_w0 + ck_w1 + ck_w2 + ck_w3 + ck_w4
                    + ck_w5 + ck_w6 + ck_w7 + ck_w8 + ck_w9;
wire [16:0] ck_sum1 = ck_sum0[15:0] + {14'd0, ck_sum0[19:16]};
wire [16:0] ck_sum2 = ck_sum1[15:0] + {16'd0, ck_sum1[16]};
wire [15:0] ip_ck_c = ~ck_sum2[15:0];

//=============================================================================
// response frame byte generator (index = order on the wire)
//=============================================================================
function [7:0] byte_at(input [6:0] i);
    begin
        case(i)
            7'd0,7'd1,7'd2,7'd3,7'd4,7'd5,7'd6: byte_at = 8'h55;
            7'd7 : byte_at = 8'hD5;
            7'd8 : byte_at = x_smac[47:40];
            7'd9 : byte_at = x_smac[39:32];
            7'd10: byte_at = x_smac[31:24];
            7'd11: byte_at = x_smac[23:16];
            7'd12: byte_at = x_smac[15:8];
            7'd13: byte_at = x_smac[7:0];
            7'd14: byte_at = BOARD_MAC[47:40];
            7'd15: byte_at = BOARD_MAC[39:32];
            7'd16: byte_at = BOARD_MAC[31:24];
            7'd17: byte_at = BOARD_MAC[23:16];
            7'd18: byte_at = BOARD_MAC[15:8];
            7'd19: byte_at = BOARD_MAC[7:0];
            7'd20: byte_at = 8'h08;
            7'd21: byte_at = 8'h00;
            7'd22: byte_at = 8'h45;                     // IPv4, IHL=5
            7'd23: byte_at = 8'h00;
            7'd24: byte_at = IP_TOTAL_LEN[15:8];
            7'd25: byte_at = IP_TOTAL_LEN[7:0];
            7'd26: byte_at = ip_id_r[15:8];
            7'd27: byte_at = ip_id_r[7:0];
            7'd28: byte_at = 8'h40;                     // DF
            7'd29: byte_at = 8'h00;
            7'd30: byte_at = 8'h40;                     // TTL 64
            7'd31: byte_at = 8'd17;                     // proto UDP
            7'd32: byte_at = ip_ck_r[15:8];
            7'd33: byte_at = ip_ck_r[7:0];
            7'd34: byte_at = BOARD_IP[31:24];
            7'd35: byte_at = BOARD_IP[23:16];
            7'd36: byte_at = BOARD_IP[15:8];
            7'd37: byte_at = BOARD_IP[7:0];
            7'd38: byte_at = x_sip[31:24];
            7'd39: byte_at = x_sip[23:16];
            7'd40: byte_at = x_sip[15:8];
            7'd41: byte_at = x_sip[7:0];
            7'd42: byte_at = CMD_PORT[15:8];            // src port 1235
            7'd43: byte_at = CMD_PORT[7:0];
            7'd44: byte_at = x_sport[15:8];             // dst = cmd src port
            7'd45: byte_at = x_sport[7:0];
            7'd46: byte_at = UDP_LEN[15:8];             // 20
            7'd47: byte_at = UDP_LEN[7:0];
            7'd48: byte_at = 8'h00;                     // UDP checksum = 0
            7'd49: byte_at = 8'h00;
            7'd50: byte_at = MAGIC_RSP[31:24];          // "P10R"
            7'd51: byte_at = MAGIC_RSP[23:16];
            7'd52: byte_at = MAGIC_RSP[15:8];
            7'd53: byte_at = MAGIC_RSP[7:0];
            7'd54: byte_at = x_op;
            7'd55: byte_at = status_r;
            7'd56: byte_at = v16_r[7:0];                // little endian
            7'd57: byte_at = v16_r[15:8];
            7'd58: byte_at = v16b_r[7:0];
            7'd59: byte_at = v16b_r[15:8];
            7'd60: byte_at = v16c_r[7:0];
            7'd61: byte_at = v16c_r[15:8];
            default: byte_at = 8'h00;
        endcase
    end
endfunction

function [7:0] fcs_byte(input [1:0] k);
    begin
        case(k)
            2'd0: fcs_byte = bitrev8(~crc_data[31:24]);
            2'd1: fcs_byte = bitrev8(~crc_data[23:16]);
            2'd2: fcs_byte = bitrev8(~crc_data[15:8]);
            default: fcs_byte = bitrev8(~crc_data[7:0]);
        endcase
    end
endfunction

//=============================================================================
// parser (eth domain)
//=============================================================================
always @(posedge clk_eth or negedge rst_eth_n) begin
    if(!rst_eth_n) begin
        pst         <= P_IDLE;
        pcnt        <= 5'd0;
        dst_mac_r   <= 48'd0;
        src_mac_r   <= 48'd0;
        eth_type_r  <= 16'd0;
        ip_hlen_r   <= 8'd0;
        ip_ver_ok   <= 1'b0;
        ip_proto_ok <= 1'b0;
        dst_ip_ok_r <= 1'b0;
        dst_ip_r    <= 32'd0;
        src_ip_r    <= 32'd0;
        dst_port_r  <= 16'd0;
        src_port_r  <= 16'd0;
        udp_len_r   <= 16'd0;
        port_match  <= 1'b0;
        magic_ok    <= 1'b0;
        magic_pref  <= 1'b0;
        magic_r     <= 32'd0;
        pay_op      <= 8'd0;
        pay_a0      <= 8'd0;
        pay_a1l     <= 8'd0;
        pay_a1h     <= 8'd0;
        pay_seen    <= 1'b0;
        cmd_hold    <= 1'b0;
        cmd_claim   <= 1'b0;
        cmd_smac    <= 48'd0;
        cmd_sip     <= 32'd0;
        cmd_sport   <= 16'd0;
        cmd_op      <= 8'd0;
        cmd_a0      <= 8'd0;
        cmd_a1      <= 16'd0;
        cmd_rx_cnt  <= 16'd0;
        cmd_err_cnt <= 16'd0;
    end
    else begin
        cmd_claim <= 1'b0;
        if(cmd_take) cmd_hold <= 1'b0;   // 执行块已取走（cmd_hold 只有本块写）

        case(pst)
        //------------------------------------------------ frame start
        P_IDLE: begin
            if(gmii_rx_dv) begin
                pcnt <= 5'd0;
                if(gmii_rxd == 8'h55) begin
                    pst <= P_PRE;                       // preamble present
                end
                else begin
                    // preamble-tolerant start: first byte is dst MAC[47:40]
                    pst         <= P_ETH;
                    pcnt        <= 5'd1;
                    dst_mac_r   <= {40'd0, gmii_rxd};
                    src_mac_r   <= 48'd0;
                    eth_type_r  <= 16'd0;
                    port_match  <= 1'b0;
                    magic_ok    <= 1'b0;
                    magic_pref  <= 1'b0;
                    pay_seen    <= 1'b0;
                end
            end
        end
        //------------------------------------------------ preamble 7x55+d5
        P_PRE: begin
            if(!gmii_rx_dv) begin
                pst <= P_IDLE;                          // runt / aborted
            end
            else if(gmii_rxd == 8'h55) begin
                pst <= P_PRE;
            end
            else if(gmii_rxd == 8'hD5) begin
                pst         <= P_ETH;
                pcnt        <= 5'd0;
                src_mac_r   <= 48'd0;
                eth_type_r  <= 16'd0;
                port_match  <= 1'b0;
                magic_ok    <= 1'b0;
                magic_pref  <= 1'b0;
                pay_seen    <= 1'b0;
            end
            else begin
                pst <= P_END;                           // bad preamble
            end
        end
        //------------------------------------------------ eth header (14 B)
        P_ETH: begin
            if(!gmii_rx_dv) begin
                pst <= P_IDLE;
            end
            else if(pcnt < 5'd6) begin
                dst_mac_r <= {dst_mac_r[39:0], gmii_rxd};
                pcnt      <= pcnt + 5'd1;
            end
            else if(pcnt < 5'd12) begin
                src_mac_r <= {src_mac_r[39:0], gmii_rxd};
                pcnt      <= pcnt + 5'd1;
            end
            else if(pcnt == 5'd12) begin
                eth_type_r[15:8] <= gmii_rxd;
                pcnt             <= pcnt + 5'd1;
            end
            else begin                                  // pcnt == 13
                eth_type_r[7:0] <= gmii_rxd;
                if(dw_ok && (eth_type_r[15:8] == 8'h08) && (gmii_rxd == 8'h00)) begin
                    pst  <= P_IP;
                    pcnt <= 5'd0;
                end
                else begin
                    pst <= P_END;                       // not an IPv4 frame for us
                end
            end
        end
        //------------------------------------------------ IP header (IHL>=5)
        P_IP: begin
            if(!gmii_rx_dv) begin
                pst <= P_IDLE;
            end
            else if((pcnt == 5'd0) && (gmii_rxd[7:4] != 4'h4)) begin
                pst <= P_END;                           // not IPv4
            end
            else begin
                if(pcnt == 5'd0) begin
                    ip_hlen_r <= {gmii_rxd[3:0], 2'b00};
                    ip_ver_ok <= 1'b1;
                end
                else if(pcnt == 5'd9) begin
                    ip_proto_ok <= (gmii_rxd == 8'd17);
                end
                else if(pcnt == 5'd12) begin
                    src_ip_r <= {src_ip_r[23:0], gmii_rxd};
                end
                else if(pcnt == 5'd13) begin
                    src_ip_r <= {src_ip_r[23:0], gmii_rxd};
                end
                else if(pcnt == 5'd14) begin
                    src_ip_r <= {src_ip_r[23:0], gmii_rxd};
                end
                else if(pcnt == 5'd15) begin
                    src_ip_r <= {src_ip_r[23:0], gmii_rxd};
                end
                else if(pcnt == 5'd16) begin
                    dst_ip_r <= {dst_ip_r[23:0], gmii_rxd};
                end
                else if(pcnt == 5'd17) begin
                    dst_ip_r <= {dst_ip_r[23:0], gmii_rxd};
                end
                else if(pcnt == 5'd18) begin
                    dst_ip_r <= {dst_ip_r[23:0], gmii_rxd};
                end
                else if(pcnt == 5'd19) begin
                    dst_ip_r    <= {dst_ip_r[23:0], gmii_rxd};
                    dst_ip_ok_r <= (({dst_ip_r[23:0], gmii_rxd} == BOARD_IP) ||
                                    ({dst_ip_r[23:0], gmii_rxd} == BCAST_IP));
                end
                else begin
                    ;                                   // IP options: skipped
                end

                if(pcnt == (ip_hlen_r - 5'd1)) begin
                    pst <= P_UDPCHK;                    // verdict on next byte
                end
                else begin
                    pcnt <= pcnt + 5'd1;
                end
            end
        end
        //------------------------------------------------ IP verdict + UDP byte 0
        // (the verdict is taken on the cycle of the FIRST UDP byte so that the
        //  byte alignment is never disturbed by a wait state)
        P_UDPCHK: begin
            if(!gmii_rx_dv) begin
                pst <= P_IDLE;
            end
            else if(ip_ver_ok && ip_proto_ok && dst_ip_ok_r && (ip_hlen_r >= 8'd20)) begin
                src_port_r[15:8] <= gmii_rxd;           // UDP header byte 0 = src port
                pcnt             <= 5'd1;
                pst              <= P_UDP;
            end
            else begin
                pst <= P_END;
            end
        end
        //------------------------------------------------ UDP header (8 B)
        P_UDP: begin
            if(!gmii_rx_dv) begin
                if(port_match || magic_pref) cmd_err_cnt <= cmd_err_cnt + 16'd1;
                pst <= P_IDLE;
            end
            else begin
                case(pcnt)
                5'd1: src_port_r[7:0]  <= gmii_rxd;      // src port low
                5'd2: dst_port_r[15:8] <= gmii_rxd;      // dst port high
                5'd3: begin
                    dst_port_r[7:0] <= gmii_rxd;         // dst port low
                    port_match      <= ({dst_port_r[15:8], gmii_rxd} == CMD_PORT);
                end
                5'd4: udp_len_r[15:8]  <= gmii_rxd;
                5'd5: udp_len_r[7:0]   <= gmii_rxd;
                default: ;                              // checksum ignored
                endcase

                if(pcnt == 5'd7) begin
                    pst        <= P_PAY;
                    pcnt       <= 5'd0;
                    magic_r    <= 32'd0;
                    magic_pref <= 1'b1;
                    pay_seen   <= 1'b0;
                end
                else begin
                    pcnt <= pcnt + 5'd1;
                end
            end
        end
        //------------------------------------------------ UDP payload (>=8 B)
        P_PAY: begin
            if(!gmii_rx_dv) begin
                // frame ended before the command was complete
                if(!pay_seen && (port_match || magic_pref)) begin
                    cmd_err_cnt <= cmd_err_cnt + 16'd1;
                end
                pst <= P_IDLE;
            end
            else if(pay_seen) begin
                pst <= P_END;                           // trailing payload
            end
            else begin
                case(pcnt)
                5'd0: begin
                    magic_r    <= {magic_r[23:0], gmii_rxd};
                    magic_pref <= magic_pref && (gmii_rxd == magic_byte(2'd0));
                end
                5'd1: begin
                    magic_r    <= {magic_r[23:0], gmii_rxd};
                    magic_pref <= magic_pref && (gmii_rxd == magic_byte(2'd1));
                end
                5'd2: begin
                    magic_r    <= {magic_r[23:0], gmii_rxd};
                    magic_pref <= magic_pref && (gmii_rxd == magic_byte(2'd2));
                end
                5'd3: begin
                    magic_r    <= {magic_r[23:0], gmii_rxd};
                    magic_ok   <= ({magic_r[23:0], gmii_rxd} == MAGIC_CMD);
                end
                5'd4: pay_op  <= gmii_rxd;
                5'd5: pay_a0  <= gmii_rxd;
                5'd6: pay_a1l <= gmii_rxd;
                5'd7: pay_a1h <= gmii_rxd;
                default: ;
                endcase

                if(pcnt == 5'd7) begin
                    pay_seen <= 1'b1;
                    pcnt     <= 5'd0;
                    if(port_match && magic_ok && pay_len_ok) begin
                        cmd_rx_cnt <= cmd_rx_cnt + 16'd1;
                        if((est == E_IDLE) && !cmd_hold) begin
                            cmd_hold  <= 1'b1;
                            cmd_claim <= 1'b1;
                            cmd_smac  <= src_mac_r;
                            cmd_sip   <= src_ip_r;
                            cmd_sport <= src_port_r;
                            cmd_op    <= pay_op;
                            cmd_a0    <= pay_a0;
                            cmd_a1    <= {pay_a1h, pay_a1l};
                        end
                        else begin
                            // Appendix v1.1 (defensive): a response is still in
                            // flight -> drop the new command, never clobber it
                            cmd_err_cnt <= cmd_err_cnt + 16'd1;
                        end
                    end
                    else if(port_match || magic_ok) begin
                        cmd_err_cnt <= cmd_err_cnt + 16'd1;
                    end
                    else begin
                        ;                               // not a command frame
                    end
                end
                else begin
                    pcnt <= pcnt + 5'd1;
                end
            end
        end
        //------------------------------------------------ drain to frame end
        P_END: begin
            if(!gmii_rx_dv) pst <= P_IDLE;
        end
        default: pst <= P_IDLE;
        endcase
    end
end

//=============================================================================
// eth domain: command FSM + response frame TX
//=============================================================================
wire [6:0] ti_next   = (ti == FRM_LAST) ? FRM_LAST : (ti + 7'd1);
wire [7:0] ti_next_b = (ti_next <= FRM_BODY_END) ? byte_at(ti_next) :
                       (ti_next == 7'd68) ? fcs_byte(2'd0) :
                       (ti_next == 7'd69) ? fcs_byte(2'd1) :
                       (ti_next == 7'd70) ? fcs_byte(2'd2) : fcs_byte(2'd3);

always @(posedge clk_eth or negedge rst_eth_n) begin
    if(!rst_eth_n) begin
        est        <= E_IDLE;
        a_req      <= 1'b0;
        a_data     <= 32'd0;
        b_ack      <= 1'b0;
        x_op       <= 8'd0;
        status_r   <= 8'd0;
        v16_r      <= 16'd0;
        v16b_r     <= 16'd0;
        v16c_r     <= 16'd0;
        x_smac     <= 48'd0;
        x_sip      <= 32'd0;
        x_sport    <= 16'd0;
        ip_id_r    <= 16'd0;
        ip_ck_r    <= 16'd0;
        crc_data   <= 32'hFFFF_FFFF;
        ci         <= 7'd0;
        ti         <= 7'd0;
        resp_tx_en <= 1'b0;
        resp_txd   <= 8'd0;
        resp_busy  <= 1'b0;
        cmd_take   <= 1'b0;
    end
    else begin
        cmd_take <= 1'b0;
        case(est)
        //------------------------------------------------ idle
        E_IDLE: begin
            resp_tx_en <= 1'b0;
            resp_busy  <= 1'b0;
            if(cmd_hold) begin
                cmd_take <= 1'b1;      // 交回解析块清 cmd_hold（避免多驱动）
                x_op     <= cmd_op;
                x_smac   <= cmd_smac;
                x_sip    <= cmd_sip;
                x_sport  <= cmd_sport;
                a_data   <= {cmd_op, cmd_a0, cmd_a1};
                a_req    <= 1'b1;
                est      <= E_ACKW;
            end
        end
        //------------------------------------------------ mailbox A (down)
        E_ACKW: begin
            if(a_ack_s[1]) begin
                a_req <= 1'b0;
                est   <= E_ACKL;
            end
        end
        E_ACKL: begin
            if(!a_ack_s[1]) est <= E_BW;
        end
        //------------------------------------------------ mailbox B (back)
        E_BW: begin
            if(b_req_s[1]) begin
                status_r <= b_data[55:48];
                v16_r    <= b_data[47:32];
                v16b_r   <= b_data[31:16];
                v16c_r   <= b_data[15:0];
                b_ack    <= 1'b1;
                est      <= E_BL;
            end
        end
        E_BL: begin
            if(!b_req_s[1]) begin
                b_ack <= 1'b0;
                est   <= E_CHK;
            end
        end
        //------------------------------------------------ IP checksum + CRC init
        E_CHK: begin
            ip_id_r  <= ip_id_r + 16'd1;
            ip_ck_r  <= ip_ck_c;
            crc_data <= 32'hFFFF_FFFF;
            ci       <= CRC_FIRST;
            est      <= E_CRC;
        end
        //------------------------------------------------ FCS pass (bytes 8..61)
        E_CRC: begin
            crc_data <= crc_step(crc_data, byte_at(ci));
            if(ci == FRM_BODY_END) est <= E_TXW;
            else                   ci  <= ci + 7'd1;
        end
        //------------------------------------------------ wait for TX window
        E_TXW: begin
            if(tx_idle) begin
                resp_busy <= 1'b1;                      // Appendix v1.1 gate
                est       <= E_TXPRE;
            end
        end
        //------------------------------------------------ 1-cycle settling
        // (top-level mux register cmd_takeover rises one clk after resp_busy)
        E_TXPRE: begin
            resp_busy  <= 1'b1;
            resp_tx_en <= 1'b1;                         // high from next clk
            resp_txd   <= byte_at(7'd0);
            ti         <= 7'd0;
            est        <= E_TX;
        end
        //------------------------------------------------ byte stream (gapless)
        E_TX: begin
            resp_busy  <= 1'b1;
            resp_tx_en <= 1'b1;
            resp_txd   <= ti_next_b;
            ti         <= ti_next;
            if(ti == FRM_LAST) begin
                resp_tx_en <= 1'b0;                     // last byte emitted now
                est        <= E_TXE;
            end
        end
        E_TXE: begin
            resp_tx_en <= 1'b0;
            resp_busy  <= 1'b0;                         // release after last byte
            est        <= E_IDLE;
        end
        default: est <= E_IDLE;
        endcase
    end
end

//=============================================================================
// user domain: execute the command, then publish the 12-byte reply payload
//   SET_MODE(0x01)      : arg0 0/1 -> cfg_mode (else status = 1)
//   READ_SLOT(0x02)     : cfg_mode <= 1, cfg_rd_slot <= arg0 (stable >= 1 clk),
//                         then ONE rd_req_pulse; v16 = slot, v16b = trigger seq
//   GET_WATERMARK(0x03) : v16 = u_wr_frame, v16b = u_rd_frame, v16c = u_buf_drop
//   GET_SLOT_MAP(0x04)  : v16 = u_wr_frame, v16b = u_wr_frame[7:0], v16c = 1
//=============================================================================
reg [2:0]  ust;
reg [31:0] ucmd;
reg [7:0]  u_op, u_a0, u_status;
reg [15:0] u_v16, u_v16b, u_v16c;

always @(posedge clk_user or negedge rst_user_n) begin
    if(!rst_user_n) begin
        ust          <= U_IDLE;
        a_ack        <= 1'b0;
        b_req        <= 1'b0;
        b_data       <= 56'd0;
        ucmd         <= 32'd0;
        u_op         <= 8'd0;
        u_a0         <= 8'd0;
        u_status     <= 8'd0;
        u_v16        <= 16'd0;
        u_v16b       <= 16'd0;
        u_v16c       <= 16'd0;
        cfg_mode     <= 1'b0;               // SEQ after reset
        cfg_rd_slot  <= 8'd0;
        rd_req_pulse <= 1'b0;
        cfg_wr_pulse <= 1'b0;               // prj11 B1 additive
        cmd_exec_cnt <= 16'd0;
        rd_trig_cnt  <= 16'd0;
    end
    else begin
        rd_req_pulse <= 1'b0;
        cfg_wr_pulse <= 1'b0;               // prj11 B1 additive (default clear)
        case(ust)
        //------------------------------------------------ wait for a command
        U_IDLE: begin
            if(a_req_s[1]) begin
                ucmd     <= a_data;                     // stable during phase
                u_op     <= a_data[31:24];
                u_a0     <= a_data[23:16];
                u_status <= ST_OK;
                u_v16    <= 16'd0;
                u_v16b   <= 16'd0;
                u_v16c   <= 16'd0;
                case(a_data[31:24])
                OP_SET_MODE: begin
                    if(a_data[23:16] <= 8'd1) begin
                        cfg_mode <= a_data[16];
                        cfg_wr_pulse <= 1'b1;          // prj11 B1 additive
                    end
                    else                      u_status <= ST_BADARG;
                    ust <= U_RESP;
                end
                OP_READ_SLOT: begin
                    cfg_mode    <= 1'b1;                // random read mode
                    cfg_rd_slot <= a_data[23:16];       // 0..255 (256 slots)
                    cfg_wr_pulse <= 1'b1;               // prj11 B1 additive
                    u_v16       <= {8'd0, a_data[23:16]};
                    u_v16b      <= rd_trig_cnt + 16'd1; // trigger sequence
                    ust         <= U_PULSE;             // cfg settles first
                end
                OP_GET_WM: begin
                    u_v16  <= u_wr_frame;
                    u_v16b <= u_rd_frame;
                    u_v16c <= u_buf_drop;
                    ust    <= U_RESP;
                end
                OP_GET_MAP: begin
                    u_v16  <= u_wr_frame;
                    u_v16b <= {8'd0, u_wr_frame[7:0]};  // write slot = frame%256
                    u_v16c <= 16'd1;                    // mapping rule id = 1
                    ust    <= U_RESP;
                end
                default: begin
                    u_status <= ST_BADARG;
                    ust      <= U_RESP;
                end
                endcase
            end
        end
        //------------------------------------------------ one-clk read pulse
        U_PULSE: begin
            rd_req_pulse <= 1'b1;                       // cfg stable >= 1 clk
            rd_trig_cnt  <= rd_trig_cnt + 16'd1;
            ust          <= U_PULSE2;
        end
        U_PULSE2: begin
            rd_req_pulse <= 1'b0;
            ust          <= U_RESP;
        end
        //------------------------------------------------ publish reply + ack
        U_RESP: begin
            b_data       <= {u_status, u_v16, u_v16b, u_v16c};
            b_req        <= 1'b1;
            a_ack        <= 1'b1;
            cmd_exec_cnt <= cmd_exec_cnt + 16'd1;
            ust          <= U_WREQL;
        end
        //------------------------------------------------ close mailbox A
        U_WREQL: begin
            if(!a_req_s[1]) begin
                a_ack <= 1'b0;
                ust   <= U_WBACK;
            end
        end
        //------------------------------------------------ close mailbox B
        U_WBACK: begin
            if(b_ack_s[1]) begin
                b_req <= 1'b0;
                ust   <= U_WBACKL;
            end
        end
        U_WBACKL: begin
            if(!b_ack_s[1]) ust <= U_IDLE;
        end
        default: ust <= U_IDLE;
        endcase
    end
end

endmodule
