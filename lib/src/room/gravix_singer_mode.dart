// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Singer mode: an explicit, runtime opt-in for singers and live-stream sound
// cards (V8-type cards, a mixer, a line input). Report 2026-11-20: pro singers
// heard their loud / high notes lowered and notes dropped. The voice chain is
// built for talk: our noise suppression (RNNoise) erases sung fundamentals over
// ~523 Hz and much of a backing track, our AGC pulls loud singing down by up
// to 10 dB, WebRTC's APM (AEC/NS/AGC) and the phone's VOICE_COMMUNICATION
// path (its own AEC/NS/AGC in the HAL) do the same again, and DTX + a 64 kbps
// voice bitrate trim the rest.
//
// On, singer mode (all at runtime, mid-room; the audio device module is NOT
// rebuilt):
//  - our chain bypassed: no NS, no AGC, no pause expander; only the limiter
//    near clip (-1 dBFS) stays (Android; gx_ns music bypass);
//  - WebRTC voice processing off: NS, AGC, high-pass, and echo cancellation
//    unless [GravixSingerOptions.echoCancellation] (software and the phone's
//    platform effects; `LocalAudioTrack.setAudioProcessingOptions`);
//  - Android: the recorder re-opened with [GravixSingerOptions.captureSource]
//    (MIC by default, not the VOICE_COMMUNICATION call path); a capture restart
//    of tens to a few hundred ms;
//  - the sender's bitrate raised to [GravixSingerOptions.maxBitrate] (96 kbps
//    mono by default; RTCRtpSender parameters, no republish);
//  - DTX off ([GravixSingerOptions.disableDtx]): the only step that needs a
//    microphone republish (a NEW track on the same capture, an audible gap of
//    ~100-300 ms; listeners see the track change). Off it costs nothing.
//
// Off restores what the microphone had before (room music running: the music
// session's profile, which it restores at its own end).
//
// Not done (not cleanly possible mid-room, or not ours):
//  - the capture rate: the audio device module fixes it when WebRTC
//    initializes. The standard scenario captures at the device rate (48 kHz
//    on phones); GravixAudioScenario.chatRoom stays at 16 kHz;
//  - the audio mode: it is the audio session's (AudioManager.setAudioSessionOptions
//    already switches it at runtime). Singer mode leaves it: the playout's usage
//    (voice communication / media) is fixed when the module is built, the
//    session does no routing in MODE_NORMAL, and Bluetooth headsets use the
//    communication mode (the chatroom model). Agora/ZEGO pair MIC with the
//    normal mode + media volume; untested here (a device check);
//  - iOS: our chain, WebRTC processing, bitrate and DTX only (no capture
//    source; the iOS voice-processing unit is the audio session's);
//  - never switched on by itself (not on a wired route either): the app asks.
//
// Echo risk: with echo cancellation off, what the phone's SPEAKER plays (the
// other speakers, room music the phone plays out loud) goes back into the
// microphone and the room hears itself. Singer mode is for headphones / a
// sound card monitor; on the loudspeaker keep [GravixSingerOptions.echoCancellation]
// true (the platform/software AEC then still takes some of the voice too).

import 'package:flutter/foundation.dart';

import '../music/gravix_room_music.dart';
import '../rtc_core/gravix_client.dart';
import '../rtc_core/src/track/local/mic_republish.dart';

/// The Android capture source singer mode records from.
enum GravixSingerCaptureSource {
  /// Leave the source as it is (VOICE_COMMUNICATION under WebRTC's defaults).
  keep,

  /// MIC (default): no call-path processing on most phones; what Agora's
  /// game-streaming / headset chat room and ZEGO's KTV mode record from.
  mic,

  /// VOICE_RECOGNITION: the CDD requires noise reduction and AGC off on it.
  voiceRecognition,

  /// UNPROCESSED where the phone supports it (API 24+), else VOICE_RECOGNITION.
  /// Flat and raw; quiet on some built-in microphones (no gain is added).
  unprocessed,
}

/// What [GravixRoomService.setSingerMode] changes. See the file comment.
@immutable
class GravixSingerOptions {
  const GravixSingerOptions({
    this.echoCancellation = false,
    this.captureSource = GravixSingerCaptureSource.mic,
    this.disableDtx = true,
    this.maxBitrate = 96000,
  });

  /// Keep echo cancellation (WebRTC's / the phone's) on. Default false: for
  /// headphones or a sound card. True on the loudspeaker (see the echo risk).
  final bool echoCancellation;

  /// Android capture source while singer mode is on.
  final GravixSingerCaptureSource captureSource;

  /// Opus DTX off while singer mode is on (a microphone republish; false
  /// keeps the track as published).
  final bool disableDtx;

  /// The microphone sender's maximum bitrate (bps, mono Opus). 96000 is what
  /// room music already uses; 128000 is untested against the server's limits.
  final int maxBitrate;

