#!/usr/bin/env bash
# ra2-node-info.sh — 网页红警2 目标机配置采集（只读体检，一次一份报告）
#
# 用途：在要跑 RA2Web 的那台机器上运行一次，产出 ra2-node-info-<主机名>-<时间戳>.txt，
#       把报告发回来，就能据实选型"这台机器到底用什么浏览器/什么渲染路径跑游戏"。
# 约束：只读（除自身报告文件外不写任何东西）、零网络请求、无常驻进程、不需要 root。
#       任何探针失败都不中断采集——失败本身（比如 glxinfo 缺失）也是有效信息，照记进报告。
# 用法：bash ra2-node-info.sh [输出目录，默认脚本所在目录；不可写则退回 $HOME]
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SELF_DIR="$PWD"
OUT_DIR="${1:-$SELF_DIR}"
mkdir -p "$OUT_DIR" 2>/dev/null
if [ ! -w "$OUT_DIR" ]; then
    OUT_DIR="$HOME"
fi
HOST_TAG="$(hostname 2>/dev/null | tr -c 'A-Za-z0-9._-' '_')"
[ -n "${HOST_TAG:-}" ] || HOST_TAG="unknown"
TS="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT_DIR/ra2-node-info-${HOST_TAG}-${TS}.txt"

REPORTED=0
on_exit() {
    echo "=============================================="
    echo "采集完成，报告文件："
    echo "  $REPORT"
    echo "把这个文件原样发回去即可。"
}
trap on_exit EXIT

: > "$REPORT" 2>/dev/null || { echo "!! 无法创建报告文件：$REPORT" >&2; exit 1; }
REPORTED=1

# sec "标题"        —— 写一节分隔头
# runsh "说明" "片段" —— 跑一段探针；stdout+stderr+退出码全进报告，超时8秒兜底防挂
sec() {
    printf '\n================ %s ================\n' "$1" >> "$REPORT"
    echo "-- $1"
}
HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
runsh() {
    local label="$1" snippet="$2"
    printf '\n[%s]\n$ %s\n' "$label" "$snippet" >> "$REPORT"
    if [ "$HAVE_TIMEOUT" = 1 ]; then
        timeout 8 bash -c "$snippet" >> "$REPORT" 2>&1
    else
        bash -c "$snippet" >> "$REPORT" 2>&1
    fi
    printf '(exit=%s)\n' "$?" >> "$REPORT"
}

sec "0. 采集说明"
cat >> "$REPORT" <<EOF
脚本: ra2-node-info.sh（网页红警2 目标机体检）
采集时间: $(date '+%F %T' 2>/dev/null)
模式: 只读 / 零网络 / 无常驻进程 / 无需root
用途: 为"这台机器用什么浏览器跑 RA2Web"提供选型依据
EOF

sec "1. 系统基础"
runsh '操作系统' 'cat /etc/os-release 2>/dev/null; cat /etc/redhat-release 2>/dev/null; cat /etc/kylin-release 2>/dev/null; head -20 /etc/.kyinfo 2>/dev/null'
runsh '内核与架构' 'uname -a'
runsh 'CPU' 'lscpu 2>/dev/null | head -25 || head -30 /proc/cpuinfo'
runsh 'ARM 特性(NEON/ASIMD)' 'grep -m1 "^Features" /proc/cpuinfo 2>/dev/null || echo "非ARM或不可得"'
runsh '内存' 'grep -E "MemTotal|MemAvailable|SwapTotal" /proc/meminfo 2>/dev/null'
runsh '磁盘空间' 'df -h / /tmp /home /opt 2>/dev/null | sort -u'
runsh '当前用户' 'id'
runsh '时间与locale' 'date; locale 2>/dev/null | head -5'

sec "2. glibc / libstdc++（决定能运行多新的浏览器二进制）"
runsh 'glibc 版本' 'ldd --version 2>/dev/null | head -1; getconf GNU_LIBC_VERSION 2>/dev/null'
runsh 'GLIBCXX 符号上限(grep -a 直查,不依赖binutils)' 'grep -ao "GLIBCXX_[0-9.]*" /usr/lib64/libstdc++.so.6 /usr/lib/libstdc++.so.6 2>/dev/null | cut -d: -f2 | sort -Vu | tail -5'
runsh '关键版本符号逐项判定' 'for s in GLIBCXX_3.4.22 GLIBCXX_3.4.26 GLIBC_2.18 GLIBC_2.27; do if grep -aq "$s" /usr/lib64/libstdc++.so.6 /usr/lib64/libc.so.6 /usr/lib/libstdc++.so.6 /usr/lib/libc.so.6 2>/dev/null; then echo "$s: 有"; else echo "$s: 无"; fi; done'

