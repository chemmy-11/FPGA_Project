#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
udp_verify.py — project_8 Aurora-UDP 数据级桥 上板判据脚本

判据（唯一硬判据）:
    PC 发 UDP payload P → 板卡回显 P′ → 要求 P′ == P
    P′ == P 说明数据**确实穿过了 Aurora 64b/66b 编解码往返**
    （回显帧在板上必经：栈 TX → 帧泵 → 8→64 打包 → Aurora TX → GT 内环
      → Aurora RX → 64→8 解包 → 帧泵 → RGMII TX）

为什么用多种 payload 长度:
    以太网帧总长 = 头(42 + 可选前导) + payload + FCS，未必是 8 的倍数；
    打包模块对"帧尾不足 8 字节"的余字有专门逻辑（左对齐 + tkeep）。
    故按 26/27/28/29/30/31/32/33/40/63/100/200 覆盖 8 种余数类别，
    任一余数类别出错即会在本表中暴露为"不一致"。

前提:
    PC 网卡 IP = 192.168.1.102/24，网线接开发板 GE1（RJ45）
    板卡 bit = D:/FPGA/project_8/out/aurora_udp_bridge.bit
    LED: T23(led_link)=Aurora channel_up, T22(led_loop)=Aurora 收到过数据

用法:
    python udp_verify.py            # 全部长度各 1 包
    python udp_verify.py 3          # 每个长度发 3 包
"""
import socket
import sys
import time

SRC_IP, SRC_PORT = "192.168.1.102", 1234
DST_IP, DST_PORT = "192.168.1.10", 1234

# 覆盖 8 种 (帧长 % 8) 余数类别
LENGTHS = [26, 27, 28, 29, 30, 31, 32, 33, 40, 63, 100, 200]

REPEAT = int(sys.argv[1]) if len(sys.argv) > 1 else 1
GAP = 0.3   # 包间隔（秒）：帧泵为握手限流，人工节奏下不会丢帧


def make_payload(n: int, seq: int) -> bytes:
    """生成可读、可逐字节比对、长度恰为 n 的 payload"""
    tag = f"P8-AURORA-64B66B-{seq:03d}-L{n:03d}-".encode()
    body = (tag * ((n // len(tag)) + 1))[:n]
    return body


def main() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((SRC_IP, SRC_PORT))
    except OSError as e:
        print(f"[!] 绑定 {SRC_IP}:{SRC_PORT} 失败: {e}")
        print("    请确认 PC 网卡已配置 192.168.1.102/24")
        return 2
    s.settimeout(2.0)

    print(f"绑定 {SRC_IP}:{SRC_PORT} -> 发往 {DST_IP}:{DST_PORT}  每个长度 {REPEAT} 包")
    print("-" * 66)

    total = ok = 0
    fails = []
    seq = 0
    for n in LENGTHS:
        for r in range(REPEAT):
            seq += 1
            p = make_payload(n, seq)
            s.sendto(p, (DST_IP, DST_PORT))
            total += 1
            try:
                rx, addr = s.recvfrom(4096)
            except socket.timeout:
                print(f"#{seq:3d} L={n:4d}  发送 {len(p):4d}B → 无回显（超时）")
                fails.append((seq, n, "timeout"))
                time.sleep(GAP)
                continue

            if rx == p:
                ok += 1
                print(f"#{seq:3d} L={n:4d}  发送 {len(p):4d}B 收到 {len(rx):4d}B  一致 ✓")
            else:
                # 定位第一个不一致的字节，便于判因
                d = next((i for i in range(min(len(rx), len(p))) if rx[i] != p[i]),
                         min(len(rx), len(p)))
                print(f"#{seq:3d} L={n:4d}  发送 {len(p):4d}B 收到 {len(rx):4d}B  不一致 ✗ "
                      f"(首差 @{d}: 发{ p[d:d+1]!r} 收{rx[d:d+1]!r})")
                fails.append((seq, n, f"mismatch@{d}"))
            time.sleep(GAP)

    s.close()
    print("-" * 66)
    print(f"回显一致 {ok}/{total}")
    if fails:
        print(f"失败清单: {fails}")
        print("排查顺序: 1) T23 led_link 是否常亮(Aurora channel_up)")
        print("          2) T22 led_loop 是否亮(Aurora 收到过数据)")
        print("          3) ILA1 pump_fwd_drop / pump_rev_drop 是否非 0(帧泵丢弃)")
        print("          4) ILA0 channel_up/lane_up/soft_err/hard_err")
        return 1
    print("PASS: 所有 payload 原样返回 → 数据已穿越 Aurora 64b/66b 编解码往返")
    return 0


if __name__ == "__main__":
    sys.exit(main())
