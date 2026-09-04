#!/usr/bin/env bash
# build-ra2-intranet.sh — 网页红警2（RA2Web/Chronodivide 客户端重构版）内网离线部署一键构建脚本
#
# 用途：在有外网的机器上执行一次，产出可整体拷入内网的纯静态站点 webroot/。
# 之后内网任意静态文件服务器托管即可，运行期零外网依赖。
# 多人联机走游戏内置 LAN 模式（WebRTC P2P）。跨机器对战需要一个内网 STUN，
# 脚本会把上游写死的 iceServers=[] 改成可自动推导，配套 ministun.py 即可，仍零外网。
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

echo "==> [4b/7] 应用局域网直连补丁（iceServers 可配置）"
python3 - <<'PYEOF'
import pathlib, re, sys

# 为什么需要这个补丁：
# 上游把两处 RTCPeerConnection 的 iceServers 硬编码成 []，用意是"零外部依赖"。
# 但现代浏览器默认用 mDNS 假名（<uuid>.local）替代真实内网 IP 上报 host candidate，
# 于是 SDP 里只有一条 *.local 候选，没有可路由的局域网 IPv4。对端要解析这个名字
# 得靠 mDNS 广播（UDP 5353），交换机/AP 的客户端隔离常把它丢掉 —— 表现就是
# 同机开两个标签页能连、两台机器连不上。
# 上游自己的 SdpCandidateDiagnostics 就为这个组合准备了失败警告文案。
#
# 修法：把 iceServers 变成运行期可配置。内网架一个 STUN（仅回 Binding Response，
# 不做中继），浏览器就会额外采集 srflx 候选，内容正是它的真实内网 IP:端口，
# 跨机器直连成立，且全程不出内网。不配则保持原行为（空列表）。
GLOBAL = "globalThis.__ra2LanIceServers"

# 1) Config：暴露 lanStunUrl（读 config.ini 的 [General] lanStunUrl）
p = pathlib.Path("src/Config.ts")
s = p.read_text()
if "lanStunUrl" not in s:
    anchor = '    get serversUrl(): string {'
    if anchor not in s:
        print("!! Config.ts 未找到 serversUrl getter 锚点", file=sys.stderr)
        sys.exit(1)
    s = s.replace(anchor,
        '    get lanStunUrl(): string {\n'
        '        return this.generalData.getString("lanStunUrl");\n'
        '    }\n' + anchor, 1)
    p.write_text(s)
    print("    Config.ts：已加 lanStunUrl getter")

# 1b) 给 globalThis 上的自定义属性补类型声明。
# 当前上游 tsconfig 是 strict:false 且 vite 用 esbuild 转译（不做类型检查），
# 不声明也能构建；但一旦上游打开 strict 就会 TS2339。声明成本为零，先钉住。
decl = pathlib.Path("src/ra2-lan-ice.d.ts")
if not decl.exists():
    decl.write_text(
        "// 由 build-ra2-intranet.sh 生成：内网 LAN 对战的 iceServers 运行期注入点。\n"
        "declare global {\n"
        "    // eslint-disable-next-line no-var\n"
        "    var __ra2LanIceServers: RTCIceServer[] | undefined;\n"
        "}\n"
        "export {};\n")
    print("    已生成 src/ra2-lan-ice.d.ts（globalThis 类型声明）")

