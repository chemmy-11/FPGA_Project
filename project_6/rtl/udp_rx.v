//=============================================================================
// udp_rx.v — UDP 接收模块：逐层解析 前导码->以太网帧头->IP首部->UDP首部->数据
// 来源: 开发指南第 45 章 45.4.2（p1414-1416）：接口表 45.4.1、状态跳转图 45.4.5、
// 第三段状态机片段（st_rx_data/st_rx_end 原文转录）；其余状态按状态图规格实现
//=============================================================================
module udp_rx(
    input               clk         ,   //接收的udp时钟信号（125MHz）
    input               rst_n       ,   //复位信号，低电平有效
    //GMII输入接口
    input               gmii_rx_dv  ,   //GMII输入数据有效信号
    input       [7:0]   gmii_rxd    ,   //GMII输入数据
    //接收数据输出（有效数据 = UDP 载荷）
    output  reg         rec_pkt_done,   //以太网单包数据接收完成信号
    output  reg         rec_en      ,   //以太网接收的数据使能信号
    output  reg [7:0]   rec_data    ,   //以太网接收的数据
    output  reg [15:0]  rec_byte_num    //以太网接收的有效字节数
    );

//parameter define
parameter BOARD_MAC = 48'h00_11_22_33_44_55;    //开发板MAC地址
parameter BOARD_IP  = {8'd192,8'd168,8'd1,8'd10}; //开发板IP地址

//reg define
reg  [2:0]  state       ;       //状态机状态
reg         skip_en     ;       //跳转使能
reg         error_en    ;       //错误使能
reg  [4:0]  cnt         ;       //字节计数
reg  [15:0] data_cnt    ;       //有效数据计数
reg  [15:0] data_byte_num;      //有效数据字节数（UDP载荷 = UDP长度-8）
reg  [47:0] dest_mac_t  ;       //目的MAC地址缓存
reg  [31:0] dest_ip_t   ;       //目的IP地址缓存
reg  [15:0] udp_len_t   ;       //UDP总长度缓存
reg  [7:0]  ip_head_t   ;       //IP首部字段缓存（协议号等）

//state define
localparam  st_idle     = 3'd0; //初始状态
localparam  st_preamble = 3'd1; //接收前导码+SFD
localparam  st_eth_head = 3'd2; //接收以太网帧头
localparam  st_ip_head  = 3'd3; //接收IP首部
localparam  st_udp_head = 3'd4; //接收UDP首部
localparam  st_rx_data  = 3'd5; //接收有效数据
localparam  st_rx_end   = 3'd6; //接收结束

wire  [15:0] udp_data_num;      //UDP载荷长度 = UDP总长度 - 8
assign udp_data_num = udp_len_t - 16'd8;

//*************************************************************************************
//**                    main code：状态跳转（第一段）
//*************************************************************************************
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        state <= st_idle;
    else begin
        case(state)
            st_idle     : if(skip_en)  state <= st_preamble; else state <= st_idle;
            st_preamble : if(error_en) state <= st_rx_end;
                          else if(skip_en) state <= st_eth_head;
                          else state <= st_preamble;
            st_eth_head : if(error_en) state <= st_rx_end;
                          else if(skip_en) state <= st_ip_head;
                          else state <= st_eth_head;
            st_ip_head  : if(error_en) state <= st_rx_end;
                          else if(skip_en) state <= st_udp_head;
                          else state <= st_ip_head;
            st_udp_head : if(error_en) state <= st_rx_end;
                          else if(skip_en) state <= st_rx_data;
                          else state <= st_udp_head;
            st_rx_data  : if(skip_en)  state <= st_rx_end;
                          else state <= st_rx_data;
            st_rx_end   : if(gmii_rx_dv == 1'b0 && skip_en == 1'b0)
                          state <= st_idle;     //单包真正结束，准备收下一包
                          else state <= st_rx_end;
            default     : state <= st_idle;
        endcase
    end
end

