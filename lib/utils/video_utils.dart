import 'package:PiliPlus/http/bili_media_headers.dart';
import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart'
    show AudioItem, VideoItem, FormatItem;
import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/utils/cdn_node_store.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

abstract final class VideoUtils {
  static CDNService cdnService = Pref.defaultCDNService;
  static String? customCDNUrl = Pref.customCDNUrl;
  static String? liveCdnUrl = Pref.liveCdnUrl;
  static bool disableAudioCDN = Pref.disableAudioCDN;

  static const _proxyTf = 'proxy-tf-all-ws.bilivideo.com';

  static final _mirrorRegex = RegExp(
    r'^https?://(?:upos-\w+-(?!302)\w+|(?:upos|proxy)-tf-[^/]+)\.(?:bilivideo|akamaized)\.(?:com|net)/upgcxcode',
  );

  static final _mCdnTfRegex = RegExp(
    r'^https?://(?:(?:(?:\d{1,3}\.){3}\d{1,3}|[^/]+\.mcdn\.bilivideo\.(?:com|cn|net))(?:\:\d{1,5})?/v\d/resource)',
  );

  static const _mediaHostSuffixes = [
    '.bilivideo.com',
    '.bilivideo.cn',
    '.acgvideo.com',
    '.akamaized.net',
  ];

  // host 首段为 API/上报类前缀的域名不参与自定义节点替换
  static final _blockedHostPrefix = RegExp(r'^(?:bvc|data|pbp|api)\w*\.');

  /// PCDN 节点路径形态：`/vN/resource/upgcxcode/...`
  static final _pcdnResourcePath = RegExp(r'^/v\d+/resource/');

  /// 把 URL 的 host 换成 [newHost]，并**丢弃原有的非标准端口**。
  ///
  /// 这个细节很关键：B 站 APP 通道下发的直链常见形如
  /// `xxx.edge.mountaintoys.cn:4483/upgcxcode/...`，而 upos 镜像节点
  /// （`upos-sz-mirrorhw.bilivideo.com` 等）只监听默认端口。
  /// 若用 `Uri.replace(host:)` 直接换 host，Dart 会**保留 :4483**，
  /// 结果请求 `upos-sz-mirrorhw.bilivideo.com:4483` 直接连接失败 → 播放卡死。
  ///
  /// 实测：同一 URL 保留 :4483 为 URLError，去掉端口后返回 206。
  /// 因此替换 host 时必须一并重置端口。
  ///
  /// 注意 `Uri.replace(port: null)` **无效**（实测仍保留原端口），
  /// 必须重建 Uri 才能丢掉端口。
  static Uri _replaceHost(Uri uri, String newHost) => Uri(
    scheme: uri.scheme.isEmpty ? 'https' : uri.scheme,
    host: newHost,
    path: uri.path,
    query: uri.hasQuery ? uri.query : null,
    fragment: uri.hasFragment ? uri.fragment : null,
  );

  static bool _isReplaceableMediaHost(String host) {
    final lower = host.toLowerCase();
    if (_blockedHostPrefix.hasMatch(lower)) {
      return false;
    }
    return lower == 'edge.mountaintoys.cn' ||
        _mediaHostSuffixes.any(lower.endsWith);
  }

