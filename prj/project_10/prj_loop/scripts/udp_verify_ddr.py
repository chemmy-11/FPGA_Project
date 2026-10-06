#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
udp_verify_ddr.py — prj10 内存进环路 一条命令闭环验证（派生自 prj9 udp_verify.py）

适用位流: aurora_mem_bridge.bit（prj_loop）
数据路径: PC → 网口 → 以太网栈 → 泵A → 【内存桥: 写入DDR4 → 按帧读出】
          → Aurora 10G → 光纤A<->B → 解包 → 泵B → 网口 → PC
回显 payload 逐字节一致 ⇒ 数据真实穿过 DDR4 写-读往返（帧在桥内走槽存储）。

四档判据:
  [1] 链路档   ping 20 次 0% 丢包
  [2] 基础档   12 种长度(26–200B, 覆盖帧长%8 全部余数)逐字节回显
  [3] 槽深档   大帧(500–1472B, 贴 MTU 顶格)逐字节回显 —— 深填 DDR 槽
  [4] 稳定档   混合长度连发 300 帧, 统计到达率+一致率(温和速率, 避开过载冻结触发量)

前提: PC 网卡 192.168.1.102/24, 板已烧 aurora_mem_bridge.bit, T22/T23 常亮
用法: python udp_verify_ddr.py          # 全档
      python udp_verify_ddr.py --quick  # 只跑 [1][2][3]
"""
import random
import re
import socket
import subprocess
import sys
import time

SRC_IP, SRC_PORT = "192.168.1.102", 1234
DST_IP, DST_PORT = "192.168.1.10", 1234

BASE_LENGTHS = [26, 27, 28, 29, 30, 31, 32, 33, 40, 63, 100, 200]   # %8 余数全覆盖
DEEP_LENGTHS  = [500, 900, 1200, 1400, 1466, 1472]                    # 1472=MTU 顶格
STRESS_N      = 300
STRESS_GAP    = 0.05    # 50ms/帧 温和速率; 总量 300 帧远低于已知冻结触发量(~3.6k)
GAP           = 0.3


def make_payload(n, seq):
    tag = f"P10-MEMLOOP-DDR4-{seq:04d}-L{n:04d}-".encode()
    return (tag * ((n // len(tag)) + 1))[:n]


def ping_check(n=20):
    print("=" * 70)
    print(f"[1] 链路档: ping {DST_IP} x{n}")
    try:
        r = subprocess.run(["ping", "-n", str(n), "-w", "1000", DST_IP],
                           capture_output=True, timeout=60)
        out = r.stdout.decode("gbk", errors="replace")  # 中文 Windows 控制台 = GBK
    except Exception as e:
        print(f"    ping 执行失败: {e}")
        return False
    got = len(re.findall(r"TTL=", out, flags=re.I))
    print(f"    收到 {got}/{n} 应答")
    return got == n


def echo_test(s, lengths, repeat, gap, tag):
    """逐长度回显比对, 返回 (ok, total, fails)"""
    ok = 0; total = 0; fails = []; seq = 0
    for n in lengths:
        for _ in range(repeat):
            seq += 1
            p = make_payload(n, seq)
            s.sendto(p, (DST_IP, DST_PORT))
            total += 1
            try:
                rx, _ = s.recvfrom(65535)
            except socket.timeout:
                fails.append((n, "timeout")); print(f"    L={n:4d}  无回显(超时) ✗"); time.sleep(gap); continue
            if rx == p:
                ok += 1
            else:
                d = next((i for i in range(min(len(rx), len(p))) if rx[i] != p[i]), min(len(rx), len(p)))
                fails.append((n, f"mismatch@{d}"))
                print(f"    L={n:4d}  不一致 ✗ (首差 @{d}: 发{p[d:d+1]!r} 收{rx[d:d+1]!r})")
            time.sleep(gap)
    print(f"    {tag}: {ok}/{total} 逐字节一致" + ("  ✓" if ok == total else "  ✗"))
    return ok, total, fails


def stress_test(s):
    print("=" * 70)
    print(f"[4] 稳定档: 混合长度连发 {STRESS_N} 帧 (间隔 {int(STRESS_GAP*1000)}ms, 温和速率)")
    random.seed(10)
    lengths = [random.choice(BASE_LENGTHS + DEEP_LENGTHS) for _ in range(STRESS_N)]
    ok = 0; to = 0; bad = 0; seq = 1000
    t0 = time.perf_counter()
    for n in lengths:
        seq += 1
        p = make_payload(n, seq)
        s.sendto(p, (DST_IP, DST_PORT))
        try:
            rx, _ = s.recvfrom(65535)
            if rx == p: ok += 1
            else: bad += 1; print(f"    L={n} seq={seq} 不一致 ✗")
        except socket.timeout:
            to += 1
        time.sleep(STRESS_GAP)
    dt = time.perf_counter() - t0
    print(f"    到达 {ok}/{STRESS_N} ({ok*100.0/STRESS_N:.1f}%)  超时 {to}  损坏 {bad}  用时 {dt:.1f}s")
    return ok == STRESS_N and bad == 0, to, bad


def main():
    quick = "--quick" in sys.argv
    print("prj10 内存进环路 · DDR 线闭环一条命令验证（位流 aurora_mem_bridge）")
    print("=" * 70)
    print("数据路径: PC → 网口 → 栈 → 泵A → 【写DDR4 → 按帧读出】 → Aurora10G")
    print("          → 光纤往返 → 解包 → 泵B → 网口 → PC")

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((SRC_IP, SRC_PORT))
    except OSError as e:
        print(f"[!] 绑定 {SRC_IP}:{SRC_PORT} 失败: {e}（确认 PC 网卡 = 192.168.1.102/24）")
        return 2
    s.settimeout(2.0)

    results = {}
    results["链路"] = ping_check()

    print("=" * 70)
    print("[2] 基础档: 12 种长度覆盖帧长%8 全部余数（26–200B）")
    ok, tot, _ = echo_test(s, BASE_LENGTHS, 1, GAP, "基础档")
    results["基础"] = (ok == tot)

    print("=" * 70)
    print("[3] 槽深档: 大帧 500–1472B（1472=MTU 顶格, 深填 DDR 槽）× 2")
    ok, tot, _ = echo_test(s, DEEP_LENGTHS, 2, GAP, "槽深档")
    results["槽深"] = (ok == tot)

    if not quick:
        st_ok, to, bad = stress_test(s)
        results["稳定"] = st_ok

    s.close()
    print("=" * 70)
    allpass = all(results.values())
    for k, v in results.items():
        print(f"  [{k}档] {'PASS ✓' if v else 'FAIL ✗'}")
    print("=" * 70)
    if allpass:
        print("DDR_VERIFY: PASS — 全档通过：数据穿 DDR4 写-读往返逐字节无损")
        print("（板端七级计数对账佐证见 截图归档/ddr_*.png 与 prj_loop/out/ila*_final.csv）")
    else:
        print("DDR_VERIFY: FAIL — 失败档位见上；排查: T22/T23 灯 → 重烧位流 → ILA 计数")
    return 0 if allpass else 1


if __name__ == "__main__":
    sys.exit(main())
