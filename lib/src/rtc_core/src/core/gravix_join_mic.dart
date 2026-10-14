// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:meta/meta.dart';

import '../logger.dart';
import '../publication/local.dart';
import '../track/local/audio.dart';
import '../options.dart';

/// The microphone a `Room.connect` publishes INSIDE the join (2026-10-12, fast
/// publish), so that it is part of the publisher connection's FIRST offer.
///
/// Without it a host's microphone is a second step after the join: the
/// publisher connection is negotiated once at the JoinResponse (data channels
/// only), and the microphone publish (capture start, AddTrack, a second
/// offer/answer) only starts after `connect` returned. A host's mic then went
/// live about 0.9 s after the room was connected on a phone 6 ms from its SFU.
///
/// With it:
///  * [createTrack] is called when each join attempt starts and the capture is
///    started right away, in parallel with the signalling;
///  * at the JoinResponse the AddTrack request goes out and the audio
///    transceiver is added BEFORE the publisher's first offer is made, so the
///    microphone flows as soon as the publisher connection connects (the
///    server accepts tracks in the first offer: it matches the offer's media to
///    the pending AddTrack by its cid);
///  * the publisher's first offer waits for the capture at most [offerWait]
///    after the JoinResponse; a capture that is not ready by then is published
///    with its own offer once it is (the order before this option existed);
///  * join retries (`ConnectOptions.joinRetries`) keep working: an attempt that
///    fails stops and disposes its capture (and its publication) before the
///    next attempt starts, and the next attempt captures and publishes again -
///    one microphone publication, never two;
///  * a join that fails or is left stops and disposes the capture before
///    `connect` returns: the OS microphone indicator does not stay on.
///
/// Opt-in (null = the old order). Pass it only when the microphone permission
/// is already granted: the capture starts during the join, and an OS
/// permission dialog would come up in the middle of it.
@immutable
class GravixJoinMicrophone {
  const GravixJoinMicrophone({
    required this.createTrack,
    this.publishOptions,
    this.offerWait = const Duration(seconds: 1),
    this.wanted,
    this.muted = false,
  });

  /// GRAVIX (2026-10-13, opt-in): the microphone goes into the first offer
  /// MUTED and WITHOUT a capture: [createTrack]'s track is stopped before the
  /// publish (its native track released; the capture is never started), the
  /// AddTrack says muted, and the audio transceiver has no track on its sender,
  /// so no audio packet can be sent. The server keeps the track pending (no
  /// media) and shows it to nobody. `LocalParticipant.setMicrophoneEnabled(true)`
  /// later (e.g. a host taking a seat) opens the capture on that sender and
  /// signals the unmute: no AddTrack, no second offer/answer at that moment.
  /// Needs a token that may publish a microphone at the join (a listener without
  /// publish permission gets nothing published; the join goes on). [wanted] is
  /// still asked before the publish (false = not published).
  final bool muted;

  /// Creates the microphone track for one join attempt (not started; the room
  /// starts it). Called once per attempt, at the attempt's start. A failure
  /// (no permission, no device) leaves the join to go on without a microphone.
  final Future<LocalAudioTrack> Function() createTrack;

  /// The publish options (null = `RoomOptions.defaultAudioPublishOptions`).
  final AudioPublishOptions? publishOptions;

  /// How long after the JoinResponse the publisher's first offer waits for a
  /// capture that is still starting.
  final Duration offerWait;

  /// Asked right before the publish and right after it: false = the app no
  /// longer wants the microphone (a mute tapped during the join). Before: the
  /// microphone is not published (the capture is stopped). After: it is muted.
  final bool Function()? wanted;
}

/// One join attempt's microphone (see [GravixJoinMicrophone]): its capture,
/// the hold on the publisher's first offer, and the undo when the attempt
/// fails. Owned by `Room.connect`.
@internal
class GravixJoinMicAttempt {
  GravixJoinMicAttempt(this.options, {required this.attempt}) {
    // the capture starts now, in parallel with the dial
    track = () async {
      final t = await options.createTrack();
      _created = t;
      if (_aborted.isCompleted) {
        // the attempt ended while the track was being created
        await _dispose(t);
        throw const _JoinMicAborted();
      }
      try {
        if (options.muted) {
          // muted join microphone: no capture until the app enables it
          // disabled first (a track the app started already sends nothing
          // more), then stopped: the native track is released
          t.mediaStreamTrack.enabled = false;
          t.updateMuted(true, shouldNotify: false);
          await t.stop();
        } else {
          await t.start();
        }
      } catch (e) {
        await _dispose(t);
        rethrow;
      }
      return t;
    }();
    // nothing may leave this future's error unhandled
    track.ignore();
  }

  final GravixJoinMicrophone options;

  /// 1-based join attempt of this `Room.connect` call.
  final int attempt;

  /// The started capture (an error when it could not be created or started).
  late final Future<LocalAudioTrack> track;

  LocalAudioTrack? _created;
  final _offer = Completer<bool>();
  final _aborted = Completer<void>();