//*************************************************************************************
//**                    main code：跳转/错误判定 + 数据解析（第二、三段）
//*************************************************************************************
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        skip_en      <= 1'b0;
        error_en     <= 1'b0;
        cnt          <= 5'd0;
        data_cnt     <= 16'd0;
        rec_pkt_done <= 1'b0;
        rec_en       <= 1'b0;
        rec_data     <= 8'd0;
        rec_byte_num <= 16'd0;
        dest_mac_t   <= 48'd0;
        dest_ip_t    <= 32'd0;
        udp_len_t    <= 16'd0;
        data_byte_num<= 16'd0;
    end
    else begin
        skip_en      <= 1'b0;       //默认拉低，单周期脉冲
        error_en     <= 1'b0;
        rec_pkt_done <= 1'b0;
        rec_en       <= 1'b0;
        case(state)
            //接收前导码：7个8'h55 + 1个8'hd5
            st_preamble : begin
                if(gmii_rx_dv) begin
                    cnt <= cnt + 5'd1;
                    if(cnt == 5'd0 && gmii_rxd == 8'h55)
                        skip_en <= 1'b1;            //开始进入前导码流
                    else if(cnt >= 5'd1 && cnt < 5'd7) begin
                        if(gmii_rxd != 8'h55)
                            error_en <= 1'b1;       //前导码错误
                    end
                    else if(cnt == 5'd7) begin
                        if(gmii_rxd == 8'hd5) begin
                            skip_en <= 1'b1;        //前导码接收完成
                            cnt <= 5'd0;
                        end
                        else
                            error_en <= 1'b1;
                    end
                end
            end
            //接收以太网帧头：目的MAC(6)+源MAC(6)+类型(2)
            st_eth_head : begin
                if(gmii_rx_dv) begin
                    cnt <= cnt + 5'd1;
                    if(cnt < 5'd6)
                        dest_mac_t <= {dest_mac_t[39:0], gmii_rxd};
                    else if(cnt == 5'd6) begin
                        cnt <= 5'd0;
                        //目的MAC为板卡MAC或广播（ARP请求为广播帧）均可
                        if(dest_mac_t == BOARD_MAC || dest_mac_t == 48'hff_ff_ff_ff_ff_ff)
                            skip_en <= 1'b1;
                        else
                            error_en <= 1'b1;       //MAC地址错误
                    end
                    //cnt==12/13 为以太网类型 8'h08/8'h00，在 cnt==13 处判定
                    else if(cnt == 5'd13) begin
                        cnt <= 5'd0;
                        if(gmii_rxd == 8'h00 && ip_head_t == 8'h08)
                            skip_en <= 1'b1;        //类型 0x0800 = IP
                        else
                            error_en <= 1'b1;       //协议类型错误
                    end
                    else if(cnt == 5'd12)
                        ip_head_t <= gmii_rxd;      //缓存类型高字节
                end
            end
            //接收IP首部（20字节）：校验版本/IHL、协议号=17(UDP)、目的IP=板卡IP
            st_ip_head : begin
                if(gmii_rx_dv) begin
                    cnt <= cnt + 5'd1;
                    if(cnt == 5'd0) begin
                        if(gmii_rxd == 8'h45)       //版本4+首部长度5
                            ;
                        else
                            error_en <= 1'b1;
                    end
                    else if(cnt == 5'd9)            //协议字段
                        ip_head_t <= gmii_rxd;
                    else if(cnt >= 5'd16 && cnt < 5'd20)    //目的IP地址
                        dest_ip_t <= {dest_ip_t[23:0], gmii_rxd};
                    else if(cnt == 5'd19) begin
                        cnt <= 5'd0;
                        if(dest_ip_t == BOARD_IP && ip_head_t == 8'd17) begin
                            skip_en <= 1'b1;        //目的IP与UDP协议均正确
                        end
                        else
                            error_en <= 1'b1;       //IP地址错误/不是UDP协议
                    end
                end
            end
            //接收UDP首部（8字节）：源端口(2)+目的端口(2)+长度(2)+校验和(2)
            st_udp_head : begin
                if(gmii_rx_dv) begin
                    cnt <= cnt + 5'd1;
                    if(cnt >= 5'd4 && cnt < 5'd6)   //UDP总长度
                        udp_len_t <= {udp_len_t[7:0], gmii_rxd};
                    else if(cnt == 5'd7) begin
                        cnt <= 5'd0;
                        data_byte_num <= udp_data_num;  //有效数据字节数
                        skip_en <= 1'b1;
                    end
                end
            end
            //接收有效数据（UDP载荷）
            st_rx_data : begin
                if(gmii_rx_dv) begin
                    data_cnt <= data_cnt + 16'd1;
                    rec_data <= gmii_rxd;
                    rec_en   <= 1'b1;
                    if(data_cnt == data_byte_num - 16'd1) begin
                        skip_en      <= 1'b1;       //有效数据接收完成
                        data_cnt     <= 16'd0;
                        rec_pkt_done <= 1'b1;       //单包数据接收完成
                        rec_byte_num <= data_byte_num;
                    end
                end
            end
            //接收结束：等待 GMII 数据有效拉低（单包真正结束）
            st_rx_end : begin
                cnt <= 5'd0;
                if(gmii_rx_dv == 1'b0 && skip_en == 1'b0)
                    skip_en <= 1'b1;
                else ;
            end
            default : ;
        endcase
    end
end

endmodule
