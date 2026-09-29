// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:meta/meta.dart';

import '../proto/gravixcloud_rtc.pb.dart' as lk_rtc;

/// The failure message if [response] is the SFU refusing OUR addTrack
/// (matched by track [cid]); null otherwise.
///
/// The SFU answers a refused addTrack (e.g. `LIMIT_EXCEEDED` for video above
/// the plan's `gravix.max_video_height`) with a RequestResponse instead of a
/// TrackPublished. AddTrack carries no requestId, so the cid inside the echoed
/// request is the only correlation. Without this the publish would sit until
/// the publish timeout and surface a generic error.
@internal
String? gravixAddTrackRejection(lk_rtc.RequestResponse response, String cid) {
  if (response.reason == lk_rtc.RequestResponse_Reason.OK) return null;
  if (response.whichRequest() != lk_rtc.RequestResponse_Request.addTrack) return null;
  if (response.addTrack.cid != cid) return null;
  final detail = response.message.isEmpty ? '' : ' - ${response.message}';
  return 'addTrack rejected: ${response.reason.name}$detail';
}
