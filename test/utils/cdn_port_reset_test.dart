// CDN 替换必须重置端口（回归测试）
//
// 事故：B 站 APP 通道下发的直链常见形如
//   https://xxx.edge.mountaintoys.cn:4483/upgcxcode/...
// 用 Uri.replace(host:) 换 host 时，Dart 会保留 :4483，于是去请求
//   https://upos-sz-mirrorhw.bilivideo.com:4483/...
// 而镜像节点只在默认端口监听 → 连接失败 → 播放卡死，必须手动换回。
//
// 实测：同一 URL 保留 :4483 = URLError；去掉端口后 = 206。
// 本测试锁定「替换 host 后必须没有非标准端口」这一约束。
import 'dart:io';

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// 实测样本：带 :4483 端口的 APP 直链（mountaintoys，可替换型）
const _appUrlWithPort =
    'https://b-baaa45b86fg3tch6cg12ggiub844c.edge.mountaintoys.cn:4483/'
    'upgcxcode/77/18/42871751877/42871751877-1-30112.m4s'
    '?os=mcdn&og=cos&platform=android&gen=playurlv3&build=7320200'
    '&upsig=5b283c89e204923604dfc6e7ebfcd8a1'
    '&uparams=e,deadline,trid,mid,gen,os,og,platform,nbs,oi,uipk';

/// 实测样本：无端口的 Web 直链（对照）
const _webUrlNoPort =
    'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/27/92/42479389227/'
    '42479389227-1-30080.m4s?platform=pc&os=coso1bv&gen=playurlv3'
    '&upsig=471600e810826b46bedf1bedf7abd7df';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('pilinara_port_test');
    Hive.init(dir.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
  });

  tearDownAll(() async {
    await Hive.close();
  });

  group('替换 host 时必须丢弃原 URL 的非标准端口', () {
    test('APP 直链 :4483 + 所选 CDN → 结果无端口', () {
      for (final service in [CDNService.hw, CDNService.cos, CDNService.ali]) {
        final out = VideoUtils.getCdnUrl(
          [_appUrlWithPort],
          defaultCDNService: service,
        );
        final uri = Uri.parse(out);
        expect(uri.host, service.host, reason: 'host 应被替换为 ${service.host}');
        expect(
          uri.port,
          443,
          reason: '端口必须重置为 https 默认 443，实际得到 ${uri.port}',
        );
        expect(uri.hasPort, isFalse, reason: '不应显式携带非默认端口');
        expect(out.contains(':4483'), isFalse,
            reason: '结果里不得残留 :4483');
      }
    });

    test('APP 直链 :4483 + 自定义节点 → 结果无端口', () {
      const custom = 'upos-sz-mirroralio1.bilivideo.com';
      final out = VideoUtils.getCdnUrl([_appUrlWithPort], customHost: custom);
      final uri = Uri.parse(out);
      expect(uri.host, custom);
      expect(uri.port, 443);
      expect(uri.hasPort, isFalse);
      expect(out.contains(':4483'), isFalse);
    });

    test('替换 host 后路径与签名参数保持不变', () {
      final out = VideoUtils.getCdnUrl(
        [_appUrlWithPort],
        defaultCDNService: CDNService.hw,
      );
      final before = Uri.parse(_appUrlWithPort);
      final after = Uri.parse(out);
      expect(after.path, before.path);
      expect(after.queryParameters['upsig'], before.queryParameters['upsig']);
      expect(after.queryParameters['uparams'], before.queryParameters['uparams']);
      expect(after.queryParameters['platform'], 'android');
    });

    test('原本无端口的 Web 直链替换后仍无端口', () {
      final out = VideoUtils.getCdnUrl(
        [_webUrlNoPort],
        defaultCDNService: CDNService.ali,
      );
      final uri = Uri.parse(out);
      expect(uri.host, CDNService.ali.host);
      expect(uri.port, 443);
    });

    test('候选队列里不得出现带非标准端口的镜像地址', () {
      final candidates = VideoUtils.cdnCandidates(
        [_appUrlWithPort],
        defaultCDNService: CDNService.hw,
      );
      expect(candidates, isNotEmpty);
      final first = Uri.parse(candidates.first);
      expect(first.host, CDNService.hw.host);
      expect(first.port, 443);
    });
  });
}
