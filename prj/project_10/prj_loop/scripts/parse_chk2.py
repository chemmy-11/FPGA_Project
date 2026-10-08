# -*- coding: utf-8 -*-
import io, csv, os
D = r'D:\FPGA\prj\project_10\prj_loop\out\dbg_chk2'
def last(idx, keys):
    p = os.path.join(D, 'ila%d.csv' % idx)
    rows = list(csv.reader(io.open(p, encoding='utf-8', errors='replace')))
    names = [c.strip() for c in rows[0]]
    vals = rows[-1]
    out = {}
    for j, n in enumerate(names):
        if any(k in n for k in keys):
            out[n] = vals[j] if j < len(vals) else '?'
    return out
print('--- ILA0 (user_clk) ---')
for k, v in last(0, ('mem_u_wr','mem_u_rd','mem_u_drop','mem_rden','mem_ost')).items():
    print('  %-24s = %s  (dec %d)' % (k, v, int(v, 16)))
print('--- ILA3 (ui_clk) ---')
for k, v in last(3, ('mem_wm','mem_wr_frm','mem_rd_frm','mem_ost','calib','mem2_wm','mem2_u_wr')).items():
    print('  %-24s = %s  (dec %d)' % (k, v, int(v, 16)))
