#!/usr/bin/env python3
# 重建 u_arb 例化段（修复 bash 转义引入的 0x01 控制字符）
import io, re

AXI = ['awid','awaddr','awlen','awsize','awburst','awlock','awcache','awprot','awqos','awvalid','awready',
       'wdata','wstrb','wlast','wvalid','wready','bresp','bvalid','bready','bid',
       'arid','araddr','arlen','arsize','arburst','arlock','arcache','arprot','arqos','arvalid','arready',
       'rdata','rresp','rlast','rvalid','rready','rid']

P = r'D:\FPGA\prj\project_10\rtl\aurora_mem_bridge.v'
src = io.open(P, encoding='utf-8').read()
assert '\x01' in src, "no control char found"

# 定位损坏的 u_arb 例化段（axi_arb_2to1 u_arb ( 起，到对应 ); 止）
m = re.search(r"axi_arb_2to1 u_arb \(.*?\n    \);", src, re.S)
assert m, "u_arb instance not found"

lines = ["axi_arb_2to1 u_arb ("]
for p in AXI:
    lines.append(f"        .s00_axi_{p}(m_{p}),")
for p in AXI:
    lines.append(f"        .s01_axi_{p}(m2_axi_{p}),")
for p in AXI:
    lines.append(f"        .m_axi_{p}(sc_s_{p}),")
lines += ["        .clk(ui_clk),", "        .rst_n(ui_rst_n)", "    );"]

src = src.replace(m.group(0), "\n".join(lines))
assert '\x01' not in src, "control char still present"
io.open(P, 'w', encoding='utf-8', newline='\n').write(src)
print("u_arb instance rebuilt clean")
