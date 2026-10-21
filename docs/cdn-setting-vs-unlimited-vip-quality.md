# 报告：开启「无限试用会员画质」后 CDN 设置是否仍然生效？

> 结论先行：**这是设计约束，不是 bug。** 但原始的「换 host 必然 403」说法**过于绝对**——
> 实测发现有一类 APP 直链是可以换 host 的，只是当前实现主动放弃了这条路。
> 也就是说：**行为符合设计，但设计本身有一处可以改进的空间。**
>
> 写于 2026-10-21。基线提交 `a02b18381`。实验脚本与原始数据见文末附录。

---

## 1. 问题

用户反馈：开启「无限试用会员画质」（R9 开关）后，在 设置 → 视频设置 → CDN 设置 里
选择任何 CDN，都不影响实际播放。

疑问：这是 bug，还是预期行为？

---

## 2. 先厘清机制：CDN 设置到底做了什么

`CDN 设置` 的实现**不是**「让 B 站给你换一个节点」，而是：

> 拿到播放地址后，**把 URL 的 host 替换成你选的镜像域名**，其它部分（路径与签名
> `upsig`/`uparams`）原封不动。

```dart
// lib/utils/video_utils.dart:124
return uri.replace(host: defaultCDNService.host).toString();
```

因此 CDN 设置能否生效，取决于一个物理条件：
**服务端签名是否绑定 host。** 绑定 → 换 host 后签名对不上 → 403；不绑定 → 换 host 可用。

---

## 3. 实测：换 host 到底会不会 403

### 3.1 实验方法

用真实账号实测（`app_access_token` + 完整的手机端 gRPC 指纹），复刻 PiliNara 的
`PlayView` 请求，拿到真实的 `DashVideo.baseUrl`，然后：

- 原样请求（对照组）
- 把 host 替换成各 `upos-sz-mirror*` 镜像
- 分别用「APP 头（无 Referer）」与「Web 头（带 Referer）」各测一遍

### 3.2 结果：两类直链，行为完全相反

对 `BV1j5nj68E48`（aid 117465090622706，cid 42860284135）取 APP 通道直链，
共 27 条 URL，`platform` 全部是 `android`：

| # | baseUrl host 类型 | 原样请求 | 换 host 后 | 换 host + Web 头 |
|---|---|---|---|---|
| 1 | `*.mcdn.bilivideo.cn`（PCDN） | **206** | **403**（cos/coso1/hw/hwo1/ali 全部） | 403 |
| 2 | `*.mcdn.bilivideo.cn`（PCDN） | **206** | **403** | 403 |
| 3 | `*.edge.mountaintoys.cn` | **206** | **206**（全部可用！） | 403 |
| 4 | `*.mcdn.bilivideo.cn`（PCDN） | **206** | **403** | 403 |

**关键发现（这是本次报告最重要的部分）：**

1. **`mcdn`（PCDN）型 APP 直链**：换任何 host 都 403 → 与文档 §4.8 的描述一致，
   「签名绑定 host」成立。
2. **`edge.mountaintoys.cn` 型 APP 直链**：换 host 后**全部 206 可用**！
   说明这类直链的签名**并不绑定 host**，理论上是可以换 CDN 的。
3. 换 host 后**必须不带 Referer**（第 3 行：APP 头 206 / Web 头 403）——
   这与文档 §4.8「APP 直链带 Referer 即 403」的结论一致。

### 3.3 对照实验：Web 通道也分两类

同一套方法测 Web 通道的直链（`platform=pc`）：

| host 类型 | 原样 | 换 host |
|---|---|---|
| `*.mcdn.bilivideo.cn`（PCDN） | 206 | **403**（全部） |
| `*.edge.mountaintoys.cn` | 206 | **206**（全部） |

**这条对照非常重要**：连 Web 通道下，`mcdn` 型直链换 host 也是 403 的。
所以「CDN 设置」这个功能**本来就不是对任何直链都有效**——它只在拿到
`upos-sz-mirror*` / `edge.mountaintoys.cn` 这类节点时才真正起作用。
（这也解释了为什么用户平时偶尔觉得 CDN 设置"有用"，偶尔觉得"没用"。）

---

## 4. 代码是怎么处理的

`lib/utils/video_utils.dart` 的 `getCdnUrl()` 开头有一段**一刀切短路**：

```dart
// APP 通道（platform=android）签发的直链，签名与 host 绑定，
// 换任何 host 都会 403；且这些 PCDN/回源节点本身可用（只要请求不带 Referer）。
// 因此原样返回，不做任何 CDN 替换。
if (urls.isNotEmpty && BiliMediaHeaders.isAndroidPlatformUrl(urls.first)) {
  return urls.first;
}
```

它的判定依据是 **`platform` 参数是否以 `android` 开头**，而不是 host 类型。

于是产生了广度问题：

- 对 `mcdn` 型 APP 直链 → 短路是**正确的**（换了确实 403）
- 对 `mountaintoys` 型 APP 直链 → 短路是**过度保守**的（实测换了 206 可用）

也就是说：**这个短路保护在语义上偏保守，把"能换的"也一起挡掉了。**

---

## 5. 回答用户的问题

### 5.1 「开启会员试用后 CDN 设置还有用吗？」

**基本没用，但原因是双重的：**

| 原因 | 说明 |
|---|---|
| ① 设计层面 | `getCdnUrl()` 对 `platform=android` 的直链**整类短路**，直接返回原始 URL，CDN 选择完全不参与 |
| ② 物理层面 | APP 通道下发的直链中，占比最大的 `mcdn`（PCDN）型**确实不能换 host**（换了 403） |

