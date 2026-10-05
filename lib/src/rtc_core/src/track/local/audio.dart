// Copyright 2024 LiveKit, Inc.
// Modifications Copyright 2024-2026 Gravity Compile
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;

import 'package:collection/collection.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:meta/meta.dart';

import '../../events.dart';
import '../../exceptions.dart' show TrackCreateException;
import '../../internal/events.dart';
import '../../logger.dart';
import '../../options.dart';
import '../../stats/audio_source_stats.dart';
import '../../stats/stats.dart';
import '../../support/native.dart';
import '../../support/platform.dart';
import '../../types/other.dart';
import '../audio_management.dart';
import '../options.dart' as track_options;
import 'engine_mic_mute.dart';
import 'local.dart';
import 'mic_uplink_pause.dart';
import 'music_voice_mute.dart';

class LocalAudioTrack extends LocalTrack with AudioTrack, LocalAudioManagementMixin {
  // Options used for this track
  @override
  covariant track_options.AudioCaptureOptions currentOptions;

  AudioPublishOptions? lastPublishOptions;

  Future<void> setDeviceId(String deviceId) async {
    if (currentOptions.deviceId == deviceId) {
      return;
    }
    currentOptions = currentOptions.copyWith(deviceId: deviceId);
    if (!muted) {
      await restartTrack();
    }
  }

  /// Applies runtime audio processing options to this local audio track.
  ///
  /// On success, updates [currentOptions] and emits
  /// [LocalTrackOptionsUpdatedEvent]. When the native layer cannot apply the
  /// options, throws [track_options.AudioProcessingException] and leaves
  /// [currentOptions] unchanged.
  ///
  /// Experimental: this API may change in a future release.
  @experimental
  Future<void> setAudioProcessingOptions(track_options.AudioProcessingOptions options) async {
    final nextOptions = currentOptions.copyWith(processing: options);
    final response = await Native.setAudioProcessingOptions(mediaStreamTrack.id!, options.toMap());

    _throwIfAudioProcessingFailed(response);

    currentOptions = nextOptions;
    events.emit(LocalTrackOptionsUpdatedEvent(track: this, options: currentOptions));
  }

  num? _currentBitrate;
  num? get currentBitrate => _currentBitrate;

  AudioSenderStats? prevStats;

  /// This track is muted through [GravixEngineMicMute] (track enabled, recorder
  /// running, PCM zeroed in the audio device module) rather than disabled.
  bool _engineMuted = false;

  /// The track currently holding the engine-wide module mute.
  static LocalAudioTrack? get _engineMuteOwner => GravixEngineMicMute.owner as LocalAudioTrack?;
  static set _engineMuteOwner(LocalAudioTrack? t) => GravixEngineMicMute.owner = t;

  /// Mutes without stopping the Android recorder when [stopOnMute] is false.
  ///
  /// Disabling the track would make the engine stop the AudioRecord (and
  /// re-create it on unmute), which re-routes the voice path on OEM audio HALs
  /// and interrupts the OTHER participants' playout (field 2026-09-30). Falls
  /// back to the disable path when the module mute is unavailable.
  ///
  /// Once muted, the RTP sender's bitrate is capped as well ([MicUplinkPause]):
  /// the zeroed audio costs ~7 kbps of uplink instead of the full publish rate.
  @override
  Future<bool> mute({bool stopOnMute = true}) async {
    if (muted) return false;
    // Room music playing (gravix_rtc 0.4.10): a voice-only mute, whatever
    // stopOnMute says. The module zeroes the voice, the mixer keeps adding the
    // music, and the publication stays live on the wire (the SFU stops
    // forwarding a track signalled muted, which would cut the music): no
    // uplink cap, no mute signal. GravixRoomMusic turns it into a normal mute
    // when the music ends.
    if (GravixEngineMicMute.supported && GravixMusicVoiceMute.appliesTo(this)) {
      final previous = _engineMuteOwner;
      if (previous != null && !identical(previous, this)) await previous._leaveEngineMute();
      if (await GravixEngineMicMute.engage()) {
        _engineMuted = true;
        _voiceOnlyMuted = true;
        _engineMuteOwner = this;
        logger.info('mic mute: voice-only (room music playing; the publication stays live)');
        updateMuted(true, shouldSendSignal: false);
        return true;
      }
    }
    if (!stopOnMute && GravixEngineMicMute.supported) {
      final previous = _engineMuteOwner;
      if (previous != null && !identical(previous, this)) await previous._leaveEngineMute();
      if (await GravixEngineMicMute.engage()) {
        _engineMuted = true;
        _engineMuteOwner = this;
        // after the PCM is zeroed: a refused cap then only costs uplink
        await _uplinkPause.pause(sender);
        updateMuted(true, shouldSendSignal: true);
        return true;
      }
    }
    final did = await super.mute(stopOnMute: stopOnMute);
    if (did) await _uplinkPause.pause(sender);
    return did;
  }

