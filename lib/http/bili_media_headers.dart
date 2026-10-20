import 'package:PiliPlus/http/browser_ua.dart';

/// B 站 CDN 对「APP 端签发的直链」与「Web 端签发的直链」要求的请求头是相反的，
/// 这里集中判定并给出正确的请求头。
///
/// 实测结论（BV1MunP6LEMs 拿不到 4K 的根因）：
/// * Web 通道（query 里 `platform=pc`）签发的直链：**必须**带
///   `Referer: https://www.bilibili.com/`，否则 403。
/// * APP 通道（query 里 `platform=android`）签发的直链：**必须不带 Referer**
///   （带了一律 403），且 `User-Agent` 不能是完整的桌面浏览器 UA
///   （Chrome/Firefox 完整 UA 会被拒；`Mozilla/5.0`、移动端 UA、Safari UA、
///   `Dart/x (dart:io)` 都可用）。
///
/// 这就是为什么有的视频能放（直链落在 `*.mcdn.bilivideo.cn:8082`，两种头都收），
/// 有的放不了（直链落在 `upos-sz-mirror*` / `*.edge.mountaintoys.cn`，带 Referer 即 403）。
abstract final class BiliMediaHeaders {
  /// APP 端直链（`platform` 以 `android` 开头，含 `android_tv_yst`）。
  /// 与 BBDown `BiliHeaders.IsAndroidPlatformUrl` 的判定保持一致。
  static bool isAndroidPlatformUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return false;
    }
    if (!uri.hasScheme) return false;
    final platform = uri.queryParameters['platform'];
    return platform != null && platform.startsWith('android');
  }

  /// APP 端直链可用的 UA：不能是完整桌面浏览器 UA。
  ///
  /// 与 BBDown `DownloaderAdapter.DownloadHeaderHandler` 保持一致（它固定发
  /// `Mozilla/5.0`，注释说明「缺 UA 的请求会被 B 站 CDN 直接 403 拒绝」）。
  static const String appUserAgent = 'Mozilla/5.0';

  /// 播放器（mpv）用：按直链来源返回 `(userAgent, referer)`。
  /// APP 端直链返回空 referer（mpv 会把 `referrer` 属性置空，从而不发 Referer）。
  static (String userAgent, String referer) forPlayer(String url) {
    if (isAndroidPlatformUrl(url)) {
      return (appUserAgent, '');
    }
    return (BrowserUa.pc, 'https://www.bilibili.com/');
  }

  /// 下载器用：按直链来源返回附加请求头。
  /// APP 端直链只给 UA，不给 Referer。
  static Map<String, String> forDownload(String url) {
    if (isAndroidPlatformUrl(url)) {
      return {'user-agent': appUserAgent};
    }
    return {
      'user-agent': 'Bilibili Freedoooooom/MarkII',
      'referer': 'https://www.bilibili.com/',
    };
  }
}