# 1c) 生成 STUN 自动推导 + 探测模块。
# 为什么不能直接把推导出的地址当默认值用：实测不可达的 STUN 会让 ICE 采集
# 拖到 ~40 秒才 complete，而上游 waitForIceGatheringComplete 的超时是 10 秒
# （ICE_GATHER_TIMEOUT_MILLIS，两个 LAN 文件各一份），超时直接抛
# "ICE 候选收集超时，请稍后重试"。也就是说天真的自动填值会把"没装 STUN 的人
# 至少能同机联机"变成"等 10 秒然后硬报错"—— 那是回归。
# 所以先探再用：拿一个一次性 RTCPeerConnection 探 1.5 秒，只有真的收到 srflx
# 候选才采纳，否则保持空列表（= 上游行为）。探测不 await，因为进 LAN 界面要
# 好几次点击，1.5 秒早已结束；全局值先钉成 [] 保证任何时刻读到的都是安全值。
lan_ice = pathlib.Path("src/ra2LanIce.ts")
lan_ice.write_text('''// 由 build-ra2-intranet.sh 生成：局域网对战的 STUN 自动推导与可用性探测。
//
// 浏览器为防指纹，默认用 <uuid>.local 假名替换 host candidate 里的真实内网 IP，
// JS 层没有任何 API 能读到本机可路由地址。要拿到它只能问一个外部反射点
// "你看到我从哪来" —— 这就是 STUN 的作用，省不掉。
// 但地址不必让人填：STUN 就跑在托管本站的那台机器上，而 location.hostname
// 已经是它。默认按站点来源推导 stun:<hostname>:3478。

const DEFAULT_STUN_PORT = 3478;
// 实测可达时 srflx 候选在 3ms 内就到，1.5s 是很宽裕的上限。
const PROBE_TIMEOUT_MILLIS = 1500;

function deriveStunUrl(): string | undefined {
    const host = globalThis.location?.hostname;
    if (!host) {
        return undefined;
    }
    return `stun:${host}:${DEFAULT_STUN_PORT}`;
}

/** 探测该 STUN 是否真能产出 srflx 候选。不可达时靠超时返回 false，不抛。 */
async function probeStun(url: string): Promise<boolean> {
    let pc: RTCPeerConnection | undefined;
    try {
        pc = new RTCPeerConnection({ iceServers: [{ urls: url }] });
        pc.createDataChannel('ra2-stun-probe');
        const gotReflexive = new Promise<boolean>((resolve) => {
            const timer = setTimeout(() => resolve(false), PROBE_TIMEOUT_MILLIS);
            pc!.addEventListener('icecandidate', (e) => {
                const c = e.candidate;
                if (!c) {
                    return;
                }
                // c.type 在个别实现里可能为空，故同时看候选串本身。
                if (c.type === 'srflx' || / typ srflx /.test(c.candidate)) {
                    clearTimeout(timer);
                    resolve(true);
                }
            });
        });
        await pc.setLocalDescription(await pc.createOffer());
        return await gotReflexive;
    } catch (e) {
        console.warn('[LAN] STUN 探测出错，按不可用处理：', e);
        return false;
    } finally {
        pc?.close();
    }
}

/**
 * 决定局域网对战用的 iceServers，结果发布到 globalThis.__ra2LanIceServers。
 * configured 来自 config.ini 的 [General] lanStunUrl：
 *   留空  = 自动推导 stun:<站点hostname>:3478，探测通过才启用
 *   off   = 强制关闭，不推导不探测（等同上游行为）
 *   其它  = 显式指定，同样要探测通过才启用
 */
export function initLanIceServers(configured: string): void {
    // 先钉住安全默认值：任何时刻被读到都是上游行为，探测成功才升级。
    globalThis.__ra2LanIceServers = [];

    const raw = (configured ?? '').trim();
    if (raw.toLowerCase() === 'off') {
        console.log('[LAN] lanStunUrl=off，不使用 STUN（仅 mDNS 候选，跨机器可能连不上）');
        return;
    }

    const explicit = raw.length > 0;
    const url = explicit ? raw : deriveStunUrl();
    if (!url) {
        console.warn('[LAN] 无法推导 STUN 地址（拿不到 location.hostname），跳过');
        return;
    }

    // 故意不 await：探测最多 1.5s，而玩家要点几次菜单才进得了局域网界面，
    // 届时全局值早已就位；万一真在探测完成前就进去，读到的是空列表 = 上游行为。
    void probeStun(url).then((usable) => {
        if (usable) {
            globalThis.__ra2LanIceServers = [{ urls: url }];
            console.log(`[LAN] STUN 可用：${url}（${explicit ? '配置指定' : '按站点自动推导'}）`);
        } else if (explicit) {
            console.warn(`[LAN] 配置的 STUN ${url} 探测失败，已退回无 STUN；跨机器对战会连不上。`);
        } else {
            console.log(`[LAN] 未在 ${url} 发现 STUN，按无 STUN 运行。`
                + '跨机器对战需在本站所在机器上运行 ministun.py。');
        }
    });
}
''')
print("    已生成 src/ra2LanIce.ts（自动推导 + 可用性探测）")

# 2) Application：config 加载完后初始化 LAN iceServers
p = pathlib.Path("src/Application.ts")
s = p.read_text()
if "initLanIceServers" not in s:
    imp_anchor = "import { Config } from './Config';"
    if imp_anchor not in s:
        print("!! Application.ts 未找到 Config import 锚点", file=sys.stderr)
        sys.exit(1)
    s = s.replace(imp_anchor,
        imp_anchor + "\nimport { initLanIceServers } from './ra2LanIce';", 1)
    anchor = "            console.log('[Application] Verification: Servers URL from config:', this.config.serversUrl);"
    if anchor not in s:
        print("!! Application.ts 未找到 config 加载后的锚点", file=sys.stderr)
        sys.exit(1)
    s = s.replace(anchor, anchor + '\n'
        '            initLanIceServers(this.config.lanStunUrl);', 1)
    p.write_text(s)
    print("    Application.ts：已接入 initLanIceServers")

