// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:meta/meta.dart';

import '../internal/events.dart' show TrackEndedEvent;
import '../logger.dart';
import '../publication/local.dart';
import '../track/local/video.dart';
import '../track/options.dart';
import '../options.dart';

/// The camera a `Room.connect` publishes INSIDE the join (2026-10-13, fast
/// publish for video), so that it is part of the publisher connection's FIRST
/// offer - beside the join microphone ([GravixJoinMicrophone]) when both are
/// set.
///
/// Without it a video host's camera is a step after the join: its AddTrack and
/// a second offer/answer only start after `connect` returned.
///
/// With it:
///  * the camera is opened when each join attempt starts ([createTrack], or a
///    capture with [captureOptions]), in parallel with the signalling;
///  * at the JoinResponse its AddTrack goes out and its video transceiver is
///    added BEFORE the publisher's first offer is made. The publish is the
///    normal camera publish (`LocalParticipant.publishVideoTrack`): the same
///    codec choice (falling back to the server's enabled codecs), simulcast
///    layers, encodings, plan cap and start bitrate as [publishOptions] give
///    there;
///  * the first offer waits for the camera at most [offerWait] after the
///    JoinResponse (and for the join microphone, which waits for the camera
///    the same way, so that ONE offer carries both); a camera that is not ready
///    by then is published with an offer of its own once it is;
///  * join retries (`ConnectOptions.joinRetries`) keep working: an attempt that
///    fails releases its camera (and its publication) before the next attempt
///    starts, which opens and publishes the camera again - one camera
///    publication, never two;
///  * a camera that cannot be published (the capture failed or the permission
///    was denied, the track ended, no permission to publish a camera, the
///    server refused it) leaves the join to go on without it: the room emits
///    `GravixJoinCameraFailedEvent`, the camera is released, and the app may
///    publish a camera the normal way afterwards;
///  * the camera is released (stopped and disposed, then [onReleased]) on every
///    path that does not end in a publication: a failed attempt, a failed join,
///    a leave while joining, a leave after `connect` returned while the publish
///    was still in flight, a failure, "not wanted". A published camera belongs
///    to its publication from then on, as after a normal publish (a full
///    reconnect republishes it once; a resume keeps it).
///
/// EXPERIMENTAL (0.4.18): in device tests it gave no measurable speed-up for
/// the camera, and with the join microphone the microphone went live later (the
/// shared first offer waits for the camera). The API may change.
///
/// Opt-in (null = the old order). Pass it only when the camera permission is
/// already granted: the camera opens during the join, and an OS permission
/// dialog would come up in the middle of it.
@immutable
class GravixJoinCamera {
  const GravixJoinCamera({
    this.createTrack,
    this.captureOptions,
    this.publishOptions,
    this.offerWait = const Duration(seconds: 1),
    this.wanted,
    this.onReleased,
  });

  /// Creates the camera track for one join attempt (e.g. the app's own camera,
  /// or a preview track it opened already). Called once per attempt, when the
  /// attempt starts; from then on the room owns the track: it publishes it, or
  /// releases it. A retry calls it again, after the previous attempt's track was
  /// released: return a NEW track then (a disposed one cannot be published). A
  /// failure (no permission, no device) leaves the join to go on without a
  /// camera. Null: `LocalVideoTrack.createCameraTrack(captureOptions)`.
  final Future<LocalVideoTrack> Function()? createTrack;

  /// The capture when [createTrack] is null (null =
  /// `RoomOptions.defaultCameraCaptureOptions`).
  final CameraCaptureOptions? captureOptions;

  /// The publish options (null = `RoomOptions.defaultVideoPublishOptions`), as
  /// for `LocalParticipant.publishVideoTrack`: codec, simulcast and its layers,
  /// encoding, backup codec, degradation preference.
  final VideoPublishOptions? publishOptions;

  /// How long after the JoinResponse the publisher's first offer waits for a
  /// camera that is still opening. With the join microphone, the microphone
  /// waits as long (one offer for both).
  final Duration offerWait;

