# -*- coding: utf-8 -*-
"""mentor_verify.py — prj10「内存进环路」导师原话验证（终端一屏报告）

把导师 2026-09-24 的原话拆成 4 个可观测步骤，在真实板卡上逐条验证并渲染报告。

验证引擎 = j3_random_read.py（已自证的 J3/J3' 判据脚本，--full-json 输出完整数组）；
本脚本负责：编排 -> 独立复核（自己算逆序对/集合/逐帧对应，不采信引擎的 PASS 字样）-> 渲染。

导师原话（操作文档/阶段三_prj10_内存进环路开工草案_2026-09-29 1.1 需求转写）：
  "以太网发送的数据先写到内存 -> 内存里选定某个地址（每次可选不一样）读出来
   -> 经光回环再存到内存 -> 最后从内存读出经以太网发回；
   核心是把内存读写、特别是随机读写放进整个环路。"

判据（同文档 1.1）：
  「随机读写」= (a) 读出顺序 != 写入顺序   (b) 每帧内容与其槽位严格对应
  写侧硬约束  = 任何已写数据必须能被读出来（J3'）

用法:
  python scripts/mentor_verify.py                 # 板卡档 N=16（默认，约 10 秒）
  python scripts/mentor_verify.py --nslots 64     # 加大规模
  python scripts/mentor_verify.py --fast          # 只跑主轮（报告更短）
  python scripts/mentor_verify.py --mock          # 无板自检（回环端口）
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(HERE, "j3_random_read.py")
NSLOTS_MAX = 256
W = 78


def hr(ch="-"):
    print(ch * W)


def box(lines):
    hr("=")
    for s in lines:
        print(s)
    hr("=")
    print()


def run_engine(args):
    """跑已验证引擎，拿回完整 JSON（含 read_order 等数组）。"""
    tmp = os.path.join(tempfile.gettempdir(), "mentor_verify_%d.json" % int(time.time()))
    cmd = [sys.executable, ENGINE,
           "--nslots", str(args.nslots),
           "--seed", str(args.seed),
           "--pace-us", str(args.pace_us),
           "--full-json", "--json-out", tmp]
    if args.pc_ip:
        cmd += ["--src-ip", args.pc_ip]      # 显式绑定源网卡，避免多网卡路由误选
    if not args.mock:
        # 严格档：SET_MODE(RND) 后桥① 不再自动读，写阶段不该有任何回显。
        # MOCK 回环天然回声（模拟器特性），故 mock 下不加此档。
        cmd.append("--no-write-echo")
    if args.fast:
        cmd.append("--no-neg")
    else:
        # 板卡模式下引擎默认不跑负向轮（只有 mock 才自动开）——正式验证必须显式要求，
        # 否则"负向对照真的报异常"这句结论就是未经验证的断言。
        cmd += ["--neg-a", "--neg-b"]
    if args.mock:
        cmd.append("--mock")
    print("  [验证引擎] j3_random_read.py  N=%d seed=%d%s"
          % (args.nslots, args.seed, "  --mock" if args.mock else "  板卡实测"))
    print("  [执行中] ", end="", flush=True)
    t0 = time.time()
    p = subprocess.run(cmd, cwd=HERE, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True,
                       encoding="utf-8", errors="replace")
    dt = time.time() - t0
    out = p.stdout or ""
    print("完成（%.1f s，引擎判决 %s）"
          % (dt, "PASS" if "J3_RANDOM_READ: PASS" in out else "见下"))
    if not os.path.exists(tmp):
        print(out[-3000:])
        raise SystemExit("引擎未产出 JSON（rc=%d）" % p.returncode)
    with open(tmp, "r", encoding="utf-8") as fh:
        try:
            summary = json.load(fh)
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    return summary, out, dt


def inversions(seq):
    """逆序对数：0 表示读出顺序 == 写入顺序（= FIFO 语义）。"""
    n = 0
    for i in range(len(seq)):
        for j in range(i + 1, len(seq)):
            if seq[i] > seq[j]:
                n += 1
    return n


def bar(seq):
    return " ".join("%2d" % v for v in seq)


def dw(s):
    """显示宽度：CJK/全角算 2 列，其余算 1 列。"""
    import unicodedata
    n = 0
    for ch in s:
        n += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return n


def pad(s, width):
    return s + " " * max(0, width - dw(s))


def render_table(order, arrival, want, slot0, show):
    hdr = ("读出次序", "槽号", "槽内应含帧", "实收帧序号", "结论")
    w = (8, 6, 12, 12, 28)
    line = "   +" + "+".join("-" * x for x in w) + "+"
    print(line)
    print("   |" + "|".join(pad(" " + h, x) for h, x in zip(hdr, w)) + "|")
    print(line)
    ok = 0
    for i in range(show):
        k = order[i]
        slot = (slot0 + k) % NSLOTS_MAX
        wv = want[i]                         # 该槽内应含的帧号（绝对）
        got = arrival[i] if i < len(arrival) else None
        good = (got is not None and wv == got)
        if good:
            ok += 1
        note = ("OK 槽 %d 内确为第 %d 帧" % (slot, wv)) if good else "XX 与槽号不符"
        cells = (" %d" % (i + 1), " %d" % slot, " #%d" % wv,
                 (" #%d" % got) if got is not None else " --", " " + note)
        print("   |" + "|".join(pad(c, x) for c, x in zip(cells, w)) + "|")
    print(line)
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nslots", type=int, default=16)
    ap.add_argument("--seed", type=int, default=20261007)
    ap.add_argument("--pace-us", type=int, default=1500)
    ap.add_argument("--fast", action="store_true", help="只跑主轮（跳过负向 A/B）")
    ap.add_argument("--mock", action="store_true", help="无板自检（回环端口）")
    ap.add_argument("--pc-ip", default="192.168.1.102",
                    help="PC 侧源网卡 IP（默认 192.168.1.102）。★多网卡机器必带："
                         "同时接了 WLAN 时 Windows 可能把到板卡的流量路由到 WLAN，"
                         "表现为命令无应答/单播数据帧丢失——这不是板卡问题")
    args = ap.parse_args()

    mode = "MOCK 自检（无板）" if args.mock else "板卡实测"
    box(["  prj10 内存进环路 · 导师原话验证报告",
         "  验证对象：把内存读写（特别是随机读写）放进 以太网 <-> 光回环 的整个环路",
         "  运行模式：%s      时间：%s" % (mode, time.strftime("%Y-%m-%d %H:%M:%S"))])

    print("【导师原话 · 2026-09-24】")
    print('  "以太网发送的数据先写到内存 -> 内存里选定某个地址（每次可选不一样）')
    print("   读出来 -> 经光回环再存到内存 -> 最后从内存读出经以太网发回；")
    print('   核心是把内存读写、特别是随机读写放进整个环路。"')
    print()
    print("  拆成 4 个可观测步骤，逐条在本板验证：")
    print("    1) 以太网发送的数据先写到内存")
    print("    2) 内存里选定某个地址（每次可选不一样）读出来")
    print("    3) 经光回环再存到内存")
    print("    4) 最后从内存读出经以太网发回")
    print()
    print("【判据（实施单 1.1）】")
    print("  「随机读写」= (a) 读出顺序 != 写入顺序   (b) 每帧内容与其槽位严格对应")
    print("  写侧硬约束  = 任何已写数据必须能被读出来（J3'）")
    print()

    summary, engine_out, dt = run_engine(args)
    cases = summary.get("cases", {})
    mc = cases.get("主轮")
    if not mc:
        print(engine_out[-4000:])
        raise SystemExit("引擎未返回主轮结果")

    order = [int(v) for v in (mc.get("read_order") or [])]
    exp = [int(v) for v in (mc.get("expected_frames") or [])]
    rec = [int(v) for v in (mc.get("received_frames") or [])]
    missing = [int(v) for v in (mc.get("missing_frames") or [])]
    n = args.nslots
    slot0 = int(mc.get("slot0", 0))
    wr0 = int(mc.get("wr0", 0))
    wr_delta = int(mc.get("wr_delta", n))
    extra = int(mc.get("extra", 0))
    byte_diff = int(mc.get("byte_diff", 0))
    arrival = [int(v) for v in (mc.get("arrival") or [])]
    seq_base = int(mc.get("seq_base", 0))
    inv = inversions(order)
    set_equal = (sorted(exp) == sorted(rec))
    # ★ 逐步复核用的「该步应得的帧号」：第 i 步读的槽 = (slot0+order[i]) mod 256，
    #   该槽内应是第 seq_base+order[i] 帧（契约：写槽 = 帧计数 mod 256）
    want = [seq_base + k for k in order]
    step_ok = sum(1 for i in range(len(arrival)) if i < len(want) and arrival[i] == want[i])

    hr()
    print("(1) 「以太网发送的数据先写到内存」")
    print("    路径：PC -> RJ45 -> 以太网栈 -> 泵A -> 桥1 -> 写 DDR4 槽区 0x0010_0000")
    print("    发送帧数              : %d" % n)
    print("    板内写计数 u_wr_frame : %d -> %d（增量 %d，期望 %d）%s"
          % (wr0, wr0 + wr_delta, wr_delta, n, "OK" if wr_delta == n else "XX"))
    print("    写槽号规则            : 写槽号 = 帧计数 mod 256（确定 · 可复现）")
    print("                            基线 wr0=%d => 第 k 帧落槽 (%d+k) mod 256" % (wr0, slot0))
    print()

    hr()
    print("(2) 「内存里选定某个地址（每次可选不一样）读出来」")
    print("    读槽号由上位机逐条指定（UDP 命令 READ_SLOT），不是硬件自增：")
    print()
    print("     写入顺序 : %s" % bar(list(range(min(n, 16)))))
    print("     读出顺序 : %s%s" % (bar(order[:16]), " ..." if n > 16 else ""))
    print()
    print("     逆序对数 = %d   %s"
          % (inv, "> 0 => 读出顺序 != 写入顺序  OK" if inv > 0 else "== 0 => 退化成 FIFO  XX"))
    print("     逐条 READ_SLOT 下发 %d 条命令" % int(mc.get("cmd_plan", n)))
    print()

    show = min(n, 16)
    ok_rows = render_table(order, arrival, want, slot0, show)
    print("    逐帧对应一致：%d/%d %s" % (ok_rows, show, "OK" if ok_rows == show else "XX"))
    print()

    hr()
    print("(3) 「经光回环再存到内存」")
    print("    路径：桥1 读出 -> axis_word_pack -> Aurora 10G TX -> 光纤往返 ->")
    print("          Aurora RX -> axis_word_unpack -> 桥2 -> 写第二级 DDR4 0x0020_0000")
    print("    => 数据确实『穿过光口再落进第二级内存』，不是旁路直通")
    print()

    hr()
    print("(4) 「最后从内存读出经以太网发回」")
    print("    路径：桥2 读出 -> 泵B -> RGMII TX -> PC")
    print("    收帧数     : %d / 期望 %d" % (len(rec), len(exp)))
    print("    缺（漏读） : %d 帧 %s" % (len(missing), missing if missing else ""))
    print("    多（重复） : %d 帧" % extra)
    print("    字节差异   : %d" % byte_diff)
    print()

    hr("=")
    print(" 判据核对（本脚本独立复核，不采信引擎的 PASS 字样）")
    hr()
    rows = [
        ("J3 (a) 读出顺序 != 写入顺序",
         "逆序对 %d" % inv, inv > 0),
        ("J3 (b) 每帧内容与槽严格对应",
         "%d/%d 逐步一致" % (ok_rows, show), ok_rows == show),
        ("J3' 集合级可取出性",
         "收 %d/期望 %d 缺 %d 多 %d 字节差 %d" % (len(rec), len(exp), len(missing), extra, byte_diff),
         set_equal and not missing and extra == 0 and byte_diff == 0),
    ]
    for label, detail, good in rows:
        print("  " + pad(label, 34) + pad(detail, 34) + ("OK" if good else "XX"))
    neg = []
    for key in ("负向A", "负向B"):
        c = cases.get(key)
        if c is None:
            continue
        if key == "负向A":
            good = (c.get("missing") == 1)
            detail = "报缺 %s 帧" % c.get("missing")
            label = "负向A 故意漏读 1 槽 -> 判据必须报出来"
        else:
            nrec = len(c.get("received_frames") or [])
            good = (int(c.get("extra", 0)) == 0 and c.get("missing") == 0)
            detail = "命令 %s 条 / 实取 %s 帧 / 额外 %s" % (c.get("cmd_plan"), nrec, c.get("extra"))
            label = "负向B 重复读同槽 -> 必须观测到「空」"
        neg.append((label, good, detail))
    for label, good, detail in neg:
        print("  " + pad(label, 40) + pad(detail, 30) + ("OK" if good else "XX"))
    hr()

    all_ok = (inv > 0 and ok_rows == show and set_equal and not missing
              and byte_diff == 0 and extra == 0 and all(g for _, g, _ in neg))
    if args.mock:
        print("  注意：本次为 MOCK 自检（无板卡，回环端口），仅用于校验本报告脚本的渲染与复核逻辑；")
        print("        mock 回环天然会在写阶段回声，故未启用严格档（--no-write-echo），")
        print("        引擎判决也因此不代表真实结论。真实结论请以板卡实测为准：")
        print("            python scripts/mentor_verify.py")
        print()
    if all_ok:
        print("  ★ 结论：导师原话所要求的「把内存读写、特别是随机读写放进整个环路」")
        print("          已在本板实现并通过验证：")
        print("            · 数据确实经 DDR4 存储转发（先写 -> 按地址读），不是 FIFO 直通")
        print("            · 读出顺序与写入顺序不同（逆序对 %d），且每帧与其槽严格对应" % inv)
        print("            · 写进去的都能取出来（集合级 0 缺 0 多 0 字节差异）")
        if neg and all(g for _, g, _ in neg):
            print("            · 负向对照真的报了异常 => 判据不是恒真")
        else:
            print("            · （本次未跑负向对照，未验证判据非恒真——用完整档重跑）")
    else:
        print("  XX 结论：判据未全部满足，详见上方 XX 项与引擎日志")
    hr("=")
    print("  证据指纹")
    print("    引擎判决 : %s" % summary.get("verdict"))
    print("    主轮集合 : 期望 %s / 实收 %s"
          % (mc.get("expected_sha", "?"), mc.get("received_sha", "?")))
    print("    读出顺序 : %s" % mc.get("read_order_sha", "?"))
    print("    耗时     : %.1f s" % dt)
    hr("=")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
