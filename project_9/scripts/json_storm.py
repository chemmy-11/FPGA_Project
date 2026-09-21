#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
json_storm.py — 全量会话 JSON 打过 FPGA 光链路的传输质量测试器
================================================================
负载 = 真实会话记录(本工程未来承载的就是 agent 间数据, 用会话 JSON 最贴近实况)。

帧格式(UDP payload): [4B seq][2B len][len B 原文切片]  —— len 含义为切片长度
链路 = PC NIC -> RGMII -> 以太网栈 -> 帧泵A -> pack -> Aurora 10G -> 光纤
       -> B 回显(unpack->pack) -> 光纤 -> Aurora -> unpack -> 帧泵B -> RGMII -> PC
质量维度:
  完整性  收到片数/发出片数, 重组文件 SHA256 与源文件比对(金标准)
  正确性  逐片 MD5 比对(定位损坏片, 不因单片坏毁掉全文结论)
  乱序    seq 单调性统计
  时延    逐片 RTT (min/avg/p95/max)
  吞吐    单向有效吞吐 + 等效信道速率(数据渡链路两次)
用法:
  python json_storm.py <文件> [--chunk 1360] [--gap-ms 1.0] [--port 1234]
                       [--limit-bytes N] [--out 重组输出路径]
"""
import argparse, hashlib, json, socket, struct, sys, threading, time

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--chunk", type=int, default=1360)
    ap.add_argument("--gap-ms", type=float, default=1.0)
    ap.add_argument("--port", type=int, default=1234)
    ap.add_argument("--limit-bytes", type=int, default=0, help="只发前 N 字节(校准用)")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    data = open(args.file, "rb").read()
    if args.limit_bytes:
        data = data[: args.limit_bytes]
    total = len(data)
    src_sha = hashlib.sha256(data).hexdigest().upper()
    chunks = [data[i : i + args.chunk] for i in range(0, total, args.chunk)]
    n = len(chunks)
    md5s = [hashlib.md5(c).hexdigest() for c in chunks]
    gap_s = args.gap_ms / 1000.0

    print(f"负载: {total} B -> {n} 片 x {args.chunk} B (帧 {args.chunk+6+42} B), gap={args.gap_ms}ms")
    print(f"源 SHA256: {src_sha}")

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", args.port))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    s.settimeout(0.002)

    # 校准提示: 先确保 1234 端口没被占用(udp_verify 同款前提)
    recv = {}          # seq -> payload
    rtts = {}          # seq -> rtt_s
    t_send = {}        # seq -> monotonic
    corrupt = []
    done = threading.Event()

    def rx():
        while not done.is_set():
            try:
                pkt, _ = s.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            t_now = time.perf_counter()
            if len(pkt) < 6:
                continue
            seq, ln = struct.unpack("<IH", pkt[:6])
            if seq >= n:
                continue  # 迟到的历史回显(上一轮残留), 与本轮无关
            recv[seq] = pkt[6:]
            if seq in t_send:
                rtts[seq] = t_now - t_send[seq]

    th = threading.Thread(target=rx, daemon=True)
    th.start()

    t0 = time.perf_counter()
    for i, c in enumerate(chunks):
        pkt = struct.pack("<IH", i, len(c)) + c
        t_send[i] = time.perf_counter()
        s.sendto(pkt, ("192.168.1.10", args.port))
        if gap_s:
            time.sleep(gap_s)
    t_send_done = time.perf_counter()

    deadline = time.time() + 3.0
    while time.time() < deadline and len(recv) < n:
        time.sleep(0.05)
    done.set(); th.join(timeout=1)
    t_all_done = time.perf_counter()

    # ---- 统计 ----
    time.sleep(0.1)  # 等 rx 线程彻底退出
    snap = dict(recv)  # 防御性快照(线程竞态)
    got = sorted(snap.keys())
    lost = [i for i in range(n) if i not in recv]
    bad = [i for i in got if hashlib.md5(snap[i]).hexdigest() != md5s[i]]
    corrupt = bad
    reordered = sum(1 for a, b in zip(got, got[1:]) if b != a + 1)  # 到达流中的逆序对(按排序后无从算, 用接收时序另行统计见 rtts 之外)
    # 乱序: 用接收线程插入顺序近似 = dict 保持插入序
    arrival = list(snap.keys())  # python dict 按插入序
    inversions = sum(1 for a, b in zip(arrival, arrival[1:]) if b < a)

    rtt_vals = sorted(rtts.values())
    def pct(p):
        return rtt_vals[min(len(rtt_vals) - 1, int(len(rtt_vals) * p))] * 1000 if rtt_vals else -1

    good_bytes = sum(len(snap[i]) for i in got if i not in bad)
    dur_send = t_send_done - t0
    dur_total = t_all_done - t0
    gput = good_bytes / dur_total / 1e6
    chan = good_bytes * 2 / dur_total / 1e6  # 数据渡链路两次

    # 重组
    ok_stream = all(i in snap for i in range(n)) and not bad
    if ok_stream:
        blob = b"".join(snap[i] for i in range(n))
        out_sha = hashlib.sha256(blob).hexdigest().upper()
        match = out_sha == src_sha
        if args.out:
            open(args.out, "wb").write(blob)
    else:
        out_sha, match = ("(有丢失/损坏, 未重组)" if not ok_stream else "?"), False

    print()
    print("==== 传输质量报告 ====")
    print(f"发送片数        : {n}")
    print(f"收到片数        : {len(got)}  ({len(got)*100.0/n:.2f}%)")
    print(f"丢失片数        : {len(lost)}  {('首丢:' + str(lost[:5])) if lost else ''}")
    print(f"损坏片数(MD5不符): {len(corrupt)} {('首坏:' + str(corrupt[:5])) if corrupt else ''}")
    print(f"到达流逆序对    : {inversions}")
    if rtt_vals:
        print(f"RTT ms  min/avg/p95/max : {rtt_vals[0]*1000:.2f} / {sum(rtt_vals)/len(rtt_vals)*1000:.2f} / {pct(0.95):.2f} / {rtt_vals[-1]*1000:.2f}")
    print(f"发送用时        : {dur_send:.2f}s   全程(含收尾): {dur_total:.2f}s")
    print(f"单向有效吞吐    : {gput:.2f} MB/s ({gput*8:.1f} Mbps)")
    print(f"等效信道速率    : {chan:.2f} MB/s ({chan*8:.1f} Mbps)  [数据渡链路两次]")
    print(f"重组 SHA256     : {out_sha}")
    print(f"SHA256 比对     : {'一致 ✓ 全量数据完好穿越光链路往返' if match else '不一致 ✗'}")

    summary = {
        "file_bytes": total, "chunks": n, "chunk_size": args.chunk,
        "gap_ms": args.gap_ms, "recv": len(got), "lost": len(lost),
        "corrupt": len(corrupt), "inversions": inversions,
        "rtt_avg_ms": (sum(rtt_vals)/len(rtt_vals)*1000) if rtt_vals else -1,
        "goodput_mbps": gput*8, "channel_mbps": chan*8, "sha_match": match,
    }
    print("JSON_STORM_SUMMARY: " + json.dumps(summary, ensure_ascii=False))
    return 0 if (len(lost) == 0 and len(corrupt) == 0 and match) else 1

if __name__ == "__main__":
    sys.exit(main())