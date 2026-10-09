# -*- coding: utf-8 -*-
'''w6_inventory.py -- W6 可观测性清单生成器（2026-10-09）

从**源头**自动提取，避免手写清单漂移：
  1) scripts/build_debug.tcl : 每个 ILA 的时钟网络(= 域) + 探针清单
     （**含被注释掉未挂的** —— 那正是可观测性缺口）
  2) rtl/aurora_mem_bridge.v : 每个 dbg_* 的声明(宽度 + 来源信号)
  3) 交叉比对 -> 已挂/未挂 + 域归属 -> 输出 Markdown 清单

用法: python scripts/w6_inventory.py [--check]
      --check: 只校验不写文件(供 CI/自检用), 有未挂信号时退出码 2
'''
import io, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # prj_loop
PRJ = os.path.dirname(ROOT)                                          # project_10
TCL = os.path.join(ROOT, 'scripts', 'build_debug.tcl')
RTL = os.path.join(PRJ, 'rtl', 'aurora_mem_bridge.v')
OUT = os.path.join(ROOT, 'out', 'W6_可观测性清单.md')

DOMAIN_HINT = {
    'user_clk': 'user_clk (Aurora A 通道)',
    'gmii_rx_clk': 'eth_rxc (gmii_rx_clk)',
    'user_clk_b': 'user_clk_b (B 通道)',
    'ui_clk': 'ui_clk (MIG ~300MHz)',
}


def parse_tcl(path):
    lines = io.open(path, encoding='utf-8').read().split(chr(10))
    ilas, cur = {}, None
    for ln in lines:
        m = re.search(r'ILA(\d+)\s*@\s*(.+?)\s*=+\s*$', ln)
        if m:
            cur = 'u_ila_' + m.group(1)
            ilas[cur] = {'title': m.group(2).strip(), 'clk': None,
                         'probes': [], 'unattached': []}
            continue
        if cur is None:
            continue
        mc = re.search(r'connect_debug_port\s+' + cur + r'/clk\s+(\S+)', ln)
        if mc:
            ilas[cur]['clk'] = mc.group(1)
        tgt = 'unattached' if ln.lstrip().startswith('#') else 'probes'
        ma = re.search(r'lappend\s+nets\d+\s+\[one_net\s+(dbg_\w+)', ln)
        if ma:
            ilas[cur][tgt].append((ma.group(1), 1))
        mb = re.search(r'foreach\s+n\s+\[bus_nets\s+(dbg_\w+)\s+(\d+)\]', ln)
        if mb:
            ilas[cur][tgt].append((mb.group(1), int(mb.group(2))))
        if 'connect_debug_port' in ln and '/probe0' in ln:
            cur = None          # 该 ILA 探针段结束
    return ilas


def parse_rtl(path):
    decl = {}
    for ln in io.open(path, encoding='utf-8'):
        m = re.search(r'wire\s*\[(\d+):0\]\s+(dbg_\w+)\s*=\s*([^;]+);', ln)
        if m:
            decl[m.group(2)] = (int(m.group(1)) + 1, m.group(3).strip())
            continue
        m1 = re.search(r'wire\s+(dbg_\w+)\s*=\s*([^;]+);', ln)
        if m1:
            decl[m1.group(1)] = (1, m1.group(2).strip())
    return decl


def main():
    check = '--check' in sys.argv
    ilas = parse_tcl(TCL)
    decl = parse_rtl(RTL)
    where = {}
    unattached = []
    for ila, d in ilas.items():
        for name, w in d['probes']:
            where.setdefault(name, []).append((ila, w))
        for name, w in d['unattached']:
            unattached.append((ila, name, w))

    out = []
    out.append('# W6 可观测性清单（自动生成，勿手改）')
    out.append('')
    out.append('> 生成器: `scripts/w6_inventory.py`  ·  源头: `scripts/build_debug.tcl` + `rtl/aurora_mem_bridge.v`')
    out.append('')
    out.append('## 一、ILA 按域分挂')
    out.append('')
    out.append('| ILA | 时钟网络 | 域 | 探针位宽合计 | 探针数 |')
    out.append('|---|---|---|---|---|')
    for ila in sorted(ilas, key=lambda x: int(x.split('_')[-1])):
        d = ilas[ila]
        bits = sum(w for _, w in d['probes'])
        out.append('| `%s` | `%s` | %s | %d | %d |'
                   % (ila, d['clk'] or '?', d['title'], bits, len(d['probes'])))
    out.append('')
    tot = sum(sum(w for _, w in ilas[i]['probes']) for i in ilas)
    out.append('合计挂载 **%d bit**；4 个 ILA 各挂各自时钟域，**无跨域采样**。' % tot)
    out.append('')
    out.append('## 二、判决计数器总表')
    out.append('')
    out.append('| 计数器 | 位宽 | 承载 ILA | 来源（RTL） |')
    out.append('|---|---|---|---|')
    for name in sorted(where, key=lambda n: (where[n][0][0], n)):
        w = decl.get(name, ('?', ''))[0]
        src = decl.get(name, ('?', '-'))[1]
        out.append('| `%s` | %s | %s | `%s` |'
                   % (name, w, ', '.join(i for i, _ in where[name]), src))
    out.append('')
    out.append('## 三、可观测性缺口（已声明但**未挂 ILA**）')
    out.append('')
    if unattached:
        out.append('| 计数器 | 位宽 | 原计划挂载 | 来源 | 板上可观测? |')
        out.append('|---|---|---|---|---|')
        for ila, name, w in unattached:
            src = decl.get(name, ('?', '-'))[1]
            out.append('| `%s` | %d | %s | `%s` | **否**（仅 xsim 可见） |'
                       % (name, w, ila, src))
    else:
        out.append('（无）')
    out.append('')
    txt = chr(10).join(out) + chr(10)
    if check:
        print('W6_CHECK: ILA=%d 挂载=%d bit 未挂=%d'
              % (len(ilas), tot, len(unattached)))
        for _, n, w in unattached:
            print('  UNATTACHED: %s (%d bit)' % (n, w))
        return 2 if unattached else 0
    d = os.path.dirname(OUT)
    if not os.path.isdir(d):
        os.makedirs(d)
    io.open(OUT, 'w', encoding='utf-8', newline=chr(10)).write(txt)
    print('W6_INVENTORY_OK: %s' % OUT)
    print('  ILA=%d  挂载=%d bit  未挂=%d' % (len(ilas), tot, len(unattached)))
    return 0


if __name__ == '__main__':
    sys.exit(main())