 ///////////////////////////////////////////////////////////////////////////////
 //
 // Project:  Aurora 64B/66B
 // Company:  Xilinx
 //
 //
 //
 // (c) Copyright 2008 - 2009 Xilinx, Inc. All rights reserved.
 //
 // This file contains confidential and proprietary information
 // of Xilinx, Inc. and is protected under U.S. and
 // international copyright and other intellectual property
 // laws.
 //
 // DISCLAIMER
 // This disclaimer is not a license and does not grant any
 // rights to the materials distributed herewith. Except as
 // otherwise provided in a valid license issued to you by
 // Xilinx, and to the maximum extent permitted by applicable
 // law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
 // WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
 // AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
 // BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
 // INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
 // (2) Xilinx shall not be liable (whether in contract or tort,
 // including negligence, or under any other theory of
 // liability) for any loss or damage of any kind or nature
 // related to, arising under or in connection with these
 // materials, including for any direct, or any indirect,
 // special, incidental, or consequential loss or damage
 // (including loss of data, profits, goodwill, or any type of
 // loss or damage suffered as a result of any action brought
 // by a third party) even if such damage or loss was
 // reasonably foreseeable or Xilinx had been advised of the
 // possibility of the same.
 //
 // CRITICAL APPLICATIONS
 // Xilinx products are not designed or intended to be fail-
 // safe, or for use in any application requiring fail-safe
 // performance, such as life-support or safety devices or
 // systems, Class III medical devices, nuclear facilities,
 // applications related to the deployment of airbags, or any
 // other applications that could lead to death, personal
 // injury, or severe property or environmental damage
 // (individually and collectively, "Critical
 // Applications"). Customer assumes the sole risk and
 // liability of any use of Xilinx products in Critical
 // Applications, subject only to applicable laws and
 // regulations governing limitations on product liability.
 //
 // THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
 // PART OF THIS FILE AT ALL TIMES.

 //
 ///////////////////////////////////////////////////////////////////////////////
 //
 //  EXAMPLE_DESIGN
 //
 //
 //  Description:  This module instantiates 1 lane Aurora Module.
 //                Used to exhibit functionality in hardware using the example design
 //                The User Interface is connected to Data Generator and Checker.
 ///////////////////////////////////////////////////////////////////////////////

 // aurora sample file, example design

 `timescale 1 ns / 10 ps

   (* core_generation_info = "aurora_64b66b_0,aurora_64b66b_v12_0_13,{c_aurora_lanes=1,c_column_used=left,c_gt_clock_1=GTHQ0,c_gt_clock_2=None,c_gt_loc_1=1,c_gt_loc_10=X,c_gt_loc_11=X,c_gt_loc_12=X,c_gt_loc_13=X,c_gt_loc_14=X,c_gt_loc_15=X,c_gt_loc_16=X,c_gt_loc_17=X,c_gt_loc_18=X,c_gt_loc_19=X,c_gt_loc_2=X,c_gt_loc_20=X,c_gt_loc_21=X,c_gt_loc_22=X,c_gt_loc_23=X,c_gt_loc_24=X,c_gt_loc_25=X,c_gt_loc_26=X,c_gt_loc_27=X,c_gt_loc_28=X,c_gt_loc_29=X,c_gt_loc_3=X,c_gt_loc_30=X,c_gt_loc_31=X,c_gt_loc_32=X,c_gt_loc_33=X,c_gt_loc_34=X,c_gt_loc_35=X,c_gt_loc_36=X,c_gt_loc_37=X,c_gt_loc_38=X,c_gt_loc_39=X,c_gt_loc_4=X,c_gt_loc_40=X,c_gt_loc_41=X,c_gt_loc_42=X,c_gt_loc_43=X,c_gt_loc_44=X,c_gt_loc_45=X,c_gt_loc_46=X,c_gt_loc_47=X,c_gt_loc_48=X,c_gt_loc_5=X,c_gt_loc_6=X,c_gt_loc_7=X,c_gt_loc_8=X,c_gt_loc_9=X,c_lane_width=4,c_line_rate=10.0,c_gt_type=GTHE3,c_qpll=true,c_nfc=false,c_nfc_mode=IMM,c_refclk_frequency=156.25,c_simplex=false,c_simplex_mode=TX,c_stream=false,c_ufc=false,c_user_k=false,flow_mode=None,interface_mode=Framing,dataflow_config=Duplex}" *)
(* DowngradeIPIdentifiedWarnings="yes" *)
 module aurora_64b66b_0_exdes  #
 (
     parameter   USE_CORE_TRAFFIC     =   0,
     parameter   USR_CLK_PCOUNT     =  9'd255,
     parameter   EXAMPLE_SIMULATION =   0
      //pragma translate_off
        | 1
      //pragma translate_on
      ,
      parameter   USE_LABTOOLS       =   0
 )
 (
     // Status (board LEDs)
     LANE_UP,
     CHANNEL_UP,

     // System Interface
     INIT_CLK_P,
     INIT_CLK_N,

     // GTX Reference Clock Interface
     GTHQ0_P,
     GTHQ0_N,





     // GTX Serial I/O
     RXP,
     RXN,
     TXP,
     TXN,

     // FMC_4SFP control
     sfp_tx_disable,
     sfp_rs0,
     sfp_rs1,
     uart_rxd,
     uart_txd

 );
 `define DLY #1


 //***********************************Port Declarations*******************************

     // Status (board LEDs)
       output             LANE_UP;
       output             CHANNEL_UP;

       input              INIT_CLK_P;
       input              INIT_CLK_N;

     // FMC_4SFP control
       output [3:0]       sfp_tx_disable;
       output [3:0]       sfp_rs0;
       output [3:0]       sfp_rs1;

     // UART bridge
       input              uart_rxd;
       output             uart_txd;

     // Reset tie-offs: internal power-on FSM sequences PMA init / system reset
       wire               RESET    = 1'b0;
       wire               PMA_INIT = 1'b0;

     // GTX Reference Clock Interface
       input              GTHQ0_P;
       input              GTHQ0_N;


     // GTX Serial I/O
       input              RXP;
       input              RXN;

       output             TXP;
       output             TXN;


 //************************External Register Declarations*****************************

     //Error reporting signals
     //Global signals
       reg                  LANE_UP;
       reg                  CHANNEL_UP;

 //********************************Wire Declarations**********************************

     wire    [280:0]          tied_to_ground_vec_i;
     wire            INIT_CLK_IN;

     //Dut1
     //TX Interface
       wire      [0:63]     tx_tdata_i; 
       wire                 tx_tvalid_i;
       wire      [0:7]       tx_tkeep_i;  
       wire                 tx_tlast_i;
       wire                 tx_tready_i;

     //RX Interface
       wire      [0:63]      rx_tdata_i;  
       wire                 rx_tvalid_i;
       wire      [0:7]       rx_tkeep_i;  
       wire                 rx_tlast_i;





     //TX Interface
       wire      [0:63]     tx_d_i;
       wire                 tx_src_rdy_n_i;
       wire      [0:2]       tx_rem_i;
       wire                 tx_sof_n_i;
       wire                 tx_eof_n_i;
       wire                 tx_dst_rdy_n_i;

     //RX Interface
       wire      [0:63]      rx_d_i;
       wire                 rx_src_rdy_n_i;
       wire      [0:2]       rx_rem_i;
       wire                 rx_sof_n_i;
       wire                 rx_eof_n_i;




     //Error Detection Interface
         (* mark_debug = "TRUE" *) wire                 hard_err_i;
         (* mark_debug = "TRUE" *) wire                 soft_err_i;

     //Status
         (* mark_debug = "TRUE" *) wire                 channel_up_i;
         (* mark_debug = "TRUE" *) wire                 lane_up_i;


     //System Interface
       wire                 reset_i ;
       wire                 gt_rxcdrovrden_i ;
       wire                 power_down_i;
       wire      [2:0]      loopback_i ;
       wire                 gt_pll_lock_i ;
       wire                 fsm_resetdone_i ;
       wire                 tx_out_clk_i ;

     // Error signals from the frame checker
         (* mark_debug = "TRUE" *) wire      [0:7]       data_err_count_o;
     wire                  data_err_init_clk_i;


     // clock
       wire               user_clk_i;
       wire               sync_clk_i;
 wire               INIT_CLK_i  /* synthesis syn_keep = 1 */;

       wire               drp_clk_i = INIT_CLK_i;
       wire               DRP_CLK_i;
       wire    [8:0] drpaddr_in_i;
       wire    [15:0]     drpdi_in_i;
       wire    [15:0]     drpdo_out_i;
       wire               drprdy_out_i;
       wire               drpen_in_i;
       wire               drpwe_in_i;
       wire    [8:0]  gt0_drpaddr_i;
       wire    [15:0]                     gt0_drpdi_i;  
       wire                               gt0_drpen_i;  
       wire                               gt0_drpwe_i;  
       wire    [15:0]                     gt0_drpdo_i;  
       wire    [31:0]     s_axi_awaddr_i;
       wire    [31:0]     s_axi_araddr_i;
       wire    [31:0]     s_axi_wdata_i;
       wire    [3:0]     s_axi_wstrb_i;
       wire    [31:0]     s_axi_rdata_i;
       wire               s_axi_awvalid_i;
       wire               s_axi_arvalid_i;
       wire               s_axi_wvalid_i;
       wire               s_axi_rvalid_i;
       wire               s_axi_bvalid_i;
       wire    [1:0]      s_axi_bresp_i;
       wire    [1:0]      s_axi_rresp_i;
       wire               s_axi_bready_i;
       wire               s_axi_awready_i;
       wire               s_axi_arready_i;
       wire               s_axi_wready_i;
       wire               s_axi_rready_i;
       wire               link_reset_i;
       wire               sysreset_from_vio_i =1'b0 ;
       wire               gtreset_from_vio_i =1'b0 ;
       wire               rx_cdrovrden_i =1'b0 ;
       wire               gt_reset_i;
       wire               gt_reset_i_tmp;
       wire               gt_reset_i_tmp2;
       wire               sysreset_from_vio_r3;
       wire               sysreset_from_vio_r3_initclkdomain;
       wire               gtreset_from_vio_r3;
       wire               tied_to_ground_i;
       wire               tied_to_vcc_i;
       wire               gt_reset_i_eff;
       wire               system_reset_i;
       wire                          pll_not_locked_i;
 
