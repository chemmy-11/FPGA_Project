#!/usr/bin/env python3
# W4 顶层改造脚本：桥② + SmartConnect + 回程拦截（每处替换均 assert）
import io, re

P = r'D:\FPGA\prj\project_10\rtl\aurora_mem_bridge.v'
src = io.open(P, encoding='utf-8').read()
orig_len = len(src)

# ---------- A) 头注释 ----------
old_hdr = "//   PC --RJ45(GE1,RGMII)--> [以太网栈] --回显帧--> 帧泵A(CDC)\n//      --> [frame_mem_if: 攒槽/写DDR4/按SEQ读回]     ←←← 本工程新增\n//      --> axis_word_pack(8→64) --> Aurora A TX --> 光纤 --> B 回显(unpack→pack)\n//      --> 光纤 --> Aurora RX --> unpack(64→8) --> 帧泵B(CDC) --> RGMII TX --> PC"
new_hdr = ("//   PC --RJ45(GE1,RGMII)--> [以太网栈] --回显帧--> 帧泵A(CDC)\n"
           "//      --> [内存桥① ING 0x0010_0000: 写DDR4/SEQ读回]                    ←W3\n"
           "//      --> axis_word_pack(8→64) --> Aurora A TX --> 光纤 --> B 回显(unpack→pack)\n"
           "//      --> 光纤 --> Aurora RX --> unpack(64→8)\n"
           "//      --> [内存桥② EGR 0x0020_0000: 写DDR4/SEQ读回]                    ←W4\n"
           "//      --> 帧泵B(CDC) --> RGMII TX --> PC\n"
           "//   W4: 两级内存全环路(导师语义③④: 光回环后再存内存再读出); AXI 互联 =\n"
           "//       SmartConnect 2主1从(S00=桥① S01=桥② M00=MIG, ui_clk 同域)")
assert old_hdr in src, "A header"
src = src.replace(old_hdr, new_hdr)

# ---------- B) 桥①实例 -> 派生桥② ----------
m = re.search(r"(frame_mem_if #\(\.SLOT_BASE\(32'h0010_0000\).*?\n\);)", src, re.S)
assert m, "B bridge1 not found"
b1 = m.group(1)
b2 = b1.replace("32'h0010_0000", "32'h0020_0000").replace("u_mem (", "u_mem2 (")
b2 = re.sub(r"\(mem_", "(mem2_", b2)
b2 = re.sub(r"\(m_axi_", "(m2_axi_", b2)
b2 = b2.replace(".wr_data (pump_fwd_data), .wr_en (pump_fwd_en),   // ← 泵A 出（原样接）",
                ".wr_data (unpack_data  ), .wr_en (unpack_en   ),   // ← W4 回程拦截点: 解包输出")
b2 = b2.replace("// DDR 侧 (ui_clk)", "// DDR 侧 (ui_clk)  —— 桥② EGRESS")

# ---------- C) 桥②声明 + SmartConnect ----------
AXI = ['awid','awaddr','awlen','awsize','awburst','awlock','awcache','awprot','awqos','awvalid','awready',
       'wdata','wstrb','wlast','wvalid','wready','bresp','bvalid','bready','bid',
       'arid','araddr','arlen','arsize','arburst','arlock','arcache','arprot','arqos','arvalid','arready',
       'rdata','rresp','rlast','rvalid','rready','rid']
W = dict(awaddr=32, araddr=32, awlen=8, arlen=8, awsize=3, arsize=3, awburst=2, arburst=2,
         wdata=512, rdata=512, wstrb=64, bresp=2, rresp=2,
         awid=4, arid=4, bid=4, rid=4, awlock=1, arlock=1,
         awcache=4, arcache=4, awprot=3, arprot=3, awqos=4, arqos=4)

lines = ["", "//*******************************************************************",
         "// ★ W4 新增: 桥②(EGRESS 0x0020_0000) 声明 + SmartConnect 2主1从",
         "//*******************************************************************"]
for p in AXI:
    w = W.get(p, 1)
    lines.append(f"    wire [{w-1}:0] m2_axi_{p};")
for p in AXI:
    w = W.get(p, 1)
    lines.append(f"    wire [{w-1}:0] sc_s_{p};")
lines += [
    "    wire [7:0]  mem2_rd_data; wire mem2_rd_en;",
    "    wire [7:0]  mem2_rd_slot_o; wire [15:0] mem2_rd_len_o;",
    "    wire        mem2_rd_frame_done, mem2_rd_busy;",
    "    reg         mem2_rd_req = 1'b0;",
    "    wire        mem2_wr_hold;",
    "    wire [15:0] mem2_wm, mem2_wr_frame, mem2_wr_stall, mem2_rd_frame;",
    "    wire [15:0] mem2_ill_rd, mem2_noframe, mem2_bresp_err, mem2_len_err;",
    "    wire [8:0]  mem2_outstanding;",
    "    wire [7:0]  mem2_dbg_wr_slot, mem2_dbg_rd_slot;",
    "    wire [31:0] mem2_dbg_wr_cycles, mem2_dbg_rd_cycles, mem2_dbg_wr_beats, mem2_dbg_rd_beats;",
    "    wire [15:0] mem2_u_wr_frame, mem2_u_rd_frame, mem2_u_buf_drop;",
    "    wire [31:0] mem2_u_hold_cycles;",
    "    wire [8:0]  mem2_outstanding_sync;",
    "",
    "    // 桥②读命令自动生成(同桥①: user 域灰码镜像 outstanding, SEQ 透传)",
    "    always @(posedge user_clk) begin",
    "        if (aurora_rst) mem2_rd_req <= 1'b0;",
    "        else            mem2_rd_req <= (mem2_outstanding_sync != 9'd0) && !mem2_rd_busy && !mem2_rd_req;",
    "    end",
]
decl_block = "\n".join(lines)

