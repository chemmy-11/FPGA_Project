#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
j3_random_read.py — prj10 W5 · 随机读判据 J3 / J3' 上位机测试脚本（PC 侧）

唯一接口依据: C:\\Users\\15266\\Desktop\\毕设\\操作文档\\阶段三_prj10_W5命令通道接口契约_2026-10-07.md
  §2.1 命令帧(PC→板) / §2.2 应答帧(板→PC) / §2.3 数据帧回流
  §4.1 主轮十步 / §4.2 负向轮 A(漏发)·B(重发) / §4.3 计数对账口径

数据路径（W4 已通的环路 + W5 命令通道）:
  PC ──数据帧(PC:1236 → 板:1234)──> 以太网栈 ──> 泵A ──> 桥①(写 DDR4 槽 k = 帧计数 mod 256)
                                                              │
                    PC <──回显帧(板:1234 → PC:1236)── 泵B <── 桥② <── Aurora 10G 光环路 <── 桥①读槽
  PC ──命令(P10C, PC:1235 → 广播:1235)──> 栈按「目的 IP ≠ 板 IP」丢弃 + cmd_channel 解析
                    PC <──应答(P10R, 板:1235 → PC:1235)── 泵B <── 桥② <── Aurora <── 桥① <── 泵A <── cmd_channel

### 为什么用「两个本地端口」（契约 §2.2 / §2.3 的直接推论）
  契约 §2.2 规定应答帧的**目的端口 = 命令帧的源端口**；§2.3 规定数据帧是「当初写进去
  的那一帧」的回显，其**目的端口 = 数据帧的源端口**（官方栈 eth_udp_loop 回显语义）。
  于是两类包的本地目的端口由**发起方各自的源端口**决定，天生分流：
    · 命令 socket 绑 PC:1235  → 只收到 P10R 应答（magic 校验兜底）
    · 数据 socket 绑 PC:1236  → 只收到被读出的帧回显（板侧源端口 1234）
  若两类包共用一个本地端口，就只能靠「magic 是否等于 P10R」事后区分，随机读时
  「某条命令对应的数据帧」与「下一条命令的应答」会交错进同一 recv 队列，判决口径变脏。
  因此本脚本固定用两个端口；--data-port 可改，但不要与 --cmd-port 相同。

### 槽 ↔ 帧映射（写侧规则本地可复算；契约 §4.1 + GET_SLOT_MAP 的「规则号 = 1」）
  写侧: 第 k 帧（k 从 0 起，含本轮起始偏移）→ 槽 k mod 256
  读侧: READ_SLOT(s) 读回的必然是「最近一次写进槽 s 的那一帧」。
  主轮不跨轮（nslots ≤ 256），于是 **seq k → 槽 k**（第 0 帧落槽 0，第 255 帧落槽 255）。
  用 GET_WATERMARK 基线对齐（漂移抵消）:
      wr0 = value16(基线)              # u_wr_frame 基线，16bit、回绕 mod 65536
      第 k 帧的帧计数 = wr0 + k        → 槽 = (wr0 + k) mod 256
      本脚本从 k=0 起连发、且发完复核「u_wr_frame 增量 = nslots」（中间无丢帧），
      故第 k 帧实际落槽 = (wr0 + k) mod 256，与上式同式 ⇒ 槽号无偏移、无需人为补偿。
      nslots = 256 时结论最强（整圈覆盖、无「一个槽装两帧」的别名）。
  读取顺序: 随机置换 P（--seed 可复现）；喂给槽 s 的命令期望取回帧号 k 满足 k ≡ s (mod 256)。
  计数器按 mod 65536 做差（契约 §2.2 的 value16 是 16bit）。

### 判据
  J3  = 数据帧**按命令顺序**到达（逐条对应、0 串帧） 且 **读出顺序 ≠ 写入顺序**（置换逆序对数 > 0）
  J3' = 集合级相等：0 缺帧 / 0 多余 / 0 字节差异（逐字节比对期望载荷）
  负向 A（漏发）: 置换故意少 1 槽 ⇒ 必须报「恰好缺 1 帧」且 u_rd_frame 增量 = 255
  负向 B（重发）: 置换故意重复 1 槽 ⇒ 第二次读同槽收不到数据帧（超时即预期现象，桥①读完即退休该槽），
                  判读口径 =「命令数 = nslots+1、实取 = nslots、集合仍相等」；
                  ill_rd_cnt +1 须由 ILA 佐证（本脚本不读 ILA，只在结论里提示）

### 纪律
  纯标准库；只跑网络流量 + 写自己的日志/JSON；不改任何 RTL / 其它脚本 / 构建脚本。
  Windows 中文控制台**必须** PYTHONUTF8=1（GBK 控制台打印中文/符号会崩）。

用法:
  set PYTHONUTF8=1                      & rem cmd.exe
  $env:PYTHONUTF8=1                     # PowerShell
  python j3_random_read.py --mock                        # 无板卡全流程自检（主轮 + 两个负向轮）
  python j3_random_read.py --mock --log j3_mock_selftest.log
  python j3_random_read.py                               # 真机：主轮 + 两个负向轮
  python j3_random_read.py --nslots 64 --pace-us 2000    # 真机快速冒烟
  python j3_random_read.py --no-neg --json-out j3_summary.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import socket
import struct
import sys
import threading
import time

# --------------------------------------------------------------- 常量（契约 §2）

CMD_MAGIC = b"P10C"          # 命令帧 magic（PC → 板）
RESP_MAGIC = b"P10R"         # 应答帧 magic（板 → PC）
OP_SET_MODE = 0x01
OP_READ_SLOT = 0x02
OP_GET_WATERMARK = 0x03
OP_GET_SLOT_MAP = 0x04
OP_NAMES = {OP_SET_MODE: "SET_MODE", OP_READ_SLOT: "READ_SLOT",
            OP_GET_WATERMARK: "GET_WATERMARK", OP_GET_SLOT_MAP: "GET_SLOT_MAP"}
STATUS_NAMES = {0: "OK", 1: "参数非法", 2: "忙/丢弃"}

MODE_SEQ, MODE_RND = 0, 1

BOARD_IP = "192.168.1.10"          # 板卡单播 IP（数据面目的）
BCAST_IP = "192.168.1.255"         # 命令面目的 IP = 广播（§2.1：官方栈按目的 IP ≠ 板 IP 丢弃）
CMD_PORT = 1235                    # 命令/应答端口（板侧固定）
DATA_PORT = 1234                   # 数据面端口（板侧固定）
PC_CMD_PORT = 1235                 # PC 命令源端口 = 应答目的端口（§2.2）
PC_DATA_PORT = 1236                # PC 数据源端口 = 回显帧目的端口（§2.3）
NSLOTS_MAX = 256                   # 写槽规则 = 帧计数 mod 256
# --mock-loopback 专用端口（PC 无 192.168.1.102/24 时的无板自检兜底）：
#   为何要换端口：mock 是本进程内的另一个 socket，Windows 上「同一端口被两个 socket 绑」
#   的投递含糊（绑 0.0.0.0 会抢走绑具体 IP 的那个，实测踩到）——回环模式下每个方向
#   都给独立端口，投递唯一确定；真机路径（默认端口 1235/1234）不受任何影响。
LP_CMD = 31235                     # mock：命令口（= 应答源端口，对应契约板侧 1235）
LP_DATA = 31234                    # mock：数据口（= 回显源端口，对应契约板侧 1234）
LP_PC_CMD = 31239                  # mock：PC 命令口（对应契约 PC 侧 1235）—— 与 LP_CMD 必须不同
LP_PC_DATA = 31241                 # mock：PC 数据口（对应契约 PC 侧 1236）—— 与 LP_DATA 必须不同
SEQ_HDR = 4                        # 帧载荷头 = seq(4B 小端)
MIN_FRAME_LEN = 16                 # 最小帧长（seq 4B + round 1B + k16 2B + check 1B + 模式 ≥8B）

_EPOCH = time.time()               # 用于 --json-out 的时间戳（本脚本不用 datetime）


# --------------------------------------------------------------- 打印 / 日志

class Tee:
    """把 stdout 同时落日志文件（--log）：直接顶替 sys.stdout，print() 自动双写。

    为什么这么做：print/标准库都可能写 sys.stdout；替换流比给每一处输出传 tee 更稳。
    文件 UTF-8；打开失败只告警、不影响主流程。
    """

    def __init__(self, path, orig):        # orig = 原始 sys.stdout
        self.orig = orig
        self.fh = None
        if path:
            try:
                self.fh = open(path, "w", encoding="utf-8", newline="\n")
            except OSError as e:
                sys.stderr.write("warn: 日志文件打开失败 %s: %s\n" % (path, e))
                self.fh = None

    def write(self, text):
        self.orig.write(text)
        if self.fh:
            self.fh.write(text)
        return len(text)

    def flush(self):
        self.orig.flush()
        if self.fh:
            try:
                self.fh.flush()
            except OSError:
                pass

    def isatty(self):
        return False

    def close(self):
        if self.fh:
            try:
                self.fh.flush()
                self.fh.close()
            except OSError:
                pass


