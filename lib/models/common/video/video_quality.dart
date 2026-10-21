import 'package:PiliPlus/models/video/play/url.dart' show FormatItem;

final class VideoQuality {
  final int code;
  final String desc;
  final String shortDesc;

  const VideoQuality(this.code, this.desc, this.shortDesc);

  @override
  String toString() => 'code: $code, desc: $desc, shortDesc: $shortDesc';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is VideoQuality) {
      return code == other.code;
    }
    return false;
  }

  @override
  int get hashCode => code.hashCode;

  static const VideoQuality hdrVivid = .new(129, 'HDR Vivid', 'HDR Vivid');
  static const VideoQuality super8k = .new(127, '8K 超高清', '8K');
  static const VideoQuality dolbyVision = .new(126, '杜比视界', '杜比');
  static const VideoQuality hdr = .new(125, 'HDR 真彩', 'HDR');
  static const VideoQuality super4K = .new(120, '4K 超高清', '4K');
  static const VideoQuality high108060 = .new(116, '1080P 60帧', '1080P60');
  static const VideoQuality high1080plus = .new(112, '1080P 高码率', '1080P+');
  static const VideoQuality superResolution = .new(100, '智能修复', '智能修复');
  static const VideoQuality high1080 = .new(80, '1080P 高清', '1080P');
  static const VideoQuality high72060 = .new(74, '720P 60帧', '720P60');
  static const VideoQuality high720 = .new(64, '720P 准高清', '720P');
  static const VideoQuality clear480 = .new(32, '480P 标清', '480P');
  static const VideoQuality fluent360 = .new(16, '360P 流畅', '360P');
  static const VideoQuality speed240 = .new(6, '240P 极速', '240P');

  static const List<VideoQuality> values = [
    hdrVivid,
    super8k,
    dolbyVision,
    hdr,
    super4K,
    high108060,
    high1080plus,
    superResolution,
    high1080,
    high72060,
    high720,
    clear480,
    fluent360,
    speed240,
  ];

  static final _codeMap = {for (final i in values) i.code: i};

  factory VideoQuality.fromId(int id, String idStr) =>
      VideoQuality(id, idStr, idStr);

  factory VideoQuality.fromCode(int code) =>
      _codeMap[code] ?? .fromId(code, code.toString());

  static VideoQuality? safeFromCode(int code) => _codeMap[code];

  /// 该画质档位是否需要大会员（非会员走 Web 通道会被封顶/拒绝）。
  ///
  /// 优先使用服务端下发的门控标记 `support_formats[].limit_watch_reason == 1`
  /// （APP 通道对应 `StreamInfo.need_vip`），这是最准确的依据；
  /// 拿不到标记时回退到档位 code 的静态判定。
  ///
  /// 用途：「无限试用会员画质」开关打开时，**只有**这些档位才走 APP gRPC 通道，
  /// 其余档位走上游原有的 Web 通道（用户要求：仅 VIP 画质使用试用方法）。
  static bool isVipQuality(int code, [List<FormatItem>? formats]) {
    if (formats != null && formats.isNotEmpty) {
      for (final f in formats) {
        if (f.quality == code) return f.isVipLocked;
      }
    }
    return _isVipQualityByCode(code);
  }

  /// 无服务端标记时的静态兜底判定。
  ///
  /// 显式列举而不用 code 大小比较，因为「智能修复」(100) 的 code 小于
  /// 1080P+ (112) 但同样属于需要会员的特殊档位。
  static bool _isVipQualityByCode(int code) =>
      code == hdrVivid.code ||      // 129 HDR Vivid
      code == super8k.code ||       // 127 8K
      code == dolbyVision.code ||   // 126 杜比视界
      code == hdr.code ||           // 125 HDR 真彩
      code == super4K.code ||       // 120 4K
      code == high108060.code ||    // 116 1080P 60帧
      code == high1080plus.code ||  // 112 1080P 高码率
      code == superResolution.code; // 100 智能修复

  factory VideoQuality.fromFormat(int code, List<FormatItem>? formats) {
    if (formats != null && formats.isNotEmpty) {
      for (final format in formats) {
        if (format.quality == code) {
          try {
            return VideoQuality(
              code,
              format.newDesc!,
              format.displayDesc!,
            );
          } catch (_) {}
        }
      }
    }

    return .fromCode(code);
  }
}
