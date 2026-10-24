abstract final class Constants {
  static const appName = 'PiliNara';
  static const sourceCodeUrl = 'https://github.com/Starfallan/PiliNara';
  static const upstreamCodeUrl = 'https://github.com/bggRGjQaUbCoE/PiliPlus';
    

  // 27eb53fc9058f8c3  移动端 Android
  // 4409e2ce8ffd12b8  HD版
  static const String appKey = 'dfca71928277209b';
  // 59b43e04ad6965f34319062b478f83dd TV端
  static const String appSec = 'b5475a8825547a4fc26c7d518eaaa02e';
  /// 手机端 Android appkey/secret（同 BBDown 的 PhoneAppKey/PhoneAppSecret）。
  /// 只有手机端签发的 access_token 才能在 PlayView 拿到 4K / 1080P+ 的 dash 流。
  static const String phoneAppKey = '783bbb7264451d82';
  static const String phoneAppSec = '2653583c8873dea268ab9386918b1d65';

  /// PlayView 需要的手机端指纹：mobi_app=android 且 build>=6400000。
  /// HD 端（android_hd / build 2001100）服务端只下发 480P/360P 的 dashVideo。
  static const String playViewMobiApp = 'android';
  static const int playViewBuild = 7320200;
  static const String playViewVersionName = '7.32.0';
  static const String playViewUserAgent =
      'Mozilla/5.0 BiliDroid/7.32.0 (bbcallen@gmail.com) os/android model/android mobi_app/android build/7320200 channel/master innerVer/7320200 osVer/15 network/2';

  // static const String thirdSign = '04224646d1fea004e79606d3b038c84a';
  // static const String thirdApi =
  //     'https://www.mcbbs.net/template/mcbbs/image/special_photo_bg.png';

  static const String traceId =
      '11111111111111111111111111111111:1111111111111111:0:0';
  static const String userAgent =
      'Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/android_hd mobi_app/android_hd build/2001100 channel/master innerVer/2001100 osVer/15 network/2';
  static const String statistics =
      '{"appId":5,"platform":3,"version":"2.0.1","abtest":""}';
  // 请求时会自动encodeComponent

  // app
  static const String userAgentApp =
      'Mozilla/5.0 BiliDroid/8.43.0 (bbcallen@gmail.com) os/android model/android mobi_app/android build/8430300 channel/master innerVer/8430300 osVer/15 network/2';

  static const String statisticsApp =
      '{"appId":1,"platform":3,"version":"8.43.0","abtest":""}';

  static const baseHeaders = {
    // 'referer': HttpString.baseUrl,
    'env': 'prod',
    'app-key': 'android64',
    'x-bili-aurora-zone': 'sh001',
  };

  static final urlRegex = RegExp(
    r'https?://[-A-Za-z0-9+&@#/%?=~_|!:,.;]+[-A-Za-z0-9+&@#/%=~_|]',
  );

  static const goodsUrlPrefix = "https://gaoneng.bilibili.com/tetris";

  // static const dynFeatures = 'itemOpusStyle,listOnlyfans,onlyfansQaCard';
  static const dynFeatures =
      'itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,decorationCard,onlyfansAssetsV2,forwardListHidden,ugcDelete,onlyfansQaCard,commentsNewVersion,avatarAutoTheme,sunflowerStyle,cardsEnhance,eva3CardOpus,eva3CardVideo,eva3CardComment,eva3CardVote,eva3CardUser';

  static const dynDetailFeatures =
      'itemOpusStyle,opusBigCover,onlyfansVote,endFooterHidden,decorationCard,onlyfansAssetsV2,ugcDelete,onlyfansQaCard,editable,opusPrivateVisible,avatarAutoTheme,sunflowerStyle,cardsEnhance,eva3CardOpus,eva3CardVideo,eva3CardComment,eva3CardVote,eva3CardUser';

  static const opusDetailFeatures =
      'onlyfansVote,onlyfansAssetsV2,onlyfansOpusCard,decorationCard,htmlNewStyle,ugcDelete,editable,opusPrivateVisible,opusTribeeApprovedThread,opusTribeeRejectThread,opusTribeeFeatured,opusTribeeModifyCategory,opusTribeeRemoveThread,opusTribeeCoin,tribeeEdit,avatarAutoTheme,avatarTypeOpus,sunflowerStyle,articleEnhance,cardsEnhance,eva3CardOpus,eva3CardVideo,eva3CardComment,eva3CardVote,eva3CardUser';
}
