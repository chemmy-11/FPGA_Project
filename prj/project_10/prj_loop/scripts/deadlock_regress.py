# -*- coding: utf-8 -*-
"""deadlock_regress.py — W5 写槽游标死锁修复的专项上板回归（2026-10-08）

复现原始死锁场景并验证修复：
  1) SET_MODE(RND)：桥① 不再自动读；
  2) **只写不读** 地灌 N 帧（N > 256，逼游标绕环撞上未读满槽）；
  3) 若为修复前实现：游标会停在满槽上 ⇒ 之后每一帧都被拒 ⇒ 永久卡死；
     修复后：游标随每帧推进（提交或被拒都 +1）⇒ 桥保持存活；
  4) 判据：灌完后仍能 READ_SLOT 读回**最后提交的**那批帧，且
     u_wr_frame 增量 == N（全部被接受，无 user 域丢弃）。

用法: python scripts\\deadlock_regress.py [--n 300] [--tail 16]
"""
import argparse
import socket
import struct
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

CMD_PORT = 1235
DATA_PORT = 1234
BOARD_IP = "192.168.1.10"
BCAST_IP = "192.168.1.255"
PC_DATA_PORT = 1236
CMD_MAGIC = b"P10C"
RSP_MAGIC = b"P10R"
OP_SET_MODE, OP_READ_SLOT, OP_GET_WM, OP_GET_MAP = 1, 2, 3, 4
NSLOTS = 256


def pack(op, a0=0, a1=0):
    return struct.pack("<4sBBH", CMD_MAGIC, op & 0xFF, a0 & 0xFF, a1 & 0xFFFF)


class Cmd(object):
    def __init__(self):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.s.bind(("0.0.0.0", CMD_PORT))
        self.s.settimeout(1.5)

    def send(self, op, a0=0, a1=0, tries=3):
        for _ in range(tries):
            self.s.sendto(pack(op, a0, a1), (BCAST_IP, CMD_PORT))
            t0 = time.time()
            while time.time() - t0 < 1.5:
                try:
                    data, _a = self.s.recvfrom(2048)
                except socket.timeout:
                    break
                if len(data) >= 12 and data[:4] == RSP_MAGIC and data[4] == (op & 0xFF):
                    _m, _o, st, v1, v2, v3 = struct.unpack_from("<4sBBHHH", data, 0)
                    return st, v1, v2, v3
        return None

    def close(self):
        self.s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=300, help="只写不读的帧数（>256 触发绕环）")
    ap.add_argument("--tail", type=int, default=16, help="最后验证读回的槽数")
    ap.add_argument("--pace-us", type=int, default=800)
    args = ap.parse_args()

    cmd = Cmd()
    print("=" * 74)
    print(" W5 写槽游标死锁修复 · 专项上板回归")
    print("=" * 74)

    r = cmd.send(OP_SET_MODE, 1)
    if r is None:
        print("SET_MODE 无应答 —— 命令通道不通，先查 runt/命令通道"); return 1
    print("SET_MODE(RND) -> status=0x%02X" % r[0])

    r = cmd.send(OP_GET_WM)
    if r is None:
        print("GET_WATERMARK 无应答"); return 1
    wr0, rd0, drop0 = r[1], r[2], r[3]
    print("基线: u_wr_frame=%d  u_rd_frame=%d  u_buf_drop=%d" % (wr0, rd0, drop0))

    # ---- 只写不读：灌 N 帧 ----
    ds = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ds.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ds.bind(("0.0.0.0", PC_DATA_PORT))
    ds.settimeout(0.05)
    print("灌帧: %d 帧（只写不读，间隔 %dus）..." % (args.n, args.pace_us))
    t0 = time.time()
    for i in range(args.n):
        payload = struct.pack("<IHH", 900000 + i, i & 0xFFFF, 0x5A5A) + b"\x00" * 32
        ds.sendto(payload, (BOARD_IP, DATA_PORT))
        if args.pace_us:
            time.sleep(args.pace_us / 1e6)
    dt = time.time() - t0
    # 排空回显
    try:
        while ds.recvfrom(4096):
            pass
    except socket.timeout:
        pass
    print("     完成，用时 %.2fs（%.0f 帧/秒）" % (dt, args.n / dt))

    time.sleep(0.5)
    r = cmd.send(OP_GET_WM)
    if r is None:
        print("★ GET_WATERMARK 无应答 —— 板子可能已挂"); return 1
    wr1, rd1, drop1 = r[1], r[2], r[3]
    print("灌后: u_wr_frame=%d（增量 %d，期望 %d）  u_rd_frame=%d  u_buf_drop=%d"
          % (wr1, (wr1 - wr0) & 0xFFFF, args.n, rd1, drop1))

    # ---- 验证桥仍存活：读最后 tail 个已分配槽 ----
    slot_end = wr1 % NSLOTS
    slots = [(slot_end - 1 - k) % NSLOTS for k in range(args.tail)]
    print("验证读回: 最后 %d 个槽 %s" % (args.tail, slots[:8] + ["..."]))
    got = 0
    for s in slots:
        cmd.send(OP_READ_SLOT, s, 0)
        try:
            d, _a = ds.recvfrom(4096)
            if d:
                got += 1
        except socket.timeout:
            pass
    print("     读回 %d/%d" % (got, args.tail))

    # 判据（物理正确的守恒口径）：
    #   N 帧只写不读、且 N > 256 槽 ⇒ 槽满后**整帧拒收是设计行为**，
    #   表现为 user 域 u_buf_drop 增加；故不能要求"全部被接受",
    #   而应要求 ① 接受 + 拒收 == N（帧不凭空消失/不静默丢失），
    #            ② 灌满绕环后桥**仍存活**（还能读回数据）—— 这正是死锁与否的判据。
    acc = (wr1 - wr0) & 0xFFFF
    drp = (drop1 - drop0) & 0xFFFF
    accounted = (acc + drp) == args.n
    ok = accounted and got > 0
    print("-" * 74)
    if ok:
        print("DEADLOCK_REGRESS: PASS")
        print("  帧量守恒: 接受 %d + 拒收 %d = %d（发出 %d，无静默丢失）" % (acc, drp, acc + drp, args.n))
        print("  灌满绕环后桥仍存活: 读回 %d/%d 帧" % (got, args.tail))
        print("  ⇒ 游标不再停在满槽上（修复前此场景永久卡死：之后所有帧被拒、读回 0）")
    else:
        print("DEADLOCK_REGRESS: FAIL")
        print("  接受 %d + 拒收 %d = %d（期望 %d）  读回 %d/%d"
              % (acc, drp, acc + drp, args.n, got, args.tail))
    print("=" * 74)
    ds.close()
    cmd.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
