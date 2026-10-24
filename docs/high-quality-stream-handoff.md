# PiliNara 高画质流（4K / 1080P+ / HDR / 8K）改造 —— 交接文档

> 用途：把 2026-10-19 ~ 2026-10-20 这一轮对 PiliPlus/PiliNara 的改动，完整交接给一个**全新的对话**，
> 让它从 0 开始在你自己的 fork（<https://github.com/Genicur/PiliNara>）里重做这件事。
>
> 写于 2026-10-20 23:0x（Asia/Shanghai）。基线提交 `b908eccfbcc3930c5ead47bc728e164ff1675cf6`。

---

## ✅ 本轮执行结果（2026-10-21 01:2x 更新，第二个对话完成）

按 §7.2 顺序「重新 clone → 同步上游 → 应用补丁」执行完毕，**每一步都先编译验证再往下走**。

**最终的本地 checkout**：`probe/pilinara-work`（不再是 §7.2 说的"压扁"目录）。
`git rev-list --count HEAD` 是真实历史（6078+），基线提交仍是 `b908eccfb`。

| 步骤 | 结果 |
| --- | --- |
| 1. 重新 clone | 通过镜像 `https://ghproxy.net/https://github.com/<owner>/<repo>.git` 完成（本机直连 `github.com:443` 被 SNI 阻断，但 `api.github.com` / `codeload` 可直连；代理也不稳） |
| 2. 同步上游 | `git merge upstream/main`（上游 = `7d4202859`）。**注意：真实情况与 §7.1 不同** —— fork 的 `main` 相对合并基线只落后 29 个提交（不是 585；585 是"压扁基线"相对上游的差），因此冲突是 16 个文件 / 34 个 hunk，不是"大量冲突" |
| 3. 应用补丁 | R1+R2+R3 补丁**基本干净应用**，只有 `lib/utils/video_utils.dart` 需要手工合（上游同期也重构了该文件） |
| 4. R9 开关 | 按 §3.2 实现，4 个文件 / 约 12 行 |

**编译验证结果**：
- `flutter analyze --no-fatal-infos` → **0 error**，76 issues（全是 info/warning，与上游基线同量级；§6.1 记的 70 是旧基线，上游合并带来一些新的 info）
- `flutter test test/` → **71 passed**（`All tests passed!`）
- 未做：`flutter build windows --release`（§5.3 的 nuget.exe 已装在 `D:\Tools\NuGet`，但本轮未验证打包产物）

**R4 已按用户要求跳过**：仓库里**没有** `lib/plugin/pl_player/hdr_player_window.dart`，
`bottom_control_type.dart` 未改，`pl_player/view/view.dart` 里的 HDR 遮罩也未加。
`pl_player/controller.dart` 只保留了 §4.10 的 media header 分支（属于 R2）。

**R8（CDN 测速失效）按用户要求只记录不修** —— 见 §3.1，本轮未改动 `cdn_select_dialog.dart`。
注意：R8 的成因描述在本轮合并后**仍然成立**（`VideoHttp.videoUrl()` 现在默认走 APP 通道，
而 `CdnSpeedTester` 的 Dio 仍写死 Web 头），排查时别把 R9 开关当成原因。

**合并时真正需要人工判断的地方**（§7.2 只说了"大概率要手工调整"，这里是清单）：
1. **上游把设置页拆分了**：`extra_settings.dart` 从 1220 行砍到 605 行，弹幕/动态/评论项分别迁到
   `dm_settings.dart` / `dyn_settings.dart` / `reply_settings.dart`（新增文件）。fork 的新增设置项
   （AI 视频总结、评论区过滤入口、点击回顶刷新、显示推荐理由、双指旋转、预发布更新等）要迁进新结构，
   不能因为旧位置被删就丢掉。
2. **`findClosestTarget`**：上游把它改名成 `findTargetMedia` 且语义不同（按 id 取最接近 vs ≤目标取最大）。
   本轮**两个都保留**，fork 的全屏画质逻辑继续用 `findClosestTarget`。
3. **`getBanWordModel` → `getListBanWordModel`**：fork 用列表编辑器版本替换了上游实现，
   上游新加的 `dyn_settings` / `reply_settings` 里的调用点要改成 fork 的名字。
4. **`FontUtils`**：fork 把单字体槽位改成了多字体导入池（`customFonts` / `customFontNames` / 无 `fontFile`），
   而上游新增的 `lib/utils/config_archive.dart` 用的是旧 API。本轮按新 API 适配了导入导出。
5. **应用内 PiP**：上游把 `didPopNext` 拆成同步壳 + `_onPopNext()`，`PlayOwner.type` 改为可空。
   fork 的 `LivePipOverlayService` 恢复逻辑必须留在**同步**的 `didPopNext` 里（它依赖当帧布局量矩形），
   且 async 的 `_onPopNext()` 里不能再调 `super.didPopNext()`。
6. **media-kit 依赖**：fork 的 `pubspec.yaml` 保留指向 `Starfallan/media-kit`（fork 分支），
   上游是指 `My-Responsitories` / `bggRGjQaUbCoE`。本轮保留 fork 的选择，`pubspec.lock` 也随之保留。

**本机网络备忘（会反复踩）**：`github.com:443` 直连会被 SNI 阻断（`Connection reset` / 握手后断），
`git clone/push` 用镜像前缀可以过；`api.github.com` 与 `codeload.github.com` 可直连。
推送凭据不要写进文件，用命令行环境变量传。

---

> ### 🔴 本期范围（用户已确认，2026-10-20 23:0x 更新）
>
> | | 需求 | 说明 |
> | --- | --- | --- |
> | ✅ **做** | **R1** 高画质解析（4K/1080P+/HDR/8K）<br>**R2** CDN 请求头修复<br>**R3** 手机端扫码登录<br>**R9** 「无限试用会员画质」开关 | R1/R2/R3 互相依赖，是核心；R9 是 R1 的安全阀（新增需求，见 §3.2） |
> | ❌ **不做** | **R4 HDR 独立窗口** | 用户明确说"这个需求不需要"。`hdr_player_window.dart` **不要加** |
> | ⏸️ **只记录** | **R8 CDN 测速失效** | 用户说"你不需要定位问题，把这个问题写到文档里就好"，见 §3.1 |
> | ⭕ 按需 | R5 测试 / R6 CI / R7 打包 | 见 §3 |
>
> **最小文件集见 §7.3**（不含任何 HDR 相关改动）。

---

## 0. 先读这一节：怎么用这份文档

1. **第 2 节是结论**：为什么 PiliNara 拿不到 4K，一句话结论 + 三条硬性条件。先看它。
2. **第 3 节是需求清单（R1–R9）**，带优先级、依赖、验收标准、以及「删掉它会发生什么」。
   你说"有些需求我暂时不需要"——在这一节勾选即可，我给了一个**最小可用集**建议。
   （R8 是已知 bug 只记录；R9 是新增的「无限试用会员画质」开关。）
3. **第 4 节是实现细节**（逐模块，含代码位置和关键代码）。
4. **第 5 节是从零复现环境**（Flutter 版本、必须打的补丁、必须装的工具）。这一步最容易翻车。
5. **第 6 节是验证方法**（怎么证明真的拿到了 4K / 真的能播）。
6. **第 7 节是 fork 同步 + GitHub Actions 自动构建方案**。
7. **第 8 节是已知坑**，都是真踩过的，能省你几个小时。
8. **第 9 节是未完成事项**。
9. **第 10 节是附录导读**：完整代码拆到了另外两个文件里（见下）。

配套的三份文件：

| 文件 | 内容 |
| --- | --- |
| `docs/high-quality-stream-handoff.md` | 本文档（背景 / 需求 / 实现要点 / 坑 / 验证） |
| `docs/high-quality-stream-handoff-code.md` | 完整代码（4 个新文件全文 + 14 个文件 diff + 5 个测试文件全文） |
| `docs/high-quality-stream-handoff.patch` | 可直接 `git apply` 的补丁（已验证能干净应用） |

> ⚠️ 注意：本仓库 `.gitignore` 第 154 行是 `docs/*`，只放行了两个既有文档。
> 这三份文件需要额外加三行放行规则（见第 7.5 节），否则 `git status` 里看不见它们。

---

## 1. 背景：这个问题是怎么来的

原始问题是：

> 为什么 BBDown 能把一个 B 站视频解析到高画质（4K）直链，而 PiliNara 不行？
> 以 `https://www.bilibili.com/video/BV1j5nj68E48/` 为例。

结论是：**不是 PiliNara 的 bug，也不是 BBDown 更强**，而是两者走的**服务端通道不同**，
而 B 站对"哪条通道给多高的画质"有不同的门控规则。

### 1.1 三条播放地址通道

| 通道 | 端点 | 鉴权 | 非大会员能拿到的最高画质 |
| --- | --- | --- | --- |
| **Web** | `/x/player/wbi/playurl`（WBI 签名） | cookie（SESSDATA） | **1080P 封顶** |
| **TV** | `/x/tv/playurl` | TV access_token | 需要有效 TV token，实测账号的已失效 |
| **APP** | `bilibili.app.playurl.v1.PlayURL/PlayView`（gRPC） | 手机端 access_token | **4K / 1080P+ / HDR / 8K 全部下发** |