sc_lines = ["    // ---- SmartConnect: S00=桥① S01=桥② M00=MIG (ui_clk 同域, aresetn=ui_rst_n) ----",
            "    smartconnect_ddr u_sc ("]
for p in AXI:
    sc_lines.append(f"        .S00_AXI_{p.upper()}(m_{p}),")
for p in AXI:
    sc_lines.append(f"        .S01_AXI_{p.upper()}(m2_axi_{p}),")
for p in AXI:
    sc_lines.append(f"        .M00_AXI_{p.upper()}(sc_s_{p}),")
sc_lines += ["        .aclk(ui_clk),", "        .aresetn(ui_rst_n)", "    );"]
sc_block = "\n".join(sc_lines)

block = decl_block + "\n\n" + b2 + "\n\n" + sc_block + "\n"
src = src.replace(b1, b1 + "\n" + block, 1)

# ---------- D) MIG 例化重定向 m_axi_ -> sc_s_ ----------
m3 = re.search(r"(ddr4_0 u_ddr4 \(.*?\n\);)", src, re.S)
assert m3, "D ddr4 not found"
mig_old = m3.group(1)
mig_new, nsub = re.subn(r"\(m_", "(sc_s_", mig_old)
assert nsub == 37, f"D: MIG AXI subs={nsub} expect 37"
src = src.replace(mig_old, mig_new)

# ---------- E) 泵B 输入改桥② ----------
old_pb = ("frame_fifo_pump u_pump_rev (\n"
          "    .wr_clk       (user_clk      ),\n"
          "    .wr_rst_n     (~aurora_rst   ),\n"
          "    .wr_data      (unpack_data   ),\n"
          "    .wr_en        (unpack_en     ),")
new_pb = ("frame_fifo_pump u_pump_rev (\n"
          "    .wr_clk       (user_clk      ),\n"
          "    .wr_rst_n     (~aurora_rst   ),\n"
          "    .wr_data      (mem2_rd_data  ),   // ★ W4: 原为 unpack_data(回程插桥②)\n"
          "    .wr_en        (mem2_rd_en    ),")
assert old_pb in src, "E pump_rev anchor"
src = src.replace(old_pb, new_pb)

# ---------- F) 桥②观测探针 ----------
anchor = '(* mark_debug = "true" *) wire [7:0]  dbg_mem_rslot   = mem_dbg_rd_slot;'
assert anchor in src, "F probe anchor"
add = anchor + "\n" + "\n".join([
 '// ★ W4: 桥②(EGRESS)观测 —— user/ui 域分挂同桥①纪律',
 '(* mark_debug = "true" *) wire [15:0] dbg_mem2_wm     = mem2_wm;',
 '(* mark_debug = "true" *) wire [15:0] dbg_mem2_wr_frm = mem2_wr_frame;',
 '(* mark_debug = "true" *) wire [15:0] dbg_mem2_rd_frm = mem2_rd_frame;',
 '(* mark_debug = "true" *) wire [15:0] dbg_mem2_stall  = mem2_wr_stall;',
 '(* mark_debug = "true" *) wire [15:0] dbg_mem2_len    = mem2_len_err;',
 '(* mark_debug = "true" *) wire [8:0]  dbg_mem2_ost    = mem2_outstanding;',
 '(* mark_debug = "true" *) wire [15:0] dbg_mem2_u_wr   = mem2_u_wr_frame;',
 '(* mark_debug = "true" *) wire [15:0] dbg_mem2_u_rd   = mem2_u_rd_frame;'])
src = src.replace(anchor, add)

# ---------- G) unused 聚合 ----------
old_un = "wire unused = ^{mem_rd_slot_o, mem_rd_len_o, mem_rd_frame_done, mem_wr_hold,"
new_un = ("wire unused = ^{mem_rd_slot_o, mem_rd_len_o, mem_rd_frame_done, mem_wr_hold,\n"
          "                mem2_rd_slot_o, mem2_rd_len_o, mem2_rd_frame_done, mem2_wr_hold,\n"
          "                mem2_ill_rd, mem2_noframe, mem2_dbg_wr_cycles, mem2_dbg_rd_cycles,\n"
          "                mem2_dbg_wr_beats, mem2_dbg_rd_beats, mem2_u_hold_cycles,")
assert old_un in src, "G unused anchor"
src = src.replace(old_un, new_un)

io.open(P, 'w', encoding='utf-8', newline='\n').write(src)
print("W4 edits OK:", orig_len, "->", len(src), "chars")
