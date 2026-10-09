# -*- coding: utf-8 -*-
import socket, struct, sys, time
sys.stdout.reconfigure(encoding='utf-8')
CMD, DAT, PCD = 1235, 1234, 1236
BIP, BCAST = '192.168.1.10', '192.168.1.255'
P10C, P10R = b'P10C', b'P10R'
IP = '192.168.1.102'
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.bind((IP, CMD)); s.settimeout(1.2)
def cmd(op, a0=0, a1=0):
    for _ in range(3):
        s.sendto(struct.pack('<4sBBH', P10C, op, a0 & 0xFF, a1 & 0xFFFF), (BCAST, CMD))
        t0 = time.time()
        while time.time() - t0 < 1.2:
            try: d, _a = s.recvfrom(2048)
            except socket.timeout: break
            if len(d) >= 12 and d[:4] == P10R and d[4] == op:
                _m, _o, st, v1, v2, v3 = struct.unpack_from('<4sBBHHH', d, 0)
                return st, v1, v2, v3
    return None
d = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
d.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
d.bind((IP, PCD)); d.settimeout(0.2)
print('SET_MODE(RND) ->', cmd(1, 1))
time.sleep(0.3)
r0 = cmd(3); print('基线 u_wr_frame =', r0[1])
N, PACE = 256, 20.0
payload = b'W' * 1466
t0 = time.perf_counter()
for k in range(N):
    d.sendto(payload, (BIP, DAT))
    tgt = t0 + (k + 1) * PACE / 1e6
    while time.perf_counter() < tgt: pass
dt = time.perf_counter() - t0
time.sleep(0.3)
r1 = cmd(3)
acc = (r1[1] - r0[1]) & 0xFFFF
print('RND 写路径 (桥不自动读): 发出 %d 帧 / %.4fs = %.0f 帧/秒' % (N, dt, N / dt))
print('  板内接受 = %d 帧  丢弃 = %d' % (acc, N - acc))
print('  ⇒ 纯写路径速率 = %.0f 帧/秒' % (acc / dt))
cmd(1, 0)
print('已恢复 SEQ')