/// PCDN 节点识别与直链择优。
///
/// 背景：B 站给 APP 通道下发的直链里有相当一部分是 **PCDN**（把用户设备当边缘
/// 节点）。PCDN 的速度取决于当时有多少人在做种：热门视频很快，冷门视频或深夜
/// 会慢到几 KB/s，表现为「有的视频卡得没法看」。
///
/// 判据沿用 BBDown（`BBDown.Core/CdnHost.cs`）的实测结论：
/// **authority 带显式端口就是 PCDN**，例如
///   `xy115x231x41x11xy.mcdn.bilivideo.cn:8082`
///   `19e949o.edge.mountaintoys.cn:4483`
/// 而官方 CDN 是 `upos-sz-mirror*.bilivideo.com`（无端口）。
///
/// 实测（2026-11-15，真实 APP 直链逐条验证）：
/// * upos 型换 host：9/9 全部 206；
/// * mcdn 型换 host：3/3 全部 403（签名与节点绑定）。
///
/// 所以策略是：**优先选不带端口的官方节点**，全都带端口时才退回第一个。
abstract final class PcdnPicker {
  /// authority 带显式端口 → PCDN。
  static final RegExp _pcdnRegex = RegExp(r'://[^/]+:\d+/');

  /// 是否为 PCDN（带显式端口的）直链。
  static bool isPcdn(String url) => _pcdnRegex.hasMatch(url);

  /// 从候选直链里挑一条最可能不卡的。
  ///
  /// 规则：
  /// 1. 优先第一条**非 PCDN**的地址；
  /// 2. 全是 PCDN 时，退回第一条（不能返回空）。
  static String pick(Iterable<String> urls) {
    final list = urls.where((e) => e.isNotEmpty).toList(growable: false);
    if (list.isEmpty) return '';
    for (final url in list) {
      if (!isPcdn(url)) return url;
    }
    return list.first;
  }

  /// 把 [primary] 与 [backups] 合成候选表后择优。
  static String pickWithBackups(String? primary, Iterable<String>? backups) {
    return pick([
      if (primary != null && primary.isNotEmpty) primary,
      ...?backups,
    ]);
  }
}
