//=============================================================================
// crc32_d8.v — Ethernet CRC32 校验模块（8bit 数据位宽，反射算法）
// 书中说明（43.4.5 p1342-1344）：源码出自 outputlogic.com 生成器"稍作修改"，
// 完整清单未给。此处按标准 Ethernet CRC-32 重实现：
//   多项式(反射) 0xEDB88320，初值/清零值 0xFFFFFFFF，数据 LSB 先行（GMII 线序）
//   crc_next = 组合逻辑下一态；crc_data = 寄存器当前值（crc_en 门控）
// 偏差记录（实操单 D1）：发送端 FCS 发射序改用本模块约定（见 udp_tx/arp_tx/icmp_tx
// st_crc 态），仿真以 Python zlib.crc32 全帧比对为准。
//=============================================================================
module crc32_d8(
    input               clk     ,       //时钟
    input               rst_n   ,       //复位信号，低电平有效
    input       [7:0]   data    ,       //输入待校验8位数据
    input               crc_en  ,       //CRC开始校验使能
    input               crc_clr ,       //CRC数据复位信号
    output  reg [31:0]  crc_data,       //CRC校验数据（寄存器当前值）
    output      [31:0]  crc_next        //CRC下次校验完成数据（组合逻辑）
    );

//单字节 CRC32 更新（反射算法，等价于标准 Ethernet FCS）
function [31:0] crc32_byte_update;
    input [31:0] crc;
    input [7:0]  d;
    integer i;
    reg [31:0] c;
    begin
        c = crc ^ {24'h0, d};
        for (i = 0; i < 8; i = i + 1) begin
            c = c[0] ? ({1'b0, c[31:1]} ^ 32'hEDB88320) : {1'b0, c[31:1]};
        end
        crc32_byte_update = c;
    end
endfunction

assign crc_next = crc32_byte_update(crc_data, data);

always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        crc_data <= 32'hFFFFFFFF;   //Ethernet CRC 初值
    else if(crc_clr)
        crc_data <= 32'hFFFFFFFF;   //每包发送完成后清零
    else if(crc_en)
        crc_data <= crc_next;
    else
        crc_data <= crc_data;       //保持（发送 CRC 期间冻结）
end

endmodule
