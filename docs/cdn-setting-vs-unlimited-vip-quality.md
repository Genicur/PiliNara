# 报告：「开启无限试用会员画质」后 CDN 设置为什么不生效

> **结论**：
> 1. 用户看到的现象 —— **CDN 设置对播放无效 —— 是预期行为，不是 bug**。
> 2. 但原因**不是**「APP 直链签名绑定 host、换 host 必然 403」。这个说法**被实测推翻**。
> 3. 真正的原因：`getCdnUrl()` 对 `platform=android` 的直链**整类短路**（按 platform 参数判定，
>    而非按 host/节点类型判定）。其中 `mcdn`（PCDN）型确实不能换，但 `upos` 型**能换且换完 206 可用**，
>    被这条一刀切规则一起挡掉了 —— 这是**功能缺失（可以做到但没做）**，不是设计上做不到。
>
> 写于 2026-10-21，基线提交 `a02b18381`（含 CDN 测速修复）。实验脚本与原始数据见附录。

---

## 1. 机制：CDN 设置到底做了什么

CDN 设置**不是**让 B 站换节点，而是拿到播放地址后**替换 URL 的 host**：

```dart
// lib/utils/video_utils.dart:124
return uri.replace(host: defaultCDNService.host).toString();
```

路径和签名参数（`upsig` / `uparams`）原样保留。所以能否生效取决于：
**服务端签名是否接受"换过 host 的 URL"**。

---

## 2. 代码现状

`lib/utils/video_utils.dart` 的 `getCdnUrl()` 开头：

```dart
// APP 通道（platform=android）签发的直链，签名（upsig/uparams）与 host 绑定，
// 换任何 host 都会 403；且这些 PCDN/回源节点本身可用（只要请求不带 Referer）。
// 因此原样返回，不做任何 CDN 替换。
if (urls.isNotEmpty && BiliMediaHeaders.isAndroidPlatformUrl(urls.first)) {
  return urls.first;
}
```

判定条件是 **`platform` 参数以 `android` 开头**，与 host 类型、节点类型无关。
只要命中，整个替换逻辑（包括用户选择的 CDN 枚举、自定义节点）都不会执行。

---

## 3. 实测：换 host 到底会不会 403

### 3.1 三类 APP 直链，三种结果

用真实 `app_access_token` + 完整手机端 gRPC 指纹复刻 `PlayView` 请求，
对 `BV1j5nj68E48` 取得 27 条 APP 直链（`platform` 全为 `android`）：

| host 类型 | 样本 | 原样 | 只换 host | 换 host + 改 `os` |
|---|---|---|---|---|
| `*.mcdn.bilivideo.cn`（PCDN） | 18 条 | 206 | **403** | 403 |
| `*.edge.mountaintoys.cn` | 若干 | 206 | **206** | — |
| `upos-sz-*`（用户提供的 HDR 直链） | 1 条 | 206 | **206** | — |

### 3.2 决定性样本：用户提供的真实 HDR Vivid 直链

```
host      = upos-sz-302ppio.bilivideo.com
platform  = android
os        = 302ppio
gen       = playurlv3
bvc       = vod
uparams   = e,nbs,gen,os,platform,deadline,oi,og,trid,mid,uipk
文件       = 36532584643_hr1-1-100170.m4s（HDR Vivid 档位）
```

对这条 URL 做 host 替换：

| 替换目标 | 结果 |
|---|---|
| 原样（对照） | **206**，`Content-Range: bytes 0-1023/264154438` |
| → `upos-sz-mirrorcos.bilivideo.com` | **206**（真实返回内容，非重定向） |
| → `upos-sz-mirrorcoso1.bilivideo.com` | **206** |
| → `upos-sz-mirrorhw.bilivideo.com` | **206** |
| → `upos-sz-mirrorhwo1.bilivideo.com` | **206** |
| → `upos-sz-mirrorali.bilivideo.com` | **206** |

**同一条 URL，带 `platform=android`，换 host 后全部可用。**