- BBDown 的 GUI 之所以能下 4K：它的 `BBDown.GUI.config.json` 里 `"Api": "app"`，走的就是 APP gRPC 通道。
- BBDown 的 CLI 之所以不行：`--api` 默认值是 `web`（`BBDown/Cli/CliOptions.cs:19-21`，`DefaultValueFactory = _ => ApiType.Web`）。
  加 `-a App` 且本地有 `BBDown.data`（含 `app_access_token`）就立刻出 4K。
- **PiliNara 只有 Web 通道**（`lib/http/api.dart:20` `ugcUrl = '/x/player/wbi/playurl'`），
  所以被 Web 侧的规则硬性封顶在 1080P。它的 `tvPlayUrl`（`lib/http/video.dart`）只在投屏 `onCast()` 时用一次。

### 1.2 决定性实验证据（Web 通道为什么封顶）

用你账号（mid `6891108`，LV6，**非大会员**，`vip.status = 0`，`due_date` 已过期到 2021-07）实测
`/x/player/wbi/playurl?avid=117465090622706&cid=42860284135&qn=127&fnval=4048&fnver=0&fourk=1`：

```
code: 0
quality: 80
accept_quality: [120, 112, 80, 64, 32, 16]     ← "接受"的档位里明明有 4K
dash.video 的 id: [16, 32, 64, 80]             ← 但真正下发的流只到 1080P
support_formats:
  120 "4K 超清"        limit_watch_reason: 1   ← 大会员门控
  112 "1080P 高码率"   limit_watch_reason: 1   ← 大会员门控
   80 "1080P 高清"     limit_watch_reason: 0
   64/32/16            limit_watch_reason: 0
```

也就是说 Web 端的 4K/1080P+ 是**大会员专属**，与客户端参数无关，怎么调 `qn`/`fnval` 都没用。

### 1.3 反直觉的发现：APP 通道对非大会员也发 4K

同一个账号，同一视频，改走 APP gRPC `PlayView`，返回的 `StreamInfo` 是：

```
q=120 "超清 4K"        needVip=1  needLogin=1  intact=1  codecid=12(HEVC)  bw=4389786
q=112 "高清 1080P+"    needVip=1  needLogin=1  intact=1
q=80  "高清 1080P"     needVip=0
q=64/32/16                                                  全部 intact=1
```

**`needVip=1` 只是标注，B 站依然下发了可用的 `base_url`**。实测对 4K 直链发
`Range: bytes=0-1023` → `HTTP 206`，完整下载也成功（270,619,135 B，ffprobe 确认为
`h264 4096x1740 bit_rate 10263637`）。

BBDown 的 `AppTrackReader.CollectVideoTracks` 只判断 `stream.DashVideo == null` 就跳过，
**从不检查 `needVip`**——所以它能拿到。

### 1.4 APP 通道的三个硬性条件（少一个都不给 4K）

这是最关键的实验结论，逐条都是实测出来的，不要凭直觉改：

| 条件 | 说明 | 不满足时 |
| --- | --- | --- |
| **1. 手机端 access_token** | APP key `783bbb7264451d82` 签发的 token（不是 HD 版 `dfca71928277209b`） | 匿名 → 只有 `[16, 32]` |
| **2. `mobi_app = android`** | 出现在 `x-bili-device-bin` / `x-bili-metadata-bin` 里 | 用 `android_hd` → 只到 1080P |
| **3. `build >= 6400000`** | 我们用 `7320200`，配合 `versionName = 7.32.0` | `2001100` / `4000000` / `6000000` / `6400000` 以下 → 只剩 `[16,32]` 或 `[80,64,32,16]` |

补充实测（用来减少你的试错）：

- `channel` / `brand` / `model` / `osver` **不影响结果**（保持 `master` / `android` / `android` / `15` 即可）。
  用 BBDown 的完整指纹（`xiaomi_cn_tv.danmaku.bili_zm20200902` / `M2012K11AC` / `osver 11`）结果一样。
- `fawkes` appkey 用 `android` 或 `android64` 都行，**只有 `android_hd` 会坏事**。
- UA 字符串**不影响**服务端门控（但会影响 CDN 是否 403，见 4.8）。
- 宿主 `app.bilibili.com` 还是 `grpc.biliapi.net` **不影响**。
- **HD 端 token + `android` 指纹 → 只剩 `[32, 16]`**。这是最容易踩的坑：
  拿着现成的 HD token 去试，会以为"接进去了但更差了"。

### 1.5 HDR / 8K 还需要第四个条件：编码偏好

`HDR Vivid(129)` / `HDR 真彩(125)` / `杜比视界(126)` / `8K(127)` **只以 HEVC 或 AV1 下发**。
如果 `preferCodecType` 选 AVC（`CODE264`），这些档位在响应里**只有 `StreamInfo`、没有 `DashVideo`**，
也就是说"画质列表里能看到，但没有地址"。

实测：同一个视频 `BV1beNcz2ECq`，
- 首选 AVC → 拿到的 dash 里没有 129/125/126/127
- 首选 HEVC → 拿到 `q=129 3840x2160 bw=21345708`、`q=127 7680x4320 bw=20046270`

**解决办法**：检测到有档位缺 `DashVideo` 时，**补发一次另一种编码的请求，把两次结果合并**
（见 4.5 的 `missingDashQualities` + 4.6 的合并逻辑）。这样 UI 里既能列出 HDR/8K，
又能同时保留 AVC 的常规档位。

---

## 2. 当前已完成状态（一句话总结）

在 `b908ecc` 之上，本地工作树已经实现了：

- ✅ UGC 视频通过 APP gRPC `PlayView` 解析，非大会员拿到 **4K / 1080P+ / HDR / 8K**
  （实测 4K 4096x1740、8K 7680x4320、HDR Vivid 3840x2160 都拿到了可下载直链）
- ✅ 失败自动**静默回退 Web 通道**（未登录、只有 HD token、接口异常时不会比现状更差）
- ✅ 新增**手机端扫码登录**（第 5 个 tab），用来拿能解锁 4K 的 `access_token`
- ✅ 修复 APP 直链的 **CDN 403**（Referer / UA 规则）
- ✅ 新增**HDR 独立窗口**（真 HDR 输出，因为应用内链路物理上只能 8bit）
- ✅ 单元测试 80 passed / 10 skipped（skip 的是需要环境变量的联网测试），`flutter analyze` **0 error**
- ✅ Windows Release 构建通过并部署

规模：**14 个文件修改（+656 / −6 行）+ 4 个新文件（约 635 行）**。

### 2.1 两个"隐蔽 bug"（顺便说一下，因为很容易再踩）

1. **`_saveAccount` 会把账号的 `type` 清空**
   `lib/pages/login/controller.dart` 里，同 mid 重新登录时新建的 `LoginAccount.type` 是空集，
   `onChange()` 把 `type: []` 写进 Hive → 重启后 `Accounts.refresh()` 恢复不出账号，
   表现就是**"登录莫名其妙掉了、4K 又没了"**。
   修法：先收集 `Accounts.accountMode` 里同 mid 槽位的类型集合，`account.type.addAll(types)` 再写。

2. **旧的 mpv Referer 会残留**
   `player.setMediaHeader()` 是**播放器级**状态。上一条视频是 APP 直链（空 Referer），
   切到直播/本地文件时如果不显式重设回 `BrowserUa.pc` + `https://www.bilibili.com/`，
   就会带着空 Referer 去请求需要 Referer 的地址。修法见 4.9。

---

## 3. 需求清单（请在这里勾选本期做哪些）

你说"有些需求我暂时不需要"。按模块拆分如下，每个都可独立取舍。

> 🔴 **2026-10-20 23:0x 更新（用户已确认）**：
> **R4（HDR 独立窗口）本期不做** —— 用户明确说"这个需求不需要"。
> 新对话请**跳过 R4**，不要把 `hdr_player_window.dart` 以及
> `pl_player/controller.dart` / `view.dart` / `bottom_control_type.dart` 里与之相关的改动带进去
> （§7.3 有"只做 R1+R2+R3"的最小文件集，直接按那个来）。
>
> 同时发现一个**新 bug（R8，CDN 测速失效）**，本期也**先不修，只记录**——见 §3.1。

| ID | 需求 | 优先级 | 依赖 | 工作量 | 本期做不做 |
| --- | --- | --- | --- | --- | --- |
| **R1** | 高画质解析：UGC 走 APP gRPC `PlayView`，拿到 4K/1080P+/HDR/8K | **P0** | R3 | 中 | ✅ 核心，必做 |
| **R2** | CDN 请求头修复：APP 直链不带 Referer，否则 403 | **P0** | R1 | 小 | ✅ 核心，必做（不做 R1 也没用） |
| **R3** | 手机端扫码登录，拿能解锁 4K 的 access_token | **P0** | — | 中 | ✅ 核心，必做（否则只有 1080P） |
| ~~**R4**~~ | ~~HDR 独立窗口（真 HDR 输出）~~ | — | R1 | 大 | ❌ **本期不做（用户已确认）** |
| **R5** | 测试（单元 + 联网验证） | P1 | R1/R2 | 中 | ⭕ 建议做（防止改坏） |
| **R6** | fork 同步上游 + GitHub Actions 自动构建 | P1 | — | 中 | ⭕ 你要的 |
| **R7** | 本地构建/打包/部署脚本 | P2 | — | 小 | ⭕ 按需 |
| **R8** | **CDN 测速失效（已知 bug）** | P2 | — | ? | ⏸️ **本期只记录，不修**（见 §3.1） |
| **R9** | **「无限试用会员画质」开关**：给 R1 的高画质通道加一个总开关，关掉就退回上游 Web 通道 | **P0** | R1 | 小 | ✅ **新增，要做**（见 §3.2） |

