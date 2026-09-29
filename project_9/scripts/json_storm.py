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
  python json_storm.py <文件> [--chunk 1466] [--gap-ms 1.0] [--port 1234]
                       [--limit-bytes N] [--parallel 1] [--pace-us 0]
                       [--sndbuf-mb 4] [--out 重组输出路径]
  # 离线自检(不建 socket / 不发送 / 未上板, 只验节奏器与构造开销):
  python json_storm.py --pacer-selfcheck 20000 --pace-us 12.5
  python json_storm.py --syscall-selfcheck 20000 --chunk 1466

2026-09-29 改造(实操单 v2 §六 A2/A3/A4/A6; 记录见
  操作文档/阶段二之十_prj9_json_storm改造与E1E5执行前置记录_2026-09-29.md):
  A2  发送循环瘦身 —— 全部帧的 struct.pack+切片在计时窗口之前一次性构造
      (_build_packets), 循环体只剩 取时刻 + sendto (+节拍等待);
      预构造耗时单独打印, 并额外给"含预构造速率"的诚实口径
  A3  发送 socket SO_SNDBUF 默认 4MB (--sndbuf-mb), 实际值 getsockopt 回读并打印
  A4  --chunk 默认 1360 -> 1466 (= 1472 - 6B 脚本头; 1472 会 IP 分片 -> 板端无重组
      -> 全丢), 显式 --chunk 仍完全生效(向后兼容)
  A6  --pace-us 忙等节奏器 —— perf_counter() 忙等到绝对时刻 t0+k*周期, 全程不用
      time.sleep(R5: Windows 高精度定时器 ~500µs 分辨率, 睡不出 12.5µs);
      --parallel N 时每进程周期 = --pace-us × N, 使聚合帧周期 = --pace-us;
      钉不住时如实计 pace_late(不假装钉住了)
  启动打印一行"生效口径"(chunk/帧长/pace/gap/parallel/sndbuf/目标速率), 日志自带口径
