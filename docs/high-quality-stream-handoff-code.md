# 高画质流改造 —— 完整代码附档

> 配套主文档：`docs/high-quality-stream-handoff.md`。

> 这里只是完整源码清单（方便对照阅读 / 手工抄写）。
> 要直接应用请用 `docs/high-quality-stream-handoff.patch`。

## A. 新增文件

### `lib/grpc/playurl.dart`

```dart
import 'package:PiliPlus/grpc/bilibili/app/playurl/v1.pb.dart';
import 'package:PiliPlus/grpc/grpc_req.dart';
import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/utils/accounts/grpc_headers.dart';
import 'package:fixnum/fixnum.dart';

abstract final class PlayUrlGrpc {
  /// APP 端视频取流（`bilibili.app.playurl.v1.PlayURL/PlayView`）。
  ///
  /// 相比 Web 的 `/x/player/wbi/playurl`，该接口对非大会员账号也会下发
  /// 4K/1080P+ 的 dash 流（StreamInfo.needVip 为 true 但 intact 为 true，
  /// 直链可正常下载）。前提：
  /// 1. [accessKey] 必须是**手机端**签发的 token（HD 端 token 无效）；
  /// 2. 指纹必须是手机端 `mobi_app=android` + `build>=6400000`
  ///    （见 [GrpcHeaders.newPlayViewHeaders]）。
  static Future<LoadingState<PlayViewReply>> playView({
    required int aid,
    required int cid,
    int qn = 127,
    int fnval = 4048 | 16384,
    CodeType preferCodecType = CodeType.CODE265,
    String spmid = 'main.ugc-video-detail.0.0',
    String fromSpmid = 'main.my-history.0.0',
    String? accessKey,
  }) {
    return GrpcReq.request(
      GrpcUrl.playView,
      PlayViewReq(
        aid: Int64(aid),
        cid: Int64(cid),
        qn: Int64(qn),
        fnver: 0,
        fnval: fnval,
        download: 0,
        forceHost: 2,
        fourk: true,
        spmid: spmid,
        fromSpmid: fromSpmid,
        preferCodecType: preferCodecType,
      ),
      PlayViewReply.fromBuffer,
      grpcHeaders: GrpcHeaders.newPlayViewHeaders(accessKey),
    );
  }
}
```

### `lib/http/bili_media_headers.dart`

APP 直链判定 / 播放下载请求头

```dart
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
```

### `lib/models/video/play/playview_convert.dart`

PlayViewReply → PlayUrlModel

```dart
import 'package:PiliPlus/grpc/bilibili/app/playurl/v1.pb.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';

/// 把 APP 端 PlayView 响应转换成 UI / 播放器 / 下载器共用的 [PlayUrlModel]。
///
/// 关键点：
/// * **不过滤 `StreamInfo.needVip`**：APP 端对非大会员也会下发 4K/1080P+ 的
///   dash 直链（`needVip=true` 但 `intact=true`，URL 可正常播放/下载）。
/// * **HDR Vivid / HDR 真彩 / 杜比视界 / 8K 只以 HEVC 或 AV1 下发**：请求
///   `preferCodecType=CODE264` 时这些档位只有 `StreamInfo` 而没有 `DashVideo`，
///   见 [missingDashQualities]。调用方据此补发一次 HEVC 请求并 [merge]。
/// * APP 端不下发 `bandwidth`（有时为 0），用 `size * 8 / 时长` 反推。
/// * 下载链路强依赖 `dash.duration`、`VideoItem.codecs/width/height`、
///   `AudioItem.frameRate/width/height`，这里全部补齐。
abstract final class PlayViewConverter {
  /// 只保留 B 站自家的 CDN 直链，避免把第三方回源地址交给
  /// [VideoUtils.getCdnUrl] 做 host 替换（替换后签名失效会 403）。
  ///
  /// 注意 `*.edge.mountaintoys.cn` / `upos-sz-*` 这些 PCDN/回源节点本身是可用的，
  /// 前提是请求时不带 Referer（见 `BiliMediaHeaders`），所以一并保留。
  static const _keepHostSuffixes = [
    '.mcdn.bilivideo.com',
    '.mcdn.bilivideo.cn',
    '.mcdn.bilivideo.net',
    '.bilivideo.com',
    '.bilivideo.cn',
    '.mountaintoys.cn',
  ];

  /// `streamList` 里出现了、但没有 `dashVideo` 的档位。
  ///
  /// 线上实测：`preferCodecType=CODE264` 请求 HDR/8K 视频时，129(HDR Vivid)、
  /// 125(HDR 真彩)、126(杜比视界)、127(8K) 这些档位只有 `StreamInfo`，
  /// 没有 `DashVideo`；换成 CODE265 / CODEAV1 再请求一次才会下发。
  static Set<int> missingDashQualities(PlayViewReply reply) {
    if (!reply.hasVideoInfo()) return const {};
    final missing = <int>{};
    for (final stream in reply.videoInfo.streamList) {
      if (stream.hasDashVideo()) continue;
      final quality = stream.hasStreamInfo() ? stream.streamInfo.quality : 0;
      if (quality > 0) missing.add(quality);
    }
    return missing;
  }

  static PlayUrlModel? toPlayUrlModel(PlayViewReply reply) =>
      toPlayUrlModelFromReplies([reply]);

  /// 把多次 PlayView 响应（同一视频、不同 `preferCodecType`）合并成一个模型。
  ///
  /// 同一档位在 AVC 与 HEVC 下都有直链时，两条流都会保留：`dash.video` 里
  /// 按 (id, codecid) 去重，`supportFormats[quality].codecs` 汇总该档位的全部编码，
  /// 这样 `VideoUtils.selectCodec` 仍能按用户偏好挑到 AVC/HEVC/AV1。
  static PlayUrlModel? toPlayUrlModelFromReplies(
    Iterable<PlayViewReply> replies,
  ) {
    int duration = 0;
    String format = '';
    int videoCodecid = 0;

    // key = quality * 100 + codecid，保证同一档位的不同编码各留一条
    final videoMap = <int, Map<String, dynamic>>{};
    final audioMap = <int, Map<String, dynamic>>{};
    // quality -> 该档位出现过的编码（用于 supportFormats.codecs）
    final qualityCodecs = <int, List<String>>{};
    final qualityDesc = <int, Map<String, String>>{};

    for (final reply in replies) {
      if (!reply.hasVideoInfo()) continue;
      final info = reply.videoInfo;
      if (info.hasTimelength() && info.timelength.toInt() > duration) {
        duration = info.timelength.toInt();
      }
      if (format.isEmpty && info.hasFormat()) format = info.format;
      if (videoCodecid == 0 && info.videoCodecid > 0) {
        videoCodecid = info.videoCodecid;
      }

      for (final stream in info.streamList) {
        if (!stream.hasDashVideo()) continue;
        final dv = stream.dashVideo;
        final si = stream.hasStreamInfo() ? stream.streamInfo : null;
        final quality = si?.quality ?? 0;
        if (quality == 0 || !dv.hasBaseUrl()) continue;

        final codecs = _codecOf(dv.codecid);
        final key = quality * 100 + dv.codecid;
        if (videoMap.containsKey(key)) continue;

        final bandwidth = dv.bandwidth > 0
            ? dv.bandwidth
            : (duration > 0 ? dv.size.toInt() * 8 * 1000 ~/ duration : 0);

        videoMap[key] = {
          'id': quality,
          'baseUrl': dv.baseUrl,
          'backupUrl': _filterUrls(dv.backupUrl),
          'bandwidth': bandwidth,
          'codecid': dv.codecid,
          'codecs': codecs,
          // 下载链路用 `videoDash.width!` / `height!`，这里必须给非 null 值。
          'width': dv.width,
          'height': dv.height,
          'frameRate': dv.hasFrameRate() ? dv.frameRate : null,
          'mime_type': 'video/mp4',
        };

        final codecList = qualityCodecs.putIfAbsent(quality, () => []);
        if (!codecList.contains(codecs)) codecList.add(codecs);

        if (!qualityDesc.containsKey(quality)) {
          final vq = VideoQuality.fromCode(quality);
          qualityDesc[quality] = {
            'format': si?.format ?? '',
            'new_description':
                (si != null &&
                    si.hasNewDescription() &&
                    si.newDescription.isNotEmpty)
                ? si.newDescription
                : vq.desc,
            'display_desc':
                (si != null && si.hasDisplayDesc() && si.displayDesc.isNotEmpty)
                ? si.displayDesc
                : vq.shortDesc,
          };
        }
      }

      for (final item in info.dashAudio) {
        if (!item.hasBaseUrl()) continue;
        if (audioMap.containsKey(item.id)) continue;
        final bandwidth = item.bandwidth > 0
            ? item.bandwidth
            : (duration > 0 ? item.size.toInt() * 8 * 1000 ~/ duration : 0);
        audioMap[item.id] = {
          'id': item.id,
          'baseUrl': item.baseUrl,
          'backupUrl': _filterUrls(item.backupUrl),
          'bandwidth': bandwidth,
          'codecid': item.codecid,
          'frameRate': item.hasFrameRate() ? item.frameRate : '',
          'width': 1,
          'height': 1,
          'mime_type': 'audio/mp4',
        };
      }
    }

    if (videoMap.isEmpty) return null;

    // 降序，保证 dash.video.first 是最高画质
    final videos = videoMap.values.toList()
      ..sort((a, b) {
        final byId = (b['id'] as int).compareTo(a['id'] as int);
        return byId != 0 ? byId : (b['codecid'] as int).compareTo(a['codecid'] as int);
      });

    final qualities = qualityCodecs.keys.toList()..sort((a, b) => b.compareTo(a));
    final formats = [
      for (final quality in qualities)
        {
          'quality': quality,
          'format': qualityDesc[quality]!['format'],
          'new_description': qualityDesc[quality]!['new_description'],
          'display_desc': qualityDesc[quality]!['display_desc'],
          'codecs': qualityCodecs[quality]!,
        },
    ];

    final audios = audioMap.values.toList()
      ..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));

    return PlayUrlModel.fromJson({
      'quality': qualities.first,
      'format': format,
      'timelength': duration,
      'accept_quality': qualities,
      'accept_description': [
        for (final f in formats) f['new_description'] as String,
      ],
      'accept_format': '',
      'video_codecid': videoCodecid,
      'support_formats': formats,
      'dash': {
        'duration': duration > 0 ? duration : 1,
        'minBufferTime': 1.0,
        'video': videos,
        if (audios.isNotEmpty) 'audio': audios,
      },
    });
  }

  /// App 返回的直链常见形态是 `https://<ip>.mcdn.bilivideo.cn:8082/...`，
  /// 备用地址里偶尔混入第三方回源域名。只保留 B 站域名，避免
  /// `VideoUtils.getCdnUrl` 把 host 替换成 upos 镜像后 403。
  static List<String> _filterUrls(Iterable<String> urls) {
    final kept = <String>[];
    for (final url in urls) {
      if (url.isEmpty) continue;
      final host = Uri.tryParse(url)?.host ?? '';
      if (host.isEmpty) continue;
      if (_keepHostSuffixes.any(host.endsWith)) kept.add(url);
    }
    return kept;
  }

  static String _codecOf(int codecid) {
    return switch (codecid) {
      12 => 'hev1.1.6.L120.90', // HEVC
      13 => 'av01.0.08M.08', // AV1
      14 => 'dvh1.05.06', // 杜比视界
      _ => 'avc1.640033', // AVC
    };
  }
}
```

### `lib/plugin/pl_player/hdr_player_window.dart`

HDR 独立窗口

```dart
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:PiliPlus/http/bili_media_headers.dart';
import 'package:PiliPlus/pages/setting/models/play_settings.dart' show kMaxVolume;
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/widgets.dart' show VoidCallback;
import 'package:media_kit/ffi/src/allocation.dart';
import 'package:media_kit/ffi/src/utf8.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/core/initializer.dart';

