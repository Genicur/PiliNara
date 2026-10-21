// CDN host 替换判定：以 host 类型为准（回归测试）
//
// 实测数据（BV1FGJd63Exr / BV1j5nj68E48，24 条直链逐条验证）：
//
// | host 类型                | os 值                     | 原样 | 换 host        |
// |--------------------------|---------------------------|------|----------------|
// | *.mcdn.bilivideo.*       | mcdn / coso1bv / hwo1bv   | 200  | 0/16 全 403    |
// | *.edge.mountaintoys.cn   | mcdn                      | 200  | 8/8 全 200     |
//
// 结论：能否替换**只取决于 host 类型**，与 query 里的 `os` 无关。
// 曾经的错误假设「os=mcdn 就不可换」是错的 —— mountaintoys 也会带 os=mcdn，
// 但它可以正常换。按 os 判定会把可替换的档位也挡掉。
//
// 另：mountaintoys 换 host 后对请求头敏感（UA 必须非空且非完整 Chrome UA、
// 不能带 Referer），见 bili_media_headers 的相关测试。
import 'dart:io';

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// 实测样本：mcdn host + os=mcdn（PCDN）→ 不可换
const _mcdnOsMcdn =
    'https://xy36x249x83x75xy.mcdn.bilivideo.cn:8082/v1/resource/upgcxcode/'
    '77/18/42871751877/42871751877-1-30112.m4s'
    '?os=mcdn&platform=android&upsig=abc&uparams=e,os,platform,upsig';

/// 实测样本：mcdn host + os=coso1bv → **同样不可换**（关键回归点）
const _mcdnOsCdn =
    'https://xy58x222x42x16xy.mcdn.bilivideo.cn:8082/v1/resource/upgcxcode/'
    '77/18/42871751877/42871751877-1-30112.m4s'
    '?os=coso1bv&platform=android&upsig=abc&uparams=e,os,platform,upsig';

/// 实测样本：mountaintoys host + os=mcdn → **可以换**（与原假设相反）
const _mtOsMcdn =
    'https://b-baaa45b86fg3tch6cg12ggiub844c.edge.mountaintoys.cn:4483/'
    'upgcxcode/77/18/42871751877/42871751877-1-30112.m4s'
    '?os=mcdn&og=cos&platform=android&gen=playurlv3&build=7320200'
    '&upsig=06e909ec48d8180a0c92d9ec3547014c'
    '&uparams=e,os,mid,deadline,uipk,platform,gen,og,oi,trid,nbs';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('pilinara_pcdn_test');
    Hive.init(dir.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
  });

  tearDownAll(() async {
    await Hive.close();
  });

  group('mcdn host 一律不可换 host（换则 403）', () {
    test('os=mcdn', () {
      final out = VideoUtils.getCdnUrl(
        [_mcdnOsMcdn],
        defaultCDNService: CDNService.hw,
      );
      expect(Uri.parse(out).host, 'xy36x249x83x75xy.mcdn.bilivideo.cn');
    });

    test('os=coso1bv 也不能换（os 不是判据）', () {
      final out = VideoUtils.getCdnUrl(
        [_mcdnOsCdn],
        defaultCDNService: CDNService.hw,
      );
      expect(
        Uri.parse(out).host,
        'xy58x222x42x16xy.mcdn.bilivideo.cn',
        reason: 'mcdn host 即使 os 指向别的 CDN，换 host 仍会 403',
      );
    });

    test('自定义节点也不能换', () {
      final out = VideoUtils.getCdnUrl(
        [_mcdnOsCdn],
        customHost: 'upos-sz-mirrorali.bilivideo.com',
      );
      expect(Uri.parse(out).host, 'xy58x222x42x16xy.mcdn.bilivideo.cn');
    });
  });

  group('mountaintoys host 可以换 host（实测 206）', () {
    test('os=mcdn 也照样可换', () {
      final out = VideoUtils.getCdnUrl(
        [_mtOsMcdn],
        defaultCDNService: CDNService.hw,
      );
      expect(
        Uri.parse(out).host,
        CDNService.hw.host,
        reason: 'mountaintoys 换 host 实测 200，不应被 os=mcdn 误挡',
      );
    });

    test('换 host 后必须丢弃 :4483 端口', () {
      final out = VideoUtils.getCdnUrl(
        [_mtOsMcdn],
        defaultCDNService: CDNService.hw,
      );
      expect(Uri.parse(out).hasPort, isFalse);
      expect(out.contains(':4483'), isFalse);
    });

    test('换 host 后 query（含 upsig/os）原样保留', () {
      final out = VideoUtils.getCdnUrl(
        [_mtOsMcdn],
        defaultCDNService: CDNService.hw,
      );
      final before = Uri.parse(_mtOsMcdn);
      final after = Uri.parse(out);
      expect(after.path, before.path);
      expect(after.queryParameters['upsig'], before.queryParameters['upsig']);
      expect(after.queryParameters['os'], before.queryParameters['os']);
    });
  });

  group('混合批次优先选可替换项', () {
    test('同时含 mcdn 与 mountaintoys 时，选后者并替换', () {
      final out = VideoUtils.getCdnUrl(
        [_mcdnOsMcdn, _mtOsMcdn],
        defaultCDNService: CDNService.hw,
      );
      expect(Uri.parse(out).host, CDNService.hw.host);
    });

    test('全部为 mcdn 时，原样返回第一条', () {
      final out = VideoUtils.getCdnUrl(
        [_mcdnOsMcdn, _mcdnOsCdn],
        defaultCDNService: CDNService.hw,
      );
      expect(Uri.parse(out).host, 'xy36x249x83x75xy.mcdn.bilivideo.cn');
    });
  });
}