### R1. 高画质解析（P0）

- **要做什么**：新增 APP 端 gRPC `PlayView` 客户端，把返回的 protobuf 转成项目已有的 `PlayUrlModel`，
  在 `VideoHttp.videoUrl()` 的 UGC 分支里优先尝试，失败静默回退 Web。
- **为什么**：见 1.3 / 1.4。这是唯一能拿到 4K 的通道。
- **涉及文件**：`lib/grpc/url.dart`、`lib/grpc/playurl.dart`（新）、
  `lib/grpc/grpc_req.dart`、`lib/utils/accounts/grpc_headers.dart`、
  `lib/utils/accounts/account_manager/account_mgr.dart`、
  `lib/models/video/play/playview_convert.dart`（新）、`lib/http/video.dart`、`lib/common/constants.dart`
- **验收标准**：
  1. 打开一个真有 4K 的视频（如 `BV1j5nj68E48` / `BV1beNcz2ECq`），画质菜单里能看到并选中 4K；
  2. 播放不报错、进度条正常；
  3. 未登录 / 只有 HD token 时行为**不比现在差**（自动回退到 1080P）。
- **删掉的后果**：一切照旧（1080P 上限）。R2/R4 也就没意义了。

### R2. CDN 请求头修复（P0）

- **要做什么**：识别"APP 直链"（URL query 里 `platform=android*`），
  播放/下载时**不带 Referer**、且 UA 不能用桌面浏览器完整 UA。
- **为什么**：两类 CDN 节点的规则**完全相反**，搞错就 403。见 4.8。
- **涉及文件**：`lib/http/bili_media_headers.dart`（新）、
  `lib/plugin/pl_player/controller.dart`、`lib/services/download/download_manager.dart`、
  `lib/utils/video_utils.dart`、`lib/models/video/play/playview_convert.dart`（host 白名单）
- **验收标准**：4K 能播、能下载；Web 直链的视频（1080P）也照常能播。
- **删掉的后果**：R1 拿到的直链全部 403，等于白做。

### R3. 手机端扫码登录（P0）

- **要做什么**：登录页加第 5 个 tab「手机扫码」，用**手机端 appkey** 走 TV 扫码的授权流程，
  拿到 `access_token` 存到账号上，供 `PlayView` 使用。
- **为什么**：`PlayView` 要手机端 token。而且**不能用 cookie 换 token**
  （`oauth2/access_token` 用 cookie 换一律 `-400`，`refresh_token` 也已失效），
  所以只能重新扫码登录一次。
- **涉及文件**：`lib/common/constants.dart`、`lib/http/login.dart`、
  `lib/pages/login/controller.dart`、`lib/pages/login/view.dart`、
  `lib/utils/accounts/account.dart`（如果要把 token 单独存字段）
- **验收标准**：扫码成功 → 重启应用仍是登录态 → 4K 可用。
- **删掉的后果**：无法拿 token，R1 永远回退 Web，只能 1080P。
- **轻量替代方案**（如果你想砍掉这个 tab）：加一个设置项，让用户**手动粘贴**手机端 `access_token`。
  省掉整个扫码 UI，但要用户自己去抓 token。功能上等价。

### R4. ~~HDR 独立窗口~~（❌ 本期不做，用户已确认）

> **2026-10-20 23:0x 用户明确指示：「HDR 独立窗口这个需求不需要」。**
> 下面保留原设计记录仅供将来参考，**新对话不要实现它**。
> 特别提醒：`lib/plugin/pl_player/hdr_player_window.dart` **不要加入**；
> `pl_player/controller.dart`、`pl_player/view/view.dart`、
> `pl_player/models/bottom_control_type.dart` 里与 HDR 窗口相关的改动**全部跳过**
> （但 `controller.dart` 里 §4.10 的 media header 分支属于 R2，**要保留**）。

<details>
<summary>原设计（仅供将来参考，本期不实施）</summary>

- **原本要做什么**：因为 Flutter Windows 的渲染链路**物理上只能 8bit**，应用内不可能输出真 HDR。
  方案是：用同一个 libmpv 再开一个**独立的原生窗口**（`vo=gpu-next` + `gpu-context=d3d11`），
  由 mpv 自己建 10bit HDR 交换链；应用内画面盖一层黑色遮罩并显示"正在 HDR 独立窗口中播放"。
- **为什么不能直接改渲染**：整条链路都是 8bit——
  `media_kit_video/windows/angle_surface_manager.h` 是 `EGL_RED/GREEN/BLUE/ALPHA_SIZE 8`，
  `.cc:195` 是 `DXGI_FORMAT_B8G8R8A8_UNORM`，`video_output.cc:310` 是
  `kFlutterDesktopPixelFormatBGRA8888`，而 Flutter embedder 的纹理格式只有 RGBA8888/BGRA8888。
  实测显示器是 10bit（`\\.\DISPLAY1 2560x1440 @ 10 bits`），源是真 HDR10，
  但应用内只能 tone-mapping。
- **原本涉及文件**：`lib/plugin/pl_player/hdr_player_window.dart`（新，315 行）、
  `lib/plugin/pl_player/controller.dart`、`lib/plugin/pl_player/models/bottom_control_type.dart`、
  `lib/plugin/pl_player/view/view.dart`
- **原本验收标准**：点按钮 → 弹出独立窗口 → mpv 日志出现
  `Selected swapchain format R10G10B10A2_UNORM` + `RGB_FULL_G2084_NONE_P2020` → 画面明显更亮/更艳；
  关窗口 → 应用内自动接回原进度继续播。

</details>

**放弃 R4 的后果**：HDR 视频只能 tone-mapping 播放（能看，但不是真 HDR）。**R1 完全不受影响**——
4K / 1080P+ / 8K 依然是真 4K/8K 分辨率，只是 HDR 视频的色彩会被压到 SDR。

### R5. 测试（P1）

- **要做什么**：单元测试（转换逻辑、Header 规则）+ 联网验证测试（真实 token 拉 4K、验证 CDN 可下）。
- **注意**：本仓库 `.gitignore` 有 `test*.dart` 和 `test*` 规则（第 157/166 行），
  **新建的测试文件默认不会进 git**，需要单独放行或改规则。
- **验收标准**：`flutter test` 全绿；`flutter analyze` 0 error。

### R6. fork 同步 + CI（P1）

- 见第 7 节。

### R7. 本地构建/打包（P2）

- 见第 5 节。主要是 `flutter build windows --release` + 复制产物。

---

### 3.1 R8：CDN 测速失效（已知 bug，本期只记录不修）

> 用户 2026-10-20 反馈：设置 → 视频设置 → CDN 设置 里，**每一行测速都显示
> 「此视频可能无法替换为该CDN」**（见下面的复现说明）。
> 用户明确表示：**"你不需要定位问题，把这个问题写到文档里就好"**。
> 所以本节**只记录现象 + 已知线索 + 候选修法**，交给新对话决定要不要修。

#### 现象

`lib/pages/setting/widgets/cdn_select_dialog.dart` 的 `CdnSelectDialog`，
在 `Pref.cdnSpeedTest == true`（默认 true）时会调用 `_testAll()`：

1. `CdnSpeedTester.getSample()` 用 `VideoHttp.videoUrl(cid: 196018899, bvid: 'BV1fK4y1t7hj', qn: 80, videoType: .ugc)`
   拿一条样本流；
2. 对 `CDNService.values` 每个枚举调 `VideoUtils.getCdnUrl(sample.playUrls, defaultCDNService: service, applyCustomCDN: false)`；
3. 用 `CdnSpeedTester.measure(url)` 下载 2MB 或 5 秒，得到速度。

**现在每一行都显示「此视频可能无法替换为该CDN」**——这是
`_describeError()` 在 HTTP 4xx 时的固定文案：

```dart
// lib/pages/setting/widgets/cdn_select_dialog.dart:158-165
String _describeError(DioException error) {
  final statusCode = error.response?.statusCode;
  if (statusCode != null && 400 <= statusCode && statusCode < 500) {
    return '此视频可能无法替换为该CDN';   // ← 就是这句
  }
  ...
}
```

所以**不是"没测出来"，是每条测速请求都拿到了 4xx（几乎肯定是 403）**。

#### 根因（高置信度推断）

这是我们 R1+R2 引入的**回归**，不是原有 bug。链条是：

1. `VideoHttp.videoUrl()` 现在对 UGC **优先走 APP 通道**（§4.6），
   返回的 `playUrls.first` 是 **APP 直链**（`.../v1/resource/upgcxcode/...`，
   query 里 `platform=android`）。
2. `CdnSpeedTester` 自己的 `Dio` 实例带着**写死的 Web 头**：

```dart
// lib/pages/setting/widgets/cdn_select_dialog.dart:70-79
Dio get dio => _dio ??= Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    headers: {
      'user-agent': BrowserUa.pc,          // Safari 完整 UA
      'referer': HttpString.baseUrl,       // https://www.bilibili.com/
    },
  ),
);
```