# 3) 两处 RTCPeerConnection 改读该全局值
# 精确匹配 new RTCPeerConnection({ iceServers: [] }) 的 iceServers 行，
# 不动周边代码结构；两个文件的写法一致但缩进不同，故按表达式替换。
targets = [
    "src/network/lan/LanMeshSession.ts",
    "src/network/lan/ManualSdpLanSession.ts",
]
patched = 0
for t in targets:
    p = pathlib.Path(t)
    s = p.read_text()
    if GLOBAL in s:
        patched += 1
        continue
    new_s, n = re.subn(r"iceServers:\s*\[\s*\],", "iceServers: " + GLOBAL + " ?? [],", s)
    if n != 1:
        print(f"!! {t}: 期望 1 处 iceServers:[]，实际 {n} 处", file=sys.stderr)
        sys.exit(1)
    p.write_text(new_s)
    patched += 1

# 自检：确认两处都不再是硬编码空列表，且 iceServers 键名仍在
# （上一版正则把键名一起吃掉了，产出 `{ globalThis.x ?? [], }` 这种语法错误，
#  而"空列表已消失 + 全局名已出现"两个断言全都通过 —— 断言必须钉到键值对本身。）
for t in targets:
    s = pathlib.Path(t).read_text()
    if re.search(r"iceServers:\s*\[\s*\],", s):
        print(f"!! {t}: 仍存在硬编码 iceServers:[]", file=sys.stderr)
        sys.exit(1)
    if not re.search(r"iceServers:\s*" + re.escape(GLOBAL) + r"\s*\?\?\s*\[\]", s):
        print(f"!! {t}: 未生成 `iceServers: {GLOBAL} ?? []` 键值对", file=sys.stderr)
        sys.exit(1)

# 自检：自动推导链必须真的接上。
# 注意区分两类断言的承重程度：Application.ts 那两条是真承重的（补丁没接上就红，
# 已消融验证）；下面对 ra2LanIce.ts 的四条是**漂移守卫**——该文件由本脚本整份
# 生成，断言读的是自己刚写下的字面量，只能在"以后有人改了 heredoc 却忘了同步
# 断言"时报警，不构成对源码树的验证。写清楚免得后人误以为它在验证运行时行为。
app = pathlib.Path("src/Application.ts").read_text()
if "import { initLanIceServers } from './ra2LanIce';" not in app:
    print("!! Application.ts 缺少 initLanIceServers 的 import", file=sys.stderr)
    sys.exit(1)
if "initLanIceServers(this.config.lanStunUrl)" not in app:
    print("!! Application.ts 未调用 initLanIceServers(this.config.lanStunUrl)", file=sys.stderr)
    sys.exit(1)
ice_mod = pathlib.Path("src/ra2LanIce.ts").read_text()
for need, why in [
    ("location?.hostname", "缺少按站点推导 hostname 的逻辑"),
    ("srflx", "探测未检查 srflx 候选，等于没验证 STUN 可用性"),
    (GLOBAL + " = [{ urls: url }]", "探测通过后未写回全局 iceServers"),
    (GLOBAL + " = [];", "缺少安全默认值（探测完成前必须是空列表）"),
]:
    if need not in ice_mod:
        print(f"!! ra2LanIce.ts: {why}", file=sys.stderr)
        sys.exit(1)
print(f"    局域网补丁应用成功（{patched} 处 RTCPeerConnection 改为可配置，STUN 地址自动推导）")
PYEOF

echo "==> [4c/7] 修正静态资源路径（CSS 相对路径与残留 favicon）"
python3 - <<'PYEOF'
import pathlib, re, sys

# main-legacy.css 位于 /css/ 下，里面写的是相对路径 url(res/img/xxx.png)，
# 浏览器按样式表位置解析成 /css/res/img/xxx.png -> 404（文件实际在 /res/img/）。
# 改成根绝对路径。cd-logo.png 上游 dist 里根本不存在，连带该规则一起去掉背景引用。
css = pathlib.Path("public/css/main-legacy.css")
if not css.exists():
    css = pathlib.Path("src/css/main-legacy.css")
