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
    if (_hasAndroidDirectLink(url)) {
      return (appUserAgent, '');
    }
    return (BrowserUa.pc, 'https://www.bilibili.com/');
  }

  /// 判断媒体源里是否含 APP 通道直链（`platform=android`）。
  ///
  /// 视频 + 音频会被拼成 **mpv EDL 字符串**再交给播放器，形如：
  /// ```
  /// edl://!no_chapters;%650%https://xxx/upgcxcode/...?platform=android;!new_stream;...
  /// ```
  /// 这时直接对整串调用 [Uri.tryParse] 拿不到 query，`platform` 判定会失效，
  /// 于是错用 Web 头（Chrome UA + Referer）→ APP 直链 403 → 黑屏。
  /// 因此先把 EDL 内嵌的 URL 拆出来，只要其中有 APP 直链就走 APP 头。
  static bool _hasAndroidDirectLink(String url) {
    if (isAndroidPlatformUrl(url)) return true;
    if (!url.startsWith('edl://')) return false;
    for (final m in _edlUrlPattern.allMatches(url)) {
      if (isAndroidPlatformUrl(m.group(0))) return true;
    }
    return false;
  }

  /// 匹配 EDL 里内嵌的 http(s) 地址（遇到 `;` 或空白即止）。
  static final RegExp _edlUrlPattern = RegExp(r'https?://[^\s;]+');

  /// 下载器用：按直链来源返回附加请求头。
  /// APP 端直链只给 UA，不给 Referer。
  static Map<String, String> forDownload(String url) {
    if (_hasAndroidDirectLink(url)) {
      return {'user-agent': appUserAgent};
    }
    return {
      'user-agent': 'Bilibili Freedoooooom/MarkII',
      'referer': 'https://www.bilibili.com/',
    };
  }
}