/// 「HDR 独立窗口」播放器。
///
/// 为什么需要它：应用内画面走 media_kit 的 `vo=libmpv` + `mpv_render_context`
/// → ANGLE（EGL 8bit/8bit/8bit/8bit）→ `DXGI_FORMAT_B8G8R8A8_UNORM` 共享纹理
/// → Flutter `kFlutterDesktopPixelFormatBGRA8888`。整条链路只有 8bit，HDR 源
/// 只能被 tone-map 成 SDR，应用内怎么调 mpv 参数都出不了 HDR。
///
/// 唯一能真 HDR 的路子：让 mpv **自己开窗口**（`vo=gpu-next` + `gpu-context=d3d11`
/// + `force-window=yes`），它才会创建 R10G10B10A2_UNORM 交换链并把色彩空间切成
/// `RGB_FULL_G2084_NONE_P2020`。所以这里另起一个**独立的 mpv 实例**（不是
/// media_kit 那个 render-context 实例）播同一条直链，应用内画面用黑色遮罩盖住。
class HdrPlayerWindow {
  HdrPlayerWindow({
    required this.videoUrl,
    this.audioUrl,
    this.position = Duration.zero,
    this.speed = 1.0,
    this.volume = 1.0,
    this.onClosed,
  });

  final String videoUrl;
  final String? audioUrl;
  final Duration position;
  final double speed;
  final double volume;

  /// 窗口被关闭（播放结束 / 用户关窗 / 播放器退出）时回调，只会触发一次。
  final VoidCallback? onClosed;

  final _mpv = NativePlayer.mpv;
  Pointer<generated.mpv_handle>? _ctx;
  bool _disposed = false;
  bool _closedNotified = false;
  bool _logLevelLowered = false;

  /// HDR 窗口里最后一次已知的播放进度，用于关窗后把应用内播放器接回原处。
  Duration? _lastPosition;
  Duration? get lastPosition => _lastPosition;

  /// mpv 日志（info 级）。用于自检「是否真的切到了 10bit HDR 交换链」，
  /// 关键行形如：
  ///   Selected swapchain format R10G10B10A2_UNORM (24)
  ///   Swapchain successfully configured to color space RGB_FULL_G2084_NONE_P2020
  final List<String> logs = [];

  /// 是否已经确认拿到 10bit HDR 交换链。
  ///
  /// 用独立标志而不是每次扫 [logs]：verbose 日志量很大，[logs] 会从头淘汰，
  /// 交换链那几行是最早出现的，很容易被挤掉。
  bool _hdrConfirmed = false;

  /// 调试用：为 true 时保留全部 mpv 日志行（不做关键字过滤）。
  bool keepAllLogs = false;

  bool get isHdrOutput => _hdrConfirmed;

  bool get isActive => _ctx != null && !_disposed;

  Map<String, String> get _options => {
    // 关键三项：gpu-next + d3d11 才会走 D3D11 交换链并支持 10bit/HDR 输出；
    // force-window 让 mpv 自己创建窗口（而不是渲染到外部 render context）。
    'vo': 'gpu-next',
    'gpu-context': 'd3d11',
    'force-window': 'yes',
    // 播放结束后不要退出，由我们发 quit 决定何时销毁（避免窗口一闪而过）。
    'idle': 'yes',
    'keep-open': 'no',
    // 让 mpv 按显示器能力自动切到 HDR 色彩空间。
    'target-colorspace-hint': 'yes',
    'hwdec': Pref.hardwareDecoding,
    // 键盘快捷键（空格暂停、方向键 seek、f 全屏、q 退出）。
    // 注意不能设 osc：这个 libmpv 构建没编入 osc 脚本，设了会被拒（-5）。
    'input-default-bindings': 'yes',
    'input-vo-keyboard': 'yes',
    'title': 'PiliNara - HDR 独立窗口',
    'autofit-larger': '90%x90%',
    'geometry': '50%:50%',
    'volume': (volume * 100).toStringAsFixed(2),
    'volume-max': kMaxVolume.toString(),
    'speed': speed.toStringAsFixed(3),
    // 必须在 initialize 之前就把日志级别开到 verbose：视频输出（d3d11 交换链）
    // 是在初始化阶段创建的，等拿到 handle 再 mpv_request_log_messages 就晚了，
    // 会漏掉「是否真的切到 10bit HDR 交换链」那几行。
    'msg-level': 'all=v',
    if (position > Duration.zero)
      'start': (position.inMilliseconds / 1000).toStringAsFixed(3),
  };

  /// 创建实例并开始播放。返回 false 表示当前平台不支持或初始化失败。
  Future<bool> start() async {
    if (!Platform.isWindows) return false;
    if (_ctx != null) return true;
    try {
      final ctx = await Initializer.create(_mpv, _onEvent, options: _options);
      _ctx = ctx;
      // 直链请求头必须和 media_kit 那条链路一致：APP 通道直链（query 里
      // platform=android）带 Referer 会被 CDN 直接 403，且不能用桌面浏览器 UA。
      final (ua, referer) = BiliMediaHeaders.forPlayer(videoUrl);
      NativePlayer.setHeader(_mpv, ctx, userAgent: ua, referer: referer);
      _observeTimePos();
      _requestLogMessages();
      _command(['loadfile', _composeSource()]);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('HDR window start failed: $e');
      await dispose();
      return false;
    }
  }

  /// 视频 + 音频合成一条 EDL 播放源，写法与 media_kit 那条链路保持一致。
  String _composeSource() {
    final audio = audioUrl;
    if (audio == null || audio.isEmpty) return videoUrl;
    return 'edl://'
        '!no_chapters;'
        '%${videoUrl.length}%$videoUrl;'
        '!new_stream;!no_chapters;'
        '%${audio.length}%$audio';
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _logLevelTimer?.cancel();
    _logLevelTimer = null;
    final ctx = _ctx;
    _ctx = null;
    if (ctx == null) return;
    try {
      Initializer.dispose(ctx);
    } catch (_) {}
    try {
      _mpv.mpv_terminate_destroy(ctx);
    } catch (_) {}
  }

  void _notifyClosed() {
    if (_closedNotified) return;
    _closedNotified = true;
    onClosed?.call();
  }

  Future<void>? _onEvent(Pointer<generated.mpv_event> event) {
    switch (event.ref.event_id) {
      case generated.mpv_event_id.MPV_EVENT_PROPERTY_CHANGE:
        final prop = event.ref.data.cast<generated.mpv_event_property>().ref;
        if (prop.format == generated.mpv_format.MPV_FORMAT_DOUBLE &&
            prop.name.toDartString() == 'time-pos') {
          _lastPosition = Duration(
            milliseconds: (prop.data.cast<Double>().value * 1000).round(),
          );
        }
        break;

      case generated.mpv_event_id.MPV_EVENT_END_FILE:
        // reason: 0=EOF 2=STOP；两种情况都意味着这个窗口没内容可放了。
        final end = event.ref.data.cast<generated.mpv_event_end_file>().ref;
        if (end.reason ==
                generated.mpv_end_file_reason.MPV_END_FILE_REASON_EOF ||
            end.reason ==
                generated.mpv_end_file_reason.MPV_END_FILE_REASON_STOP) {
          _notifyClosed();
          _command(['quit']);
        }
        break;

      case generated.mpv_event_id.MPV_EVENT_SHUTDOWN:
        _notifyClosed();
        dispose();
        break;

      case generated.mpv_event_id.MPV_EVENT_LOG_MESSAGE:
        final log = event.ref.data.cast<generated.mpv_event_log_message>().ref;
        final text =
            '${log.prefix.toDartString().trim()}: ${log.text.toDartString().trim()}';
        // 只留跟 HDR / 交换链 / 视频输出相关的行，避免把内存日志撑爆。
        if (keepAllLogs ||
            text.contains('swapchain') ||
            text.contains('Swapchain') ||
            text.contains('R10G10B10A2') ||
            text.contains('G2084') ||
            text.contains('gpu-next') ||
            text.contains('D3D11') ||
            text.contains('error') ||
            text.contains('Error')) {
          logs.add(text);
          if (logs.length > 2000) logs.removeAt(0);
          // 已经确认拿到 10bit HDR 交换链，降回 error 级别再刷日志。
          if (!_logLevelLowered &&
              (text.contains('R10G10B10A2') || text.contains('G2084'))) {
            _hdrConfirmed = true;
            _logLevelLowered = true;
            _logLevelTimer?.cancel();
            _logLevelTimer = null;
            _setLogLevel('error');
          }
        }
        break;
    }
    return null;
  }

  void _requestLogMessages() {
    // 交换链是否切到 10bit HDR 只有 verbose 级别才会打印，所以先要 verbose；
    // 一旦确认到 HDR 就降回 error，避免持续产生大量日志事件。
    _setLogLevel('v');
    // 显示器没开 HDR / 源不是 HDR 时永远等不到那行日志，兜底 20s 后也降下来，
    // 否则 verbose 会一直刷到关窗。
    _logLevelTimer?.cancel();
    _logLevelTimer = Timer(const Duration(seconds: 20), () {
      if (!_logLevelLowered && !_disposed) {
        _logLevelLowered = true;
        _setLogLevel('error');
      }
    });
  }

  Timer? _logLevelTimer;

  void _setLogLevel(String level) {
    final ctx = _ctx;
    if (ctx == null) return;
    final levelPtr = level.toNativeUtf8();
    _mpv.mpv_request_log_messages(ctx, levelPtr);
    calloc.free(levelPtr);
    // 请求级别只是「送不送给客户端」，真正的产生级别由 msg-level 决定；
    // 确认到 HDR 之后一起降下来，免得一直生成 verbose 日志。
    // msg-level 的语法是 `模块=级别`，裸写 'error' 会被拒（Expected '=' and a value）。
    if (level != 'v') {
      _setProperty('msg-level', 'all=$level');
    }
  }

  void _observeTimePos() {
    final ctx = _ctx;
    if (ctx == null) return;
    final name = 'time-pos'.toNativeUtf8();
    _mpv.mpv_observe_property(
      ctx,
      _timePosObserveId,
      name,
      generated.mpv_format.MPV_FORMAT_DOUBLE,
    );
    calloc.free(name);
  }

  static const _timePosObserveId = 0x484452;

  void _command(List<String> args) {
    final ctx = _ctx;
    if (ctx == null) return;
    final pointers = args.map((e) => e.toNativeUtf8()).toList();
    final arr = calloc<Pointer<Uint8>>(pointers.length + 1);
    for (int i = 0; i < args.length; i++) {
      arr[i] = pointers[i];
    }
    _mpv.mpv_command(ctx, arr);
    calloc.free(arr);
    pointers.forEach(calloc.free);
  }

  /// 同步音量（0.0~1.0，与播放器控制器的 volume 同量纲）。
  void setVolume(double value) {
    _setProperty('volume', (value * 100).toStringAsFixed(2));
  }

  /// 同步倍速。
  void setSpeed(double value) {
    _setProperty('speed', value.toStringAsFixed(3));
  }

  /// 同步进度（秒）。
  void seek(Duration position) {
    _command([
      'seek',
      (position.inMilliseconds / 1000).toStringAsFixed(3),
      'absolute',
    ]);
  }

  /// 暂停 / 继续（跟随应用内播放器的播放状态）。
  void setPaused(bool paused) {
    _setProperty('pause', paused ? 'yes' : 'no');
  }