3. 而 §4.8 已经实测确认：**APP 直链（`platform=android`）带 Referer 会 403**，
   且不能配桌面浏览器完整 UA。两条都踩中 ⇒ 每个 CDN 枚举测速都 403 ⇒ 全部显示
   「此视频可能无法替换为该CDN」。

**另一个必然因素**：`VideoUtils.getCdnUrl` 在 §4.8 里被改成了
**APP 直链直接短路返回、不做 host 替换**（`lib/utils/video_utils.dart:94-96`）。
所以就算测速器请求头修好了，`_testAll()` 里对每个 `CDNService` 拿到的 URL
**其实都是同一个原始 APP 直链**——测速仍然会全部显示同一个数字，
"按 CDN 枚举测速"这个功能从语义上就失效了（APP 直链的签名与 host 绑定，本来就无法换 CDN，见 §4.8）。

#### 候选修法（三选一，按推荐度排序）

**方案 A（推荐）：APP 直链时跳过 CDN 枚举测速**
既然 APP 直链无法换 CDN，这个功能对它就没意义。在 `_testAll()` 里判断
`BiliMediaHeaders.isAndroidPlatformUrl(sample.playUrls.first)`，
是的话直接给每行显示「APP 直链不支持切换 CDN」（而不是去发一堆注定 403 的请求）。
代价小、语义清晰、不会误导用户。

**方案 B：测速器改用 `BiliMediaHeaders`**
把 `CdnSpeedTester.dio` 的写死头换成
`BiliMediaHeaders.forDownload(url)`（APP 直链 → 只有 `user-agent: Mozilla/5.0`，无 Referer）。
测速能出数字了，但如上面所说，各枚举拿到的其实是同一条 URL，数字会全都一样，
**仍然是个半残功能**。

**方案 C：给 CDN 测速单独拿一条 Web 通道的样本流**
`getSample()` 里**绕开** APP 通道（比如直接调 Web `/x/player/wbi/playurl`，
或给 `videoUrl()` 加一个 `preferWeb: true` 参数）。
这样样本是 Web 直链（`platform=pc`），可以正常换 host，CDN 枚举测速语义恢复。
代价最大，但功能最完整。

> 如果决定**暂时不修**，建议至少做方案 A 的"显示提示"部分，
> 避免用户以为是自己网络/CDN 坏了。

#### 补充实测（本机无法复现出 403，仅供参考）

我用真实 token 拉了一条 APP 直链，用 Dart `Dio` 直接发请求，**两种头都返回 200**：

```
platform = android
url      = https://xy39x184x180x114xy.mcdn.bilivideo.cn:8082/v1/resource/upgcxcode/...
A. 测速器默认头(Safari UA + Referer) -> HTTP 200
B. Mozilla/5.0 无 Referer             -> HTTP 200
```

说明**具体哪类节点 403 取决于视频/节点**（§4.8 的表格里，老视频的 mcdn 节点两种头都 200，
新视频的 `edge.mountaintoys.cn` / `upos-sz-*` 才 403）。所以：
- 测试样本 `BV1fK4y1t7hj` 落在哪类节点上会直接影响复现；
- 修的时候**不要只按"加/去 Referer"来判定**，要按 `platform=android` 走 §4.8 的规则。

---

### 3.2 R9：「无限试用会员画质」开关（P0，本轮新增需求）

> 用户 2026-10-20 23:17 原话：
> **"将这种特殊获得高画质视频流的方法做一个开关名字叫做无限试用会员画质。关闭开关后依旧使用上游获取视频流的方法。"**

#### 要做什么

给 R1 的 APP `PlayView` 通道加一个**用户可见的总开关**，名字就叫
**「无限试用会员画质」**。语义：

| 开关状态 | 行为 |
| --- | --- |
| **开**（默认建议开） | `VideoHttp.videoUrl()` 的 UGC 分支优先走 APP gRPC `PlayView`（R1 现有行为），能拿 4K/1080P+/HDR/8K |
| **关** | **完全跳过** APP 通道，走上游原有的 Web `/x/player/wbi/playurl`，行为和没改过一样 |

关键要求：**关掉必须是干净地回到上游逻辑**，不能只是"失败回退"——
即关掉后**一次 PlayView 请求都不要发**（否则浪费流量、且未登录用户会触发额外错误），
`VideoUtils.getCdnUrl` 的 APP 直链短路分支也不会命中（因为拿到的本来就是 Web 直链）。

#### 为什么需要这个开关

1. **可回退**：APP 通道依赖手机端 token 和一套非公开指纹，B 站随时可能收紧。
   出问题时用户能一键回到上游行为，不用等新版本。
2. **省流量/隐私**：多一次 gRPC 请求、多走一条通道。
3. **合规边界透明**：这个通道本质是"非大会员也能拿到会员画质直链"，
   命名成「无限试用会员画质」让用户明确知道自己在用什么，而不是偷偷默认开启。
4. **便于排查**：用户报"4K 没了/画质不对"时，第一句就可以问"开关是不是关了"。

#### 实现要点（新对话照这个做）

**① 存储键** —— `lib/utils/storage_key.dart`，`SettingBoxKey` 里加：

```dart
unlimitedVipQuality = 'unlimitedVipQuality',
```

> 建议紧挨着 `cdnSpeedTest`（第 115 行附近）加，便于查找。

**② Pref 读取** —— `lib/utils/storage_pref.dart`，紧挨着 `cdnSpeedTest`（:716-717）加：

```dart
/// 「无限试用会员画质」：开启后 UGC 视频优先走 APP gRPC PlayView 通道，
/// 可拿到 4K/1080P+/HDR/8K；关闭则完全走上游 Web playurl。
static bool get unlimitedVipQuality =>
    _setting.get(SettingBoxKey.unlimitedVipQuality, defaultValue: true);
```

**③ 设置项 UI** —— `lib/pages/setting/models/video_settings.dart`，
紧挨着「CDN 测速」那个 `SwitchModel`（:73-79）加：

```dart
const SwitchModel(
  title: '无限试用会员画质',
  leading: Icon(Icons.workspace_premium_outlined),
  subtitle: '通过 APP 端接口获取 4K/1080P+/HDR/8K 视频流，'
      '非大会员账号也可使用；关闭后使用官方 Web 接口（非大会员最高 1080P）',
  setKey: SettingBoxKey.unlimitedVipQuality,
  defaultVal: true,
),
```

> **注意**：`SwitchModel` 的 `setKey` 是**必填**，`defaultVal` 要与 ② 的
> `defaultValue` 保持一致，否则开关显示状态和实际行为会对不上。
> `SwitchModel` 定义见 `lib/pages/setting/models/model.dart:183-230`。
> 如果希望开关切换后立刻生效（而不是等下一集/下次进详情页），
> 可以加 `onChanged: (v) => ...`，但通常不需要——`videoUrl()` 每次取流都会重新读 Pref。

**④ 唯一拦截点** —— `lib/http/video.dart`，`videoUrl()` 的 UGC 分支入口
（本轮实现在第 256-259 行）：

```dart
// R1：只有开关打开时才尝试 APP 通道
if (Pref.unlimitedVipQuality &&
    videoType == .ugc &&
    epid == null &&
    seasonId == null) {
  final appRes = await _videoUrlByApp(avid: avid, bvid: bvid, cid: cid);
  if (appRes != null) return appRes;
}
```

**只改这一处判断即可**，`_videoUrlByApp()` 本身不用动——
开关关掉时它根本不会被调用，自然就"干净回到上游"。

**⑤ 验证关闭后真的没走 APP 通道**

- 单元测试：`Pref` 里塞 `unlimitedVipQuality=false`，调 `videoUrl()`，
  断言返回的 `dash.video.first.playUrls.first` 里 **`platform=pc`**（Web 直链），
  且日志里没有 PlayView 请求。
- 手动验证：关开关 → 进一个 4K 视频 → 画质菜单最高只有 1080P；
  开开关 → 最高有 4K 超高清。
- 再关掉 → 重启 App → 确认开关状态被持久化（`GStorage.setting` 有写入）。

#### 涉及文件汇总

| 文件 | 改动 |
| --- | --- |
| `lib/utils/storage_key.dart` | +1 行：`unlimitedVipQuality` |
| `lib/utils/storage_pref.dart` | +2 行：`Pref.unlimitedVipQuality` |
| `lib/pages/setting/models/video_settings.dart` | +8 行：一个 `SwitchModel` |
| `lib/http/video.dart` | 改 1 个 `if` 条件（+1 行 `Pref.unlimitedVipQuality &&`） |

**工作量很小（约 12 行）**，但强烈建议做——它是 R1 的安全阀。

#### 与 R4/R8 的关系

- 与 R4（HDR 独立窗口，已砍）**无关**。
- 与 R8（CDN 测速，先不修）**无关**，但两者都会受"取流通道变了"影响，排查时容易混。

---

## 4. 实现细节（逐模块）

> 完整代码见第 10 节附录，这里讲**为什么这么写**和**关键位置**。

### 4.1 常量与 gRPC 路由

`lib/common/constants.dart` 新增：

```dart
static const phoneAppKey = '783bbb7264451d82';
static const phoneAppSec = '2653583c8873dea268ab9386918b1d65';
static const playViewMobiApp = 'android';
static const playViewBuild = 7320200;
static const playViewVersionName = '7.32.0';
```

`lib/grpc/url.dart` 新增：