  /// Asked right before the publish: false = the app no longer wants the camera
  /// (it was turned off during the join): not published, released, no failure
  /// event. Asked again right after the publish: false = muted.
  final bool Function()? wanted;

  /// Called after the room released a camera track it did not publish (stopped
  /// and disposed it): for an app whose track is backed by a capture of its own
  /// that it closes separately. Errors are logged.
  final Future<void> Function(LocalVideoTrack track)? onReleased;

  /// Test seam: what a [createTrack]-less camera is captured with.
  @visibleForTesting
  static Future<LocalVideoTrack> Function(CameraCaptureOptions options)? debugCreateCameraTrack;

  /// Opens a camera with [options] (the [createTrack]-less path).
  @internal
  static Future<LocalVideoTrack> openCamera(CameraCaptureOptions options) {
    final seam = debugCreateCameraTrack;
    return seam != null ? seam(options) : LocalVideoTrack.createCameraTrack(options);
  }
}

/// Why the join's camera was not published (`GravixJoinCameraFailedEvent`).
enum GravixJoinCameraFailure {
  /// The camera could not be opened ([GravixJoinCamera.createTrack] threw: no
  /// permission, no device, the camera is in use).
  captureFailed,

  /// The track ended before it was published (e.g. another app took the camera).
  trackEnded,

  /// The participant may not publish a camera (its token's grant).
  notAllowed,

  /// The server refused the camera's AddTrack (e.g. above the plan's video cap).
  rejected,

  /// The session was replaced (a full reconnect) while the camera was being
  /// published; the new session does not have it.
  sessionReplaced,

  /// The publish failed otherwise.
  publishFailed,
}

/// One join attempt's camera (see [GravixJoinCamera]): its capture, the hold on
/// the publisher's first offer, the release when the attempt fails. Owned by
/// `Room.connect` (and by the room until its publish settled).
@internal
class GravixJoinCameraAttempt {
  GravixJoinCameraAttempt(this.options, {required this.attempt, required Future<LocalVideoTrack> Function() create}) {
    track = () async {
      final t = await create();
      _created = t;
      _endedCancel = t.events.on<TrackEndedEvent>((_) {
        if (!_ended.isCompleted) _ended.complete();
      });
      if (_aborted.isCompleted) {
        // the attempt ended while the camera was opening
        await release();
        throw const _JoinCameraAborted();
      }
      return t;
    }();
    // nothing may leave this future's error unhandled
    track.ignore();
  }

  final GravixJoinCamera options;

  /// 1-based join attempt of this `Room.connect` call.
  final int attempt;

  /// The opened camera (an error when it could not be opened).
  late final Future<LocalVideoTrack> track;

  LocalVideoTrack? _created;
  Function? _endedCancel;
  final _offer = Completer<bool>();
  final _aborted = Completer<void>();
  final _ended = Completer<void>();

  /// The publish of this attempt, once the JoinResponse started it.
  Future<LocalTrackPublication<LocalVideoTrack>?>? publishing;

  /// Its publication, once published.
  LocalTrackPublication<LocalVideoTrack>? publication;

  /// Whether the publish asked for the publisher's FIRST offer; null until the
  /// publish negotiated.
  bool? inFirstOffer;

  /// Why the camera was not published (null: published, still publishing, or
  /// not wanted); set once.
  GravixJoinCameraFailure? failure;
  Object? failureError;

  /// Set by the room: the other join publishes of this attempt (the join
  /// microphone) to wait for before this one negotiates (one first offer).
  Future<void> Function()? peersReady;

  bool get started => publishing != null;
  bool get isAborted => _aborted.isCompleted;
  bool get hasEnded => _ended.isCompleted;

  /// Completes when the attempt is abandoned (its AddTrack wait ends at once).
  Future<void> get abortSignal => _aborted.future;

  /// The hold on the publisher's join-time offer: true when the publish asked
  /// for that offer itself, false when it gave up (bounded:
  /// [GravixJoinCamera.offerWait] plus a margin).
  Future<bool> offerHold() => _offer.future.timeout(options.offerWait + _holdMargin, onTimeout: () => false);
  static const _holdMargin = Duration(seconds: 1);

