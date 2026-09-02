#!/usr/bin/env bash
# fetch-ra2-resources.sh — 只拉游戏资源，配合预构建客户端使用
#
# 为什么单独一个脚本：客户端构建需要 node >= 20.19（vite 8 的硬性要求），
# 而资源拉取只需要 python3 + curl。客户端已预先构建好（client/ 目录），
# 所以运行本脚本的机器完全不需要 node。
#
# 用法：
#   1) 解开 ra2web-client-dist.zip（或 .tar.gz），得到 client/ 目录
#   2) bash fetch-ra2-resources.sh client
#   3) 把 client/ 整体拷进内网，静态服务器托管
#
# 走代理：直接 export http_proxy / https_proxy 即可，curl 自动继承。
#
# 依赖：python3、curl。可选 python3-pillow（画中文占位加载图，缺了就用纯色底图）
set -euo pipefail

WEBROOT="${1:-client}"
[ -f "$WEBROOT/index.html" ] || { echo "!! $WEBROOT 里没有 index.html，路径不对？" >&2; exit 1; }

RES="$WEBROOT/cdn/game-res/v2"
# 清空 MOD 远端清单：上游 mods.ini 里的 Download/Website 全是外网地址
printf '[General]\n' > "$WEBROOT/mods.ini"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

echo "==> 拉取游戏资源到 $RES （约 187MB，断点续跑：已下载且校验通过的会跳过）"
mkdir -p "$RES"
curl -fsS --retry 3 --retry-delay 2 --max-time 60 -A "$UA" \
     -o "$RES/manifest.official.json" "https://wyhjres.ra2web.cn/manifest.json"

python3 - "$RES" "$UA" <<'PYEOF'
import json, os, subprocess, sys, zlib

res_dir, ua = sys.argv[1], sys.argv[2]

# 官方清单单独留一份：本地 manifest.json 里占位图的校验和会被改写，
# 不能拿改写后的值当校验基准（否则损坏文件也能"校验通过"）。
official = json.load(open(os.path.join(res_dir, "manifest.official.json")))
checksums = official["checksums"]

def crc(path):
    h = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                return h & 0xFFFFFFFF
            h = zlib.crc32(b, h)

# 上一轮跑出来的本地清单：占位图的 CRC 与官方不同，靠它认出"这张图是我自己生成的"，
# 否则每次重跑都会对着已下架的 URL 再试一遍。
prev_path = os.path.join(res_dir, "manifest.json")
prev = {}
if os.path.exists(prev_path):
    try:
        prev = json.load(open(prev_path)).get("checksums", {})
    except Exception:
        prev = {}

placeholders = []   # 官方已下架 / 拉不到，用本地生成的图替代

def ok(fn):
    """本地文件是否已就位：与官方一致，或是上一轮生成的占位图"""
    p = os.path.join(res_dir, fn)
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return False
    c = crc(p)
    if c == checksums[fn]:
        return True
    if fn.lower().endswith(".png") and prev.get(fn) == c:
        placeholders.append(fn)   # 沿用上一轮的占位图
        return True
    return False

need = [fn for fn in checksums if not ok(fn)]

if not need:
    print("    全部 %d 项资源已就位，无需下载" % len(checksums))

for i, fn in enumerate(need, 1):
    print(f"    [{i}/{len(need)}] {fn}", flush=True)
    dst = os.path.join(res_dir, fn)
    r = subprocess.run(["curl", "-fsS", "--retry", "3", "--retry-delay", "2",
                        "--max-time", "900", "-A", ua,
                        "-H", "Referer: https://game.ra2web.com/",
                        "-o", dst, f"https://wyhjres.ra2web.cn/{fn}"])
    bad = None
    if r.returncode != 0:
        bad = f"下载失败 (curl exit {r.returncode})"
    elif not os.path.exists(dst) or os.path.getsize(dst) == 0:
        bad = "文件为空"
    elif crc(dst) != checksums[fn]:
        # 关键：下载完必须比对官方 CRC。反盗链会返回 HTML 伪装页，
        # 代理/网络中断会返回截断文件，两者都是"下载成功"但内容是坏的。
        bad = "内容校验不通过（可能是反盗链页面或传输截断）"

    if not bad:
        continue
    if fn.lower().endswith(".png"):
        # 官方已下架 10 张阵营加载图 + glsl.png，只是加载画面装饰，可本地替代
        print(f"        {bad} → 用内网占位图替代")
        placeholders.append(fn)
        if os.path.exists(dst):
            os.remove(dst)
    else:
        # .mix 是引擎必需的游戏数据，绝不能拿坏文件糊过去
        print(f"!! 资源不可用: {fn} — {bad}", file=sys.stderr)
        print("   若在受限网络下，先 export https_proxy=... 再重跑本脚本。", file=sys.stderr)
        sys.exit(1)