所以：**当前行为符合代码设计，不是运行时 bug**；但设计采用了"整类短路"的粗粒度策略，
把本来可以换的 `mountaintoys` 型也排除了。

### 5.2 这是 bug 吗？

**结论：属于「功能受限」，不是「功能失效」。**

严格定义上不是 bug，因为：
- 代码有明确注释，是**有意的**设计决策
- 短路后返回的原始直链**能正常播放**（206），不会让用户看不了
- 不存在"本应工作但报错"的情形

但有三点值得改进，我建议记为技术债而非立即修：

1. **判定粒度太粗**：应该按 host 类型判定（`mcdn` 短路、`mountaintoys`/`upos` 允许替换），
   而不是按 `platform` 参数一刀切。这样 `mountaintoys` 型直链也能享受 CDN 加速。
2. **UI 缺少说明**：CDN 设置页没有告诉用户"会员试用开启时此设置不生效"。
   用户会以为设置坏了 —— 这正是你产生疑问的原因。
3. **测速结果有误导性**：上一轮修好的 CDN 测速用的是 **Web 通道样本**
   （因为只有 Web 样本才能换 host 测速），所以测出的速度是"Web 通道下这条 CDN 有多快"，
   与实际播放走的 APP 通道**不是同一回事**。测速通过 ≠ 播放会用这条 CDN。

---

## 6. 建议

### 6.1 立即可做（低风险，改善认知）

在 `CDN 设置` 对话框顶部加一行说明，条件渲染：

```dart
if (Pref.unlimitedVipQuality)
  Text('「无限试用会员画质」已开启：通过 APP 通道取流，'
       '直链签名与节点绑定，CDN 设置对播放不生效。'
       '如需按 CDN 加速，请关闭该开关使用 Web 通道。');
```

同时在测速结果的说明里补一句"测速基于 Web 通道样本，仅供参考"。

### 6.2 可选优化（需要实测验证，风险中等）

把 `getCdnUrl()` 的短路条件从「`platform=android`」收窄到「`platform=android` **且** host 属于不可替换类型」：

```dart
if (urls.isNotEmpty &&
    BiliMediaHeaders.isAndroidPlatformUrl(urls.first) &&
    !_isReplaceableMediaHost(Uri.parse(urls.first).host)) {
  return urls.first;
}
```

注意：`_isReplaceableMediaHost()` 目前的白名单里包含 `.mcdn.bilivideo.*`，
而实测 `mcdn` 是**不可替换**的，白名单与实测结论有冲突，改之前必须先把白名单校正，
并补一组联网测试（`mcdn` 期望 403 / `mountaintoys` 期望 206）。

**不建议现在就改**：这块牵涉签名与节点行为，B 站随时可能调整，贸然放开会让部分用户
从"能播"变成"403 看不了"。建议先只做 6.1 的提示。

---

## 7. 附录：实验原始数据

### 7.1 APP 通道（gRPC PlayView，真实 token）

```
请求 PlayView: aid=117465090622706 cid=42860284135
  HTTP 200  bytes=19569  grpc-status=0
  提取到 27 条 URL, platform 分布: {'android': 27}

[1] host=xy116x196x147x144xy.mcdn.bilivideo.cn platform=android
    原样 + APP头(无Referer)      : 206
    原样 + Web头(带Referer)      : 206
    换cos/coso1/hw/hwo1/ali      : 403 / 403（全部）

[3] host=h2i438c.edge.mountaintoys.cn platform=android
    原样 + APP头(无Referer)      : 206
    原样 + Web头(带Referer)      : 403
    换cos    + APP头 / Web头 : 206 / 403
    换coso1  + APP头 / Web头 : 206 / 403
    换hw     + APP头 / Web头 : 206 / 403
    换hwo1   + APP头 / Web头 : 206 / 403
    换ali    + APP头 / Web头 : 206 / 403
```

### 7.2 Web 通道（对照组，platform=pc）

```
BV1j5nj68E48 q=32 host=xy116x196x147x144xy.mcdn.bilivideo.cn  kind=mcdn(PCDN)
  原样=206  cos=403  coso1=403  hw=403  hwo1=403  ali=403
... (共 7 条 mcdn 型：原样 7/7 可用，换host 0/35 可用)

BV1fK4y1t7hj q=32 host=b-baaa45l...edge.mountaintoys.cn  kind=mountaintoys
  原样=206  cos=206  coso1=206  hw=206  hwo1=206  ali=206
... (共 2 条 mountaintoys 型：原样 2/2 可用，换host 10/10 可用)

统计：
  mcdn(PCDN)     原样 7/7 可用   换host 0/35 可用
  mountaintoys   原样 2/2 可用   换host 10/10 可用
```

---

## 8. 一句话总结

> 「开启会员试用后 CDN 设置无效」**是预期行为，不是 bug**——因为 CDN 设置本质是替换 URL 的 host，
> 而 APP 通道主流的 `mcdn`（PCDN）直链签名绑定 host，换了就 403；代码因此对整类 APP 直链短路。
> 但实测显示 `edge.mountaintoys.cn` 型 APP 直链其实可以换 host（206），
> 当前实现把它也一并短路了，属于**偏保守的设计**，可记为技术债。
> 建议眼下只补 UI 提示（告知用户此设置在该开关下不生效），不要动取流逻辑。
