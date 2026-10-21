import 'package:PiliPlus/http/bili_media_headers.dart';
import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart'
    show AudioItem, VideoItem, FormatItem;
import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/utils/cdn_node_store.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
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
  /// 实测（见 docs/cdn-setting-vs-unlimited-vip-quality.md）：
  /// * `*.mcdn.bilivideo.*` 且路径 `/vN/resource/...`（query 里通常 os=mcdn）
  ///   → 换 host 403；把 os 一起改掉仍 403。
  /// * `upos-sz-*` / `*.edge.mountaintoys.cn` → 换 host 206，可正常替换。
  ///
  /// 注意不能用「platform=android」整类判定：APP 通道下发的流里
  /// upos/mountaintoys 型同样存在且可替换（HDR/4K 常是这种）。
  static bool _isPcdnLockedUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    // 只有 mcdn 系列 host 才可能是 PCDN 锁定节点；
    // upos-*、edge.mountaintoys.cn 等均可安全替换（实测 206）。
    if (!host.contains('.mcdn.bilivideo.')) return false;
    // 实测锁定的形态：{ip or node}.mcdn.bilivideo.* + /vN/resource/upgcxcode/...
    // 这是 PCDN 节点，签名绑定了节点本身，换 host 必 403。
    return _pcdnResourcePath.hasMatch(uri.path);
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
      return Uri.parse(picked).replace(host: customHost).toString();
    }
    if (service == CDNService.backupUrl || (isAudio && disableAudioCDN)) {
      return picked;
    }
    final serviceHost = service.host;
    if (serviceHost == null) return picked;
    return Uri.parse(picked).replace(host: serviceHost).toString();
  }

  /// 取流的候选 URL 队列：按优先级依次尝试，最后一个必定是「原始直链」。
  ///
  /// 用户要求：「先做轮询，都不行再回到原始直链」。播放器在首个地址失败时
  /// 会从这里取下一个候选，全部失败则回落到服务端下发的原始地址，
  /// 避免因为选了不可用 CDN 而卡住、需要手动切换。
  static List<String> cdnCandidates(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
  }) {
    final list = urls.toList(growable: false);
    if (list.isEmpty) return const [];
    final primary = getCdnUrl(
      list,
      defaultCDNService: defaultCDNService,
      isAudio: isAudio,
    );
    final result = <String>[];
    void add(String u) {
      if (u.isNotEmpty && !result.contains(u)) result.add(u);
    }

    add(primary);
    // 其余原始直链作为次选（B 站下发的 backupUrl 往往就是可用备用节点）
    for (final u in list) {
      add(u);
    }
    return result;
  }

  /// 单个地址是否可出数据（Range: bytes=0-0 轻量请求，只读 1 字节）。
  ///
  /// 请求头按直链来源选用 [BiliMediaHeaders.forPlayer]，避免因 Referer/UA
  /// 不对而把可用节点误判为不可用。
  static Future<bool> isUrlReachable(
    String url, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (url.isEmpty) return false;
    final dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        validateStatus: (s) => s != null && s < 400,
      ),
    );
    try {
      final (ua, referer) = BiliMediaHeaders.forPlayer(url);
      await dio.get<void>(
        url,
        options: Options(
          headers: {
            'user-agent': ua,
            if (referer.isNotEmpty) 'referer': referer,
            'Range': 'bytes=0-0',
          },
          responseType: ResponseType.stream,
        ),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      dio.close(force: true);
    }
  }

  /// 逐个探测候选地址，返回第一个可用者；全部不可用时回落到原始直链。
  static Future<String> pickReachableCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final list = urls.toList(growable: false);
    if (list.isEmpty) return '';
    final fallback = list.first;
    final candidates = cdnCandidates(
      list,
      defaultCDNService: defaultCDNService,
      isAudio: isAudio,
    );
    if (candidates.length <= 1) {
      return candidates.isEmpty ? fallback : candidates.first;
    }
    for (final url in candidates) {
      if (await isUrlReachable(url, timeout: timeout)) return url;
    }
    // 全部失败：回落到原始直链，让播放器按原行为处理（多半是可播放的）
    return fallback;
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

  /// [customHost] 显式指定自定义节点（节点测速用）；未传时按 [applyCustomCDN]
  /// 决定是否采用全局自定义节点。全局自定义生效时完全旁路枚举语义。
  static String getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    String? customHost,
    bool applyCustomCDN = true,
    bool isAudio = false,
  }) {
    defaultCDNService ??= cdnService;
    customHost ??= applyCustomCDN ? customCDNUrl : null;
    if (isAudio && disableAudioCDN) {
      customHost = null;
    }

    // APP 通道（platform=android）签发的直链分两类，处理方式不同
    // （实测数据见 docs/cdn-setting-vs-unlimited-vip-quality.md）：
    //  * PCDN 型（`*.mcdn.bilivideo.*`，query 里 os=mcdn、路径形如 /vN/resource/...）：
    //    签名与节点绑定，换任何 host 都会 403，必须原样返回。
    //  * `upos-sz-*` / `*.edge.mountaintoys.cn` 型：签名**不**绑定 host，
    //    换 host 后仍返回 206，可以像 Web 直链一样享受 CDN 替换。
    // 早期实现按 platform 一刀切整类短路，把这些本可替换的档位（恰恰是
    // HDR/4K 这类高码率流）也一起跳过了，这里改为按节点类型判定。
    if (urls.isNotEmpty && BiliMediaHeaders.isAndroidPlatformUrl(urls.first)) {
      return _appUrlForCdn(
        urls,
        service: defaultCDNService,
        customHost: customHost,
        isAudio: isAudio,
      );
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
            return uri.replace(host: customHost).toString();
          }
          if (defaultCDNService == CDNService.backupUrl ||
              (isAudio && disableAudioCDN)) {
            return url;
          }
          return uri.replace(host: defaultCDNService.host).toString();
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
        return uri.replace(host: customHost).toString();
      }
      return uri
          .replace(host: defaultCDNService.host ?? CDNService.ali.host)
          .toString();
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