# --------------------------------------------------------------- 帧载荷编解码

def build_payload(seq, round_id, size):
    """构造第 seq 帧的完整载荷：seq(4B LE) + [round(1B) | k16(2B LE) | 校验(1B)] + 递增模式。

    递增模式: payload[i] = (i * 37 + (seq & 0xFFFF) * 131 + round_id * 7) & 0xFF
      性质: 只依赖 (i, seq, round_id) ⇒ 接收侧无需查表即可逐字节复算；
            帧长 %8 余数固定，避开官方栈打包/解包尾部处理的边界（W4 已单独覆盖 12 种长度）。
    校验字节: (sum(前 7 字节) * 31 + size) & 0xFF —— 抓头部单字节翻转。
    """
    if size < MIN_FRAME_LEN:
        raise ValueError("帧长须 >= %d" % MIN_FRAME_LEN)
    buf = bytearray(size)
    struct.pack_into("<I", buf, 0, seq & 0xFFFFFFFF)
    buf[4] = round_id & 0xFF
    struct.pack_into("<H", buf, 5, seq & 0xFFFF)
    buf[7] = (sum(buf[0:7]) * 31 + size) & 0xFF
    for i in range(8, size):
        buf[i] = (i * 37 + (seq & 0xFFFF) * 131 + round_id * 7) & 0xFF
    return bytes(buf)


def parse_payload(data):
    """解析回显载荷 → (seq, round_id, k16)；长度非法返回 None。"""
    if len(data) < MIN_FRAME_LEN:
        return None
    seq, = struct.unpack_from("<I", data, 0)
    k16, = struct.unpack_from("<H", data, 5)
    return seq, data[4], k16


def first_diff(a, b):
    """首个字节差异下标；完全相同返回 -1；前缀相同则返回 min(len)。"""
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return -1 if len(a) == len(b) else n


def inversion_count(order):
    """逆序对数（O(n log n) 树状数组，先做坐标压缩以支持任意取值）。

    J3 要求「读出顺序 ≠ 写入顺序」——逆序对数 > 0 即严格不相等。
    负向 A 的序列缺一个元素（长度 n-1、取值不连续），故必须压缩后计数。
    """
    n = len(order)
    if n < 2:
        return 0
    rank = {v: i for i, v in enumerate(sorted(order))}     # 坐标压缩 → 0..n-1
    tree = [0] * (n + 1)

    def add(i):
        i += 1
        while i <= n:
            tree[i] += 1
            i += i & (-i)

    def qry(i):
        i += 1
        s = 0
        while i > 0:
            s += tree[i]
            i -= i & (-i)
        return s

    inv = 0
    for idx, v in enumerate(order):
        inv += idx - qry(rank[v])
        add(rank[v])
    return inv


def d16(now, base):
    """16bit 计数器差值（mod 65536；契约 §2.2 的 value16 是 16bit）。"""
    return (now - base) & 0xFFFF


def short_set_desc(vals, limit=12):
    s = sorted(vals)
    head = ", ".join(str(v) for v in s[:limit])
    return "{%s%s}" % (head, ", ..." if len(s) > limit else "")


# --------------------------------------------------------------- 命令客户端

class CmdError(Exception):
    pass


class CmdClient:
    """契约 §2.1/§2.2 命令客户端：UDP 广播发命令，等 P10R 应答（超时可重发）。"""

    def __init__(self, src_ip, cmd_port=PC_CMD_PORT, dst_ip=BCAST_IP, dst_port=CMD_PORT,
                 timeout_ms=1500, retries=2, broadcast=True, verbose=True):
        self.src_ip = src_ip
        self.dst = (dst_ip, dst_port)
        self.timeout = timeout_ms / 1000.0
        self.retries = max(0, retries)
        self.verbose = verbose
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if broadcast:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)   # §2.1：广播发
        self.sock.bind((src_ip, cmd_port))
        self.sock.settimeout(self.timeout)
        self.n_sent = 0          # 含重发的发送次数
        self.n_cmd = 0           # 逻辑命令数（不含重发）
        self.n_retry = 0         # 重发次数
        self.stray = 0           # 落到命令口的非 P10R 杂包数

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    @staticmethod
    def pack(opcode, arg0=0, arg1=0):
        """§2.1 组包：magic(4) + opcode(1) + arg0(1) + arg1(2, LE) [+ 保留可空]。"""
        return struct.pack("<4sBBH", CMD_MAGIC, opcode & 0xFF, arg0 & 0xFF, arg1 & 0xFFFF)

    @staticmethod
    def parse_resp(data):
        """§2.2 解包（12 字节定长）；magic / 长度 / status 任一不合法即抛 CmdError。"""
        if len(data) < 12:
            raise CmdError("应答长度 %d < 12（§2.2 定长 12 字节）" % len(data))
        magic, opcode, status, v16, v16b, v16c = struct.unpack_from("<4sBBHHH", data, 0)
        if magic != RESP_MAGIC:
            raise CmdError("应答 magic = %r != %r" % (magic, RESP_MAGIC))
        if status != 0:
            raise CmdError("status = %d (%s)，opcode=0x%02X" % (status, STATUS_NAMES.get(status, "未知"), opcode))
        return {"magic": magic, "opcode": opcode, "status": status,
                "value16": v16, "value16b": v16b, "value16c": v16c}

    def send(self, opcode, arg0=0, arg1=0, expect_resp=True, label="", timeout_ms=None):
        """发一条命令。expect_resp=True 时等应答（最多重发 --retries 次），失败抛 CmdError。
        expect_resp=False 用于「明知没有应答」的场景（负向 B 的重复读槽）。"""
        pkt = self.pack(opcode, arg0, arg1)
        self.n_cmd += 1
        if not expect_resp:
            self.sock.sendto(pkt, self.dst)
            self.n_sent += 1
            return None
        timeout = (timeout_ms / 1000.0) if timeout_ms is not None else self.timeout
        attempts = self.retries + 1
        for att in range(attempts):
            self.sock.sendto(pkt, self.dst)
            self.n_sent += 1
            t0 = time.perf_counter()
            while True:
                left = timeout - (time.perf_counter() - t0)
                if left <= 0:
                    break
                self.sock.settimeout(left)
                try:
                    data, addr = self.sock.recvfrom(65535)
                except socket.timeout:
                    break
                except ConnectionResetError:
                    # Windows：上一包触发的 ICMP port-unreachable 会打断 recv —— 继续等
                    continue
                except OSError:
                    break
                # 认领条件：magic = P10R 且 opcode 回显一致（§2.2）
                if len(data) >= 5 and data[0:4] == RESP_MAGIC and data[4] == (opcode & 0xFF):
                    r = self.parse_resp(data)
                    r["addr"] = addr
                    r["rtt_ms"] = (time.perf_counter() - t0) * 1000.0
                    r["attempts"] = att + 1
                    if att:
                        self.n_retry += att
                    return r
                self.stray += 1
                if self.verbose:
                    print("    [命令口杂包] %s:%d len=%d（非本命令的 P10R，丢弃）"
                          % (addr[0], addr[1], len(data)))
            if att < attempts - 1 and self.verbose:
                print("    [重发] %s%s 第 %d 次超时(%.0fms)"
                      % (OP_NAMES.get(opcode, "0x%02X" % opcode), label, att + 1, timeout * 1000))
        raise CmdError("%s%s 无应答：%d 次尝试均超时 %.0fms（查板卡在线 / 广播路由 / 端口 %d）"
                       % (OP_NAMES.get(opcode, "0x%02X" % opcode), label, attempts, timeout * 1000, CMD_PORT))

    # ---- 契约 §2.1 四个命令的语义封装 ----
    def set_mode(self, mode):
        return self.send(OP_SET_MODE, arg0=mode)

    def get_watermark(self):
        r = self.send(OP_GET_WATERMARK)
        return r["value16"], r["value16b"], r["value16c"]        # u_wr_frame, u_rd_frame, u_buf_drop

    def get_slot_map(self):
        r = self.send(OP_GET_SLOT_MAP)
        return r["value16"], r["value16b"], r["value16c"]        # u_wr_frame, wr_slot, 规则号

    def read_slot(self, slot, arg1=0, expect_resp=True, timeout_ms=None):
        return self.send(OP_READ_SLOT, arg0=slot & 0xFF, arg1=arg1 & 0xFFFF,
                         expect_resp=expect_resp, timeout_ms=timeout_ms,
                         label="(slot=%d)" % (slot & 0xFF))


# --------------------------------------------------------------- 数据面（PC 侧）

