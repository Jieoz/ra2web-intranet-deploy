#!/usr/bin/env python3
"""基准机（Ubuntu 18.04 / python3.6 / POSIX locale）兼容性静态门禁。

为什么需要它：这个仓库的构建脚本要在 Jay 的基准部署机上跑，那台机器是
python3.6.9、LANG 为空、locale=POSIX。开发机是 python3.13，下面每一条在
开发机上都不会报错，只在基准机上崩，而且崩点看起来像网络故障：

  1. `X | None` 类型注解        —— 3.10+ 语法，3.6 抛 TypeError
  2. subprocess capture_output/text —— 3.7+ 参数，3.6 抛 TypeError
  3. Path.read_text/write_text 不带 encoding
       —— 用 locale.getpreferredencoding()，POSIX locale 下是 ASCII，
          读写含中文的文件直接 UnicodeEncodeError
  4. f-string 里的 = 自文档       —— 3.8+
  5. walrus :=                   —— 3.8+

用法：python3 check_py36_compat.py <文件...>
退出码 0 = 全部通过，1 = 有违规。
"""
import io
import re
import sys

# 这个脚本自己也要能在基准机上跑（python3.6 + POSIX locale），而它输出中文。
# 不能靠调用方 export PYTHONIOENCODING —— 手工直接跑它时没人 export，
# 结果就是"检查全通过、最后一句 print 崩掉、退出码 1"，门禁反过来挡住构建。
# sys.stdout.reconfigure() 是 3.7+，所以用 TextIOWrapper 重包一层。
if (sys.stdout.encoding or '').lower() not in ('utf-8', 'utf8'):
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')

# .read_text( / .write_text( 之后到平衡右括号之间必须出现 encoding=
def _balanced_end(s, open_paren):
    """返回与 s[open_paren] 匹配的右括号下标，跳过字符串字面量。"""
    depth = 0
    j = open_paren
    n = len(s)
    while j < n:
        c = s[j]
        if c in '\'"':
            if s[j:j + 3] in ("'''", '"""'):
                q = s[j:j + 3]
                nxt = s.find(q, j + 3)
                j = (nxt + 3) if nxt != -1 else n
                continue
            q = c
            j += 1
            while j < n:
                if s[j] == '\\':
                    j += 2
                    continue
                if s[j] == q:
                    j += 1
                    break
                j += 1
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return n


def check(path):
    s = open(path, encoding='utf-8').read()
    bad = []

    def add(pos, msg):
        bad.append((s[:pos].count('\n') + 1, msg))

    for m in re.finditer(r'\.(read_text|write_text)\(', s):
        end = _balanced_end(s, m.end() - 1)
        if 'encoding' not in s[m.end():end]:
            add(m.start(), f'{m.group(1)}() 缺 encoding="utf-8"（POSIX locale 下退化成 ASCII）')

    for m in re.finditer(r'capture_output\s*=|(?<![\w.])text\s*=\s*True', s):
        add(m.start(), 'subprocess capture_output/text 是 3.7+，用 stdout=PIPE, stderr=PIPE')

    for m in re.finditer(r'->\s*[\w\[\]]+\s*\|\s*[\w\[\]]+|:\s*[\w\[\]]+\s*\|\s*None\b', s):
        add(m.start(), 'X | Y 类型注解是 3.10+，用 typing.Optional/Union')

    for m in re.finditer(r'(?<![!<>=]):=', s):
        add(m.start(), 'walrus := 是 3.8+')

    for m in re.finditer(r'f["\'][^"\']*\{[^{}]+=\}', s):
        add(m.start(), 'f-string 的 {x=} 自文档是 3.8+')

    return bad


def main(argv):
    files = argv[1:]
    if not files:
        print(__doc__)
        return 2
    total = 0
    for path in files:
        bad = check(path)
        if bad:
            print(f'!! {path}')
            for line, msg in bad:
                print(f'   L{line}: {msg}')
            total += len(bad)
        else:
            print(f'OK {path}')
    if total:
        print(f'\n共 {total} 处不兼容基准机（Ubuntu 18.04 / python3.6 / POSIX locale）')
        return 1
    print('\n全部通过基准机兼容检查')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