```dart
static const playUrl = '/bilibili.app.playurl.v1.PlayURL';
static const playView = '$playUrl/PlayView';
```

> 注：仓库里**早就生成好了** `lib/grpc/bilibili/app/playurl/v1.pb.dart`（含 `PlayViewReq` / `PlayViewReply`），
> 但整个项目从来没引用过它（只有音频用的 `Listener/PlayURL` 走 gRPC）。
> 这次是第一次真正用上它，而且是死代码复用，不需要重新生成 protobuf。

### 4.2 `PlayView` gRPC 客户端（新文件 `lib/grpc/playurl.dart`，46 行）

单方法，请求体照 BBDown 的参数来：

```
aid / cid / qn=127 / fnver=0 / fnval=4048|16384 / download=0 /
forceHost=2 / fourk=true / spmid='main.ugc-video-detail.0.0' /
fromSpmid='main.my-history.0.0' / preferCodecType
```

`fnval = 4048 | 16384`：`4048` 是 BBDown 的 `Config.Fnval`（16 dash | 64 HDR | 128 4K |
256 杜比音 | 512 杜比视界 | 1024 8K | 2048 AV1），`16384` 是 HDR Vivid 位。

`qn=127` 是**固定请求最高档**——BBDown 注释里写了"传入 qn 反而会被服务端限流到该档"，
所以不要按用户选的画质去传，服务端会一次性把你能拿到的全给你。

`preferCodecType` 由用户偏好决定（`Pref.preferCodecs.first`）：AVC→`CODE264`，
AV1→`CODEAV1`，其余→`CODE265`。

### 4.3 请求头指纹（最关键的一步）—— `grpc_headers.dart:92`

`PlayView` 必须带**手机端指纹**，但项目全局的 gRPC 头是 HD 指纹
（`android_hd` / `2001100` / `2.0.1`），弹幕/评论/动态都靠它工作。

**决策：全局指纹一个字节都不动，只给 `PlayView` 用一套独立的头。**

新增 `GrpcHeaders.newPlayViewHeaders([String? accessKey])`，与 `newHeaders` 的差异：

| 字段 | 全局 `newHeaders`（不动） | 新的 `newPlayViewHeaders` |
| --- | --- | --- |
| `mobi_app` | `android_hd` | **`android`** |
| `build` | `2001100` | **`7320200`** |
| `versionName` | `2.0.1` | **`7.32.0`** |
| fawkes appkey | `android_hd` | **`android64`** |
| `authorization` | 有 accessKey 时 `identify_v1 <token>` | 同左 |

`x-bili-device-bin` 的 protobuf 字段号（**这个必须对，写错会 `grpc-status 2`**）：

```
1 appId=5, 2 build, 3 buvid, 4 mobiApp, 5 platform, 7 channel,
8 brand, 9 model, 10 osver, 13 versionName
```

`x-bili-metadata-bin`：`1 accessKey, 2 mobiApp, 3 platform, 4 build, 5 channel, 6 buvid, 7 platform`。

### 4.4 让请求级头能覆盖拦截器 —— `account_mgr.dart:62`

这里有个坑：`AccountManager.onRequest` 里是

```dart
options.headers.addAll(account.grpcHeaders);   // addAll 会覆盖
```

它在**拦截器**里执行，所以 `Options(headers: ...)` 传进来的头会被它盖掉。

**解决办法**：给 `GrpcReq.request` 加 `Map<String, String>? grpcHeaders` 参数，
非空时用 `Options(extra: {'grpcHeaders': grpcHeaders})` 携带；拦截器改成优先读 `extra`：

```dart
if (options.extra['grpcHeaders'] case final Map<String, String> headers) {
  options.headers.addAll(headers);
} else {
  options.headers.addAll(account.grpcHeaders);
}
```

另外 `_findAccount(path)` 对 `appBaseUrl` 开头的路径会回退到**主账号**，
所以还需要显式 `extra: {'account': Accounts.video}`，才会用「视频取流」那个账号槽位。

### 4.5 `PlayViewReply` → `PlayUrlModel`（新文件 `playview_convert.dart`，216 行）

**决策：不要手写对象，先拼一个"Web playurl 形状的 JSON"，再交给 `PlayUrlModel.fromJson`。**

理由：`Dash.fromJson` / `VideoItem.fromJson` / `AudioItem`（它**只有** `fromJson` 构造）、
`FormatItem`、`VideoQuality.fromFormat` 这些解析逻辑已经很成熟，复用比自己 new 一遍安全得多。

要点（每条都是踩过的）：

| 点 | 做法 | 原因 |
| --- | --- | --- |
| `dash.duration` | `timelength ~/ 1000`（**秒**） | Web 约定是秒；下载路径 `download.dart` 里有 `duration: dash.duration!` 强解引用 |
| 顶层 `timelength` | 毫秒 | 与 Web 一致 |
| `dash.video` 排序 | **按 id 降序** | `findAvailableVideoQuality` 用 `dash.video.first.quality.code` 当"最高画质" |
| `support_formats` | **每个有流的档位都要有**，且带 `newDesc`/`displayDesc`/`codecs` | `showSetDecodeFormats` 里是 `firstWhere(...).codecs`，缺了会抛异常；`missingVideoQualityBelowHighest` 也会抽风 |
| `bandwidth` 为 0 | `size * 8 * 1000 ~/ duration` 反推 | `size` 是字节、`duration` 是毫秒，少乘 1000 会差 1000 倍 |
| 音频项 | 必须补 `codecid`/`frameRate`/`width`/`height` | `download.dart:100-139` 里是 `audioDash.frameRate!` / `width!` / `height!` 强解引用 |
| `codecs` | `7→avc1.640033`、`12→hev1.1.6.L120.90`、`13→av01.0.08M.08`、`14→dvh1.05.06` | `VideoDecodeFormatType` 是 `startsWith` 匹配（`avc1`/`hev1`/`av01`/`dvh1`） |
| `base_url` 白名单 | 只保留 `.mcdn.bilivideo.*` / `.bilivideo.*` / `.mountaintoys.cn` | 见 4.8 |
| 多响应合并 | key = `quality * 100 + codecid` 去重 | 同一档位可能有 AVC/HEVC 两条流，都要保留（解码格式切换） |
| 缺失档位探测 | `missingDashQualities(reply)` = 有 `StreamInfo` 无 `DashVideo` | 用来触发"补发另一种编码" |

### 4.6 接进 `videoUrl()` —— `lib/http/video.dart:256` 与 `:380`

在 `videoUrl()` 函数体最开头（UGC 且无 epid/seasonId 时）先试 APP 通道：

```dart
if (videoType == .ugc && epid == null && seasonId == null) {
  final appRes = await _videoUrlByApp(avid: avid, bvid: bvid, cid: cid);
  if (appRes != null) return appRes;
}
```

`_videoUrlByApp` 里有两道**保护**，一定要保留：

1. **补发另一种编码**：`missingDashQualities` 非空 → 用 `CODE265`/`CODEAV1` 再发一次，合并两次结果。
   这样 HDR/8K 档位才出现。
2. **降级保护**：如果结果的最高画质 `< VideoQuality.high1080.code`（80），**不用它**，返回 null 回退 Web。
   因为 HD 端 token 在这条通道上只能拿到 480P/360P，接管了反而把用户从 1080P 降到 480P。

另外 `_preferCodecType` 读 `Pref.preferCodecs.first`（默认 `[AVC, AV1]` → `CODE264`）。
这意味着**默认情况下 HDR/8K 档位需要靠第 1 条的补发才出现**。

### 4.7 手机端扫码登录

- `lib/http/login.dart:62` `getPhoneCode()`：和原来的 `getHDcode()` 一样调 `Api.getTVCode`，
  但 `mobi_app: 'android'`，并且**用手机端 appkey 签名**。
- `codePoll(String authCode, {bool phone = false})`：**轮询必须用同一个 appkey 签名**，
  否则服务端不认（这是扫码流程最容易错的地方）。
- 登录页：`TabController(length: 5)`，tab 顺序 `密码 / 短信 / 扫码 / 手机扫码 / Cookie`；
  新状态 `phoneCodeInfo`、`phoneQrCodeLeftTime`、`phoneQrCodeTimer`；`refreshPhoneQRCode()`
  做 180s 倒计时 + 只在 `tabController.index == 3` 时轮询 + `86038` 视为过期。
- **`_saveAccount` 的 type 修复**见 2.1。

### 4.8 CDN 请求头规则（这条反直觉，务必看）

实测发现**两类 CDN 节点的规则完全相反**：

| 直链来源 | 典型节点 | 带 `Referer: bilibili.com` | 不带 Referer |
| --- | --- | --- | --- |
| 老视频（Web 风格） | `*.mcdn.bilivideo.cn:8082` | **206** | 206 |
| 新视频（APP 风格） | `*.edge.mountaintoys.cn:4483` / `upos-sz-*` | **403** | **200** |

UA 矩阵（q=120，无 Referer）：`Mozilla/5.0` 200、`Bilibili Freedoooooom/MarkII` 200、
`Dalvik/...` 200、`Dart/3.6 (dart:io)` 200、Safari 完整 UA 200、
**Chrome 完整 UA 403**、无 UA 403。

结论归纳成两个函数（`lib/http/bili_media_headers.dart`）：