  /// The sender's bitrate is restored BEFORE the microphone goes live again
  /// (engine mute released / track enabled), so the first spoken word is not
  /// squeezed through the muted cap.
  @override
  Future<bool> unmute({bool stopOnMute = true}) async {
    if (!muted) return false;
    if (_voiceOnlyMuted) {
      // the wire never saw the mute: no signal, no cap to lift
      _voiceOnlyMuted = false;
      _engineMuted = false;
      if (identical(_engineMuteOwner, this)) _engineMuteOwner = null;
      await GravixEngineMicMute.release();
      await enable();
      updateMuted(false, shouldSendSignal: false);
      return true;
    }
    // A failed restore is logged (severe) and the unmute still goes ahead: the
    // user asked to be heard, and low-rate audio beats none.
    await _uplinkPause.resume(sender);
    if (_engineMuted) {
      _engineMuted = false;
      if (identical(_engineMuteOwner, this)) _engineMuteOwner = null;
      await GravixEngineMicMute.release();
      await enable(); // it stayed enabled; a no-op unless something else disabled it
      updateMuted(false, shouldSendSignal: true);
      return true;
    }
    return super.unmute(stopOnMute: stopOnMute);
  }

  final _uplinkPause = MicUplinkPause();

  /// Muted for the user (voice zeroed in the audio device module) while the
  /// publication stays live for room music. See [mute].
  bool _voiceOnlyMuted = false;

  /// Whether the current mute is a voice-only mute (room music playing).
  bool get voiceOnlyMuted => _voiceOnlyMuted;

  /// The mute state the server should have: a voice-only mute is not one.
  @override
  bool get wireMuted => muted && !_voiceOnlyMuted;

  /// Room music started while this track is muted: keeps the voice muted and
  /// puts the track back on the wire (the caller sends the unmute signal).
  /// Returns false when the platform cannot mute in the audio device module;
  /// the track is then left as it was.
  @internal
  Future<bool> enterMusicVoiceMute() async {
    if (!muted || _voiceOnlyMuted) return muted;
    if (!GravixEngineMicMute.supported) return false;
    if (!_engineMuted) {
      // a disabled (stopOnMute) mute: zero the voice in the module FIRST, then
      // bring the capture back, so not one frame of voice goes out
      final previous = _engineMuteOwner;
      if (previous != null && !identical(previous, this)) await previous._leaveEngineMute();
      _engineMuteOwner = this;
      if (!await GravixEngineMicMute.engage()) {
        if (identical(_engineMuteOwner, this)) _engineMuteOwner = null;
        return false;
      }
      if (!isActive) await restartTrack();
      await enable();
      _engineMuted = true;
    }
    await _uplinkPause.resume(sender);
    _voiceOnlyMuted = true;
    return true;
  }

  /// Room music ended while voice-only muted: becomes a normal (module) mute,
  /// uplink capped; the caller sends the mute signal. Returns whether it was
  /// voice-only muted.
  @internal
  Future<bool> leaveMusicVoiceMute() async {
    if (!_voiceOnlyMuted) return false;
    _voiceOnlyMuted = false;
    await _uplinkPause.pause(sender);
    return true;
  }

  /// Whether the muted-uplink bitrate cap is applied.
  @visibleForTesting
  bool get uplinkCapped => _uplinkPause.capped;

  /// A republish while muted (RED auto, full reconnect) creates a NEW sender,
  /// which starts uncapped: `publication.mute()` on an already-muted track is a
  /// no-op, so the cap is re-applied here. Not gated on super's result: a
  /// full reconnect re-publishes without unpublishing first.
  @override
  Future<bool> onPublish() async {
    final did = await super.onPublish();
    if (wireMuted) await _uplinkPause.pause(sender);
    return did;
  }

