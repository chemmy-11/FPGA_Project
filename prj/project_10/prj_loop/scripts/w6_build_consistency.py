# -*- coding: utf-8 -*-
import io, re, sys
BASE = r'D:\FPGA\prj\project_10\prj_loop\scripts'

def probes(path):
    s = io.open(path, encoding='utf-8').read().split(chr(10))
    out, cur, stop = {}, None, False
    for ln in s:
        m = re.search(r'ILA(\d+)\s*@', ln)
        if m and '====' in ln:
            cur = 'ila' + m.group(1); out[cur] = []; continue
        if cur is None: continue
        t = ln.strip()
        if t.startswith('#'): continue
        ma = re.search(r'one_net\s+(dbg_\w+)', t)
        mb = re.search(r'bus_nets\s+(dbg_\w+)\s+(\d+)', t)
        mc = re.search(r'connect_debug_port\s+u_ila_\d+/probe0', t)
        if ma: out[cur].append((ma.group(1), 1))
        elif mb: out[cur].append((mb.group(1), int(mb.group(2))))
        if mc: cur = None
    return out

a = probes(BASE + r'\build_debug.tcl')
b = probes(BASE + r'\build_debug_resume.tcl')
bad = 0
for k in sorted(set(a) | set(b)):
    x, y = a.get(k, []), b.get(k, [])
    same = (x == y)
    if not same: bad += 1
    print('%-6s main=%2d 项/%3d bit   resume=%2d 项/%3d bit   %s'
          % (k, len(x), sum(w for _, w in x), len(y), sum(w for _, w in y),
             'OK 一致' if same else 'XX 不一致'))
    if not same:
        sx, sy = set(x), set(y)
        for d in sorted(sx - sy): print('      仅 main 有: %s(%d)' % d)
        for d in sorted(sy - sx): print('      仅 resume 有: %s(%d)' % d)
        if sx == sy: print('      (集合相同, 仅顺序不同)')
print()
print('BUILD_PATH_CONSISTENCY: %s' % ('PASS 两条构建路径探针完全一致' if bad == 0 else 'FAIL %d 个 ILA 不一致' % bad))
sys.exit(0 if bad == 0 else 2)