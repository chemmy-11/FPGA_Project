# -*- coding: utf-8 -*-
'''w6_archive.py -- W6 报告归档索引生成器（2026-10-09）

为 W 线全部交付物生成**带指纹**的归档索引 —— 判据「可复现」的落点:
别人拿到索引即可核对位流/证据/文档是否与结论一致(哈希不符 = 证据不可信)。

用法: python scripts/w6_archive.py
'''
import io, os, sys, glob, hashlib, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # prj_loop
PRJ = os.path.dirname(ROOT)                                          # project_10
VAULT = r'C:\Users\15266\Desktop\毕设'
OUT = os.path.join(ROOT, 'out', 'W6_报告归档索引.md')


def sha(p, n=16):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    d = h.hexdigest().upper()
    return d if n == 0 else d[:n]


def row(path, desc, full=False):
    if not os.path.exists(path):
        return '| %s | `%s` | *缺失* | - |' % (desc, os.path.basename(path))
    sz = os.path.getsize(path)
    mt = time.strftime('%Y-%m-%d %H:%M', time.localtime(os.path.getmtime(path)))
    return '| %s | `%s` | %s | `%s` | %d |' % (
        desc, os.path.basename(path), mt, sha(path, 0 if full else 16), sz)


def main():
    L = []
    L.append('# W6 报告归档索引（自动生成，勿手改）')
    L.append('')
    L.append('> 生成器: `scripts/w6_archive.py`  ·  生成时间: %s'
             % time.strftime('%Y-%m-%d %H:%M:%S'))
    L.append('>')
    L.append('> **用法**: 任何结论都要能追溯到这里的指纹。若位流/证据哈希与报告记录不符，');
    L.append('> 以**文件实际哈希为准**，报告作废重跑。')
    L.append('')
    L.append('## 一、位流与探针（版本闸门）')
    L.append('')
    L.append('| 工件 | 文件 | 时间 | SHA256 | 字节 |')
    L.append('|---|---|---|---|---|')
    L.append(row(os.path.join(ROOT, 'out', 'aurora_mem_bridge.bit'),
                 '**当前位流**（W5 终版 / 已上板验证）', full=True))
    L.append(row(os.path.join(ROOT, 'out', 'archive',
                              'w5_cursor_fixed_2026-10-08.bit'), 'W5 归档位流', full=True))
    L.append(row(os.path.join(ROOT, 'scripts', 'probes.ltx'), 'ILA 探针（须与位流同批）'))
    L.append('')
    L.append('## 二、板卡实测证据（终端输出原文）')
    L.append('')
    L.append('| 证据 | 文件 | 时间 | SHA256 | 字节 |')
    L.append('|---|---|---|---|---|')
    for p in sorted(glob.glob(os.path.join(ROOT, 'evidence', '*'))):
        name = os.path.basename(p)
        if name.lower().endswith(('.log', '.txt', '.md')):
            L.append(row(p, name.replace('.log', '').replace('_2026-10-08', '')))
    L.append('')
    L.append('## 三、W 线文档（vault）')
    L.append('')
    L.append('| 文档 | 文件 | 时间 | SHA256 | 字节 |')
    L.append('|---|---|---|---|---|')
    docs = [
        ('汇报', '导师原话验证报告_prj10内存进环路_2026-10-08.md'),
        ('操作文档', '阶段三_prj10_W5随机读上板验证单_2026-10-07.md'),
        ('操作文档', '阶段三_prj10_W5命令通道接口契约_2026-10-07.md'),
        ('操作文档', '阶段三_prj10_内存进环路开工草案_2026-09-29.md'),
        ('操作文档', '阶段三_prj10_W4两级内存联调上板验证单_2026-10-07.md'),
        ('调试记录', '阶段三_prj10_W5命令通道上板缺陷_runt帧_2026-10-08.md'),
        ('调试记录', '阶段三_prj10_W5写槽游标死锁_2026-10-08.md'),
        ('调试记录', '阶段三_prj10_W5时序收敛_第三轮根因验证与收敛_2026-10-08.md'),
        ('调试记录', '阶段三_prj10_W4_J4上板执行记录_2026-10-07.md'),
        ('调试记录', '阶段三_prj10_W4仲裁器路由缺陷修复与两级全环路重建_2026-10-07.md'),
    ]
    for sub, name in docs:
        L.append(row(os.path.join(VAULT, sub, name), name.replace('.md', '')))
    L.append('')
    L.append('## 四、复现入口（脚本）')
    L.append('')
    L.append('| 用途 | 文件 | 时间 | SHA256 | 字节 |')
    L.append('|---|---|---|---|---|')
    for name, desc in [
        ('mentor_verify.py', '导师原话验证（终端截图版）'),
        ('j3_random_read.py', 'J3/J3′ 判据引擎'),
        ('deadlock_regress.py', '写槽游标死锁专项回归'),
        ('w6_inventory.py', 'W6 可观测性清单生成器'),
        ('w6_healthcheck.py', 'W6 可观测性自检'),
        ('w6_archive.py', '本索引生成器'),
        ('cmd_probe.py', '命令通道裸探测'),
        ('program_loop.tcl', '一次性烧录 + 体检'),
        ('dbg_snap.tcl', '四域 ILA 立刻快照'),
        ('build_debug.tcl', '位流构建（含 ILA 分挂）'),
    ]:
        L.append(row(os.path.join(ROOT, 'scripts', name), desc))
    L.append('')
    L.append('## 五、构建日志（时序与闸门）')
    L.append('')
    L.append('| 日志 | 文件 | 时间 | SHA256 | 字节 |')
    L.append('|---|---|---|---|---|')
    for name, desc in [
        ('build_w5_mir2.log', 'W5 时序收敛 +0.001（keep 镜像）'),
        ('build_w5_runt.log', '+0.010（runt 修复后）'),
        ('build_w5_cursor_resume.log', '+0.010（写槽游标修复后 = 当前位流）'),
    ]:
        L.append(row(os.path.join(ROOT, name), desc))
    L.append('')
    txt = chr(10).join(L) + chr(10)
    io.open(OUT, 'w', encoding='utf-8', newline=chr(10)).write(txt)
    miss = txt.count('*缺失*')
    print('W6_ARCHIVE_OK: %s' % OUT)
    print('  条目=%d  缺失=%d' % (sum(1 for x in L if x.startswith('| ') and '---' not in x), miss))
    return 0


if __name__ == '__main__':
    sys.exit(main())