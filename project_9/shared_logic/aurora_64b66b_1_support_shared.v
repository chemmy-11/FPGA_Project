//=============================================================================
// aurora_64b66b_1_support_shared.v — prj9 双笼 A<->B 真链路
//
// B 通道(光口Y9 = GT X1Y9)的 Aurora 64b/66b 支撑层（无 GT_COMMON / 无参考时钟 IBUFDS）
// 参考 clock (refclk1_shared) 与 QPLL 四件套全部来自同 quad 兄弟实例 aurora_64b66b_0_support_ext，
// 一个 quad 只允许一个 GT_COMMON —— 本模块只含: 私有 MMCM 时钟模块 + 复位逻辑 + aurora_64b66b_1 裸核。
// 结构逐段对照 aurora_64b66b_0_support.v（Xilinx 例程生成，勿改原文件——本文件是新建派生）。
//=============================================================================
`timescale 1 ns / 10 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module aurora_64b66b_1_support_shared (
    // TX AXI4-S（echo FIFO → B 核发送）
    input  [63:0]   s_axi_tx_tdata,
    input  [7:0]    s_axi_tx_tkeep,
    input           s_axi_tx_tlast,
    input           s_axi_tx_tvalid,
    output          s_axi_tx_tready,
    // RX AXI4-S（B 核接收 → echo FIFO）
    output [63:0]   m_axi_rx_tdata,
    output [7:0]    m_axi_rx_tkeep,
    output          m_axi_rx_tlast,
    output          m_axi_rx_tvalid,
    // GT 串行 IO（光口Y9）
    input           rxp,
    input           rxn,
    output          txp,
    output          txn,
    // 错误/状态
    output          hard_err,
    output          soft_err,
    output          channel_up,
    output          lane_up,
    // 系统
    output          user_clk_out,
    output          sync_clk_out,
    input           reset_pb,
    input   [2:0]   loopback,
    input           pma_init,
    input           init_clk,
    output          gt_pll_lock,
    // ---- 共享资源（来自 aurora_64b66b_0_support_ext）----
    input           refclk1_shared,           // MGTREFCLK1(156.25M, T6/T5) 缓冲后
    input           gt_qpllclk_shared,        // QPLL 时钟
    input           gt_qpllrefclk_shared,     // QPLL 参考时钟
    input           gt_qplllock_shared,       // QPLL 锁定
    input           gt_qpllrefclklost_shared, // QPLL 参考丢失
    output          gt_to_common_qpllreset_out // 本核 QPLL 复位请求(送到 _ext OR)
);
//---- 内部连线 ----
    wire          user_clk_b, sync_clk_b;
    wire          mmcm_not_locked_b;
    wire          bufg_gt_clr_b;
    wire          tx_out_clk_b;
    wire          sysreset_from_support_b;
    wire          pma_init_b;
    wire [31:0]   drp_rdata_b;
    wire          drp_awready_b, drp_wready_b, drp_bvalid_b, drp_arready_b, drp_rvalid_b;
    wire [1:0]    drp_bresp_b, drp_rresp_b;
    wire          link_reset_b, sys_reset_b;
    // 注意: 核的 gt_pll_lock 是状态输出口(由核驱动, 供上层观测); 外部锁定状态走 gt_qplllock_quad1_in
//---- bufg_gt_clr 延时（与 _support 同款）----
    localparam DLY_FACTOR = 16;
    reg                     bufg_gt_clr_delayed = 1'b1;
    reg [DLY_FACTOR-1:0]    bufg_gt_clr_dly_cnt  = 'h0;
    always @(posedge init_clk or posedge bufg_gt_clr_b) begin
        if (bufg_gt_clr_b) begin
            bufg_gt_clr_delayed <= 1'b1;
            bufg_gt_clr_dly_cnt <= 'h0;
        end else begin
            bufg_gt_clr_dly_cnt <= bufg_gt_clr_dly_cnt + 1;
            if (&bufg_gt_clr_dly_cnt)
                bufg_gt_clr_delayed <= 1'b0;
        end
    end
//---- 时钟模块（每实例私有 MMCM：tx_out_clk → user_clk/sync_clk）----
    aurora_64b66b_0_CLOCK_MODULE clock_module_i (
        .CLK              (tx_out_clk_b),          // 来自 B 核 GT txoutclk
        .CLK_LOCKED       (bufg_gt_clr_delayed),
        .USER_CLK         (user_clk_b),
        .SYNC_CLK         (sync_clk_b),
        .MMCM_NOT_LOCKED  (mmcm_not_locked_b)
    );
    assign user_clk_out = user_clk_b;
    assign sync_clk_out = sync_clk_b;
//---- 复位逻辑（每实例私有）----
    aurora_64b66b_0_SUPPORT_RESET_LOGIC support_reset_logic_i (
        .RESET         (reset_pb),
        .USER_CLK      (user_clk_b),
        .INIT_CLK      (init_clk),
        .GT_RESET_IN   (pma_init),
        .SYSTEM_RESET  (sysreset_from_support_b),
        .GT_RESET_OUT  (pma_init_b)
    );
//---- B 裸核（GT X1Y9；QPLL/refclk 来自共享输入；DRP 悬空同 A）----
    aurora_64b66b_1  aurora_64b66b_1_i (
        // TX AXI4-S
        .s_axi_tx_tdata  (s_axi_tx_tdata),
        .s_axi_tx_tlast  (s_axi_tx_tlast),
        .s_axi_tx_tkeep  (s_axi_tx_tkeep),
        .s_axi_tx_tvalid (s_axi_tx_tvalid),
        .s_axi_tx_tready (s_axi_tx_tready),
        // RX AXI4-S
        .m_axi_rx_tdata  (m_axi_rx_tdata),
        .m_axi_rx_tlast  (m_axi_rx_tlast),
        .m_axi_rx_tkeep  (m_axi_rx_tkeep),
        .m_axi_rx_tvalid (m_axi_rx_tvalid),
        // GT 串行 IO
        .rxp             (rxp),
        .rxn             (rxn),
        .txp             (txp),
        .txn             (txn),
        // 参考时钟（共享）
        .refclk1_in      (refclk1_shared),
        .hard_err        (hard_err),
        .soft_err        (soft_err),
        .channel_up      (channel_up),
        .lane_up         (lane_up),
        // 系统
        .mmcm_not_locked (!mmcm_not_locked_b),
        .user_clk        (user_clk_b),
        .sync_clk        (sync_clk_b),
        .reset_pb        (sysreset_from_support_b),
        .gt_rxcdrovrden_in (1'b0),
        .power_down      (1'b0),
        .loopback        (loopback),
        .pma_init        (pma_init_b),
        .gt_pll_lock     (gt_pll_lock),
        // QPLL 共享四件套
        .gt_qpllclk_quad1_in     (gt_qpllclk_shared),
        .gt_qpllrefclk_quad1_in  (gt_qpllrefclk_shared),
        .gt_qplllock_quad1_in    (gt_qplllock_shared),
        .gt_qpllrefclklost_quad1 (gt_qpllrefclklost_shared),
        .gt_to_common_qpllreset_out (gt_to_common_qpllreset_out),
        // DRP AXI4-Lite 悬空（与 A 同款）
        .s_axi_awaddr  (32'h0),
        .s_axi_awvalid (1'b0),
        .s_axi_awready (drp_awready_b),
        .s_axi_wdata   (32'h0),
        .s_axi_wstrb   (4'h0),
        .s_axi_wvalid  (1'b0),
        .s_axi_wready  (drp_wready_b),
        .s_axi_bvalid  (drp_bvalid_b),
        .s_axi_bresp   (drp_bresp_b),
        .s_axi_bready  (1'b0),
        .s_axi_araddr  (32'h0),
        .s_axi_arvalid (1'b0),
        .s_axi_arready (drp_arready_b),
        .s_axi_rdata   (drp_rdata_b),
        .s_axi_rvalid  (drp_rvalid_b),
        .s_axi_rresp   (drp_rresp_b),
        .s_axi_rready  (1'b0),
        // Misc
        .init_clk       (init_clk),
        .link_reset_out (link_reset_b),
        .bufg_gt_clr_out (bufg_gt_clr_b),
        .tx_out_clk     (tx_out_clk_b),
        .sys_reset_out  (sys_reset_b)
    );
endmodule
