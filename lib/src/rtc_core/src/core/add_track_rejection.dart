// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:meta/meta.dart';

import '../../../connect/gravix_region_media.dart';
import '../proto/gravixcloud_models.pb.dart' as lk_models;
import '../proto/gravixcloud_rtc.pb.dart' as lk_rtc;

/// The failure message if [response] is the SFU refusing OUR addTrack
/// (matched by track [cid]); null otherwise.
///
/// The SFU answers a refused addTrack (e.g. `LIMIT_EXCEEDED` for video above
/// the plan's `gravix.max_video_height`) with a RequestResponse instead of a
/// TrackPublished. AddTrack carries no requestId, so the cid inside the echoed
/// request is the only correlation. Without this the publish would sit until
/// the publish timeout and surface a generic error.
///
/// `QUEUED` is not a refusal: the SFU queues an addTrack whose cid is still
/// published (a republish of the same track: RED auto, the room-music DTX swap)
/// and answers TrackPublished once the old publication is gone. Field
/// 2026-10-05: treating it as a refusal failed every same-track republish and
/// left the host without a microphone.
@internal
String? gravixAddTrackRejection(lk_rtc.RequestResponse response, String cid) {
  if (response.reason == lk_rtc.RequestResponse_Reason.OK) return null;
  if (response.reason == lk_rtc.RequestResponse_Reason.QUEUED) return null;
  if (response.whichRequest() != lk_rtc.RequestResponse_Request.addTrack) return null;
  if (response.addTrack.cid != cid) return null;
  final detail = response.message.isEmpty ? '' : ' - ${response.message}';
  return 'addTrack rejected: ${response.reason.name}$detail';
}

/// GRAVIX (2026-11-04): a server refusal of [type]'s medium on this node that names no
/// AddTrack: no TrackPublished will come for a pending publish of that medium, so it ends
/// now instead of at timeouts.publish. Null otherwise, also for a refusal naming another
/// AddTrack ([gravixAddTrackRejection] decides those).
@internal
String? gravixAddTrackMediaRefusal(lk_rtc.RequestResponse response, lk_models.TrackType type) {
  if (response.reason == lk_rtc.RequestResponse_Reason.OK) return null;
  if (response.whichRequest() == lk_rtc.RequestResponse_Request.addTrack) return null;
  if (!gravixIsMediaNotAllowed(response.message)) return null;
  final video = gravixRefusedMedia(response.message) == GravixRoomMedia.video;
  if (video != (type == lk_models.TrackType.VIDEO)) return null;
  return 'addTrack rejected: ${response.reason.name} - ${response.message}';
}
