#!/usr/bin/env bash
# ra2-browser-probe.sh — 网页红警2 目标机浏览器渲染路线探针（只读体检+生成启动器）
#
# 背景：目标机 NeoKylin 7.0 aarch64，glibc 2.17 / GLIBCXX≤3.4.19，装不了任何现代浏览器；
#       机上只有 360安全/360企业/lbrowser（Chromium 69 代际）和 Firefox 52（无 WebGL2，跳过）。
#       系统 GL 是 swrast（GL 2.1），Chromium 默认 GLX/ANGLE 路径报 BindToCurrentSequence failed，
#       但机器有 mesa-libEGL + libGLESv2 —— 走 EGL/GLES 的 llvmpipe 才有 WebGL2 可言。
# 做法：本机起一次性 python 信标服务（127.0.0.1 随机端口，零依赖）；
#       自检页（file:// 加载，零外网）算完结论后用图片信标回传；无 dump/CDP 依赖。
#       每台已装浏览器 × 7 组渲染参数实测，第一个出 WEBGL2-OK 的组合立即生成
#       免安装启动器 ra2-launch.sh（打开游戏站点用）。
# 约束：不需要 root、不改系统配置；除 $HOME/ra2-browser-fix/ 外不写任何东西。
# 用法：bash ra2-browser-probe.sh [游戏站点URL，默认 http://143.33.32.220:8080/]
# 产物：$HOME/ra2-browser-fix/ 下的 探测日志、逐次尝试记录、(成功时) ra2-launch.sh
set -u

SITE="${1:-http://143.33.32.220:8080/}"
WORK="$HOME/ra2-browser-fix"
mkdir -p "$WORK/attempt-logs" 2>/dev/null || { echo "!! 无法创建工作目录 $WORK" >&2; exit 1; }
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$WORK/probe-${TS}.log"
BEACON_DIR="$WORK/.beacon"
BEACON_PID=""

exec > >(tee -a "$LOG") 2>&1
cleanup() {
    [ -n "$BEACON_PID" ] && kill "$BEACON_PID" 2>/dev/null
    echo "----- 信标收包记录(全轮) -----"
    cat "$BEACON_DIR/hit.txt" 2>/dev/null || echo "(无收包)"
    rm -rf "$BEACON_DIR"
    printf "\n===== 本轮完整日志 =====\n%s\n" "$LOG"
}
trap cleanup EXIT

echo "== RA2Web 目标机浏览器探针 =="
echo "站点: $SITE"
echo "工作目录: $WORK"

# ---------- 一次性信标服务（python3 标准库，回退 python2） ----------
# 端口池依次尝试，全部被占才放弃（自检不落盘=失败）
BEACON_PORT=""
start_beacon() {
    rm -rf "$BEACON_DIR"; mkdir -p "$BEACON_DIR"
    local PY=""
    command -v python3 >/dev/null 2>&1 && PY=python3
    [ -z "$PY" ] && command -v python2 >/dev/null 2>&1 && PY=python2
    [ -z "$PY" ] && { echo "!! 需要 python3 或 python2（仅用于本机信标）"; return 1; }
    local cand
    for cand in 39271 39273 39277 39281 39283; do
        rm -f "$BEACON_DIR/hit.txt"
        "$PY" - "$cand" "$BEACON_DIR" <<'PYEOF' &
import sys, threading
try:
    from http.server import HTTPServer, BaseHTTPRequestHandler  # py3
except ImportError:
    from BaseHTTPServer import HTTPServer                      # py2
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            with open(sys.argv[2] + '/hit.txt', 'a') as f:
                f.write(self.path + '\n')
        except Exception:
            pass
        try:
            self.send_response(204)
            self.end_headers()
        except Exception:
            pass
    def log_message(self, *a):
        pass
srv = HTTPServer(('127.0.0.1', int(sys.argv[1])), H)
srv.serve_forever()
PYEOF
        BEACON_PID=$!
        sleep 1
        kill -0 "$BEACON_PID" 2>/dev/null || continue   # 端口被占，python 已退出
        # 自检：信标必须真的能落盘
        (command -v curl >/dev/null 2>&1 && curl -s --max-time 2 "http://127.0.0.1:$cand/selftest" >/dev/null) || \
            (echo > /dev/tcp/127.0.0.1/$cand) 2>/dev/null || { kill "$BEACON_PID" 2>/dev/null; continue; }
        sleep 1
        if [ -f "$BEACON_DIR/hit.txt" ]; then
            BEACON_PORT="$cand"
            echo "信标服务就绪: 127.0.0.1:$BEACON_PORT"
            return 0
        fi
        kill "$BEACON_PID" 2>/dev/null
    done
    echo "!! 信标服务启动失败（端口池全占或本机回环不可用）"
    return 1
}

