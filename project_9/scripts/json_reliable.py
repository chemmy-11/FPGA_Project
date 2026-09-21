#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
json_reliable.py — prj9 真实业务传输层（2026-09-21）
选择性重传滑窗：板子逐帧回显 = 隐式 ACK；超时未 ACK 的帧重发。
设计动机：链路存在已定位的 ~0.4% 随机丢失 + 板端串行容量上限，
真实业务(Agent 间数据)要求 100% 完整交付 —— 可靠性由本层保证，
链路丢失降级为吞吐税(每丢帧一次重传)。这是"FPGA 快路径 + 传输层可靠性"叙事的实现。

用法:
  python json_reliable.py <file> [--chunk 1360] [--window 4] [--timeout-ms 10]
                          [--limit-bytes N] [--out 重组文件] [--port 1234]

语义:
  - 窗口 W: 最多 W 帧在途未 ACK；ACK = 收到该 seq 的回显且 MD5 匹配
  - MD5 不匹配的回显 = 损坏, 不算 ACK, 留在窗口等重传(逐片 MD5 仍把损坏关死)
  - 超时(默认 10ms, ≈20×RTT_p95)重发, 每帧最多重发 8 次
  - 结束条件: 全部 ACK；打印 重传/重复/损坏 统计 + SHA256(应恒一致)
注意:
  - 窗口越大越逼近板端串行容量上限; 过载会触发板端硬冻结(重烧恢复),
    判决位流的 dbg_pfwd_stuck_cnt 可在线证实。演示建议 W=4。
"""
import argparse, hashlib, json, socket, struct, sys, threading, time

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--chunk", type=int, default=1360)
    ap.add_argument("--window", type=int, default=4)
    ap.add_argument("--timeout-ms", type=float, default=10.0)
    ap.add_argument("--max-retry", type=int, default=8)
    ap.add_argument("--limit-bytes", type=int, default=0)
    ap.add_argument("--out", default="")
    ap.add_argument("--port", type=int, default=1234)
    args = ap.parse_args()

    data = open(args.file, "rb").read()
    if args.limit_bytes:
        data = data[: args.limit_bytes]
    src_sha = hashlib.sha256(data).hexdigest().upper()
    n = (len(data) + args.chunk - 1) // args.chunk
    chunks = [data[i*args.chunk:(i+1)*args.chunk] for i in range(n)]
    md5s = [hashlib.md5(c).hexdigest() for c in chunks]
    print(f"负载: {len(data)} B -> {n} 片 x {args.chunk} B, 窗口={args.window}, 超时={args.timeout_ms}ms")
    print(f"源 SHA256: {src_sha}")

    addr = ("192.168.1.10", args.port)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", args.port))
    s.settimeout(0.002)

    recv = {}                 # seq -> payload (仅 MD5 匹配者)
    outstanding = {}          # seq -> [上次发送时刻, 重发次数]
    stats = {"sends": 0, "retx": 0, "dup": 0, "corrupt": 0}
    lock = threading.Lock()
    done_evt = threading.Event()

    def rx():
        while not done_evt.is_set():
            try:
                pkt, _ = s.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            if len(pkt) < 6:
                continue
            seq, ln = struct.unpack("<IH", pkt[:6])
            payload = pkt[6:]
            if seq >= n or len(payload) != len(chunks[seq]):
                continue
            with lock:
                if seq in recv:
                    stats["dup"] += 1
                    continue
                if hashlib.md5(payload).hexdigest() == md5s[seq]:
                    recv[seq] = payload
                    outstanding.pop(seq, None)
                else:
                    stats["corrupt"] += 1   # 损坏: 不 ACK, 留窗重发

    th = threading.Thread(target=rx, daemon=True)
    th.start()

    t0 = time.perf_counter()
    nxt = 0
    timeout_s = args.timeout_ms / 1000.0
    while len(recv) < n:
        now = time.perf_counter()
        with lock:
            # 1) 填窗
            while nxt < n and len(outstanding) < args.window:
                pkt = struct.pack("<IH", nxt, len(chunks[nxt])) + chunks[nxt]
                s.sendto(pkt, addr)
                outstanding[nxt] = [now, 0]
                stats["sends"] += 1
                nxt += 1
            # 2) 超时重发
            for seq in list(outstanding.keys()):
                t_last, cnt = outstanding[seq]
                if now - t_last >= timeout_s:
                    if cnt >= args.max_retry:
                        print(f"!! 片 {seq} 重发 {cnt} 次未 ACK —— 放弃(链路/板端异常)")
                        done_evt.set()
                        break
                    pkt = struct.pack("<IH", seq, len(chunks[seq])) + chunks[seq]
                    s.sendto(pkt, addr)
                    outstanding[seq] = [now, cnt + 1]
                    stats["retx"] += 1
                    stats["sends"] += 1
        time.sleep(0.0002)
    dur = time.perf_counter() - t0
    done_evt.set(); th.join(timeout=1)

    blob = b"".join(recv[i] for i in range(n))
    out_sha = hashlib.sha256(blob).hexdigest().upper()
    match = (out_sha == src_sha) and (len(recv) == n)
    if args.out and match:
        open(args.out, "wb").write(blob)
    goodput = len(data) / dur / 1e6 if dur > 0 else 0
    print()
    print("==== 可靠传输报告 ====")
    print(f"交付片数        : {len(recv)}/{n}")
    print(f"重传次数        : {stats['retx']}   重复回显: {stats['dup']}   损坏拦截: {stats['corrupt']}")
    print(f"总发送          : {stats['sends']} 帧 (含重传)")
    print(f"用时            : {dur:.2f}s   有效吞吐: {goodput:.2f} MB/s ({goodput*8:.1f} Mbps)")
    print(f"重组 SHA256     : {out_sha}")
    print(f"SHA256 比对     : {'一致 ✓ 全量数据完好穿越光链路往返' if match else '不一致 ✗'}")
    print("JSON_RELIABLE_SUMMARY: " + json.dumps({
        "file_bytes": len(data), "chunks": n, "window": args.window,
        "retx": stats["retx"], "dup": stats["dup"], "corrupt": stats["corrupt"],
        "dur_s": round(dur, 3), "goodput_mbps": round(goodput*8, 2), "sha_match": match}))
    sys.exit(0 if match else 1)

if __name__ == "__main__":
    main()
