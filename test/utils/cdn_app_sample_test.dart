// 视频页入口的 CDN 测速必须也用 Web 样本（回归测试）
//
// 背景：从视频页点「CDN 设置」时，调用方会把当前播放流作为 sample 传进来。
// 开启「无限试用会员画质」后该流来自 APP 通道（platform=android），
// 若直接拿它测速，会因为：
//   · PCDN 型换 host 必 403
//   · 可替换型也要求不带 Referer，而测速器固定带 Web 头
// 导致每一行都显示「此视频可能无法替换为该CDN」。
//
// 本测试锁定「传入 APP 样本时应被识别并丢弃」这一行为。
import 'package:PiliPlus/http/bili_media_headers.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:flutter_test/flutter_test.dart';

VideoItem _item({String? base, List<String>? backup}) => VideoItem(
      id: 120,
      baseUrl: base,
      backupUrl: backup,
      codecs: 'hev1.1.6.L120.90',
      quality: VideoQuality.hdr,
    );

const _appUrl =
    'https://upos-sz-mirror08ct.bilivideo.com/upgcxcode/43/46/36532584643/'
    '36532584643_hr1-1-100170.m4s?os=302ppio&platform=android&upsig=abc';

const _webUrl =
    'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/35/41/42860284135/'
    '42860284135-1-30032.m4s?os=cos&platform=pc&upsig=abc';

void main() {
  group('APP 样本识别（决定是否退回 Web 样本）', () {
    test('platform=android 的 baseUrl 应被判定为 APP 样本', () {
      final item = _item(base: _appUrl);
      final urls = <String>[?item.baseUrl, ...?item.backupUrl];
      expect(urls.any(BiliMediaHeaders.isAndroidPlatformUrl), isTrue);
    });

    test('platform=pc 的 baseUrl 不应被判定为 APP 样本', () {
      final item = _item(base: _webUrl);
      final urls = <String>[?item.baseUrl, ...?item.backupUrl];
      expect(urls.any(BiliMediaHeaders.isAndroidPlatformUrl), isFalse);
    });

    test('baseUrl 为 Web、backupUrl 混入 APP 直链时也应识别为 APP 样本', () {
      final item = _item(base: _webUrl, backup: [_appUrl]);
      final urls = <String>[?item.baseUrl, ...?item.backupUrl];
      expect(urls.any(BiliMediaHeaders.isAndroidPlatformUrl), isTrue);
    });

    test('无任何 URL 时不会误判', () {
      final item = _item();
      final urls = <String>[?item.baseUrl, ...?item.backupUrl];
      expect(urls.any(BiliMediaHeaders.isAndroidPlatformUrl), isFalse);
    });
  });
}
