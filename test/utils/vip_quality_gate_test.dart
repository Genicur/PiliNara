// 「仅 VIP 画质使用试用通道」的判定逻辑（回归测试）
//
// 用户要求：开启「无限试用会员画质」时，只有会员画质档位走 APP gRPC 通道，
// 非会员画质走上游原有 Web 通道（这样 CDN 设置对普通视频仍然生效）。
//
// 判定依据优先用服务端门控标记（Web 的 limit_watch_reason / APP 的 need_vip），
// 拿不到标记时回退到档位 code 的静态表。
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:flutter_test/flutter_test.dart';

FormatItem _fmt(int quality, {int? limitReason, bool? needVip}) => FormatItem(
      quality: quality,
      newDesc: 'q$quality',
      displayDesc: 'q$quality',
      limitWatchReason: limitReason,
      needVip: needVip,
    );

void main() {
  group('FormatItem.isVipLocked', () {
    test('limit_watch_reason == 1 视为会员档位', () {
      expect(_fmt(120, limitReason: 1).isVipLocked, isTrue);
    });

    test('limit_watch_reason == 0 视为非会员档位', () {
      expect(_fmt(80, limitReason: 0).isVipLocked, isFalse);
    });

    test('need_vip == true 视为会员档位（APP 通道）', () {
      expect(_fmt(120, needVip: true).isVipLocked, isTrue);
    });

    test('两者都没有时不判定为会员档位', () {
      expect(_fmt(80).isVipLocked, isFalse);
    });
  });

  group('VideoQuality.isVipQuality —— 有服务端标记时以标记为准', () {
    test('服务端标记 1080P(80) 需会员 → 判为会员档', () {
      // 构造一个反常但可能的场景：服务端把 80 标成会员门控
      final formats = [_fmt(80, limitReason: 1)];
      expect(VideoQuality.isVipQuality(80, formats), isTrue);
    });

    test('服务端标记 4K(120) 不需会员 → 判为非会员档', () {
      final formats = [_fmt(120, limitReason: 0)];
      expect(VideoQuality.isVipQuality(120, formats), isFalse);
    });

    test('APP 的 need_vip 标记同样生效', () {
      final formats = [_fmt(129, needVip: true)];
      expect(VideoQuality.isVipQuality(129, formats), isTrue);
    });
  });

  group('VideoQuality.isVipQuality —— 无标记时用静态兜底表', () {
    test('4K / 8K / HDR / 杜比视界 / 1080P+ / 1080P60 / 智能修复 都是会员档', () {
      for (final vq in [
        VideoQuality.hdrVivid,
        VideoQuality.super8k,
        VideoQuality.dolbyVision,
        VideoQuality.hdr,
        VideoQuality.super4K,
        VideoQuality.high108060,
        VideoQuality.high1080plus,
        VideoQuality.superResolution,
      ]) {
        expect(VideoQuality.isVipQuality(vq.code), isTrue,
            reason: '${vq.desc}(${vq.code}) 应判为会员档');
      }
    });

    test('1080P 及以下都是非会员档', () {
      for (final vq in [
        VideoQuality.high1080,
        VideoQuality.high72060,
        VideoQuality.high720,
        VideoQuality.clear480,
        VideoQuality.fluent360,
        VideoQuality.speed240,
      ]) {
        expect(VideoQuality.isVipQuality(vq.code), isFalse,
            reason: '${vq.desc}(${vq.code}) 应判为非会员档');
      }
    });
  });
}
