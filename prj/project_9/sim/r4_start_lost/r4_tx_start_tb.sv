`timescale 1ns/1ps
// =============================================================================
// r4_tx_start_tb.sv - prj9 过载冻结 R4 机制复现 TB (2026-10-01)
//
// 命题 (实操单 v2 四 R4 / 体检报告 3.x):
//   udp_tx 的 start 边沿在 TX 忙态到达时被【丢弃】, 且长度寄存器不更新,
//   导致无帧边界的字节 FIFO 与帧边界错位 (旧帧字节顶到新帧长度上)。
//
// RTL 依据 (全部只读, 未改动任何设计文件):
//   udp_tx.v L94   assign pos_start_en = (~start_en_d2) & start_en_d1;  // 单拍上升沿
//   udp_tx.v L120  if(pos_start_en && cur_state==st_idle)  长度仅 idle 锁存
//   udp_tx.v L137  trig_tx_en <= pos_start_en;             无条件打拍
//   udp_tx.v L247  st_idle: if(trig_tx_en)                 忙态脉冲无处锁存 -> 丢
//   顶层     L96   assign tx_start_en = rec_pkt_done;      start 源为单拍脉冲
//   顶层     L436  async_fifo_2048x8b: rd_en=tx_req, .full()/.empty() 空接(无帧边界)
//
// 判据:
//   step3 之后 nframes 不增加            -> 忙态 start 确实被丢弃
//   step4 发出的帧载荷是 D0 而不是 E0    -> 字节流错位(损失 20 字节偏移)
//   终态 rd_ptr != wr_ptr                -> FIFO 残留未消费字节
// =============================================================================
module r4_tx_start_tb;

  reg clk = 1'b0;
  always #4 clk = ~clk;                 // 125 MHz
  reg rst_n = 1'b0;

  // ---- udp_tx 端口 ----
  reg         tx_start_en = 1'b0;
  reg  [7:0]  tx_data;
  reg  [15:0] tx_byte_num = 16'd0;
  wire        tx_done, tx_req, gmii_tx_en, crc_en, crc_clr;
  wire [7:0]  gmii_txd;

  udp_tx dut (
    .clk          (clk          ),
    .rst_n        (rst_n        ),
    .tx_start_en  (tx_start_en  ),
    .tx_data      (tx_data      ),
    .tx_byte_num  (tx_byte_num  ),
    .des_mac      (48'h0        ),
    .des_ip       (32'h0        ),
    .des_port     (16'd1234     ),
    .crc_data     (32'hDEAD_BEEF),
    .crc_next     (8'h00        ),
    .tx_done      (tx_done      ),
    .tx_req       (tx_req       ),
    .gmii_tx_en   (gmii_tx_en   ),
    .gmii_txd     (gmii_txd     ),
    .crc_en       (crc_en       ),
    .crc_clr      (crc_clr      )
  );

  // ---- 上游建模: 无帧边界的字节 FIFO (模拟 async_fifo_2048x8b) ----
  // 读语义 = 标准 FIFO(非 FWFT) 1 拍读延迟 —— 依据 udp_tx.v L334-337 的
  //   "提前读请求数据,等待数据有效时发送"(tx_req 在 st_ip_head 末尾提前一拍拉起,
  //    下一拍 tx_data 才有效)。若按组合读(FWFT)建模, 首个数据字节会被吃掉一字节。
  reg [7:0] fifo [0:8191];
  reg [7:0] rd_data_r = 8'h00;
  integer   wr_ptr = 0, rd_ptr = 0;
  always @(posedge clk) if (tx_req) begin rd_data_r <= fifo[rd_ptr]; rd_ptr <= rd_ptr + 1; end
  always @(*) tx_data = rd_data_r;

  task automatic push(input [7:0] b); begin fifo[wr_ptr] = b; wr_ptr = wr_ptr + 1; end endtask

  // ---- 帧捕获 (逐字节抓 GMII 输出) ----
  integer   nframes = 0;
  reg [7:0] cap [0:7][0:511];
  integer   caplen [0:7];
  integer   cur = -1;
  reg       prev_en = 1'b0;

  always @(posedge clk) begin
    if (gmii_tx_en && !prev_en) begin
      if (nframes < 8) begin cur = nframes; caplen[cur] = 0; end
      else cur = -1;
      nframes = nframes + 1;
    end
    if (gmii_tx_en && cur >= 0) begin
      if (caplen[cur] < 512) cap[cur][caplen[cur]] = gmii_txd;
      caplen[cur] = caplen[cur] + 1;
    end
    prev_en = gmii_tx_en;
  end

  // ---- 激励 ----
  task automatic start_frame(input [15:0] len); begin
    @(posedge clk);
    tx_byte_num = len;
    tx_start_en = 1'b1;
    @(posedge clk);
    tx_start_en = 1'b0;
  end endtask

  task automatic wait_cycles(input integer n); begin
    repeat (n) @(posedge clk);
  end endtask

  // 帧载荷起始偏移 = 8(前导) + 14(以太头) + 28(IP+UDP 头) = 50
  localparam integer DATA_OFF = 50;
  task automatic show(input integer f); begin
    $display("    frame[%0d] len=%0d  payload[0..5]=%02x %02x %02x %02x %02x %02x",
             f, caplen[f], cap[f][DATA_OFF], cap[f][DATA_OFF+1], cap[f][DATA_OFF+2],
             cap[f][DATA_OFF+3], cap[f][DATA_OFF+4], cap[f][DATA_OFF+5]);
  end endtask

  integer i;
  initial begin
    $display("==== R4 忙态 start 丢失复现 (prj9 udp_tx) ====");
    rst_n = 1'b0; repeat (10) @(posedge clk); rst_n = 1'b1; repeat (5) @(posedge clk);

    // step1: 基线帧 A (100B, 图案 A0)
    for (i = 0; i < 100; i = i + 1) push(8'hA0 + i[7:0]);
    start_frame(16'd100); wait_cycles(3000);
    $display("[step1] A(100B,A0) 发出后 nframes=%0d  wr=%0d rd=%0d", nframes, wr_ptr, rd_ptr);
    if (nframes >= 1) begin
      show(0);
      $write("        头部转储[44..53]= ");
      for (i = 44; i <= 53; i = i + 1) $write("%02x ", cap[0][i]);
      $display(" <- 载荷首字节(a0)应落在 %0d", DATA_OFF);
    end

    // step2: 空闲态帧 B (100B, 图案 B0) —— 对照: 空闲时 start 被正常接受
    for (i = 0; i < 100; i = i + 1) push(8'hB0 + i[7:0]);
    start_frame(16'd100); wait_cycles(3000);
    $display("[step2] B(100B,B0) 发出后 nframes=%0d  wr=%0d rd=%0d", nframes, wr_ptr, rd_ptr);
    if (nframes >= 2) show(1);

    // step3: 关键场景 —— C 帧(200B)开始发送后, 在其忙窗口内投 D 帧(50B)并脉冲 start
    for (i = 0; i < 200; i = i + 1) push(8'hC0 + i[7:0]);
    start_frame(16'd200);
    wait_cycles(60);                       // 此刻 TX 正在发 C (寿命 ~300 拍)
    $display("[step3] 忙态注入: gmii_tx_en=%0b (1=确在忙)  -> 投 D(50B,D0) 并脉冲 start", gmii_tx_en);
    for (i = 0; i < 50; i = i + 1) push(8'hD0 + i[7:0]);
    start_frame(16'd50);
    wait_cycles(3000);
    $display("[step3] 忙态 start 之后  nframes=%0d  (若=3 则 D 的 start 被丢弃)", nframes);
    $display("[step3] FIFO: wr=%0d rd=%0d  残留=%0d B (D 的 50B 未消费)", wr_ptr, rd_ptr, wr_ptr - rd_ptr);
    if (nframes >= 3) show(2);

    // step4: 空闲后投 E(30B,E0) 并 start —— 若字节流已错位, 发出的将是 D 的字节
    for (i = 0; i < 30; i = i + 1) push(8'hE0 + i[7:0]);
    start_frame(16'd30); wait_cycles(3000);
    $display("[step4] E(30B,E0) 发出后 nframes=%0d  wr=%0d rd=%0d", nframes, wr_ptr, rd_ptr);
    if (nframes >= 4) begin
      show(3);
      $display("        期望(正确设计)=e0..  实得(错误)=%02x %02x %02x",
               cap[3][DATA_OFF], cap[3][DATA_OFF+1], cap[3][DATA_OFF+2]);
      if (cap[3][DATA_OFF] == 8'hD0)
        $display(">> 判决: 字节流错位【成立】—— 新帧(E0/len=30)发出了旧帧(D0)的字节");
      else if (cap[3][DATA_OFF] == 8'hE0)
        $display(">> 判决: 未错位(与 R4 命题不符, 需复核)");
      else
        $display(">> 判决: 其它图案 %02x (需人工判读)", cap[3][DATA_OFF]);
    end

    $display("[终态] nframes=%0d  wr=%0d rd=%0d  未消费=%0d B", nframes, wr_ptr, rd_ptr, wr_ptr - rd_ptr);
    $display("==== R4 TB 结束 ====");
    $finish;
  end

endmodule
