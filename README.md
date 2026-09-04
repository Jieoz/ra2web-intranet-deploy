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

玩家浏览器访问 `http://<内网IP>:8080/`，关掉 MOD 导入弹窗即进主菜单。

生产环境建议换 nginx / caddy，别用 `http.server`（单线程、无并发）。

### 多人对战：需要一个内网 STUN

主菜单 → **局域网联机** → 创建房间，把邀请码（二维码或文本）给对方即可。信令
不经服务器，靠玩家自己传递。

**但只做到这一步，跨机器多半连不上。** 现代浏览器默认用 mDNS 假名
（`<uuid>.local`）替代真实内网 IP 上报 ICE host candidate，实测一台机器采集到的
候选只有一条：

```
a=candidate:... 09cd5807-...-9407d07729a1.local 51158 typ host
```

对端要解析这个名字得靠 mDNS 广播（UDP 5353），交换机 / AP 的客户端隔离经常把它
丢掉。表现是**同一台机器开两个标签页能连，两台机器连不上**。上游客户端自己的
`SdpCandidateDiagnostics.ts` 就为这个组合准备了警告文案，原话是「跨机器局域网很
容易因为 mDNS/UDP 被拦而失败」。

浏览器**拿不到自己的内网 IP**，这是刻意的防指纹设计，JS 层没有任何 API 能读到本机
可路由地址。要知道自己的地址，唯一办法是问一个外部反射点「你看到我从哪来」——
这就是 STUN 的全部作用，省不掉。它回报的 srflx 候选内容正是你的真实内网 IP:端口，
直连即可成立，且请求只发到你自己的内网地址，不出网。

仓库自带 `ministun.py`（纯标准库，约 90 行，只实现 STUN Binding，不做 TURN 中继）。
**在托管站点的那台机器上跑起来就行，不用配地址**：

```bash
python3 ministun.py 0.0.0.0 3478
```

客户端按站点地址自动推导 `stun:<本站hostname>:3478` —— STUN 与站点同机，而浏览器
本来就知道站点地址，没有需要人填的信息。启动时会探测 1.5 秒确认真能拿到 srflx
候选，拿到才启用。

> STUN Binding 协议本身不带认证，任何人发请求都会得到回应。这个端口只放在可信
> 内网，**别把 3478/udp 映射到公网** —— 源 IP 可伪造，公网开放 STUN 会被当作 UDP
> 反射放大源。能指定内网网卡地址就别用 `0.0.0.0`。

`config.ini` 里的 `lanStunUrl` 只在偏离默认时才需要动：

```ini
lanStunUrl=                        # 留空（默认）= 自动推导 + 探测
lanStunUrl=off                     # 强制不用 STUN
lanStunUrl=stun:192.168.1.10:3478  # STUN 在另一台机器，或换了端口
```

改完刷新页面即可，**不用重新构建**。

为什么要探测而不是直接用推导值：不可达的 STUN 会让 ICE 采集拖到约 40 秒才结束，
而上游 `waitForIceGatheringComplete` 的超时是 10 秒（`ICE_GATHER_TIMEOUT_MILLIS`），
超时直接抛「ICE 候选收集超时，请稍后重试」。天真的自动填值会把「没装 STUN 至少
还能同机联机」变成「等 10 秒然后硬报错」，那是回归。探测失败就退回空列表，行为与
上游完全一致。

三种情形的实测结果：

| 情形 | `__ra2LanIceServers` | ICE 采集 | 候选 |
|---|---|---|---|
| STUN 在跑（自动推导命中） | `[{urls:"stun:…:3478"}]` | 115ms | host + **srflx** |
| STUN 没跑（探测失败退回） | `[]` | 124ms | 仅 host |
| `lanStunUrl=off` | `[]` | 118ms | 仅 host |

两种没有 STUN 的情形都远低于 10 秒超时，即未启用 STUN 时无任何行为变化。

跨机器可行性用双 peer 实测过：两个独立浏览器 context，信令层剔除所有 host 候选
（模拟对端无法解析 `.local`），仅凭 srflx 候选在 2.5 秒内完成双向 DataChannel
通信。反过来把 STUN 停掉，同一测试 30 秒都建不起连接。

若内网禁 UDP 3478，换端口时两边都要改（`ministun.py 0.0.0.0 19302` +
`lanStunUrl=stun:<IP>:19302`）。

> 另外：本项目**不生成 `servers.ini`**。那是官方战网登录（`LoginScreen` /
> `WolService`）读的服务器列表，局域网对战走 WebRTC，完全不碰它。早期版本这里
> 写过一份带 `wolUrl` / `apiRegUrl` 的占位文件，实测其中每个键在客户端里都没有
> 任何读取方，纯属摆设，已删除。

## 脚本做了什么

1. **纯 CDN 模式补丁** — 上游 `VirtualFileSystem.ts` 假定用户会通过浏览器 File System Access API 授予本地 RA2 安装目录（`this.rfs`）。内网纯 CDN 模式下没有这个句柄，`this.rfs` 为 `undefined` 会抛 `TypeError`。脚本给 5 处调用加空值保护，用正则按表达式替换而非上下文 diff，因此对上游缩进变动不敏感，且幂等（重复运行会跳过）。

