# -*- coding: utf-8 -*-
'''rate_diag.py -- 速率瓶颈定位（差分计数器归因）2026-10-09

思路: 抓「跑流量前」与「跑流量后」两组四域快照, 对每个计数器取增量, 把丢失的帧
      **归因到具体环节** —— 这是回答「瓶颈在哪」最直接的实验, 不靠推测。

用法:
  python scripts/rate_diag.py --before out/dbg_rb --after out/dbg_ra --sent 7022 --recv 6797

判读表见脚本末尾 ATTRIB 说明。
'''
import io, os, csv, sys

def hx(s):
    s = (s or '').strip()
    try:
        return int(s, 16)
    except ValueError:
        return None

def load(d, i):
    p = os.path.join(d, 'ila%d.csv' % i)
    if not os.path.exists(p):
        return {}
    rows = list(csv.reader(io.open(p, encoding='utf-8', errors='replace')))
    hdr = None
    for k, r in enumerate(rows[:60]):
        if r and any('dbg_' in c for c in r):
            hdr = k; break
    if hdr is None:
        return {}
    idx = {}
    for j, n in enumerate(rows[hdr]):
        if 'dbg_' in n:
            idx[n[n.find('dbg_'):].split()[0].split('[')[0]] = j
    samples = [r for r in rows[hdr + 1:] if r and r[0].strip()]
    if not samples:
        return {}
    last = samples[-1]
    return {k: hx(last[j]) for k, j in idx.items() if j < len(last)}

def snap(d):
    v = {}
    for i in range(4):
        for k, x in load(d, i).items():
            v.setdefault(k, x)
    return v

# (计数器, 域, 含义, 增量>0 的归因)
ATTRIB = [
    ('dbg_pfwd_wr',     'eth',  '泵A 收到的帧',        '-'),
    ('dbg_pfwd_drop',   'eth',  '泵A 入口丢弃',        '★丢在 以太网栈->泵A 入口'),
    ('dbg_up_frames',   'user', '上游帧计数',          '-'),
    ('dbg_up_ovf',      'user', '上游溢出',            '★丢在 上游(栈)溢出'),
    ('dbg_pk_frames',   'user', 'pack 帧计数',         '-'),
    ('dbg_pk_ovf',      'user', 'pack 溢出',           '★丢在 打包侧溢出'),
    ('dbg_prev_wr',     'user', '帧泵写计数',          '-'),
    ('dbg_prev_drop',   'user', '帧泵丢弃',            '★丢在 帧泵'),
    ('dbg_mem_u_wr',    'user', '桥① 接受帧数',        '-'),
    ('dbg_mem_u_rd',    'user', '桥① 读出帧数',        '-'),
    ('dbg_mem_u_drop',  'user', '桥① user 域丢弃',     '★丢在 桥① 用户侧'),
    ('dbg_mem_wr_frm',  'ui',   '桥① 提交帧数',        '-'),
    ('dbg_mem_rd_frm',  'ui',   '桥① 读出帧数',        '-'),
    ('dbg_mem_stall',   'ui',   '桥① 写被拒(槽满)',    '★丢在 桥① 槽满拒收'),
    ('dbg_mem_len_err', 'ui',   '桥① 长度错',          '★丢在 桥① 长度非法'),
    ('dbg_mem_bresp',   'ui',   '桥① 写响应错',        '★丢在 桥① AXI 写失败'),
    ('dbg_mem2_wr_frm', 'ui',   '桥② 提交帧数',        '-'),
    ('dbg_mem2_rd_frm', 'ui',   '桥② 读出帧数',        '-'),
]

def main():
    a = {}
    for i, x in enumerate(sys.argv):
        if x in ('--before', '--after') and i + 1 < len(sys.argv):
            a[x[2:]] = sys.argv[i + 1]
        if x in ('--sent', '--recv') and i + 1 < len(sys.argv):
            a[x[2:]] = int(sys.argv[i + 1])
    if 'before' not in a or 'after' not in a:
        print(__doc__); return 1
    b, c = snap(a['before']), snap(a['after'])
    sent, recv = a.get('sent'), a.get('recv')
    print('=' * 84)
    print(' 速率瓶颈定位（差分归因）')
    print('   before = %s' % a['before'])
    print('   after  = %s' % a['after'])
    if sent is not None and recv is not None:
        print('   发出 %d 帧 / 到达 %d 帧 / **丢失 %d 帧**' % (sent, recv, sent - recv))
    print('=' * 84)
    print('  %-18s %-5s %-30s %10s  %s' % ('计数器', '域', '含义', '增量', '归因'))
    print('  ' + '-' * 80)
    tot = {}
    for name, dom, desc, attr in ATTRIB:
        x, y = b.get(name), c.get(name)
        if x is None or y is None:
            print('  %-18s %-5s %-30s %10s  %s' % (name, dom, desc, '缺', '-'))
            continue
        d = (y - x) & 0xFFFF
        print('  %-18s %-5s %-30s %10d  %s' % (name, dom, desc, d, attr if d else ''))
        if attr.startswith('★') and d:
            tot[attr] = tot.get(attr, 0) + d
    print('  ' + '-' * 80)
    if tot:
        print('  丢帧归因汇总:')
        for k, v in sorted(tot.items(), key=lambda kv: -kv[1]):
            print('    %-34s %6d 帧' % (k, v))
        print('    归因合计 %d 帧' % sum(tot.values()))
    else:
        print('  无任何丢弃计数器增长 —— 丢帧不在板内(查 PC 侧/网卡/交换机)')
    print('=' * 84)
    return 0

if __name__ == '__main__':
    sys.exit(main())