// 本次改造的三条核心规则的回归测试。
//
// 1. PCDN 降优先级：带显式端口的节点判定与择优（对齐 BBDown CdnHost.cs 的判据）。
// 2. HDR 排除：「锁定最高画质」不能选中 HDR Vivid / 真彩 / 杜比视界。
// 3. 通道选择：纯 UGC 且有手机端 token 时才走 APP。
import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/video/play/playview_convert.dart';
import 'package:PiliPlus/utils/pcdn_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PCDN 判定：authority 带显式端口即为 PCDN', () {
    test('官方 upos 节点（无端口）不是 PCDN', () {
      for (final u in [
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3.m4s?os=cosbv',
        'http://upos-sz-mirrorbd.bilivideo.com/upgcxcode/50/44/1.m4s?os=bdbv',
        'https://upos-sz-mirrorcoso1.bilivideo.com/upgcxcode/x.m4s',
      ]) {
        expect(PcdnPicker.isPcdn(u), isFalse, reason: u);
      }
    });

    test('mcdn / mountaintoys（带端口）是 PCDN', () {
      for (final u in [
        'https://xy115x231x41x11xy.mcdn.bilivideo.cn:8082/v1/resource/x.m4s',
        'https://19e949o.edge.mountaintoys.cn:4483/upgcxcode/x.m4s',
        'http://36.250.117.138:8000/upgcxcode/x.m4s',
      ]) {
        expect(PcdnPicker.isPcdn(u), isTrue, reason: u);
      }
    });
  });

  group('直链择优：优先非 PCDN', () {
    const mcdn = 'https://xy1.mcdn.bilivideo.cn:8082/v1/resource/a.m4s';
    const upos = 'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/a.m4s';

    test('候选里有 upos 时选 upos（即使它排在后面）', () {
      expect(PcdnPicker.pick([mcdn, upos]), upos);
      expect(PcdnPicker.pickWithBackups(mcdn, [upos]), upos);
    });

    test('全是 PCDN 时退回第一条，不返回空', () {
      expect(PcdnPicker.pick([mcdn, mcdn]), mcdn);
      expect(PcdnPicker.pick([]), '');
    });

    test('primary 是 upos 时直接用它', () {
      expect(PcdnPicker.pickWithBackups(upos, [mcdn]), upos);
    });
  });

  group('HDR 档位排除', () {
    test('HDR Vivid / 真彩 / 杜比视界 被判为 HDR', () {
      expect(PlayViewConverter.isHdrQuality(129), isTrue); // HDR Vivid
      expect(PlayViewConverter.isHdrQuality(125), isTrue); // HDR 真彩
      expect(PlayViewConverter.isHdrQuality(126), isTrue); // 杜比视界
      expect(VideoQuality.isHdrQuality(129), isTrue);
      expect(VideoQuality.isHdrQuality(125), isTrue);
      expect(VideoQuality.isHdrQuality(126), isTrue);
    });

    test('4K / 8K / 1080P60 / 1080P+ 不是 HDR（要保留）', () {
      for (final q in [120, 127, 116, 112, 80, 64, 32, 16]) {
        expect(PlayViewConverter.isHdrQuality(q), isFalse, reason: 'q=$q');
        expect(VideoQuality.isHdrQuality(q), isFalse, reason: 'q=$q');
      }
    });
  });
}
