# -*- coding: utf-8 -*-
'''rate_probe.py -- 速率瓶颈定位（命令通道口径, 不依赖 ILA）2026-10-09

原理: 同时量三个数 —— 
  ① PC 发出 N 帧
  ② 板内 u_wr_frame 增量 = **到达内存桥的帧数**(过了泵A 闸门之后的)
  ③ PC 收到 M 帧 = 走完整条回路回来的帧数
判读:
  N - ② ≈ 丢在 **入口**(泵A 握手闸门: 栈->泵A)
  ② - ③ ≈ 丢在 **出口**(回程: 泵B 闸门 / PC 收包缓冲)
  ② ≈ ③ ≈ N ⇒ 该速率无丢帧

用法: python scripts/rate_probe.py --n 1000 --pace-us 60 [--pc-ip 192.168.1.102]
'''
import socket, struct, sys, time
try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

CMD_PORT, DATA_PORT, PC_DATA_PORT = 1235, 1234, 1236
BOARD_IP, BCAST_IP = '192.168.1.10', '192.168.1.255'
CMD_MAGIC, RSP_MAGIC = b'P10C', b'P10R'
OP_SET_MODE, OP_GET_WM = 1, 3


class Cmd(object):
    def __init__(self, pc_ip=None):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        if pc_ip:
            self.s.bind((pc_ip, CMD_PORT))
        else:
            self.s.bind(('0.0.0.0', CMD_PORT))
        self.s.settimeout(1.2)

    def _send(self, op, a0=0, a1=0):
        self.s.sendto(struct.pack('<4sBBH', CMD_MAGIC, op & 0xFF, a0 & 0xFF, a1 & 0xFFFF),
                      (BCAST_IP, CMD_PORT))

    def get(self, op, a0=0, a1=0, tries=3):
        for _ in range(tries):
            self._send(op, a0, a1)
            t0 = time.time()
            while time.time() - t0 < 1.2:
                try:
                    d, _a = self.s.recvfrom(2048)
                except socket.timeout:
                    break
                if len(d) >= 12 and d[:4] == RSP_MAGIC and d[4] == (op & 0xFF):
                    _m, _o, st, v1, v2, v3 = struct.unpack_from('<4sBBHHH', d, 0)
                    return st, v1, v2, v3
        return None

    def close(self):
        self.s.close()


def main():
    n, pace = 1000, 200.0
    pc_ip = '192.168.1.102'
    flen = 1466
    a = sys.argv[1:]
    for i, x in enumerate(a):
        if x == '--n' and i + 1 < len(a): n = int(a[i + 1])
        if x == '--pace-us' and i + 1 < len(a): pace = float(a[i + 1])
        if x == '--pc-ip' and i + 1 < len(a): pc_ip = a[i + 1]
        if x == '--len' and i + 1 < len(a): flen = int(a[i + 1])

    cmd = Cmd(pc_ip)
    # 先回 SEQ（板子能主动发帧 -> ARP 可解析），再预热
    if cmd.get(OP_SET_MODE, 0) is None:
        print('SET_MODE(SEQ) 无应答 —— 命令通道不通'); return 1
    time.sleep(0.3)

    ds = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ds.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ds.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    ds.bind((pc_ip, PC_DATA_PORT))
    ds.settimeout(0.2)
    try:
        ds.sendto(b'\x00' * 32, (BOARD_IP, DATA_PORT))
    except OSError:
        pass
    time.sleep(0.6)

    r0 = cmd.get(OP_GET_WM)
    if r0 is None:
        print('GET_WATERMARK 无应答'); return 1
    wr0, rd0, dr0 = r0[1], r0[2], r0[3]

    print('=' * 78)
    print(' 速率瓶颈定位   N=%d  pace=%.0fus (目标 %.0f 帧/秒 / %.1f Mbps)'
          % (n, pace, 1e6 / pace, flen * 8 / pace))
    print('=' * 78)
    print('  基线: u_wr_frame=%d  u_rd_frame=%d  u_buf_drop=%d' % (wr0, rd0, dr0))

    payload = b'R' * flen
    t0 = time.perf_counter()
    for k in range(n):
        ds.sendto(payload, (BOARD_IP, DATA_PORT))
        if pace > 0:
            tgt = t0 + (k + 1) * pace / 1e6
            while time.perf_counter() < tgt:
                pass
    t_send = time.perf_counter() - t0

    # 收包（回程帧）
    got = 0
    t1 = time.perf_counter()
    while time.perf_counter() - t1 < 3.0:
        try:
            d, _a = ds.recvfrom(4096)
            if len(d) >= flen:
                got += 1
        except socket.timeout:
            if got and time.perf_counter() - t1 > 0.8:
                break
    t_recv = time.perf_counter() - t1

    time.sleep(0.3)
    r1 = cmd.get(OP_GET_WM)
    if r1 is None:
        print('★ 收尾 GET_WATERMARK 无应答'); return 1
    wr1, rd1, dr1 = r1[1], r1[2], r1[3]
    acc = (wr1 - wr0) & 0xFFFF          # 到达内存桥(过泵A 闸门)
    buf_drop = (dr1 - dr0) & 0xFFFF     # 桥内 user 侧拒收
    in_loss = n - acc                   # 入口丢(泵A 闸门)
    out_loss = acc - buf_drop - got     # 出口丢(回程/PC)

    print('  ① PC 发出            : %d 帧 / %.3fs = %.0f 帧/秒' % (n, t_send, n / t_send));
    print('  ② 板内到达内存桥     : u_wr_frame 增量 %d' % acc);
    print('  ③ PC 收回           : %d 帧 (%.2fs)' % (got, t_recv));
    print('  桥内 user 侧拒收     : %d' % buf_drop);
    print('  ' + '-' * 74);
    print('  **入口丢 (泵A 闸门)  : %d 帧 (%.2f%%)**' % (in_loss, 100.0 * in_loss / n));
    print('  **出口丢 (回程/PC)   : %d 帧 (%.2f%%)**' % (out_loss, 100.0 * out_loss / n));
    print('  ' + '-' * 74);
    if abs(in_loss) <= n * 0.005 and abs(out_loss) <= n * 0.005:
        print('  RATE_PROBE: 该速率无显著丢帧');
    elif in_loss > out_loss:
        print('  RATE_PROBE: 瓶颈在**入口**(泵A 握手闸门: 以太网栈->泵A), 出口正常');
    else:
        print('  RATE_PROBE: 瓶颈在**出口**(回程泵B 闸门 或 PC 收包缓冲)');
    print('=' * 78);
    ds.close(); cmd.close();
    return 0


if __name__ == '__main__':
    sys.exit(main())