  @override
  Future<bool> onUnpublish() async {
    _uplinkPause.forget();
    return super.onUnpublish();
  }

  /// Converts an engine mute into a plain disabled track and releases the
  /// module mute (the track stays muted, and silent).
  Future<void> _leaveEngineMute() async {
    if (!_engineMuted) return;
    await disable();
    _engineMuted = false;
    _voiceOnlyMuted = false;
    if (identical(_engineMuteOwner, this)) _engineMuteOwner = null;
    await GravixEngineMicMute.release();
  }

  @override
  Future<bool> stop() async {
    await _leaveEngineMute();
    return super.stop();
  }

  @override
  Future<void> startCapture() async {
    // A new microphone capture never inherits a stale module mute (it is
    // engine-wide): a still-muted older track is turned into a disabled one.
    final owner = _engineMuteOwner;
    if (owner != null && !identical(owner, this)) await owner._leaveEngineMute();
    if (GravixEngineMicMute.engaged && _engineMuteOwner == null) await GravixEngineMicMute.release();
    await super.startCapture();
    if (lkPlatformSupportsExplicitAudioRecordingStart()) {
      // Match Swift: start the ADM before publishing so capture-time audio
      // processing options are applied before WebRTC opens the microphone.
      await gravixStartExplicitRecording(() => Native.startLocalRecording(currentOptions.processing.toMap()));
    }
  }

  @override
  Future<bool> monitorStats() async {
    if (events.isDisposed || !isActive) {
      _currentBitrate = 0;
      return false;
    }
    try {
      final stats = await getSenderStats();

      if (stats != null && prevStats != null && sender != null) {
        final bitrate = computeBitrateForSenderStats(stats, prevStats);
        _currentBitrate = bitrate;
        events.emit(AudioSenderStatsEvent(stats: stats, currentBitrate: bitrate));
      }

      prevStats = stats;
    } catch (e) {
      logger.warning('failed to get sender stats: $e');
      return false;
    }
    return true;
  }

  Future<AudioSenderStats?> getSenderStats() async {
    if (sender == null) {
      return null;
    }

    late List<rtc.StatsReport> stats;
    try {
      stats = await sender!.getStats();
    } catch (e) {
      rethrow;
    }

    return audioSenderStatsFrom(stats);
  }

  // private constructor
  @internal
  LocalAudioTrack(TrackSource source, rtc.MediaStream stream, rtc.MediaStreamTrack track, this.currentOptions)
    : super(TrackType.AUDIO, source, stream, track);

