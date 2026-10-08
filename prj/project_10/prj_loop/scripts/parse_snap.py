# -*- coding: utf-8 -*-
import io, csv, sys, os
B = r'D:\FPGA\prj\project_10\prj_loop\out\dbg_before'
A = r'D:\FPGA\prj\project_10\prj_loop\out\dbg_after'

def load(d, idx):
    p = os.path.join(d, 'ila%d.csv' % idx)
    rows = list(csv.reader(io.open(p, encoding='utf-8', errors='replace')))
    # Vivado CSV: 头部若干行元数据, 之后一行是探针名, 再之后是样本
    hdr = None
    for i, r in enumerate(rows[:40]):
        if r and r[0].strip().lower() in ('sample', 'sample in buffer', 'sample_in_buffer'):
            hdr = i; break
    if hdr is None:
        # 退而求其次: 找含 'dbg_' 的行
        for i, r in enumerate(rows[:60]):
            if any('dbg_' in c for c in r):
                hdr = i; break
    return rows, hdr

for idx in range(4):
    rb, hb = load(B, idx)
    ra, ha = load(A, idx)
    print('=== ila%d ===' % idx)
    if hb is None or ha is None:
        print('  未找到表头 (hb=%s ha=%s); 前 6 行:' % (hb, ha))
        for r in rb[:6]: print('   ', r[:6])
        continue
    names = rb[hb]
    dbg = [(j, n) for j, n in enumerate(names) if 'dbg_' in n or 'cmd' in n.lower()]
    lastb = rb[-1] if rb[-1] and rb[-1][0].strip() else rb[-2]
    lasta = ra[-1] if ra[-1] and ra[-1][0].strip() else ra[-2]
    print('  探针数=%d, 样本行 before=%d after=%d' % (len(names), len(rb)-hb-1, len(ra)-ha-1))
    for j, n in dbg:
        vb = lastb[j] if j < len(lastb) else '?'
        va = lasta[j] if j < len(lasta) else '?'
        mark = '  <<< 变化' if vb != va else ''
        print('   %-28s before=%-12s after=%-12s%s' % (n.strip(), vb.strip(), va.strip(), mark))