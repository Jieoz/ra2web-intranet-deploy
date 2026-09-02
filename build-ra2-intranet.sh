#!/usr/bin/env bash
# build-ra2-intranet.sh — 网页红警2（RA2Web/Chronodivide 客户端重构版）内网离线部署一键构建脚本
#
# 用途：在有外网的机器上执行一次，产出可整体拷入内网的纯静态站点 webroot/。
# 之后内网任意静态文件服务器托管即可，运行期零外网依赖。
# 多人联机走游戏内置 LAN 模式（WebRTC P2P，iceServers=[]，无 STUN/TURN）。
#
# 用法：  bash build-ra2-intranet.sh [输出目录，默认 ./ra2-intranet]
# 依赖：  git、python3、curl、tar
#         node 不需要预装：版本不满足 vite 要求时脚本会自动下载便携版 Node，
#         只在构建目录内使用，不碰系统 node、不需要 root。
# 环境变量：RA2_FORCE_NODE=1  强制使用便携版 Node（忽略系统 node）
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-./ra2-intranet}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"   # 绝对化：脚本中途会 cd 进仓库，相对路径会算错
REPO="$OUT/redalert2"
WEBROOT="$OUT/webroot"
TOOLS="$OUT/toolchain"
NODE_LTS="v24.20.0"         # vite 8 / rolldown 需要 node ^20.19 || >=22.12
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

echo "==> [1/7] 准备目录 $OUT"

echo "==> [2/7] 检查 Node 工具链"
node_ok() {
    command -v node >/dev/null 2>&1 || return 1
    node -e 'const [a,b]=process.versions.node.split(".").map(Number);
             process.exit((a===20&&b>=19)||a>=22 ? 0 : 1)' 2>/dev/null
}
if [ "${RA2_FORCE_NODE:-0}" != "1" ] && node_ok; then
    echo "    系统 node $(node -v) 满足要求"
else
    if command -v node >/dev/null 2>&1; then
        echo "    系统 node $(node -v) 版本过低（vite 8 需要 ^20.19 || >=22.12）"
    else
        echo "    未检测到 node"
    fi
    case "$(uname -m)" in
        x86_64|amd64)  NARCH=x64 ;;
        aarch64|arm64) NARCH=arm64 ;;
        armv7l)        NARCH=armv7l ;;
        *) echo "!! 不支持的 CPU 架构 $(uname -m)，请手动安装 node >= 22.12" >&2; exit 1 ;;
    esac
    mkdir -p "$TOOLS"
    # 官方二进制需要 glibc >= 2.28；老系统（CentOS 7 等）回退到 unofficial-builds 的 glibc-2.17 变体
    CANDIDATES=(
        "https://nodejs.org/dist/${NODE_LTS}/node-${NODE_LTS}-linux-${NARCH}.tar.xz|node-${NODE_LTS}-linux-${NARCH}|官方"
    )
    if [ "$NARCH" = "x64" ]; then
        CANDIDATES+=("https://unofficial-builds.nodejs.org/download/release/${NODE_LTS}/node-${NODE_LTS}-linux-x64-glibc-217.tar.xz|node-${NODE_LTS}-linux-x64-glibc-217|glibc-2.17 兼容版")
    fi

    NODE_READY=0
    for entry in "${CANDIDATES[@]}"; do
        URL="${entry%%|*}"; rest="${entry#*|}"; DIRNAME="${rest%%|*}"; LABEL="${rest##*|}"
        NODE_DIR="$TOOLS/$DIRNAME"
        if [ ! -x "$NODE_DIR/bin/node" ]; then
            echo "    下载便携版 Node ${NODE_LTS} (${NARCH}, ${LABEL})"
            if ! curl -fL --progress-bar -o "$TOOLS/node.tar.xz" "$URL"; then
                echo "    下载失败，尝试下一个来源"
                continue
            fi
            tar -xJf "$TOOLS/node.tar.xz" -C "$TOOLS" || { echo "    解压失败，尝试下一个来源"; continue; }
            rm -f "$TOOLS/node.tar.xz"
        fi
        # 真正跑一次，确认二进制在本机能启动（glibc/架构不匹配会在这里暴露）
        if "$NODE_DIR/bin/node" -v >/dev/null 2>&1; then
            export PATH="$NODE_DIR/bin:$PATH"
            hash -r
            echo "    已切换到便携版 node $(node -v) (${LABEL})"
            NODE_READY=1
            break
        fi
        echo "    ${LABEL} 无法在本机运行（$("$NODE_DIR/bin/node" -v 2>&1 | head -1)）"
        rm -rf "$NODE_DIR"
    done

    if [ "$NODE_READY" != "1" ]; then
        echo "" >&2
        echo "!! 无法自动准备可用的 Node。你的系统 glibc: $(ldd --version 2>&1 | head -1)" >&2
        echo "   vite 8 需要 node ^20.19 || >=22.12，请手动安装后重跑，例如：" >&2
        echo "     curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs" >&2
        echo "   或改用不需要 node 的预构建路线（见 README 路线 B）。" >&2
        exit 1
    fi
fi

echo "==> [3/7] 克隆 huangkaoya/redalert2"
if [ ! -d "$REPO" ]; then
    git clone --depth 1 https://github.com/huangkaoya/redalert2.git "$REPO"
fi

echo "==> [4/7] 应用纯CDN模式补丁（rfs为空时不崩溃）"
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
    (r"private\s+rfs:\s*RealFileSystem\s*;",
     "private rfs: RealFileSystem | undefined;"),
    (r"constructor\s*\(\s*rfs:\s*RealFileSystem\s*,",
     "constructor(rfs: RealFileSystem | undefined,"),
    (r"of\s+this\.rfs\.getEntries\(\)",
     "of (this.rfs ? this.rfs.getEntries() : [])"),
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

echo "==> [5/7] 写入内网化配置并构建"
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
# 清空 MOD 远端清单：上游 mods.ini 里的 Download/Website 全是外网地址（k0s.cn、download.ra2web.com 等）
cat > public/mods.ini <<'MODEOF'
[General]
MODEOF
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
npm ci --no-audit --no-fund
node ./node_modules/vite/bin/vite.js build
[ -d dist ] || { echo "!! 构建未产出 dist/" >&2; exit 1; }

echo "==> [6/7] 同步构建产物到 webroot"
find "$WEBROOT" -mindepth 1 -maxdepth 1 ! -name cdn -exec rm -rf {} +
cp -r "$REPO/dist/." "$WEBROOT/"

echo "==> [7/7] 拉取游戏资源（官方CDN, 187MB）"
# 资源拉取逻辑只有一份实现：fetch-ra2-resources.sh。
# 优先用脚本同目录下的那份，没有就从仓库拉。
FETCH="$SELF_DIR/fetch-ra2-resources.sh"
if [ ! -f "$FETCH" ]; then
    FETCH="$OUT/fetch-ra2-resources.sh"
    echo "    本地未找到 fetch-ra2-resources.sh，从仓库获取"
    curl -fsS --retry 3 -o "$FETCH" \
        "https://raw.githubusercontent.com/Jieoz/ra2web-intranet-deploy/main/fetch-ra2-resources.sh"
fi
bash "$FETCH" "$WEBROOT"
