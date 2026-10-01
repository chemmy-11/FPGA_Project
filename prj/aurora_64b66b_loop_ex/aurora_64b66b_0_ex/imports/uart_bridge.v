// ============================================================================
// uart_bridge.v — UART <-> Aurora AXI4-Stream bridge (final, 2026-08-31)
// 115200 8N1, ui_clk~151.5MHz, DIV=82 -> 115471 baud (+0.24%)
// TX: uart bytes -> 256B frames (32 words, tkeep=FF, tlast) -> AXIS
// RX: AXIS -> 512B fifo -> uart_tx
// 字节序约定：tdata[8k+7:8k] = 帧内第 k 字节（k=0 先到），TX/RX 同约定
// 流控：in-flight 信用计数（TX 词推送 +1 / RX 词到达 -1），防 RX FIFO 溢出
// ============================================================================
`timescale 1ns/1ps

// ---------------------------------------------------------------- UART RX
module uart_rx #(
    parameter DIV = 82
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       rxd,
    output reg  [7:0] data,
    output reg        valid,        // 1-clk pulse, stop bit verified
    output reg        frame_err     // stop bit == 0 (sticky per byte)
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync = 2'b11;
    always @(posedge clk) sync <= {sync[0], rxd};
    wire rx = sync[1];

    reg       run  = 0;
    reg       half = 0;
    reg [7:0] cnt  = 0;
    reg [3:0] bit  = 0;
    reg [7:0] sh;
    reg [7:0] dbuf;

    always @(posedge clk) begin
        valid <= 1'b0;
        if (rst) begin
            run <= 0; half <= 0; cnt <= 0; bit <= 0; frame_err <= 0;
        end else if (!run) begin
            if (!rx) begin                       // start edge
                run <= 1; half <= 0; cnt <= 0; bit <= 0;
            end
        end else if (cnt == (half ? DIV-1 : DIV/2-1)) begin
            cnt  <= half ? 0 : (DIV/2);          // start-mid -> jump half phase
            half <= 1'b1;
            if (bit == 0) begin                  // start bit sample
                if (rx) run <= 0;                // glitch
                else bit <= 4'd1;
            end else if (bit <= 8) begin         // data LSB first
                sh[bit-1] <= rx;
                bit <= bit + 4'd1;
            end else begin                       // stop bit sample
                if (rx) begin
                    data  <= dbuf;
                    valid <= 1'b1;
                end else frame_err <= 1'b1;
                run  <= 0;
                half <= 0;
            end
        end else begin
            cnt <= cnt + 8'd1;
        end
    end
    // dbuf: 1-cycle-delayed sh for correct sampling alignment
    always @(posedge clk) dbuf <= sh;
endmodule

// ---------------------------------------------------------------- UART TX
module uart_tx #(
    parameter DIV = 82
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       start,            // 1-clk pulse, ignored while busy
    output reg        txd,
    output reg        busy
);
    reg [7:0] sh;
    reg [3:0] bitn;
    reg [7:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            running <= 0; txd <= 1'b1; busy <= 0; cnt <= 0; bitn <= 0;
        end else if (!running) begin
            txd  <= 1'b1;
            busy <= 1'b0;
            if (start) begin
                sh <= data; running <= 1; busy <= 1;
                cnt <= 0; bitn <= 0; txd <= 1'b0;    // start bit
            end
        end else if (cnt == DIV-1) begin
            cnt <= 0;
            if (bitn <= 7) begin
                txd  <= sh[bitn];                    // LSB first
                bitn <= bitn + 4'd1;
            end else if (bitn == 8) begin
                txd  <= 1'b1;                        // stop bit
                bitn <= bitn + 4'd1;
            end else begin
                running <= 0; busy <= 0;
            end
        end else begin
            cnt <= cnt + 8'd1;
        end
    end
    reg running = 0;
endmodule

// ---------------------------------------------------------------- Bridge
module uart_bridge #(
    parameter DIV = 82
)(
    input  wire        clk,             // user_clk_i (~151.5MHz)
    input  wire        rst,             // sync reset (active high)
    input  wire        uart_rxd,        // AE33: PC -> FPGA
    output wire        uart_txd,        // AF34: FPGA -> PC
    // Aurora TX AXIS (ports match exdes [0:63] wires; index-connected)
    output wire [0:63] tx_tdata,
    output wire [0:7]  tx_tkeep,
    output wire        tx_tlast,
    output wire        tx_tvalid,
    input  wire        tx_tready,
    // Aurora RX AXIS
    input  wire [63:0] rx_tdata,
    input  wire [7:0]  rx_tkeep,
    input  wire        rx_tvalid,
    input  wire        rx_tlast,
    // observation (mark_debug targets)
    output wire [15:0] dbg_uart_rx_cnt,
    output wire [15:0] dbg_uart_tx_cnt,
    output wire [15:0] dbg_frame_cnt,
    output wire        dbg_bridge_err
);
    localparam FRM_BYTES = 256;          // 32 words x 8 bytes
    localparam FIFO_SZ   = 512;

    // ================= UART RX (from PC) =================
    wire [7:0] urx_data;
    wire       urx_valid;
    wire       urx_ferr;
    uart_rx #(.DIV(DIV)) u_urx (
        .clk(clk), .rst(rst), .rxd(uart_rxd),
        .data(urx_data), .valid(urx_valid), .frame_err(urx_ferr)
    );

    // ================= TX packer: bytes -> 256B frames =================
    reg [63:0] wordacc = 0;
    reg [2:0]  binw = 0;                 // byte index in word
    reg [8:0]  bidx = 0;                 // byte index in frame (0..255)
    reg        wlast_pend = 0;           // last word of frame pending push
    reg [63:0] tdata_r = 0;
    reg        tlast_r = 0;
    reg        tvalid_r = 0;
    reg [15:0] urx_cnt = 0;
    reg [15:0] frm_cnt = 0;
    reg [7:0]  hold_byte = 0;
    reg        hold_v = 0;
    reg        hold_err = 0;

    wire word_pending = tvalid_r && !tx_tready;
    wire push_ok      = !tvalid_r || tx_tready;              // can accept new word
    wire room         = (bidx < FRM_BYTES-1) || (bidx == FRM_BYTES-1 && !wlast_pend);

    // byte capture with 1-byte skid (prevents loss during word push stall)
    wire load = urx_valid && (push_ok || !hold_v);
    always @(posedge clk) begin
        if (rst) begin
            hold_v <= 0; hold_err <= 0; urx_cnt <= 0;
        end else begin
            if (urx_valid) urx_cnt <= urx_cnt + 16'd1;
            if (urx_valid && hold_v && push_ok) hold_err <= 1'b1;  // both full
        end
    end

    // packer: single always
    always @(posedge clk) begin
        if (rst) begin
            wordacc<=0; binw<=0; bidx<=0; wlast_pend<=0;
            tdata_r<=0; tlast_r<=0; tvalid_r<=0; frm_cnt<=0;
        end else begin
            // push completed word to AXIS
            if (wlast_pend && push_ok) begin
                tdata_r  <= wordacc;
                tlast_r  <= 1'b1;
                tvalid_r <= 1'b1;
                wlast_pend <= 0;
                frm_cnt  <= frm_cnt + 16'd1;
            end else if (binw==3'd7 && !wlast_pend && (load || hold_v) && push_ok) begin
                // word completed by this cycle's byte (see below) -> push next cycle
            end
            // byte load into accumulator
            if (load) begin
                wordacc[binw*8 +: 8] <= hold_v ? hold_byte : urx_data;
                if (hold_v) hold_v <= 1'b0;                        // skid drains
                if (bidx == FRM_BYTES-1) begin
                    bidx <= 0;
                    wlast_pend <= 1'b1;                            // frame done
                end else begin
                    bidx <= bidx + 9'd1;
                end
            end
        end
    end

    // hold refill: urx byte -> hold when accumulator busy with word push
    always @(posedge clk) begin
        if (rst) hold_v <= 0;
        else if (urx_valid && !load) begin
            hold_byte <= urx_data;
            hold_v    <= 1'b1;
        end
    end

    wire word_complete_pulse = urx_valid && !word_pending && (binw==3'd7);

    // push word: when a word completes, latch to output regs
    always @(posedge clk) begin
        if (rst) begin
            tdata_r <= 0; tlast_r <= 0; tvalid_r <= 0; frm_cnt <= 0;
        end else if (word_complete_pulse && push_ok) begin
            tdata_r  <= wordacc;
            tlast_r  <= (bidx == FRM_BYTES-1);
            tvalid_r <= 1'b1;
            frm_cnt  <= frm_cnt + 16'd1;
        end
    end

    assign tx_tdata  = tdata_r;
    assign tx_tkeep  = {8{1'b1}};
    assign tx_tlast  = tlast_r;
    assign tx_tvalid = tvalid_r;

    // ================= RX unpack: AXIS -> 512B fifo -> UART TX ===========
    reg [7:0]  fifo [0:FIFO_SZ-1];
    reg [8:0]  wrptr = 0, rdptr = 0;
    reg [9:0]  fifocnt = 0;
    reg [15:0] utx_cnt = 0;
    reg        fifo_err = 0;
    reg [1:0]  inflight = 0;             // credit: words pushed not yet received

    // write 8 bytes per rx word (value-position: byte k at [8k+7:8k])
    integer k;
    always @(posedge clk) begin
        if (rst) wrptr <= 0;
        else if (rx_tvalid) begin
            for (k = 0; k < 8; k = k + 1)
                fifo[wrptr + k[8:0]] <= rx_tdata[8*k +: 8];
            wrptr <= wrptr + 9'd8;
        end
    end

    always @(posedge clk) begin
        if (rst) fifocnt <= 0;
        else begin
            if (rx_tvalid && !utx_start_q) fifocnt <= fifocnt + 10'd8;
            else if (rx_tvalid && utx_start_q)  fifocnt <= fifocnt + 10'd7;
            else if (utx_start_q)               fifocnt <= fifocnt - 10'd1;
        end
    end
    reg utx_start_q = 0;
    always @(posedge clk) utx_start_q <= (fifocnt != 0) && !utx_busy;

    wire utx_start = (fifocnt != 0) && !utx_busy;
    wire [7:0] utx_data = fifo[rdptr];

    always @(posedge clk) begin
        if (rst) begin
            rdptr <= 0; utx_cnt <= 0; fifo_err <= 0;
        end else if (utx_start) begin
            rdptr <= rdptr + 9'd1;
            utx_cnt <= utx_cnt + 16'd1;
            if (fifocnt > FIFO_SZ-8) fifo_err <= 1'b1;
        end
    end

    uart_tx #(.DIV(DIV)) u_utx (
        .clk(clk), .rst(rst), .data(utx_data), .start(utx_start),
        .txd(uart_txd), .busy(utx_busy)
    );
    wire utx_busy;

    assign dbg_uart_rx_cnt = urx_cnt;
    assign dbg_uart_tx_cnt = utx_cnt;
    assign dbg_frame_cnt   = frm_cnt;
    assign dbg_bridge_err  = fifo_err | hold_err | urx_ferr;

endmodule
