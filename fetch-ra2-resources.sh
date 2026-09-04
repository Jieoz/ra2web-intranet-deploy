#!/usr/bin/env bash
# fetch-ra2-resources.sh — 拉取网页红警2运行所需的全部资源，配合预构建客户端使用
#
# 为什么单独一个脚本：客户端构建需要 node >= 20.19（vite 8 的硬性要求），
# 而资源拉取只需要 python3 + curl。客户端已预先构建好（client/ 目录），
# 所以运行本脚本的机器完全不需要 node。
#
# 用法：
#   bash fetch-ra2-resources.sh [客户端目录]     # 默认 ./client
#
# 可重复运行：已经就位且校验通过的文件会跳过，中断后重跑只补缺的部分。
# 依赖：python3、curl

set -euo pipefail

WEBROOT="${1:-client}"
[ -d "$WEBROOT" ] || { echo "!! 找不到客户端目录：$WEBROOT" >&2; exit 1; }
[ -f "$WEBROOT/index.html" ] || { echo "!! $WEBROOT 里没有 index.html，不像是客户端目录" >&2; exit 1; }
WEBROOT="$(cd "$WEBROOT" && pwd)"

command -v python3 >/dev/null || { echo "!! 需要 python3" >&2; exit 1; }
command -v curl    >/dev/null || { echo "!! 需要 curl" >&2; exit 1; }

echo "==> 拉取游戏资源到 $WEBROOT"

WEBROOT="$WEBROOT" python3 <<'PYEOF'
import os, re, subprocess, sys, struct, zlib, json

webroot  = os.environ["WEBROOT"]
res_dir  = os.path.join(webroot, "cdn", "game-res", "v2")
ls_dir   = os.path.join(res_dir, "ls")
maps_dir = os.path.join(webroot, "cdn", "maps")
for d in (res_dir, ls_dir, maps_dir):
    os.makedirs(d, exist_ok=True)

RES_BASE = "https://wyhjres.ra2web.cn/"
MAP_BASE = "https://gameres.chronodivide.com/map/"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
REFERER = "https://game.ra2web.com/"

def curl(url, dst, timeout=180):
    """下载到 dst。返回 True 表示 curl 认为成功（内容是否可用由调用方校验）。"""
    r = subprocess.run(
        ["curl", "-sS", "-f", "--max-time", str(timeout),
         "-A", UA, "-e", REFERER, "-o", dst, url],
        capture_output=True, text=True)
    return r.returncode == 0

def crc(path):
    with open(path, "rb") as f:
        return zlib.crc32(f.read()) & 0xFFFFFFFF

# ---------------------------------------------------------------- 引擎资源
# 官方清单原样落盘。客户端对 .mix 会用清单里的 CRC 做强校验（CdnResourceLoader
# 附加 ?h=<crc> 并比对），所以清单绝不能被改写——改写等于把校验关掉。
manifest_path = os.path.join(res_dir, "manifest.json")
if not curl(RES_BASE + "manifest.json", manifest_path):
    print("!! 拉取资源清单失败（manifest.json）", file=sys.stderr)
    sys.exit(1)

with open(manifest_path, encoding="utf-8") as f:
    checksums = json.load(f)["checksums"]

def remote_and_local(fn):
    """加载图在 CDN 的 ls/ 子目录下，客户端也按 ls/<name> 请求（LoadingScreenWrapper
    直接用 <img src=cdnBase+"ls/"+name>，不走 CRC 校验的下载器）。其余在根。"""
    if fn.startswith("ls800"):
        return RES_BASE + "ls/" + fn, os.path.join(ls_dir, fn)
    return RES_BASE + fn, os.path.join(res_dir, fn)

def content_ok(fn, path, want):
    """校验下载内容。反盗链页面和截断文件都是 HTTP 200 + curl 退出码 0，
    只有比对内容才能挡下来。"""
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return False
    if fn.endswith(".png"):
        # 上游 manifest 对 glsl.png / ls800russia.png 的 CRC 与自家 CDN 上的
        # 文件就是不一致的，而客户端对图片本来也不校验 CRC，所以只验 PNG 头。
        with open(path, "rb") as f:
            return f.read(8) == b"\x89PNG\r\n\x1a\n"
    return crc(path) == (want & 0xFFFFFFFF)

print("--> 引擎资源 %d 项" % len(checksums))
todo = []
for fn, want in checksums.items():
    _, dst = remote_and_local(fn)
    if not content_ok(fn, dst, want):
        todo.append(fn)

if todo:
    for i, fn in enumerate(sorted(todo), 1):
        url, dst = remote_and_local(fn)
        want = checksums[fn]
        for attempt in (1, 2, 3):
            ok = curl(url, dst) and content_ok(fn, dst, want)
            if ok:
                break
            if attempt < 3:
                print("    [%d/%d] %s 第 %d 次失败，重试" % (i, len(todo), fn, attempt))
        else:
            print("!! 资源不可用: %s（内容校验不通过，可能是反盗链页面或传输截断）" % fn,
                  file=sys.stderr)
            sys.exit(1)
        print("    [%d/%d] %s" % (i, len(todo), fn))
else:
    print("    全部 %d 项已就位，无需下载" % len(checksums))

total = 0
for fn in checksums:
    _, dst = remote_and_local(fn)
    total += os.path.getsize(dst)
mix_ok = sum(1 for fn, w in checksums.items()
             if not fn.endswith(".png") and content_ok(fn, remote_and_local(fn)[1], w))
print("    引擎资源就绪：%d 项 / %.1f MB（其中 %d 项 .mix/.mp4 与官方 CRC 逐字节一致）"
      % (len(checksums), total / 1048576, mix_ok))