  /// Creates a new audio track from the default audio input device.
  static Future<LocalAudioTrack> create([track_options.AudioCaptureOptions? options]) async {
    options ??= const track_options.AudioCaptureOptions();
    final stream = await LocalTrack.createStream(options);

    final track = LocalAudioTrack(TrackSource.microphone, stream, stream.getAudioTracks().first, options);

    try {
      if (options.processor != null) {
        await track.setProcessor(options.processor);
      }
    } catch (error, stackTrace) {
      try {
        await track.stop();
      } catch (stopError) {
        logger.warning('failed to stop audio track after processor setup failure: $stopError');
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    return track;
  }
}

/// Runs the explicit audio-recording start. Returns false, and the caller goes
/// on, when the platform has no such start (no native implementation: the audio
/// device then starts when the track is published, as it always did); a real
/// processing failure still throws. 2026-09-27: treating "not implemented" as a
/// failure made every mic publish fail on Android.
///
/// The native plugin now implements the start on Android and iOS. On iOS the
/// audio device module can also report audio-session trouble
/// (`audioSessionConfigureFailed`, `audioSessionInvalidCategory`): those fall
/// back the same way, because the publish-time start is what 0.3.1 always
/// relied on. A missing microphone permission (`deviceAccessDenied`) is not
/// something a later start can fix, so it fails the track as a
/// [TrackCreateException] instead of being reported as an audio processing
/// failure.
@visibleForTesting
Future<bool> gravixStartExplicitRecording(Future<void> Function() start) async {
  try {
    await start();
    return true;
  } on PlatformException catch (error) {
    switch (error.code) {
      case 'audioSessionConfigureFailed':
      case 'audioSessionInvalidCategory':
        logger.warning('explicit audio recording start failed (${error.code}); the track starts the device on publish');
        return false;
      case 'deviceAccessDenied':
        throw TrackCreateException(error.message ?? 'Microphone permission is not granted');
    }
    final reason = _audioProcessingFailureReason(error.code);
    if (reason == track_options.AudioProcessingFailureReason.platformUnavailable) {
      logger.fine('explicit audio recording start unavailable; the track starts the device on publish');
      return false;
    }
    throw track_options.AudioProcessingException(reason, error.message ?? '');
  }
}

void _throwIfAudioProcessingFailed(Map<String, dynamic> response) {
  final code = response['code'] as String?;
  final message = (response['message'] as String?) ?? '';

  final reason = _audioProcessingFailureReason(code);
  switch (code) {
    case 'applied':
    case 'stored':
      return;
    case 'rejectedInvalidCombination':
    case 'rejectedPlatformUnavailable':
    case 'applyFailed':
    case 'unknown':
    case 'rejectedRemoteTrack':
      throw track_options.AudioProcessingException(reason, message);
    default:
      throw track_options.AudioProcessingException(
        track_options.AudioProcessingFailureReason.unknown,
        _unknownAudioProcessingMessage(code, message),
      );
  }
}

track_options.AudioProcessingFailureReason _audioProcessingFailureReason(String? code) {
  switch (code) {
    case 'rejectedInvalidCombination':
      return track_options.AudioProcessingFailureReason.invalidCombination;
    case 'rejectedPlatformUnavailable':
      return track_options.AudioProcessingFailureReason.platformUnavailable;
    case 'applyFailed':
      return track_options.AudioProcessingFailureReason.applyFailed;
    default:
      return track_options.AudioProcessingFailureReason.unknown;
  }
}

String _unknownAudioProcessingMessage(String? code, String message) {
  final trimmed = message.trim();
  if (trimmed.isNotEmpty) {
    return trimmed;
  }
  if (code != null && code.isNotEmpty) {
    return 'Unknown audio processing result code: $code.';
  }
  return '';
}

/// The sender stats of a published audio track from its getStats() reports.
///
/// GRAVIX 2026-09-29: packetsLost / roundTripTime / jitter are what the REMOTE
/// receiver (the SFU) reports back about our uplink: the `remote-inbound-rtp`
/// report (matched by the outbound-rtp `remoteId`, or its `localId`), as the video
/// path already did. They used to be read from `outbound-rtp`, which has none of
/// them: the Kuwait tester's app showed 0 % loss and no RTT while doh1 measured
/// ~15 % uplink loss. Null (not 0) until the first RTCP receiver report arrives.
AudioSenderStats? audioSenderStatsFrom(List<rtc.StatsReport> stats) {
  AudioSenderStats? senderStats;
  for (var v in stats) {
    if (v.type == 'outbound-rtp') {
      senderStats ??= AudioSenderStats(v.id, v.timestamp);
      senderStats.packetsSent = getNumValFromReport(v.values, 'packetsSent');
      senderStats.bytesSent = getNumValFromReport(v.values, 'bytesSent');

      final remoteId = getStringValFromReport(v.values, 'remoteId');
      final r =
          stats.firstWhereOrNull((e) => remoteId != null && e.id == remoteId) ??
          stats.firstWhereOrNull((e) => e.type == 'remote-inbound-rtp' && e.values['localId'] == v.id);
      if (r != null) {
        senderStats.packetsLost = getNumValFromReport(r.values, 'packetsLost');
        senderStats.roundTripTime = getNumValFromReport(r.values, 'roundTripTime');
        senderStats.jitter = getNumValFromReport(r.values, 'jitter');
      }

      final c = stats.firstWhereOrNull((element) => element.type == 'codec');
      if (c != null) {
        senderStats.mimeType = getStringValFromReport(c.values, 'mimeType');
        senderStats.payloadType = getNumValFromReport(c.values, 'payloadType');
        senderStats.channels = getNumValFromReport(c.values, 'channels');
        senderStats.clockRate = getNumValFromReport(c.values, 'clockRate');
      }
    } else if (v.type == 'media-source') {
      senderStats ??= AudioSenderStats(v.id, v.timestamp);
      senderStats.audioSourceStats = AudioSourceStats.fromReport(v);
    }
  }
  return senderStats;
}
