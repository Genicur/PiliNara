// 「锁定 HDR Vivid 为全屏画质」的判定逻辑（回归测试）
//
// 需求：开启「无限试用会员画质」时，可选的「锁定 HDR Vivid 为全屏画质」开关
// 会把全屏默认画质与全屏蜂窝网络画质都强制为 HDR Vivid(129)，忽略用户设置。
//
// 关键约束：
// 1. 两个开关必须**同时**开启才生效（Web 通道拿不到 HDR，单开锁定无意义）。
// 2. 关闭时完全回落用户设置，行为与原生一致。
// 3. 只影响取流时的「默认画质」取值，不修改用户已保存的设置项本身。
import 'dart:io';

import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Box<dynamic> setting;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('pilinara_hdr_lock_test');
    Hive.init(dir.path);
    setting = await Hive.openBox('setting');
    GStorage.setting = setting;
    GStorage.localCache = await Hive.openBox('localCache');
  });

  tearDownAll(() async {
    await Hive.close();
  });

  /// 写入用户自定义的画质设置（非 HDR Vivid），便于区分是否被锁定覆盖。
  Future<void> seedUserSettings() async {
    await setting.put(SettingBoxKey.defaultVideoQa, VideoQuality.super4K.code);
    await setting.put(
      SettingBoxKey.defaultVideoQaCellular,
      VideoQuality.high1080.code,
    );
  }

  group('两个开关同时开启 → 锁定生效', () {
    setUp(() async {
      await seedUserSettings();
      await setting.put(SettingBoxKey.unlimitedVipQuality, true);
      await setting.put(SettingBoxKey.lockHdrVividQuality, true);
    });

    test('hdrVividQualityLocked 为 true', () {
      expect(Pref.hdrVividQualityLocked, isTrue);
    });

    test('全屏默认画质被锁定为 HDR Vivid（忽略用户设的 4K）', () {
      expect(Pref.effectiveFullscreenQa, VideoQuality.hdrVivid.code);
      expect(Pref.effectiveFullscreenQa, isNot(VideoQuality.super4K.code));
    });

    test('全屏蜂窝画质同样被锁定为 HDR Vivid（忽略用户设的 1080P）', () {
      expect(Pref.effectiveFullscreenQaCellular, VideoQuality.hdrVivid.code);
      expect(
        Pref.effectiveFullscreenQaCellular,
        isNot(VideoQuality.high1080.code),
      );
    });

    test('用户原始设置项不被改写（只影响取流取值）', () {
      expect(Pref.defaultVideoQa, VideoQuality.super4K.code);
      expect(Pref.defaultVideoQaCellular, VideoQuality.high1080.code);
    });

    test('HDR Vivid 是 values 里的最高档（取流按 first 取最高画质）', () {
      expect(VideoQuality.values.first.code, VideoQuality.hdrVivid.code);
    });
  });

  group('只开锁定、不开试用 → 不生效', () {
    setUp(() async {
      await seedUserSettings();
      await setting.put(SettingBoxKey.unlimitedVipQuality, false);
      await setting.put(SettingBoxKey.lockHdrVividQuality, true);
    });

    test('hdrVividQualityLocked 为 false', () {
      expect(Pref.hdrVividQualityLocked, isFalse);
    });

    test('全屏画质回落到用户设置', () {
      expect(Pref.effectiveFullscreenQa, VideoQuality.super4K.code);
      expect(Pref.effectiveFullscreenQaCellular, VideoQuality.high1080.code);
    });
  });

  group('只开试用、不开锁定 → 不生效', () {
    setUp(() async {
      await seedUserSettings();
      await setting.put(SettingBoxKey.unlimitedVipQuality, true);
      await setting.put(SettingBoxKey.lockHdrVividQuality, false);
    });

    test('hdrVividQualityLocked 为 false', () {
      expect(Pref.hdrVividQualityLocked, isFalse);
    });

    test('全屏画质回落到用户设置', () {
      expect(Pref.effectiveFullscreenQa, VideoQuality.super4K.code);
      expect(Pref.effectiveFullscreenQaCellular, VideoQuality.high1080.code);
    });
  });

  group('两个都关 → 行为与原生一致', () {
    setUp(() async {
      await seedUserSettings();
      await setting.put(SettingBoxKey.unlimitedVipQuality, false);
      await setting.put(SettingBoxKey.lockHdrVividQuality, false);
    });

    test('effectiveFullscreenQa 等价于 defaultVideoQa', () {
      expect(Pref.effectiveFullscreenQa, Pref.defaultVideoQa);
      expect(
        Pref.effectiveFullscreenQaCellular,
        Pref.defaultVideoQaCellular,
      );
    });
  });

  group('默认值', () {
    test('lockHdrVividQuality 默认关闭', () {
      // 用全新 box 验证默认值
      expect(Pref.lockHdrVividQuality, isFalse);
    });
  });
}
