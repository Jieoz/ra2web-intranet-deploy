#!/usr/bin/env bash
# build-ra2-intranet.sh — 网页红警2（RA2Web/Chronodivide 客户端重构版）内网离线部署一键构建脚本
#
# 用途：在有外网的机器上执行一次，产出可整体拷入内网的纯静态站点 webroot/。
# 之后内网任意静态文件服务器托管即可，运行期零外网依赖。
# 多人联机走游戏内置 LAN 模式（WebRTC P2P，iceServers=[]，无 STUN/TURN）。
#
# 用法：  bash build-ra2-intranet.sh [输出目录，默认 ./ra2-intranet]
# 依赖：  git、node>=20（含 npm）、python3、curl、python3-pillow(可选,用于占位加载图)
set -euo pipefail

OUT="${1:-./ra2-intranet}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"   # 绝对化：脚本中途会 cd 进仓库，相对路径会算错
REPO="$OUT/redalert2"
WEBROOT="$OUT/webroot"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

echo "==> [1/7] 准备目录 $OUT"
mkdir -p "$OUT"

echo "==> [2/7] 克隆 huangkaoya/redalert2"
if [ ! -d "$REPO" ]; then
    git clone --depth 1 https://github.com/huangkaoya/redalert2.git "$REPO"
fi

echo "==> [3/7] 应用纯CDN模式补丁（rfs为空时不崩溃）"
cd "$REPO"
python3 - <<'PYEOF'
import pathlib, re, sys

p = pathlib.Path("src/data/vfs/VirtualFileSystem.ts")
s = p.read_text()
orig = s

# 幂等：已打过补丁直接返回（否则 openFile 正则会二次嵌套）
if "this.rfs ? " in s:
    print("    补丁已存在，跳过")
    sys.exit(0)

# 逐表达式替换，不依赖缩进/上下文，不重排代码块。
# 目的：纯 CDN 模式下 this.rfs 为 undefined 时不抛 TypeError。
subs = [
    # 1) 类字段与构造参数改为可选
    (r"private\s+rfs:\s*RealFileSystem\s*;",
     "private rfs: RealFileSystem | undefined;"),
    (r"constructor\s*\(\s*rfs:\s*RealFileSystem\s*,",
     "constructor(rfs: RealFileSystem | undefined,"),
    # 2) for await ... of this.rfs.getEntries()  ->  空迭代兜底
    (r"of\s+this\.rfs\.getEntries\(\)",
     "of (this.rfs ? this.rfs.getEntries() : [])"),
    # 3) await this.rfs.openFile(X)  ->  三元兜底
    (r"await\s+this\.rfs\.openFile\(([A-Za-z_$][\w$]*)\)",
     r"(this.rfs ? await this.rfs.openFile(\1) : undefined)"),
]
for pat, rep in subs:
    s = re.sub(pat, rep, s)

if s == orig:
    print("!! 未匹配到任何目标表达式：上游源码结构已变更", file=sys.stderr)
    sys.exit(1)

# 自检：每一处 this.rfs.xxx() 调用都必须带空值保护
raw = len(re.findall(r"this\.rfs\.\w+\(", s))
guarded = len(re.findall(r"this\.rfs \? (?:await )?this\.rfs\.\w+\(", s))
if raw != guarded:
    print(f"!! 自检失败：this.rfs 调用 {raw} 处，受保护 {guarded} 处", file=sys.stderr)
    sys.exit(1)

p.write_text(s)
print(f"    补丁应用成功（{guarded} 处 this.rfs 调用已加空值保护）")
PYEOF

echo "==> [4/7] 写入内网化配置"
cat > public/config.ini <<'CFGEOF'
[General]
discordUrl=
csfFile = general.csf