2. **清空所有外网引用** — `config.ini` 里的资源包下载地址、更新公告、排行榜规则、mod SDK、Discord 链接全部置空；`mods.ini` 的远端 MOD 清单清空（上游那份的 Download / Website 全指向 k0s.cn 等外网）。全仓唯一剩余硬编码外链是 Sentry，而不配置 `[Sentry]` 段就不会加载。官方对战服不需要专门摘除——局域网对战走 WebRTC，客户端这个版本压根不读服务器列表（见上文 `servers.ini` 注）。

3. **局域网 ICE 自动化** — 上游两处 `RTCPeerConnection` 把 `iceServers` 写死成 `[]`，跨机器对战因此拿不到可路由候选。补丁给 `Config.ts` 加 `lanStunUrl` getter，生成 `src/ra2LanIce.ts` 负责按 `location.hostname` 推导 STUN 地址、探测可用性并发布到 `globalThis.__ra2LanIceServers`，`Application.ts` 在 config 加载完成后调用它，两处构造点改读该全局值。**默认无需配置**：STUN 与站点同机，地址可推导；探测失败则退回 `[]`，行为与上游完全一致。附带生成 `src/ra2-lan-ice.d.ts` 声明该全局，避免 `tsc` 报错。

4. **静态资源修复** — `main-legacy.css` 里 `url(res/img/...)` 是相对路径，而 CSS 自己在 `/css/` 下，浏览器解析成 `/css/res/img/...` 全部 404，改为绝对路径；同一份 CSS 引用的 `cd-logo.png` 上游 `public/res/img/` 里根本不存在（只有 `download-arrow` / `drag-*`），去掉那条 `background` 简写里的 `url()`；`index.html` 的 favicon 指向 Vite 模板残留的 `/vite.svg`，换成内联 `data:` URI —— 单纯删掉 `<link>` 是不够的，那样浏览器会自己去请求 `/favicon.ico`，日志里照样一条 404。

5. **资源本地化** — 按官方 `manifest.json` 逐项拉取 33 个引擎资源（约 187MB）。官方 CDN 有 UA / Referer 反盗链，脚本带上对应请求头。

   `.mix` / `.mp4` 下载后比对官方 CRC32 才算通过——反盗链会返回 HTTP 200 的 HTML 伪装页，代理或网络中断会返回截断文件，两者都是「curl 退出码 0」但内容是坏的。校验不通过重试 3 次后直接退出并报明原因，绝不拿坏文件糊过去。

   **路径不是扁平的**：`manifest.json` 里 10 张阵营加载图（`ls800*.png`）的键是裸文件名，但 CDN 上它们在 `ls/` 子目录下，客户端也按 `<cdn>/ls/<name>` 请求（`LoadingScreenWrapper.tsx` 直接 `<img src>`，不走校验下载器）。按键名扁平拼 URL 会全部 404。`glsl.png` 反而在根目录。

   图片只验 PNG magic，不验 CRC：上游 manifest 对 `glsl.png` 和 `ls800russia.png` 的校验和与它自家 CDN 上的文件本来就不一致，而客户端对图片也不做校验。清单原样落盘，不重写。

6. **地图本地化** — 地图是**独立的第二套资源**，不在 `manifest.json` 里。客户端进遭遇战 / 局域网时按需去 `mapsBaseUrl` 取 `.map`，取不到就弹「下载失败，请检查网络连接」（`TXT_DOWNLOAD_FAILED`，来自游戏原版 `general.csf`，不在客户端 locale JSON 里）。

   地图清单藏在 `ini.mix` 内的 `missions.pkt`，脚本内置 MIX 解析器（复刻 `MixEntry.hashFilename` 那套大写 + 4 字节补齐的哈希规则）把它取出来，共 137 张。其中 62 张多人对战地图可从官方地图服务器拉到（约 12MB），75 张战役合作地图（`c1m1a` ~ `c5m5c`）官方已下架，全部 404 —— 不影响多人对战。

## 运行期外网依赖

零。构建完成后 `webroot/` 内所有资源路径都是站点内相对路径，断网可完整运行单人遭遇战与局域网对战。

局域网联机走上游内置的 WebRTC mesh（`src/network/lan/`），信令通过二维码或手动交换 SDP 完成，不需要信令服务器。`iceServers` 默认为空（保持上游行为），可通过 `config.ini` 的 `lanStunUrl` 指向**内网自建**的 STUN —— 见上文「多人对战」一节，那是跨机器对战能否成立的关键，且该 STUN 同样在内网，不构成外网依赖。

## 授权与法律

- 本仓库脚本：GPL-3.0（与上游一致）
- 上游客户端源自闭源商业产品 Chronodivide 的反编译重建，法律状态属灰色地带
- 游戏美术与音频资源版权属 EA，仅限内网自用，请勿对外提供服务或用于商业用途
- RA2Web 授权要求保留「网页红井 / RA2WEB」名称标识
