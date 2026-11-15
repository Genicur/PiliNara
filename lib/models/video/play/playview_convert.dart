import 'package:PiliPlus/grpc/bilibili/app/playurl/v1.pb.dart';
import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';

/// 把 APP 端 PlayView 响应转换成 UI / 播放器 / 下载器共用的 [PlayUrlModel]。
///
/// 两条硬性规则：
///
/// 1. **不过滤 `needVip`**：服务端对非大会员也会下发 4K/1080P+ 的真实直链
///    （`needVip=true` 但 `intact=true`，URL 可正常播放）。
///
/// 2. **丢弃 HDR 类档位**：本项目播放链路只有 8bit 输出，HDR Vivid(129)、
///    HDR 真彩(125)、杜比视界(126) 播出来会明显发灰/偏色，因此直接不进菜单。
///    8K(127) 保留——它不是 HDR，只是分辨率高。
abstract final class PlayViewConverter {
  /// 需要排除的 HDR / 杜比档位。
  ///
  /// 注意：这里排的是**画质档位**，不是编码。HEVC/AV1 编码的普通 4K 档位
  /// 仍然保留，只有这三个 HDR 专档被剔除。
  static const Set<int> hdrQualities = {
    129, // HDR Vivid
    125, // HDR 真彩
    126, // 杜比视界
  };

  /// 该档位是否属于 HDR 类（播放器不支持，应排除）。
  static bool isHdrQuality(int quality) => hdrQualities.contains(quality);

  /// 只保留 B 站自家的 CDN 直链，避免把第三方回源地址交给 CDN 替换逻辑。
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
  /// HDR/8K 类档位只在 HEVC 或 AV1 下才带直链：首选 AVC 时它们只有
  /// StreamInfo。调用方据此补发一次其它编码的请求并合并。
  static Set<int> missingDashQualities(PlayViewReply reply) {
    if (!reply.hasVideoInfo()) return const {};
    final missing = <int>{};
    for (final stream in reply.videoInfo.streamList) {
      if (stream.hasDashVideo()) continue;
      final quality = stream.hasStreamInfo() ? stream.streamInfo.quality : 0;
      if (quality > 0 && !isHdrQuality(quality)) missing.add(quality);
    }
    return missing;
  }

  static PlayUrlModel? toPlayUrlModel(PlayViewReply reply) =>
      toPlayUrlModelFromReplies([reply]);

  /// 把多次 PlayView 响应（同一视频、不同 `preferCodecType`）合并成一个模型。
  static PlayUrlModel? toPlayUrlModelFromReplies(
    Iterable<PlayViewReply> replies,
  ) {
    int duration = 0;
    String format = '';
    int videoCodecid = 0;

    // key = quality * 100 + codecid，同一档位的不同编码各留一条
    final videoMap = <int, Map<String, dynamic>>{};
    final audioMap = <int, Map<String, dynamic>>{};
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

        // HDR 类档位不进入模型：播放器无法正确输出，列出来只会让人选到坏档
        if (isHdrQuality(quality)) continue;

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

      // APP 通道独有的特殊音轨：
      // * DolbyItem.audio 是 DashItem 列表（杜比全景声，可能多条）
      // * LossLessItem.audio 是单条 DashItem（Hi-Res 无损）
      void addAudio(DashItem item) {
        if (!item.hasBaseUrl()) return;
        if (audioMap.containsKey(item.id)) return;
        audioMap[item.id] = {
          'id': item.id,
          'baseUrl': item.baseUrl,
          'backupUrl': _filterUrls(item.backupUrl),
          'bandwidth': item.bandwidth,
          'codecid': item.codecid,
          'frameRate': '',
          'width': 1,
          'height': 1,
          'mime_type': 'audio/mp4',
        };
      }

      if (info.hasDolby()) {
        for (final item in info.dolby.audio) {
          addAudio(item);
        }
      }
      if (info.hasLossLessItem() && info.lossLessItem.hasAudio()) {
        addAudio(info.lossLessItem.audio);
      }
    }

    if (videoMap.isEmpty) return null;

    // 降序，保证 dash.video.first 是最高画质
    final videos = videoMap.values.toList()
      ..sort((a, b) {
        final byId = (b['id'] as int).compareTo(a['id'] as int);
        return byId != 0
            ? byId
            : (b['codecid'] as int).compareTo(a['codecid'] as int);
      });

    final qualities = qualityCodecs.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    final formats = [
      for (final quality in qualities)
        {
          'quality': quality,
          'format': qualityDesc[quality]!['format'],
          'new_description': qualityDesc[quality]!['new_description'],
          'display_desc': qualityDesc[quality]!['display_desc'],
          'codecs': qualityCodecs[quality]!,
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
