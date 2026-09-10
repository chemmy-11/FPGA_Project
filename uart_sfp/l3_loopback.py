#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# l3_loopback.py — 串口↔Aurora 桥 L2/L3 回环压测（二之四实操单 §5 L3）
# 用法:
#   python l3_loopback.py                    # 自动探测 COM，115200 / 1MB
#   python l3_loopback.py COM4 921600        # 指定口与波特率
#   python l3_loopback.py COM4 115200 65536  # L2 半严格：64KB
# 失败时自动把接收数据存 rx_fail.bin，用 fc /b 原文件 rx_fail.bin 定位首错
import sys, os, time

try:
    import serial
except ImportError:
    sys.exit("需要 pyserial: python -m pip install pyserial")

def list_ports():
    try:
        from serial.tools import list_ports
        return [p.device for p in list_ports.comports()]
    except Exception:
        import serial
        return serial.Serial().getPortNames() if hasattr(serial.Serial(), 'getPortNames') else []

def pick_port():
    ports = list_ports()
    if not ports:
        sys.exit("未发现任何 COM 口——检查 FT2232H 是否插好")
    print("可用 COM 口:", ports)
    return ports[-1]   # 默认取编号最大的（FT2232H 通道 B=UART 通常排后）

def run(port, baud, n):
    data = os.urandom(n)
    s = serial.Serial(port, baud, timeout=2)
    s.reset_input_buffer()
    print(f"[{port} @ {baud} 8N1] 发送 {n} B ...")
    t0 = time.time()
    s.write(data)
    s.flush()
    rx = bytearray()
    while len(rx) < n and (time.time() - t0) < max(30, n / (baud / 10) * 2):
        chunk = s.read(min(4096, n - len(rx)))
        if chunk:
            rx.extend(chunk)
    dt = time.time() - t0
    s.close()
    ok = (bytes(rx) == data)
    first = next((i for i, (a, b) in enumerate(zip(data, bytes(rx))) if a != b), "无")
    miss = n - len(rx)
    print(f"{'PASS' if ok else 'FAIL'}: 收 {len(rx)}/{n} B, {dt:.1f}s, {len(rx)/dt:.0f} B/s, 首错位 {first}, 缺 {miss} B")
    if not ok:
        with open("rx_fail.bin", "wb") as f:
            f.write(rx)
        print("接收数据已存 rx_fail.bin —— fc /b <原文件> rx_fail.bin 比对（或发我首错位）")
    return ok

if __name__ == "__main__":
    port = sys.argv[1] if len(sys.argv) > 1 else pick_port()
    baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 1_000_000
    ok = run(port, baud, n)
    sys.exit(0 if ok else 1)
