// APP 通道直链的 CDN 替换判定（回归测试）
//
// 背景：早期实现按 `platform=android` 整类跳过 CDN 替换，导致开启「无限试用
// 会员画质」后 CDN 设置完全无效。实测（见 docs/cdn-setting-vs-unlimited-vip-quality.md）
// 证明：PCDN 型（mcdn + /vN/resource/）换 host 必 403，但 upos/mountaintoys 型
// 换 host 仍 206，应当支持替换。
//
// 本测试锁定这套分类，防止再次退回"整类跳过"或误伤可替换节点。
import 'dart:io';

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// 实测样本：PCDN 锁定节点（mcdn host + /vN/resource/ 路径）
const _pcdnUrl =
    'https://xy119x188x217x14xy.mcdn.bilivideo.cn:8082/v1/resource/upgcxcode/'
    '35/41/42860284135/42860284135-1-100029.m4s'
    '?e=ig8euxZM2rNcNbdlhoNvNC8BqJIzNbfq&gen=playurlv2&os=mcdn'
    '&platform=android&mid=6891108&upsig=abc&uparams=e,gen,os,platform,mid';

/// 实测样本：用户从其它 APP 读到的真实 HDR Vivid 直链（upos 型，可替换）
const _uposUrl =
    'http://upos-sz-302ppio.bilivideo.com/upgcxcode/43/46/36532584643/'
    '36532584643_hr1-1-100170.m4s'
    '?nbs=1&gen=playurlv3&os=302ppio&platform=android&mid=6891108'
    '&upsig=6f203bd32e6dc185aabbc8f24ef6d52f'
    '&uparams=e,nbs,gen,os,platform,mid&bvc=vod';

/// 实测样本：mountaintoys 型（APP 通道下发，可替换）
const _mountaintoysUrl =
    'https://h2i438c.edge.mountaintoys.cn:4483/upgcxcode/66/89/196018899/'
    '196018899-1-30080.m4s?gen=playurlv2&os=mcdn&platform=android&upsig=abc';

/// Web 通道直链：不受 APP 判定影响，应保持原行为
const _webUrl =
    'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/35/41/42860284135/'
    '42860284135-1-30032.m4s?os=cosbv&platform=pc&upsig=abc';

void main() {
  // VideoUtils 的静态字段会在首次访问时读 Pref（依赖 GStorage.setting），
  // 因此需要先起一个临时 Hive 目录，避免 LateInitializationError。
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('pilinara_cdn_test');
    Hive.init(dir.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
  });

  tearDownAll(() async {
    await Hive.close();
  });

  group('APP 通道直链：PCDN 型必须原样返回（换 host 会 403）', () {
    test('mcdn + /vN/resource/ 路径：任何 CDN 选择都不替换 host', () {
      for (final service in [
        CDNService.ali,
        CDNService.cos,
        CDNService.hw,
        CDNService.cosov,
      ]) {
        final out = VideoUtils.getCdnUrl(
          [_pcdnUrl],
          defaultCDNService: service,
        );
        expect(
          Uri.parse(out).host,
          'xy119x188x217x14xy.mcdn.bilivideo.cn',
          reason: 'PCDN 锁定节点不应被替换为 ${service.host}',
        );
      }
    });

    test('PCDN 型 + 自定义节点：同样不替换', () {
      final out = VideoUtils.getCdnUrl(
        [_pcdnUrl],
        customHost: 'upos-sz-mirrorali.bilivideo.com',
      );
      expect(
        Uri.parse(out).host,
        'xy119x188x217x14xy.mcdn.bilivideo.cn',
      );
    });
  });

  group('APP 通道直链：upos / mountaintoys 型可以替换', () {
    test('upos 型（真实 HDR 直链）按所选 CDN 替换 host', () {
      final out = VideoUtils.getCdnUrl(
        [_uposUrl],
        defaultCDNService: CDNService.ali,
      );
      expect(Uri.parse(out).host, CDNService.ali.host);
      // 路径与签名参数必须保持不变，否则会 403
      final before = Uri.parse(_uposUrl);
      final after = Uri.parse(out);
      expect(after.path, before.path);
      expect(after.queryParameters['upsig'], before.queryParameters['upsig']);
      expect(after.queryParameters['uparams'], before.queryParameters['uparams']);
    });

    test('upos 型 + 自定义节点：替换到自定义 host', () {
      const custom = 'upos-sz-mirrorhw.bilivideo.com';
      final out = VideoUtils.getCdnUrl([_uposUrl], customHost: custom);
      expect(Uri.parse(out).host, custom);
    });

    test('mountaintoys 型按所选 CDN 替换 host', () {
      final out = VideoUtils.getCdnUrl(
        [_mountaintoysUrl],
        defaultCDNService: CDNService.cos,
      );
      expect(Uri.parse(out).host, CDNService.cos.host);
    });
  });

  group('混合批次与边界', () {
    test('PCDN 与 upos 混合时，优先替换可替换的那条', () {
      final out = VideoUtils.getCdnUrl(
        [_pcdnUrl, _uposUrl],
        defaultCDNService: CDNService.hw,
      );
      expect(
        Uri.parse(out).host,
        CDNService.hw.host,
        reason: '不应因为第一条是 PCDN 就整批放弃替换',
      );
    });

    test('未选择 CDN（baseUrl）时原样返回第一条', () {
      final out = VideoUtils.getCdnUrl(
        [_uposUrl],
        defaultCDNService: CDNService.baseUrl,
      );
      expect(out, _uposUrl);
    });

    test('Web 通道直链行为不变', () {
      final out = VideoUtils.getCdnUrl(
        [_webUrl],
        defaultCDNService: CDNService.ali,
      );
      // Web upos 型同样可替换
      expect(Uri.parse(out).host, CDNService.ali.host);
    });
  });
}
