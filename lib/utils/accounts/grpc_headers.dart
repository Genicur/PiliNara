import 'dart:convert';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/metadata.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/device.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/fawkes.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/locale.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/network.pb.dart' as network;
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/utils.dart';

abstract final class GrpcHeaders {
  static const _build = 2001100;
  static const _versionName = '2.0.1';
  static const _biliChannel = 'master';
  static const _mobiApp = 'android_hd';
  static const _device = 'android';

  static String get _traceId => Constants.traceId;
  static String get _sessionId => Utils.generateRandomString(8);

  static final Map<String, String> _base = {
    'grpc-encoding': 'gzip',
    'gzip-accept-encoding': 'gzip,identity',
    'user-agent': Constants.userAgent,
    'x-bili-gaia-vtoken': '',
    'x-bili-aurora-zone': '',
    'x-bili-trace-id': _traceId,
    'bili-http-engine': 'cronet',
    // 'te': 'trailers', // dio not supported
    'x-bili-network-bin': base64Encode(
      network.Network(type: network.NetworkType.WIFI).writeToBuffer(),
    ),
    'x-bili-locale-bin': base64Encode(
      Locale(
        cLocale: LocaleIds(language: 'zh', region: 'CN', script: 'Hans'),
        sLocale: LocaleIds(language: 'zh', region: 'CN', script: 'Hans'),
        timezone: 'Asia/Shanghai',
      ).writeToBuffer(),
    ),
    'x-bili-exps-bin': '',
  };

  static String get fawkes => base64Encode(
    FawkesReq(
      appkey: _mobiApp,
      env: 'prod',
      sessionId: _sessionId,
    ).writeToBuffer(),
  );

  /// PlayView 专用指纹。
  ///
  /// 实测（2026-11-15，真机 + 复刻请求双重验证）：服务端按
  /// `x-bili-device-bin` / `x-bili-metadata-bin` 里的 `mobiApp` + `build`
  /// 决定是否下发 4K/1080P+ 的 dash 直链，必须同时满足：
  ///   * `mobi_app = android`（**不能**是全局指纹用的 `android_hd`）；
  ///   * `build >= 6400000`（这里用 9130500 / 9.13.0，与 ReVanced 版一致）。
  /// 不满足时高画质档位只有 StreamInfo、没有 DashVideo（播放会黑屏）。
  static Map<String, String> newPlayViewHeaders({
    required String? accessKey,
    required String buvid,
  }) {
    const build = 9130500;
    const versionName = '9.13.0';
    const mobiApp = 'android';
    return {
      ..._base,
      'user-agent':
          'Mozilla/5.0 BiliDroid/$versionName (bbcallen@gmail.com) os/android '
          'model/android mobi_app/$mobiApp build/$build channel/master '
          'innerVer/$build osVer/15 network/2',
      'buvid': buvid,
      'x-bili-fawkes-req-bin': base64Encode(
        FawkesReq(
          appkey: 'android64',
          env: 'prod',
          sessionId: _sessionId,
        ).writeToBuffer(),
      ),
      'x-bili-device-bin': base64Encode(
        Device(
          appId: 5,
          build: build,
          buvid: buvid,
          mobiApp: mobiApp,
          platform: _device,
          channel: _biliChannel,
          brand: _device,
          model: _device,
          osver: '15',
          versionName: versionName,
        ).writeToBuffer(),
      ),
      'x-bili-metadata-bin': base64Encode(
        Metadata(
          accessKey: accessKey,
          mobiApp: mobiApp,
          device: _device,
          build: build,
          channel: _biliChannel,
          buvid: buvid,
          platform: _device,
        ).writeToBuffer(),
      ),
      if (accessKey != null && accessKey.isNotEmpty)
        'authorization': 'identify_v1 $accessKey',
    };
  }

  static Map<String, String> newHeaders(Account account) {
    return {
      ..._base,
      if (account.accessKey != null)
        'authorization': 'identify_v1 ${account.accessKey}',
      'buvid': account.buvid,
      'x-bili-fawkes-req-bin': fawkes,
      'x-bili-device-bin': base64Encode(
        Device(
          appId: 5,
          build: _build,
          buvid: account.buvid,
          mobiApp: _mobiApp,
          platform: _device,
          channel: _biliChannel,
          brand: _device,
          model: _device,
          osver: '15',
          versionName: _versionName,
        ).writeToBuffer(),
      ),
      'x-bili-metadata-bin': base64Encode(
        Metadata(
          accessKey: account.accessKey,
          mobiApp: _mobiApp,
          device: _device,
          build: _build,
          channel: _biliChannel,
          buvid: account.buvid,
          platform: _device,
        ).writeToBuffer(),
      ),
    };
  }
}