  /// The WebRTC voice processing singer mode asks for.
  AudioProcessingOptions get processing => AudioProcessingOptions(
    echoCancellation: echoCancellation,
    noiseSuppression: false,
    autoGainControl: false,
    highPassFilter: false,
  );

  GravixSingerOptions copyWith({
    bool? echoCancellation,
    GravixSingerCaptureSource? captureSource,
    bool? disableDtx,
    int? maxBitrate,
  }) => GravixSingerOptions(
    echoCancellation: echoCancellation ?? this.echoCancellation,
    captureSource: captureSource ?? this.captureSource,
    disableDtx: disableDtx ?? this.disableDtx,
    maxBitrate: maxBitrate ?? this.maxBitrate,
  );

  @override
  bool operator ==(Object other) =>
      other is GravixSingerOptions &&
      other.echoCancellation == echoCancellation &&
      other.captureSource == captureSource &&
      other.disableDtx == disableDtx &&
      other.maxBitrate == maxBitrate;

  @override
  int get hashCode => Object.hash(echoCancellation, captureSource, disableDtx, maxBitrate);

  @override
  String toString() =>
      'GravixSingerOptions(echoCancellation: $echoCancellation, captureSource: ${captureSource.name}, '
      'disableDtx: $disableDtx, maxBitrate: $maxBitrate)';
}

/// What [GravixRoomService.setSingerMode] did.
@immutable
class GravixSingerModeState {
  const GravixSingerModeState({
    required this.on,
    this.options,
    this.micPublished = false,
    this.processingApplied = false,
    this.nativeApplied = false,
    this.bitrateApplied = false,
    this.republished = false,
    this.notes = const [],
  });

  /// Singer mode is on.
  final bool on;

  /// Its options (null when off).
  final GravixSingerOptions? options;

  /// A microphone was published (off: everything applies at its publish).
  final bool micPublished;

  /// WebRTC's voice processing took the singer (or the restored) options.
  final bool processingApplied;

  /// The native side took it (our chain bypass; the Android capture source is
  /// requested: the recorder restarts asynchronously and falls back to its
  /// original source if the phone refuses the new one).
  final bool nativeApplied;

  /// The sender's bitrate was set.
  final bool bitrateApplied;

  /// The microphone was republished (the DTX change).
  final bool republished;

  /// What did not apply, and why.
  final List<String> notes;

  @override
  String toString() =>
      'GravixSingerModeState(on: $on, mic: $micPublished, processing: $processingApplied, native: $nativeApplied, '
      'bitrate: $bitrateApplied, republished: $republished${notes.isEmpty ? '' : ', notes: $notes'})';
}

/// The published microphone as singer mode drives it (a seam for tests).
abstract class GravixSingerMic {
  AudioProcessingOptions get processing;
  Future<bool> setProcessing(AudioProcessingOptions o);

  /// DTX as published.
  bool get dtx;

  /// The sender's max bitrate (null: unknown / no sender).
  int? get maxBitrate;
  Future<bool> setMaxBitrate(int bps);

  /// Republishes with [dtx] / [maxBitrate] on a new track; null when it failed
  /// (the old one stays published).
  Future<GravixSingerMic?> republish({required bool dtx, required int maxBitrate});

  /// Same underlying track.
  bool sameAs(GravixSingerMic other);
}

/// Room music as singer mode sees it (a seam for tests).
abstract class GravixSingerMusicHooks {
  bool get sessionActive;
  bool get disableDtxWhileMusic;
  ({AudioProcessingOptions? processing, bool dtxSwapped, int? bitrate, bool bitrateApplied}) handOver();
  Future<bool> retake({
    required AudioProcessingOptions processingBefore,
    required bool dtxBefore,
    required int? bitrateBefore,
  });
}

class _Before {
  _Before(this.processing, this.dtx, this.bitrate);
  final AudioProcessingOptions processing;
  final bool dtx;
  final int? bitrate;
}

/// Singer mode's state machine (one per GravixRoomService). Calls are
/// serialised: the last one wins.
@internal
class GravixSingerModeController {
  GravixSingerModeController({required this.mic, required this.music, required this.native, required this.defaults});

  /// The published microphone (null: none).
  final GravixSingerMic? Function() mic;

  /// Room music (null: none attached).
  final GravixSingerMusicHooks? Function() music;

  /// The native side: (on, source) -> applied.
  final Future<bool> Function(bool on, GravixSingerCaptureSource source) native;

  /// The microphone's profile without singer mode (processing, DTX, bitrate):
  /// what it is restored to when it was published while singer mode was on.
  final ({AudioProcessingOptions processing, bool dtx, int bitrate}) Function() defaults;

  GravixSingerOptions? _options;
  _Before? _before;
  bool _dtxTried = false; // one DTX republish per enable (a failed one is not retried on every publish)
  Future<void> _queue = Future<void>.value();