  /// Releases the hold; [tookOver] = the publish negotiates the offer itself.
  bool releaseOffer(bool tookOver) {
    if (_offer.isCompleted) return false;
    _offer.complete(tookOver);
    return true;
  }

  /// The publish is about to ask for the publisher's offer with the camera's
  /// transceiver in it. [firstOffer]: no offer was asked for before.
  void noteNegotiating({required bool firstOffer}) {
    inFirstOffer = firstOffer;
    releaseOffer(true);
  }

  /// Records why the camera was not published (the first reason wins).
  void fail(GravixJoinCameraFailure reason, [Object? error]) {
    if (failure != null) return;
    failure = reason;
    failureError = error;
  }

  /// The opened camera for the first offer: waits up to
  /// [GravixJoinCamera.offerWait] with the offer held, then releases it and
  /// waits on (the publish then makes its own offer). Null when the attempt was
  /// abandoned, the capture failed ([failure] says which) or the track ended.
  Future<LocalVideoTrack?> trackForPublish() async {
    final timer = Timer(options.offerWait, () {
      if (releaseOffer(false)) {
        logger.fine('join camera: not ready after ${options.offerWait.inMilliseconds} ms; offer released');
      }
    });
    try {
      final t = await Future.any<LocalVideoTrack?>([
        track,
        _aborted.future.then((_) => null),
        _ended.future.then((_) => null),
      ]);
      if (t == null || isAborted) return null;
      if (hasEnded) return null;
      return t;
    } catch (e) {
      logger.warning('join camera: the camera could not be opened ($e); the join goes on without it');
      fail(GravixJoinCameraFailure.captureFailed, e);
      return null;
    } finally {
      if (hasEnded && !isAborted) fail(GravixJoinCameraFailure.trackEnded);
      timer.cancel();
    }
  }

  /// The attempt is over (failed, left): ends the publish's waits, releases the
  /// hold. Idempotent.
  void abort() {
    if (!_aborted.isCompleted) _aborted.complete();
    releaseOffer(false);
  }

  /// The camera, once created (null while it is opening or when it could not be).
  LocalVideoTrack? get createdTrack => _created;

  bool _released = false;

  /// Stops and disposes the camera that was not published (one still opening:
  /// when it opens), then tells [GravixJoinCamera.onReleased]. Idempotent.
  Future<void> release() async {
    final t = _created;
    if (t == null) {
      // still opening (or it failed): released when it opens
      unawaited(track.then((_) => release(), onError: (Object _) {}));
      return;
    }
    if (_released) return;
    _released = true;
    _endedCancel?.call();
    _endedCancel = null;
    try {
      await t.stop();
    } catch (e) {
      logger.warning('join camera: stop failed: $e');
    }
    try {
      if (!t.isDisposed) await t.dispose();
    } catch (e) {
      logger.warning('join camera: dispose failed: $e');
    }
    final cb = options.onReleased;
    if (cb != null) {
      try {
        await cb(t);
      } catch (e) {
        logger.warning('join camera: onReleased failed: $e');
      }
    }
  }

  /// The camera is published: its publication owns it from now on.
  void notePublished(LocalTrackPublication<LocalVideoTrack> pub) {
    publication = pub;
    _endedCancel?.call();
    _endedCancel = null;
  }

  bool _undone = false;

  /// Abandons the attempt's camera: [abort], waits (bounded) for the publish to
  /// settle, unpublishes it ([unpublish], given the publication) and releases
  /// the camera - also one still opening. Idempotent.
  Future<void> undo({Future<void> Function(LocalTrackPublication<LocalVideoTrack> pub)? unpublish}) async {
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
        logger.warning('join camera: unpublish failed: $e');
      }
    }
    // after the unpublish (which disposes, and stops only with
    // stopLocalTrackOnUnpublish): the capture is closed in every case
    await release();
  }

  static const _settleWait = Duration(seconds: 2);
}

class _JoinCameraAborted implements Exception {
  const _JoinCameraAborted();
  @override
  String toString() => 'join camera: the join attempt ended';
}