# ---------- 内嵌自检页（与仓库 webgl-check.html 同源，改必同步） ----------
cat > "$WORK/webgl-check.html" <<'HTMLEOF'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>WebGL 自检</title>
</head>
<body style="background:#141414;color:#33ff66;font-family:monospace;padding:16px;line-height:1.5">
<h2>RA2Web WebGL 自检</h2>
<pre id="out">检测中...</pre>
<script>
(function () {
    function line(s) {
        document.getElementById('out').textContent += s + "\n";
    }
    function info(gl) {
        var r = '(浏览器隐藏)', v = '(浏览器隐藏)';
        try {
            var d = gl.getExtension('WEBGL_debug_renderer_info');
            if (d) {
                r = gl.getParameter(d.UNMASKED_RENDERER_WEBGL);
                v = gl.getParameter(d.UNMASKED_VENDOR_WEBGL);
            }
        } catch (e) { r = '(取renderer出错: ' + e + ')'; }
        var mt = '?';
        try { mt = gl.getParameter(gl.MAX_TEXTURE_SIZE); } catch (e) {}
        var ver = '?';
        try { ver = gl.getParameter(gl.VERSION); } catch (e) {}
        return '    RENDERER: ' + r + "\n" +
               '    VENDOR: ' + v + "\n" +
               '    GL_VERSION: ' + ver + "\n" +
               '    MAX_TEXTURE_SIZE: ' + mt + "\n";
    }
    var out = document.getElementById('out');
    out.textContent = '';
    var BPORT = null;
    try {
        var m = location.search.match(/[?&]beacon=(\d+)/);
        if (m) BPORT = m[1];
    } catch (e) {}
    function beacon(path) {
        if (!BPORT) return;
        try { new Image().src = 'http://127.0.0.1:' + BPORT + path; } catch (e) {}
    }
    beacon('/start');
    var ok = false;
    try {
        var g1 = null, g2 = null;
        try { g1 = document.createElement('canvas').getContext('webgl') ||
                   document.createElement('canvas').getContext('experimental-webgl'); } catch (e) {}
        try { g2 = document.createElement('canvas').getContext('webgl2'); } catch (e) {}
        line('WebGL1: ' + (g1 ? '可用' : '不可用'));
        if (g1) line(info(g1));
        line('WebGL2: ' + (g2 ? '可用' : '不可用'));
        if (g2) line(info(g2));
        var mt2 = 0;
        try { mt2 = g2 ? g2.getParameter(g2.MAX_TEXTURE_SIZE) : 0; } catch (e) {}
        ok = !!g2 && mt2 >= 2048;
        line(ok ? '结论: WEBGL2-OK 该浏览器可运行 RA2Web'
                : '结论: WEBGL2-FAIL 无法运行（游戏需要 WebGL2，本机/本浏览器未提供）');
        document.title = ok ? 'WEBGL2-OK' : 'WEBGL2-FAIL';
    } catch (e) {
        line('结论: WEBGL2-FAIL 检测异常: ' + e);
        document.title = 'WEBGL2-FAIL';
    }
    var rBrief = '';
    try {
        var g3 = ok ? g2 : (g1 || g2);
        if (g3) {
            var dd = g3.getExtension('WEBGL_debug_renderer_info');
            if (dd) rBrief = String(g3.getParameter(dd.UNMASKED_RENDERER_WEBGL));
        }
    } catch (e) {}
    beacon('/r?ok=' + (ok ? 1 : 0) + '&r=' + encodeURIComponent(rBrief));
})();
</script>
</body>
</html>
HTMLEOF

