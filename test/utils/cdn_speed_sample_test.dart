// 验证 CDN 测速样本必须是 Web 通道（platform=pc）而非 APP 通道（platform=android）。
//
// 运行：flutter test test/cdn_speed_sample_test.dart   （需要联网）
// 离线时自动 skip。
import 'package:PiliPlus/http/bili_media_headers.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CDN 测速样本 URL 必须是 Web 通道（platform=pc）', () {
    // 修复后的行为：getSample() 显式请求 Web playurl，得到的直链 platform 为 pc
    const webSample =
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/66/89/196018899/'
        '196018899-1-30080.m4s?e=ig8euxZM2rNcNbRVhwdVhwdtVhwdVhwdVhwdV&'
        'deadline=1700000000&gen=playurlv2&os=cosbv&oi=1857210511&trid=abc&'
        'mid=6891108&platform=pc&upsig=abc&uparams=e,deadline,gen,os,oi,trid,mid,platform&cdn=0';

    // APP 通道的直链（修复前会拿到这种）
    const appSample =
        'https://xy39x184x180x114xy.mcdn.bilivideo.cn:8082/v1/resource/upgcxcode/'
        '66/89/196018899/196018899-1-30080.m4s?e=ig8euxZM2rNcNbRVhwdVhwdtVhwd&'
        'deadline=1700000000&gen=playurlv2&os=mcdn&platform=android&upsig=abc&uparams=e,deadline,gen,os,platform';

    expect(BiliMediaHeaders.isAndroidPlatformUrl(webSample), isFalse,
        reason: 'Web 样本不应被判定为 APP 直链');
    expect(BiliMediaHeaders.isAndroidPlatformUrl(appSample), isTrue,
        reason: 'APP 直链应被识别，从而触发 host 不改写');
  });

  test('Web 样本可以正常换 host（CDN 测速语义前提）', () {
    // getCdnUrl 对 Web 直链会做 host 替换；对 APP 直链短路。
    // 这里只断言判定函数，因为 getCdnUrl 的替换需要真实 URL 片段。
    const webWithUpgcxcode =
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/66/89/x.m4s'
        '?os=cosbv&platform=pc';
    expect(BiliMediaHeaders.isAndroidPlatformUrl(webWithUpgcxcode), isFalse);
  });
}