### 3.3 `mcdn` 型为什么 403：不是"签名绑 host"

对 `mcdn` 型直链（`os=mcdn`，`uparams` 含 `os`）做三组对照：

| 操作 | 结果 |
|---|---|
| 只换 host → upos 镜像 | 403 |
| 换 host **且**把 `os=mcdn` 改成 `os=cos` | **仍然 403** |

如果 403 单纯是"签名绑 host"，那把 `os` 一起改掉应该能修复；但它依然 403。
说明 `mcdn` 型 403 另有原因（PCDN 节点路径 `/v1/resource/...` 与 upos 的
`/upgcxcode/...` 形态不同，签名覆盖了更多节点绑定的内容），
**不能用"签名绑 host"来概括整类 APP 直链。**

### 3.4 对照实验：Web 通道也分两类

同一套方法测 Web 通道（`platform=pc`）：

| host 类型 | 原样 | 换 host |
|---|---|---|
| `*.mcdn.bilivideo.cn` | 206 | **403**（7 条样本，35 次替换 0 成功） |
| `*.edge.mountaintoys.cn` | 206 | **206**（2 条样本，10 次替换 10 成功） |

**重要旁证**：`mcdn` 型直链换 host 403 这件事，**Web 通道一模一样**。
所以这不是"APP 通道特有的限制"，而是 **PCDN 节点的固有特性**。
CDN 设置从设计上就只对 `upos` / `mountaintoys` 这类节点有效。

---

## 4. 直接回答用户的问题

### Q：开启会员试用后，CDN 设置还有用吗？

**对当前的实现：没用。** 但这是**代码主动跳过**的结果，不是物理上做不到。

拆开来看是两层原因叠加：

| 层次 | 结论 |
|---|---|
| 物理层 | APP 通道直链里，`mcdn`(PCDN) 型确实换 host 会 403（Web 通道同样如此）；但 `upos` 型、`mountaintoys` 型**换 host 可用** |
| 代码层 | `getCdnUrl()` 按 `platform=android` 一刀切短路，**连能够替换的类型也一起跳过了** |

### Q：这是 bug 吗？

**严格判定：不是 bug，是功能缺失（feature gap）。**

判定依据：
- 代码有明确注释与意图，属**有意设计**，不是逻辑写错
- 短路后返回原始直链，**播放正常**（206），不会导致"看不了"
- 不存在"本应成功却报错"的运行期故障

但它有**明确的改进空间**，因为实测证明：**`upos` 型 APP 直链是可以换 CDN 的**，
而当前实现放弃了这部分能力。

---

## 5. 影响面

1. **用户感知**：开启会员试用后 CDN 设置看起来"坏了" → 正是本次疑问的由来。
2. **测速结果有误导性**：CDN 测速用的是 **Web 通道样本**（上一轮修复），
   测出的速度是"Web 通道下该 CDN 多快"，与实际播放走的 APP 通道**不是一回事**。
   测速通过 ≠ 播放会使用该 CDN。
3. **功能落差**：HDR / 4K 直链恰好常是 `upos` 型（如本例 `upos-sz-302ppio`），
   也就是**最需要 CDN 加速的高码率档位**，反而被一律跳过。

---

## 6. 建议

### 6.1 立即做（低风险）：补 UI 说明

在 CDN 设置对话框顶部条件渲染一行提示：

```dart
if (Pref.unlimitedVipQuality)
  Text('「无限试用会员画质」已开启：通过 APP 通道取流，'
       'CDN 设置对播放不生效。如需按 CDN 加速，请关闭该开关使用 Web 通道。');
```

并在测速区说明"基于 Web 通道样本，仅供参考"。
这一步能消除"设置坏了"的误解，且不碰取流逻辑。

### 6.2 建议做（中等风险，需联网测试）：按节点类型判定

把短路条件从「`platform=android`」收窄为「`platform=android` **且 host 不可替换」：

