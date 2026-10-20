import 'package:PiliPlus/grpc/bilibili/app/playurl/v1.pb.dart';
import 'package:PiliPlus/grpc/grpc_req.dart';
import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/utils/accounts/grpc_headers.dart';
import 'package:fixnum/fixnum.dart';

abstract final class PlayUrlGrpc {
  /// APP 端视频取流（`bilibili.app.playurl.v1.PlayURL/PlayView`）。
  ///
  /// 相比 Web 的 `/x/player/wbi/playurl`，该接口对非大会员账号也会下发
  /// 4K/1080P+ 的 dash 流（StreamInfo.needVip 为 true 但 intact 为 true，
  /// 直链可正常下载）。前提：
  /// 1. [accessKey] 必须是**手机端**签发的 token（HD 端 token 无效）；
  /// 2. 指纹必须是手机端 `mobi_app=android` + `build>=6400000`
  ///    （见 [GrpcHeaders.newPlayViewHeaders]）。
  static Future<LoadingState<PlayViewReply>> playView({
    required int aid,
    required int cid,
    int qn = 127,
    int fnval = 4048 | 16384,
    CodeType preferCodecType = CodeType.CODE265,
    String spmid = 'main.ugc-video-detail.0.0',
    String fromSpmid = 'main.my-history.0.0',
    String? accessKey,
  }) {
    return GrpcReq.request(
      GrpcUrl.playView,
      PlayViewReq(
        aid: Int64(aid),
        cid: Int64(cid),
        qn: Int64(qn),
        fnver: 0,
        fnval: fnval,
        download: 0,
        forceHost: 2,
        fourk: true,
        spmid: spmid,
        fromSpmid: fromSpmid,
        preferCodecType: preferCodecType,
      ),
      PlayViewReply.fromBuffer,
      grpcHeaders: GrpcHeaders.newPlayViewHeaders(accessKey),
    );
  }
}
