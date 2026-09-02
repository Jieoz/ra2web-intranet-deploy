# ra2web-intranet-deploy

一键构建**网页版红警2的纯静态内网离线站点**。在有外网的机器上跑一次，产出的成品目录整体拷进内网，任意静态文件服务器托管即可，运行期零外网依赖。

上游游戏客户端是 [huangkaoya/redalert2](https://github.com/huangkaoya/redalert2)（RA2Web / 《时空分裂》Chronodivide 中文版客户端的 React + TypeScript + Three.js 重构版）。本仓库**只提供构建与内网化脚本**，不分发任何游戏客户端代码或美术资源。

## 两条路线

| | 现成站点包 | `build-ra2-intranet.sh` |
|---|---|---|
| 做什么 | 下载 Release 里的成品 tar.gz，解压即用 | 克隆上游 → 打补丁 → 构建 → 拉资源 |
| 依赖 | `tar` | git、python3、curl、tar（node 可选，见下） |
| 适用 | 只想部署，不关心构建 | 想自己从源码构建 |

### 路线 A：现成站点包（最省事）

Release 里的 `ra2web-intranet-site.tar.gz` 是完整成品站点（约 100MB 压缩 / 200MB 解压后），引擎资源与 62 张多人地图都已就位，解压即可托管：

```bash
tar -xzf ra2web-intranet-site.tar.gz
cd client && python3 -m http.server 8080 --bind 0.0.0.0
```

### 路线 B：从源码构建

```bash
bash build-ra2-intranet.sh [输出目录]    # 默认 ./ra2-intranet
```

**Node 版本要求**：上游用 vite 8 + rolldown，需要 `node ^20.19 || >=22.12`。脚本会自动检测：
- 系统 node 满足要求 → 直接用
- 不满足 → 自动下载便携版 Node 到 `<输出目录>/toolchain/`，只在构建期使用，不碰系统环境、不需要 root
- `RA2_FORCE_NODE=1` 可强制走便携版

便携版 Node 官方二进制需要 glibc >= 2.28（CentOS 7 / Ubuntu 18.04 等老系统不满足），脚本会自动回退到 [unofficial-builds](https://unofficial-builds.nodejs.org/) 的 glibc-2.17 变体。若两者都跑不起来，脚本会明确报错并提示改用路线 A，而不是继续往下崩。

产物结构：

```
<输出目录>/
├── toolchain/    # 便携 Node（若下载过），构建完可删
├── redalert2/    # 上游 git 克隆 + node_modules（构建中间产物，可删）
└── webroot/      # ← 这个才是要拷进内网的成品站点
```

### 只补资源

如果客户端已有（比如从 Release 拿的 `ra2web-client-dist.zip`），只想拉资源：

```bash
bash fetch-ra2-resources.sh <客户端目录>
```

`build-ra2-intranet.sh` 的资源步骤也是调用这个脚本，资源逻辑全仓库只有这一份实现。

**受限网络**：脚本走 `curl`，直接 `export https_proxy=http://host:port` 即可继承。

**断点续跑**：已下载且内容校验通过的文件跳过，中断后重跑只补缺的。

## 内网部署

```bash
cd webroot && python3 -m http.server 8080 --bind 0.0.0.0
```

玩家浏览器访问 `http://<内网IP>:8080/`，关掉 MOD 导入弹窗即进主菜单。多人对战走**主菜单 → 局域网(LAN) → 创建房间**生成邀请码，同一内网互通。

生产环境建议换 nginx / caddy，别用 `http.server`（单线程、无并发）。

## 脚本做了什么

1. **纯 CDN 模式补丁** — 上游 `VirtualFileSystem.ts` 假定用户会通过浏览器 File System Access API 授予本地 RA2 安装目录（`this.rfs`）。内网纯 CDN 模式下没有这个句柄，`this.rfs` 为 `undefined` 会抛 `TypeError`。脚本给 5 处调用加空值保护，用正则按表达式替换而非上下文 diff，因此对上游缩进变动不敏感，且幂等（重复运行会跳过）。

2. **清空所有外网引用** — `config.ini` 里的资源包下载地址、更新公告、排行榜规则、mod SDK、Discord 链接全部置空；`servers.ini` 只留一个不可用的占位 LAN 条目，摘掉官方对战服（`wolUrl` 指向 k0s.cn / wangerhuoda.cn）。全仓唯一剩余硬编码外链是 Sentry，而不配置 `[Sentry]` 段就不会加载。

3. **资源本地化** — 按官方 `manifest.json` 逐项拉取 33 个引擎资源（约 187MB）。官方 CDN 有 UA / Referer 反盗链，脚本带上对应请求头。

   `.mix` / `.mp4` 下载后比对官方 CRC32 才算通过——反盗链会返回 HTTP 200 的 HTML 伪装页，代理或网络中断会返回截断文件，两者都是「curl 退出码 0」但内容是坏的。校验不通过重试 3 次后直接退出并报明原因，绝不拿坏文件糊过去。

   **路径不是扁平的**：`manifest.json` 里 10 张阵营加载图（`ls800*.png`）的键是裸文件名，但 CDN 上它们在 `ls/` 子目录下，客户端也按 `<cdn>/ls/<name>` 请求（`LoadingScreenWrapper.tsx` 直接 `<img src>`，不走校验下载器）。按键名扁平拼 URL 会全部 404。`glsl.png` 反而在根目录。

   图片只验 PNG magic，不验 CRC：上游 manifest 对 `glsl.png` 和 `ls800russia.png` 的校验和与它自家 CDN 上的文件本来就不一致，而客户端对图片也不做校验。清单原样落盘，不重写。

4. **地图本地化** — 地图是**独立的第二套资源**，不在 `manifest.json` 里。客户端进遭遇战 / 局域网时按需去 `mapsBaseUrl` 取 `.map`，取不到就弹「下载失败，请检查网络连接」（`TXT_DOWNLOAD_FAILED`，来自游戏原版 `general.csf`，不在客户端 locale JSON 里）。

   地图清单藏在 `ini.mix` 内的 `missions.pkt`，脚本内置 MIX 解析器（复刻 `MixEntry.hashFilename` 那套大写 + 4 字节补齐的哈希规则）把它取出来，共 137 张。其中 62 张多人对战地图可从官方地图服务器拉到（约 12MB），75 张战役合作地图（`c1m1a` ~ `c5m5c`）官方已下架，全部 404 —— 不影响多人对战。

## 运行期外网依赖

零。构建完成后 `webroot/` 内所有资源路径都是站点内相对路径，断网可完整运行单人遭遇战与局域网对战。

局域网联机走上游内置的 WebRTC mesh（`src/network/lan/`），`RTCPeerConnection` 配置为 `iceServers: []`，不依赖任何 STUN / TURN 服务器，信令通过二维码或手动交换 SDP 完成——因此在完全隔离的内网里也能建立连接。

## 授权与法律

- 本仓库脚本：GPL-3.0（与上游一致）
- 上游客户端源自闭源商业产品 Chronodivide 的反编译重建，法律状态属灰色地带
- 游戏美术与音频资源版权属 EA，仅限内网自用，请勿对外提供服务或用于商业用途
- RA2Web 授权要求保留「网页红井 / RA2WEB」名称标识
