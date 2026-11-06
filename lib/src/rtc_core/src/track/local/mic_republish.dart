// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

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
/// - [stillWanted] (0.4.12: callers pass "the room is still connected and not
///   leaving") is asked before the unpublish, before every attempt and after a
///   successful publish. A republish that is no longer wanted never leaves a
///   track behind: field 2026-10-06, room music stopped by a leave republished
///   the mic during the disconnect, three publishes failed, and a capture
///   started by the retries stayed open after the room was gone.
/// - Every track this creates is either returned published or stopped (which
///   also releases the recorder its capture start pre-warmed).
///
/// Returns the published track (null when nothing was published) and whether
/// it went out with [wanted].
@internal
Future<(LocalAudioTrack?, bool)> gravixRepublishMic(
  LocalParticipant local,
  LocalAudioTrack track, {
  required AudioPublishOptions wanted,
  required AudioPublishOptions fallback,
  // test seams (null = LocalAudioTrack.create / publishAudioTrack / removePublishedTrack)
  Future<LocalAudioTrack> Function(AudioCaptureOptions options)? createTrack,
  Future<void> Function(LocalAudioTrack track, AudioPublishOptions options)? publish,
  Future<void> Function(String sid)? unpublish,
  Duration retryDelay = const Duration(milliseconds: 400),
  bool Function()? stillWanted,
}) async {
  final done = Completer<void>();
  local.gravixMicSwap = done.future;
  try {
    return await _republishMic(
      local,
      track,
      wanted: wanted,
      fallback: fallback,
      createTrack: createTrack,
      publish: publish,
      unpublish: unpublish,
      retryDelay: retryDelay,
      stillWanted: stillWanted,
    );
  } finally {
    if (identical(local.gravixMicSwap, done.future)) local.gravixMicSwap = null;
    done.complete();
  }
}

Future<(LocalAudioTrack?, bool)> _republishMic(
  LocalParticipant local,
  LocalAudioTrack track, {
  required AudioPublishOptions wanted,
  required AudioPublishOptions fallback,
  // test seams (null = LocalAudioTrack.create / publishAudioTrack / removePublishedTrack)
  Future<LocalAudioTrack> Function(AudioCaptureOptions options)? createTrack,
  Future<void> Function(LocalAudioTrack track, AudioPublishOptions options)? publish,
  Future<void> Function(String sid)? unpublish,
  Duration retryDelay = const Duration(milliseconds: 400),
  bool Function()? stillWanted,
}) async {
  bool wantedNow() => stillWanted == null || stillWanted();
  final pub = local.getTrackPublicationBySource(TrackSource.microphone);
  if (pub == null || !identical(pub.track, track)) return (null, false);
  if (!wantedNow()) {
    debugPrint('mic republish: skipped (the room is leaving or gone)');
    return (null, false);
  }
  final create = createTrack ?? LocalAudioTrack.create;
  final doPublish = publish ?? ((t, o) async => local.gravixPublishSwappedMic(t, o));
  final doUnpublish = unpublish ?? local.gravixPublicationLost; // no request of the app's
  // GRAVIX (0.8.4): the newest call decides, up to the publish and after it: a tap during the
  // create or the unpublish reaches the old track, or no track at all
  final asks = local.gravixAskCount(TrackSource.microphone);
  bool muteWanted() => local.gravixAskCount(TrackSource.microphone) != asks ? !local.gravixMicWanted : track.muted;
  Future<void> applyWanted(LocalAudioTrack t) async {
    if (muteWanted()) {
      if (!t.muted) await t.mute(stopOnMute: false);
    } else if (t.muted) {
      await t.unmute(stopOnMute: false);
    }
  }

  final LocalAudioTrack fresh;
  try {
    fresh = await create(track.currentOptions);
  } catch (e) {
    debugPrint('mic republish: no new track ($e); left as published');
    return (null, false);
  }
  try {
    // not one frame of voice for a muted mic: muted before it is published
    if (muteWanted()) await fresh.mute(stopOnMute: false);
  } catch (e) {
    debugPrint('mic republish: the new track could not be muted ($e); left as published');
    await _stopUnpublished(fresh);
    return (null, false);
  }
  if (!wantedNow()) {
    // the leave started while the track was being created: the old mic stays
    // as published (the leave unpublishes it), the new one never runs
    debugPrint('mic republish: abandoned before the unpublish (the room is leaving or gone)');
    await _stopUnpublished(fresh);
    return (null, false);
  }
  try {
    await doUnpublish(pub.sid);
  } catch (e) {
    debugPrint('mic republish: unpublish failed: $e');
  }
  try {
    // Started once, here: a failed publish of a track it did not start stops
    // it, and the next attempt would restart a stopped capture.
    await fresh.start();
    // a plain mute before the start finds no capture to turn off. An engine or voice-only mute lives
    // on an enabled capture: disabling it would zero room music too.
    if (fresh.muted && !fresh.gravixMuteKeepsCapture) await fresh.disable();
  } catch (e) {
    debugPrint('mic republish: the new track did not start: $e');
    await _stopUnpublished(fresh);
    return (null, false);
  }
  for (var attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await Future<void>.delayed(retryDelay * attempt);
    if (!wantedNow()) break;
    if (local.getTrackPublicationBySource(TrackSource.microphone) != null) break;
    final options = attempt == 0 ? wanted : fallback;
    try {
      await applyWanted(fresh);
      await doPublish(fresh, options);
      await applyWanted(fresh); // the newest call decides, both ways
    } catch (e) {
      debugPrint('mic republish (attempt ${attempt + 1}) failed: $e');
      continue;
    }
    if (!wantedNow()) {
      // published while the leave ran: the leave's unpublish may already be
      // past, so this one is taken down here
      debugPrint('mic republish: published after the leave started; taken down');
      final now = local.getTrackPublicationBySource(TrackSource.microphone);
      if (now != null && identical(now.track, fresh)) {
        try {
          await doUnpublish(now.sid);
        } catch (_) {}
      }
      await _stopUnpublished(fresh);
      return (null, false);
    }
    return (fresh, attempt == 0);
  }
  // never published: do not leave a capture (or a pre-warmed recorder) running
  await _stopUnpublished(fresh);
  return (null, false);
}

Future<void> _stopUnpublished(LocalAudioTrack track) async {
  try {
    await track.stop();
  } catch (e) {
    debugPrint('mic republish: stopping the unused track failed: $e');
  }
}