# ---------- 发现已装浏览器（顺序即优先级） ----------
BROWSERS=""
for b in lbrowser browser360-cn browser360ent-cn browser360ent chromium chromium-browser google-chrome-stable google-chrome firefox firefox-esr; do
    p="$(command -v "$b" 2>/dev/null)"
    [ -n "$p" ] || continue
    dup=0
    for existing in $BROWSERS; do
        [ "$existing" = "$p" ] && dup=1
    done
    [ "$dup" = 0 ] && BROWSERS="$BROWSERS $p"
done
if [ -z "$BROWSERS" ]; then
    echo "!! 未发现可用浏览器（找过 lbrowser/360/chromium/google-chrome）"
    exit 1
fi
echo "发现浏览器:$BROWSERS"
echo

# ---------- Chromium 系参数矩阵（顺序即尝试顺序：EGL/GLES 优先，纯 SwiftShader 垫底） ----------
MATRIX="
GLES-EGL最强|--use-gl=angle --use-angle=gles --enable-unsafe-swiftshader --ignore-gpu-blocklist --enable-gpu-rasterization
GLES-EGL基本|--use-angle=gles --enable-unsafe-swiftshader --ignore-gpu-blocklist
ANGLE-EGL旧写法|--use-gl=egl --use-angle=gles --enable-unsafe-swiftshader
仅解除熔断|--enable-unsafe-swiftshader --ignore-gpu-blocklist
SwiftShader-ANGLE|--use-gl=angle --use-angle=swiftshader --enable-unsafe-swiftshader
SwiftShader-基本|--use-angle=swiftshader --enable-unsafe-swiftshader
裸跑(浏览器默认)|--ignore-gpu-blocklist
"

WINNER=""
SUMMARY=""

