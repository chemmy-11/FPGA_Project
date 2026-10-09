# -*- coding: utf-8 -*-
import io, os
NL = chr(10)
R = r'C:\\Users\\15266\\Desktop\\毕设\\复现\\README.md'
s = io.open(R, encoding='utf-8').read()

a1 = '| **prj10** | [prj10_复现指南.md](prj10_复现指南.md) | 在光口两侧各插一级 DDR4，验证**按地址随机读**（读出顺序 ≠ 写入顺序，每帧与槽严格对应） |'
assert s.count(a1) == 1
s = s.replace(a1, a1 + NL + '| **prj10 · 速率** | [prj10_复现指南.md](prj10_复现指南.md#第-9-步速率验证l1-乒乓泵修复后) | 验证**帧泵乒乓修复后的速率上限**：1466B 帧 82.67k fps 零丢帧（≈969 Mbps 线速）；PRJ9 同款吞吐档 99.99%（修复前 51.45%）|', 1)

a2 = '| 3 | 位流/探针不配对，ILA 抓不到信号 | 位流与 `.ltx` 必须**同批产出** | 用指南里的 SHA256 闸门核对后再烧 |'
assert s.count(a2) == 1
s = s.replace(a2, a2 + NL
  + '| 4 | 测「板卡速率上限」得到的结果其实是 PC 的节拍 | **报价没盖过被测上限**：`--pace-us 20` 时 PC 最多只能报 50k fps，把 128B 档的板卡真实上限（≥117k）遮住，线性拟合便把「PC 节拍」拟成了「板卡固定开销」（实测曾据此走错方向做了无效修复）| **测上限固定用 `--pace-us 5`**，并先确认「PC 发出速率」显著高于预期上限 |' + NL
  + '| 5 | 跑完 RND 用例后，后续依赖回显的测试「收到 0 片」 | RND 模式桥① 不自动读，回显路径本就不通 | 跑 RND 用例前后都 `SET_MODE(SEQ)`（本轮已给 `deadlock_regress.py` 补上收尾恢复）|', 1)

io.open(R, 'w', encoding='utf-8', newline=NL).write(s)
assert os.path.getsize(R) > 1500
print('README patched:', len(s))

# ---- 镜像到仓库 docs/复现 ----
import shutil
V = r'C:\\Users\\15266\\Desktop\\毕设\\复现'
D = r'D:\\FPGA\\docs\\复现'
os.makedirs(D, exist_ok=True)
for f in os.listdir(V):
    if f.endswith('.md'):
        shutil.copy2(os.path.join(V, f), os.path.join(D, f))
        print('mirrored', f)
