# ra2web-intranet-deploy

一键构建**网页版红警2的纯静态内网离线站点**。在有外网的机器上跑一次，产出的 `webroot/` 整体拷进内网，任意静态文件服务器托管即可，运行期零外网依赖。

上游游戏客户端是 [huangkaoya/redalert2](https://github.com/huangkaoya/redalert2)（RA2Web / 《时空分裂》Chronodivide 中文版客户端的 React + TypeScript + Three.js 重构版）。本仓库**只提供构建与内网化脚本**，不分发任何游戏客户端代码或美术资源。

## 用法

```bash
bash build-ra2-intranet.sh [输出目录]    # 默认 ./ra2-intranet
```

依赖：`git`、`node >= 20`（含 npm）、`python3`、`curl`。可选 `python3-pillow`（用于生成占位加载图，缺失则跳过）。

产物结构：

```
<输出目录>/
├── redalert2/    # 上游 git 克隆 + node_modules（构建中间产物，可删）
└── webroot/      # ← 这个才是要拷进内网的成品站点
```

内网部署：

```bash
cd webroot && python3 -m http.server 8080 --bind 0.0.0.0
```

玩家浏览器访问 `http://<内网IP>:8080/`，关掉 MOD 导入弹窗即进主菜单。多人对战走**主菜单 → 局域网(LAN) → 创建房间**生成邀请码，同一内网互通。

## 脚本做了什么

七步，每步都有进度输出：

1. 准备输出目录（内部会 `cd` 进仓库，所以路径先绝对化——相对路径在这里会算错）
2. `git clone --depth 1` 上游仓库
3. **打纯 CDN 模式补丁**（见下）
4. 写入内网化的 `config.ini` / `servers.ini`：资源基址全部指向本地 `/cdn/...`，关闭 Discord、快速匹配、排位队列，开启 bot，默认中文
5. `npm ci` + `vite build`（纯 node，不需要 bun）
6. 从官方 CDN 拉取约 187MB 游戏资源，按 `manifest.json` 的 CRC32 逐文件校验，只补缺失或损坏的
7. 同步构建产物到 `webroot/`，保留已下载的 `cdn/` 资源目录

## 关于那个补丁

上游的 `VirtualFileSystem` 假定始终存在 `RealFileSystem`（本地导入的游戏文件）。纯 CDN 模式下 `this.rfs` 是 `undefined`，`getEntries()` / `openFile()` 会直接抛 `TypeError`。

补丁**不是 diff，也不贴源码当锚点** —— 那种方式对缩进、空白、行尾、git 版本都敏感，换台机器就失败。这里改成表达式级正则替换：只把类字段与构造参数改为可选，再给每处 `this.rfs.xxx()` 调用套上空值兜底，完全不看上下文和缩进。

两道自检保证它不会静默出错：

- **计数断言**：改完统计裸调用数与受保护调用数，不相等就退出报错
- **幂等检测**：开头检查是否已打过补丁，避免重复运行嵌套成 `this.rfs ? (this.rfs ? ...)`
- 若所有正则都没命中（上游源码结构变了），报 `上游源码结构已变更` 并退出，而不是继续构建出一个坏包

资源侧另有一处兜底：官方已下架若干 PNG 加载图，脚本在有 pillow 时生成中文占位图，并**全量重写 `manifest.json` 的校验和**，保证离线包自洽——否则客户端会因 CRC 不匹配反复重试下载。

## 验证过什么

- 全新空目录连跑两次：首次 `补丁应用成功（5 处 this.rfs 调用已加空值保护）`，复跑 `补丁已存在，跳过`，两次产物一致且源码无嵌套
- 33 项资源 CRC 全部校验通过
- 产物起本地服务后用浏览器实测：`manifest.json`、`ini.mix`、`ui.mix`、`strings.mix` 全部 200，无 `getEntries` 崩溃，引擎推进到渲染器阶段

headless 无 GPU 时会卡在 WebGL 初始化，真机浏览器无此问题。

## 免责声明与授权

上游项目基于对 RA2Web / 《时空分裂》(Chronodivide) 中文版的分析开发，**项目全部权利（含收益权）归《时空分裂》/ RA2WEB 负责人所有**。《时空分裂》所有者从未以任何形式开源游戏客户端代码。

未经权利人许可，**严禁任何商业用途**，包括但不限于植入广告、封装收费、以"作者"身份骗取赞助或充电收益。原作者：Alexandru Ciucă / RA2WEB。

本仓库仅含构建脚本，不含也不分发游戏客户端代码与美术资源；脚本运行时从上游仓库与官方 CDN 获取。脚本本身以 GPL-3.0 授权（与上游一致）。