class DataPlane:
    """数据帧收发：绑 PC:1236，发往板:1234；回显帧按 §2.3 回到本 socket。"""

    def __init__(self, src_ip, src_port=PC_DATA_PORT, dst_ip=BOARD_IP,
                 dst_port=DATA_PORT, timeout_ms=1500):
        self.src_port = src_port
        self.dst = (dst_ip, dst_port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((src_ip, src_port))
        self.sock.settimeout(timeout_ms / 1000.0)
        self.n_sent = 0
        self.src_counts = {}

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def send(self, payload):
        self.sock.sendto(payload, self.dst)
        self.n_sent += 1

    def recv(self, timeout_s):
        """收一帧；超时返回 None。"""
        self.sock.settimeout(timeout_s)
        try:
            return self.sock.recvfrom(65535)
        except socket.timeout:
            return None
        except ConnectionResetError:
            return None
        except OSError:
            return None

    def drain(self, timeout_s):
        """收取窗口内所有帧（用于「不应到达」的帧计数 / 排空）。"""
        got = []
        deadline = time.perf_counter() + timeout_s
        while True:
            left = deadline - time.perf_counter()
            if left <= 0:
                return got
            r = self.recv(left)
            if r is None:
                return got
            got.append(r)

    def drain_all(self, timeout_s, max_frames=8192, max_s=60.0):
        """连续排空：读到「静默 timeout_s」为止（上限 max_frames / max_s 防呆）。

        用途：数据面是**闭环**（写进槽的帧会被读出来回显给 PC），写阶段必然有一批
        回显在途。若只排空一次固定窗口，晚到的回显会漏进读阶段，污染
        「到达顺序 = 命令顺序」的匹配。故写阶段/读阶段收尾都用「静默窗口」排空。
        """
        got = []
        deadline = time.perf_counter() + max_s
        while len(got) < max_frames:
            left = min(timeout_s, deadline - time.perf_counter())
            if left <= 0:
                break
            r = self.recv(left)
            if r is None:
                break
            got.append(r)
        return got

    def read_frame(self, wait_s, expected_seq, expected_slot, verbose=False):
        """等「属于 expected_slot 的那一帧」：按命令顺序（J3 口径）只认第一帧。

        返回 (status, seq_or_None, data_or_None, addr_or_None)
          status ∈ {"ok", "timeout", "mismatch", "stale"}
          · ok       = 帧存在且 seq = expected_seq
          · mismatch = 该槽取回的是别的帧（槽↔帧错位 / 串帧）
          · stale    = 该槽本应为空（负向 B 的重复槽）却收到帧
          · timeout  = 窗口内无帧到达
        非期望 seq 的帧会被丢弃（stream 严格按命令顺序推进；如真机出现轻微乱序，
        可用 --resync，此时最多再等到窗口耗尽去凑 expected_seq）。
        """
        deadline = time.perf_counter() + wait_s
        while True:
            left = deadline - time.perf_counter()
            if left <= 0:
                return ("timeout", None, None, None)
            r = self.recv(left)
            if r is None:
                return ("timeout", None, None, None)
            data, addr = r
            key = (addr[0], addr[1])
            self.src_counts[key] = self.src_counts.get(key, 0) + 1
            p = parse_payload(data)
            if p is None:
                if verbose:
                    print("    [短帧/异帧] len=%d from %s:%d（跳过）" % (len(data), addr[0], addr[1]))
                continue
            seq = p[0]
            if expected_seq is None:
                return ("stale", seq, data, addr)
            if seq == expected_seq:
                return ("ok", seq, data, addr)
            if verbose:
                print("    [顺序异常] 期望 seq=%d（槽 %d），先到 seq=%d（槽 %d）"
                      % (expected_seq, expected_slot, seq, seq % NSLOTS_MAX))
            if not ARGS_RESYNC:
                return ("mismatch", seq, data, addr)
            # --resync：丢掉该帧，继续等 expected_seq 直到窗口耗尽
            continue


# --------------------------------------------------------------- 用例执行（契约 §4.1/§4.2）

ARGS_RESYNC = False        # 由 main() 按 --resync 设置（读取函数需要全局可见）
LISTEN = {}                # 由 main() 填：src_ip / pc_cmd_port / pc_data_port / board_cmd_port / board_data_port
PLAN = None                # 由 main() 生成：本用例的 (槽序列, 帧号序列)


def base_permutation(n, seed):
    """可复现的基准置换（同 seed 必得同一置换）。"""
    rnd = random.Random(seed)
    slots = list(range(n))
    rnd.shuffle(slots)
    return slots


def make_plan(n, seed, slot0, drop=None, dup=None, dup_first=False):
    """读取计划：(slots, frames)。

    输入 slot0 = 本轮第 0 帧写入的槽号 = u_wr_frame 基线 mod 256（调用方从 GET_WATERMARK 基线取）。
    写侧第 k 帧落槽 (slot0 + k) mod 256（契约 §1「写槽 = 帧计数 mod 256」，帧计数 = 基线 + k）。
    故：相对序号 r 的帧落在槽 (slot0 + r) mod 256 —— 置换在**相对序号**上做，再映射成绝对槽号，
    nslots=256 时即恒等（槽 ≡ seq mod 256）；nslots<256 时同样成立，且不依赖 wr0 是否对齐。

      漏发（drop）: 从置换里**去掉**一个相对序号 → 命令数 = n-1，u_rd_frame 增量应 = n-1
      重发（dup） : 某相对序号在置换里**出现两次** → 命令数 = n+1，第二次读同槽无数据帧，
                    u_rd_frame 增量应 = n
    drop/dup 由调用方在「基准置换」上选定（默认取置换首元素），**按相对序号**给出。
    """
    order = base_permutation(n, seed)          # 相对序号 0..n-1 的随机置换
    if drop is not None:
        if drop not in order:
            raise ValueError("--drop-slot 相对序号 %d 不在 0..%d 内" % (drop, n - 1))
        order.remove(drop)
    if dup is not None:
        if dup not in order:
            raise ValueError("--dup-slot 相对序号 %d 不在 0..%d 内" % (dup, n - 1))
        pos = 0 if dup_first else order.index(dup) + 1
        order.insert(pos, dup)                 # 同槽相邻重复 → 第二次读时该槽已退休
    slots = [(slot0 + r) % NSLOTS_MAX for r in order]      # 绝对槽号（发给 READ_SLOT）
    info = {"seed": seed, "n_cmds_expected": len(slots),
            "read_inversions": inversion_count(order), "rel_order": order}
    return slots, order, info


def send_burst(args, dm, client, n, round_id, size, tag, seq_base):
    """按保守节奏连发 n 帧数据帧（载荷 seq 唯一、可逐字节复算）。"""
    seqs_out = []
    pace = args.pace_us / 1e6
    for k in range(n):
        seq = seq_base + k
        dm.send(build_payload(seq, round_id, size))
        seqs_out.append(seq)
        if pace > 0:
            time.sleep(pace)
    return seqs_out


def classify_frames(dm, timeout_s, expected_seqs):
    """排空并分类数据帧 → (echo_frames, foreign_frames)。

    echo = 载荷可解析且 seq ∈ 本轮刚写入的 seq 集合（闭环回显，正常现象）
    foreign = 其余（非本轮数据 / 载荷不可解析）→ 必须报错
    """
    got = dm.drain_all(timeout_s)
    echo, foreign = [], []
    for data, addr in got:
        p = parse_payload(data)
        if p is not None and p[0] in expected_seqs:
            echo.append((p[0], addr))
        else:
            foreign.append((data, addr))
    return echo, foreign


def run_case(args, client, dm, name, round_id, size, drop=None, dup=None,
             dup_first=False, neg_mode=None):
    """跑一个用例（主轮 / 负向 A / 负向 B），返回统计 dict。

    顺序严格照契约 §4.1 主轮十步 + §4.2 负向构造：
      0 SET_MODE(RND) → GET_WATERMARK 基线 → 连发 n 帧 → 复核 u_wr_frame 增量
      → 生成置换 → 逐条 READ_SLOT 并收对应数据帧 → 判 J3/J3' → GET_WATERMARK 终值
    """
    st = {"name": name, "round_id": round_id, "ok": False, "errors": [], "warnings": [],
          "n_sent": 0, "n_echo": 0, "cmd_sent": 0, "cmd_resp": 0, "cmd_timeout_expected": 0,
          "timeouts": 0, "missing": 0, "missing_frames": [], "extra": 0,
          "byte_diff": 0, "seq_mismatch": 0,
          "expected_frames": [], "received_frames": [],
          "inv": 0, "wr_delta": None, "rd_delta": None, "drop_slot": drop, "dup_slot": dup,
          "seq_base": 0, "slot0": 0, "wr0": 0, "drop_frame": None,
          "write_echo": 0, "write_echo_foreign": 0, "late_extra": 0, "dup_empty": 0}
    print("-" * 74)
    print("[%s] 步骤 0: SET_MODE(RND) + GET_WATERMARK 取基线" % name)
    client.set_mode(MODE_RND)
    wr0, rd0, drop0 = client.get_watermark()
    print("    基线: u_wr_frame=%d  u_rd_frame=%d  u_buf_drop=%d" % (wr0, rd0, drop0))
    seq_base = args.seq_base          # 本用例的起点 seq（main 在用例之间会推进它，必须就地快照）
    st["seq_base"] = seq_base
    if args.check_slot_map:
        m_wr, m_slot, m_rule = client.get_slot_map()
        print("    GET_SLOT_MAP: u_wr_frame=%d  写槽指针=%d  规则号=%d（期望 1 = 写槽 = 帧计数 mod 256）"
              % (m_wr, m_slot, m_rule))
        if m_rule != 1:
            st["warnings"].append("GET_SLOT_MAP 规则号 = %d ≠ 1（槽↔帧映射推导的可信度依赖该规则）" % m_rule)

    print("[%s] 步骤 1: 连发 %d 帧数据（帧长 %dB, 间隔 %dus, 目的 %s:%d）"
          % (name, args.nslots, size, args.pace_us, dm.dst[0], dm.dst[1]))
    seqs_out = send_burst(args, dm, client, args.nslots, round_id, size, name, seq_base)
    st["n_sent"] = len(seqs_out)
    expect_seqs = set(seqs_out)
    # 数据面是闭环：写进槽的帧会被桥①按 SEQ 自动读出来回显给 PC（W4 的 udp_verify 就是这个
    # 现象）。所以写阶段收到回显是**正常的**，但必须：① 全部排空（否则漏进读阶段污染 J3 的
    # 顺序匹配）② 逐帧校验它确实是本轮刚写进去的那一帧（归属校验）。
    echo, foreign = classify_frames(dm, args.echo_timeout_ms / 1000.0, expect_seqs)
    st["write_echo"] = len(echo)
    st["write_echo_foreign"] = len(foreign)
    if foreign:
        st["errors"].append("写阶段收到 %d 个「非本轮」数据帧（帧来源/载荷异常）" % len(foreign))
    print("    写阶段回显: %d 帧（闭环自动读出，已排空；seq 全部属于本轮 ✓）%s"
          % (len(echo), "" if not foreign else "  ⚠ 异物 %d 帧" % len(foreign)))
    if not args.expect_write_echo and echo:
        st["errors"].append("--no-write-echo 下收到 %d 帧写阶段回显" % len(echo))

    wr1, rd1, drop1 = client.get_watermark()
    st["wr_delta"] = d16(wr1, wr0)
    print("    复核: u_wr_frame %d → %d（增量 %d，期望 %d）  u_buf_drop=%d"
          % (wr0, wr1, st["wr_delta"], args.nslots, drop1))
    if st["wr_delta"] != args.nslots:
        st["errors"].append("u_wr_frame 增量 %d ≠ 发帧数 %d（写侧丢帧/被 FULL 拒收）"
                            % (st["wr_delta"], args.nslots))

    # 槽号推导（契约 §1「写槽 = 帧计数 mod 256」）：
    #   本轮第 k 帧的帧计数 = wr0 + k（wr0 = 步骤 0 的 u_wr_frame 基线）⇒ 落槽 (wr0 + k) mod 256
    #   ⇒ 基线随桥内计数漂移，槽号必须按基线算，不能写死「第 k 帧落槽 k」（那只是 wr0 ≡ 0 的特例）
    slot0 = wr0 % NSLOTS_MAX
    # 负向构造：默认漏/重「基准置换的首元素」（相对序号，同 seed 下可复现）
    base = base_permutation(args.nslots, args.seed)
    if drop is None and neg_mode == "drop":
        drop = args.drop_slot if args.drop_slot is not None else base[0]
    if dup is None and neg_mode == "dup":
        dup = args.dup_slot if args.dup_slot is not None else base[0]
    print("[%s] 步骤 2: 生成 %d 槽随机置换（seed=%d）%s"
          % (name, args.nslots, args.seed,
             "· 故意漏 1 序号 %d（命令数 = N-1）" % drop if drop is not None else
             ("· 故意重复 1 序号 %d（命令数 = N+1）" % dup if dup is not None else "")))
    slots, order, info = make_plan(args.nslots, args.seed, slot0,
                                   drop=drop, dup=dup, dup_first=dup_first)
    st["inv"] = info["read_inversions"]
    st["read_order"] = order
    st["cmd_plan"] = len(slots)
    st["slot0"] = slot0
    st["wr0"] = wr0
    st["drop_frame"] = drop
    # 绝对槽号 = (slot0 + 相对序号) mod 256（drop 已不在 order 里，直接按公式算）
    st["drop_slot"] = (slot0 + drop) % NSLOTS_MAX if drop is not None else None
    st["dup_slot"] = (slot0 + dup) % NSLOTS_MAX if dup is not None else None
    print("    基线 wr0=%d ⇒ 本轮第 0 帧落槽 %d，第 k 帧落槽 (%d+k) mod %d"
          % (wr0, slot0, slot0, NSLOTS_MAX))
    print("    置换前 8 槽: %s%s" % (slots[:8], " ..." if len(slots) > 8 else ""))
    print("    读出顺序相对写入顺序逆序对数 = %d（J3 要求 > 0，即读出顺序 ≠ 写入顺序）" % st["inv"])
    if dup is not None:
        assert len(set(order)) == args.nslots, "重复构造不得改变集合"

    print("[%s] 步骤 3: 逐条 READ_SLOT + 等对应数据帧（每条命令超时 %.0fms）"
          % (name, args.timeout_ms))
    seen = {}                     # seq → 出现次数
    t0 = time.perf_counter()
    for i, slot in enumerate(slots):
        exp_k = order[i]                       # 相对序号 → 该槽应含的帧
        exp_seq = seq_base + exp_k
        dup_here = (dup is not None and i > 0 and slots[i - 1] == slot)
        if dup_here:
            # 契约 §4.2 负向 B：第二次读同槽 → 桥① 该槽已退休（无数据帧输出）→ 预期「无应答、无数据帧」
            client.read_slot(slot, arg1=i & 0xFFFF, expect_resp=False)
            print("    #%03d READ_SLOT(%d) [重复槽·预期空]: 不发等待，观测窗口 %.0fms"
                  % (i + 1, slot, args.timeout_ms))
            got = dm.drain(args.timeout_ms / 1000.0)
            if got:
                st["extra"] += len(got)
                for d, _a in got:
                    p = parse_payload(d)
                    if p is not None:
                        seen[p[0]] = seen.get(p[0], 0) + 1
                st["errors"].append("负向 B：重复读槽 %d 竟收到 %d 个数据帧（预期空——桥①已退休该槽）"
                                    % (slot, len(got)))
            else:
                st["dup_empty"] += 1          # 预期现象：第二次读同槽无数据帧
            continue
        r = client.read_slot(slot, arg1=i & 0xFFFF, expect_resp=True)
        if r is not None:
            st["cmd_resp"] += 1
            if r["value16"] != (slot & 0xFF):
                st["errors"].append("READ_SLOT(%d) 应答 value16 = %d（已 clamp 槽号应是 %d）"
                                    % (slot, r["value16"], slot & 0xFF))
        status, seq, data, addr = dm.read_frame(args.timeout_ms / 1000.0, exp_seq, slot)
        if status == "ok":
            seen[seq] = seen.get(seq, 0) + 1
            exp_payload = build_payload(exp_seq, round_id, size)
            if data != exp_payload:
                st["byte_diff"] += 1
                d = first_diff(data, exp_payload)
                st["errors"].append("帧 seq=%d（槽 %d）字节差异 @%d（收 %d 字节 / 期望 %d 字节）"
                                    % (exp_seq, slot, d, len(data), len(exp_payload)))
            if i < 6 or (i + 1) == len(slots):
                print("    #%03d READ_SLOT(%3d) → seq=%-4d 逐字节一致 ✓（rtt %.1fms, 来自 %s:%d）"
                      % (i + 1, slot, seq, r["rtt_ms"] if r else -1, addr[0], addr[1]))
        elif status == "timeout":
            st["timeouts"] += 1
            print("    #%03d READ_SLOT(%3d) → 超时无数据帧 ✗（期望 seq=%d）" % (i + 1, slot, exp_seq))
        elif status == "mismatch":
            st["seq_mismatch"] += 1
            seen[seq] = seen.get(seq, 0) + 1
            st["errors"].append("槽 %d 取回 seq=%d，期望 seq=%d（槽↔帧错位/串帧）"
                                % (slot, seq, exp_seq))
            print("    #%03d READ_SLOT(%3d) → seq=%-4d 与期望 %d 不符 ✗" % (i + 1, slot, seq, exp_seq))
        else:  # stale：该槽本应为空
            st["extra"] += 1
            seen[seq] = seen.get(seq, 0) + 1
            st["errors"].append("槽 %d 期望空帧，却收到 seq=%d（负向构造未生效/桥未退休该槽）"
                                % (slot, seq))
    dt = time.perf_counter() - t0
    # 读阶段收尾：把「读命令触发的迟到帧/多余帧」也全部计入（不能靠读得快蒙混过去）
    late_echo, late_foreign = classify_frames(dm, args.echo_timeout_ms / 1000.0, expect_seqs)
    st["late_extra"] = len(late_echo) + len(late_foreign)
    for _s, _a in late_echo:
        seen[_s] = seen.get(_s, 0) + 1
    if late_echo or late_foreign:
        print("    读阶段收尾排空: 又收到 %d 帧（其中非本轮 %d 帧）" % (st["late_extra"], len(late_foreign)))
    st["n_echo"] = sum(seen.values())
    st["received_frames"] = sorted(seen.keys())
    recv_set = set(seen.keys())

    wr2, rd2, drop2 = client.get_watermark()
    st["rd_delta"] = d16(rd2, rd1)
    st["wr_delta_after"] = d16(wr2, wr1)

    # 集合口径（契约 §4.2）：基准 = **本轮写进桥① 的全部帧**（不受读取计划构造影响）。
    #   缺帧 = 写了却没读回来的帧；多帧 = 读回来但本轮没写过的帧。
    #   负向 A 漏发一个槽 ⇒ 恰好缺 1 帧；负向 B 重复读同槽 ⇒ 集合仍相等（缺 0 / 多 0）。
    expect_frames = set(seq_base + k for k in range(args.nslots))
    missing_frames = sorted(expect_frames - recv_set)
    surplus_frames = sorted(recv_set - expect_frames)
    st["expected_frames"] = sorted(expect_frames)
    st["missing"] = len(missing_frames)
    st["missing_frames"] = missing_frames
    st["extra"] += len(surplus_frames)
    if surplus_frames:
        st["errors"].append("多出 %d 个不属于「本轮已写帧」的回显：%s"
                            % (len(surplus_frames), short_set_desc(surplus_frames)))

    print("[%s] 步骤 4: 收尾 GET_WATERMARK  →  u_rd_frame %d → %d（增量 %d）  u_wr_frame %d → %d"
          % (name, rd1, rd2, st["rd_delta"], wr1, wr2))
    if missing_frames:
        print("    缺帧明细: %s" % short_set_desc(missing_frames))
    print("    耗时 %.2fs  发帧 %d  写阶段回显 %d  读回帧 %d  命令数(计划) %d  命令应答 %d  重发 %d"
          "  缺帧 %d  超时 %d  多余 %d  字节差异 %d"
          % (dt, st["n_sent"], st["write_echo"], st["n_echo"], len(slots), st["cmd_resp"],
             client.n_retry, st["missing"], st["timeouts"], st["extra"], st["byte_diff"]))

    return st


def check_main(st, args):
    """主轮 J3 / J3' 判定（契约 §4.1 + §4.3）。"""
    errs = st["errors"]
    if st["rd_delta"] != args.nslots:
        errs.append("u_rd_frame 增量 %d ≠ %d（每槽恰好读一次）" % (st["rd_delta"], args.nslots))
    if st["missing"]:
        errs.append("缺 %d 帧（期望 0）：%s" % (st["missing"], short_set_desc(st["missing_frames"])))
    if st["timeouts"]:
        errs.append("READ_SLOT 超时 %d 次（期望 0）" % st["timeouts"])
    if st["extra"] + st["late_extra"]:
        errs.append("多 %d 帧（读阶段出现不属于命令计划的数据帧，期望 0）"
                    % (st["extra"] + st["late_extra"]))
    if st["byte_diff"]:
        errs.append("%d 帧字节差异（期望 0）" % st["byte_diff"])
    if st["inv"] <= 0:
        errs.append("读出顺序与写入顺序相同（逆序对数 = 0）→ J3 的「随机读」前提不成立")
    n_ok = st["n_echo"]
    st["ok"] = (not errs, errs)
    print("[%s] J3  : 到达顺序 = 命令顺序 %s（缺帧 %d / 超时 %d / 错位 %d）· 读出顺序 ≠ 写入顺序 %s（逆序对数 %d）"
          % (st["name"], "✓" if (st["missing"] == 0 and st["timeouts"] == 0
                                  and st["seq_mismatch"] == 0) else "✗",
             st["missing"], st["timeouts"], st["seq_mismatch"],
             "✓" if st["inv"] > 0 else "✗", st["inv"]))
    print("[%s] J3' : 收帧 %d / 期望 %d · 缺 %d · 多 %d · 字节差异 %d · u_rd_frame 增量 %d"
          "（另：写阶段闭环回显 %d 帧已单独排空计数）"
          % (st["name"], n_ok, args.nslots, st["missing"], st["extra"] + st["late_extra"],
             st["byte_diff"], st["rd_delta"], st["write_echo"]))
    print("[%s] 结论: %s" % (st["name"], "PASS ✓" if not errs else "FAIL ✗"))
    for e in errs:
        print("        · %s" % e)
    return not errs


def check_neg_a(st, args):
    """负向 A：必须报「恰好缺 1 帧」，且 u_rd_frame 增量 = nslots-1。"""
    errs = st["errors"]
    if st["timeouts"]:
        errs.append("出现 %d 次命令超时（漏发轮不应有超时的命令）" % st["timeouts"])
    if st["missing"] != 1:
        errs.append("缺帧数 = %d，期望恰好 1" % st["missing"])
    elif st["missing_frames"] != [st["seq_base"] + st["drop_frame"]]:
        errs.append("缺的帧是 %s，期望恰好是漏掉槽 %d（帧 %d）对应的 seq=%d"
                    % (short_set_desc(st["missing_frames"]), st["drop_slot"], st["drop_frame"],
                       st["seq_base"] + st["drop_frame"]))
    if st["rd_delta"] != args.nslots - 1:
        errs.append("u_rd_frame 增量 %d ≠ %d（漏 1 槽应少读 1 帧）" % (st["rd_delta"], args.nslots - 1))
    if st["extra"] + st["late_extra"]:
        errs.append("多收 %d 帧（期望 0）" % (st["extra"] + st["late_extra"]))
    if st["byte_diff"]:
        errs.append("收到帧中 %d 帧字节差异（期望 0）" % st["byte_diff"])
    if st["n_echo"] != args.nslots - 1:
        errs.append("实取帧数 %d ≠ N-1 = %d" % (st["n_echo"], args.nslots - 1))
    ok = not errs
    print("[负向 A] 漏发判定: 缺帧 %d（期望恰好 1，缺的是 seq=%s）%s · u_rd_frame 增量 %d（期望 %d）%s · 收帧 %d"
          % (st["missing"], st["missing_frames"], "✓" if st["missing"] == 1 else "✗",
             st["rd_delta"], args.nslots - 1,
             "✓" if st["rd_delta"] == args.nslots - 1 else "✗", st["n_echo"]))
    print("[负向 A] 结论: %s（构造 = 置换中删除「相对序号 %s」= 绝对槽 %s / 帧 %s；命令数 %d = N-1）"
          % ("PASS ✓（判据真的能报缺帧，非恒真）" if ok else "FAIL ✗",
             st["drop_frame"], st["drop_slot"],
             None if st["drop_frame"] is None else st["seq_base"] + st["drop_frame"],
             st["cmd_plan"]))
    for e in errs:
        print("        · %s" % e)
    return ok


def check_neg_b(st, args):
    """负向 B：命令数 = N+1、实取 = N、集合仍相等；第二次读同槽无数据帧。"""
    errs = st["errors"]
    n_dup = st["dup_slot"]
    cmds = st["cmd_plan"]
    real = args.nslots
    if cmds != real + 1:
        errs.append("命令数 %d ≠ N+1 = %d" % (cmds, real + 1))
    if st["dup_empty"] < 1:
        errs.append("重复读同槽未观测到「空」现象（dup_empty = 0）")
    if st["n_echo"] != real:
        errs.append("实取帧数 %d ≠ N = %d" % (st["n_echo"], real))
    if st["missing"]:
        errs.append("缺 %d 帧（重复读不应造成缺帧；多出的那条命令应「空」而非顶掉别人）：%s"
                    % (st["missing"], short_set_desc(st["missing_frames"])))
    if st["rd_delta"] != real:
        errs.append("u_rd_frame 增量 %d ≠ %d（重复读同槽不再增计数）" % (st["rd_delta"], real))
    if st["extra"] + st["late_extra"]:
        errs.append("多收 %d 帧（第二次读同槽应无数据帧）" % (st["extra"] + st["late_extra"]))
    if st["byte_diff"]:
        errs.append("收到帧中 %d 帧字节差异（期望 0）" % st["byte_diff"])
    ok = not errs
    print("[负向 B] 重复读判定: 命令数 %d = N+1 %s · 实取 %d = N %s · 集合仍相等(缺 %d / 多 %d / 字节差异 %d) %s"
          % (cmds, "✓" if cmds == real + 1 else "✗", st["n_echo"], "✓" if st["n_echo"] == real else "✗",
             st["missing"], st["extra"], st["byte_diff"],
             "✓" if (st["missing"] == 0 and st["extra"] == 0 and st["byte_diff"] == 0) else "✗"))
    print("[负向 B] 结论: %s（第二次读绝对槽 %s 观测到「空」%d 次——桥① 读完即退休该槽；预期现象，不是丢包）"
          % ("PASS ✓" if ok else "FAIL ✗", n_dup, st["dup_empty"]))
    print("[负向 B] 佐证提示: ill_rd_cnt 应 +1 —— 该计数只在 ui 域 ILA 可见（契约 §4.3），本脚本不读 ILA，"
          "请用 W4 探针 dbg_mem_ill 抓取核对；u_rd_frame 不因重复读而增加是本轮的结构性判据。")
    for e in errs:
        print("        · %s" % e)
    return ok


# --------------------------------------------------------------- mock 板卡（--mock 自检）

class MockBoard(threading.Thread):
    """本地假实现：模拟 cmd_channel 应答 + 桥① RND 语义（读完退休 / 空读无应答）。

    忠实复刻的关键语义（契约 §1/§4.2）:
      · 写侧：槽 = u_wr_frame mod 256；目标槽已 FULL（写后未被读走）→ 拒收（u_buf_drop++）
      · 读侧：READ_SLOT(s) 槽有帧 → 数据帧 + 应答(value16=槽号, value16b=触发序号)；槽已退休 → 无应答
      · SET_MODE/GET_WATERMARK/GET_SLOT_MAP 应答字段照 §2.2 回读表
    这样负向轮在 mock 下也会真的触发对应判定（漏槽 → 恰缺 1；重复槽 → 第二次读空）。
    """

    def __init__(self, bcast_ip=BCAST_IP, port=CMD_PORT, data_port=DATA_PORT,
                 pc_data_port=PC_DATA_PORT, cmd_bind_ip=None, data_bind_ip=None):
        super().__init__(daemon=True)
        self.bcast_ip = bcast_ip
        self.port = port
        self.data_port = data_port
        self.pc_data_port = pc_data_port
        cmd_bind_ip = cmd_bind_ip if cmd_bind_ip is not None else bcast_ip
        data_bind_ip = data_bind_ip if data_bind_ip is not None else bcast_ip
        self.lock = threading.Lock()
        self.stop_ev = threading.Event()
        self.mode = MODE_SEQ
        self.wr_frame = 0
        self.rd_frame = 0
        self.buf_drop = 0
        self.rd_trig = 0
        self.slots = {}            # slot → 载荷（bytes）
        self.cmd_rx = 0
        self.err = None
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        # 应答源地址须像真板（源 IP = 板 IP、源端口 = 1235）。
        # 真机同网段时绑 bcast_ip 即可（本机 192.168.1.255 被视作接口本地址，可绑）；
        # 回环兜底时绑 127.0.0.1（此时端口另择，见 LP_* 常量说明）。
        self.sock.bind((cmd_bind_ip, port))
        self.bind_desc = (cmd_bind_ip, port)
        # 短超时 + 每通道独立线程：单线程轮询两个 socket 时，对端 recv 的 200ms 超时
        # 会把数据通道整段饿死（实测慢 100 倍，写计数对不上），必须分开收。
        self.sock.settimeout(0.005)
        self.data = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.data.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        # 数据面：模拟桥① 收 PC 发往「板:1234」的帧，并从同一端口回显（§2.3）
        self.data.bind((data_bind_ip, data_port))
        self.data_desc = (data_bind_ip, data_port)
        self.data.settimeout(0.005)
        for _s in (self.sock, self.data):       # 256 帧 + 回显突发，缓冲给足
            try:
                _s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
                _s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
            except OSError:
                pass

    # ---- 线程体：命令口 / 数据口 各一条接收线程（互不阻塞） ----
    def run(self):
        t_cmd = threading.Thread(target=self._loop, args=(self.sock, self._on_cmd),
                                 name="mock-cmd", daemon=True)
        t_data = threading.Thread(target=self._loop, args=(self.data, self._on_data),
                                  name="mock-data", daemon=True)
        t_cmd.start()
        t_data.start()
        t_cmd.join()
        t_data.join()

    def _loop(self, sk, handler):
        while not self.stop_ev.is_set():
            try:
                data, addr = sk.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                if self.stop_ev.is_set():
                    return
                continue
            try:
                handler(data, addr)
            except Exception as e:                 # noqa: BLE001  自检期任何异常都要暴露
                self.err = e

    def stop(self):
        self.stop_ev.set()

    def close(self):
        self.stop()
        try:
            self.join(timeout=1.0)
        except RuntimeError:
            pass
        for sk in (self.sock, self.data):
            try:
                sk.close()
            except OSError:
                pass

    # ---- 数据面：模拟桥① 写槽 ----
    def _on_data(self, data, addr):
        if len(data) < SEQ_HDR:
            return
        with self.lock:
            slot = self.wr_frame % NSLOTS_MAX
            if slot in self.slots:                 # 目标槽 FULL → 拒收（契约 §1）
                self.buf_drop = (self.buf_drop + 1) & 0xFFFF
            else:
                self.slots[slot] = bytes(data)
                self.wr_frame = (self.wr_frame + 1) & 0xFFFF
        # 回显：源端口 = 板侧 1234 → 目的 = 发起方端口（PC 数据口）；mock 直接回给 src addr
        self.data.sendto(bytes(data), addr)

    # ---- 命令面：模拟 cmd_channel 解析 + 应答 ----
    def _on_cmd(self, data, addr):
        if len(data) < 8 or data[0:4] != CMD_MAGIC:
            return
        opcode, arg0 = data[4], data[5]
        arg1, = struct.unpack_from("<H", data, 6)
        with self.lock:
            self.cmd_rx += 1
            v16 = v16b = v16c = 0
            frame = None
            resp = True
            if opcode == OP_SET_MODE:
                self.mode = arg0 & 1
            elif opcode == OP_READ_SLOT:
                slot = arg0 & 0xFF
                self.mode = MODE_RND
                if slot in self.slots:             # 有帧 → 读出；无帧（已退休）→ 无应答（契约 §4.2）
                    frame = self.slots.pop(slot)
                    self.rd_frame = (self.rd_frame + 1) & 0xFFFF
                    self.rd_trig = (self.rd_trig + 1) & 0xFFFF
                    v16, v16b = slot, self.rd_trig
                else:
                    resp = False
            elif opcode == OP_GET_WATERMARK:
                v16, v16b, v16c = self.wr_frame, self.rd_frame, self.buf_drop
            elif opcode == OP_GET_SLOT_MAP:
                v16, v16b, v16c = self.wr_frame, self.wr_frame % NSLOTS_MAX, 1
            else:
                resp = False
        if frame is not None:
            self.data.sendto(frame, (addr[0], self.pc_data_port))
        if resp:
            # 契约 §2.2：应答目的 = 命令帧的源 MAC/IP/端口。mock 直接对 addr 回；
            # 若 Windows 投递把源地址抹成通配（默认路径实测），则退回 (PC IP, PC 命令口)。
            dst = addr if addr[1] else (LISTEN["src_ip"], LISTEN["pc_cmd_port"])
            pkt = struct.pack("<4sBBHHH", RESP_MAGIC, opcode, 0, v16, v16b, v16c)
            # 应答源端口 = 板侧命令口（契约 §2.2）；mock 的 sock 就绑在该端口上
            self.sock.sendto(pkt, dst)


# --------------------------------------------------------------- 本机 IP / 参数

def detect_local_ip(dst=BOARD_IP):
    """探测到板卡的路由源 IP（不实际发包）。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((dst, 9))
        return s.getsockname()[0]
    finally:
        s.close()


def find_bindable_ips(dst_ip, ports):
    """找出本机能同时 bind 命令口与数据口的 IPv4 地址（按优先级排序）。

    真机路径：优先「PC 网卡地址」（能绑则说明本机就是那台 PC）→ 再试板卡 IP / 其它候选。
    192.168.1.255 这类「接口本地址」在 Windows 上可绑（本机实测），但 mock 绝不能绑广播地址
    （会与 255.255.255.255 混淆），故候选里排除 .255 结尾者。
    返回: [(ip, cmd_port, data_port), ...]
    """
    seen = set()
    cands = []
    # 到板卡的路由源地址（顺序正确：先定网段）
    d = detect_local_ip(dst_ip)
    if d:
        cands.append(d)
        seen.add(d)
    # 同网段候选（形如 192.168.1.x）——mock 的广播回环也依赖这一网段
    prefix = dst_ip.rsplit(".", 1)[0] + "."
    for ip in [dst_ip] + list_ipv4():
        if not ip or ip in seen or ip.startswith("169.254.") or ip.endswith(".255"):
            continue
        if ip.startswith(prefix):
            cands.append(ip)
            seen.add(ip)
    # 兜底：其它地址（真机路径下可能仍可用；mock 到不了这里就会自动回环兜底）
    for ip in list_ipv4():
        if not ip or ip in seen or ip.startswith("169.254.") or ip.endswith(".255"):
            continue
        cands.append(ip)
        seen.add(ip)
    cmd_port, data_port = ports
    out = []
    for ip in cands:
        s1 = s2 = None
        try:
            s1 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s1.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s1.bind((ip, cmd_port))
            s2 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s2.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s2.bind((ip, data_port))
        except OSError:
            s1 = s2 = None
        finally:
            for s in (s1, s2):
                if s is not None:
                    try:
                        s.close()
                    except OSError:
                        pass
        if s1 is not None and s2 is not None:
            out.append((ip, cmd_port, data_port))
    return out


def list_ipv4():
    try:
        return sorted({a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)})
    except OSError:
        return []


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="prj10 W5 随机读判据 J3/J3' 测试脚本（契约 v1）",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("--nslots", type=int, default=256, help="本轮槽数 N（≤256，主轮建议 256）")
    p.add_argument("--seed", type=int, default=20261007, help="随机置换种子（同种子可复现同一置换）")
    p.add_argument("--pace-us", type=int, default=1000, help="数据帧发送间隔 us（保守防泵A忙丢）")
    p.add_argument("--timeout-ms", type=int, default=1500, help="单条命令/单帧等待超时 ms")
    p.add_argument("--retries", type=int, default=2, help="命令超时后的重发次数")
    p.add_argument("--size", type=int, default=64, help="数据帧载荷字节数")
    p.add_argument("--seq-base", type=int, default=1000, help="本轮起始 seq（跨轮自动 +256 递增）")
    p.add_argument("--mock", action="store_true", help="本地假板卡自检（无需真板）")
    p.add_argument("--mock-loopback", action="store_true",
                   help="（mock 已固定走回环 + 独立端口；此开关保留兼容，无实际作用）")
    p.add_argument("--neg-a", action="store_true", help="跑负向轮 A（置换漏 1 槽）")
    p.add_argument("--neg-b", action="store_true", help="跑负向轮 B（置换重复 1 槽）")
    p.add_argument("--no-neg", action="store_true", help="不跑负向轮（只跑主轮）")
    p.add_argument("--drop-slot", type=int, default=None, help="负向 A 漏掉的槽号（默认取置换首元素）")
    p.add_argument("--dup-slot", type=int, default=None, help="负向 B 重复的槽号（默认取置换首元素）")
    p.add_argument("--cleanup", action="store_true", default=True,
                   help="负向轮后补读残留槽（默认开：保证下一轮写槽不被 FULL 拒收）")
    p.add_argument("--no-cleanup", dest="cleanup", action="store_false")
    p.add_argument("--resync", action="store_true",
                   help="容忍数据帧轻微乱序（默认严格按命令顺序认帧 = J3 口径）")
    p.add_argument("--strict-src", action="store_true",
                   help="严格要求数据帧源 = 板 IP:1234（默认只记录不判负）")
    p.add_argument("--echo-timeout-ms", type=int, default=1200,
                   help="闭环回显排空的「静默窗口」ms（连续静默这么久才认为排空完毕）")
    p.add_argument("--expect-write-echo", action="store_true", default=True,
                   help="写阶段允许并校验闭环自动读出的回显（W4 实测行为，默认开）")
    p.add_argument("--no-write-echo", dest="expect_write_echo", action="store_false",
                   help="写阶段不允许任何回显（位流若关掉 SEQ 自动读再用）")
    p.add_argument("--check-slot-map", action="store_true", default=True,
                   help="主轮用 GET_SLOT_MAP 复核写槽指针/规则号")
    p.add_argument("--no-slot-map", dest="check_slot_map", action="store_false")
    p.add_argument("--src-ip", default=None, help="PC 侧 IP（默认自动探测到板卡的路由源 IP）")
    p.add_argument("--dst-ip", default=BOARD_IP, help="板卡单播 IP（数据面目的）")
    p.add_argument("--bcast-ip", default=BCAST_IP, help="命令面广播 IP（§2.1）")
    p.add_argument("--cmd-port", type=int, default=PC_CMD_PORT, help="PC 命令 socket 端口（= 板侧 1235）")
    p.add_argument("--board-cmd-port", type=int, default=CMD_PORT, help="板侧命令端口（固定 1235）")
    p.add_argument("--data-port", type=int, default=PC_DATA_PORT, help="PC 数据 socket 端口（= 板侧 1234）")
    p.add_argument("--board-data-port", type=int, default=DATA_PORT, help="板侧数据端口（固定 1234）")
    p.add_argument("--log", default=None, help="日志文件（UTF-8），例如 j3_mock_selftest.log")
    p.add_argument("--json-out", default=None, help="把 JSON 汇总另存到文件（便于入库）")
    p.add_argument("--quiet", action="store_true", help="少打印（逐条明细只打首尾）")
    a = p.parse_args(argv)

    if not (1 <= a.nslots <= NSLOTS_MAX):
        p.error("--nslots 须在 1..%d（写槽规则 = 帧计数 mod %d）" % (NSLOTS_MAX, NSLOTS_MAX))
    if a.size < MIN_FRAME_LEN:
        p.error("--size 须 ≥ %d" % MIN_FRAME_LEN)
    if a.timeout_ms <= 0 or a.pace_us < 0 or a.retries < 0:
        p.error("--timeout-ms 须 > 0；--pace-us/--retries 须 ≥ 0")
    if a.cmd_port == a.data_port:
        p.error("--cmd-port 与 --data-port 不能相同（见文件头「两个本地端口」推导）")
    return a


# --------------------------------------------------------------- main

def main(argv=None):
    global ARGS_RESYNC, args_verbose
    args = parse_args(argv)
    ARGS_RESYNC = args.resync
    args_verbose = not args.quiet
    orig_stdout = sys.stdout
    tee = Tee(args.log, orig_stdout)
    if tee.fh is not None:
        sys.stdout = tee            # 从此 print() 自动双写（控制台 + 日志文件）

    mock = None
    client = None
    dm = None
    if args.mock:
        args.neg_a = args.neg_b = True
    try:
        # ---- 本机地址与 bind 地址选择（规则见 find_bindable_ips 注释） ----
        bcast_ip = args.bcast_ip
        dst_ip, dst_port = args.dst_ip, args.board_data_port
        command_ip = None                     # 最终选定的本机 bind 地址（None = 无可用地址）
        cmd_port, data_port = args.cmd_port, args.data_port

        if not args.src_ip:                   # 显式 --src-ip 时按用户指定，不做探测
            candidates = find_bindable_ips(args.dst_ip, (args.cmd_port, args.data_port))
            if candidates:
                command_ip, cmd_port, data_port = candidates[0]

        # ---- mock 一律走回环 + 独立端口（原因见 LP_* 常量注释）----
        # 为什么不复用真机端口：mock 是本进程的另一个 socket，与本脚本的命令 socket
        # 会在同一 IP:端口 上撞车（Windows 上无法指定由谁收，实测客户端收不到应答）。
        # 回环 + 每方向独立端口后投递唯一确定；顺带好处：板子在线时跑 --mock 也**不会**
        # 打扰真板（命令不发往网络，只在本机回环里转）。
        if args.mock:
            if not args.mock_loopback and not args.quiet:
                print("[提示] mock 模式固定用回环 127.0.0.1 + 独立端口（PC 命令口 %d / 数据口 %d /"
                      " 假板命令口 %d / 数据口 %d），与本机 %s/24 网卡的真板互不打扰"
                      % (LP_PC_CMD, LP_PC_DATA, LP_CMD, LP_DATA, args.dst_ip.rsplit(".", 1)[0] + ".0"))
            args.mock_loopback = True
            command_ip = "127.0.0.1"
            cmd_port, data_port = LP_PC_CMD, LP_PC_DATA
            bcast_ip, dst_ip, dst_port = "127.0.0.1", "127.0.0.1", LP_DATA
            args.board_cmd_port, args.board_data_port = LP_CMD, LP_DATA
            if args.src_ip and not args.quiet:
                print("[提示] mock 模式忽略 --src-ip %s（假板只在本机回环上）" % args.src_ip)
            args.src_ip = None
        elif args.src_ip:
            command_ip = args.src_ip

        binds = []
        if command_ip is not None:
            binds.append((command_ip, cmd_port, data_port))
            for _ip, _cp, _dp in find_bindable_ips(args.dst_ip, (args.cmd_port, args.data_port)):
                if _ip not in [b[0] for b in binds]:
                    binds.append((_ip, _cp, _dp))
        if not binds:
            print("[!] 本机找不到可同时 bind 命令口 %d 与数据口 %d 的 IPv4 地址（候选 %s）"
                  % (args.cmd_port, args.data_port, list_ipv4()))
            if args.mock:
                print("    → 改用: --mock --mock-loopback")
            else:
                print("    → 真机运行需 PC 网卡 = %s/24（AGENTS.md §三）" % args.dst_ip)
            return 2

        listener = []
        for ip, cp, dp in binds:
            try:
                client = CmdClient(ip, cp, dst_ip=bcast_ip, dst_port=args.board_cmd_port,
                                   timeout_ms=args.timeout_ms, retries=args.retries,
                                   verbose=args_verbose)
                dm = DataPlane(ip, dp, dst_ip=dst_ip, dst_port=dst_port,
                               timeout_ms=args.timeout_ms)
                command_ip, cmd_port, data_port = ip, cp, dp
                listener.append("ok")
                break
            except OSError as e:
                print("[!] bind %s:%d / %s:%d 失败: %s" % (ip, cp, ip, dp, e))
        if not listener:
            print("    → 端口被占用或地址不可用。真机运行前请关掉占用 %d/%d 的程序"
                  "（udp_verify 也占 1234，AGENTS.md §七）" % (args.cmd_port, args.data_port))
            return 2

        LISTEN.update({"src_ip": command_ip, "pc_cmd_port": cmd_port, "pc_data_port": data_port,
                       "board_cmd_port": args.board_cmd_port, "board_data_port": args.board_data_port})

        print("=" * 74)
        print("prj10 W5 · 随机读判据 J3 / J3' 上位机测试（契约 v1 冻结版，2026-10-07）")
        print("=" * 74)
        print("命令面: P10C → %s:%d（本地 %s:%d，SO_BROADCAST）  应答 P10R 回本地命令口"
              % (bcast_ip, args.board_cmd_port, command_ip, cmd_port))
        print("数据面: 帧 → %s:%d（本地 %s:%d）  被读出的帧回显到本地数据口"
              % (dst_ip, dst_port, command_ip, data_port))
        print("参数  : N=%d seed=%d pace=%dus timeout=%dms retries=%d 帧长=%dB mock=%s%s"
              % (args.nslots, args.seed, args.pace_us, args.timeout_ms, args.retries, args.size,
                 "ON" if args.mock else "OFF", "（回环兜底）" if args.mock_loopback else ""))

        if args.mock:
            mock = MockBoard(bcast_ip=bcast_ip, port=args.board_cmd_port,
                             data_port=dst_port, pc_data_port=data_port,
                             cmd_bind_ip=command_ip, data_bind_ip=command_ip)
            mock.start()
            print("mock  : 假板卡已起（命令口 %s，数据口 %s，PC 命令口 %d / 数据口 %d）"
                  % (mock.bind_desc, mock.data_desc, cmd_port, data_port))

        cases = {}

        # ================= 主轮（契约 §4.1） =================
        st_main = run_case(args, client, dm, "主轮", 1, args.size)
        ok_main = check_main(st_main, args)
        cases["主轮"] = st_main

        # ================= 负向轮 A（契约 §4.2 漏发） =================
        if args.neg_a:
            args.seq_base += NSLOTS_MAX
            drop = args.drop_slot
            st_a = run_case(args, client, dm, "负向A", 2, args.size, drop=drop, neg_mode="drop")
            ok_a = check_neg_a(st_a, args)
            if args.cleanup:
                print("[负向A] 补读残留槽 %s → 退休该槽，保证下一轮写槽不被 FULL 拒收" % st_a["drop_slot"])
                _cleanup(args, client, dm, st_a)
            args.seq_base += NSLOTS_MAX
            cases["负向A"] = st_a

        # ================= 负向轮 B（契约 §4.2 重发） =================
        if args.neg_b:
            dup = args.dup_slot
            st_b = run_case(args, client, dm, "负向B", 3, args.size, dup=dup, neg_mode="dup")
            ok_b = check_neg_b(st_b, args)
            cases["负向B"] = st_b

        # ================= 汇总 =================
        print("=" * 74)
        print("汇总（契约 §4.3 计数对账口径）")
        for k, v in cases.items():
            print("  [%s] 起始槽 %d  发帧 %d  收帧 %d  命令 %d  缺 %d  超时 %d  多 %d  字节差异 %d  "
                  "u_wr Δ%d  u_rd Δ%d  逆序对 %d"
                  % (k, v.get("slot0", 0), v["n_sent"], v["n_echo"], v["cmd_plan"], v["missing"],
                     v["timeouts"], v["extra"], v["byte_diff"], v.get("wr_delta") or 0,
                     v.get("rd_delta") or 0, v["inv"]))
        print("  ILA 对账提示: ill_rd_cnt 主轮 0 / 负向A 0 / 负向B +1；wr_stall_cnt 主轮 0"
              "（本脚本不读 ILA，用 W4 探针 dbg_mem_ill/dbg_mem_wstall 抓取）")

        errs = []
        if not ok_main:
            errs.append("主轮 FAIL")
        if args.neg_a and not ok_a:
            errs.append("负向A FAIL")
        if args.neg_b and not ok_b:
            errs.append("负向B FAIL")
        if client and client.n_retry:
            print("  提示: 命令重发 %d 次（真机若频发重发，检查链路/广播路由）" % client.n_retry)
        if dm and len(dm.src_counts) > 1:
            print("  数据帧来源分布: %s" % dm.src_counts)
        if args.strict_src and dm:
            bad = [k for k in dm.src_counts if k != (dst_ip, dst_port)]
            if bad:
                errs.append("数据帧来源非 %s:%d: %s" % (dst_ip, dst_port, bad))

        def digest(vals):
            """帧号序列的紧凑指纹（避免把 256 个数字灌进 JSON）。"""
            return hashlib.sha256(
                ",".join(str(v) for v in vals).encode("ascii")).hexdigest()[:16]

        def slim(v):
            """用例统计瘦身：大数组 → 计数 + SHA256 前 16 位（集合是否相等一看便知）。"""
            d = {kk: vv for kk, vv in v.items()
                 if kk not in ("read_order", "expected_frames", "received_frames",
                               "missing_frames", "cmd_plan")}
            exp, rec = v.get("expected_frames") or [], v.get("received_frames") or []
            d["expected_n"] = len(exp)
            d["received_n"] = len(rec)
            d["expected_sha"] = digest(exp)
            d["received_sha"] = digest(rec)
            d["read_order_sha"] = digest(v.get("read_order") or [])
            d["missing_frames"] = (v.get("missing_frames") or [])[:16]
            d["set_equal"] = (digest(exp) == digest(rec))
            return d

        summary = {
            "script": "j3_random_read.py",
            "contract": "阶段三_prj10_W5命令通道接口契约_2026-10-07",
            "mode": "mock" if args.mock else "board",
            "mock_loopback": bool(args.mock_loopback),
            "ts": round(_EPOCH, 3),
            "nslots": args.nslots, "seed": args.seed, "pace_us": args.pace_us,
            "timeout_ms": args.timeout_ms, "frame_size": args.size,
            "cmd_dst": "%s:%d" % (bcast_ip, args.board_cmd_port),
            "data_dst": "%s:%d" % (dst_ip, dst_port),
            "pc_cmd_port": cmd_port, "pc_data_port": data_port,
            "cmd_sent": client.n_sent if client else 0,
            "cmd_retry": client.n_retry if client else 0,
            "cases": {k: slim(v) for k, v in cases.items()},
            "verdict": "PASS" if not errs else "FAIL",
            "errors": errs,
        }
        print("=" * 74)
        if not errs:
            print("J3_RANDOM_READ: PASS")
        else:
            print("J3_RANDOM_READ: FAIL (%s)（0 errors 口径）" % "；".join(errs))
        print("J3_SUMMARY: " + json.dumps(summary, ensure_ascii=False))
        if args.json_out:
            try:
                with open(args.json_out, "w", encoding="utf-8", newline="\n") as fh:
                    json.dump(summary, fh, ensure_ascii=False, indent=2)
                print("JSON 汇总已写: %s" % args.json_out)
            except OSError as e:
                print("warn: --json-out 写入失败 %s: %s" % (args.json_out, e))
        return 0 if not errs else 1
    except CmdError as e:
        print("=" * 74)
        if mock is not None and mock.err is not None:
            print("[!] mock 线程异常（自检失败根因）: %r" % (mock.err,))
        print("J3_RANDOM_READ: FAIL (命令通道错误: %s)（0 errors 口径）" % e)
        print("    排查: ① 真机——板卡在线？广播路由/防火墙放行 UDP %d？" % args.board_cmd_port)
        print("          ② mock——回环端口 %d/%d 是否被上一次未退出的进程占用（重跑即可）"
              % (LP_CMD, LP_DATA))
        return 3
    except KeyboardInterrupt:
        print("J3_RANDOM_READ: FAIL (用户中断)（0 errors 口径）")
        return 130
    finally:
        if mock:
            mock.close()
            if mock.err:
                print("warn: mock 线程异常: %r" % (mock.err,))
        if dm:
            dm.close()
        if client:
            client.close()
        sys.stdout = orig_stdout
        tee.close()


args_verbose = True


def _cleanup(args, client, dm, st):
    """负向 A 后补读残留槽（把该槽退休，避免下一轮写槽 FULL 拒收）。"""
    slot = st["drop_slot"]
    try:
        r = client.read_slot(slot, arg1=0xFFFF)
        status, seq, data, addr = dm.read_frame(args.timeout_ms / 1000.0, None, slot)
        if status == "ok":
            print("    补读槽 %d → seq=%s（应答 value16=%d）；该槽已退休"
                  % (slot, seq, r["value16"] if r else -1))
        elif status == "stale":
            print("    补读槽 %d → seq=%s" % (slot, seq))
        else:
            print("    补读槽 %d → 无数据帧（%s）；下一轮若报 FULL 拒收请手工复位位流" % (slot, status))
    except CmdError as e:
        print("    补读槽 %d 命令无应答: %s" % (slot, e))


if __name__ == "__main__":
    sys.exit(main())