# Where game resources are located
gameresBaseUrl=/cdn/game-res/v2/
mapsBaseUrl=/cdn/maps/
modsBaseUrl=/cdn/mods/
gameResArchiveUrl=
patchNotesUrl=
ladderRulesUrl=
modSdkUrl=
breakingNewsUrl=/breaking-news.html
oldClientsBaseUrl=/old/
quickMatchEnabled=no
botsEnabled=yes
defaultLanguage=zh-CN
unrankedQueueEnabled=no

viewport.width=1024
viewport.height=768
CFGEOF
cat > public/servers.ini <<'SVCEOF'
[lan]
label="内网 LAN 对战"
available=no
gameVersion=0.65.1
wolUrl="wss://localhost/wol"
apiRegUrl="http://localhost/register"
wladderUrl="http://localhost/ladder"
wgameresUrl="http://localhost/wgameres"
SVCEOF

echo "==> [5/7] npm 安装依赖并构建（纯 node，无需 bun）"
npm ci --no-audit --no-fund
node ./node_modules/vite/bin/vite.js build

echo "==> [6/7] 拉取游戏资源（官方CDN, 187MB, 带UA与Referer）"
RES="$WEBROOT/cdn/game-res/v2"
mkdir -p "$RES"
curl -s --max-time 60 -A "$UA" -o "$RES/manifest.json" "https://wyhjres.ra2web.cn/manifest.json"
python3 - "$RES" "$UA" <<'PYEOF'
import json, subprocess, sys, zlib, os
res_dir, ua = sys.argv[1], sys.argv[2]
man = json.load(open(os.path.join(res_dir, "manifest.json")))
need = []
for fn, crc in man["checksums"].items():
    dst = os.path.join(res_dir, fn)
    if os.path.exists(dst) and zlib.crc32(open(dst, "rb").read()) & 0xFFFFFFFF == crc:
        continue
    need.append((fn, crc))
for fn, crc in need:
    subprocess.run(["curl", "-s", "--max-time", "300", "-A", ua,
                    "-H", "Referer: https://game.ra2web.com/",
                    "-o", os.path.join(res_dir, fn),
                    f"https://wyhjres.ra2web.cn/{fn}"], check=True)
# PNG 加载图官方已下架：有 pillow 就生成内网占位图并重写校验和
try:
    from PIL import Image, ImageDraw, ImageFont
    font = None
    for fp in ["/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
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
    make(f"{res_dir}/glsl.png", "红警 2 网页版", "内网离线部署版")
    for key, cn in {"ustates":"美国","france":"法国","germany":"德国","ukingdom":"英国",
                    "russia":"俄罗斯","cuba":"古巴","libya":"利比亚","iraq":"伊拉克",
                    "korea":"韩国","obs":"观察者"}.items():
        make(f"{res_dir}/ls800{key}.png", cn, "正在加载战场数据...")
except ImportError:
    pass
# 全量重写校验和，保证包内自洽
for fn in list(man["checksums"]):
    data = open(os.path.join(res_dir, fn), "rb").read()
    man["checksums"][fn] = zlib.crc32(data) & 0xFFFFFFFF
json.dump(man, open(os.path.join(res_dir, "manifest.json"), "w"), indent=2)
print("resources OK:", len(man["checksums"]), "files")
PYEOF

echo "==> [7/7] 同步构建产物到 webroot（保留 cdn/ 资源目录）"
find "$WEBROOT" -mindepth 1 -maxdepth 1 ! -name cdn -exec rm -rf {} +
cp -r "$REPO/dist/." "$WEBROOT/"

SIZE=$(du -sh "$WEBROOT" | cut -f1)
echo ""
echo "✅ 完成：$WEBROOT ($SIZE)"
echo ""
echo "内网部署：把 webroot/ 整体拷到内网服务器，任意静态服务器托管即可。例如："
echo "  cd webroot && python3 -m http.server 8080 --bind 0.0.0.0"
echo "玩家访问 http://<内网IP>:8080/ 关闭MOD导入弹窗即可进入主菜单。"
echo "多人对战：主菜单 → 局域网(LAN) → 创建房间生成邀请码（同一内网互通）。"