# ---- 生成占位加载图 ----
def solid_png(path, w=800, h=600, rgb=(16, 18, 24)):
    import struct
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    row = b"\x00" + bytes(rgb) * w
    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(row * h))
        + chunk(b"IEND", b""))

labels = {"ustates": "美国", "france": "法国", "germany": "德国", "ukingdom": "英国",
          "russia": "俄罗斯", "cuba": "古巴", "libya": "利比亚", "iraq": "伊拉克",
          "korea": "韩国", "obs": "观察者"}

if placeholders:
    try:
        from PIL import Image, ImageDraw, ImageFont
        font = None
        for fp in ["/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
                   "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
                   "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]:
            try:
                font = ImageFont.truetype(fp, 42); break
            except Exception:
                pass
        def make(path, l1, l2):
            img = Image.new("RGB", (800, 600), (16, 18, 24))
            d = ImageDraw.Draw(img)
            d.rectangle([8, 8, 791, 591], outline=(70, 130, 60), width=3)
            if font:
                d.text((400, 270), l1, fill=(220, 220, 210), font=font, anchor="mm")
                d.text((400, 330), l2, fill=(150, 150, 140), font=font, anchor="mm")
            img.save(path, "PNG")
        for fn in placeholders:
            dst = os.path.join(res_dir, fn)
            if fn == "glsl.png":
                make(dst, "红警 2 网页版", "内网离线部署版")
            else:
                make(dst, labels.get(fn[5:-4], fn[5:-4]), "正在加载战场数据...")
    except ImportError:
        print("    (未装 python3-pillow：加载图用纯色底图占位)")
        for fn in placeholders:
            solid_png(os.path.join(res_dir, fn))

# ---- 最终验收：逐项分类核对 ----
local = dict(checksums)
errs = []
for fn in checksums:
    p = os.path.join(res_dir, fn)
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        errs.append(f"{fn}: 缺失")
        continue
    c = crc(p)
    if c == checksums[fn]:
        continue
    if fn in placeholders:
        local[fn] = c          # 占位图：允许与官方不同，写入本地清单保持包内自洽
    else:
        errs.append(f"{fn}: CRC 不符（本地 {c} != 官方 {checksums[fn]}）")

if errs:
    print("!! 资源校验失败：", file=sys.stderr)
    for e in errs:
        print("   -", e, file=sys.stderr)
    sys.exit(1)

official["checksums"] = local
json.dump(official, open(os.path.join(res_dir, "manifest.json"), "w"), indent=2)
os.remove(os.path.join(res_dir, "manifest.official.json"))

total = sum(os.path.getsize(os.path.join(res_dir, f)) for f in local)
real = len(local) - len(placeholders)
print("    资源就绪：%d 项 / %.1f MB —— %d 项与官方 CRC 逐字节一致，%d 项为本地占位图"
      % (len(local), total / 1048576, real, len(placeholders)))
PYEOF

SIZE=$(du -sh "$WEBROOT" | cut -f1)
echo ""
echo "✅ 完成：$WEBROOT ($SIZE) —— 这个目录整体拷进内网即可"
echo ""
echo "内网托管："
echo "  cd $WEBROOT && python3 -m http.server 8080 --bind 0.0.0.0"
echo "玩家访问 http://<内网IP>:8080/ 关闭MOD导入弹窗即进主菜单。"
echo "多人对战：主菜单 → 局域网(LAN) → 创建房间生成邀请码（同一内网互通）。"