  /// The publish of this attempt, once the JoinResponse started it.
  Future<LocalTrackPublication<LocalAudioTrack>?>? publishing;

  /// Its publication, once published.
  LocalTrackPublication<LocalAudioTrack>? publication;

  /// Whether the publish asked for the publisher's FIRST offer (the microphone
  /// is in it); null until the publish negotiated.
  bool? inFirstOffer;

  /// Set by the room when the join's camera (GravixJoinCamera) is published
  /// in the same first offer: waited for between the transceiver and the
  /// negotiation, so that one offer carries both. Null = the microphone alone.
  Future<void> Function()? peersReady;

  bool get started => publishing != null;
  bool get isAborted => _aborted.isCompleted;

  /// Completes when the attempt is abandoned (its AddTrack wait ends at once).
  Future<void> get abortSignal => _aborted.future;

  /// The engine's hold on the publisher's join-time offer: true when the
  /// publish asked for that offer itself, false when the engine makes it
  /// (bounded: [GravixJoinMicrophone.offerWait] plus a margin, in case nothing
  /// releases it).
  Future<bool> offerHold() => _offer.future.timeout(options.offerWait + _holdMargin, onTimeout: () => false);
  static const _holdMargin = Duration(seconds: 1);

  /// Releases the hold; [tookOver] = the publish negotiates the offer itself.
  /// Returns whether this call released it (false: it was released already).
  bool releaseOffer(bool tookOver) {
    if (_offer.isCompleted) return false;
    _offer.complete(tookOver);
    return true;
  }

  /// The publish is about to ask for the publisher's offer with the
  /// microphone's transceiver in it: releases the hold (the engine does not make
  /// an offer of its own). [firstOffer]: no offer was asked for before.
  void noteNegotiating({required bool firstOffer}) {
    inFirstOffer = firstOffer;
    releaseOffer(true);
  }

  /// The started capture for the first offer: waits up to
  /// [GravixJoinMicrophone.offerWait] with the offer held, then releases it and
  /// waits on (the publish then makes its own offer). Null when the attempt was
  /// abandoned or the capture failed.
  Future<LocalAudioTrack?> trackForPublish() async {
    final timer = Timer(options.offerWait, () {
      if (releaseOffer(false)) {
        logger.fine('join microphone: capture not ready after ${options.offerWait.inMilliseconds} ms; offer released');
      }
    });
    try {
      return await Future.any<LocalAudioTrack?>([track, _aborted.future.then((_) => null)]);
    } catch (e) {
      logger.warning('join microphone: capture failed ($e); the join goes on without it');
      releaseOffer(false);
      return null;
    } finally {
      timer.cancel();
    }
  }

  /// The attempt is over (failed, left, or its microphone is not wanted): ends
  /// the publish's waits, releases the hold. Idempotent.
  void abort() {
    if (!_aborted.isCompleted) _aborted.complete();
    releaseOffer(false);
  }

  /// The capture, once created (null while it is being created or when it
  /// could not be).
  LocalAudioTrack? get createdTrack => _created;

  /// Stops and disposes the capture (one still being created: when it
  /// completes). Does not wait for the publish. Idempotent.
  void disposeCapture() {
    final created = _created;
    if (created != null) {
      unawaited(_dispose(created));
    } else {
      unawaited(track.then(_dispose, onError: (Object _) {}));
    }
  }

  bool _undone = false;

  /// Abandons the attempt's microphone: [abort], waits (bounded) for the
  /// publish to settle, unpublishes it ([unpublish], given the publication)
  /// and stops and disposes the capture - also one still being created (when
  /// it completes). Idempotent.
  Future<void> undo({Future<void> Function(LocalTrackPublication<LocalAudioTrack> pub)? unpublish}) async {
    abort();
    if (_undone) return;
    _undone = true;
    final p = publishing;
    if (p != null) {
      try {
        await p.timeout(_settleWait, onTimeout: () => null);
      } catch (_) {}
    }
    final pub = publication;
    publication = null;
    if (pub != null && unpublish != null) {
      try {
        await unpublish(pub);
      } catch (e) {
        logger.warning('join microphone: unpublish failed: $e');
      }
    }
    final created = _created;
    if (created != null) {
      await _dispose(created);
    } else {
      // still being created: disposed when it completes (the track future
      // sees the abort)
      unawaited(track.then(_dispose, onError: (Object _) {}));
    }
  }

  static const _settleWait = Duration(seconds: 2);

  static Future<void> _dispose(LocalAudioTrack t) async {
    try {
      await t.stop();
    } catch (e) {
      logger.warning('join microphone: stop failed: $e');
    }
    try {
      if (!t.isDisposed) await t.dispose();
    } catch (e) {
      logger.warning('join microphone: dispose failed: $e');
    }
  }
}

class _JoinMicAborted implements Exception {
  const _JoinMicAborted();
  @override
  String toString() => 'join microphone: the join attempt ended';
}