  bool get active => _options != null;
  GravixSingerOptions? get options => _options;

  /// While on: the publish options' DTX / bitrate (null: not on).
  bool get dtxOff => _options?.disableDtx ?? false;
  int? get maxBitrate => _options?.maxBitrate;

  Future<GravixSingerModeState> set(bool on, [GravixSingerOptions options = const GravixSingerOptions()]) {
    final c = _queue.then((_) => on ? _enable(options) : _disable());
    _queue = c.then((_) {}, onError: (_) {});
    return c;
  }

  Future<GravixSingerModeState> _enable(GravixSingerOptions o) async {
    final notes = <String>[];
    final m = mic();
    if (m != null && _before == null) {
      final h = music();
      if (h != null && h.sessionActive) {
        final r = h.handOver();
        _before = _Before(
          r.processing ?? m.processing,
          r.dtxSwapped ? true : m.dtx,
          r.bitrateApplied ? r.bitrate : m.maxBitrate,
        );
      } else {
        _before = _Before(m.processing, m.dtx, m.maxBitrate);
      }
    }
    _options = o; // before any await: a music session starting now sees it held
    _dtxTried = false;
    final nativeOk = await _native(true, o.captureSource, notes);
    if (m == null) {
      notes.add('no microphone published: applies when it is');
      return GravixSingerModeState(on: true, options: o, nativeApplied: nativeOk, notes: notes);
    }
    final r = await _applyTo(m, o, notes);
    return GravixSingerModeState(
      on: true,
      options: o,
      micPublished: true,
      processingApplied: r.processing,
      nativeApplied: nativeOk,
      bitrateApplied: r.bitrate,
      republished: r.republished,
      notes: notes,
    );
  }

  Future<({bool processing, bool bitrate, bool republished})> _applyTo(
    GravixSingerMic m,
    GravixSingerOptions o,
    List<String> notes,
  ) async {
    var processing = true;
    if (!_sameProcessing(m.processing, o.processing)) {
      processing = await m.setProcessing(o.processing);
      if (!processing) notes.add('voice processing not changed');
    }
    if (o.disableDtx && m.dtx && !_dtxTried) {
      _dtxTried = true;
      final fresh = await m.republish(dtx: false, maxBitrate: o.maxBitrate);
      if (fresh != null) return (processing: processing, bitrate: true, republished: true);
      notes.add('DTX unchanged (republish failed)');
    }
    final bitrate = await _setBitrate(m, o.maxBitrate, notes);
    return (processing: processing, bitrate: bitrate, republished: false);
  }

  Future<GravixSingerModeState> _disable() async {
    final notes = <String>[];
    final was = _options;
    if (was == null) return const GravixSingerModeState(on: false);
    _options = null;
    final before = _before;
    _before = null;
    final nativeOk = await _native(false, GravixSingerCaptureSource.keep, notes);
    final m = mic();
    if (m == null) return GravixSingerModeState(on: false, nativeApplied: nativeOk, notes: notes);
    final d = defaults();
    final b = before ?? _Before(d.processing, d.dtx, d.bitrate);
    final h = music();
    var processing = false, bitrate = false, republished = false;
    var dtxHandled = false;
    if (h != null && h.sessionActive) {
      // the music session takes the microphone again and restores b at its end
      dtxHandled = await h.retake(processingBefore: b.processing, dtxBefore: b.dtx, bitrateBefore: b.bitrate);
      processing = true;
      bitrate = true;
      if (!dtxHandled && b.dtx && !m.dtx) {
        republished = await m.republish(dtx: true, maxBitrate: m.maxBitrate ?? d.bitrate) != null;
        if (!republished) notes.add('DTX not restored (republish failed)');
      }
    } else {
      processing = _sameProcessing(m.processing, b.processing) || await m.setProcessing(b.processing);
      if (!processing) notes.add('voice processing not restored');
      final rate = b.bitrate ?? d.bitrate;
      if (b.dtx != m.dtx) {
        republished = await m.republish(dtx: b.dtx, maxBitrate: rate) != null;
        if (!republished) notes.add('DTX not restored (republish failed)');
      }
      if (!republished) bitrate = await _setBitrate(m, rate, notes);
      if (republished) bitrate = true;
    }
    return GravixSingerModeState(
      on: false,
      micPublished: true,
      processingApplied: processing,
      nativeApplied: nativeOk,
      bitrateApplied: bitrate,
      republished: republished,
      notes: notes,
    );
  }