  void _setProperty(String name, String value) {
    final ctx = _ctx;
    if (ctx == null) return;
    final namePtr = name.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    _mpv.mpv_set_property_string(ctx, namePtr, valuePtr);
    calloc
      ..free(namePtr)
      ..free(valuePtr);
  }
}
```

## B. 修改文件的 diff

```diff
diff --git a/.gitignore b/.gitignore
index 05f4d90..396db12 100644
--- a/.gitignore
+++ b/.gitignore
@@ -154,6 +154,8 @@ test.dart
 docs/*
 !docs/danmaku_font_scaling.md
 !docs/inapp_pip_implementation.md
+!docs/high-quality-stream-handoff.md
+!docs/high-quality-stream-handoff.patch
 test*.dart
 
 AGENTS.md
diff --git a/lib/common/constants.dart b/lib/common/constants.dart
index 6194f52..5348561 100644
--- a/lib/common/constants.dart
+++ b/lib/common/constants.dart
@@ -9,6 +9,19 @@ abstract final class Constants {
   static const String appKey = 'dfca71928277209b';
   // 59b43e04ad6965f34319062b478f83dd TV端
   static const String appSec = 'b5475a8825547a4fc26c7d518eaaa02e';
+  /// 手机端 Android appkey/secret（同 BBDown 的 PhoneAppKey/PhoneAppSecret）。
+  /// 只有手机端签发的 access_token 才能在 PlayView 拿到 4K / 1080P+ 的 dash 流。
+  static const String phoneAppKey = '783bbb7264451d82';
+  static const String phoneAppSec = '2653583c8873dea268ab9386918b1d65';
+
+  /// PlayView 需要的手机端指纹：mobi_app=android 且 build>=6400000。
+  /// HD 端（android_hd / build 2001100）服务端只下发 480P/360P 的 dashVideo。
+  static const String playViewMobiApp = 'android';
+  static const int playViewBuild = 7320200;
+  static const String playViewVersionName = '7.32.0';
+  static const String playViewUserAgent =
+      'Mozilla/5.0 BiliDroid/7.32.0 (bbcallen@gmail.com) os/android model/android mobi_app/android build/7320200 channel/master innerVer/7320200 osVer/15 network/2';
+
   // static const String thirdSign = '04224646d1fea004e79606d3b038c84a';
   // static const String thirdApi =
   //     'https://www.mcbbs.net/template/mcbbs/image/special_photo_bg.png';
diff --git a/lib/grpc/grpc_req.dart b/lib/grpc/grpc_req.dart
index e221f0a..9552ed8 100644
--- a/lib/grpc/grpc_req.dart
+++ b/lib/grpc/grpc_req.dart
@@ -57,11 +57,18 @@ abstract final class GrpcReq {
     GeneratedMessage request,
     T Function(Uint8List) grpcParser, {
     bool isolate = false,
+    Map<String, String>? grpcHeaders,
   }) async {
     final response = await Request().post<Uint8List>(
       HttpString.appBaseUrl + url,
       data: compressProtobuf(request.writeToBuffer()),
-      options: options,
+      options: grpcHeaders == null
+          ? options
+          : Options(
+              contentType: 'application/grpc',
+              responseType: ResponseType.bytes,
+              extra: {'grpcHeaders': grpcHeaders},
+            ),
     );
 
     if (response.data case final Map map) {
diff --git a/lib/grpc/url.dart b/lib/grpc/url.dart
index 41b8599..bbf8cc1 100644
--- a/lib/grpc/url.dart
+++ b/lib/grpc/url.dart
@@ -60,6 +60,10 @@ abstract final class GrpcUrl {
   static const audioTripleLike = '$audio/TripleLike';
   static const audioCoinAdd = '$audio/CoinAdd';
 
+  // playurl (APP 端视频取流，可拿到 4K)
+  static const playUrl = '/bilibili.app.playurl.v1.PlayURL';
+  static const playView = '$playUrl/PlayView';
+
   // space
   static const space = '/bilibili.app.interface.v1.Space';
   static const searchArchive = '$space/SearchArchive';
diff --git a/lib/http/login.dart b/lib/http/login.dart
index e620413..d62bae0 100644
--- a/lib/http/login.dart
+++ b/lib/http/login.dart
@@ -53,12 +53,51 @@ abstract final class LoginHttp {
     }
   }
 
-  static Future codePoll(String authCode) async {
+  /// 手机端（`mobi_app=android` + 手机端 appkey）扫码登录。
+  ///
+  /// 只有手机端签发的 access_token 才能让 APP 端 PlayView 下发 4K / 1080P+
+  /// 的 dash 流；HD 端（[getHDcode]）签发的 token 服务端只给到 1080P。
+  @pragma('vm:notify-debugger-on-exception')
+  static Future<LoadingState<({String authCode, String url})>>
+  getPhoneCode() async {
+    final params = {
+      'local_id': '0',
+      'platform': 'android',
+      'mobi_app': 'android',
+    };
+    AppSign.appSign(
+      params,
+      appkey: Constants.phoneAppKey,
+      appsec: Constants.phoneAppSec,
+    );
+    final res = await Request().post(Api.getTVCode, queryParameters: params);
+
+    if (res.data['code'] == 0) {
+      try {
+        final Map<String, dynamic> data = res.data['data'];
+        return Success((authCode: data['auth_code'], url: data['url']));
+      } catch (e, s) {
+        return Error('$e\n\n$s');
+      }
+    } else {
+      return Error(res.data['message']);
+    }
+  }
+
+  static Future codePoll(String authCode, {bool phone = false}) async {
     final params = {
       'auth_code': authCode,
       'local_id': '0',
     };
-    AppSign.appSign(params);
+    if (phone) {
+      AppSign.appSign(
+        params,
+        appkey: Constants.phoneAppKey,
+        appsec: Constants.phoneAppSec,
+      );
+    } else {
+      AppSign.appSign(params);
+    }
     final res = await Request().post(Api.qrcodePoll, queryParameters: params);
     return {
       'status': res.data['code'] == 0,
diff --git a/lib/http/video.dart b/lib/http/video.dart
index 672759a..368e862 100644
--- a/lib/http/video.dart
+++ b/lib/http/video.dart
@@ -1,8 +1,11 @@
 import 'dart:convert';
 
 import 'package:PiliPlus/common/constants.dart';
+import 'package:PiliPlus/grpc/bilibili/app/playurl/v1.pb.dart' show PlayViewReply;
+import 'package:PiliPlus/grpc/bilibili/app/playurl/v1.pbenum.dart' show CodeType;
 import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
     show ReplyInfo;
+import 'package:PiliPlus/grpc/playurl.dart';
 import 'package:PiliPlus/http/api.dart';
 import 'package:PiliPlus/http/browser_ua.dart';
 import 'package:PiliPlus/http/constants.dart';
@@ -10,11 +13,13 @@ import 'package:PiliPlus/http/init.dart';
 import 'package:PiliPlus/http/loading_state.dart';
 import 'package:PiliPlus/http/login.dart';
 import 'package:PiliPlus/models/common/account_type.dart';
+import 'package:PiliPlus/models/common/video/video_quality.dart';
 import 'package:PiliPlus/models/common/video/video_type.dart';
 import 'package:PiliPlus/models/home/rcmd/result.dart';
 import 'package:PiliPlus/models/model_hot_video_item.dart';
 import 'package:PiliPlus/models/model_rec_video_item.dart';
 import 'package:PiliPlus/models/pgc_lcf.dart';
+import 'package:PiliPlus/models/video/play/playview_convert.dart';
 import 'package:PiliPlus/models/video/play/url.dart';
 import 'package:PiliPlus/models_new/pgc/pgc_rank/pgc_rank_item_model.dart';
 import 'package:PiliPlus/models_new/popular/popular_precious/data.dart';
@@ -244,6 +249,15 @@ abstract final class VideoHttp {
     String? language,
     bool voiceBalance = false,
   }) async {
+    // UGC 视频优先走 APP 端 gRPC PlayView：只有这条通道能拿到 4K / 1080P+ 的
+    // dash 直链（Web 端 x/player/wbi/playurl 对非大会员硬性封顶 1080P）。
+    // 失败（未登录 / 没有手机端 access_key / 接口异常）时静默回退 Web 通道。
+    // 带 epid/seasonId 的走番剧（pgc）逻辑，这里不接管。
+    if (videoType == .ugc && epid == null && seasonId == null) {
+      final appRes = await _videoUrlByApp(avid: avid, bvid: bvid, cid: cid);
+      if (appRes != null) return appRes;
+    }
+
     final Map<String, dynamic> params;
     Map<String, dynamic>? data;
 
@@ -358,6 +372,79 @@ abstract final class VideoHttp {
     }
   }
 
+  /// 走 APP 端 gRPC PlayView 取流（可拿到 4K / 1080P+）。
+  ///
+  /// 需要手机端 access_token：`authorization: identify_v1 <token>` 加上
+  /// `mobi_app=android & build>=6400000` 的指纹，服务端才会下发 4K 的 dashVideo。
+  /// 任一条件不满足时返回 null，由调用方回退 Web 通道。
+  static Future<Success<PlayUrlModel>?> _videoUrlByApp({
+    int? avid,
+    String? bvid,
+    required int cid,
+  }) async {
+    final accessKey = Accounts.video.accessKey;
+    if (accessKey == null || accessKey.isEmpty) return null;
+
+    final int? aid = avid ?? (bvid != null ? IdUtils.bv2av(bvid) : null);
+    if (aid == null || aid <= 0) return null;
+
+    try {
+      final preferCodecType = _preferCodecType;
+      final res = await PlayUrlGrpc.playView(
+        aid: aid,
+        cid: cid,
+        preferCodecType: preferCodecType,
+        accessKey: accessKey,
+      );
+      if (res case Success(:final response)) {
+        final replies = <PlayViewReply>[response];
+
+        // HDR Vivid(129) / HDR 真彩(125) / 杜比视界(126) / 8K(127) 只以 HEVC 或
+        // AV1 下发：首选 AVC 时这些档位只有 StreamInfo、没有 DashVideo。
+        // 检测到有档位缺流就再发一次 HEVC 请求，把两次结果合并，
+        // 让 UI 能列出并播放这些档位（对齐 BBDown 的 APP 通道能力）。
+        if (PlayViewConverter.missingDashQualities(response).isNotEmpty) {
+          final fallbackCodec = preferCodecType == CodeType.CODE265
+              ? CodeType.CODEAV1
+              : CodeType.CODE265;
+          final fallback = await PlayUrlGrpc.playView(
+            aid: aid,
+            cid: cid,
+            preferCodecType: fallbackCodec,
+            accessKey: accessKey,
+          );
+          if (fallback case Success(:final response)) {
+            replies.add(response);
+          }
+        }
+
+        final model = PlayViewConverter.toPlayUrlModelFromReplies(replies);
+        if (model != null && model.dash?.video?.isNotEmpty == true) {
+          // 服务端按 token 来源决定下发哪些档位：HD 端（`mobi_app=android_hd`
+          // 签发的 token）只会给到 480P/360P。这种结果不能接管，否则会把原本
+          // 能用 Web 通道看 1080P 的用户降级成 480P。低于 1080P 就回退 Web。
+          final topQuality = model.dash!.video!.first.quality.code;
+          if (topQuality >= VideoQuality.high1080.code) {
+            return Success(model);
+          }
+        }
+      }
+    } catch (_) {
+      // 静默回退 Web 通道
+    }
+    return null;
+  }
+
+  static CodeType get _preferCodecType {
+    final codecs = Pref.preferCodecs;
+    if (codecs.isEmpty) return CodeType.CODE265;
+    return switch (codecs.first) {
+      .AVC => CodeType.CODE264,
+      .AV1 => CodeType.CODEAV1,
+      _ => CodeType.CODE265,
+    };
+  }
+
   static String _parseVideoErr(int? code, String? msg) {
     return switch (code) {
       -404 => '视频不存在或已被删除',
diff --git a/lib/pages/login/controller.dart b/lib/pages/login/controller.dart
index 9474ce7..22742b6 100644
--- a/lib/pages/login/controller.dart
+++ b/lib/pages/login/controller.dart
@@ -35,11 +35,18 @@ class LoginPageController extends GetxController
   late final codeInfo =
       LoadingState<({String authCode, String url})>.loading().obs;
 
+  /// 手机端扫码（`mobi_app=android` + 手机端 appkey）的状态。
+  /// 只有手机端 token 才能在 APP 端 PlayView 拿到 4K / 1080P+ 的 dash 流。
+  late final phoneCodeInfo =
+      LoadingState<({String authCode, String url})>.loading().obs;
+
   late final TabController tabController;
 
   late final CaptchaDataModel captchaData = CaptchaDataModel();
   late final RxInt qrCodeLeftTime = 180.obs;
   late final RxString statusQRCode = ''.obs;
+  late final RxInt phoneQrCodeLeftTime = 180.obs;
+  late final RxString phoneStatusQRCode = ''.obs;
 
   late var selectedCountryCodeId = Login.dialPrefix.first;
   late String captchaKey = '';
@@ -48,9 +55,11 @@ class LoginPageController extends GetxController
 
   // 定时器
   Timer? qrCodeTimer;
+  Timer? phoneQrCodeTimer;
   Timer? smsSendCooldownTimer;
 
   bool _isReq = false;
+  bool _isPhoneReq = false;
   bool _isImportingWebLogin = false;
 
   static const Set<String> _requiredWebLoginCookies = {
@@ -62,7 +71,7 @@ class LoginPageController extends GetxController
   @override
   void onInit() {
     super.onInit();
-    tabController = TabController(length: 4, vsync: this)
+    tabController = TabController(length: 5, vsync: this)
       ..addListener(_handleTabChange);
   }
 
@@ -72,6 +81,7 @@ class LoginPageController extends GetxController
       ..removeListener(_handleTabChange)
       ..dispose();
     qrCodeTimer?.cancel();
+    phoneQrCodeTimer?.cancel();
     smsSendCooldownTimer?.cancel();
     telTextController.dispose();
     usernameTextController.dispose();
@@ -119,11 +129,57 @@ class LoginPageController extends GetxController
     }
   }
 
+  /// 手机端扫码：拿到的 access_token 才能在 APP 端 PlayView 拿到 4K。
+  Future<void> refreshPhoneQRCode() async {
+    final res = await LoginHttp.getPhoneCode();
+    if (res case Success(:final response)) {
+      phoneQrCodeTimer?.cancel();
+      phoneCodeInfo.value = res;
+      phoneQrCodeTimer = Timer.periodic(
+        const Duration(milliseconds: 1000),
+        (t) {
+          final left = 180 - t.tick;
+          if (left <= 0) {
+            t.cancel();
+            phoneStatusQRCode.value = '二维码已过期，请刷新';
+            phoneQrCodeLeftTime.value = 0;
+            return;
+          }
+          phoneQrCodeLeftTime.value = left;
+          if (_isPhoneReq || tabController.index != 3) return;
+
+          _isPhoneReq = true;
+          LoginHttp.codePoll(response.authCode, phone: true).then((value) async {
+            _isPhoneReq = false;
+            if (value['status']) {
+              t.cancel();
+              phoneStatusQRCode.value = '扫码成功';
+              await setAccount(
+                value['data'],
+                value['data']['cookie_info']['cookies'],
+              );
+              Get.back();
+            } else if (value['code'] == 86038) {
+              t.cancel();
+              phoneQrCodeLeftTime.value = 0;
+            } else {
+              phoneStatusQRCode.value = value['msg'];
+            }
+          });
+        },
+      );
+    }
+  }
+
   void _handleTabChange() {
     if (tabController.index == 2) {
       if (qrCodeTimer == null || !qrCodeTimer!.isActive) {
         refreshQRCode();
       }
+    } else if (tabController.index == 3) {
+      if (phoneQrCodeTimer == null || !phoneQrCodeTimer!.isActive) {
+        refreshPhoneQRCode();
+      }
     }
   }
 
@@ -766,6 +822,16 @@ class LoginPageController extends GetxController
   }
 
   Future<void> _saveAccount(LoginAccount account) async {
+    // 同一 mid 重新登录（典型场景：先用 Cookie 导入登录，再用手机扫码登录以
+    // 拿到 access_token）时，新 account 的 type 是空集合。若直接替换槽位，
+    // hive 里会存下 `type: []`，下次启动 Accounts.refresh() 就恢复不出这个
+    // 账号，表现为「登录掉了」。这里把被替换账号所占的槽位补回新账号。
+    final types = <AccountType>{
+      for (int i = 0; i < AccountType.values.length; i++)
+        if (Accounts.accountMode[i].mid == account.mid) AccountType.values[i],
+    };
+    account.type.addAll(types);
+
     await Future.wait([?account.onChange(), AnonymousAccount().delete()]);
     for (int i = 0; i < AccountType.values.length; i++) {
       if (Accounts.accountMode[i].mid == account.mid) {
diff --git a/lib/pages/login/view.dart b/lib/pages/login/view.dart
index 9b20651..bafe20d 100644
--- a/lib/pages/login/view.dart
+++ b/lib/pages/login/view.dart
@@ -38,6 +38,7 @@ class _LoginPageState extends State<LoginPage> {
   // 二维码生成时间
   bool showPassword = false;
   GlobalKey globalKey = GlobalKey();
+  GlobalKey phoneGlobalKey = GlobalKey();
 
   @override
   void didChangeDependencies() {
@@ -172,6 +173,122 @@ class _LoginPageState extends State<LoginPage> {
     );
   }
 
+  /// 手机端扫码登录：签发的 access_token 才能在 APP 端 PlayView 拿到 4K。
+  Widget loginByPhoneQRCode(ThemeData theme) {
+    return Column(
+      children: [
+        const SizedBox(height: 20),
+        const Text('使用 bilibili 官方 App 扫码登录（手机端）'),
+        const SizedBox(height: 8),
+        Padding(
+          padding: const EdgeInsets.symmetric(horizontal: 20),
+          child: Text(
+            '手机端凭证才可解析 4K / 1080P 高码率视频',
+            textAlign: TextAlign.center,
+            style: theme.textTheme.labelMedium!.copyWith(
+              color: theme.colorScheme.primary,
+            ),
+          ),
+        ),
+        const SizedBox(height: 20),
+        Obx(
+          () => Text(
+            '剩余有效时间: ${_loginPageCtr.phoneQrCodeLeftTime} 秒',
+            style: TextStyle(
+              fontFeatures: const [FontFeature.tabularFigures()],
+              color: theme.colorScheme.primaryFixedDim,
+            ),
+          ),
+        ),
+        const SizedBox(height: 5),
+        Row(
+          mainAxisAlignment: MainAxisAlignment.center,
+          children: [
+            TextButton.icon(
+              onPressed: _loginPageCtr.refreshPhoneQRCode,
+              icon: const Icon(Icons.refresh),
+              label: const Text('刷新二维码'),
+            ),
+            TextButton.icon(
+              onPressed: () async {
+                SmartDialog.showLoading(msg: '正在生成截图');
+                final boundary =
+                    phoneGlobalKey.currentContext!.findRenderObject()
+                        as RenderRepaintBoundary;
+                final image = await boundary.toImage(pixelRatio: 3);
+                final byteData = await image.toByteData(format: .png);
+                final pngBytes = byteData!.buffer.asUint8List();
+                image.dispose();
+                SmartDialog.dismiss();
+                final picName =
+                    "${Constants.appName}_loginQRCode_phone_${_loginPageCtr.phoneCodeInfo.value.data.authCode.hashCode.toUnsigned(32).toRadixString(16)}";
+                ImageUtils.saveByteImg(bytes: pngBytes, fileName: picName);
+              },
+              icon: const Icon(Icons.save),
+              label: const Text('保存至相册'),
+            ),
+            if (kDebugMode || PlatformUtils.isMobile)
+              TextButton.icon(
+                onPressed: () => PageUtils.launchURL(
+                  'bilibili://browser?url=${Uri.encodeComponent(_loginPageCtr.phoneCodeInfo.value.data.url)}',
+                  mode: LaunchMode.externalNonBrowserApplication,
+                ),
+                icon: const Icon(Icons.open_in_browser_outlined),
+                label: const Text('其他应用打开'),
+              ),
+          ],
+        ),
+        RepaintBoundary(
+          key: phoneGlobalKey,
+          child: Obx(
+            () => switch (_loginPageCtr.phoneCodeInfo.value) {
+              Loading() => const SizedBox(
+                height: 200,
+                width: 200,
+                child: m3eLoading,
+              ),
+              Success(:final response) => Container(
+                width: 200,
+                height: 200,
+                color: Colors.white,
+                padding: const EdgeInsets.all(8),
+                child: PrettyQrView.data(
+                  data: response.url,
+                  decoration: const PrettyQrDecoration(
+                    shape: PrettyQrSquaresSymbol(
+                      color: Colors.black87,
+                    ),
+                  ),
+                ),
+              ),
+              Error(:final errMsg) => HttpError(
+                isSliver: false,
+                errMsg: errMsg,
+                onReload: _loginPageCtr.refreshPhoneQRCode,
+              ),
+            },
+          ),
+        ),
+        const SizedBox(height: 10),
+        Obx(
+          () => Text(
+            _loginPageCtr.phoneStatusQRCode.value,
+            style: TextStyle(color: theme.colorScheme.secondaryFixedDim),
+          ),
+        ),
+        Padding(
+          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
+          child: Text(
+            '请务必在 ${Constants.appName} 开源仓库等可信渠道下载安装。',
+            style: theme.textTheme.labelSmall!.copyWith(
+              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
+            ),
+          ),
+        ),
+      ],
+    );
+  }
+
   Widget loginByCookie(ThemeData theme) {
     return Column(
       mainAxisSize: MainAxisSize.min,
@@ -596,6 +713,15 @@ class _LoginPageState extends State<LoginPage> {
                           children: [Icon(Icons.qr_code), Text(' 扫码')],
                         ),
                       ),
+                      Tab(
+                        child: Row(
+                          mainAxisSize: MainAxisSize.min,
+                          children: [
+                            Icon(Icons.phone_android),
+                            Text(' 手机扫码'),
+                          ],
+                        ),
+                      ),
                       Tab(
                         child: Row(
                           mainAxisSize: MainAxisSize.min,
@@ -621,6 +747,7 @@ class _LoginPageState extends State<LoginPage> {
                 Tab(icon: Icon(Icons.password), text: '密码'),
                 Tab(icon: Icon(Icons.sms_outlined), text: '短信'),
                 Tab(icon: Icon(Icons.qr_code), text: '扫码'),
+                Tab(icon: Icon(Icons.phone_android), text: '手机扫码'),
                 Tab(icon: Icon(Icons.cookie_outlined), text: 'Cookie'),
               ],
               controller: _loginPageCtr.tabController,
@@ -640,6 +767,7 @@ class _LoginPageState extends State<LoginPage> {
                     tabViewOuter(loginByPassword(theme)),
                     tabViewOuter(loginBySmS(theme)),
                     tabViewOuter(loginByQRCode(theme)),
+                    tabViewOuter(loginByPhoneQRCode(theme)),
                     tabViewOuter(loginByCookie(theme)),
                   ],
                 ),
diff --git a/lib/plugin/pl_player/controller.dart b/lib/plugin/pl_player/controller.dart
index f57ed0b..4072adc 100644
--- a/lib/plugin/pl_player/controller.dart
+++ b/lib/plugin/pl_player/controller.dart
@@ -5,6 +5,7 @@ import 'dart:math' show max, min;
 import 'dart:ui' as ui;
 
 import 'package:PiliPlus/common/assets.dart';
+import 'package:PiliPlus/http/bili_media_headers.dart';
 import 'package:PiliPlus/http/browser_ua.dart';
 import 'package:PiliPlus/http/constants.dart';
 import 'package:PiliPlus/http/loading_state.dart';
@@ -77,6 +78,7 @@ import 'package:path/path.dart' as path;
 import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
 import 'package:wakelock_plus/wakelock_plus.dart';
 import 'package:window_manager/window_manager.dart';
+import 'package:PiliPlus/plugin/pl_player/hdr_player_window.dart';
 import 'package:PiliPlus/plugin/pl_player/models/auto_audio_only_state.dart';
 
 typedef PlayCallback = Future<void>? Function();
@@ -164,6 +166,116 @@ class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
 
   final Rx<VideoFitType> videoFit = Rx(.contain);
 
+  // ---------------------------------------------------------------------
+  // HDR 独立窗口
+  //
+  // 应用内画面走 media_kit 的 render context → ANGLE 8bit → Flutter 8bit，
+  // 物理上出不了 HDR。点「HDR」后改为另起一个 mpv 实例自己开窗（gpu-next +
+  // d3d11），Windows 才会切到 10bit HDR 交换链；应用内画面用遮罩盖住。
+  // 见 HdrPlayerWindow。
+  HdrPlayerWindow? _hdrWindow;
+
+  /// HDR 窗口是否正在使用中（应用内画面此时是黑屏遮罩）。
+  final RxBool hdrWindowActive = false.obs;
+
+  /// 是否可以在当前视频上启用 HDR 独立窗口（桌面端 + 网络源 + 非直播）。
+  bool get canUseHdrWindow =>
+      PlatformUtils.isDesktop &&
+      !isLive &&
+      dataSource is NetworkSource &&
+      dataSource.videoSource.isNotEmpty;
+
+  /// 打开 HDR 独立窗口播放当前直链；返回是否成功。
+  ///
+  /// 成功后应用内播放器会暂停（否则两路音频叠着响），画面由调用方盖遮罩。
+  Future<bool> openHdrWindow() async {
+    if (!canUseHdrWindow) return false;
+    if (_hdrWindow != null) return true;
+
+    final player = _videoPlayerController;
+    final startPosition = player?.state.position ?? Duration.zero;
+    // 先暂停应用内播放器，避免与 HDR 窗口的音频重复。
+    await player?.pause();
+
+    final window = HdrPlayerWindow(
+      videoUrl: dataSource.videoSource,
+      audioUrl: dataSource.audioSource,
+      position: startPosition,
+      speed: playbackSpeed,
+      volume: volume.value,
+      onClosed: _onHdrWindowClosed,
+    );
+    final ok = await window.start();
+    if (!ok) {
+      window.dispose();
+      // 失败时恢复应用内播放，别让用户卡在黑屏上。
+      if (player != null && playerStatus.isPlaying) {
+        await player.play();
+      }
+      return false;
+    }
+    _hdrWindow = window;
+    hdrWindowActive.value = true;
+    playerStatus = .paused;
+    _startHdrProgressSync();
+    return true;
+  }
+
+  /// HDR 窗口接管期间，应用内播放器是暂停的，进度条不会自己走。
+  /// 用一个 500ms 的定时器把 HDR 窗口的 time-pos 同步到 [position]，
+  /// 这样进度条、弹幕、记忆进度都还是对的。
+  Timer? _hdrSyncTimer;
+
+  void _startHdrProgressSync() {
+    _hdrSyncTimer?.cancel();
+    _hdrSyncTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
+      final window = _hdrWindow;
+      if (window == null) return;
+      final pos = window.lastPosition;
+      if (pos == null) return;
+      final seconds = pos.inSeconds;
+      if (seconds != position.value) {
+        position.value = seconds;
+      }
+    });
+  }
+
+  void _stopHdrProgressSync() {
+    _hdrSyncTimer?.cancel();
+    _hdrSyncTimer = null;
+  }
+
+  /// 关闭 HDR 独立窗口，并把应用内播放器接回原进度继续播放。
+  Future<void> closeHdrWindow({bool resume = true}) async {
+    _stopHdrProgressSync();
+    final window = _hdrWindow;
+    _hdrWindow = null;
+    hdrWindowActive.value = false;
+    final lastPosition = window?.lastPosition;
+    window?.dispose();
+    if (resume) {
+      if (lastPosition != null) {
+        await seekTo(lastPosition, isSeek: false);
+      }
+      await play(hideControls: false);
+    }
+  }
+
+  void _onHdrWindowClosed() {
+    // mpv 窗口被关掉/播完：清状态、恢复应用内播放。
+    _stopHdrProgressSync();
+    if (_hdrWindow == null) return;
+    final lastPosition = _hdrWindow?.lastPosition;
+    _hdrWindow = null;
+    hdrWindowActive.value = false;
+    if (lastPosition != null) {
+      seekTo(lastPosition, isSeek: false);
+    }
+    if (!isLive) {
+      play(hideControls: false);
+    }
+  }
+
   late final RxBool continuePlayInBackground =
       Pref.continuePlayInBackground.obs;
 
@@ -1029,6 +1141,10 @@ class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
   }) async {
     try {
       _processing = true;
+      // 换视频/换P：HDR 独立窗口播的是上一条直链，必须一起关掉。
+      if (_hdrWindow != null) {
+        await closeHdrWindow(resume: false);
+      }
       // 换视频/换P：解除倍速锁定并恢复锁定前速度。
       // 必须先于临时配置重置执行，否则 lastPlaybackSpeed 会被先行覆盖
       await releaseSpeedLock();
@@ -1229,6 +1345,8 @@ class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
       player.setProperty('force-window', 'no');
     }
 
+    // 默认按 Web 通道直链配置；真正的取值在 _createVideoController 里按
+    // 每条直链的来源（APP / Web）重新设置，见 BiliMediaHeaders。
     player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);
 
     _startListeners(player);
@@ -1277,6 +1395,19 @@ class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
         ...buffer,
     };
 
+    if (dataSource is NetworkSource && !isLive) {
+      // APP 通道直链（query 里 platform=android）带 Referer 会被 CDN 直接 403，
+      // 且不能用桌面浏览器 UA；Web 通道直链则必须带 Referer。见 BiliMediaHeaders。
+      final (ua, referer) = BiliMediaHeaders.forPlayer(
+        dataSource.videoSource,
+      );
+      player.setMediaHeader(userAgent: ua, referer: referer);
+    } else {
+      // 直播 / 本地文件沿用原有默认值。必须显式重设，否则会残留上一条
+      // APP 直链留下的空 Referer（mpv 的 referrer 是播放器级状态）。
+      player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);
+    }
+
     String video = dataSource.videoSource;
     if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
       if (onlyPlayAudio.value) {
@@ -1543,6 +1674,8 @@ class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
   }
 
   Future<void> seek(Duration position, {bool isSeek = false}) async {
+    // HDR 独立窗口接管期间，跳转要作用到那个 mpv 实例上。
+    _hdrWindow?.seek(position);
     if (isSeek) {
       /// 拖动进度条调节时，不等待第一帧，防止抖动
       await _videoPlayerController?.stream.buffer.first;
@@ -1582,6 +1715,9 @@ class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
   Future<void> setPlaybackSpeed(double speed) async {
     lastPlaybackSpeed = playbackSpeed;
 
+    // HDR 独立窗口是另一个 mpv 实例，倍速要同步过去。
+    _hdrWindow?.setSpeed(speed);
+
     if (speed == _videoPlayerController?.state.rate) return;
 
     await _videoPlayerController?.setRate(speed);
@@ -1622,6 +1758,13 @@ class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
 
   /// 底层播放：申请音频焦点 + 启动播放，不含 UI 副作用
   Future<void> _rawPlay() async {
+    // HDR 独立窗口接管期间，播放/暂停要作用到那个 mpv 实例上，
+    // 应用内播放器保持暂停（否则两路音频叠着响）。
+    if (_hdrWindow case final window?) {
+      window.setPaused(false);
+      playerStatus = PlayerStatus.playing;
+      return;
+    }
     await _videoPlayerController?.play();
     audioSessionHandler?.setActive(true);
     playerStatus = PlayerStatus.playing;
@@ -1643,6 +1786,8 @@ class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
 
   /// 暂停播放
   Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
+    // HDR 独立窗口接管期间，暂停要作用到那个 mpv 实例上。
+    _hdrWindow?.setPaused(true);
     await _videoPlayerController?.pause();
     playerStatus = .paused;
 
@@ -1712,6 +1857,8 @@ class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
   Future<void> setVolume(double volume, {bool showIndicator = true}) async {
     if (this.volume.value != volume) {
       this.volume.value = volume;
+      // HDR 独立窗口是另一个 mpv 实例，音量要同步过去。
+      _hdrWindow?.setVolume(volume);
       try {
         if (PlatformUtils.isDesktop) {
           await _videoPlayerController!.setVolume(volume * 100);
@@ -2647,6 +2794,11 @@ class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
     }
 
     _playerCount = 0;
+    // HDR 独立窗口必须在这里销毁，否则会残留一个孤立的 mpv 窗口。
+    _stopHdrProgressSync();
+    _hdrWindow?.dispose();
+    _hdrWindow = null;
+    hdrWindowActive.value = false;
     if (removeSafeArea) {
       showSystemBar();
     }
diff --git a/lib/plugin/pl_player/models/bottom_control_type.dart b/lib/plugin/pl_player/models/bottom_control_type.dart
index be14c84..4c6d37a 100644
--- a/lib/plugin/pl_player/models/bottom_control_type.dart
+++ b/lib/plugin/pl_player/models/bottom_control_type.dart
@@ -13,4 +13,5 @@ enum BottomControlType {
   dmChart,
   qa,
   aiTranslate,
+  hdr,
 }
diff --git a/lib/plugin/pl_player/view/view.dart b/lib/plugin/pl_player/view/view.dart
index 420ef99..428e35e 100644
--- a/lib/plugin/pl_player/view/view.dart
+++ b/lib/plugin/pl_player/view/view.dart
@@ -1018,6 +1018,39 @@ class _PLVideoPlayerState extends State<PLVideoPlayer>
         },
       ),
 
+      /// HDR 独立窗口
+      ///
+      /// 应用内画面走 media_kit 的 render context → ANGLE 8bit → Flutter 8bit，
+      /// 物理上出不了 HDR；点这里改为另起一个 mpv 实例自己开窗（gpu-next +
+      /// d3d11），Windows 才会切到 10bit HDR 交换链。见 HdrPlayerWindow。
+      BottomControlType.hdr => Obx(
+        () {
+          final active = plPlayerController.hdrWindowActive.value;
+          return ComBtn(
+            width: widgetWidth,
+            height: 30,
+            tooltip: active ? '退出 HDR 独立窗口' : 'HDR 独立窗口（真 HDR 输出）',
+            icon: Icon(
+              active ? Icons.hdr_on : Icons.hdr_off,
+              size: 22,
+              color: active ? colorScheme.primary : Colors.white,
+            ),
+            onTap: () async {
+              if (active) {
+                await plPlayerController.closeHdrWindow();
+                return;
+              }
+              final ok = await plPlayerController.openHdrWindow();
+              SmartDialog.showToast(
+                ok
+                    ? '已在独立窗口中播放，应用内画面暂停；关窗后自动接回'
+                    : '无法打开 HDR 窗口（仅桌面端网络视频可用）',
+              );
+            },
+          );
+        },
+      ),
+
       /// 全屏
       BottomControlType.fullscreen => ComBtn(
         width: widgetWidth,
@@ -1055,6 +1088,7 @@ class _PLVideoPlayerState extends State<PLVideoPlayer>
       .subtitle,
       .speed,
       if (isNotFileSource && flag) .qa,
+      if (plPlayerController.canUseHdrWindow) .hdr,
       if (!plPlayerController.isDesktopPip) .fullscreen,
     ];
     return PlayerBar(
@@ -1696,6 +1730,14 @@ class _PLVideoPlayerState extends State<PLVideoPlayer>
       children: <Widget>[
         _videoWidget,
 
+        // HDR 独立窗口接管期间，应用内画面是过时的 SDR 渲染，直接盖住。
+        // 该窗口自己带 OSC，进度/暂停/音量/倍速都与本播放器双向同步。
+        Obx(
+          () => plPlayerController.hdrWindowActive.value
+              ? const Positioned.fill(child: _HdrWindowMask())
+              : const SizedBox.shrink(),
+        ),
+
         if (widget.danmuWidget case final danmaku?)
           Positioned.fill(top: _kDanmakuTopInset, child: danmaku),
 
@@ -2979,3 +3021,37 @@ class _SubtitleSelectPanel extends StatelessWidget {
     );
   }
 }
+
+/// HDR 独立窗口接管时的应用内画面遮罩。
+///
+/// 应用内渲染链路是 media_kit render context → ANGLE 8bit → Flutter 8bit，
+/// 无法输出 HDR；点「HDR」后由 [HdrPlayerWindow] 另起一个 mpv 实例自己开窗，
+/// 应用内这块画面就只是过时的 SDR 内容，用纯黑盖住并给出提示。
+class _HdrWindowMask extends StatelessWidget {
+  const _HdrWindowMask();
+
+  @override
+  Widget build(BuildContext context) {
+    return const ColoredBox(
+      color: Colors.black,
+      child: Center(
+        child: Column(
+          mainAxisSize: MainAxisSize.min,
+          children: [
+            Icon(Icons.hdr_on, size: 40, color: Colors.white70),
+            SizedBox(height: 12),
+            Text(
+              '正在 HDR 独立窗口中播放',
+              style: TextStyle(color: Colors.white, fontSize: 14),
+            ),
+            SizedBox(height: 6),
+            Text(
+              '该窗口支持真 HDR 输出；关闭它后自动接回此处继续播放',
+              style: TextStyle(color: Colors.white54, fontSize: 12),
+            ),
+          ],
+        ),
+      ),
+    );
+  }
+}
diff --git a/lib/services/download/download_manager.dart b/lib/services/download/download_manager.dart
index a9aa746..b22e880 100644
--- a/lib/services/download/download_manager.dart
+++ b/lib/services/download/download_manager.dart
@@ -1,6 +1,7 @@
 import 'dart:async';
 import 'dart:io';
 
+import 'package:PiliPlus/http/bili_media_headers.dart';
 import 'package:PiliPlus/http/init.dart';
 import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
 import 'package:PiliPlus/utils/extension/file_ext.dart';
@@ -61,7 +62,13 @@ class DownloadManager {
       response = await Request.http11Dio.get<ResponseBody>(
         url.http2https,
         options: Options(
-          headers: {'range': 'bytes=$received-'},
+          headers: {
+            'range': 'bytes=$received-',
+            // 账号拦截器默认会给所有请求补 `Referer: https://www.bilibili.com/`。
+            // 但 APP 通道直链（query 里 platform=android）带 Referer 会被 CDN 直接 403，
+            // 这里显式置空以阻止拦截器的 `??=` 补值。见 BiliMediaHeaders。
+            if (BiliMediaHeaders.isAndroidPlatformUrl(url)) 'referer': '',
+          },
           responseType: ResponseType.stream,
           validateStatus: (status) =>
               status != null &&
diff --git a/lib/utils/accounts/account_manager/account_mgr.dart b/lib/utils/accounts/account_manager/account_mgr.dart
index ef18974..1e797d2 100644
--- a/lib/utils/accounts/account_manager/account_mgr.dart
+++ b/lib/utils/accounts/account_manager/account_mgr.dart
@@ -58,7 +58,12 @@ class AccountManager extends Interceptor {
     final isApp = path.startsWith(HttpString.appBaseUrl);
 
     if (isApp && options.responseType == ResponseType.bytes) {
-      options.headers.addAll(account.grpcHeaders);
+      // 允许单个 gRPC 请求覆盖指纹（如 PlayView 需要手机端 android 指纹）
+      if (options.extra['grpcHeaders'] case final Map<String, String> headers) {
+        options.headers.addAll(headers);
+      } else {
+        options.headers.addAll(account.grpcHeaders);
+      }
       return handler.next(options);
     }
 
diff --git a/lib/utils/accounts/grpc_headers.dart b/lib/utils/accounts/grpc_headers.dart
index ee83b3b..a1731d7 100644
--- a/lib/utils/accounts/grpc_headers.dart
+++ b/lib/utils/accounts/grpc_headers.dart
@@ -83,4 +83,61 @@ abstract final class GrpcHeaders {
       ),
     };
   }
+
+  /// PlayView 专用指纹。
+  ///
+  /// 服务端按 `x-bili-device-bin` 里的 `mobi_app` + `build` 决定是否下发
+  /// 4K/1080P+ 的 dash 流：必须 `mobi_app=android` 且 `build>=6400000`，
+  /// 而全局 gRPC 指纹是 HD 端（android_hd / 2001100），所以这里单独构造。
+  static Map<String, String> newPlayViewHeaders([String? accessKey]) {
+    const mobiApp = Constants.playViewMobiApp;
+    const build = Constants.playViewBuild;
+    const versionName = Constants.playViewVersionName;
+    return {
+      'grpc-encoding': 'gzip',
+      'gzip-accept-encoding': 'gzip,identity',
+      'user-agent': Constants.playViewUserAgent,
+      'x-bili-gaia-vtoken': '',
+      'x-bili-aurora-zone': '',
+      'x-bili-trace-id': _traceId,
+      'buvid': _buvid,
+      'bili-http-engine': 'cronet',
+      'x-bili-device-bin': base64Encode(
+        Device(
+          appId: 5,
+          build: build,
+          buvid: _buvid,
+          mobiApp: mobiApp,
+          platform: _device,
+          channel: _biliChannel,
+          brand: _device,
+          model: _device,
+          osver: '15',
+          versionName: versionName,
+        ).writeToBuffer(),
+      ),
+      'x-bili-network-bin': _base['x-bili-network-bin']!,
+      'x-bili-locale-bin': _base['x-bili-locale-bin']!,
+      'x-bili-exps-bin': '',
+      'x-bili-fawkes-req-bin': base64Encode(
+        FawkesReq(
+          appkey: 'android64',
+          env: 'prod',
+          sessionId: _sessionId,
+        ).writeToBuffer(),
+      ),
+      'x-bili-metadata-bin': base64Encode(
+        Metadata(
+          accessKey: accessKey,
+          mobiApp: mobiApp,
+          device: _device,
+          build: build,
+          channel: _biliChannel,
+          buvid: _buvid,
+          platform: _device,
+        ).writeToBuffer(),
+      ),
+      if (accessKey != null) 'authorization': 'identify_v1 $accessKey',
+    };
+  }
 }
diff --git a/lib/utils/video_utils.dart b/lib/utils/video_utils.dart
index fe192e6..d0f172f 100644
--- a/lib/utils/video_utils.dart
+++ b/lib/utils/video_utils.dart
@@ -1,3 +1,4 @@
+import 'package:PiliPlus/http/bili_media_headers.dart';
 import 'package:PiliPlus/models/common/video/cdn_type.dart';
 import 'package:PiliPlus/models/common/video/video_decode_type.dart';
 import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
@@ -87,6 +88,13 @@ abstract final class VideoUtils {
       customHost = null;
     }
 
+    // APP 通道（platform=android）签发的直链，签名（upsig/uparams）与 host 绑定，
+    // 换任何 host 都会 403；且这些 PCDN/回源节点本身可用（只要请求不带 Referer）。
+    // 因此原样返回，不做任何 CDN 替换。
+    if (urls.isNotEmpty && BiliMediaHeaders.isAndroidPlatformUrl(urls.first)) {
+      return urls.first;
+    }
+
     if (customHost == null && defaultCDNService == CDNService.baseUrl) {
       return urls.first;
     }
```

## C. 测试文件

### `test/playview_convert_test.dart`

```dart
import 'package:PiliPlus/grpc/bilibili/app/playurl/v1.pb.dart';
import 'package:PiliPlus/models/video/play/playview_convert.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一条和线上 APP PlayView 同构的流。
Stream _stream({
  required int quality,
  required int codecid,
  required int width,
  required int height,
  required int size,
  required String newDesc,
  required String displayDesc,
  bool needVip = false,
}) {
  return Stream(
    streamInfo: StreamInfo(
      quality: quality,
      format: 'hdflv2',
      description: 'desc $quality',
      needVip: needVip,
      needLogin: needVip,
      intact: true,
      newDescription: newDesc,
      displayDesc: displayDesc,
    ),
    dashVideo: DashVideo(
      baseUrl: 'https://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/v1/resource/upgcxcode/$quality.m4s?os=mcdn',
      backupUrl: [
        'https://upos-sz-mirrorcoso1.bilivideo.com/upgcxcode/$quality.m4s',
      ],
      bandwidth: 0, // App 端不下发，需用 size 反推
      codecid: codecid,
      size: Int64(size),
      width: width,
      height: height,
      frameRate: '24.000',
    ),
  );
}

PlayViewReply _reply() {
  const duration = 206464; // ms
  return PlayViewReply(
    videoInfo: VideoInfo(
      quality: 120,
      format: 'hdflv2',
      timelength: Int64(duration),
      videoCodecid: 12,
      streamList: [
        _stream(
          quality: 120,
          codecid: 12,
          width: 4096,
          height: 1740,
          size: 113289079,
          newDesc: '4K 超清',
          displayDesc: '4K',
          needVip: true,
        ),
        _stream(
          quality: 112,
          codecid: 12,
          width: 1920,
          height: 816,
          size: 42991850,
          newDesc: '1080P 高码率',
          displayDesc: '1080P+',
          needVip: true,
        ),
        _stream(
          quality: 80,
          codecid: 12,
          width: 1920,
          height: 816,
          size: 24898484,
          newDesc: '1080P 高清',
          displayDesc: '1080P',
        ),
        _stream(
          quality: 64,
          codecid: 12,
          width: 1280,
          height: 544,
          size: 12845022,
          newDesc: '720P 准高清',
          displayDesc: '720P',
        ),
        _stream(
          quality: 32,
          codecid: 12,
          width: 854,
          height: 362,
          size: 7706824,
          newDesc: '480P 标清',
          displayDesc: '480P',
        ),
        _stream(
          quality: 16,
          codecid: 12,
          width: 640,
          height: 272,
          size: 5322002,
          newDesc: '360P 流畅',
          displayDesc: '360P',
        ),
      ],
      dashAudio: [
        DashItem(
          id: 30280,
          baseUrl: 'https://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/v1/resource/audio192.m4s',
          bandwidth: 212206,
          size: Int64(5477180),
        ),
        DashItem(
          id: 30232,
          baseUrl: 'https://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/v1/resource/audio132.m4s',
          bandwidth: 108099,
        ),
        DashItem(
          id: 30216,
          baseUrl: 'https://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/v1/resource/audio64.m4s',
          bandwidth: 65708,
        ),
      ],
    ),
  );
}

void main() {
  group('PlayViewConverter', () {
    test('保留 needVip 的 4K / 1080P+ 流', () {
      final model = PlayViewConverter.toPlayUrlModel(_reply())!;
      final videos = model.dash!.video!;
      expect(videos.length, 6, reason: '6 档全部要保留，不能因 needVip 过滤');
      expect(videos.first.quality.code, VideoQuality.super4K.code);
      expect(videos.first.quality.desc, '4K 超清');
      expect(videos.first.width, 4096);
      expect(videos.first.height, 1740);
    });

    test('画质按降序排列，dash.video.first 是最高画质', () {
      final model = PlayViewConverter.toPlayUrlModel(_reply())!;
      final qualities = model.dash!.video!.map((e) => e.quality.code).toList();
      expect(qualities, [120, 112, 80, 64, 32, 16]);
      expect(model.acceptQuality, [120, 112, 80, 64, 32, 16]);
      expect(model.quality, 120);
    });

    test('bandwidth 为 0 时用 size/时长反推', () {
      final model = PlayViewConverter.toPlayUrlModel(_reply())!;
      final first = model.dash!.video!.first;
      // 113289079 * 8 * 1000 ~/ 206464 = 4389688（线上真实 bw 4389786，反推够用）
      expect(first.bandWidth, closeTo(4389688, 5));
    });

    test('codecs 按 codecid 映射，供 selectCodec / 下载链路使用', () {
      final model = PlayViewConverter.toPlayUrlModel(_reply())!;
      expect(model.dash!.video!.first.codecs, startsWith('hev1'));
      expect(model.dash!.video!.first.codecid, 12);
    });

    test('support_formats 每档带 newDesc/displayDesc/codecs', () {
      final model = PlayViewConverter.toPlayUrlModel(_reply())!;
      final formats = model.supportFormats!;
      expect(formats.length, 6);
      for (final f in formats) {
        expect(f.newDesc, isNotNull);
        expect(f.displayDesc, isNotNull);
        expect(f.codecs, isNotEmpty);
      }
      final first = formats.first;
      expect(first.quality, 120);
      expect(first.newDesc, '4K 超清');
      expect(first.displayDesc, '4K');
    });

    test('下载链路依赖的字段全部非空', () {
      final model = PlayViewConverter.toPlayUrlModel(_reply())!;
      expect(model.dash!.duration, 206464);
      for (final v in model.dash!.video!) {
        expect(v.bandWidth, isNotNull);
        expect(v.codecid, isNotNull);
        expect(v.width, isNotNull);
        expect(v.height, isNotNull);
        expect(v.codecs, isNotNull);
        expect(v.playUrls, isNotEmpty);
      }
      for (final a in model.dash!.audio!) {
        expect(a.frameRate, isNotNull);
        expect(a.width, isNotNull);
        expect(a.height, isNotNull);
        expect(a.bandWidth, isNotNull);
        expect(a.codecid, isNotNull);
      }
      expect(model.dash!.audio!.length, 3);
      expect(model.dash!.audio!.first.id, 30280);
    });

    test('backupUrl 里的 upos 镜像会被过滤，只留 mcdn 直链', () {
      final model = PlayViewConverter.toPlayUrlModel(_reply())!;
      final first = model.dash!.video!.first;
      expect(first.baseUrl, contains('mcdn.bilivideo.cn'));
      expect(first.backupUrl, isNotNull);
      // upos-sz-mirrorcoso1 是 B 站域名，会被保留（getCdnUrl 默认不改写）
      expect(
        first.backupUrl!.every((e) => e.contains('bilivideo')),
        isTrue,
      );
    });

    test('没有可用流时返回 null', () {
      final empty = PlayViewReply(
        videoInfo: VideoInfo(quality: 0, streamList: const []),
      );
      expect(PlayViewConverter.toPlayUrlModel(empty), isNull);
    });

    test('findAvailableVideoQuality 能选到 4K', () {
      final model = PlayViewConverter.toPlayUrlModel(_reply())!;
      // 请求 127(8K) → 落到实际最高的 120
      expect(model.findAvailableVideoQuality(127), 120);
      // 请求 112 → 112
      expect(model.findAvailableVideoQuality(112), 112);
      // 请求 100 → 落到 80
      expect(model.findAvailableVideoQuality(100), 80);
    });

    test('missingDashQualities 找出只有 StreamInfo 没有 DashVideo 的档位', () {
      // 线上 AVC 请求 HDR 视频时的真实形态：129 只有 StreamInfo。
      final avcReply = PlayViewReply(
        videoInfo: VideoInfo(
          quality: 120,
          timelength: Int64(100000),
          streamList: [
            Stream(
              streamInfo: StreamInfo(quality: 129, description: 'HDR Vivid'),
              // 故意不给 dashVideo
            ),
            _stream(
              quality: 120,
              codecid: 7,
              width: 3840,
              height: 2160,
              size: 10000000,
              newDesc: '4K 超清',
              displayDesc: '4K',
            ),
          ],
        ),
      );
      expect(PlayViewConverter.missingDashQualities(avcReply), {129});
      expect(PlayViewConverter.toPlayUrlModel(avcReply)!.acceptQuality, [120]);
    });

    test('合并 AVC + HEVC 两次响应后 HDR/8K 档位出现且编码可区分', () {
      final avcReply = PlayViewReply(
        videoInfo: VideoInfo(
          quality: 120,
          timelength: Int64(100000),
          streamList: [
            Stream(streamInfo: StreamInfo(quality: 129)),
            _stream(
              quality: 120,
              codecid: 7,
              width: 3840,
              height: 2160,
              size: 10000000,
              newDesc: '4K 超清',
              displayDesc: '4K',
            ),
          ],
        ),
      );
      final hevcReply = PlayViewReply(
        videoInfo: VideoInfo(
          quality: 129,
          timelength: Int64(100000),
          videoCodecid: 12,
          streamList: [
            Stream(
              streamInfo: StreamInfo(
                quality: 129,
                description: 'HDR Vivid',
                newDescription: 'HDR Vivid',
                displayDesc: 'HDR',
              ),
              dashVideo: DashVideo(
                baseUrl: 'https://upos-sz-estghw.bilivideo.com/upgcxcode/129.m4s',
                codecid: 12,
                size: Int64(264154438),
                width: 3840,
                height: 2160,
                frameRate: '119.990',
              ),
            ),
            _stream(
              quality: 120,
              codecid: 12,
              width: 3840,
              height: 2160,
              size: 13037515,
              newDesc: '4K 超清',
              displayDesc: '4K',
            ),
          ],
        ),
      );

      final model = PlayViewConverter.toPlayUrlModelFromReplies([
        avcReply,
        hevcReply,
      ])!;

      // 129 出现在最高档，120 有 AVC + HEVC 两条
      expect(model.acceptQuality, [129, 120]);
      expect(model.quality, 129);
      expect(model.dash!.video!.first.quality.code, VideoQuality.hdrVivid.code);
      expect(model.dash!.video!.first.width, 3840);
      final v120 = model.dash!.video!
          .where((e) => e.quality.code == 120)
          .map((e) => e.codecid)
          .toSet();
      expect(v120, {7, 12}, reason: '同一档位的两种编码都要保留');

      // supportFormats 汇总该档位的全部编码
      final fmt120 = model.supportFormats!.firstWhere((e) => e.quality == 120);
      expect(fmt120.codecs!.length, 2);
      expect(fmt120.codecs!.any((e) => e.startsWith('avc1')), isTrue);
      expect(fmt120.codecs!.any((e) => e.startsWith('hev1')), isTrue);
      // HDR Vivid 的文案来自 StreamInfo.newDescription
      final fmt129 = model.supportFormats!.firstWhere((e) => e.quality == 129);
      expect(fmt129.newDesc, 'HDR Vivid');
      expect(fmt129.displayDesc, 'HDR');
    });

    test('8K 档位能通过 findAvailableVideoQuality 选中', () {
      final reply = PlayViewReply(
        videoInfo: VideoInfo(
          quality: 127,
          timelength: Int64(70000),
          streamList: [
            Stream(
              streamInfo: StreamInfo(
                quality: 127,
                newDescription: '8K 超高清',
                displayDesc: '8K',
              ),
              dashVideo: DashVideo(
                baseUrl: 'https://upos-sz-estghw.bilivideo.com/upgcxcode/127.m4s',
                codecid: 12,
                size: Int64(174486540),
                width: 7680,
                height: 4320,
              ),
            ),
            _stream(
              quality: 120,
              codecid: 12,
              width: 3840,
              height: 2160,
              size: 11355665,
              newDesc: '4K 超清',
              displayDesc: '4K',
            ),
          ],
        ),
      );
      final model = PlayViewConverter.toPlayUrlModel(reply)!;
      expect(model.findAvailableVideoQuality(127), 127);
      expect(model.dash!.video!.first.width, 7680);
      expect(model.dash!.video!.first.height, 4320);
    });
  });
}
```

### `test/bili_media_headers_test.dart`

```dart
import 'package:PiliPlus/http/bili_media_headers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BiliMediaHeaders.isAndroidPlatformUrl', () {
    test('APP 通道直链识别', () {
      expect(
        BiliMediaHeaders.isAndroidPlatformUrl(
          'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/70/65/1/1-1-30121.m4s'
          '?e=abc&platform=android&mid=1&build=7320200',
        ),
        isTrue,
      );
      expect(
        BiliMediaHeaders.isAndroidPlatformUrl(
          'https://upos-sz-mirrorhw.bilivideo.com/x.m4s?platform=android_tv_yst',
        ),
        isTrue,
      );
    });

    test('Web 通道直链不识别为 APP', () {
      expect(
        BiliMediaHeaders.isAndroidPlatformUrl(
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3.m4s'
          '?platform=pc&qn_dyeid=abc',
        ),
        isFalse,
      );
      expect(
        BiliMediaHeaders.isAndroidPlatformUrl(
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3.m4s',
        ),
        isFalse,
      );
    });

    test('空/非法 URL 安全返回 false', () {
      expect(BiliMediaHeaders.isAndroidPlatformUrl(null), isFalse);
      expect(BiliMediaHeaders.isAndroidPlatformUrl(''), isFalse);
      expect(BiliMediaHeaders.isAndroidPlatformUrl('not a url'), isFalse);
    });
  });

  group('BiliMediaHeaders.forPlayer', () {
    test('APP 直链：非桌面浏览器 UA + 空 Referer', () {
      final (ua, referer) = BiliMediaHeaders.forPlayer(
        'https://a.bilivideo.com/x.m4s?platform=android',
      );
      expect(ua, isNot(contains('Chrome/1')));
      expect(ua, isNot(contains('Version/15.2')));
      expect(referer, isEmpty);
    });

    test('Web 直链：浏览器 UA + bilibili Referer', () {
      final (ua, referer) = BiliMediaHeaders.forPlayer(
        'https://a.bilivideo.com/x.m4s?platform=pc',
      );
      expect(ua, isNotEmpty);
      expect(referer, 'https://www.bilibili.com/');
    });
  });

  group('BiliMediaHeaders.forDownload', () {
    test('APP 直链不带 Referer（否则 CDN 403）', () {
      final headers = BiliMediaHeaders.forDownload(
        'https://a.bilivideo.com/x.m4s?platform=android',
      );
      expect(headers.containsKey('referer'), isFalse);
      expect(headers['user-agent'], isNotEmpty);
      expect(headers['user-agent'], isNot(contains('Chrome/1')));
    });

    test('Web 直链带 Referer', () {
      final headers = BiliMediaHeaders.forDownload(
        'https://a.bilivideo.com/x.m4s?platform=pc',
      );
      expect(headers['referer'], 'https://www.bilibili.com/');
    });
  });
}
```

### `test/playview_live_test.dart`

```dart
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// 需要真实手机端 token 的联网测试：
///   PILINARA_LIVE_TOKEN=access_token flutter test test/playview_live_test.dart
/// 未设置环境变量时整体跳过。
void main() {
  final token = Platform.environment['PILINARA_LIVE_TOKEN'];
  const bvid = 'BV1j5nj68E48';
  const cid = 42860284135;

  late Directory tempDir;

  setUpAll(() async {
    if (token == null) return;
    tempDir = await Directory.systemTemp.createTemp('pilinara-live-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
    Accounts.account = await Hive.openBox<LoginAccount>('account');
    Accounts.accountMode[AccountType.video.index] = LoginAccount(
      BiliCookieJar.fromJson({
        'DedeUserID': '6891108',
        'bili_jct': 'csrf',
      }),
      token,
      null,
    );
    // 触发 Dio 单例构造并挂上 AccountManager（gRPC 指纹注入依赖它）
    Request();
    Request.dio.interceptors.add(AccountManager());
  });

  tearDownAll(() async {
    if (token == null) return;
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('PlayView via videoUrl returns 4K dash for non-vip account', () async {
    if (token == null) {
      markTestSkipped('PILINARA_LIVE_TOKEN not set');
      return;
    }
    final res = await VideoHttp.videoUrl(
      bvid: bvid,
      cid: cid,
      qn: 127,
      tryLook: false,
      videoType: VideoType.ugc,
    );
    expect(res, isA<Success>(), reason: '$res');
    final data = (res as Success).response;
    expect(data.dash, isNotNull);
    final qualities = data.dash!.video!.map((e) => e.quality.code).toSet();
    // ignore: avoid_print
    print('qualities=$qualities');
    // ignore: avoid_print
    print(
      'supportFormats=${data.supportFormats!.map((e) => '${e.quality}:${e.newDesc}/${e.displayDesc}/${e.codecs}').toList()}',
    );
    // ignore: avoid_print
    print(
      'audio=${data.dash!.audio?.map((e) => '${e.id}:${e.quality}').toList()}',
    );
    expect(qualities, contains(120));
    expect(data.findAvailableVideoQuality(127), 120);
    final uhd = data.dash!.video!.firstWhere((e) => e.quality.code == 120);
    // ignore: avoid_print
    print(
      '4k url=${uhd.baseUrl} ${uhd.width}x${uhd.height} bw=${uhd.bandWidth} codecs=${uhd.codecs} codecid=${uhd.codecid}',
    );
    expect(uhd.baseUrl, isNotNull);
    expect(uhd.width, greaterThan(1920));
    expect(uhd.codecs, isNotNull);
    final fmt = data.supportFormats!.firstWhere((e) => e.quality == 120);
    expect(fmt.codecs, isNotNull);
    expect(fmt.newDesc, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('HDR Vivid / 8K 档位通过二次 HEVC 请求补齐', () async {
    if (token == null) {
      markTestSkipped('PILINARA_LIVE_TOKEN not set');
      return;
    }
    // P1: 4K 120FPS HDR Vivid，P4: 8K。AVC 首选时这两档只有 StreamInfo。
    const cases = <(String, int, int)>[
      ('BV1beNcz2ECq', 36532584643, 129), // HDR Vivid
      ('BV1beNcz2ECq', 36532588493, 127), // 8K
    ];
    for (final (bvid, cid, topQa) in cases) {
      final res = await VideoHttp.videoUrl(
        bvid: bvid,
        cid: cid,
        qn: 127,
        tryLook: false,
        videoType: VideoType.ugc,
      );
      expect(res, isA<Success>(), reason: '$bvid/$cid -> $res');
      final data = (res as Success).response;
      final qualities = data.dash!.video!.map((e) => e.quality.code).toSet();
      final top = data.dash!.video!.first;
      // ignore: avoid_print
      print(
        '$bvid/$cid qualities=$qualities top=${top.quality.code} '
        '${top.width}x${top.height} codecid=${top.codecid} '
        'codecs=${top.codecs} bw=${top.bandWidth}',
      );
      // HDR Vivid(129) 高于默认偏好 127，默认会落到 4K；显式选 129 才能选中。
      expect(qualities, contains(topQa));
      expect(data.findAvailableVideoQuality(topQa), topQa);
      expect(top.quality.code, topQa);
      expect(top.width, topQa == 127 ? 7680 : 3840);
      expect(top.codecs, isNotNull);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
```

### `test/playview_cdn_live_test.dart`

```dart
import 'dart:io';

import 'package:PiliPlus/http/bili_media_headers.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// 需要真实手机端 token 的联网测试：验证 APP 通道签发的 4K 直链
/// 用 BiliMediaHeaders 给出的请求头确实能取到数据（不再 403）。
///   PILINARA_LIVE_TOKEN=access_token flutter test test/playview_cdn_live_test.dart
/// 未设置环境变量时整体跳过。
void main() {
  final token = Platform.environment['PILINARA_LIVE_TOKEN'];

  // 已知踩坑视频：4K 直链落在 upos-sz-mirror* / *.edge.mountaintoys.cn，
  // 带 Referer 必 403。
  const cases = [
    ('BV1MunP6LEMs', 42899276570),
    ('BV1j5nj68E48', 42860284135),
  ];

  late Directory tempDir;

  setUpAll(() async {
    if (token == null) return;
    tempDir = await Directory.systemTemp.createTemp('pilinara-cdn-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
    Accounts.account = await Hive.openBox<LoginAccount>('account');
    Accounts.accountMode[AccountType.video.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '6891108', 'bili_jct': 'csrf'}),
      token,
      null,
    );
    Request();
    Request.dio.interceptors.add(AccountManager());
  });

  tearDownAll(() async {
    if (token == null) return;
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  for (final (bvid, cid) in cases) {
    test('$bvid 4K 直链带正确请求头可下载', () async {
      if (token == null) {
        markTestSkipped('PILINARA_LIVE_TOKEN not set');
        return;
      }
      final res = await VideoHttp.videoUrl(
        bvid: bvid,
        cid: cid,
        qn: 127,
        tryLook: false,
        videoType: VideoType.ugc,
      );
      expect(res, isA<Success>(), reason: '$res');
      final data = (res as Success).response;
      final uhd = data.dash!.video!.firstWhere((e) => e.quality.code == 120);
      // 播放器/下载器实际用的地址是 getCdnUrl 处理后的结果，必须原样保留
      // （APP 直链签名与 host 绑定，换 host 会 403）。
      final url = VideoUtils.getCdnUrl(uhd.playUrls);
      expect(BiliMediaHeaders.isAndroidPlatformUrl(url), isTrue,
          reason: 'getCdnUrl 不应改写 APP 直链: $url');
      final headers = BiliMediaHeaders.forDownload(url);
      // ignore: avoid_print
      print('$bvid host=${Uri.parse(url).host} headers=$headers');

      // 用独立 HttpClient 发 Range 请求，完全模拟下载器行为。
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(url));
        headers.forEach(req.headers.set);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
        final resp = await req.close();
        // ignore: avoid_print
        print('$bvid status=${resp.statusCode}');
        expect(
          resp.statusCode,
          anyOf(200, 206),
          reason: '带 Referer 会被 CDN 403，说明 BiliMediaHeaders 判定有误',
        );
        final bytes = await resp.fold<int>(0, (n, chunk) => n + chunk.length);
        expect(bytes, greaterThan(0));
      } finally {
        client.close(force: true);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  // HDR Vivid / 杜比视界 / 8K 这些高动态档位同样走 APP 通道，直链也是
  // platform=android，必须验证它们能取到数据（这是本轮新增的能力）。
  const hdrCases = [
    ('BV1beNcz2ECq', 36532584643, 129), // HDR Vivid 4K120
    ('BV1beNcz2ECq', 36532587657, 125), // HDR 真彩
    ('BV1beNcz2ECq', 36532653061, 126), // 杜比视界
    ('BV1beNcz2ECq', 36532588493, 127), // 8K
  ];

  for (final (bvid, cid, quality) in hdrCases) {
    test('$bvid q=$quality 高动态直链可下载', () async {
      if (token == null) {
        markTestSkipped('PILINARA_LIVE_TOKEN not set');
        return;
      }
      final res = await VideoHttp.videoUrl(
        bvid: bvid,
        cid: cid,
        qn: 127,
        tryLook: false,
        videoType: VideoType.ugc,
      );
      expect(res, isA<Success>(), reason: '$res');
      final data = (res as Success).response;
      final target = data.dash!.video!.firstWhere(
        (e) => e.quality.code == quality,
        orElse: () => throw StateError('缺少 q=$quality，实际=${data.dash!.video!.map((e) => e.quality.code).toSet()}'),
      );
      final url = VideoUtils.getCdnUrl(target.playUrls);
      expect(BiliMediaHeaders.isAndroidPlatformUrl(url), isTrue);
      final headers = BiliMediaHeaders.forDownload(url);

      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(url));
        headers.forEach(req.headers.set);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
        final resp = await req.close();
        // ignore: avoid_print
        print('$bvid q=$quality ${target.width}x${target.height} '
            'codecid=${target.codecid} host=${Uri.parse(url).host} '
            'status=${resp.statusCode}');
        expect(resp.statusCode, anyOf(200, 206));
        final bytes = await resp.fold<int>(0, (n, chunk) => n + chunk.length);
        expect(bytes, greaterThan(0));
      } finally {
        client.close(force: true);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
```

### `test/hdr_window_live_test.dart`

```dart
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/grpc/bilibili/app/playurl/v1.pbenum.dart';
import 'package:PiliPlus/grpc/playurl.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/video/play/playview_convert.dart';
import 'package:PiliPlus/plugin/pl_player/hdr_player_window.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';

/// HDR 独立窗口的联网验证：真的起一个 mpv 实例（vo=gpu-next + d3d11），
/// 播一条 HDR Vivid 直链，然后从 mpv 日志里确认拿到了 10bit HDR 交换链。
///
///   PILINARA_LIVE_TOKEN=access_token flutter test test/hdr_window_live_test.dart
/// 测试进程没有打包产物的 dll 目录，按几个已知位置找 libmpv-2.dll。
String _findLibMpv() {
  const candidates = [
    r'D:\Tools\PiliNara-4K\libmpv-2.dll',
    r'D:\Tools\PiliPlus\libmpv-2.dll',
    'build/windows/x64/runner/Release/libmpv-2.dll',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  throw StateError('libmpv-2.dll not found; run a windows build first');
}

void main() {
  final token = Platform.environment['PILINARA_LIVE_TOKEN'];  // P1: 4K 120FPS HDR Vivid
  const aid = 116188277381963;
  const cid = 36532584643;

  late Directory tempDir;

  setUpAll(() async {
    if (token == null) return;
    tempDir = await Directory.systemTemp.createTemp('pilinara-hdr-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
    Accounts.account = await Hive.openBox<LoginAccount>('account');
    Accounts.accountMode[AccountType.video.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '6891108', 'bili_jct': 'csrf'}),
      token,
      null,
    );
    Request();
    Request.dio.interceptors.add(AccountManager());
    // HdrPlayerWindow 依赖 media_kit 已初始化（NativePlayer.mpv / libmpv 路径）。
    // 测试进程没有打包产物的 dll 目录，显式指到构建出来的 libmpv-2.dll。
    MediaKit.ensureInitialized(libmpv: _findLibMpv());
  });

  tearDownAll(() async {
    if (token == null) return;
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('HDR 独立窗口拿到 10bit HDR 交换链', () async {
    if (token == null) {
      markTestSkipped('PILINARA_LIVE_TOKEN not set');
      return;
    }
    // 1) 取 HDR Vivid 直链
    final res = await PlayUrlGrpc.playView(
      aid: aid,
      cid: cid,
      preferCodecType: CodeType.CODE265,
      accessKey: token,
    );
    expect(res, isA<Success>(), reason: '$res');
    final model = PlayViewConverter.toPlayUrlModel((res as Success).response);
    expect(model, isNotNull);
    final hdr = model!.dash!.video!.firstWhere((e) => e.quality.code == 129);
    // ignore: avoid_print
    print('HDR source: ${hdr.width}x${hdr.height} codecs=${hdr.codecs}');

    // 2) 起独立 mpv 窗口
    final window = HdrPlayerWindow(videoUrl: hdr.baseUrl!)
      ..keepAllLogs = true;
    addTearDown(window.dispose);
    final ok = await window.start();
    expect(ok, isTrue, reason: 'HDR window failed to start');

    // 3) 等交换链日志出现（最多 20s）
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (window.isHdrOutput) break;
      await Future.delayed(const Duration(milliseconds: 250));
    }

    // ignore: avoid_print
    print('--- HDR window logs ---');
    for (final line in window.logs) {
      // ignore: avoid_print
      print(line);
    }
    expect(
      window.logs.any((e) => e.contains('R10G10B10A2_UNORM')),
      isTrue,
      reason: '未拿到 10bit 交换链',
    );
    expect(
      window.logs.any((e) => e.contains('RGB_FULL_G2084_NONE_P2020')),
      isTrue,
      reason: '未切到 HDR 色彩空间',
    );
    expect(window.isHdrOutput, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('HDR 独立窗口带音频（EDL 合成）也能拿到 10bit 交换链', () async {
    if (token == null) {
      markTestSkipped('PILINARA_LIVE_TOKEN not set');
      return;
    }
    final res = await PlayUrlGrpc.playView(
      aid: aid,
      cid: cid,
      preferCodecType: CodeType.CODE265,
      accessKey: token,
    );
    expect(res, isA<Success>(), reason: '$res');
    final model = PlayViewConverter.toPlayUrlModel((res as Success).response);
    expect(model, isNotNull);
    final hdr = model!.dash!.video!.firstWhere((e) => e.quality.code == 129);
    final audio = model.dash!.audio!.firstWhere((e) => e.id == 30280);
    // ignore: avoid_print
    print('HDR source: ${hdr.width}x${hdr.height} audio=${audio.id}');

    final window = HdrPlayerWindow(
      videoUrl: hdr.baseUrl!,
      audioUrl: audio.baseUrl!,
    )..keepAllLogs = true;
    addTearDown(window.dispose);
    expect(await window.start(), isTrue);

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (window.isHdrOutput) break;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    expect(
      window.logs.any((e) => e.contains('R10G10B10A2_UNORM')),
      isTrue,
      reason: 'EDL 合成后未拿到 10bit 交换链',
    );
    expect(window.isHdrOutput, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
```