```dart
// 判定：APP 直链 = URL query 里 platform 以 "android" 开头
static bool isAndroidPlatformUrl(String? url)

// 播放：APP 直链 → ('Mozilla/5.0', '')；Web 直链 → (BrowserUa.pc, 'https://www.bilibili.com/')
static (String userAgent, String referer) forPlayer(String url)

// 下载：APP 直链 → 只有 user-agent；Web 直链 → Freedoooooom UA + Referer
static Map<String, String> forDownload(String url)
```

BBDown 源码印证：`BBDown.Core/Util/BiliHeaders.cs:140-145` 的 `IsAndroidPlatformUrl`
（注释：「移动端下载地址带 Referer 会被拒；`platform=android_tv_yst` 也以 android 开头，一次判定即可」）、
`DownloaderAdapter.cs:126-144` 的 `DownloadHeaderHandler`。

**另外还有一处必改**：`lib/services/download/download_manager.dart:70`。
Dio 的账号拦截器里有 `options.headers..['referer'] ??= HttpString.baseUrl`，
会把 Referer 补回来。所以 APP 直链要**显式传 `'referer': ''`** 提前占位。

**还有一处**：`lib/utils/video_utils.dart:94`。`VideoUtils.getCdnUrl` 默认会把 mcdn 直链
包到 `proxy-tf-all-ws.bilivideo.com?url=...` 里、或者换成镜像 host。
对 APP 直链**不要做任何 host 改写**（改了签名就失效 → 403），直接返回 `urls.first`。
实测 `proxy-tf` 包装虽然能用（206），但没必要。

### 4.9 HDR 独立窗口（R4，可裁剪）

核心思想：**应用内 8bit 是硬约束，绕不过去，所以让 mpv 自己开窗**。
用同一个 `NativePlayer.mpv` 再 `Initializer.create(...)` 一个 handle（媒体转换功能
`mpv_convert_webp.dart` 已经这么干了，是可行模式）。

关键 mpv 选项：

```
vo=gpu-next
gpu-context=d3d11
force-window=yes
target-colorspace-hint=yes
idle=yes
keep-open=no
msg-level=all=v          ← 关键：必须在 initialize 之前就设 verbose
```

**为什么 `msg-level` 要在 init 前设**：`vo=gpu-next` + `force-window=yes` 在
`mpv_initialize` 阶段就创建窗口和交换链；如果等拿到 handle 之后再
`mpv_request_log_messages('v')`，交换链那几行日志已经发完了，收不到 → 误判成"没拿到 HDR"。
这是本次调试卡最久的一个点。

**验证手段**：日志里出现

```
Selected swapchain format R10G10B10A2_UNORM (24)
Selected swapchain color space RGB_FULL_G2084_NONE_P2020 (12)
Swapchain successfully configured to color space RGB_FULL_G2084_NONE_P2020 (12)!
```

就是真 HDR。注意这些日志**只在 verbose 级别**出现，`info` 看不到。

其它坑：
- 这个 libmpv 构建**没有编进 OSC 脚本**，`osc=yes` 会被拒（`MPV_ERROR_OPTION_NOT_FOUND = -5`），
  只能靠 `input-default-bindings` / `input-vo-keyboard`（空格/箭头/f/q）。
- `_setProperty('msg-level', level)` 的值必须是 `all=<level>` 这种带 `=` 的形式，
  裸写 `error` 会被 mpv 拒：`cplayer: Expected '=' and a value.`
- 窗口关闭的判定：监听 `MPV_EVENT_END_FILE`（reason 为 EOF/STOP）→ 通知 UI + `quit`；
  `MPV_EVENT_SHUTDOWN` → 通知 + `dispose()`。**不要在回调里重入 `mpv_terminate_destroy`**。
- 关闭后要把 `lastPosition` seek 回应用内播放器，并恢复播放。
- 应用内的黑遮罩要在 `pl_player/view/view.dart` 的 Stack 里、紧跟 `_videoWidget` 之后插入，
  且要用 `Obx` 包住（`Positioned.fill` 不能直接是 `Obx` 的返回值）。

### 4.10 另外两个必须显式重设的地方

`lib/plugin/pl_player/controller.dart:1398-1410`（`_createVideoController` 内）：

```dart
if (dataSource is NetworkSource && !isLive) {
  final (ua, referer) = BiliMediaHeaders.forPlayer(dataSource.videoSource);
  player.setMediaHeader(userAgent: ua, referer: referer);
} else {
  // 直播 / 本地文件沿用原有默认值。必须显式重设，否则会残留上一条
  // APP 直链留下的空 Referer（mpv 的 referrer 是播放器级状态）。
  player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);
}
```

`HdrPlayerWindow` 里对 **视频和音频都**要用 `forPlayer(videoUrl)` 的同一组头。
音频如果是 APP 直链同样不能带 Referer。

---

## 5. 从零复现环境（这一步最容易翻车）

### 5.1 Flutter 版本必须精确

```yaml
# pubspec.yaml
environment:
  sdk: ">=3.13.0"

# .fvmrc
{"flutter": "3.47.7"}
```

用 **Flutter 3.47.7 stable**（Dart 3.13.5）。下载：
`https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.7-stable.zip`

### 5.2 ⚠️ 必须打补丁，否则 analyze 报 121 个 error

```powershell
$env:FLUTTER_ROOT = "D:\Tools\flutter"
$env:GITHUB_WORKSPACE = "<你的仓库路径>"
pwsh -NoProfile -File lib/scripts/patch.ps1 windows
```

这个脚本会：
1. 在 Flutter SDK 里 `git apply` 约 22 个补丁（`lib/scripts/*.patch`）——
   包括 `draggable_scrollable_sheet`、`text_selection`、`scrollable`、`sliver`、`refresh_indicator` 等；
2. 删掉 pub cache 里的 `material_ui-*`，重跑 `flutter pub get`；
3. 在 `material_ui-1.6.0` 目录里 `git apply` `lib/scripts/material/*.patch`（含 `tabs.patch`）。

**不打补丁的症状**：`flutter analyze` 报
`DraggableScrollableSheetState` / `TabBarState` / `initialScrollOffset` /
`horizontalDragGestureRecognizer` 找不到，共 **121 个 error**（全是项目自己 patch 的 API）。
看起来像 SDK 版本不对，其实是补丁没打。

打完：`flutter analyze` → **0 error**，70 个 info/warning（都是原有的）。

### 5.3 ⚠️ 必须把 `nuget.exe` 放进 PATH

否则 `flutter_inappwebview_windows` 的 CMake 会报
`MSB3073 ... NUGET-NOTFOUND install Microsoft.Windows.ImplementationLibrary`。

下载 `https://dist.nuget.org/win-x86-commandline/latest/nuget.exe`，放到 PATH 里。

### 5.4 构建命令

`lib/scripts/build.ps1` 会改写 `pubspec.yaml` 的 version 并生成 `pili_release.json`，
它依赖 `$env:GITHUB_ENV`（CI 环境变量），**本地跑要手动设一个临时文件路径**。

最省事的本地构建：

```powershell
# 1) 手动生成 pili_release.json（内容按需）
'{"pili.time":1792491699,"pili.code":1,"pili.name":"2.1.6","pili.hash":"<你的 HEAD>"}' |
  Set-Content -Encoding utf8 pili_release.json

# 2) 构建
flutter build windows --release --dart-define-from-file=pili_release.json --no-pub
```

产物：`build\windows\x64\runner\Release\`（`pilinara.exe` + `data\app.so` + 各种 dll）。

### 5.5 我的环境实测值（供参考）

- Flutter `3.47.7`，revision `abaf9c5237`，Dart `3.13.5`
- VS 2022 BuildTools `17.14.42`，Windows 10 SDK `10.0.26100.0`
- `data/app.so` 约 **28,722,056 B**；打包 zip 约 **46,211,558 B**
- 构建耗时约 3–6 分钟（首次更久）

### 5.6 部署时注意

- **必须确认用户启动的是新路径**。之前出现过：新 build 部署到 `D:\Tools\PiliNara-4K`，
  但用户启动的是旧的 `D:\Tools\PiliPlus\pilinara.exe`，于是"改了还是不行"。
  交付前用进程路径核对一遍。
- 替换之前先 `Stop-Process -Name pilinara`，否则
  `rm: cannot remove '.../app_icon.ico': Device or resource busy`。

---

## 6. 验证方法

### 6.1 静态检查

```bash
export PATH="/d/Tools/flutter/bin:$PATH"
cd <repo>
flutter analyze --no-fatal-infos      # 期望：0 error
flutter test test/                    # 期望：All tests passed!（联网测试会 skip）
```

本次基线：**analyze 0 error / 70 issues**，**test 80 passed / 10 skipped**。

### 6.2 联网验证（最容易验证"真的拿到 4K"）

跑 live 测试需要环境变量 `PILINARA_LIVE_TOKEN` = 手机端 access_token：

```bash
PILINARA_LIVE_TOKEN='<token>' flutter test test/playview_live_test.dart
```

期望输出能看到 `qualities={120, 112, 80, 64, 32, 16}`，
4K 项 `4096x1740 bw=10266156 codecs=avc1.640033`。

### 6.3 手工验证清单

1. 启动应用 → 登录页第 4 个 tab「手机扫码」→ 扫码 → 登录成功；
2. 重启应用，确认**还是登录态**（这一条用来验证 2.1 的 type bug 没复发）；
3. 打开 `BV1j5nj68E48` → 画质菜单里能看到「4K 超高清」→ 选中 → 能播；
4. 打开 `BV1beNcz2ECq` → 画质菜单里能看到「HDR Vivid」/「8K 超高清」→ 能播；
5. 随便打开一个普通 1080P 视频 → 正常播放（验证回退没坏）；
6. 下载一个 4K 视频 → 不 403、能下完；
7. （如果做了 R4）HDR 视频点「HDR 独立窗口」→ 弹窗出画面 → 关窗后应用内接回。

### 6.4 判定"是不是真 4K"

```bash
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,codec_name,bit_rate -of csv=p=0 <文件>
```

4096x1740 / 7680x4320 就是真的；如果还是 1920x816 说明回退了 Web。

---

## 7. fork 同步与 CI

### 7.1 fork 现状（重要）

| 仓库 | 关系 | 状态 |
| --- | --- | --- |
| `bggRGjQaUbCoE/PiliPlus` | 源头 | `main` HEAD = `7d42028`（2026-10-20） |
| `Starfallan/PiliNara` | 你的上游 | `b908ecc`（2026-10-17），落后源头 **585** 个提交 |
| `Genicur/PiliNara` | 你的 fork | `b908ecc`，与上游同点 |

`compare/b908ecc...main` → `status: diverged`，`ahead_by: 29`，`behind_by: 585`。
**你的 fork 已经落后上游 585 个提交**，直接 merge 会有大量冲突。

### 7.2 ⚠️ 本地这份 checkout 是"压扁"的

`git rev-list --count HEAD` = **1**，`git log` 只有一条 `b908ecc`。
也就是说**本地没有真实历史**（只有那一个快照提交）。

**所以新对话不要直接在这个目录里 rebase**，会很痛苦。推荐流程：

```bash
# 1) 重新 clone 你的 fork（GitHub 上那份有真实历史）
git clone https://github.com/Genicur/PiliNara.git pilinara-work
cd pilinara-work

