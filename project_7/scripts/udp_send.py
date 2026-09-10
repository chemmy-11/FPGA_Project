#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# udp_send.py — UDP 回环发送器（配合 ILA 抓取或网口助手）
# 用法: python udp_send.py [次数]   默认发 3 包
# 前提: PC 网卡已配 192.168.1.102/24，网线接 GE1
import socket, sys, time

SRC_IP, SRC_PORT = "192.168.1.102", 1234
DST_IP, DST_PORT = "192.168.1.10", 1234
PAYLOADS = [b"UDP-SFP-INNER-LOOP-TEST-01", b"UDP-SFP-INNER-LOOP-TEST-02", b"UDP-SFP-INNER-LOOP-TEST-03"]

n = int(sys.argv[1]) if len(sys.argv) > 1 else 3
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((SRC_IP, SRC_PORT))
s.settimeout(2)
print(f"绑定 {SRC_IP}:{SRC_PORT} -> 发往 {DST_IP}:{DST_PORT}")
ok = 0
for i in range(n):
    p = PAYLOADS[i % len(PAYLOADS)]
    s.sendto(p, (DST_IP, DST_PORT))
    t0 = time.time()
    try:
        rx, addr = s.recvfrom(2048)
        match = (rx == p)
        print(f"#{i+1} 发 {len(p)}B 收 {len(rx)}B from {addr} 回显{'一致' if match else '不一致!'}")
        ok += 1 if match else 0
    except socket.timeout:
        print(f"#{i+1} 发 {len(p)}B 无回显（超时 2s）")
    time.sleep(0.5)   # 拉开包间隔，方便 ILA 单次触发抓单帧
s.close()
print(f"回显成功 {ok}/{n}")