  /// A microphone was (re)published while singer mode is on (a join, a
  /// reconnect, a RED or music republish): singer processing + bitrate again.
  Future<void> onMicPublished() {
    final c = _queue.then((_) async {
      final o = _options;
      final m = mic();
      if (o == null || m == null) return;
      if (_before == null) {
        final d = defaults();
        _before = _Before(d.processing, d.dtx, d.bitrate);
      }
      final notes = <String>[];
      // the native side again (idempotent): a capture source asked for while
      // the audio device module was not up yet applies now
      await _native(true, o.captureSource, notes);
      await _applyTo(m, o, notes);
      if (notes.isNotEmpty) debugPrint('singer mode on the new microphone: $notes');
    });
    _queue = c.then((_) {}, onError: (_) {});
    return c;
  }

  Future<bool> _native(bool on, GravixSingerCaptureSource source, List<String> notes) async {
    try {
      final ok = await native(on, source);
      if (!ok) notes.add('native singer mode unavailable on this platform');
      return ok;
    } catch (e) {
      notes.add('native singer mode failed: $e');
      return false;
    }
  }

  Future<bool> _setBitrate(GravixSingerMic m, int bps, List<String> notes) async {
    if (m.maxBitrate == bps) return true;
    final ok = await m.setMaxBitrate(bps);
    if (!ok) notes.add('bitrate not set (no sender, or the mic is muted on the wire)');
    return ok;
  }

  static bool _sameProcessing(AudioProcessingOptions a, AudioProcessingOptions b) =>
      a.echoCancellation == b.echoCancellation &&
      a.noiseSuppression == b.noiseSuppression &&
      a.autoGainControl == b.autoGainControl &&
      a.highPassFilter == b.highPassFilter;
}

/// The published LocalAudioTrack as a [GravixSingerMic].
@internal
class GravixSingerTrackMic implements GravixSingerMic {
  GravixSingerTrackMic(this.local, this.track, {required this.stillWanted});

  final LocalParticipant local;
  final LocalAudioTrack track;
  final bool Function() stillWanted;

  @override
  AudioProcessingOptions get processing => track.currentOptions.processing;

  @override
  Future<bool> setProcessing(AudioProcessingOptions o) async {
    try {
      await track.setAudioProcessingOptions(o);
      return true;
    } catch (e) {
      debugPrint('singer mode: voice processing not changed: $e');
      return false;
    }
  }

  @override
  bool get dtx => track.lastPublishOptions?.dtx ?? true;

  @override
  int? get maxBitrate {
    final enc = track.sender?.parameters.encodings;
    return (enc == null || enc.isEmpty) ? null : enc.first.maxBitrate;
  }

  @override
  Future<bool> setMaxBitrate(int bps) async {
    final sender = track.sender;
    // muted on the wire: MicUplinkPause holds the sender at its mute cap and
    // gives back the rate it replaced; the next publish carries ours
    if (sender == null || track.wireMuted) return false;
    try {
      final params = sender.parameters;
      final enc = params.encodings;
      if (enc == null || enc.isEmpty) return false;
      final before = enc.first.maxBitrate;
      enc.first.maxBitrate = bps;
      if (await sender.setParameters(params)) return true;
      enc.first.maxBitrate = before; // the cache must match the native side
      return false;
    } catch (e) {
      debugPrint('singer mode: bitrate not set: $e');
      return false;
    }
  }

  @override
  Future<GravixSingerMic?> republish({required bool dtx, required int maxBitrate}) async {
    final base = track.lastPublishOptions ?? const AudioPublishOptions();
    final (fresh, ok) = await gravixRepublishMic(
      local,
      track,
      wanted: base.copyWith(
        dtx: dtx,
        encoding: AudioEncoding(maxBitrate: maxBitrate),
      ),
      fallback: base,
      stillWanted: stillWanted,
    );
    debugPrint('singer mode: microphone republished=${fresh != null} dtx=${ok ? dtx : base.dtx}');
    if (fresh == null || !ok) return null;
    return GravixSingerTrackMic(local, fresh, stillWanted: stillWanted);
  }

  @override
  bool sameAs(GravixSingerMic other) => other is GravixSingerTrackMic && identical(other.track, track);
}

/// [GravixRoomMusic] as [GravixSingerMusicHooks].
@internal
class GravixSingerRoomMusicHooks implements GravixSingerMusicHooks {
  GravixSingerRoomMusicHooks(this.music);
  final GravixRoomMusic music;

  @override
  bool get sessionActive => music.gravixSessionActive;

  @override
  bool get disableDtxWhileMusic => music.options.disableDtxWhileMusic;

  @override
  ({AudioProcessingOptions? processing, bool dtxSwapped, int? bitrate, bool bitrateApplied}) handOver() =>
      music.gravixHandOverMicProfile();

  @override
  Future<bool> retake({
    required AudioProcessingOptions processingBefore,
    required bool dtxBefore,
    required int? bitrateBefore,
  }) => music.gravixRetakeMicProfile(
    processingBefore: processingBefore,
    dtxBefore: dtxBefore,
    bitrateBefore: bitrateBefore,
  );
}