sec "3. 图形栈（WebGL 能不能活的关键证据）"
runsh '会话与显示变量' 'echo "DISPLAY=$DISPLAY"; echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"; echo "XDG_SESSION_TYPE=$XDG_SESSION_TYPE"; echo "XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP"'
runsh 'X server 基本信息' 'xdpyinfo 2>/dev/null | grep -iE "GLX|dimensions|depth of root" | head -10 || echo "xdpyinfo 未安装"'
runsh 'glxinfo -B（mesa-demos，缺失只影响诊断精度）' 'command -v glxinfo >/dev/null 2>&1 && glxinfo -B 2>&1 | head -25 || echo "glxinfo 未安装"'
runsh 'Mesa 相关包与版本（判断 llvmpipe 支持的 OpenGL 上限）' 'rpm -qa 2>/dev/null | grep -i mesa | sort; dpkg -l 2>/dev/null | grep -i mesa | head -10'
runsh 'DRI 驱动文件' 'ls /usr/lib64/dri/ 2>/dev/null | head -20; ls /usr/lib/aarch64-linux-gnu/dri/ /usr/lib/x86_64-linux-gnu/dri/ 2>/dev/null | head -10'
runsh 'GL/EGL/GLES 库文件' 'ls -l /usr/lib64/libGL.so.1* /usr/lib64/libEGL.so.1* /usr/lib64/libGLESv2.so.2* /usr/lib/aarch64-linux-gnu/libGL.so.1* 2>/dev/null'
runsh 'libGL 里的 Mesa 版本串' 'for f in /usr/lib64/libGL.so.1.2.0 /usr/lib64/libGL.so.1 /usr/lib/aarch64-linux-gnu/libGL.so.1; do [ -e "$f" ] && grep -aom1 "Mesa [0-9][0-9.]*" "$f"; done; true'
runsh 'libglvnd/GL 库注册表' 'ldconfig -p 2>/dev/null | grep -E "libGL\.|libEGL|libGLX" | head -10'
runsh 'Mesa 配置与相关环境变量' 'cat /etc/drirc 2>/dev/null; cat "$HOME/.drirc" 2>/dev/null; env | grep -iE "^LIBGL|^GALLIUM|__GL|EGL_" ; true'
runsh 'Xorg 日志中的 GLX/AIGLX' 'grep -iE "AIGLX|GLX" /var/log/Xorg.0.log 2>/dev/null | head -15 || echo "Xorg.0.log 不可读或不存在"'

sec "4. 已安装浏览器"
runsh 'rpm 匹配(firefox/chromium/360/qihoo)' 'rpm -qa 2>/dev/null | grep -iE "firefox|chrom|browser|360|qihoo" | sort'
runsh 'PATH 里的浏览器' 'for b in firefox firefox-esr chromium chromium-browser google-chrome google-chrome-stable browser360 browser360-cn; do p=$(command -v "$b" 2>/dev/null); [ -n "$p" ] && echo "$b -> $p"; done; true'
runsh '常见安装目录' 'ls -d /usr/lib64/firefox* /usr/lib/firefox* /usr/lib64/chromium* /opt/*irefox* /opt/*hromium* /opt/360* /usr/local/*irefox* /usr/local/*hromium* 2>/dev/null; true'
runsh 'Firefox 版本' 'command -v firefox >/dev/null 2>&1 && (timeout 15 firefox --version 2>&1 | head -2) || echo "无 firefox"'
runsh '浏览器用户配置目录' 'ls -ld "$HOME/.mozilla" "$HOME/.config/chromium" "$HOME/.config/google-chrome" "$HOME/.config"/360* "$HOME/.config"/qihoo* 2>/dev/null; true'

sec "5. 浏览器 GPU 崩溃证据（尽力收集）"
runsh 'GPU/崩溃相关小日志尾部' 'find "$HOME/.mozilla" "$HOME/.config/chromium" "$HOME/.config/google-chrome" "$HOME/.config"/360* "$HOME/.config"/qihoo* -maxdepth 4 -type f \( -iname "*gpu*" -o -iname "*crash*" \) -size -200k 2>/dev/null | head -8 | while IFS= read -r f; do echo "----- $f -----"; tail -c 3000 "$f" 2>/dev/null; echo; done; true'
runsh 'Firefox Crash Reports' 'ls -lt "$HOME/.mozilla/firefox/"*.default*/crashes 2>/dev/null | head -5; ls -lt "$HOME/.mozilla/firefox/Crash Reports" 2>/dev/null | head -5; true'

sec "6. 中文字体"
runsh 'CJK 字体' 'fc-list 2>/dev/null | grep -icE "cjk|noto sans|wqy|uming|ukai|zenhei"; fc-list :lang=zh 2>/dev/null | head -5'

sec "7. 工具链（后续适配部署要用）"
runsh '常用工具与版本' 'for c in curl wget tar xz unzip cpio rpm2cpio python3 python2 gcc; do printf "%s: " "$c"; if command -v "$c" >/dev/null 2>&1; then "$c" --version 2>&1 | head -1; else echo "缺失"; fi; done'
runsh 'yum 源文件清单(不联网)' 'ls /etc/yum.repos.d/ 2>/dev/null; true'

sec "8. 采集结束"
printf '结束时间: %s\n' "$(date '+%F %T' 2>/dev/null)" >> "$REPORT"
