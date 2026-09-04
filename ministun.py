#!/usr/bin/env python3
"""极小 STUN 服务器：只实现 ICE 采集 srflx 候选所需的 Binding Request/Response。

用途：内网部署网页红警时，浏览器默认用 mDNS 假名（*.local）隐藏真实内网 IP，
导致 WebRTC 只有 host candidate、跨机器建连失败。给客户端配一个内网 STUN
服务器后，浏览器会额外采集 srflx 候选（内容就是它的真实内网 IP:端口），
跨机器直连即可成立，且全程不出内网。

只处理 RFC 5389 的 Binding 方法，返回 XOR-MAPPED-ADDRESS。不做认证、
不做 TURN 中继 —— 同一内网内不需要中继。

安全须知：STUN Binding 按协议设计就是无认证的（任何人发请求都会得到回应），
所以这个端口只应暴露在可信内网。别把 3478/udp 映射到公网：源 IP 可伪造，
公网上的开放 STUN 会被当作 UDP 反射源（响应约为请求的 2 倍大小）。
默认监听 0.0.0.0 是为了内网多网卡场景方便，能指定内网网卡地址就指定。
"""
import socket
import struct
import sys

MAGIC = 0x2112A442
BIND_REQUEST = 0x0001
BIND_RESPONSE = 0x0101
ATTR_XOR_MAPPED_ADDRESS = 0x0020
ATTR_MAPPED_ADDRESS = 0x0001
FAMILY_IPV4 = 0x01


def xor_mapped_address(ip: str, port: int) -> bytes:
    """XOR-MAPPED-ADDRESS：端口异或 magic 高 16 位，IPv4 异或整个 magic。

    （只有 IPv6 才需要让 transaction id 参与异或，这里只做 IPv4，故不收 txid。）
    """
    xport = port ^ (MAGIC >> 16)
    raw = socket.inet_aton(ip)
    xip = bytes(b ^ m for b, m in zip(raw, struct.pack("!I", MAGIC)))
    value = struct.pack("!BBH", 0, FAMILY_IPV4, xport) + xip
    return struct.pack("!HH", ATTR_XOR_MAPPED_ADDRESS, len(value)) + value


def mapped_address(ip: str, port: int) -> bytes:
    """MAPPED-ADDRESS：RFC 3489 的老式属性，个别老客户端只认这个。"""
    value = struct.pack("!BBH", 0, FAMILY_IPV4, port) + socket.inet_aton(ip)
    return struct.pack("!HH", ATTR_MAPPED_ADDRESS, len(value)) + value


def handle(data: bytes, addr) -> bytes | None:
    if len(data) < 20:
        return None
    msg_type, msg_len, magic = struct.unpack("!HHI", data[:8])
    if magic != MAGIC or msg_type != BIND_REQUEST:
        return None
    if len(data) < 20 + msg_len:      # 声明长度超过实到字节 = 截断包，丢弃
        return None
    txid = data[8:20]
    ip, port = addr[0], addr[1]
    attrs = xor_mapped_address(ip, port) + mapped_address(ip, port)
    return struct.pack("!HHI", BIND_RESPONSE, len(attrs), MAGIC) + txid + attrs


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "0.0.0.0"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 3478
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, port))
    print(f"STUN listening on {host}:{port} (udp)", flush=True)
    while True:
        try:
            data, addr = s.recvfrom(2048)
        except KeyboardInterrupt:
            return 0
        except OSError as e:
            # 单个畸形数据报不该弄死服务：ICMP port-unreachable 之类会让
            # recvfrom/sendto 抛 OSError，记一行继续收就行。
            print(f"  socket error: {e}", flush=True)
            continue
        try:
            resp = handle(data, addr)
        except (struct.error, OSError) as e:
            print(f"  drop malformed from {addr[0]}:{addr[1]}: {e}", flush=True)
            continue
        if resp:
            try:
                s.sendto(resp, addr)
            except OSError as e:
                print(f"  send failed to {addr[0]}:{addr[1]}: {e}", flush=True)
                continue
            print(f"  binding {addr[0]}:{addr[1]}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
