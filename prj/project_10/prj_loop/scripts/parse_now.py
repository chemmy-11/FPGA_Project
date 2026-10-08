# -*- coding: utf-8 -*-
import io, csv, os
D = r'D:\FPGA\prj\project_10\prj_loop\out\dbg_now1'
def load(idx):
    p = os.path.join(D, 'ila%d.csv' % idx)
    rows = list(csv.reader(io.open(p, encoding='utf-8', errors='replace')))
    names = [c.strip() for c in rows[0]]
    data = rows[1:]
    last = data[-1]
    return names, last
for idx in (0, 3):
    names, last = load(idx)
    print('=== ila%d ===' % idx)
    for j, n in enumerate(names):
        if any(k in n for k in ('mem_wm','mem_wr_frm','mem_rd_frm','mem_u_wr','mem_u_rd','mem_u_drop','mem2_u_wr','mem2_wm','mem_ost','mem_rden','calib')):
            print('   %-24s = %s' % (n, last[j] if j < len(last) else '?'))