```dart
if (urls.isNotEmpty) {
  final first = urls.first;
  final host = Uri.tryParse(first)?.host ?? '';
  // 仅跳过 PCDN 节点：实测 mcdn 型换 host 必 403，upos/mountaintoys 型可换
  if (BiliMediaHeaders.isAndroidPlatformUrl(first) &&
      !_isReplaceableMediaHost(host)) {
    return first;
  }
}
```

**前提修正（重要）**：现有的 `_isReplaceableMediaHost()` 白名单里包含
`.mcdn.bilivideo.com` / `.mcdn.bilivideo.cn` / `.mcdn.bilivideo.net`，
与本次实测**冲突**（`mcdn` 是不可替换的）。必须先把这三个后缀从白名单移除，
否则放开短路后会大面积 403。

配套需要补的测试（联网，带真实 token）：
- `mcdn` 型 → 期望 403（守住不回归）
- `upos-sz-*` 型 → 期望 206
- `mountaintoys` 型 → 期望 206

### 6.3 不建议做

不要"直接把短路删掉"。`mcdn` 型在 APP 通道里占多数（本例 27 条里 18 条），
一旦全部放开，会让大部分视频从"能播"变成"403 看不了"。

---

## 7. 附录：原始实验数据

### 7.1 APP 通道 PlayView（真实 token）

```
请求 PlayView: aid=117465090622706 cid=42860284135
  HTTP 200  bytes=19569  grpc-status=0
  提取到 27 条 URL, platform 分布: {'android': 27}
  其中 mcdn 型 18 条, 其它 9 条

mcdn 型样本: host=xy119x188x217x14xy.mcdn.bilivideo.cn
  os=mcdn  uparams=e,trid,platform,deadline,uipk,gen,og,oi,mid,nbs,os
    只换 host → upos-sz-mirrorcos  403
    只换 host → upos-sz-mirrorhw   403
    换host+改os=cos                403
    换host+改os=hw                 403

mountaintoys 型样本: host=h2i438c.edge.mountaintoys.cn platform=android
    原样 + APP头(无Referer)  206
    原样 + Web头(带Referer)  403
    换 cos/coso1/hw/hwo1/ali  206 / 206 / 206 / 206 / 206（APP头）
                              403（Web头，全部）
```

### 7.2 用户提供的 upos 型 HDR 直链

```
host=upos-sz-302ppio.bilivideo.com  os=302ppio  platform=android
gen=playurlv3  bvc=vod  bw=21345813
uparams=e,nbs,gen,os,platform,deadline,oi,og,trid,mid,uipk

原样请求:
  206, Content-Range: bytes 0-1023/264154438
  跟随重定向落点: aiafgqkaks5iqgrx.nexusedgeio.com:35671

换 host（APP 头，无 Referer）:
  cos    206（真实内容，无重定向）
  coso1  206
  hw     206
  hwo1   206
  ali    206
带 Web 头（Referer）时全部 403 —— 与 §4.8「APP 直链带 Referer 即 403」一致
```

### 7.3 Web 通道对照（platform=pc）

```
mcdn(PCDN) 型：原样 7/7 可用，换 host 0/35 可用
mountaintoys 型：原样 2/2 可用，换 host 10/10 可用
```

---

## 8. 一句话总结

> 「开启会员试用后 CDN 设置无效」**是代码有意为之的行为，不是运行期 bug**；
> 但它的**判定依据不准确** —— 代码按 `platform=android` 一刀切跳过，
> 而实测显示 `upos` 型与 `mountaintoys` 型的 APP 直链**换 host 后仍是 206 可用**，
> 真正不能换的是 `mcdn`(PCDN) 型（Web 通道同样不能换）。
> 因此这是**可以改进的功能缺失**：收窄判定条件即可让高码率（HDR/4K）档位也用上 CDN 加速，
> 但必须先把 `_isReplaceableMediaHost` 白名单里的 `.mcdn.*` 移除，并补联网测试防止回归。
