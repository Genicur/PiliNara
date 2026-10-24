import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/grpc/bilibili/app/playurl/v1.pb.dart';
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
    final qualityDesc = <int, Map<String, dynamic>>{};

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
            // 服务端标注该档位需要大会员（APP 侧对应 limit_watch_reason == 1）。
            // 用于「仅 VIP 画质走试用通道」的分流判定。
            'need_vip': si?.needVip ?? false,
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
          // 交给 FormatItem.isVipLocked，供「仅 VIP 画质走试用通道」判定
          'need_vip': qualityDesc[quality]!['need_vip'],
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