# 2) 加源头远程
git remote add upstream https://github.com/bggRGjQaUbCoE/PiliPlus.git
git fetch upstream

# 3) 同步上游
git merge upstream/main        # 或 git rebase upstream/main

# 4) 应用本轮的补丁（本文件同目录的 .patch）
git apply /path/to/high-quality-stream-handoff.patch
```

补丁应用后大概率需要手工调整（上游 585 个提交，`video.dart` / `login.dart` 这些热点文件肯定变了）。
**建议按 R1→R2→R3→R4 的顺序分阶段应用、分阶段编译验证**，不要一次全应用。

### 7.3 只保留高画质解析、不引入其它改动

如果只想拿 R1+R2+R3+R9，最小文件集是：

```
新增：lib/grpc/playurl.dart
      lib/http/bili_media_headers.dart
      lib/models/video/play/playview_convert.dart
修改：lib/common/constants.dart
      lib/grpc/url.dart
      lib/grpc/grpc_req.dart
      lib/utils/accounts/grpc_headers.dart
      lib/utils/accounts/account_manager/account_mgr.dart
      lib/http/video.dart
      lib/http/login.dart
      lib/pages/login/controller.dart
      lib/pages/login/view.dart
      lib/services/download/download_manager.dart
      lib/utils/video_utils.dart
      lib/plugin/pl_player/controller.dart   ← 只有 setMediaHeader 那一小段
再加（R9 开关）：lib/utils/storage_key.dart        ← +1 行
      lib/utils/storage_pref.dart       ← +2 行
      lib/pages/setting/models/video_settings.dart  ← +1 个 SwitchModel
```

`lib/plugin/pl_player/controller.dart` 可以只挑 `_createVideoController` 里的 media header 分支
（`hdrPlayerWindow` 相关的全部跳过）。

> **R9 的代码不在这份 patch 里**（本轮只写进文档，没有实装）——
> patch 里的 `videoUrl()` 是**无条件**先试 APP 通道的。如果你要 R9，
> 需要自己在 `lib/http/video.dart` 的 UGC 分支入口加 `Pref.unlimitedVipQuality &&`，
> 再补上 §3.2 列的 3 个设置相关文件。改动很小（约 12 行）。

### 7.4 GitHub Actions 自动构建

上游的 `.github/workflows/win_x64.yml` 是**现成可用的**，结构：

```
checkout(fetch-depth 0)
  → subosito/flutter-action@v2 (flutter-version-file: pubspec.yaml)
  → dart pub global activate fastforge + choco install innosetup
  → 复制 ChineseSimplified.isl
  → lib/scripts/build.ps1
  → lib/scripts/patch.ps1 windows
  → fastforge package --platform windows --targets exe
  → 整理 Release 目录
  → Compress-Archive 出 portable zip
  → softprops/action-gh-release@v3（有 tag 时）
  → actions/upload-artifact@v7（两个 artifact）
