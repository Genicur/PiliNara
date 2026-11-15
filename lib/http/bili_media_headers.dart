import 'package:PiliPlus/http/browser_ua.dart';

/// B 站 CDN 对「APP 端签发」与「Web 端签发」的直链要求的请求头是相反的。
///
/// 实测（2026-11-15，用 ReVanced APP 里复制的真实串流地址逐条验证）：
///
/// | 直链来源 | UA | Referer |
/// | --- | --- | --- |
/// | Web（`platform=pc`） | 桌面浏览器 UA | **必须**带 `https://www.bilibili.com/` |
/// | APP（`platform=android`） | `Mozilla/5.0` | **必须不带**（带了必 403） |
///
/// 同一份 4K 直链的实测结果：
/// * `Mozilla/5.0` + 无 Referer → **206**
/// * 完整 Chrome UA（有无 Referer 都一样）→ **403**
/// * `Mozilla/5.0` + Referer → **403**
///
/// 播放器的 UA / Referer 是**播放器级**状态，只能设一组；所以音视频必须来自
/// 同一通道，否则必有一边 403（表现为黑屏 / 无声）。
abstract final class BiliMediaHeaders {
  /// APP 端直链可用的 UA：不能是完整桌面浏览器 UA。
  static const String appUserAgent = 'Mozilla/5.0';

  /// APP 端直链判定：query 里 `platform` 以 `android` 开头。
  static bool isAndroidPlatformUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return false;
    final platform = uri.queryParameters['platform'];
    return platform != null && platform.startsWith('android');
  }

  /// 判断媒体源里是否含 APP 通道直链。
  ///
  /// 视频 + 音频会被拼成 **mpv EDL 字符串**再交给播放器：
  /// `edl://!no_chapters;%650%https://...?platform=android;!new_stream;...`
  /// 这时对整串 `Uri.tryParse` 拿不到 query，必须先把内嵌 URL 拆出来。
  static bool hasAndroidDirectLink(String url) {
    if (isAndroidPlatformUrl(url)) return true;
    if (!url.startsWith('edl://')) return false;
    for (final m in _edlUrlPattern.allMatches(url)) {
      if (isAndroidPlatformUrl(m.group(0))) return true;
    }
    return false;
  }

  static final RegExp _edlUrlPattern = RegExp(r'https?://[^\s;]+');

  /// 播放器用：按直链来源返回 `(userAgent, referer)`。
  /// APP 端直链返回空 referer（mpv 会把 referrer 置空，从而不发 Referer）。
  static (String userAgent, String referer) forPlayer(String url) {
    if (hasAndroidDirectLink(url)) {
      return (appUserAgent, '');
    }
    return (BrowserUa.pc, 'https://www.bilibili.com/');
  }

  /// 下载器用：APP 端直链只给 UA，不给 Referer。
  static Map<String, String> forDownload(String url) {
    if (hasAndroidDirectLink(url)) {
      return {'user-agent': appUserAgent};
    }
    return {
      'user-agent': 'Bilibili Freedoooooom/MarkII',
      'referer': 'https://www.bilibili.com/',
    };
  }
}