probe_one() {
    # $1=浏览器路径  $2=组名  $3=参数串  ; 成功 echo OK
    local bin="$1" gname="$2" gargs="$3"
    local tag
    tag="$(basename "$bin")-$(echo "$gname" | tr -c 'A-Za-z0-9' '_')"
    local outfile="$WORK/attempt-logs/${tag}.dom"
    set -f
    # shellcheck disable=SC2086
    set -- $gargs
    rm -f "$BEACON_DIR/hit.txt"
    timeout 40 "$bin" --headless --no-sandbox --disable-setuid-sandbox --disable-gpu-sandbox \
        --no-first-run --no-default-browser-check --disable-background-networking \
        --disable-component-update --disable-sync --disable-extensions \
        --user-data-dir="$WORK/prof-$tag" \
        "$@" "file://$WORK/webgl-check.html?beacon=$BEACON_PORT" \
        > "$outfile" 2> "$WORK/attempt-logs/${tag}.err"
    local rc=$?
    set +f
    rm -rf "$WORK/prof-$tag"
    cp "$BEACON_DIR/hit.txt" "$WORK/attempt-logs/${tag}.beacon" 2>/dev/null || true
    # 信标回传 /r?ok=1 即成功（不依赖 dump-dom/CDP/WebSocket）
    # 注意：hit.txt 落盘的是 self.path，行首无 "GET " 前缀
    if grep -q '^/r?ok=1' "$BEACON_DIR/hit.txt" 2>/dev/null; then
        local rend
        rend="$(grep -m1 '^/r?' "$BEACON_DIR/hit.txt" | sed 's/.*[?&]r=//; s/&ok=.*//; s/&.*//')"
        rend="$(printf '%b' "${rend//%/\\x}")"
        echo "    [$gname] 成功 (renderer: ${rend:-未知})"
        return 0
    elif [ $rc -eq 124 ]; then
        echo "    [$gname] 超时(40s)（浏览器进程被强杀）"
    else
        echo "    [$gname] 失败 exit=$rc $(grep -m1 -iE 'ERROR' "$WORK/attempt-logs/${tag}.err" 2>/dev/null | head -c 120)"
    fi
    return 1
}

start_beacon || exit 1

for bin in $BROWSERS; do
    echo "== 浏览器: $bin =="
    # Firefox 特判：<54 无 WebGL2，直接跳过
    "$bin" --version 2>/dev/null | grep -qi firefox && {
        fvmaj="$("$bin" --version 2>/dev/null | sed -n 's/.*Firefox \([0-9][0-9]*\).*/\1/p')"
        if [ -n "${fvmaj:-}" ] && [ "$fvmaj" -lt 54 ] 2>/dev/null; then
            echo "    Firefox $fvmaj 无 WebGL2（需要 >=54），跳过"
            SUMMARY="$SUMMARY
$bin : 跳过（Firefox $fvmaj 无 WebGL2）"
            continue
        fi
    }
    echo "$MATRIX" | while IFS='|' read -r gname gargs; do
        [ -n "$gname" ] || continue
        if probe_one "$bin" "$gname" "$gargs"; then
            echo "WINNER|$bin|$gname|$gargs" >> "$WORK/.winner"
            break
        fi
    done
    if [ -f "$WORK/.winner" ]; then
        WINNER="$(cat "$WORK/.winner")"
        rm -f "$WORK/.winner"
        break
    fi
    SUMMARY="$SUMMARY
$bin : 全部参数组失败（详见 $WORK/attempt-logs/）"
done

echo
echo "================ 探测结果 ================"
if [ -n "$WINNER" ]; then
    wbin="$(echo "$WINNER" | cut -d'|' -f2)"
    wgname="$(echo "$WINNER" | cut -d'|' -f3)"
    wargs="$(echo "$WINNER" | cut -d'|' -f4)"
    echo "胜出: $(basename "$wbin") + [$wgname]"
    LAUNCHER="$WORK/ra2-launch.sh"
    {
        echo '#!/usr/bin/env bash'
        echo "# RA2Web 启动器 — 由 ra2-browser-probe.sh 于 $(date '+%F %T') 依据实测生成"
        echo "# 路线: $(basename "$wbin") + 参数组[$wgname]"
        echo "# 用法: bash $LAUNCHER   （或桌面快捷方式指向本文件）"
        echo 'set -u'
        echo "SITE=\"$SITE\""
        echo "PROFILE=\"$WORK/profile\""
        echo "set -f"
        echo "# shellcheck disable=SC2086"
        echo "set -- $wargs"
        echo "exec \"$wbin\" --no-sandbox --disable-setuid-sandbox --user-data-dir=\"\$PROFILE\" \"\$@\" \"\$SITE\""
    } > "$LAUNCHER"
    chmod +x "$LAUNCHER"
    echo "启动器已生成: $LAUNCHER"
    echo "以后玩红警2就运行它（浏览器窗口打开游戏站点，参数已带好）。"
    SUMMARY="$SUMMARY
胜出: $wbin + [$wgname] -> $LAUNCHER"
else
    echo "结论: 所有已装浏览器在全部参数组下都无法提供 WebGL2。"
    echo "下一步（按性价比）:"
    echo "  1) 看各 attempt-logs/*.err 的首个 ERROR 行，发回来我判读；"
    echo "  2) 若全是 GPU 进程崩溃 -> 该代际 Chromium 与此 Mesa 组合无解，"
    echo "     需要推动 KVM 侧给这台机器开 3D 加速(virtio-gpu/VirGL)，"
    echo "     或换一台有 GL 加速的机器跑游戏。"
    SUMMARY="$SUMMARY
结论: 全部失败（日志: $LOG）"
fi
echo "$SUMMARY"
