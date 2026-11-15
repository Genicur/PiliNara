import 'package:PiliPlus/grpc/bilibili/app/playurl/v1.pb.dart';
import 'package:PiliPlus/grpc/grpc_req.dart';
import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/utils/accounts/grpc_headers.dart';
import 'package:fixnum/fixnum.dart';

/// B 站 APP 端播放地址接口（`bilibili.app.playurl.v1.PlayURL/PlayView`）。
///
/// 为什么必须走它：Web 的 `/x/player/wbi/playurl` 对**非大会员恒定封顶
/// 1080P(80)**，与 qn/fnval/fourk 怎么传都无关（实测 qn=127 与 qn=80 返回一致）。
/// 而 APP 通道在「手机端指纹 + 手机端 token」下，会把 4K(120)/1080P+(112)/
/// 1080P60(116) 的**真实 DashVideo 直链**一并下发。
///
/// 关键实测结论（2026-11-15）：
/// * 请求里的 `qn` 几乎不影响返回：qn 传 0/16/32/80/127，返回的档位完全相同，
///   所以这里固定 127，由响应决定实际可用档位；
/// * 服务端不看 `needVip` 才给地址，非大会员也能拿到 4K 直链；
/// * `preferCodecType` 会影响 HDR 类档位能否拿到直链：HDR Vivid/真彩/杜比/8K
///   只在 HEVC 或 AV1 下带 DashVideo。
abstract final class PlayUrlGrpc {
  static const _fnval = 4048 | 16384;

  static Future<LoadingState<PlayViewReply>> playView({
    required int aid,
    required int cid,
    CodeType preferCodecType = CodeType.CODE265,
    String? accessKey,
    required String buvid,
    int qn = 127,
  }) {
    return GrpcReq.request(
      GrpcUrl.playView,
      PlayViewReq(
        aid: Int64(aid),
        cid: Int64(cid),
        qn: Int64(qn),
        fnver: 0,
        fnval: _fnval,
        download: 0,
        // 0: 允许使用 ip  1: 使用 http  2: 使用 https
        forceHost: 2,
        fourk: true,
        spmid: 'main.ugc-video-detail.0.0',
        fromSpmid: 'main.my-history.0.0',
        preferCodecType: preferCodecType,
      ),
      PlayViewReply.fromBuffer,
      grpcHeaders: GrpcHeaders.newPlayViewHeaders(
        accessKey: accessKey,
        buvid: buvid,
      ),
    );
  }
}
