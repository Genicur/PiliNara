import 'dart:convert';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/metadata.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/device.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/fawkes.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/locale.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/network.pb.dart' as network;
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/utils.dart';

abstract final class GrpcHeaders {
  static const _build = 2001100;
  static const _versionName = '2.0.1';
  static const _biliChannel = 'master';
  static const _mobiApp = 'android_hd';
  static const _device = 'android';

  static String get _buvid => LoginUtils.buvid;
  static String get _traceId => Constants.traceId;
  static String get _sessionId => Utils.generateRandomString(8);

  static final Map<String, String> _base = {
    'grpc-encoding': 'gzip',
    'gzip-accept-encoding': 'gzip,identity',
    'user-agent': Constants.userAgent,
    'x-bili-gaia-vtoken': '',
    'x-bili-aurora-zone': '',
    'x-bili-trace-id': _traceId,
    'buvid': _buvid,
    'bili-http-engine': 'cronet',
    // 'te': 'trailers', // dio not supported
    'x-bili-device-bin': base64Encode(
      Device(
        appId: 5,
        build: _build,
        buvid: _buvid,
        mobiApp: _mobiApp,
        platform: _device,
        channel: _biliChannel,
        brand: _device,
        model: _device,
        osver: '15',
        versionName: _versionName,
      ).writeToBuffer(),
    ),
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

  static Map<String, String> newHeaders([String? accessKey]) {
    return {
      ..._base,
      if (accessKey != null) 'authorization': 'identify_v1 $accessKey',
      'x-bili-fawkes-req-bin': fawkes,
      'x-bili-metadata-bin': base64Encode(
        Metadata(
          accessKey: accessKey,
          mobiApp: _mobiApp,
          device: _device,
          build: _build,
          channel: _biliChannel,
          buvid: _buvid,
          platform: _device,
        ).writeToBuffer(),
      ),
    };
  }

  /// PlayView 专用指纹。
  ///
  /// 服务端按 `x-bili-device-bin` 里的 `mobi_app` + `build` 决定是否下发
  /// 4K/1080P+ 的 dash 流：必须 `mobi_app=android` 且 `build>=6400000`，
  /// 而全局 gRPC 指纹是 HD 端（android_hd / 2001100），所以这里单独构造。
  static Map<String, String> newPlayViewHeaders([String? accessKey]) {
    const mobiApp = Constants.playViewMobiApp;
    const build = Constants.playViewBuild;
    const versionName = Constants.playViewVersionName;
    return {
      'grpc-encoding': 'gzip',
      'gzip-accept-encoding': 'gzip,identity',
      'user-agent': Constants.playViewUserAgent,
      'x-bili-gaia-vtoken': '',
      'x-bili-aurora-zone': '',
      'x-bili-trace-id': _traceId,
      'buvid': _buvid,
      'bili-http-engine': 'cronet',
      'x-bili-device-bin': base64Encode(
        Device(
          appId: 5,
          build: build,
          buvid: _buvid,
          mobiApp: mobiApp,
          platform: _device,
          channel: _biliChannel,
          brand: _device,
          model: _device,
          osver: '15',
          versionName: versionName,
        ).writeToBuffer(),
      ),
      'x-bili-network-bin': _base['x-bili-network-bin']!,
      'x-bili-locale-bin': _base['x-bili-locale-bin']!,
      'x-bili-exps-bin': '',
      'x-bili-fawkes-req-bin': base64Encode(
        FawkesReq(
          appkey: 'android64',
          env: 'prod',
          sessionId: _sessionId,
        ).writeToBuffer(),
      ),
      'x-bili-metadata-bin': base64Encode(
        Metadata(
          accessKey: accessKey,
          mobiApp: mobiApp,
          device: _device,
          build: build,
          channel: _biliChannel,
          buvid: _buvid,
          platform: _device,
        ).writeToBuffer(),
      ),
      if (accessKey != null) 'authorization': 'identify_v1 $accessKey',
    };
  }
}