```

**注意事项**：

1. `.github/workflows/build.yml` 里各 job 的 `if` 条件带了
   `github.repository == 'Starfallan/PiliNara'` —— **在你的 fork 里不会触发**。
   要么改掉这个条件，要么直接用「Run workflow」手动跑 `win_x64.yml`。
2. `patch.ps1` 要在 CI 里 `git apply` Flutter SDK，**SDK 版本必须和 `pubspec.yaml`/
   `.fvmrc` 里的 3.47.7 完全一致**，否则补丁会失败。
3. `lib/scripts/build.ps1` 依赖 `$env:GITHUB_ENV`（CI 里自动有）。

**建议**：fork 后先不改任何代码，**先手动跑一次上游的 win_x64.yml**，
确认 CI 本身在你的 fork 上是绿的，再往里加改动。这样出问题时能分清是"CI 问题"还是"代码问题"。

### 7.5 .gitignore 需要放行的文件

```gitignore
# 第 154 行是 docs/*
docs/*
!docs/danmaku_font_scaling.md
!docs/inapp_pip_implementation.md
!docs/high-quality-stream-handoff.md         ← 新增
!docs/high-quality-stream-handoff-code.md    ← 新增
!docs/high-quality-stream-handoff.patch      ← 新增
```

测试文件同理（第 157 行 `test*.dart`、第 166 行 `test*`），要提交测试就得改这两条规则。

---

## 8. 已知坑（都真踩过）

| # | 坑 | 症状 | 解法 |
| --- | --- | --- | --- |
| 1 | 没跑 `patch.ps1` | analyze 报 121 个 error，像是 SDK 版本不对 | 跑 `patch.ps1 windows`（见 5.2） |
| 2 | 没有 `nuget.exe` | CMake `MSB3073 ... NUGET-NOTFOUND` | 装 nuget 到 PATH（见 5.3） |
| 3 | 用 HD token 试 APP 通道 | 只有 `[32,16]`，以为"接进去更差了" | 必须手机端 token（见 1.4） |
| 4 | `mobi_app=android_hd` | 只到 1080P | 必须 `android`（见 1.4） |
| 5 | `build < 6400000` | 只剩 `[16,32]` | 用 `7320200`（见 1.4） |
| 6 | AVC 偏好下 HDR/8K 没地址 | 画质列表有但点不了/加载失败 | 补发 HEVC 请求合并（见 4.5/4.6） |
| 7 | APP 直链带 Referer | 403 Forbidden | 空 Referer + 非桌面 Chrome UA（见 4.8） |
| 8 | APP 直链被改写 host | 403（签名和 host 绑定） | 不改写 host（见 4.8） |
| 9 | Dio 拦截器补 Referer | 403 | 显式传 `'referer': ''` 占位（见 4.8） |
| 10 | `msg-level` 设晚了 | 判不出 HDR，误以为失败 | init 前就设 `all=v`（见 4.9） |
| 11 | `osc=yes` | 选项被拒 `-5` | 该 libmpv 没编 OSC，别用（见 4.9） |
| 12 | `_saveAccount` 清空 type | 重启后掉登录、4K 消失 | 补齐 type 集合（见 2.1） |
| 13 | mpv Referer 残留 | 切换视频后 403 | 显式重设（见 4.10） |
| 14 | 启动了旧的 exe | "改了还是不行" | 核对进程路径（见 5.6） |
| 15 | 磁盘写满 | 所有 shell 命令 `No space left on device` | 清 `%TEMP%`（见 8.1） |

### 8.1 磁盘（顺带记一下）

调试期间 C 盘曾经被下载的 4K 测试文件写满（476G 只剩 308K），
导致所有 bash 命令都报 `No space left on device`，非常难排查。
清理 `C:\Users\<user>\AppData\Local\Temp` 即可。留至少 10G 余量。

---

## 9. 未完成 / 待办

- 🔑 **把改动推到 `Genicur/PiliNara`**：本机**没有任何 GitHub 认证**
  （无 `gh`、无 SSH key、无 `~/.git-credentials`、无 `GH_*` 环境变量），
  推送需要你提供 PAT。**需要勾哪些权限见 §9.3**（不用全勾，只勾 3 个就够）。
- ⬜ **回答 PR 2145 的参考价值**（已调研，结论见 9.1）。
- ~~HDR 独立窗口的体验打磨~~ → **R4 已取消，不做**（见 §3）。
- ⬜ **R8 CDN 测速失效**（见 §3.1）：用户指示本期只记录不修。
- ⬜ PGC / 番剧的 4K：`PlayView` 的 protobuf 里**没有 epId/seasonId 字段**（只有 aid/cid），
  所以番剧走不了这条通道，需要另外研究。
- ⬜ 解码格式切换目前只能看到 1 个 codec（每次请求只下发 preferCodecType 对应的那一组），
  已通过"补发另一种编码"部分缓解，但不是完整的双编码列表。

### 9.3 推送需要什么 GitHub Token 权限

你列出的那一大串 scope 里，**绝大多数都不需要**。按用途分三档：

#### 场景 A：只在本地把改动 push 上去（最小权限）

只需要 **1 个** scope：

| Scope | 为什么 |
| --- | --- |
| ✅ **`repo`** | 一把梭：公有+私有仓库的完整读写（含 push）。**勾这一个就够。** |

如果你**只想给公有仓库用**（`Genicur/PiliNara` 是 public），可以只勾：

| Scope | 说明 |
| --- | --- |
| ✅ **`public_repo`** | 仅公有仓库读写。权限比 `repo` 小，够 push 这个 fork。 |

> **推荐：`repo`**。因为将来你可能把仓库转私有、或推到别的私有仓库，
> `public_repo` 到时候就不够用了，还得重新建 token。

#### 场景 B：还想让新对话帮你看 CI 运行结果（可选）

在上面的基础上，**再加 1 个**：

| Scope | 为什么 |
| --- | --- |
| ⭕ **`workflow`** | 更新 `.github/workflows/*.yml`。**只有当你需要改 CI 文件时才要**——GitHub 对 workflow 文件的写入单独要求这个 scope，普通 push 不带它会被拒。 |

如果你只是想**看** Actions 运行结果（不改 workflow 文件），**`repo` 已经够了**，不用加 `workflow`。
（`repo:status` / `repo_deployment` 也属于"看状态"，同样不必单独勾——`repo` 已覆盖私有库的状态读写；
公有库的状态读取本来就是匿名可读的。）

#### 场景 C：不需要的 scope（明确别勾）

| Scope | 为什么不需要 |
| --- | --- |
| `admin:org` / `write:org` / `read:org` / `manage_runners:org` | 不操作组织 |
| `admin:org_hook` / `admin:repo_hook` / `write:repo_hook` / `read:repo_hook` | 不配 webhook |
| `admin:public_key` / `write:public_key` / `read:public_key` | 不配 SSH key |
| `admin:gpg_key*` / `admin:ssh_signing_key*` | 不签名 |
| `write:packages` / `read:packages` / `delete:packages` | 不发 npm/NuGet 包 |
| `delete_repo` | **危险**，不要让 agent 有删库能力 |
| `gist` / `notifications` / `user` / `user:email` / `user:follow` | 与改代码无关 |
| `write:discussion` / `read:discussion` / `project` / `read:project` | 不用 Discussions/Projects |
| `admin:enterprise` / `manage_runners:enterprise` / `manage_billing:*` / `read:enterprise` | 不是企业账号 |
| `scim:enterprise` / `audit_log` / `read:audit_log` | 审计相关，无关 |
| `codespace` / `codespace:secrets` | 不用 Codespaces |
| `copilot` / `manage_billing:copilot` | 不用 Copilot |
| `write:network_configurations` / `read:network_configurations` | 组织级网络配置，无关 |

#### 一句话总结

> **Fine-grained token**：选 `Genicur/PiliNara` 这一个仓库，
> 给 **Contents: Read and write**、**Metadata: Read**（自动带）、
> 如果要改 CI 再加 **Workflows: Read and write**。其余全空。
>
> **Classic token**：只勾 **`repo`**；要改 `.github/workflows/` 再加 **`workflow`**。

#### ⚠️ 安全提醒

- 这个 token 等于你的仓库写权限。**不要粘到公开的地方**（issue/PR/聊天记录）。
- 用完可以立刻在 <https://github.com/settings/tokens> 撤销。
- 建议给 token **设过期时间**（如 7 天），别选 "No expiration"。
- 如果只是想让 agent 推代码，**一个仓库级的 fine-grained token 就够**，不要用账号级 classic token。

### 9.4 新对话怎么用这个 token

不要写在任何文件里。让新对话在**命令里**用环境变量：

```bash
# 方式 1：临时环境变量（推荐，进程结束就没了）
export GH_TOKEN='ghp_xxxxxxxx'
git push https://x-access-token:$GH_TOKEN@github.com/Genicur/PiliNara.git main

# 方式 2：git credential store（会落盘，注意之后清理）
git config --local credential.helper store
# 然后 push 时输一次，token 会存进 .git-credentials（记得加进 .gitignore）
```

用完后检查一下别把 token 提交进仓库：

```bash
git log --all -p | grep -i 'ghp_\|github_pat_' && echo '⚠️ 有 token 泄漏！'
```

### 9.1 PR 2145 的参考价值（简答）

`https://github.com/bggRGjQaUbCoE/PiliPlus/pull/2145`（作者 PA733，标题 `feat: hdr`）
—— **closed 未 merge**。正文说「目前只实现了安卓平台的 HDR 支持」。

- **不能直接复用**：它是 **Android** 方案（Media3 ExoPlayer + MethodChannel + PlatformView），
  和 Windows 的独立 mpv 窗口是两套完全不同的东西。
- **可借鉴的**：它抽了一层 `abstract class PlaybackBackend`（`mediaKit` / `androidHdr` 两种实现），
  如果你以后想把"应用内播放 / HDR 独立窗口"做成可切换的抽象层，这个分层思路值得看。
  另外它的 `data_source.dart` 加了 `qualityCode`、外挂字幕解析也可以参考。

### 9.2 抓 GitHub 的小技巧（省时间）

- `web_fetch` 有时候抓不到 github.com 的 PR 页面；
  `patch-diff.githubusercontent.com` 也可能连不上（curl exit 28）。
- **能用的是**：`https://api.github.com/repos/<owner>/<repo>/pulls/<n>/files?per_page=100`，
  JSON 里每个文件的 `patch` 字段就是 diff。
- 读 JSON 时 Python 要显式 `io.open(..., encoding='utf-8')`，
  否则 Windows 默认 GBK 会 `UnicodeDecodeError`。

---

## 10. 附录

本轮的完整代码不在正文里（否则这份文档会大到没法读）。三份东西：

| 文件 | 内容 | 怎么用 |
| --- | --- | --- |
| `docs/high-quality-stream-handoff.patch` | **完整补丁**（14 个修改 + 4 个新文件 + `.gitignore` 放行规则），LF 行尾 | `git apply <patch>` |
| `docs/high-quality-stream-handoff-code.md` | 4 个新文件全文 + 14 个文件的 diff + 5 个测试文件全文 | 对照阅读 / 手工抄 |
| `docs/high-quality-stream-handoff.md` | 就是本文档（背景、需求、实现要点、坑、验证） | 先读这个 |

补丁已验证：对基线 `b908ecc` 的干净 checkout `git apply --check` 通过，
应用后与本地工作树**内容逐字节一致**（行尾差异由 `core.autocrlf=true` 自动归一）。

应用顺序建议（别一次全怼）：

```bash
# 1) 先只应用 R1+R2+R3 涉及的文件
git apply --include='lib/grpc/playurl.dart' \
          --include='lib/http/bili_media_headers.dart' \
          --include='lib/models/video/play/playview_convert.dart' \
          --include='lib/grpc/url.dart' \
          --include='lib/grpc/grpc_req.dart' \
          --include='lib/utils/accounts/*' \
          --include='lib/http/video.dart' \
          --include='lib/http/login.dart' \
          --include='lib/pages/login/*' \
          --include='lib/common/constants.dart' \
          --include='lib/services/download/download_manager.dart' \
          --include='lib/utils/video_utils.dart' \
          docs/high-quality-stream-handoff.patch

# 2) 编译验证通过后，再单独加 media header 那一段和（可选的）HDR 窗口
```

> `lib/plugin/pl_player/controller.dart` 里同时含 **R2 的 media header 分支**和
> **R4 的 HDR 窗口代码**。只想做 R2 的话，手工挑 `_createVideoController` 里那 12 行即可
> （见 4.10）；把 `hdrPlayerWindow` / `openHdrWindow` / `closeHdrWindow` 相关的全删掉。

## 11. 给你新对话的开场建议

新对话直接贴这段（把 `<...>` 换掉）：

> 读 `docs/high-quality-stream-handoff.md`（在我的 PiliNara fork 仓库里）。
> 我要从上游重新同步，然后做 **R1（高画质解析）+ R2（CDN 请求头）+ R3（手机端扫码登录）**，
> **再加 R9（「无限试用会员画质」开关）**。
> **R4（HDR 独立窗口）不做**，`hdr_player_window.dart` 不要加。
> R5/R6/R7 按需，R8（CDN 测速失效）先只记录不修。
> 按文档第 7.2 节重新 clone → 同步上游 → 应用补丁的顺序来，每步都先编译验证再往下走。

如果你只想先要最小可用（不折腾登录界面），把 R3 去掉：

> 读 `docs/high-quality-stream-handoff.md`（在我的 PiliNara fork 仓库里）。
> 先只做 **R1 + R2**，R3 登录界面暂时不动（我没手机端 token 就先别做 4K）。
> R4 不做。按第 7.2 节顺序来。

这样新对话能少走很多弯路——文档里 15 个坑已经帮你排掉了。
