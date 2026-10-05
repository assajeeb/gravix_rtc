// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:meta/meta.dart';

import '../../options.dart';
import '../../participant/local.dart';
import '../../types/other.dart';
import '../options.dart';
import 'audio.dart';

/// Publishes the microphone again with other publish options (RED, DTX: both
/// are fixed at publish time) on a NEW [LocalAudioTrack].
///
/// Why a new track: `removePublishedTrack` disposes the track it unpublishes,
/// so the same track can never be published again (field 2026-10-05: the
/// room-music DTX swap left the host without a microphone; RED auto used the
/// same pattern). The capture, the module mute and the room-music hook belong
/// to the audio device module, so they carry over to the new track.
///
/// - The mute state is carried over: a muted mic is muted before it is
///   published (a voice-only mute while room music plays).
/// - A failed publish is retried with [fallback] (the options it had): the
///   host is never left without a microphone because of a republish.
///
/// Returns the published track (null when nothing was published) and whether
/// it went out with [wanted].
@internal
Future<(LocalAudioTrack?, bool)> gravixRepublishMic(
  LocalParticipant local,
  LocalAudioTrack track, {
  required AudioPublishOptions wanted,
  required AudioPublishOptions fallback,
  @visibleForTesting Future<LocalAudioTrack> Function(AudioCaptureOptions options)? createTrack,
  @visibleForTesting Future<void> Function(LocalAudioTrack track, AudioPublishOptions options)? publish,
  @visibleForTesting Future<void> Function(String sid)? unpublish,
  Duration retryDelay = const Duration(milliseconds: 400),
  bool Function()? stillWanted,
}) async {
  final pub = local.getTrackPublicationBySource(TrackSource.microphone);
  if (pub == null || !identical(pub.track, track)) return (null, false);
  final create = createTrack ?? LocalAudioTrack.create;
  final doPublish = publish ?? ((t, o) async => local.publishAudioTrack(t, publishOptions: o));
  final doUnpublish = unpublish ?? ((sid) => local.removePublishedTrack(sid, notify: true));
  final wasMuted = track.muted;
  final LocalAudioTrack fresh;
  try {
    fresh = await create(track.currentOptions);
    // not one frame of voice for a muted mic: muted before it is published
    if (wasMuted) await fresh.mute(stopOnMute: false);
  } catch (e) {
    debugPrint('mic republish: no new track ($e); left as published');
    return (null, false);
  }
  try {
    await doUnpublish(pub.sid);
  } catch (e) {
    debugPrint('mic republish: unpublish failed: $e');
  }
  for (var attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await Future<void>.delayed(retryDelay * attempt);
    if (stillWanted != null && !stillWanted()) break;
    if (local.getTrackPublicationBySource(TrackSource.microphone) != null) break;
    final options = attempt == 0 ? wanted : fallback;
    try {
      await doPublish(fresh, options);
      return (fresh, attempt == 0);
    } catch (e) {
      debugPrint('mic republish (attempt ${attempt + 1}) failed: $e');
    }
  }
  try {
    await fresh.stop(); // never published: do not leave a capture running
  } catch (_) {}
  return (null, false);
}