reg  pma_init_from_fsm = 0;
reg pma_init_from_fsm_r1 = 0;
reg lane_up_vio_usrclk_r1 = 0;
reg data_err_count_o_r1  = 0;
(* mark_debug = "TRUE" *) reg rx_tvalid_r = 1'd0;
 
(* mark_debug = "TRUE" *) reg [8:0] usr_clk_counter = 9'd0;
(* mark_debug = "TRUE" *) wire usr_clk_count_done;
 

     wire reset2FrameGenCheck;
 

 //*********************************Main Body of Code**********************************

     assign reset2FrameGenCheck = system_reset_i | !channel_up_i;
 


   IBUFDS IBUFDS_INIT_CLK
   (
      .I  (INIT_CLK_P),
      .IB (INIT_CLK_N),
      .O  (INIT_CLK_IN)
   );

   BUFG initclk_bufg_i
   (
      .I  (INIT_CLK_IN),
      .O  (INIT_CLK_i)
   );


//--- Instance of GT differential buffer ---------//

     //____________________________Register User I/O___________________________________

     // Register User Outputs from core.
     always @(posedge user_clk_i)
     begin
         LANE_UP          <=  lane_up_i;
         CHANNEL_UP       <=  channel_up_i;
     end


     //____________________________Register User I/O___________________________________

     // System Interface
     assign power_down_i      =   1'b0;
     assign tied_to_ground_i   =   1'b0;
     assign tied_to_ground_vec_i = 281'd0;
     assign tied_to_vcc_i      =   1'b1;
    // FMC_4SFP: enable laser (tx_disable=0), rate select >4.25G (rs=1)
      assign sfp_tx_disable = 4'b0000;
      assign sfp_rs0        = 4'b1111;
      assign sfp_rs1        = 4'b1111;


    // AXI4 Lite Interface
     assign  s_axi_awaddr_i    =  32'h0;
     assign  s_axi_wdata_i     =  16'h0;
     assign  s_axi_wstrb_i     =  'h0;
     assign  s_axi_araddr_i    =  32'h0;
     assign  s_axi_awvalid_i   =  1'b0;
     assign  s_axi_wvalid_i    =  1'b0;
     assign  s_axi_arvalid_i   =  1'b0;
     assign  s_axi_rvalid_i    =  1'b0;
     assign  s_axi_rready_i    =  1'b0;
     assign  s_axi_bready_i    =  1'b0;




   reg [127:0]        pma_init_stage = {128{1'b1}};
 reg [23:0]         pma_init_pulse_width_cnt = 24'h0;
   reg pma_init_assertion = 1'b0;
 reg pma_init_assertion_r;
   reg gt_reset_i_delayed_r1;
  reg gt_reset_i_delayed_r2;
   wire gt_reset_i_delayed;



     generate
        always @(posedge INIT_CLK_i)
        begin
            pma_init_stage[127:0] <= {pma_init_stage[126:0], gt_reset_i_tmp};
        end

        assign gt_reset_i_delayed = pma_init_stage[127];

        always @(posedge INIT_CLK_i)
        begin
            gt_reset_i_delayed_r1     <=  gt_reset_i_delayed;
            gt_reset_i_delayed_r2     <=  gt_reset_i_delayed_r1;
            pma_init_assertion_r  <= pma_init_assertion;
            if(~gt_reset_i_delayed_r2 & gt_reset_i_delayed_r1 & ~pma_init_assertion & (pma_init_pulse_width_cnt != 24'hFFFFFF))
                pma_init_assertion <= 1'b1;
            else if (pma_init_assertion & pma_init_pulse_width_cnt == 24'hFFFFFF)
                pma_init_assertion <= 1'b0;

            if(pma_init_assertion)
                pma_init_pulse_width_cnt <= pma_init_pulse_width_cnt + 24'h1;
        end



    if(EXAMPLE_SIMULATION)
    assign gt_reset_i_eff = gt_reset_i_delayed;
    else
    assign gt_reset_i_eff = pma_init_assertion ? 1'b1 : gt_reset_i_delayed;


     if(USE_LABTOOLS)
     begin:chip_reset
     assign  gt_reset_i_tmp = PMA_INIT | gtreset_from_vio_r3 | pma_init_from_fsm_r1;
     assign  reset_i  =  RESET | sysreset_from_vio_r3;
     assign  gt_reset_i = gt_reset_i_eff;
     assign  gt_rxcdrovrden_i  =  rx_cdrovrden_i;
     end
     else
     begin:no_chip_reset
     assign  gt_reset_i_tmp = PMA_INIT;
     assign  reset_i  =   RESET | gt_reset_i_tmp2;
     assign  gt_reset_i = gt_reset_i_eff;
     assign  gt_rxcdrovrden_i  =  1'b0;
     assign  loopback_i  =  3'b010;  // NEAR-END PMA SERIAL LOOPBACK (2026-08-31): no optical loopback hardware; restore 3'b000 for external fiber loop
     end

     if(!USE_LABTOOLS)
     begin
aurora_64b66b_0_rst_sync_exdes   u_rst_sync_gtrsttmpi
     (
       .prmry_in     (gt_reset_i_tmp),
       .scndry_aclk  (user_clk_i),
       .scndry_out   (gt_reset_i_tmp2)
      );
     end

     endgenerate

     //___________________________Module Instantiations_________________________________

// this is non shared mode, the clock, GT common are part of example design.
    aurora_64b66b_0_support
aurora_64b66b_0_block_i
     (
        // TX AXI4-S Interface
         .s_axi_tx_tdata(tx_tdata_i),
         .s_axi_tx_tlast(tx_tlast_i),
         .s_axi_tx_tkeep(tx_tkeep_i),
         .s_axi_tx_tvalid(tx_tvalid_i),
         .s_axi_tx_tready(tx_tready_i),


        // RX AXI4-S Interface
         .m_axi_rx_tdata(rx_tdata_i),
         .m_axi_rx_tlast(rx_tlast_i),
         .m_axi_rx_tkeep(rx_tkeep_i),
         .m_axi_rx_tvalid(rx_tvalid_i),



        // GT Serial I/O
         .rxp(RXP),
         .rxn(RXN),

         .txp(TXP),
         .txn(TXN),


        //GT Reference Clock Interface
        .gt_refclk1_p (GTHQ0_P),
        .gt_refclk1_n (GTHQ0_N),
        // Error Detection Interface
         .hard_err              (hard_err_i),
         .soft_err              (soft_err_i),

        // Status
         .channel_up            (channel_up_i),
         .lane_up               (lane_up_i),

        // System Interface
         .user_clk_out          (user_clk_i),

         .sync_clk_out(sync_clk_i),
         .reset_pb(reset_i),
         .gt_rxcdrovrden_in(gt_rxcdrovrden_i),
         .power_down(power_down_i),
         .loopback(loopback_i),
         .pma_init(gt_reset_i),
         .gt_pll_lock(gt_pll_lock_i),

     // ---------- AXI4-Lite input signals ---------------
         .s_axi_awaddr(s_axi_awaddr_i),
         .s_axi_awvalid(s_axi_awvalid_i),
         .s_axi_awready(s_axi_awready_i),
         .s_axi_wdata(s_axi_wdata_i),
         .s_axi_wstrb(s_axi_wstrb_i),
         .s_axi_wvalid(s_axi_wvalid_i),
         .s_axi_wready(s_axi_wready_i),
         .s_axi_bvalid(s_axi_bvalid_i),
         .s_axi_bresp(s_axi_bresp_i),
         .s_axi_bready(s_axi_bready_i),
         .s_axi_araddr(s_axi_araddr_i),
         .s_axi_arvalid(s_axi_arvalid_i),
         .s_axi_arready(s_axi_arready_i),
         .s_axi_rdata(s_axi_rdata_i),
         .s_axi_rvalid(s_axi_rvalid_i),
         .s_axi_rresp(s_axi_rresp_i),
         .s_axi_rready(s_axi_rready_i),

         .init_clk                              (INIT_CLK_i),
         .link_reset_out                        (link_reset_i),
         .mmcm_not_locked_out                   (pll_not_locked_i),


           .bufg_gt_clr_out                 (bufg_gt_clr_out),


         .sys_reset_out                            (system_reset_i),
         .tx_out_clk                               (tx_out_clk_i)
     );

generate
 if (USE_CORE_TRAFFIC==1)
 begin : core_traffic

     //_____________________________ TX AXI SHIM _______________________________
aurora_64b66b_0_EXAMPLE_LL_TO_AXI #
     (
        .DATA_WIDTH(64),
        .STRB_WIDTH(8),
        .USE_4_NFC (0),
        .REM_WIDTH (3)
     )

     frame_gen_ll_to_axi_data_i
     (
      // LocalLink input Interface
      .LL_IP_DATA(tx_d_i),
      .LL_IP_SOF_N(tx_sof_n_i),
      .LL_IP_EOF_N(tx_eof_n_i),
      .LL_IP_REM(tx_rem_i),
      .LL_IP_SRC_RDY_N(tx_src_rdy_n_i),
      .LL_OP_DST_RDY_N(tx_dst_rdy_n_i),

      // AXI4-S output signals
      .AXI4_S_OP_TVALID(tx_tvalid_i),
      .AXI4_S_OP_TDATA(tx_tdata_i),
      .AXI4_S_OP_TKEEP(tx_tkeep_i),
      .AXI4_S_OP_TLAST(tx_tlast_i),
      .AXI4_S_IP_TREADY(tx_tready_i),

      .USER_CLK(user_clk_i),
      .RESET(reset2FrameGenCheck)
     );





    // Frame Generator to provide with input to TX_Stream
aurora_64b66b_0_FRAME_GEN frame_gen_i
    (
         .TX_D(tx_d_i),
         .TX_SOF_N(tx_sof_n_i),
         .TX_EOF_N(tx_eof_n_i),
         .TX_REM(tx_rem_i),
         .TX_SRC_RDY_N(tx_src_rdy_n_i),
         .TX_DST_RDY_N(tx_dst_rdy_n_i),




         .CHANNEL_UP(channel_up_i),
         .USER_CLK(user_clk_i),
         .RESET(reset2FrameGenCheck)
    );

     //_____________________________ RX AXI SHIM _______________________________
aurora_64b66b_0_EXAMPLE_AXI_TO_LL #
     (
        .DATA_WIDTH(64),
        .STRB_WIDTH(8),
        .ISUFC(0),
        .REM_WIDTH (3)
     )
     frame_chk_axi_to_ll_data_i
     (
      // AXI4-S input signals
      .AXI4_S_IP_TX_TVALID(rx_tvalid_i),
      .AXI4_S_IP_TX_TREADY(),
      .AXI4_S_IP_TX_TDATA(rx_tdata_i),
      .AXI4_S_IP_TX_TKEEP(rx_tkeep_i),
      .AXI4_S_IP_TX_TLAST(rx_tlast_i),

      // LocalLink output Interface
      .LL_OP_DATA(rx_d_i),
      .LL_OP_SOF_N(rx_sof_n_i),
      .LL_OP_EOF_N(rx_eof_n_i) ,
      .LL_OP_REM(rx_rem_i) ,
      .LL_OP_SRC_RDY_N(rx_src_rdy_n_i),
      .LL_IP_DST_RDY_N(1'b0),

      // System Interface
      .USER_CLK(user_clk_i),
      .RESET(reset2FrameGenCheck),
      .CHANNEL_UP(channel_up_i)
      );



    // Frame Checker to check output from RX_Stream
aurora_64b66b_0_FRAME_CHECK frame_check_i
    (
         .RX_D(rx_d_i),
         .RX_REM(rx_rem_i),
         .RX_SOF_N(rx_sof_n_i),
         .RX_EOF_N(rx_eof_n_i),
         .RX_SRC_RDY_N(rx_src_rdy_n_i),
         .DATA_ERR_COUNT(data_err_count_o),



         .CHANNEL_UP(channel_up_i),
         .USER_CLK(user_clk_i),
         .RESET(reset2FrameGenCheck)
    );
    
 end //end USE_CORE_TRAFFIC=1 block
 else
   begin: no_traffic
      // UART <-> Aurora bridge (2026-09-01): PC serial <-> Aurora internal loopback
      (* mark_debug = "TRUE" *) wire [15:0] dbg_uart_rx_cnt_i, dbg_uart_tx_cnt_i, dbg_frame_cnt_i;
      (* mark_debug = "TRUE" *) wire        dbg_bridge_err_i;
      (* mark_debug = "TRUE" *) reg [0:7] data_err_count_hold_r;
      always @(posedge user_clk_i) data_err_count_hold_r <= 8'h00;
      assign data_err_count_o = data_err_count_hold_r;

      uart_bridge #(.DIV(82)) u_uart_bridge (
          .clk(user_clk_i), .rst(reset2FrameGenCheck),
          .uart_rxd(uart_rxd), .uart_txd(uart_txd),
          .tx_tdata(tx_tdata_i), .tx_tkeep(tx_tkeep_i), .tx_tlast(tx_tlast_i),
          .tx_tvalid(tx_tvalid_i), .tx_tready(tx_tready_i),
          .rx_tdata(rx_tdata_i), .rx_tkeep(rx_tkeep_i), .rx_tvalid(rx_tvalid_i), .rx_tlast(rx_tlast_i),
          .dbg_uart_rx_cnt(dbg_uart_rx_cnt_i), .dbg_uart_tx_cnt(dbg_uart_tx_cnt_i),
          .dbg_frame_cnt(dbg_frame_cnt_i), .dbg_bridge_err(dbg_bridge_err_i)
      );
  end //end USE_CORE_TRAFFIC=0 block

endgenerate //End generate for USE_CORE_TRAFFIC

     always @(posedge user_clk_i)
         if (reset2FrameGenCheck)
             rx_tvalid_r <=  `DLY 1'b0;
         else if (rx_tvalid_i)
         	 rx_tvalid_r <=  `DLY 1'b1;
         else 
         	 rx_tvalid_r <=  `DLY rx_tvalid_r;


     always @(posedge user_clk_i)
         if (reset2FrameGenCheck)
             usr_clk_counter <=  `DLY 'd0;
         else if (usr_clk_counter >= USR_CLK_PCOUNT)
         	 usr_clk_counter <=  `DLY USR_CLK_PCOUNT;
         else 
         	 usr_clk_counter <=  `DLY usr_clk_counter + 1'b1;

     assign usr_clk_count_done = (usr_clk_counter >= USR_CLK_PCOUNT)? 1'b1:1'b0;

    reg usr_clk_count_done_r;
    reg usr_clk_count_done_r2;     

     always @(posedge user_clk_i)
             usr_clk_count_done_r <=  `DLY usr_clk_count_done;

     always @(posedge user_clk_i)
             usr_clk_count_done_r2 <=  `DLY usr_clk_count_done_r;


//------------------------------------------------------------------------------
 endmodule