if css.exists():
    s = css.read_text()
    orig = s
    s = s.replace("url(res/img/", "url(/res/img/")
    # cd-logo.png 上游 public/res/img/ 里根本不存在（只有 download-arrow / drag-*），
    # 引用它必然 404。它写成 `background: url(...) no-repeat center center;` 的简写形式，
    # 不是 background-image，按 background-image 匹配会漏掉 —— 按 url() 本身匹配。
    s = re.sub(r"background:\s*url\(/res/img/cd-logo\.png\)[^;]*;",
               "background: none;", s)
    s = re.sub(r"\s*background-image:\s*url\(/res/img/cd-logo\.png\);", "", s)
    if s != orig:
        css.write_text(s)
        print(f"    {css}：已修正相对路径引用")
    else:
        print(f"    {css}：无需修改")
    # 自检：产物里不能再有指向不存在文件的引用，也不能残留相对路径
    chk = css.read_text()
    if "url(res/img/" in chk:
        print("!! CSS 仍有相对路径 url(res/img/...)", file=sys.stderr)
        sys.exit(1)
    if "cd-logo" in chk:
        print("!! CSS 仍引用不存在的 cd-logo.png", file=sys.stderr)
        sys.exit(1)
else:
    print("!! 未找到 main-legacy.css", file=sys.stderr)
    sys.exit(1)

# index.html 的 favicon 指向 Vite 模板残留的 /vite.svg，产物里没有这个文件。
idx = pathlib.Path("index.html")
if idx.exists():
    s = idx.read_text()
    orig = s
    # 换成内联 data: URI，而不是单纯删掉这个 <link>：没有 icon 声明时浏览器会自己
    # 去请求 /favicon.ico，访问日志里照样留一条 404（实测确认）。内联后请求不发出，
    # 也不必往包里塞图标文件。
    s = re.sub(r'<link rel="icon"[^>]*href="/vite\.svg"[^>]*/?>',
               '<link rel="icon" href="data:,">', s)
    # vite.svg 那行不一定在（上游可能自己删掉，或本树已被旧版补丁处理过）。
    # 只做替换会留下"完全没有 icon 声明"的状态，浏览器照样请求 /favicon.ico。
    # 所以缺失时补插一条，而不是依赖那个 <link> 必然存在。
    if 'rel="icon"' not in s:
        s = s.replace('</head>', '    <link rel="icon" href="data:,">\n</head>', 1)
    if s != orig:
        idx.write_text(s)
        print("    index.html：favicon 改为内联 data: URI（消除 /favicon.ico 404）")
    # 自检：产物不能再引用 vite.svg，且必须有一个 icon 声明（否则浏览器自动请求 .ico）
    chk = idx.read_text()
    if "vite.svg" in chk:
        print("!! index.html 仍引用 /vite.svg", file=sys.stderr)
        sys.exit(1)
    if 'rel="icon"' not in chk:
        print("!! index.html 缺少 icon 声明，浏览器会自动请求 /favicon.ico 并 404", file=sys.stderr)
        sys.exit(1)
else:
    print("!! 未找到 index.html", file=sys.stderr)
    sys.exit(1)
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

# 局域网对战用的 STUN 服务器。**默认留空即自动**：客户端按站点地址推导
# stun:<本站hostname>:3478，启动时探测 1.5 秒，确认能拿到 srflx 候选才启用；
# 探测不到就按无 STUN 运行（等同上游行为，不影响同机联机）。
# 所以正常情况下你只需在这台机器上跑 `python3 ministun.py 0.0.0.0 3478`，
# 这里不用改。
#   留空  = 自动推导 + 探测（推荐）
#   off   = 强制不用 STUN
#   显式值 = 指定别的地址，例 lanStunUrl=stun:192.168.1.10:3478
lanStunUrl=
CFGEOF
# 清空 MOD 远端清单：上游 mods.ini 里的 Download/Website 全是外网地址（k0s.cn、download.ra2web.com 等）
cat > public/mods.ini <<'MODEOF'
[General]
MODEOF
# 不写 servers.ini：那是官方战网登录（LoginScreen/WolService）用的服务器列表，
# 内网 LAN 对战走 WebRTC，完全不读它。之前这里生成过一份带 wolUrl/apiRegUrl 的
# 占位文件，实测其中每个键在客户端里都没有任何读取方 —— 纯摆设，删掉避免误导。
rm -f public/servers.ini
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
