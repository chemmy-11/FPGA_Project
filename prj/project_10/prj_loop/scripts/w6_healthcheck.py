# -*- coding: utf-8 -*-
'''w6_healthcheck.py -- W6 可观测性自检 v2（2026-10-09）

读四域快照(out/dbg_*/ila0..3.csv), 按**硬件恒等式**判定。

两条设计原则（v1 的教训，均已实测踩过）:
  ① **进制**: Vivado ILA CSV 的数值是**十六进制**。v1 按十进制读 -> 同一状态读出
     116 而实际是 0x116=278, 且所有数被一致地读错, 算术恒等式**照样成立**
     => 恒等式不能替代进制正确性。本版一律 int(x, 16) 并在 --selftest 下断言。
  ② **滚动采样**: ILA 连续采样, 末行可能正处在传输中, 故「末行 ost==0」不是判据。
     正确判据 = **每一行样本都必须满足的硬件恒等式**(与有无流量无关), 例如
       ost == (wm - rd_frm) mod 2^9            (契约 §六.3 在途定义)
       wm  == wr_frm                            (提交即计数)
     静止口径(ost==0)只在「抓快照时链路空闲」时另行检查, 用 --quiet 打开。

用法: python scripts/w6_healthcheck.py [目录 ...] [--quiet] [--selftest]
'''
import io, os, csv, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTD = os.path.join(ROOT, 'out')

DOMAIN = {0: 'user_clk (Aurora A)', 1: 'eth_rxc (gmii_rx_clk)',
          2: 'user_clk_b (B 通道)', 3: 'ui_clk (MIG ~300MHz)'}


def hx(s):
    s = (s or '').strip()
    if not s:
        return None
    try:
        return int(s, 16)          # ★Vivado ILA CSV 为十六进制
    except ValueError:
        return None


def load(path):
    '''返回 (探针名->列号, 样本行列表)'''
    rows = list(csv.reader(io.open(path, encoding='utf-8', errors='replace')))
    hdr = None
    for i, r in enumerate(rows[:60]):
        if r and any('dbg_' in c for c in r):
            hdr = i
            break
    if hdr is None:
        return {}, []
    idx = {}
    for j, n in enumerate(rows[hdr]):
        n = n.strip()
        if 'dbg_' in n:
            k = n[n.find('dbg_'):].split()[0].split('[')[0]
            idx[k] = j
    samples = [r for r in rows[hdr + 1:] if r and r[0].strip()]
    return idx, samples


def col(idx, row, name):
    j = idx.get(name)
    return hx(row[j]) if (j is not None and j < len(row)) else None


def scan(d):
    '''逐行扫描, 统计不变量违例'''
    res = {'rows': {}, 'viol': [], 'static': {}, 'max': {}}
    got = {}
    for i in range(4):
        p = os.path.join(d, 'ila%d.csv' % i)
        if not os.path.exists(p):
            continue
        idx, samples = load(p)
        res['rows'][i] = len(samples)
        for k in idx:
            got.setdefault(k, (i, idx, samples))
    def series(name):
        v = got.get(name)
        if not v:
            return []
        i, idx, samples = v
        return [col(idx, r, name) for r in samples]

    # ---- 不变量: 每一行都要成立 ----
    def inv(name, fn, note):
        vs = []
        for name in fn.__code__.co_varnames[:fn.__code__.co_argcount]:
            pass
        n = 0
        bad = 0
        rows = None
        for k in ('dbg_mem_wm', 'dbg_mem_rd_frm', 'dbg_mem_ost'):
            pass
        return vs, bad, n

    wm, rd, ost = series('dbg_mem_wm'), series('dbg_mem_rd_frm'), series('dbg_mem_ost')
    wm2, rd2, ost2 = series('dbg_mem2_wm'), series('dbg_mem2_rd_frm'), series('dbg_mem2_ost')
    u_wr, u_rd = series('dbg_mem_u_wr'), series('dbg_mem_u_rd')
    u2_wr = series('dbg_mem2_u_wr')

    def check_inv(tag, a, b, c, note):
        '''a == (b - c) mod 512, 逐行; 记录差值分布以区分「边沿寄存偏斜」与「真实不一致」'''
        if not a or not b or not c:
            res['viol'].append((tag, '缺列', 0, 0, []))
            return
        n = min(len(a), len(b), len(c))
        deltas = []
        for k in range(n):
            if a[k] is None or b[k] is None or c[k] is None:
                continue
            d = (a[k] - ((b[k] - c[k]) & 0x1FF)) & 0x1FF
            if d:
                deltas.append(d - 512 if d > 256 else d)   # 归一到 [-256,256)
        res['viol'].append((tag, note, len(deltas), n, deltas))

    check_inv('桥① 在途恒等式', ost, wm, rd, 'ost == (wm - rd_frm) mod 512')
    check_inv('桥② 在途恒等式', ost2, wm2, rd2, 'ost == (wm - rd_frm) mod 512')

    def check_eq(tag, a, b, note):
        if not a or not b:
            res['viol'].append((tag, '缺列', 0, 0, []))
            return
        n = min(len(a), len(b))
        deltas = [a[k] - b[k] for k in range(n)
                  if a[k] is not None and b[k] is not None and a[k] != b[k]]
        res['viol'].append((tag, note, len(deltas), n, deltas))

    check_eq('桥① 写=提交', wm, series('dbg_mem_wr_frm'), 'wm == wr_frm 逐行')
    check_eq('桥② user=ui', u2_wr, wm2, 'mem2_u_wr == mem2_wm 逐行')

    def check_le(tag, a, b, note):
        if not a or not b:
            res['viol'].append((tag, '缺列', 0, 0, []))
            return
        n = min(len(a), len(b))
        deltas = [a[k] - b[k] for k in range(n)
                  if a[k] is not None and b[k] is not None and a[k] < b[k]]
        res['viol'].append((tag, note, len(deltas), n, deltas))

    check_le('user 域单调', u_wr, u_rd, 'mem_u_wr >= mem_u_rd 逐行')

    # ---- 静止口径(可选) ----
    last = {}
    for k, (i, idx, samples) in got.items():
        if samples:
            last[k] = col(idx, samples[-1], k)
    res['static'] = last
    for k in ('dbg_mem_ost', 'dbg_mem2_ost'):
        s = series(k)
        res['max'][k] = max([x for x in s if x is not None] or [0])
    return res


