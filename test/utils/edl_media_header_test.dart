// EDL 媒体源的头判定（回归测试）
//
// 事故：BV1FGJd63Exr 选 hw 后黑屏。诊断确认：
//   最终 videoUrl = upos-sz-mirrorhw.bilivideo.com  os=mcdn  platform=android
//   最终 audioUrl = upos-sz-mirrorhw.bilivideo.com  os=coso1bv platform=pc
// 播放器把两者拼成 mpv EDL 字符串：
//   edl://!no_chapters;%650%https://...platform=android;!new_stream;...%719%https://...
//
// 原实现对所有媒体源直接调用 isAndroidPlatformUrl(url)：
//   对 `edl://...` 这种整串，Uri.tryParse 拿不到 query（platform 为 null），
//   于是判定为「非 APP 直链」→ 用 Web 头（Chrome UA + Referer）→ APP 直链 403。
//
// 实测：mountaintoys 直链换 host 后，
//   UA=Mozilla/5.0 + 无 Referer  → 200
//   UA=完整 Chrome + Referer     → 403
//
// 修复：从 EDL 里拆出内嵌 URL，只要含 platform=android 就用 APP 头。
import 'package:PiliPlus/http/bili_media_headers.dart';
import 'package:flutter_test/flutter_test.dart';

const _androidUrl =
    'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/77/18/42871751877/'
    '42871751877-1-30112.m4s?os=mcdn&platform=android&upsig=abc';

const _webUrl =
    'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/27/92/42479389227/'
    '42479389227-1-30080.m4s?platform=pc&os=coso1bv&upsig=abc';

void main() {
  group('普通 URL 的头判定', () {
    test('platform=android → APP 头（Mozilla/5.0 + 空 Referer）', () {
      final (ua, referer) = BiliMediaHeaders.forPlayer(_androidUrl);
      expect(ua, 'Mozilla/5.0');
      expect(referer, '');
    });

    test('platform=pc → Web 头（含 Referer）', () {
      final (ua, referer) = BiliMediaHeaders.forPlayer(_webUrl);
      expect(referer, contains('bilibili.com'));
      expect(ua, isNot('Mozilla/5.0'));
    });
  });

  group('EDL 拼接媒体源的头判定', () {
    String edlOf(String video, String audio) =>
        'edl://!no_chapters;%${video.length}%$video;'
        '!new_stream;!no_chapters;%${audio.length}%$audio';

    test('视频为 APP 直链 → 整串走 APP 头', () {
      final src = edlOf(_androidUrl, _webUrl);
      final (ua, referer) = BiliMediaHeaders.forPlayer(src);
      expect(ua, 'Mozilla/5.0',
          reason: 'EDL 内含 platform=android 时必须用 APP UA，否则 CDN 403');
      expect(referer, '');
    });

    test('视频 + 音频都是 APP 直链 → APP 头', () {
      final src = edlOf(_androidUrl, _androidUrl);
      final (ua, referer) = BiliMediaHeaders.forPlayer(src);
      expect(ua, 'Mozilla/5.0');
      expect(referer, '');
    });

    test('视频与音频都是 Web 直链 → Web 头', () {
      final src = edlOf(_webUrl, _webUrl);
      final (ua, referer) = BiliMediaHeaders.forPlayer(src);
      expect(referer, contains('bilibili.com'));
    });

    test('下载器同样能识别 EDL 里的 APP 直链', () {
      final src = edlOf(_androidUrl, _webUrl);
      final headers = BiliMediaHeaders.forDownload(src);
      expect(headers['user-agent'], 'Mozilla/5.0');
      expect(headers.containsKey('referer'), isFalse,
          reason: 'APP 直链带 Referer 会 403');
    });
  });
}