# ------------------------------------------------------------------ 地图
# 地图是独立的第二套资源，不在 manifest.json 里。客户端进遭遇战/局域网时
# 按需去 mapsBaseUrl 取 .map，取不到就弹"下载失败，请检查网络连接"。
# 地图清单藏在 ini.mix 里的 missions.pkt。

def _crc_table():
    t = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (0xEDB88320 ^ (c >> 1)) if (c & 1) else (c >> 1)
        t.append(c)
    return t

_CRC_T = _crc_table()

def crc32_ww(data):
    """引擎用的 CRC32（等价 zlib.crc32，显式实现便于对照源码）。"""
    c = 0xFFFFFFFF
    for b in data:
        c = ((c >> 8) ^ _CRC_T[(c & 0xFF) ^ b]) & 0xFFFFFFFF
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF

def mix_hash(name):
    """复刻引擎的 MixEntry.hashFilename：大写 + 补齐到 4 字节倍数的诡异规则。
    末尾不足 4 字节时先追加一个"已满块数"字符，再用该位置的字符重复填满。"""
    s = name.upper()
    n = len(s)
    r = n >> 2
    if n & 3:
        s += chr(n - (r << 2))
        pad_n = 3 - (n & 3)
        idx = r << 2
        ch = s[idx] if idx < len(s) else s[0]
        s += ch * pad_n
    return crc32_ww(bytes(ord(c) & 0xFF for c in s))

def mix_entries(path):
    """最小 MIX 解析：返回 (data, {hash: (offset, size)})。只支持未加密归档。

    头部布局易错：可选 4 字节 flags，随后条目数是 uint16、数据区大小是 uint32,
    合计 6 字节——不是两个 uint32。按 8 字节算会把索引起点偏移 2 字节，
    表现为解析到一半 unpack 越界。
    """
    with open(path, "rb") as f:
        data = f.read()
    flags = struct.unpack_from("<I", data, 0)[0]
    if (flags & ~0x30000) == 0:
        if flags & 0x20000:
            raise NotImplementedError("encrypted MIX not supported: " + path)
        pos = 4
    else:
        pos = 0
    count = struct.unpack_from("<H", data, pos)[0]
    pos += 6                       # count(2) + datasize(4)
    body = pos + count * 12
    out = {}
    for _ in range(count):
        h, off, size = struct.unpack_from("<III", data, pos)
        pos += 12
        out[h & 0xFFFFFFFF] = (body + off, size)
    return data, out

def mix_get(path, name):
    data, entries = mix_entries(path)
    hit = entries.get(mix_hash(name))
    if not hit:
        return None
    off, size = hit
    return data[off:off + size]

pkt = mix_get(os.path.join(res_dir, "ini.mix"), "missions.pkt")
if not pkt:
    print("!! 无法从 ini.mix 取出 missions.pkt，跳过地图（进遭遇战会报下载失败）",
          file=sys.stderr)
    sys.exit(1)

# missions.pkt 是 INI：[MultiMaps] 之外每个小节是一张地图
maps, cur = [], None
for line in pkt.decode("latin-1").splitlines():
    s = line.strip()
    if not s or s.startswith(";"):
        continue
    if s.startswith("[") and s.endswith("]"):
        cur = s[1:-1].lower()
        if cur != "multimaps":
            maps.append(cur + ".map")

print("--> 地图 %d 张（清单来自 ini.mix/missions.pkt）" % len(maps))
have = miss = 0
missing = []
for i, fn in enumerate(maps, 1):
    dst = os.path.join(maps_dir, fn)
    # 地图是 INI 文本。别用"首字节必须是 ["：tn01t2.map 开头是裸 key=value，
    # 小节头在后面几行，卡首字节会把好文件误判成坏的。
    if os.path.exists(dst) and os.path.getsize(dst) > 4096:
        have += 1
        continue
    ok = False
    for attempt in (1, 2):
        if curl(MAP_BASE + fn, dst, timeout=60) and os.path.getsize(dst) > 4096:
            head = open(dst, "rb").read(2048).lstrip()
            if b"[" in head and b"<html" not in head[:200].lower():
                ok = True
                break
    if ok:
        have += 1
    else:
        miss += 1
        missing.append(fn)
        if os.path.exists(dst):
            os.remove(dst)

size = sum(os.path.getsize(os.path.join(maps_dir, f))
           for f in os.listdir(maps_dir)) / 1048576
print("    地图就绪：%d 张 / %.1f MB" % (have, size))
if missing:
    print("    另有 %d 张官方 CDN 未提供（战役合作图，多人对战不受影响）" % miss)

# 客户端启动时会拉这个页面填公告位，缺了会在控制台报 404
news = os.path.join(webroot, "breaking-news.html")
if not os.path.exists(news):
    with open(news, "w", encoding="utf-8") as f:
        f.write('<!doctype html><meta charset="utf-8"><title>news</title>\n')
PYEOF

SIZE=$(du -sh "$WEBROOT" | cut -f1)
echo ""
echo "✅ 完成：$WEBROOT ($SIZE) —— 这个目录整体拷进内网即可"
echo ""
echo "内网托管："
echo "  cd $WEBROOT && python3 -m http.server 8080 --bind 0.0.0.0"
echo "玩家访问 http://<内网IP>:8080/ 关闭 MOD 导入弹窗即进主菜单。"
echo ""
echo "多人对战（跨机器需要这一步）："
echo "  在这台机器上另起一个 STUN：python3 ministun.py 0.0.0.0 3478"
echo "  客户端会自动按站点地址找到它，config.ini 不用改。"
echo "  不跑 STUN 时浏览器只上报 mDNS(*.local) 候选，同机可连、跨机器基本连不上。"
echo "  然后：主菜单 → 局域网(LAN) → 创建房间，把邀请码给对方。"