"""
import argparse, hashlib, json, os, socket, struct, sys, threading, time

# ------------------------------------------------------- 帧口径常量(实操单 v2 §三)
APP_HDR   = 6                 # [4B seq][2B len]
CHUNK_MAX = 1466              # = 1472 - 6; 再大就 IP 分片, 板端栈无重组 -> 全丢
DEST_IP   = "192.168.1.10"    # 板卡(prj9 判决位流)
WIRE_US   = 12.304            # chunk=1466 时千兆线上帧周期(1538 B @ 1000 Mbps)


def wire_sizes(chunk):
    """实操单 v2 §三口径: 返回 (UDP载荷B, IP包B, 以太帧B, 线上B)"""
    udp  = APP_HDR + chunk
    ipk  = 20 + 8 + udp
    eth  = 14 + ipk + 4        # 14 Eth 头 + IP 包 + 4 FCS
    wire = 8 + eth + 12        # 8 前导/SFD + 以太帧 + 12 IFG
    return udp, ipk, eth, wire


def _build_packets(data, chunk, seqs=None):
    """A2 核心: 一次性构造全部待发帧, 把 struct.pack + 切片搬出发送计时窗口。

    返回 [(seq, pkt_bytes), ...]; seqs=None 表示构造全部帧, 也供各进程只构造自己
    那一段(seq % nproc == wid)。临时切片每轮即释放, 故内存 ≈ len(data) + Σ包体。
    """
    if seqs is None:
        seqs = range((len(data) + chunk - 1) // chunk)
    out = []
    add = out.append
    for i in seqs:
        c = data[i * chunk:(i + 1) * chunk]
        add((i, struct.pack("<IH", i, len(c)) + c))
    return out


def _pace_period_us(args, nproc):
    """A6: 返回"每进程"的帧周期(µs); 0 = 不启用节奏器。

    --parallel N 时聚合帧周期 = --pace-us, 各进程只发自己 1/N 的帧, 故每进程周期
    = --pace-us × N(独立节拍, 进程间不通信)。
    """
    if args.pace_us <= 0:
        return 0.0
    return args.pace_us * nproc


def print_profile(args, nproc, sndbuf_req):
    """运行开始打印生效口径(实操单 §六 要求: 让实验日志自带口径)"""
    udp, ipk, eth, wire = wire_sizes(args.chunk)
    per_proc = _pace_period_us(args, nproc)
    agg = per_proc / nproc if per_proc else 0.0
    net_limit = args.chunk / wire * 1000.0        # 该 chunk 下的净载荷线速上限
    parts = [f"chunk={args.chunk}B", f"UDP载荷={udp}B", f"以太帧={eth}B",
             f"线上={wire}B(含前导+IFG)"]
    if agg:
        fps = 1e6 / agg
        parts.append(f"pace={agg:.3f}µs/帧" + (f"(每进程 {per_proc:.3f}µs)" if nproc > 1 else "")
                     + f"→目标 {args.chunk * fps * 8 / 1e6:.1f}Mbps @{fps / 1000:.2f}kfps")
        arb = f"pace 接管节奏, --gap-ms={args.gap_ms}ms 被忽略(R5: sleep 无 µs 精度)"
    else:
        parts.append(f"gap={args.gap_ms}ms(sleep 节拍, Windows 精度 ~0.5ms)")
        arb = f"未启用 pace(--pace-us=0), 用 --gap-ms={args.gap_ms}ms"
    parts.append(f"parallel={nproc}")
    parts.append(f"sndbuf={sndbuf_req / 1048576:.2f}MB")
    print("生效口径: " + " | ".join(parts))
    print(f"节奏裁决: {arb} | 该 chunk 净载荷线速上限 {net_limit:.1f}Mbps")
    if args.chunk > CHUNK_MAX:
        print(f"!! 警告: chunk={args.chunk} > {CHUNK_MAX} -> UDP 载荷={udp}B 超 MTU -> IP 分片 "
              f"-> 板端栈无分片重组 -> 全丢(实操单 v2 §六 A4)")
    if agg and agg < WIRE_US:
        print(f"!! 警告: pace={agg:.3f}µs/帧 < 千兆线上帧周期 {WIRE_US}µs -> 目标速率超线速, "
              f"必然被 NIC 背压/板端丢弃")


def _iv_stats_us(t_list):
    """相邻发送时刻差(µs)的统计"""
    iv = sorted((b - a) * 1e6 for a, b in zip(t_list, t_list[1:]))
    if not iv:
        return {}
    def q(p):
        return iv[min(len(iv) - 1, int(len(iv) * p))]
    return {"n": len(iv), "min": iv[0], "avg": sum(iv) / len(iv),
            "p50": q(0.50), "p95": q(0.95), "max": iv[-1]}


def _run_send(pkts, sendto, addr, period_s, gap_s, t_send, t_list):
    """发送循环(单进程 / 多进程 worker / 离线自检共用同一份代码, 保证自检的就是实跑的那段)。

    sendto=None  -> 只跑节奏器与记账(离线自检, 不发送)
    period_s>0   -> A6 忙等到下一帧目标时刻, 全程不用 sleep; 相对节拍(见下), 不追账
    gap_s>0      -> 旧语义 time.sleep(仅当未启用 pace)
    返回 {t_end, waited, late, lag_s}: waited=真的等到了; late=上一帧之后已被抢占超一个周期

    相对节拍(下一帧目标 = 本帧实际发出时刻 + period), 而不是绝对时间轴 t0+k*period。
    理由(离线自检实测, 未上板): 绝对时间轴下, 一次 OS 抢占(实测 150-180µs ≈ 12-14 个周期)
    会积欠十几个周期, 追赶时连续十几帧背靠背发出 —— 实测最小帧间隔 0.2µs(定点追账)/
    0.5µs(仅迟到时重定基准), 都会瞬时打穿板端零裕量通路(实操单 §三 定论 2-b / §四 R1),
    造成实验假失败。相对节拍下"帧间隔 >= 目标周期"由构造保证, 可被自检断言(实测 min ≈ 12.4µs),
    代价是抢占耗时如实计入平均周期(实测 12.53-12.57µs vs 目标 12.5µs, 慢 0.3-0.6%)。
    """
    perf = time.perf_counter
    n_wait = n_late = 0
    lag = 0.0
    t_next = perf()                         # 首帧立即发
    for k, (i, pkt) in enumerate(pkts):
        if period_s:
            now = perf()
            if now < t_next:
                while perf() < t_next:      # 忙等: 绝不 sleep(R5)
                    pass
                n_wait += 1
            else:
                n_late += 1                 # 上一帧之后被抢占超一个周期: 如实记账, 不假装钉住
                lag += now - t_next
        ts = perf()
        if period_s:
            t_next = ts + period_s          # 相对节拍: 下一帧至少隔一个周期 -> 永不压缩/不追账
        t_send[i] = ts
        t_list.append(ts)
        if sendto is not None:
            sendto(pkt, addr)
        if gap_s:
            time.sleep(gap_s)
    return {"t_end": perf(), "waited": n_wait, "late": n_late, "lag_s": lag}


def _ensure_parent(path):
    d = os.path.dirname(os.path.abspath(path))
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)


# ============================================================ 离线自检(未上板)
def pacer_selfcheck(args):
    """A6 离线自检: 不建 socket、不发送, 跑与实跑同构的 _run_send, 量出
    (a) A2 预构造的每帧成本 (b) perf_counter() 单次成本 (c) 节奏器实际节拍/迟发/CPU 代价。
    注意: 不含 sendto; 真实 syscall 成本须上板 E1 实测(--syscall-selfcheck 只给环回下界)。
    """
    print_profile(args, max(1, args.parallel), int(args.sndbuf_mb * 1048576))
    N = args.pacer_selfcheck
    period_s = _pace_period_us(args, 1) / 1e6
    src = bytes(args.chunk * N)                       # 只为构造 N 帧, 内容无关
    t_p0 = time.perf_counter()
    pkts = _build_packets(src, args.chunk)
    t_p1 = time.perf_counter()
    prep_s = t_p1 - t_p0
    del src
    perf = time.perf_counter
    K = 200000
    a = perf()
    for _ in range(K):
        perf()
    b = perf()
    pc_ns = (b - a) / K * 1e9
    t_send, t_list = {}, []
    cpu0, w0 = time.process_time(), perf()
    run = _run_send(pkts, None, None, period_s, 0.0, t_send, t_list)
    w1, cpu1 = perf(), time.process_time()
    wall_s, cpu_s = w1 - w0, cpu1 - cpu0
    iv = _iv_stats_us(t_list)
    print()
    print("==== 节奏器离线自检(未上板: 不建 socket, 不发送) ====")
    print(f"帧数 / chunk    : {N} / {args.chunk}B  (构造内存 ≈ {N * args.chunk / 1048576:.1f} MB)")
    print(f"目标节拍        : {period_s * 1e6:.3f} µs/帧" + ("  (pace-us=0: 不等待, 测纯循环开销)" if not period_s else f"  (--pace-us={args.pace_us})"))
    print(f"A2 预构造       : {prep_s * 1000:.1f} ms  →  {prep_s / N * 1e6:.3f} µs/帧")
    print(f"perf_counter()  : {pc_ns:.1f} ns/次")
    print(f"循环墙钟        : {wall_s * 1e6 / N:.3f} µs/帧      CPU: {cpu_s * 1e6 / N:.3f} µs/帧"
          f"  (总 {cpu_s * 1000:.1f} ms; Windows process_time 粒度 ~15.6ms, 短样本显示 0 属正常)")
    if iv:
        print(f"节拍实测 µs     : min {iv['min']:.3f} / avg {iv['avg']:.3f} / p50 {iv['p50']:.3f} / p95 {iv['p95']:.3f} / max {iv['max']:.3f}")
        if period_s:
            print(f"突发检查        : 最短帧间隔 {iv['min']:.3f} µs vs 目标 {period_s * 1e6:.3f} µs -> "
                  + ("无背靠背突发 ✓(帧间隔恒 >= 目标)" if iv["min"] >= period_s * 1e6 * 0.99 else "存在背靠背突发 ✗(会打穿板端零裕量)"))
    print(f"节拍等待/抢占   : 忙等命中 {run['waited']} 帧, 入口已过期(OS 抢占) {run['late']} 帧, 累计滞后 {run['lag_s'] * 1e6:.1f} µs")
    if period_s:
        real_us = wall_s * 1e6 / N
        tgt_us = period_s * 1e6
        mean_iv = iv["avg"] if iv else real_us          # 用帧间隔均值(N-1 个), 不受首帧不等影响
        print(f"速率代价        : 实测平均帧间隔 {mean_iv:.3f} µs/帧 vs 目标 {tgt_us:.3f} -> "
              f"目标速率 {args.chunk / period_s / 1e6 * 8:.1f} Mbps, 实测 {args.chunk / (mean_iv * 1e-6) / 1e6 * 8:.1f} Mbps")
        print(f"结论            : " + (f"节拍钉住 ✓ 帧间隔恒 >= 目标(本自检不含 sendto); "
              f"平均周期比目标慢 {100 * (real_us - tgt_us) / tgt_us:.2f}% = OS 抢占耗时(如实计入, 不追赶)"
              if iv and iv["min"] >= tgt_us * 0.99 else
              "节拍被压缩 ✗ 出现 < 目标周期的帧间隔(会打穿板端零裕量)"))
    summary = {"n": N, "chunk": args.chunk, "pace_us": args.pace_us,
               "period_us": period_s * 1e6, "prep_s": round(prep_s, 4),
               "prep_us_per_frame": round(prep_s / N * 1e6, 3),
               "perf_counter_ns": round(pc_ns, 1),
               "loop_us_per_frame": round(wall_s * 1e6 / N, 3),
               "cpu_us_per_frame": round(cpu_s * 1e6 / N, 3),
               "iv_us": {k: round(v, 3) for k, v in iv.items()},
               "waited": run["waited"], "late": run["late"],
               "lag_us": round(run["lag_s"] * 1e6, 1), "onboard": False}
    print("PACER_SELFCHECK: " + json.dumps(summary, ensure_ascii=False))
    return 0


def syscall_selfcheck(args):
    """离线自检(未上板, 环回): 向 127.0.0.1:9 实发 N 帧, 量 sendto 单帧成本的下界。
    环回不走 ARP/PHY/板卡, 故这是下界, **不是吞吐测量**, 不得当板卡数字引用。"""
    print_profile(args, max(1, args.parallel), int(args.sndbuf_mb * 1048576))
    N = args.syscall_selfcheck
    req = int(args.sndbuf_mb * 1048576)
    src = bytes(args.chunk * N)
    pkts = _build_packets(src, args.chunk)
    del src
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, req)
    act = s.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)
    t_send, t_list, errs = {}, [], []
    try:
        run = _run_send(pkts, s.sendto, ("127.0.0.1", 9), 0.0, 0.0, t_send, t_list)
    except OSError as e:
        errs.append(repr(e))
        run = {"t_end": time.perf_counter(), "waited": 0, "late": 0, "lag_s": 0.0}
    n_sent = len(t_list)
    wall = run["t_end"] - t_list[0] if t_list else 0.0
    per_us = wall / n_sent * 1e6 if n_sent else -1
    iv = _iv_stats_us(t_list)
    s.close()
    print()
    print("==== sendto 离线自检(未上板: 环回 127.0.0.1:9, 非板卡吞吐) ====")
    print(f"帧数 / chunk    : {N} / {args.chunk}B")
    print(f"SO_SNDBUF       : 请求 {req / 1048576:.2f}MB -> 实际 {act / 1048576:.2f}MB")
    print(f"sendto 单帧     : {per_us:.3f} µs/帧 (环回下界, 含取时刻+记账)")
    if iv:
        print(f"帧间隔 µs       : avg {iv['avg']:.3f} / p95 {iv['p95']:.3f} / max {iv['max']:.3f}")
    print(f"环回循环上限    : {1e6 / per_us:.0f} fps ≈ {args.chunk * 1e6 / per_us * 8 / 1e6:.0f} Mbps 净载荷")
    print(f"异常            : {len(errs)} {errs[:1]}")
    print("SYSCALL_SELFCHECK: " + json.dumps(
        {"n": n_sent, "chunk": args.chunk, "sndbuf_req": req, "sndbuf_actual": act,
         "sendto_us_per_frame": round(per_us, 3), "iv_us": {k: round(v, 3) for k, v in iv.items()},
         "errors": len(errs), "onboard": False}, ensure_ascii=False))
    return 0


# ============================================================ 多进程
def _worker(args, wid, nproc, data, n, src_sha):
    """每个进程: 独立端口 + 独立 seq 段, 返回 (wid, {seq: payload}, {stats})"""
    import socket as sk
    port = args.port + wid * 2
    # 本进程负责的 seq 段(交错分配: seq % nproc == wid, 负载与丢失在时间上均匀)
    mine = [i for i in range(n) if i % nproc == wid]
    period_s = _pace_period_us(args, nproc) / 1e6      # A6: 每进程 N 倍周期
    gap_s = 0.0 if period_s else args.gap_ms / 1000.0
    t_prep = time.perf_counter()
    my_pkts = _build_packets(data, args.chunk, mine)   # A2: 只构造本进程那一段
    prep_s = time.perf_counter() - t_prep
    s = sk.socket(sk.AF_INET, sk.SOCK_DGRAM)
    s.bind(("0.0.0.0", port))
    s.setsockopt(sk.SOL_SOCKET, sk.SO_RCVBUF, 4 * 1024 * 1024)
    s.setsockopt(sk.SOL_SOCKET, sk.SO_SNDBUF, int(args.sndbuf_mb * 1048576))   # A3
    snd_act = s.getsockopt(sk.SOL_SOCKET, sk.SO_SNDBUF)
    s.settimeout(0.002)
    recv = {}; t_send = {}
    # 注意: 此处不能再 import time/struct/threading —— 函数内有 import 会让这些名字变成
    # 局部变量, 使函数前段(如 t_prep = time.perf_counter())抛 UnboundLocalError。
    # 模块级已有 import argparse, hashlib, json, os, socket, struct, sys, threading, time。
    done = threading.Event()
    def rx():
        while not done.is_set():
            try:
                pkt, _ = s.recvfrom(65535)
            except sk.timeout:
                continue
            except OSError:
                break
            if len(pkt) < 6:
                continue
            seq, ln = struct.unpack("<IH", pkt[:6])
            if seq < n:
                recv[seq] = pkt[6:]
                if seq in t_send:
                    rtts_w[seq] = time.perf_counter() - t_send[seq]
    rtts_w = {}
    th = threading.Thread(target=rx, daemon=True)
    th.start()
    t_list = []
    run = _run_send(my_pkts, s.sendto, (DEST_IP, port), period_s, gap_s, t_send, t_list)
    t_done = run["t_end"]
    deadline = time.time() + 3.0
    while time.time() < deadline and len(recv) < len(mine):
        time.sleep(0.05)
    done.set(); th.join(timeout=1)
    return wid, dict(recv), {"t_done": t_done, "rtts": dict(rtts_w), "port": port,
                             "prep_s": prep_s, "sndbuf": snd_act,
                             "pacer": {"waited": run["waited"], "late": run["late"],
                                       "lag_s": run["lag_s"], "iv": _iv_stats_us(t_list)}}


def run_parallel(data, args):
    import hashlib, json, multiprocessing as mp, struct, time
    total = len(data)
    if args.limit_bytes:
        data = data[: args.limit_bytes]
        total = len(data)
    src_sha = hashlib.sha256(data).hexdigest().upper()
    n = (total + args.chunk - 1) // args.chunk
    nproc = args.parallel
    print_profile(args, nproc, int(args.sndbuf_mb * 1048576))
    print(f"负载: {total} B -> {n} 片 x {args.chunk} B, 并行 {nproc} 进程")
    print(f"源 SHA256: {src_sha}")
    t0 = time.perf_counter()
    ctx = mp.get_context("spawn")
    with ctx.Pool(nproc) as pool:
        results = pool.starmap(_worker, [(args, w, nproc, data, n, src_sha) for w in range(nproc)])
    dur_send = max(r[2]["t_done"] for r in results) - t0
    dur_total = time.perf_counter() - t0
    recv = {}
    for wid, d, st in results:
        recv.update(d)
    t_prep_max = max(r[2]["prep_s"] for r in results)
    t_prep_sum = sum(r[2]["prep_s"] for r in results)
    snd_acts = [r[2]["sndbuf"] for r in results]
    pace_late = sum(r[2]["pacer"]["late"] for r in results)
    pace_waited = sum(r[2]["pacer"]["waited"] for r in results)
    pace_iv = [r[2]["pacer"]["iv"]["avg"] for r in results if r[2]["pacer"]["iv"]]
    md5s = {i: hashlib.md5(data[i*args.chunk:(i+1)*args.chunk]).hexdigest() for i in range(n)}
    got = sorted(recv.keys())
    lost = [i for i in range(n) if i not in recv]
    bad = [i for i in got if hashlib.md5(recv[i]).hexdigest() != md5s[i]]
    rtts = sorted(v for _, _, st in results for v in st["rtts"].values())
    def pct(p):
        return rtts[min(len(rtts)-1, int(len(rtts)*p))] * 1000 if rtts else -1
    good_bytes = sum(len(recv[i]) for i in got if i not in bad)
    gput_send = good_bytes / dur_send / 1e6 if dur_send > 0 else 0
    ok_stream = all(i in recv for i in range(n)) and not bad
    if ok_stream:
        blob = b"".join(recv[i] for i in range(n))
        out_sha = hashlib.sha256(blob).hexdigest().upper()
        match = out_sha == src_sha
        if args.out:
            _ensure_parent(args.out)
            open(args.out, "wb").write(blob)
    else:
        out_sha, match = "(有丢失/损坏, 未重组)", False
    print()
    print("==== 传输质量报告(并行) ====")
    print(f"发送片数        : {n}  (进程端口: {[st['port'] for _,_,st in results]})")
    print(f"收到片数        : {len(got)}  ({len(got)*100.0/n:.2f}%)")
    print(f"丢失片数        : {len(lost)}  {('首丢:' + str(lost[:5])) if lost else ''}")
    print(f"损坏片数(MD5不符): {len(bad)}")
    if rtts:
        print(f"RTT ms  min/avg/p95/max : {rtts[0]*1000:.2f} / {sum(rtts)/len(rtts)*1000:.2f} / {pct(0.95):.2f} / {rtts[-1]*1000:.2f}")
    print(f"发送用时        : {dur_send:.2f}s")
    print(f"A2 预构造(各进程): {t_prep_sum*1000:.1f} ms 合计, 最慢 {t_prep_max*1000:.1f} ms(不计入下方速率)")
    print(f"发送阶段速率    : {gput_send:.2f} MB/s ({gput_send*8:.1f} Mbps)  [{nproc} 进程聚合, 纯 sendto 循环]")
    if dur_send + t_prep_max > 0:
        print(f"含预构造速率    : {good_bytes/(dur_send+t_prep_max)/1e6*8:.1f} Mbps  [诚实口径: 预构造+发送]")
    print(f"SO_SNDBUF(实际) : {[x for x in snd_acts]} B  (请求 {int(args.sndbuf_mb*1048576)} B)")
    if args.pace_us > 0:
        agg = args.pace_us
        print(f"节拍实测        : 目标聚合 {agg:.3f}µs/帧(每进程 {_pace_period_us(args,nproc):.3f}µs), "
              f"各进程平均帧间隔 µs = {[round(v,3) for v in pace_iv]}")
        print(f"节拍等待/抢占   : 各进程合计 忙等命中 {pace_waited} 帧, 入口已过期(OS 抢占) {pace_late} 帧"
              + ("  (无压缩突发)" if pace_late == 0 else "  (抢占后不追账, 帧间隔不变量仍成立)"))
        if pace_iv:
            per_proc = _pace_period_us(args, nproc)
            mean_iv = sum(pace_iv) / len(pace_iv)
            print("判定            : " + (f"节拍有效 —— 每进程实测平均帧间隔 {mean_iv:.3f}µs <= 每进程目标 {per_proc:.3f}µs×1.05"
                  if mean_iv <= per_proc * 1.05 else
                  f"!! pacer 形同虚设 —— 每进程单帧耗时(≈{mean_iv:.3f}µs) > 每进程目标({per_proc:.3f}µs), 实测速率 = PC 上限"))
    print(f"等效信道速率    : {gput_send*2:.2f} MB/s ({gput_send*16:.1f} Mbps)  [数据渡链路两次]")
    print(f"重组 SHA256     : {out_sha}")
    print(f"SHA256 比对     : {'一致 ✓ 全量数据完好穿越光链路往返' if match else '不一致 ✗'}")
    summary = {"file_bytes": total, "chunks": n, "chunk_size": args.chunk, "parallel": nproc,
               "recv": len(got), "lost": len(lost), "corrupt": len(bad),
               "rtt_avg_ms": (sum(rtts)/len(rtts)*1000) if rtts else -1,
               "goodput_send_mbps": gput_send*8, "sha_match": match,
               "pace_us": args.pace_us, "pace_per_proc_us": _pace_period_us(args, nproc),
               "pace_late": pace_late, "prep_s_max": round(t_prep_max, 4),
               "sndbuf_requested": int(args.sndbuf_mb*1048576), "sndbuf_actual": snd_acts}
    print("JSON_STORM_SUMMARY: " + json.dumps(summary, ensure_ascii=False))
    return 0 if (len(lost) == 0 and len(bad) == 0 and match) else 1


# ============================================================ 单进程
def main():
    ap = argparse.ArgumentParser(
        description="prj9 会话 JSON 全量传输质量测试器(UDP 打过 FPGA 光链路, 回显重组比对)",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", nargs="?", default="", help="负载文件(自检模式下可省略)")
    ap.add_argument("--chunk", type=int, default=CHUNK_MAX,
                    help=f"单帧净载荷字节, 默认 {CHUNK_MAX} = 1472-6; >{CHUNK_MAX} 会 IP 分片 -> 板端全丢")
    ap.add_argument("--gap-ms", type=float, default=1.0,
                    help="帧间隔 ms, time.sleep 实现(精度 ~0.5ms); --pace-us>0 时被忽略")
    ap.add_argument("--pace-us", type=float, default=0.0,
                    help="A6 忙等节奏器: 每帧目标周期 µs, 0=关闭; 与 --gap-ms 同时给出时 pace 优先")
    ap.add_argument("--sndbuf-mb", type=float, default=4.0, help="A3 发送 socket SO_SNDBUF(MB)")
    ap.add_argument("--port", type=int, default=1234)
    ap.add_argument("--limit-bytes", type=int, default=0, help="只发前 N 字节(校准用)")
    ap.add_argument("--out", default="", help="重组输出路径(父目录不存在会自动创建)")
    ap.add_argument("--parallel", type=int, default=1,
                    help="并行进程数(各持独立端口, 真并行绕开 GIL); 每进程节拍 = pace-us × N")
    ap.add_argument("--pacer-selfcheck", type=int, default=0, metavar="N",
                    help="离线自检: 不建 socket/不发送, 跑 N 帧同构循环验节奏器(N×chunk 字节会被构造)")
    ap.add_argument("--syscall-selfcheck", type=int, default=0, metavar="N",
                    help="离线自检: 向 127.0.0.1 实发 N 帧, 测 sendto 单帧成本环回下界(非吞吐)")
    args = ap.parse_args()

    if args.chunk <= 0:
        ap.error("--chunk 必须为正")
    if args.parallel < 1:
        ap.error("--parallel 必须 >= 1")
    if args.pacer_selfcheck:
        return pacer_selfcheck(args)
    if args.syscall_selfcheck:
        return syscall_selfcheck(args)
    if not args.file:
        ap.error("需要 <文件> 参数(或用 --pacer-selfcheck / --syscall-selfcheck 做离线自检)")

    data = open(args.file, "rb").read()
    if args.parallel > 1:
        return run_parallel(data, args)
    if args.limit_bytes:
        data = data[: args.limit_bytes]
    total = len(data)
    src_sha = hashlib.sha256(data).hexdigest().upper()
    gap_s = args.gap_ms / 1000.0
    period_s = _pace_period_us(args, 1) / 1e6
    if period_s:
        gap_s = 0.0                      # A6 裁决: pace 接管, gap 忽略

    print_profile(args, 1, int(args.sndbuf_mb * 1048576))

    t_prep = time.perf_counter()
    pkts = _build_packets(data, args.chunk)                       # A2: pack+切片移出计时窗口
    md5s = [hashlib.md5(p[1][APP_HDR:]).hexdigest() for p in pkts]  # MD5 取自实际包体
    prep_s = time.perf_counter() - t_prep
    n = len(pkts)

    print(f"负载: {total} B -> {n} 片 x {args.chunk} B, 预构造 {prep_s*1000:.1f} ms({prep_s/n*1e6:.3f} µs/帧, 不含在发送计时内)")
    print(f"源 SHA256: {src_sha}")

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", args.port))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    req = int(args.sndbuf_mb * 1048576)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, req)        # A3
    snd_act = s.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)
    s.settimeout(0.002)
    print(f"发送 socket: SO_SNDBUF 请求 {req} B -> 实际 {snd_act} B (getsockopt 回读)"
          + ("  ⚠ 被系统夹取" if snd_act < req else "  ✓"))

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

    t_list = []
    run = _run_send(pkts, s.sendto, (DEST_IP, args.port), period_s, gap_s, t_send, t_list)
    t_send_done = run["t_end"]

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
    dur_send = t_send_done - t_send[0] if t_send else 0.0
    dur_total = t_all_done - t_send[0] if t_send else 0.0
    gput = good_bytes / dur_total / 1e6
    chan = good_bytes * 2 / dur_total / 1e6  # 数据渡链路两次

    # 重组
    ok_stream = all(i in snap for i in range(n)) and not bad
    if ok_stream:
        blob = b"".join(snap[i] for i in range(n))
        out_sha = hashlib.sha256(blob).hexdigest().upper()
        match = out_sha == src_sha
        if args.out:
            _ensure_parent(args.out)
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
    gput_send = good_bytes / dur_send / 1e6 if dur_send > 0 else 0
    print(f"A2 预构造用时   : {prep_s*1000:.1f} ms ({prep_s/n*1e6:.3f} µs/帧, 已移出发送计时窗口)")
    print(f"单向有效吞吐    : {gput:.2f} MB/s ({gput*8:.1f} Mbps)")
    print(f"发送阶段速率    : {gput_send:.2f} MB/s ({gput_send*8:.1f} Mbps)  [扣除收尾等待, 纯 sendto 循环+节拍]")
    print(f"含预构造速率    : {good_bytes/(dur_send+prep_s)/1e6*8:.1f} Mbps  [诚实口径: 预构造+发送]")
    if period_s:
        agg = period_s * 1e6
        iv = _iv_stats_us(t_list)
        print(f"节拍实测        : 目标 {agg:.3f}µs/帧, 实测 min/avg/p50/p95/max = "
              f"{iv['min']:.3f}/{iv['avg']:.3f}/{iv['p50']:.3f}/{iv['p95']:.3f}/{iv['max']:.3f} µs")
        print(f"突发检查        : 最短帧间隔 {iv['min']:.3f} µs vs 目标 {agg:.3f} µs -> "
              + ("无背靠背突发 ✓(帧间隔恒 >= 目标)" if iv["min"] >= agg * 0.99 else "存在突发 ✗(会打穿板端零裕量)"))
        print(f"节拍等待/抢占   : 忙等命中 {run['waited']} 帧, 入口已过期(OS 抢占) {run['late']} 帧, 累计滞后 {run['lag_s']*1e6:.1f} µs")
        print("判定            : " + (f"节拍有效 —— 帧周期由脚本设定({agg:.3f}µs), 实测速率是设计值, 不是 PC 上限"
              if iv["avg"] <= agg * 1.05 else
              f"!! pacer 形同虚设 —— 单帧耗时(≈{iv['avg']:.2f}µs) > 目标周期({agg:.3f}µs), 帧间隔被 sendto 顶穿; "
              f"此刻实测速率 = PC 单进程上限而非设定值, 不得读成硬件上限(实操单 §十 风险 5 -> B2)"))
    print(f"等效信道速率    : {chan:.2f} MB/s ({chan*8:.1f} Mbps)  [数据渡链路两次]")
    print(f"重组 SHA256     : {out_sha}")
    print(f"SHA256 比对     : {'一致 ✓ 全量数据完好穿越光链路往返' if match else '不一致 ✗'}")

    iv_all = _iv_stats_us(t_list) if period_s else {}
    summary = {
        "file_bytes": total, "chunks": n, "chunk_size": args.chunk,
        "gap_ms": args.gap_ms, "pace_us": args.pace_us,
        "pace_per_proc_us": _pace_period_us(args, 1),
        "sndbuf_requested": req, "sndbuf_actual": snd_act,
        "prep_s": round(prep_s, 4), "prep_us_per_frame": round(prep_s/n*1e6, 3) if n else -1,
        "recv": len(got), "lost": len(lost),
        "corrupt": len(corrupt), "inversions": inversions,
        "rtt_avg_ms": (sum(rtt_vals)/len(rtt_vals)*1000) if rtt_vals else -1,
        "goodput_mbps": gput*8, "goodput_send_mbps": gput_send*8, "channel_mbps": chan*8, "sha_match": match,
        "pace_late": run["late"], "pace_waited": run["waited"],
        "pace_iv_avg_us": round(iv_all.get("avg", -1), 3),
    }
    print("JSON_STORM_SUMMARY: " + json.dumps(summary, ensure_ascii=False))
    return 0 if (len(lost) == 0 and len(corrupt) == 0 and match) else 1


if __name__ == "__main__":
    sys.exit(main())
