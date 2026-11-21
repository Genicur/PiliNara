import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';

/// PCDN 直链的「先探测、失败回退」解析。
///
/// ## 背景
///
/// APP 通道下发的 dash 直链常带 PCDN 节点，形如
/// `xy36x250x117x146xy.mcdn.bilivideo.cn:8082`。这类直链的 `uparams`
/// 里含 `os=mcdn`，签名与节点**绑定** —— 直接把 host 换成 upos 镜像会 403。
///
/// 实测（2026-11-15，多视频 / 多节点，逐条验证）：
/// ```
/// 原样 mcdn                    → 206
/// → coso1 / cos / 08c / 08h / hw / ali  → 403（换任何 host 都失败）
/// ```
///
/// BBDown 的做法（`DownloadUtil.ResolveReplacedUrlAsync`）是：先用替换后的
/// 地址发 `Range: 0-0` 轻量探测，命中失败再回退原始直链。播放器没有这种
/// 机制，URL 一旦 403 就是黑屏，所以这里在交给播放器之前先自己做一次。
///
/// ## 策略
///
/// 1. 用户没选任何 CDN（基础 URL）→ 直接返回原地址，不发请求，零开销。
/// 2. 用户选了 CDN（预设服务或自定义节点）→ 用它构造候选地址并探测：
///    - 通过 → 用候选（走用户选择的节点）
///    - 失败 → 回退原始直链（保证能播）
///
/// 探测实测耗时约 0.15s，失败有超时兜底，不会拖慢正常播放。
abstract final class CdnProbe {
  /// 探测超时：CDN 对不存在的对象会立刻返回，超时只用于兜住网络异常。
  static const Duration timeout = Duration(seconds: 4);

  /// 当前设置下用户期望的 CDN host；返回 null 表示「基础 URL / 不替换」。
  ///
  /// 与 [VideoUtils.getCdnUrl] 的取值口径保持一致：
  /// 自定义节点优先，其次是 CDNService 预设。
  static String? get preferredHost {
    final custom = VideoUtils.customCDNUrl;
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    final service = VideoUtils.cdnService;
    final host = service.host;
    if (host == null || host.isEmpty) {
      return null;
    }
    if (service == CDNService.baseUrl || service == CDNService.backupUrl) {
      // 这两种语义是「不换 host」，交给原逻辑按多地址挑选，探测无意义
      return null;
    }
    return host;
  }

  /// 给 [url] 挑一个可用地址。
  ///
  /// 返回 null 表示 [url] 本身为空。
  static Future<String?> resolve(
    String? url, {
    String? host,
    bool preferUserCdn = true,
  }) async {
    if (url == null || url.isEmpty) {
      return null;
    }
    if (!preferUserCdn) {
      return url;
    }
    final target = host ?? preferredHost;
    if (target == null || target.isEmpty) {
      return url;
    }
    final candidate = VideoUtils.hostReplaced(url, target);
    if (candidate == null || candidate == url) {
      return url;
    }
    final ok = await isReachable(candidate);
    return ok ? candidate : url;
  }

  /// 批量版本：为音视频两条流同时挑地址。
  ///
  /// 两者互不依赖，并发探测；任意一条失败只影响它自己。
  static Future<({String? video, String? audio})> resolvePair({
    String? videoUrl,
    String? audioUrl,
    String? host,
    bool preferUserCdn = true,
  }) async {
    final results = await Future.wait([
      resolve(videoUrl, host: host, preferUserCdn: preferUserCdn),
      resolve(audioUrl, host: host, preferUserCdn: preferUserCdn),
    ]);
    return (video: results[0], audio: results[1]);
  }

  /// 对 [url] 发一次 `Range: bytes=0-0` 探测，返回是否可用。
  ///
  /// 只有 2xx 视为可用；403/404/其他状态码与网络异常一律视为不可用。
  /// 用 Range 探测是为了让 CDN 只回一个字节，几乎不产生流量。
  static Future<bool> isReachable(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return false;
    }
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = timeout
        ..idleTimeout = timeout;
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      // APP 直链的协议要求：UA 必须是 Mozilla/5.0 且不带 Referer
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      final response = await request.close().timeout(timeout);
      // 必须把响应体读掉，否则连接会一直挂着
      await response.drain<void>().timeout(timeout);
      final code = response.statusCode;
      return code >= 200 && code < 300;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// 并发探测多个候选地址，返回第一个可用的。
  ///
  /// 全部失败时返回 [urls] 的第一项：保持原有行为，让播放器自己报错，
  /// 而不是返回 null 变成「无可用地址」。
  static Future<String?> firstReachable(List<String> urls) async {
    if (urls.isEmpty) {
      return null;
    }
    if (urls.length == 1) {
      return urls.first;
    }
    final results = await Future.wait(urls.map(isReachable));
    for (var i = 0; i < results.length; i++) {
      if (results[i]) {
        return urls[i];
      }
    }
    return urls.first;
  }

  /// 当前设置下是否值得做探测（用户确实指定了要用的节点）。
  static bool get shouldProbe => preferredHost != null;
}