  /// PCDN 节点判定：这类直链的签名与节点绑定，换 host 必 403。
  ///
  /// **实测结论（BV1FGJd63Exr / BV1j5nj68E48 等，24 条直链逐条验证）**：
  /// 能否替换 host **只取决于 host 类型，与 query 里的 `os` 值无关**：
  ///
  /// | host 类型 | os 值 | 原样 | 换 host |
  /// | --- | --- | --- | --- |
  /// | `*.mcdn.bilivideo.*` | mcdn / coso1bv / hwo1bv | 200 | **0/16 全 403** |
  /// | `*.edge.mountaintoys.cn` | mcdn | 200 | **8/8 全 200** |
  ///
  /// 所以：`mcdn` host 一律不可换；`mountaintoys` host 一律可换。
  /// 早期按 `os` 判定是错的（mountaintoys 也会带 os=mcdn）。
  ///
  /// 另注意：mountaintoys 换 host 后，**请求头必须满足** UA 不能为空、
  /// 也不能是完整 Chrome UA，且不能带 Referer（详见 BiliMediaHeaders）。
  static bool _isPcdnLockedUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    // mcdn 节点：签名与节点绑定，换任何 host 都 403
    return host.contains('.mcdn.bilivideo.');
  }

  /// APP 通道直链的 CDN 处理。
  ///
  /// 把「能否换 host」的判定从 platform 参数收窄到节点类型：
  /// * 遇到 PCDN 型直链（或整批都是 PCDN）时，原样返回；
  /// * upos / mountaintoys 型则按所选 CDN 做 host 替换。
  ///
  /// 混合批次的策略：优先在可替换的那几条里挑，避免因为第一条是 PCDN
  /// 就把整批都放弃替换。
  static String _appUrlForCdn(
    Iterable<String> urls, {
    required CDNService service,
    String? customHost,
    required bool isAudio,
  }) {
    final list = urls.toList(growable: false);
    if (list.isEmpty) return '';

    // 没有选择任何 CDN 替换时，维持原有行为
    if (customHost == null && service == CDNService.baseUrl) {
      return list.first;
    }

    // 优先用可替换的直链
    final replaceable = list.where((u) => !_isPcdnLockedUrl(u)).toList();
    if (replaceable.isEmpty) {
      // 整批都是 PCDN 型：签名锁死，换 host 必 403，原样返回
      return list.first;
    }

    final picked = replaceable.first;
    if (customHost != null) {
      return _replaceHost(Uri.parse(picked), customHost).toString();
    }
    if (service == CDNService.backupUrl || (isAudio && disableAudioCDN)) {
      return picked;
    }
    final serviceHost = service.host;
    if (serviceHost == null) return picked;
    return _replaceHost(Uri.parse(picked), serviceHost).toString();
  }

  /// 完整 URL 提取 host；纯 host 不得含路径/查询/锚点；空白视为 null
  static String? normalizeCustomCDNHost(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      return null;
    }
    if (uri.hasScheme) {
      return uri.host.isEmpty ? null : uri.host;
    }
    if (trimmed.contains('/') ||
        trimmed.contains('?') ||
        trimmed.contains('#') ||
        trimmed.contains(' ')) {
      return null;
    }
    return trimmed;
  }

  /// 当前生效 CDN 的展示文本：自定义节点优先反查节点表标注地区运营商
  static String effectiveCdnDesc() {
    final host = customCDNUrl;
    if (host == null) {
      return cdnService.desc;
    }
    return CdnNodeStore.labelOf(host) ?? '自定义：$host';
  }

  /// 取播放地址。
  ///
  /// 【设计约束：会员试用与 CDN 替换互斥】
  ///
  /// 实测结论（BV1FGJd63Exr / BV1j5nj68E48 等，逐条验证）：
  /// * APP 通道（platform=android）直链的签名 `upsig` 覆盖了 `uparams` 中的
  ///   `os`，`os` 记录服务端选定的节点；换 host 后 os 与新 host 不匹配 → 403。
  ///   `mcdn` 型必 403；`mountaintoys` 型换 host 虽偶有 200，但请求头稍有不符
  ///   （UA 为空/完整 Chrome UA/带 Referer）同样 403，稳定性不足以支撑普通播放。
  /// * Web 通道直链同理：换 host 一律 403（mcdn 与 upos backupUrl 均如此）。
  ///
  /// 因此「开启会员试用」与「CDN 替换」不能同时生效：
  /// * 试用开关打开 → 直接返回服务端下发的原始直链，不做任何 CDN 替换；
  /// * 试用开关关闭 → 恢复上游原有的 CDN 替换逻辑（行为与本项目改前一致）。
  ///
  /// [customHost] 显式指定自定义节点（节点测速用）；未传时按 [applyCustomCDN]
  /// 决定是否采用全局自定义节点。
  static String getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    String? customHost,
    bool applyCustomCDN = true,
    bool isAudio = false,
  }) {
    // 会员试用开启时，取流走 APP 通道，CDN 替换必然破坏签名 —— 原样返回。
    if (Pref.unlimitedVipQuality) {
      return urls.first;
    }

    defaultCDNService ??= cdnService;
    customHost ??= applyCustomCDN ? customCDNUrl : null;
    if (isAudio && disableAudioCDN) {
      customHost = null;
    }

    if (customHost == null && defaultCDNService == CDNService.baseUrl) {
      return urls.first;
    }

    String? mcdnTf;
    String? mcdnUpgcxcode;

    String last = '';
    for (final url in urls) {
      last = url;
      if (_mirrorRegex.hasMatch(url)) {
        final uri = Uri.parse(url);
        if (uri.queryParameters['os'] == 'mcdn') {
          // upos-sz-mirrorcoso1.bilivideo.com os=mcdn
          mcdnUpgcxcode = url;
        } else {
          if (customHost != null) {
            return _replaceHost(uri, customHost).toString();
          }
          if (defaultCDNService == CDNService.backupUrl ||
              (isAudio && disableAudioCDN)) {
            return url;
          }
          return _replaceHost(uri, defaultCDNService.host!).toString();
        }
      }

      if (_mCdnTfRegex.hasMatch(url)) {
        mcdnTf = url;
        continue;
      }

      // upos-\w*-302.* & bcache & mcdn host but upgcxcode path
      if (url.contains('/upgcxcode/')) {
        mcdnUpgcxcode = url;
        continue;
      }

      // may be deprecated
      if (url.contains('szbdyd.com')) {
        final uri = Uri.parse(url);
        final hostname =
            uri.queryParameters['xy_usource'] ??
            customHost ??
            defaultCDNService.host;
        return uri
            .replace(scheme: 'https', host: hostname, port: 443)
            .toString();
      }

      if (kDebugMode) {
        debugPrint('unknown cdn type: $url');
      }
    }

    if (mcdnUpgcxcode != null) {
      final uri = Uri.parse(mcdnUpgcxcode);
      if (customHost != null && _isReplaceableMediaHost(uri.host)) {
        return _replaceHost(uri, customHost).toString();
      }
      return _replaceHost(
        uri,
        defaultCDNService.host ?? CDNService.ali.host!,
      ).toString();
    }
    return mcdnTf == null
        ? last
        : Uri(
            scheme: 'https',
            host: _proxyTf,
            queryParameters: {'url': mcdnTf},
          ).toString();
  }

  static String getLiveCdnUrl(CodecItem e, {int index = 0}) {
    final urlInfo = e.urlInfo.getOrFirst(index);
    return (liveCdnUrl ?? urlInfo.host) + e.baseUrl + urlInfo.extra;
  }

  static VideoDecodeFormatType selectCodec(
    Iterable<String> codecs,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    if (preferCodecs.isNotEmpty) {
      int bestIndex = preferCodecs.length;
      for (final e in codecs) {
        for (int i = 0; i < bestIndex; i++) {
          if (preferCodecs[i].codes.any(e.startsWith)) {
            bestIndex = i;
            if (bestIndex == 0) {
              return preferCodecs[0];
            }
            break;
          }
        }
      }
      if (bestIndex < preferCodecs.length) {
        return preferCodecs[bestIndex];
      }
    }
    return VideoDecodeFormatType.fromString(codecs.first);
  }

  static int _findAvailableVideoQuality(
    List<VideoItem> videoList,
    List<int>? acceptQuality,
    int preferQuality,
  ) {
    final highestVideoQa = videoList.first.id;
    if (preferQuality >= highestVideoQa) {
      return highestVideoQa;
    }

    if (acceptQuality != null && acceptQuality.isNotEmpty) {
      return acceptQuality.findTargetMedia((e) => e, preferQuality);
    }

    return videoList.findTargetMedia((e) => e.id, preferQuality).quality.code;
  }

  static (
    int targetQuality,
    FormatItem targetFormat,
    VideoDecodeFormatType targetDecode,
    VideoItem targetVideo,
  )
  findTargetVideo(
    List<VideoItem> videoList,
    int preferQuality,
    List<int>? acceptQuality,
    List<FormatItem> supportFormats,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    assert(videoList.isNotEmpty);

    final targetQuality = _findAvailableVideoQuality(
      videoList,
      acceptQuality,
      preferQuality,
    );

    final targetFormat = supportFormats.firstWhere(
      (e) => e.quality == targetQuality,
      orElse: () => supportFormats.first,
    );

    final targetDecode = VideoUtils.selectCodec(
      targetFormat.codecs!,
      preferCodecs,
    );

    final targetQaVideoList = videoList
        .where((e) => e.id == targetQuality)
        .toList();

    final targetVideo = targetQaVideoList.firstWhere(
      (e) => targetDecode.codes.any(e.codecs!.startsWith),
      orElse: () => targetQaVideoList.first,
    );

    return (targetQuality, targetFormat, targetDecode, targetVideo);
  }

  static AudioItem findTargetAudio(
    List<AudioItem> audioList,
    int preferQuality,
  ) {
    assert(audioList.isNotEmpty);

    final preferredRank = AudioQuality.fromCode(preferQuality).rank;
    return audioList.findTargetMedia(
      (audio) => AudioQuality.fromCode(audio.id).rank,
      preferredRank,
    );
  }
}
