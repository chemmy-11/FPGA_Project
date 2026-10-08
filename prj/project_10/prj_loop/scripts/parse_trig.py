# -*- coding: utf-8 -*-
import io, csv
P = r'D:\FPGA\prj\project_10\prj_loop\out\trig_r3\resp.csv'
rows = list(csv.reader(io.open(P, encoding='utf-8', errors='replace')))
# 找表头行（含 dbg_ 的行）
hdr = None
for i, r in enumerate(rows[:80]):
    if any('dbg_' in c for c in r):
        hdr = i; break
print('表头行号 =', hdr)
names = [c.strip() for c in rows[hdr]]
print('探针:', [n for n in names if n][:20])
# 数据行: 跳过可能的单位行
data = rows[hdr+1:]
data = [r for r in data if len(r) >= len(names) and r[0].strip() != '' and not r[0].strip().startswith('Radix')]
print('数据行数 =', len(data))
idx = {n: j for j, n in enumerate(names)}
def col(n):
    j = idx.get(n)
    return j
j_bsy = col('dbg_cmd_respbsy')
j_rx  = col('dbg_cmd_rx[15:0]')
j_err = col('dbg_cmd_err[15:0]')
print('列索引: respbsy=%s rx=%s err=%s' % (j_bsy, j_rx, j_err))
if j_bsy is not None:
    vals = [r[j_bsy].strip() for r in data]
    ones = [i for i, v in enumerate(vals) if v in ('1', '1\'b1', '0x1')]
    print('respbsy=1 的样本数 =', len(ones))
    if ones:
        print('首个 =', ones[0], ' 末个 =', ones[-1], ' 连续段长度 =', ones[-1]-ones[0]+1)
if j_rx is not None:
    rxv = [r[j_rx].strip() for r in data]
    print('cmd_rx 首=%s 末=%s 去重=%s' % (rxv[0], rxv[-1], sorted(set(rxv))))
if j_err is not None:
    print('cmd_err 去重 =', sorted(set(r[j_err].strip() for r in data)))
# 打印触发点前后 respbsy 的变化序列（压缩游程）
if j_bsy is not None:
    runs = []
    prev = None; cnt = 0
    for v in vals:
        if v == prev: cnt += 1
        else:
            if prev is not None: runs.append((prev, cnt))
            prev = v; cnt = 1
    runs.append((prev, cnt))
    print('respbsy 游程(值,拍数), 前 12 段:', runs[:12])