STATIC = [('MIG 校准', 'dbg_calib', 1), ('A 通道 up', 'dbg_ch_up', 1),
          ('A lane up', 'dbg_lane_up', 1), ('A hard_err 计数', 'dbg_hard_err_cnt', 0),
          ('A soft_err 计数', 'dbg_soft_err_cnt', 0), ('B 通道 up', 'dbg_ch_up_b', 1),
          ('B lane up', 'dbg_lane_up_b', 1), ('B hard_err 计数', 'dbg_hard_err_b_cnt', 0),
          ('eth 命令错帧', 'dbg_cmd_err', 0), ('桥① bresp_err', 'dbg_mem_bresp', 0),
          ('桥① len_err', 'dbg_mem_len_err', 0), ('user 域丢帧', 'dbg_mem_u_drop', 0)]


def run(d, quiet=False):
    r = scan(d)
    print('=' * 76)
    print(' W6 可观测性自检  %s' % d)
    print('=' * 76)
    print('  快照样本行: ' + '  '.join('ila%d=%d' % (i, r['rows'][i]) for i in sorted(r['rows'])))
    print()
    print('  ── 逐行不变量（与有无流量无关；违例必须为 0 或仅为边沿 ±1 偏斜） ──')
    ok = True
    for tag, note, bad, n, deltas in r['viol']:
        # 边沿偏斜: 同一拍内 wm/rd_frm/ost 分属不同寄存级, 计数器翻转的那一拍会差 1
        skew = (bad > 0 and bad <= 4 and all(abs(d) == 1 for d in deltas))
        good = (bad == 0 or skew) and n > 0
        ok &= good
        mark = 'OK' if bad == 0 else ('OK(边沿±1)' if skew else 'XX')
        extra = '' if bad == 0 else '  Δ=%s' % sorted(set(deltas))[:6]
        print('    %-16s %-34s 违例 %d/%d  %s%s'
              % (tag, note, bad, n, mark, extra))
    print()
    print('  ── 静态判据（末行） ──')
    for name, key, want in STATIC:
        got = r['static'].get(key)
        good = (got == want)
        ok &= good
        print('    %-16s %-28s %s'
              % (name, '%s = %s' % (key, '缺失' if got is None else got),
                 'OK' if good else 'XX'))
    print()
    # 跨域观测量: user 域接受数 - ui 域提交数 = 尚未提交的帧（死锁态会持续增大）
    lw, lwm = r['static'].get('dbg_mem_u_wr'), r['static'].get('dbg_mem_wm')
    if lw is not None and lwm is not None:
        lag = lw - lwm
        good = (0 <= lag <= 32)
        ok &= good
        print('    %-16s %-34s %s' % ('跨域提交滞后', 'mem_u_wr - wm = %d（警戒 <=32）' % lag,
                                      'OK' if good else 'XX 疑似提交停滞'))
    mx = ', '.join('%s max=%d' % (k, v) for k, v in sorted(r['max'].items()))
    print('  ── 在途峰值（滚动采样, 非判据）: %s' % mx)
    if quiet:
        for k in ('dbg_mem_ost', 'dbg_mem2_ost'):
            good = r['static'].get(k) == 0
            ok &= good
            print('    [quiet] %s 末行 = %s  %s'
                  % (k, r['static'].get(k), 'OK' if good else 'XX'))
    print('-' * 76)
    print('W6_HEALTHCHECK: %s' % ('PASS —— 逐行不变量与静态判据全部成立' if ok else 'FAIL'))
    print('=' * 76)
    return ok


def selftest():
    '''断言进制解析: 0x116 -> 278（v1 曾把它读成 116）'''
    assert hx('116') == 278, 'hex parse broken'
    assert hx('14E') == 334
    assert hx('101') == 257
    assert hx('15') == 21
    assert hx('0') == 0
    print('W6_SELFTEST: OK  (116->278, 14E->334, 101->257, 15->21)')
    return True


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    quiet = '--quiet' in sys.argv
    if '--selftest' in sys.argv:
        return 0 if selftest() else 1
    if not args:
        c = sorted(glob.glob(os.path.join(OUTD, 'dbg_*')),
                   key=lambda p: os.path.getmtime(p), reverse=True)
        args = [p for p in c if os.path.isdir(p)][:1]
        if not args:
            print('未找到快照目录');
            return 1
    return 0 if all(run(d, quiet) for d in args) else 1


if __name__ == '__main__':
    sys.exit(main())