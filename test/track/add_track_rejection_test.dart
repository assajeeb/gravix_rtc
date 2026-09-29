// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/add_track_rejection.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pbenum.dart' as lk_rtc_enum;

void main() {
  lk_rtc.RequestResponse resp({
    required lk_rtc_enum.RequestResponse_Reason reason,
    String cid = 'TR_cam',
    String message = 'video resolution above plan limit (540p)',
    bool addTrack = true,
  }) => lk_rtc.RequestResponse(
    reason: reason,
    message: message,
    addTrack: addTrack ? lk_rtc.AddTrackRequest(cid: cid) : null,
    mute: addTrack ? null : lk_rtc.MuteTrackRequest(sid: 'x'),
  );

  test('LIMIT_EXCEEDED for our cid is a rejection carrying the server message', () {
    final msg = gravixAddTrackRejection(resp(reason: lk_rtc_enum.RequestResponse_Reason.LIMIT_EXCEEDED), 'TR_cam');
    expect(msg, isNotNull);
    expect(msg, contains('video resolution above plan limit (540p)'));
    expect(msg, contains('LIMIT_EXCEEDED'));
  });

  test('any non-OK reason for our cid is a rejection', () {
    expect(gravixAddTrackRejection(resp(reason: lk_rtc_enum.RequestResponse_Reason.NOT_ALLOWED), 'TR_cam'), isNotNull);
  });

  test('OK, another cid, or another request case is not ours', () {
    expect(gravixAddTrackRejection(resp(reason: lk_rtc_enum.RequestResponse_Reason.OK), 'TR_cam'), isNull);
    expect(
      gravixAddTrackRejection(
        resp(reason: lk_rtc_enum.RequestResponse_Reason.LIMIT_EXCEEDED, cid: 'TR_other'),
        'TR_cam',
      ),
      isNull,
    );
    expect(
      gravixAddTrackRejection(
        resp(reason: lk_rtc_enum.RequestResponse_Reason.LIMIT_EXCEEDED, addTrack: false),
        'TR_cam',
      ),
      isNull,
    );
  });
}
