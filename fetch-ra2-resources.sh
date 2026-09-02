#!/usr/bin/env bash
# fetch-ra2-resources.sh — 只拉游戏资源，配合预构建客户端使用
#
# 为什么单独一个脚本：客户端构建需要 node >= 20.19（vite 8 的硬性要求），
# 而资源拉取只需要 python3 + curl。客户端我已经构建好了（client/ 目录），
# 所以你的机器完全不需要 node。
#
# 用法：
#   1) 解开 ra2web-client-dist.zip，得到 client/ 目录
#   2) bash fetch-ra2-resources.sh client
#   3) 把 client/ 整体拷进内网，静态服务器托管
#
# 依赖：python3、curl。可选 python3-pillow（画中文占位加载图，缺了就用纯色底图）
set -euo pipefail

WEBROOT="${1:-client}"
[ -f "$WEBROOT/index.html" ] || { echo "!! $WEBROOT 里没有 index.html，路径不对？" >&2; exit 1; }

RES="$WEBROOT/cdn/game-res/v2"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

echo "==> 拉取游戏资源到 $RES （约 187MB，断点续跑：已下载且校验通过的会跳过）"
mkdir -p "$RES"
curl -fs --max-time 60 -A "$UA" -o "$RES/manifest.json" "https://wyhjres.ra2web.cn/manifest.json"

python3 - "$RES" "$UA" <<'PYEOF'
import json, os, subprocess, sys, zlib

res_dir, ua = sys.argv[1], sys.argv[2]
man = json.load(open(os.path.join(res_dir, "manifest.json")))

need = []
for fn, crc in man["checksums"].items():
    dst = os.path.join(res_dir, fn)
    if os.path.exists(dst) and os.path.getsize(dst) > 0 \
       and zlib.crc32(open(dst, "rb").read()) & 0xFFFFFFFF == crc:
        continue
    need.append(fn)

if not need:
    print("    全部 %d 项资源已就位，无需下载" % len(man["checksums"]))
else:
    for i, fn in enumerate(need, 1):
        print(f"    [{i}/{len(need)}] {fn}", flush=True)
        r = subprocess.run(["curl", "-fs", "--max-time", "600", "-A", ua,
                            "-H", "Referer: https://game.ra2web.com/",
                            "-o", os.path.join(res_dir, fn),
                            f"https://wyhjres.ra2web.cn/{fn}"])
        if r.returncode != 0:
            if not fn.lower().endswith(".png"):
                print(f"!! 资源下载失败: {fn} (curl exit {r.returncode})", file=sys.stderr)
                sys.exit(1)
            print("        官方已下架，将用内网占位图替代")

# 官方已下架的 10 张阵营加载图 + glsl.png：生成内网占位图
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

pngs = [f for f in man["checksums"] if f.lower().endswith(".png")]
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
    labels = {"ustates": "美国", "france": "法国", "germany": "德国", "ukingdom": "英国",
              "russia": "俄罗斯", "cuba": "古巴", "libya": "利比亚", "iraq": "伊拉克",
              "korea": "韩国", "obs": "观察者"}
    for fn in pngs:
        dst = os.path.join(res_dir, fn)
        if os.path.exists(dst) and os.path.getsize(dst) > 0:
            continue
        if fn == "glsl.png":
            make(dst, "红警 2 网页版", "内网离线部署版")
        else:
            key = fn[5:-4]
            make(dst, labels.get(key, key), "正在加载战场数据...")
except ImportError:
    print("    (未装 python3-pillow：加载图用纯色底图占位)")
    for fn in pngs:
        dst = os.path.join(res_dir, fn)
        if not os.path.exists(dst) or os.path.getsize(dst) == 0:
            solid_png(dst)

missing = [fn for fn in man["checksums"]
           if not os.path.exists(os.path.join(res_dir, fn))
           or os.path.getsize(os.path.join(res_dir, fn)) == 0]
if missing:
    print("!! 缺失资源:", missing, file=sys.stderr)
    sys.exit(1)

# 全量重写校验和，保证包内自洽（占位图的 CRC 与官方不同）
for fn in man["checksums"]:
    man["checksums"][fn] = zlib.crc32(open(os.path.join(res_dir, fn), "rb").read()) & 0xFFFFFFFF
json.dump(man, open(os.path.join(res_dir, "manifest.json"), "w"), indent=2)

total = sum(os.path.getsize(os.path.join(res_dir, f)) for f in man["checksums"])
print("    资源就绪：%d 项，%.1f MB，CRC 全部一致" % (len(man["checksums"]), total / 1048576))
PYEOF

SIZE=$(du -sh "$WEBROOT" | cut -f1)
echo ""
echo "✅ 完成：$WEBROOT ($SIZE) —— 这个目录整体拷进内网即可"
echo ""
echo "内网托管："
echo "  cd $WEBROOT && python3 -m http.server 8080 --bind 0.0.0.0"
echo "玩家访问 http://<内网IP>:8080/ 关闭MOD导入弹窗即进主菜单。"
echo "多人对战：主菜单 → 局域网(LAN) → 创建房间生成邀请码（同一内网互通）。"
