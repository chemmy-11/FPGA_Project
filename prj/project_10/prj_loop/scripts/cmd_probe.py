# -*- coding: utf-8 -*-
"""cmd_probe.py — W5 命令通道裸探测（上板定位用）

只做一件事：发一条命令，把命令口收到的每个包**原样打印**（长度+十六进制+首4字节），
并区分三类：
  · 自有广播回环副本 : len == 8 且 payload 以 P10C 开头（PC 自己收到自己的广播）
  · 板子应答         : payload 以 P10R 开头（12B）
  · 其它             : 原样打印
用法: python scripts\\cmd_probe.py [op_hex] [arg0] [arg1] [--timeout 2.0]
"""
import socket, struct, sys, time

CMD_PORT = 1235
BCAST = "192.168.1.255"
CMD_MAGIC = b"P10C"
RSP_MAGIC = b"P10R"


def pack(op, a0=0, a1=0):
    return struct.pack("<4sBBH", CMD_MAGIC, op & 0xFF, a0 & 0xFF, a1 & 0xFFFF)


def main():
    argv = sys.argv[1:]
    timeout = 2.0
    if "--timeout" in argv:
        k = argv.index("--timeout")
        timeout = float(argv[k + 1])
        del argv[k:k + 2]
    args = [a for a in argv if not a.startswith("--")]
    op = int(args[0], 16) if len(args) > 0 else 0x01
    a0 = int(args[1], 0) if len(args) > 1 else 1
    a1 = int(args[2], 0) if len(args) > 2 else 0

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(("0.0.0.0", CMD_PORT))
    s.settimeout(timeout)

    pkt = pack(op, a0, a1)
    print("[发送] op=0x%02X a0=%d a1=%d  len=%d  payload=%s  -> %s:%d"
          % (op, a0, a1, len(pkt), pkt.hex(), BCAST, CMD_PORT))
    while True:
        s.sendto(pkt, (BCAST, CMD_PORT))
        break

    t0 = time.time()
    n_echo = n_resp = n_other = 0
    while time.time() - t0 < timeout:
        try:
            data, addr = s.recvfrom(2048)
        except socket.timeout:
            break
        dt = (time.time() - t0) * 1000.0
        head = data[:4]
        if head == RSP_MAGIC:
            n_resp += 1
            tag = "★板子应答 P10R"
            if len(data) >= 12:
                _, rop, st, v1, v2, v3 = struct.unpack_from("<4sBBHHH", data, 0)
                tag += "  op=0x%02X status=0x%02X v16=%d/%d/%d" % (rop, st, v1, v2, v3)
        elif head == CMD_MAGIC:
            n_echo += 1
            tag = "(自有广播回环副本)"
        else:
            n_other += 1
            tag = "(其它)"
        print("  [+%7.3f ms] %-16s len=%-3d %s" % (dt, addr[0], len(data), tag))
        if head not in (CMD_MAGIC, RSP_MAGIC):
            print("      hex=%s" % data[:32].hex())

    print("---")
    print("汇总: 板子应答=%d  自有回环=%d  其它=%d" % (n_resp, n_echo, n_other))
    if n_resp == 0:
        print("PROBE: NO_RESPONSE  (命令通道无应答 -> 看 ILA dbg_cmd_rx/cmd_err/respbsy)")
    else:
        print("PROBE: RESPONSE_OK")


if __name__ == "__main__":
    main()