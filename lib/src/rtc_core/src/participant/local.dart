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

// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:async/async.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:meta/meta.dart';
import 'package:mime_type/mime_type.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';

import '../core/engine.dart';
import '../core/gravix_join_camera.dart';
import '../core/gravix_join_mic.dart';
import '../core/room.dart';
import '../core/signal_client.dart';
import '../core/gravix_pub_log.dart';
import '../core/transport.dart';
import '../data_stream/stream_writer.dart';
import '../events.dart';
import '../exceptions.dart';
import '../extensions.dart';
import '../internal/events.dart';
import '../logger.dart';
import '../managers/android_screen_capture.dart';
import '../managers/broadcast_manager.dart';
import '../managers/gravix_foreground_service.dart';
import '../options.dart';
import '../proto/gravixcloud_models.pb.dart' as lk_models;
import '../proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import '../publication/local.dart';
import '../support/platform.dart';
import '../track/local/audio.dart';
import '../track/local/local.dart';
import '../track/local/video.dart';
import '../track/options.dart';
import '../types/audio_encoding.dart';
import '../types/data_stream.dart';
import '../types/other.dart';
import '../types/participant_permissions.dart';
import '../types/video_cap.dart';
import '../types/video_dimensions.dart';
import '../utils.dart'
    show buildStreamId, computeStartTargetBitrate, mimeTypeToVideoCodecString, Utils, isSVCCodec, isVideoCodec;
import 'gravix_publish_runners.dart';
import 'participant.dart';

/// Represents the current participant in the room. Instance of [LocalParticipant] is automatically
/// created after successfully connecting to a [Room] and will be accessible from [Room.localParticipant].
class LocalParticipant extends Participant<LocalTrackPublication> {
  // Pending signal request responses (keyed by requestId)
  final Map<int, Completer<void>> _pendingSignalRequests = {};

  // Serializes publish operations to prevent duplicate tracks from concurrent calls
  // GRAVIX (0.4.8): one runner per source group instead of one for all (camera
  // beside microphone); see gravix_publish_runners.dart. GravixFastJoin off =
  // the single upstream runner.
  final _publishRunners = GravixPublishRunners<LocalTrackPublication?>();

  LocalParticipant._({required Room room, required String sid, required String identity, required String name})
    : super(room: room, sid: sid, identity: identity, name: name);

  @internal
  static Future<LocalParticipant> createFromInfo({required Room room, required lk_models.ParticipantInfo info}) async {
    final participant = LocalParticipant._(room: room, sid: info.sid, identity: info.identity, name: info.name);

    await participant.updateFromInfo(info);

    if (lkPlatformIs(PlatformType.iOS)) {
      BroadcastManager().addListener(participant._broadcastStateChanged);
    }

    participant.onDispose(() async {
      BroadcastManager().removeListener(participant._broadcastStateChanged);
      // Fail any pending signal requests
      for (final completer in participant._pendingSignalRequests.values) {
        if (!completer.isCompleted) {
          completer.completeError(UnexpectedStateException('Participant disposed'));
        }
      }
      participant._pendingSignalRequests.clear();
      await participant.unpublishAllTracks();
    });

    return participant;
  }

  @override
  @internal
  Future<bool> updateFromInfo(lk_models.ParticipantInfo info) async {
    final capBefore = GravixVideoCap.parse(attributes);
    final didUpdate = await super.updateFromInfo(info);
    if (!didUpdate) return false;

    // The plan cap can change mid-session (plan up/downgrade). Only a LOWER
    // cap needs action on live senders; see [_applyVideoCapToPublished].
    final capAfter = GravixVideoCap.parse(attributes);
    if (capAfter != null && (capBefore == null || capAfter < capBefore)) {
      unawaited(_applyVideoCapToPublished(capAfter));
    }

    // Reconcile local mute state with the server's copy.
    for (final trackInfo in info.tracks) {
      final pub = trackPublications[trackInfo.sid];
      if (pub == null) continue;

      // a voice-only mute (room music) is live on the wire
      final localMuted = pub.track?.wireMuted ?? pub.muted;
      if (localMuted != trackInfo.muted) {
        logger.fine('updating server mute state after reconcile, track: ${trackInfo.sid}, muted: $localMuted');
        try {
          room.engine.signalClient.sendMuteTrack(trackInfo.sid, localMuted);
        } catch (e) {
          logger.warning('Failed to update server mute state after reconcile: $e');
        }
      }
    }

    return true;
  }

  /// Effective short-edge cap for a video track of [source] from the
  /// server-owned `gravix.max_video_height` attribute; null = no cap known.
  int? _videoCapFor(TrackSource source) {
    final cap = GravixVideoCap.parse(attributes);
    if (cap == null) return null;
    return GravixVideoCap.effective(cap, isScreenShare: source == TrackSource.screenShareVideo);
  }

  /// Best-effort: bring already-published video under a newly LOWERED cap.
  ///
  /// Capture can't be changed without a republish, so each sender encoding
  /// whose output short edge is above the cap gets a larger
  /// `scaleResolutionDownBy`. Limits (documented, accepted):
  ///  • the layer sizes the SFU was told at addTrack are not re-announced
  ///    (this core has no UpdateLocalVideoTrack sender), so the SFU may still
  ///    treat the old top layer as above-cap and stop forwarding it; lower
  ///    layers keep flowing;
  ///  • backup-codec senders and legacy-SVC senders are left as-is.
  /// A RAISED cap is not applied to live senders — it takes effect on the
  /// next publish. That is conservative: never above the cap, never rejected.
  Future<void> _applyVideoCapToPublished(int planCap) async {
    for (final pub in videoTrackPublications) {
      final track = pub.track;
      final sender = track?.transceiver?.sender;
      if (track == null || sender == null) continue;
      final cap = GravixVideoCap.effective(planCap, isScreenShare: track.source == TrackSource.screenShareVideo);
      final source = track.currentOptions.params.dimensions;
      if (source.min() <= 0) continue;
      try {
        final params = sender.parameters;
        final encodings = params.encodings;
        if (encodings == null || encodings.isEmpty) continue;
        var changed = false;
        for (final e in encodings) {
          final scale = e.scaleResolutionDownBy ?? 1.0;
          if (source.min() / scale > cap) {
            e.scaleResolutionDownBy = source.min() / cap;
            changed = true;
          }
        }
        if (!changed) continue;
        params.encodings = encodings;
        await sender.setParameters(params);
        logger.info('applied lowered video cap ${cap}p to ${pub.sid}');
      } catch (e) {
        logger.warning('failed to apply lowered video cap to ${pub.sid}: $e');
      }
    }
  }

  /// Handle broadcast state change (iOS only)
  void _broadcastStateChanged() {
    final isEnabled = BroadcastManager().isBroadcasting && BroadcastManager().shouldPublishTrack;
    // Listener must stay sync (void), so use unawaited here.
    unawaited(setScreenShareEnabled(isEnabled));
  }

  /// Publish an [AudioTrack] to the [Room].
  /// For most cases, using [setMicrophoneEnabled] would be simpler and recommended.
  Future<LocalTrackPublication<LocalAudioTrack>> publishAudioTrack(
    LocalAudioTrack track, {
    AudioPublishOptions? publishOptions,
  }) async {
    final result = await _publishRunners
        .forSource(track.source)
        .run(() => _publishAudioTrack(track, publishOptions: publishOptions));
    return result! as LocalTrackPublication<LocalAudioTrack>;
  }

  /// GRAVIX (2026-10-12, fast publish): publishes the join's microphone
  /// ([GravixJoinMicAttempt], see GravixJoinMicrophone) at the JoinResponse,
  /// on the microphone's publish queue: a setMicrophoneEnabled that comes in
  /// meanwhile (GravixRoomService's mic step) waits for it and then finds the
  /// publication instead of publishing a second microphone. Null when nothing
  /// was published (the attempt ended, the capture failed, the microphone is
  /// not wanted any more, or one is published already); the hold on the
  /// publisher's first offer is released in every case.
  @internal
  Future<LocalTrackPublication<LocalAudioTrack>?> gravixPublishJoinMicrophone(GravixJoinMicAttempt join) async {
    final result = await _publishRunners.forSource(TrackSource.microphone).run(() async {
      if (join.isAborted) return null;
      if (getTrackPublicationBySource(TrackSource.microphone) != null) {
        logger.fine('join microphone: a microphone is published already');
        join.releaseOffer(false);
        return null;
      }
      final track = await join.trackForPublish();
      if (track == null || join.isAborted) return null;
      if (!(join.options.wanted?.call() ?? true)) {
        logger.fine('join microphone: not wanted any more; not published');
        join.releaseOffer(false);
        return null;
      }
      return _publishAudioTrack(
        track,
        publishOptions: join.options.publishOptions,
        gravixJoin: join,
        // a muted join microphone: a transceiver without a track (no capture,
        // nothing can be sent), the AddTrack muted
        gravixDetached: join.options.muted,
      );
    });
    final pub = result as LocalTrackPublication<LocalAudioTrack>?;
    // a mute tapped while the publish was in flight
    if (pub != null && !join.isAborted && !(join.options.wanted?.call() ?? true)) {
      await pub.mute(stopOnMute: room.roomOptions.defaultAudioCaptureOptions.stopAudioCaptureOnMute);
    }
    return pub;
  }

  Future<LocalTrackPublication<LocalAudioTrack>?> _publishAudioTrack(
    LocalAudioTrack track, {
    AudioPublishOptions? publishOptions,
    // GRAVIX (0.4.15): republish a muted track whose capture is stopped without
    // a capture (see rePublishAllTracks)
    bool gravixDetached = false,
    // GRAVIX (2026-10-12, fast publish): the join's microphone. The AddTrack
    // and the transceiver go out side by side (whatever enabledPublishCodecs
    // says: the sequential branch adds the transceiver one round trip later);
    // the AddTrack wait ends when the join attempt does.
    GravixJoinMicAttempt? gravixJoin,
  }) async {
    if (audioTrackPublications.any((e) => e.track?.mediaStreamTrack.id == track.mediaStreamTrack.id)) {
      throw TrackPublishException('track already exists');
    }

    // Use defaultPublishOptions if options is null
    publishOptions ??= track.lastPublishOptions ?? room.roomOptions.defaultAudioPublishOptions;

    final audioEncoding = publishOptions.encoding ?? AudioEncoding.presetMusic;
    final List<rtc.RTCRtpEncoding> encodings = [audioEncoding.toRTCRtpEncoding()];

    final shouldStopOnFailure = !track.isActive && !gravixDetached;
    try {
      // Start capture before signaling so create-time audio processing failures
      // abort publish without creating a server-side publication.
      // (A detached republish has no capture to start: the unmute restarts it.)
      if (!gravixDetached) await track.start();

      // GRAVIX (2026-10-21, DTX): a stereo preset publishes stereo, without DTX
      final opusShape = gravixOpusPublishShape(publishOptions);

      final req = lk_rtc.AddTrackRequest(
        cid: track.getCid(),
        name: publishOptions.name ?? AudioPublishOptions.defaultMicrophoneName,
        type: track.kind.toPBType(),
        source: track.source.toPBType(),
        muted: track.wireMuted,
        stream: buildStreamId(publishOptions, track.source),
        disableDtx: !opusShape.dtx,
        disableRed: gravixDisableRed(e2ee: room.e2eeManager != null, red: publishOptions.red),
        encryption: room.roomOptions.lkEncryptionType,
      );

      // GRAVIX (2026-10-21, DTX): the answer for this section carries usedtx=1
      // (unless dtx is off) and stereo=1 only for a stereo publication, whatever
      // the SFU mirrored
      room.engine.publisher?.gravixSetOpusPin(track.getCid(), dtx: opusShape.dtx, stereo: opusShape.stereo);

      // Populate audio features (e.g., TF_STEREO, TF_NO_DTX, TF_PRECONNECT_BUFFER)
      req.audioFeatures.addAll([
        if (opusShape.stereo) lk_models.AudioTrackFeature.TF_STEREO,
        if (!opusShape.dtx) lk_models.AudioTrackFeature.TF_NO_DTX,
        if (publishOptions.preConnect) lk_models.AudioTrackFeature.TF_PRECONNECT_BUFFER,
      ]);

      Future<lk_models.TrackInfo> negotiate(AudioPublishOptions options) async {
        track.transceiver = await room.engine.createTransceiverRTCRtpSender(
          track,
          options,
          encodings,
          gravixDetached: gravixDetached,
        );
        // GRAVIX (2026-10-12): the join's microphone takes over the publisher's
        // held first offer (no await between: the engine must not make it too)
        gravixJoin?.noteNegotiating(firstOffer: !room.engine.gravixHasNegotiated);
        // GRAVIX (2026-10-13): with the join's camera, the offer is made once its
        // transceiver is added too (or it gave up): one first offer for both
        final peers = gravixJoin?.peersReady;
        if (peers != null) {
          await peers();
          if (gravixJoin!.isAborted) return lk_models.TrackInfo();
        }
        await room.engine.negotiate();
        return lk_models.TrackInfo();
      }

      late lk_models.TrackInfo trackInfo;
      if (gravixJoin != null || (room.engine.enabledPublishCodecs?.isNotEmpty ?? false)) {
        final rets = await Future.wait<lk_models.TrackInfo>([
          room.engine.addTrack(req, gravixAbort: gravixJoin?.abortSignal),
          negotiate(publishOptions),
        ]);
        trackInfo = rets[0];
      } else {
        trackInfo = await room.engine.addTrack(req);

        final transceiverInit = rtc.RTCRtpTransceiverInit(
          direction: rtc.TransceiverDirection.SendOnly,
          sendEncodings: encodings,
        );
        // addTransceiver cannot pass in a kind parameter due to a bug in flutter-webrtc (web)
        final pc = room.engine.publisher?.pc;
        // a detached republish: a transceiver of the kind, no track (the
        // interface's track parameter is non-nullable, so it is left out)
        track.transceiver = gravixDetached
            ? await pc?.addTransceiver(kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio, init: transceiverInit)
            : await pc?.addTransceiver(
                track: track.mediaStreamTrack,
                kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio,
                init: transceiverInit,
              );

        await room.engine.negotiate();
      }

      logger.fine('publishAudioTrack engine.addTrack response: ${trackInfo}');

      track.lastPublishOptions = publishOptions;

      final pub = LocalTrackPublication<LocalAudioTrack>(participant: this, info: trackInfo, track: track);
      addTrackPublication(pub);
      if (track.source == TrackSource.microphone) {
        // background capture needs the service's microphone type (when enabled)
        unawaited(GravixForegroundService.roomPublished(room, microphone: true));
      }

      // did publish
      await track.onPublish();
      await track.processor?.onPublish(room);

      final listener = track.createListener();
      listener.on((TrackEndedEvent event) async {
        logger.fine('TrackEndedEvent: ${event.track}');
        await removePublishedTrack(pub.sid);
      });

      [events, room.events].emit(LocalTrackPublishedEvent(participant: this, publication: pub));

      return pub;
    } catch (error) {
      if (shouldStopOnFailure) {
        try {
          await track.stop();
        } catch (stopError) {
          logger.warning('failed to stop audio track after publish failure: $stopError');
        }
      }
      rethrow;
    }
  }

  /// Publish a [LocalVideoTrack] to the [Room].
  /// For most cases, using [setCameraEnabled] would be simpler and recommended.
  Future<LocalTrackPublication<LocalVideoTrack>> publishVideoTrack(
    LocalVideoTrack track, {
    VideoPublishOptions? publishOptions,
  }) async {
    if (_gravixJoinCameraBusy != null) await _gravixAfterJoinCamera(track.source);
    final result = await _publishRunners
        .forSource(track.source)
        .run(() => _publishVideoTrack(track, publishOptions: publishOptions));
    return result! as LocalTrackPublication<LocalVideoTrack>;
  }

  /// GRAVIX (2026-10-13, fast publish for video): publishes the join's camera
  /// ([GravixJoinCameraAttempt], see GravixJoinCamera) at the JoinResponse, on
  /// the camera's publish queue (a setCameraEnabled meanwhile waits for it and
  /// finds the publication). The normal camera publish ([_publishVideoTrack]):
  /// codec, simulcast layers and encodings are the normal path's. Null when
  /// nothing was published (the attempt ended, the camera could not be opened
  /// or ended, it is not wanted any more, or a camera is published already);
  /// the hold on the publisher's first offer is released in every case. The
  /// caller releases a camera that was not published.
  @internal
  Future<LocalTrackPublication<LocalVideoTrack>?> gravixPublishJoinCamera(GravixJoinCameraAttempt join) async {
    final run = _publishRunners.forJoinCamera.run(() async {
      if (join.isAborted) return null;
      if (getTrackPublicationBySource(TrackSource.camera) != null) {
        logger.fine('join camera: a camera is published already');
        join.releaseOffer(false);
        return null;
      }
      final track = await join.trackForPublish();
      if (track == null || join.isAborted) return null;
      if (!(join.options.wanted?.call() ?? true)) {
        logger.fine('join camera: not wanted any more; not published');
        join.releaseOffer(false);
        return null;
      }
      if (getTrackPublicationBySource(TrackSource.camera) != null) {
        logger.fine('join camera: a camera is published already');
        join.releaseOffer(false);
        return null;
      }
      return _publishVideoTrack(track, publishOptions: join.options.publishOptions, gravixJoin: join);
    });
    final busy = run.then<void>((_) {}, onError: (Object _) {});
    _gravixJoinCameraBusy = busy;
    final LocalTrackPublication? result;
    try {
      result = await run;
    } finally {
      if (identical(_gravixJoinCameraBusy, busy)) _gravixJoinCameraBusy = null;
    }
    final pub = result as LocalTrackPublication<LocalVideoTrack>?;
    // turned off while the publish was in flight
    if (pub != null && !join.isAborted && !(join.options.wanted?.call() ?? true)) {
      await pub.mute(stopOnMute: room.roomOptions.defaultCameraCaptureOptions.stopCameraCaptureOnMute);
    }
    return pub;
  }

  /// GRAVIX (2026-10-13): the join's camera publish in flight (see
  /// [gravixPublishJoinCamera]); the app's camera publishes wait for it, then
  /// find its publication instead of opening a second camera.
  Future<void>? _gravixJoinCameraBusy;

  Future<void> _gravixAfterJoinCamera(TrackSource source) async {
    final busy = _gravixJoinCameraBusy;
    if (source == TrackSource.camera && busy != null) await busy;
  }

  Future<LocalTrackPublication<LocalVideoTrack>?> _publishVideoTrack(
    LocalVideoTrack track, {
    VideoPublishOptions? publishOptions,
    // GRAVIX (0.4.15): see _publishAudioTrack
    bool gravixDetached = false,
    // GRAVIX (2026-10-13, fast publish for video): the join's camera. With the
    // server's publish codecs (the parallel branch below, the normal path on a
    // Gravix server) its transceiver takes over the publisher's held first
    // offer; without them it is published as any camera, with an offer of its
    // own. The AddTrack wait ends when the join attempt does.
    GravixJoinCameraAttempt? gravixJoin,
  }) async {
    if (videoTrackPublications.any((e) => e.track?.mediaStreamTrack.id == track.mediaStreamTrack.id)) {
      throw TrackPublishException('track already exists');
    }

    // Use defaultPublishOptions if options is null
    publishOptions ??= track.lastPublishOptions ?? room.roomOptions.defaultVideoPublishOptions;

    if (publishOptions.videoCodec.toLowerCase() != publishOptions.videoCodec) {
      publishOptions = publishOptions.copyWith(videoCodec: publishOptions.videoCodec.toLowerCase());
    }

    if (room.engine.enabledPublishCodecs?.isNotEmpty ?? false) {
      // fallback to a supported codec if it is not supported
      if (!room.engine.enabledPublishCodecs!
          .where((c) => c.mime.startsWith('video/'))
          .where((c) => videoCodecs.any((v) => c.mime.toLowerCase().endsWith(v)))
          .any((c) => publishOptions?.videoCodec == mimeTypeToVideoCodecString(c.mime))) {
        publishOptions = publishOptions.copyWith(
          videoCodec: mimeTypeToVideoCodecString(room.engine.enabledPublishCodecs![0].mime).toLowerCase(),
        );
      }
    }

    // handle SVC publishing
    final isSVC = isSVCCodec(publishOptions.videoCodec);
    if (isSVC) {
      if (!room.roomOptions.dynacast) {
        room.engine.roomOptions = room.roomOptions.copyWith(dynacast: true);
      }

      if (publishOptions.scalabilityMode == null) {
        publishOptions = publishOptions.copyWith(scalabilityMode: 'L3T3_KEY');
      }

      // vp9 svc with screenshare has problem to encode, always use L1T3 here
      if (track.source == TrackSource.screenShareVideo) {
        publishOptions = publishOptions.copyWith(scalabilityMode: 'L1T3');
      }
    }

    // use finalraints passed to getUserMedia by default
    VideoDimensions dimensions = track.currentOptions.params.dimensions;

    if (kIsWeb || lkPlatformIsMobile()) {
      // getSettings() is only implemented for Web & Mobile
      try {
        // try to use getSettings for more accurate resolution
        final settings = track.mediaStreamTrack.getSettings();
        if ((settings['width'] is int && settings['width'] as int > 0) &&
            (settings['height'] is int && settings['height'] as int > 0)) {
          dimensions = dimensions.copyWith(width: settings['width'] as int);
          dimensions = dimensions.copyWith(height: settings['height'] as int);
        }
      } catch (_) {
        logger.warning('Failed to call `mediaStreamTrack.getSettings()`');
      }
    }

    // Gravix plan cap: clamp every published layer's short edge so a
    // compliant app is never rejected by the SFU. `dimensions` stays the real
    // capture size (encoder scale factors are relative to it);
    // `publishedDimensions` is what is actually sent and announced.
    final planCap = GravixVideoCap.parse(attributes);
    final videoCap = _videoCapFor(track.source);
    // Remember the app's own ladder: a republish after a cap raise should get
    // its rungs back rather than inherit today's clamp via lastPublishOptions.
    final requestedOptions = publishOptions;
    if (planCap != null) {
      publishOptions = GravixVideoCap.clampPublishOptions(publishOptions, planCap);
    }
    final publishedDimensions = videoCap == null ? dimensions : GravixVideoCap.clampDimensions(dimensions, videoCap);

    logger.fine('Compute encodings with resolution: ${dimensions}, cap: ${videoCap}, options: ${publishOptions}');

    // Video encodings and simulcasts
    var encodings = Utils.computeVideoEncodings(
      isScreenShare: track.source == TrackSource.screenShareVideo,
      dimensions: dimensions,
      options: publishOptions,
      codec: publishOptions.videoCodec,
      maxShortEdge: videoCap,
    );

    logger.fine('Using encodings: ${encodings?.map((e) => e.toMap())}');

    final simulcastCodecs = <lk_rtc.SimulcastCodec>[
      lk_rtc.SimulcastCodec(codec: publishOptions.videoCodec, cid: track.getCid()),
    ];

    if (publishOptions.backupVideoCodec.enabled && publishOptions.backupVideoCodec.codec != publishOptions.videoCodec) {
      simulcastCodecs.add(lk_rtc.SimulcastCodec(codec: publishOptions.backupVideoCodec.codec.toLowerCase(), cid: ''));
    }

    // The SVC branch ignores scaleResolutionDownBy and halves whatever size it
    // is given, so hand it the clamped size; simulcast derives from scale.
    final layers = Utils.computeVideoLayers(isSVC ? publishedDimensions : dimensions, encodings, isSVC);

    if (room.engine.isClosed) {
      throw UnexpectedConnectionState('cannot publish track when not connected');
    }

    logger.fine('Video layers: ${layers.map((e) => e)}');

    Future<lk_models.TrackInfo> negotiate(VideoPublishOptions options) async {
      track.transceiver = await room.engine.createTransceiverRTCRtpSender(
        track,
        options,
        encodings,
        gravixDetached: gravixDetached,
      );

      track.codec = options.videoCodec;
      if (lkBrowser() != BrowserType.firefox) {
        await room.engine.setPreferredCodec(track.transceiver!, 'video', options.videoCodec);
      }

      await track.setDegradationPreference(
        options.degradationPreference ?? getDefaultDegradationPreference(track.source),
      );
      if (gravixJoin != null && gravixJoin.isAborted) return lk_models.TrackInfo();

      if (kIsWeb && lkBrowser() == BrowserType.firefox && track.kind == TrackType.AUDIO) {
        //TOOD:
      } else if (isVideoCodec(options.videoCodec) && encodings?.first.maxBitrate != null) {
        // Apply start bitrate for all video codecs to prevent initial blurriness
        if (room.roomOptions.recovery.startBitrateBySetupTime) {
          // GRAVIX (0.4.15): upstream 2.13.1 (#1218): the target is the sum of the
          // simulcast layers (encodings[0] is the LOWEST one), screen share flagged
          final targetBitrate = computeStartTargetBitrate(options.videoCodec, options, encodings);
          if (targetBitrate > 0) {
            room.engine.publisher?.setTrackBitrateInfo(
              TrackBitrateInfo(
                cid: track.getCid(),
                transceiver: track.transceiver,
                codec: options.videoCodec,
                maxbr: targetBitrate ~/ 1000,
                isScreenShare: track.source == TrackSource.screenShareVideo,
              ),
            );
          }
        } else {
          room.engine.publisher?.setTrackBitrateInfo(
            TrackBitrateInfo(
              cid: track.getCid(),
              transceiver: track.transceiver,
              codec: options.videoCodec,
              maxbr: encodings![0].maxBitrate! ~/ 1000,
            ),
          );
        }
      }

      if (gravixJoin != null) {
        // GRAVIX (2026-10-13): the join's camera takes over the publisher's held
        // first offer; with the join's microphone, the offer is made once both
        // transceivers are added (or the other one gave up)
        gravixJoin.noteNegotiating(firstOffer: !room.engine.gravixHasNegotiated);
        final peers = gravixJoin.peersReady;
        if (peers != null) await peers();
        if (gravixJoin.isAborted) return lk_models.TrackInfo();
      }
      await room.engine.negotiate();

      return lk_models.TrackInfo();
    }

    final req = lk_rtc.AddTrackRequest(
      cid: track.getCid(),
      name:
          publishOptions.name ??
          (track.source == TrackSource.screenShareVideo
              ? VideoPublishOptions.defaultScreenShareName
              : VideoPublishOptions.defaultCameraName),
      type: track.kind.toPBType(),
      source: track.source.toPBType(),
      encryption: room.roomOptions.lkEncryptionType,
      simulcastCodecs: simulcastCodecs,
      muted: track.muted,
      stream: buildStreamId(publishOptions, track.source),
    );

    // video specific. Announce the size actually sent: the SFU checks the
    // cap against this, so the raw capture size would be rejected.
    if (publishedDimensions.width > 0 && publishedDimensions.height > 0) {
      req.width = publishedDimensions.width;
      req.height = publishedDimensions.height;
    }

    if (layers.isNotEmpty) {
      req.layers
        ..clear()
        ..addAll(layers);
    }
    late lk_models.TrackInfo trackInfo;
    if (room.engine.enabledPublishCodecs?.isNotEmpty ?? false) {
      try {
        final rets = await Future.wait<lk_models.TrackInfo>([
          room.engine.addTrack(req, gravixAbort: gravixJoin?.abortSignal),
          negotiate(publishOptions),
        ]);
        trackInfo = rets[0];
      } catch (_) {
        // negotiate() already attached a sender; on a refused/timed-out
        // addTrack drop it so a retry (e.g. at a lower resolution) starts clean.
        // (Not for a join attempt that ended: its connection is gone, and the
        // renegotiation must not reach the next attempt's.)
        final sender = track.transceiver?.sender;
        if (sender != null && !(gravixJoin?.isAborted ?? false)) {
          try {
            await room.engine.publisher?.pc.removeTrack(sender);
            await room.engine.negotiate();
          } catch (e) {
            logger.warning('cleanup after failed addTrack did throw $e');
          }
        }
        rethrow;
      }
    } else {
      // GRAVIX (2026-10-13): no publish codecs announced: the join's camera is
      // published as any camera (the server picks the codec), not in the first
      // offer
      if (gravixJoin != null) {
        gravixJoin.inFirstOffer = false;
        gravixJoin.releaseOffer(false);
      }
      trackInfo = await room.engine.addTrack(req, gravixAbort: gravixJoin?.abortSignal);

      String? primaryCodecMime;
      for (var codec in trackInfo.codecs) {
        primaryCodecMime ??= codec.mimeType;
      }

      if (primaryCodecMime != null) {
        final updatedCodec = mimeTypeToVideoCodecString(primaryCodecMime);
        if (updatedCodec != publishOptions.videoCodec) {
          logger.fine(
            'requested a different codec than specified by serverRequested: ${publishOptions.videoCodec}, server: ${updatedCodec}',
          );
          publishOptions = publishOptions.copyWith(videoCodec: updatedCodec);
          // recompute encodings since bitrates/etc could have changed
          encodings = Utils.computeVideoEncodings(
            isScreenShare: track.source == TrackSource.screenShareVideo,
            dimensions: dimensions,
            options: publishOptions,
            codec: publishOptions.videoCodec,
            maxShortEdge: videoCap,
          );
        }
      }

      final transceiverInit = rtc.RTCRtpTransceiverInit(
        direction: rtc.TransceiverDirection.SendOnly,
        sendEncodings: encodings,
      );

      logger.fine('publishVideoTrack publisher: ${room.engine.publisher}');

      final pc = room.engine.publisher?.pc;
      track.transceiver = gravixDetached
          ? await pc?.addTransceiver(kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo, init: transceiverInit)
          : await pc?.addTransceiver(
              track: track.mediaStreamTrack,
              kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
              init: transceiverInit,
            );

      track.codec = publishOptions.videoCodec;
      if (lkBrowser() != BrowserType.firefox) {
        await room.engine.setPreferredCodec(track.transceiver!, 'video', publishOptions.videoCodec);
      }

      await track.setDegradationPreference(
        publishOptions.degradationPreference ?? getDefaultDegradationPreference(track.source),
      );

      if (kIsWeb && lkBrowser() == BrowserType.firefox && track.kind == TrackType.AUDIO) {
        //TOOD:
      } else if (isVideoCodec(publishOptions.videoCodec) && encodings?.first.maxBitrate != null) {
        // Apply start bitrate for all video codecs to prevent initial blurriness
        if (room.roomOptions.recovery.startBitrateBySetupTime) {
          // GRAVIX (0.4.15): upstream 2.13.1 (#1218): the target is the sum of the
          // simulcast layers (encodings[0] is the LOWEST one), screen share flagged
          final targetBitrate = computeStartTargetBitrate(publishOptions.videoCodec, publishOptions, encodings);
          if (targetBitrate > 0) {
            room.engine.publisher?.setTrackBitrateInfo(
              TrackBitrateInfo(
                cid: track.getCid(),
                transceiver: track.transceiver,
                codec: publishOptions.videoCodec,
                maxbr: targetBitrate ~/ 1000,
                isScreenShare: track.source == TrackSource.screenShareVideo,
              ),
            );
          }
        } else {
          room.engine.publisher?.setTrackBitrateInfo(
            TrackBitrateInfo(
              cid: track.getCid(),
              transceiver: track.transceiver,
              codec: publishOptions.videoCodec,
              maxbr: encodings![0].maxBitrate! ~/ 1000,
            ),
          );
        }
      }

      await room.engine.negotiate();
    }

    logger.fine('publishVideoTrack engine.addTrack response: ${trackInfo}');

    track.lastPublishOptions = publishOptions.copyWith(
      videoSimulcastLayers: requestedOptions.videoSimulcastLayers,
      screenShareSimulcastLayers: requestedOptions.screenShareSimulcastLayers,
    );

    if (!gravixDetached) await track.start();

    final pub = LocalTrackPublication<LocalVideoTrack>(participant: this, info: trackInfo, track: track);
    addTrackPublication(pub);
    if (track.source == TrackSource.camera) {
      unawaited(GravixForegroundService.roomPublished(room, camera: true));
    }
    pub.backupVideoCodec = publishOptions.backupVideoCodec;

    // did publish
    await track.onPublish();
    await track.processor?.onPublish(room);

    final listener = track.createListener();
    listener.on((TrackEndedEvent event) async {
      logger.fine('TrackEndedEvent: ${event.track}');
      await removePublishedTrack(pub.sid);
    });

    [events, room.events].emit(LocalTrackPublishedEvent(participant: this, publication: pub));

    return pub;
  }

  Future<void> removePublishedTrack(String trackSid, {bool notify = true}) async {
    logger.finer('Unpublish track sid: $trackSid, notify: $notify');
    final pub = trackPublications.remove(trackSid);
    if (pub == null) {
      logger.warning('Publication not found $trackSid');
      return;
    }
    final track = pub.track;
    if (track != null) {
      if (room.roomOptions.stopLocalTrackOnUnpublish) {
        await track.stop();
      }

      final sender = track.transceiver?.sender;
      var didRemoveSender = false;
      if (sender != null) {
        // GRAVIX (0.4.19): the m-line stays (inactive); its mid is not reused
        GravixPubLog.step(
          'senderRemove',
          pc: room.engine.publisher?.gravixLogLabel,
          detail: 'kind=${track.kind.name} source=${track.source.name} mid=${GravixPubLog.midOf(track.transceiver)}',
        );
        try {
          await room.engine.publisher?.pc.removeTrack(sender);
        } catch (e) {
          logger.warning('[$objectId] rtc.removeTrack() did throw $e');
        }
        didRemoveSender = true;
      }

      // not gated on the primary sender, stale backup codec state must not
      // survive unpublish even when the track never got a live sender
      if (track is LocalVideoTrack) {
        // remove each backup sender on its own, one failure should not
        // prevent removal of the others
        for (final simulcastTrack in track.simulcastCodecs.values.toList()) {
          final simulcastSender = simulcastTrack.sender;
          if (simulcastSender == null) {
            continue;
          }
          try {
            await room.engine.publisher?.pc.removeTrack(simulcastSender);
          } catch (e) {
            logger.warning('[$objectId] rtc.removeTrack() did throw $e');
          }
          simulcastTrack.sender = null;
          didRemoveSender = true;
        }
        track.clearSimulcastState();
      }

      // doesn't make sense to negotiate if already disposed
      if (didRemoveSender && !isDisposed) {
        // manual negotiation since track changed
        await room.engine.negotiate();
      }

      // did unpublish
      await track.onUnpublish();

      if (track.processor != null) {
        await track.processor?.onUnpublish();
        await track.stopProcessor();
      }
    }

    // After the capture is torn down: stopping the mediaProjection foreground
    // service ends the projection itself on Android 14+.
    if (pub.source == TrackSource.screenShareVideo && lkPlatformIs(PlatformType.android)) {
      await AndroidScreenCapture.release();
    }

    if (notify) {
      [events, room.events].emit(LocalTrackUnpublishedEvent(participant: this, publication: pub));
    }

    await pub.dispose();
  }

  /// Convenience method to unpublish all tracks.
  Future<void> unpublishAllTracks({bool notify = true, bool? stopOnUnpublish}) async {
    final trackSids = trackPublications.keys.toSet();
    for (final trackid in trackSids) {
      await removePublishedTrack(trackid, notify: notify);
    }
  }

  /// Publications a full rejoin is republishing that are not published yet. A
  /// newer rejoin takes them over (otherwise the muted mic could be lost between
  /// two back-to-back rejoins).
  final List<LocalTrackPublication> _gravixRepublishPending = [];

  /// GRAVIX (0.4.15): the room is left: nothing is republished any more.
  @internal
  void gravixForgetRepublish() => _gravixRepublishPending.clear();

  /// GRAVIX (2026-10-11): a rejoin still has to republish a [source] track. Its
  /// publication is missing on purpose meanwhile; the host-camera restore
  /// (GravixDataSaver) must not open a second camera into that window.
  @internal
  bool gravixRepublishPending(TrackSource source) => _gravixRepublishPending.any((p) => p.source == source);

  Future<void> rePublishAllTracks() async {
    final restartGen = room.engine.gravixRestartGen;
    bool superseded() => room.engine.gravixRestartGen != restartGen;
    // what the previous rejoin did not finish, then what is published now; one
    // entry per track
    final pubs = <LocalTrackPublication>[];
    for (final pub in [..._gravixRepublishPending, ...trackPublications.values]) {
      if (pub.track == null || pubs.any((p) => identical(p.track, pub.track))) continue;
      pubs.add(pub);
    }
    _gravixRepublishPending
      ..clear()
      ..addAll(pubs);
    trackPublications.clear();
    final detachStopped = room.roomOptions.recovery.republishStoppedTracksMuted;
    for (LocalTrackPublication pub in pubs) {
      if (superseded()) {
        // a newer rejoin replaced the session: it republishes what is left
        logger.info('republish: the session was replaced; ${_gravixRepublishPending.length} left for the next one');
        return;
      }
      final track = pub.track;
      // GRAVIX (0.4.15, field 2026-10-09 03:50:13.919): a track muted with
      // stopOnMute (stopAudioCaptureOnMute, the default) has no native track any
      // more; handing it to addTransceiver threw "track is null" out of the
      // rejoin, which then never emitted RoomReconnectedEvent. Republish it muted
      // with no capture behind it: the unmute restarts the capture on the new
      // sender (LocalTrack.unmute -> restartTrack -> replaceTrack), and the
      // microphone is not reopened while muted.
      final detached = detachStopped && track != null && track.muted && !track.isActive;
      try {
        if (track is LocalAudioTrack) {
          if (detached) {
            logger.info('republishing the stopped muted ${track.source} without a capture');
            await _publishRunners.forSource(track.source).run(() => _publishAudioTrack(track, gravixDetached: true));
          } else {
            await publishAudioTrack(track);
          }
        } else if (track is LocalVideoTrack) {
          // a full reconnect replaced the peer connection, so any simulcast
          // codec senders the track still holds belong to the old one
          track.clearSimulcastState();
          if (detached) {
            logger.info('republishing the stopped muted ${track.source} without a capture');
            await _publishRunners.forSource(track.source).run(() => _publishVideoTrack(track, gravixDetached: true));
          } else {
            await publishVideoTrack(track);
          }
        }
        _gravixRepublishPending.remove(pub);
      } catch (error) {
        if (error is GravixSessionReplacedException || superseded()) {
          // GRAVIX (0.4.15, F4): not a failure: the next session republishes it
          logger.info('republishing ${pub.source}: the session was replaced; the next rejoin republishes it');
          return;
        }
        _gravixRepublishPending.remove(pub);
        // GRAVIX (0.4.15): one track that cannot be republished must not abort the
        // rejoin (the other tracks, RoomReconnectedEvent): report it instead.
        logger.severe('republishing ${pub.source} after the rejoin failed: $error');
        [events, room.events].emit(LocalTrackRepublishFailedEvent(participant: this, publication: pub, error: error));
      }
    }
  }

  /// Publish a new data payload to the room.
  /// @param reliable, when true, data will be sent reliably.
  /// @param destinationIdentities When empty, data will be forwarded to each participant in the room.
  /// @param topic, the topic under which the message gets published.
  Future<void> publishData(List<int> data, {bool? reliable, List<String>? destinationIdentities, String? topic}) async {
    final publishReliably = reliable == true;
    final packet = lk_models.DataPacket(
      kind: publishReliably ? lk_models.DataPacket_Kind.RELIABLE : lk_models.DataPacket_Kind.LOSSY,
      user: lk_models.UserPacket(
        payload: data,
        participantIdentity: identity,
        destinationIdentities: destinationIdentities,
        topic: topic,
      ),
    );

    await room.engine.sendDataPacket(packet, reliability: publishReliably ? Reliability.reliable : Reliability.lossy);
  }

  /// Sets and updates the metadata of the local participant.
  /// Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
  /// @param metadata
  Future<void> setMetadata(String metadata) {
    final requestId = room.engine.signalClient.sendUpdateLocalMetadata(
      lk_rtc.UpdateParticipantMetadata(name: name, metadata: metadata),
    );
    return _waitForRequestResponse(requestId);
  }

  /// Sets and updates the attributes of the local participant.
  /// @attributes key-value pairs to set
  Future<void> setAttributes(Map<String, String> attributes) {
    final requestId = room.engine.signalClient.sendUpdateLocalMetadata(
      lk_rtc.UpdateParticipantMetadata(name: name, metadata: metadata, attributes: attributes.entries),
    );
    return _waitForRequestResponse(requestId);
  }

  /// Sets and updates the name of the local participant.
  ///  Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
  ///  @param name
  Future<void> setName(String name) {
    final requestId = room.engine.signalClient.sendUpdateLocalMetadata(
      lk_rtc.UpdateParticipantMetadata(name: name, metadata: metadata),
    );
    return _waitForRequestResponse(requestId);
  }

  Future<void> _waitForRequestResponse(int requestId) {
    final completer = Completer<void>();
    _pendingSignalRequests[requestId] = completer;
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pendingSignalRequests.remove(requestId);
        throw TimeoutException('Signal request timed out');
      },
    );
  }

  @internal
  void handleSignalRequestResponse(lk_rtc.RequestResponse response) {
    final completer = _pendingSignalRequests.remove(response.requestId);
    if (completer != null && !completer.isCompleted) {
      if (response.reason != lk_rtc.RequestResponse_Reason.OK) {
        completer.completeError(
          UnexpectedStateException('Signal request failed: ${response.reason} - ${response.message}'),
        );
      } else {
        completer.complete();
      }
    }
  }

  /// A convenience property to get all video tracks.
  @override
  List<LocalTrackPublication<LocalVideoTrack>> get videoTrackPublications =>
      trackPublications.values.whereType<LocalTrackPublication<LocalVideoTrack>>().toList();

  /// A convenience property to get all audio tracks.
  @override
  List<LocalTrackPublication<LocalAudioTrack>> get audioTrackPublications =>
      trackPublications.values.whereType<LocalTrackPublication<LocalAudioTrack>>().toList();

  @override
  LocalTrackPublication? getTrackPublicationByName(String name) {
    final track = super.getTrackPublicationByName(name);
    if (track != null) {
      return track;
    }
    return null;
  }

  @override
  LocalTrackPublication? getTrackPublicationBySid(String sid) {
    final track = super.getTrackPublicationBySid(sid);
    if (track != null) {
      return track;
    }
    return null;
  }

  @override
  LocalTrackPublication? getTrackPublicationBySource(TrackSource source) {
    final track = super.getTrackPublicationBySource(source);
    if (track != null) {
      return track;
    }
    return null;
  }

  /// Shortcut for publishing a [TrackSource.camera]
  Future<LocalTrackPublication?> setCameraEnabled(bool enabled, {CameraCaptureOptions? cameraCaptureOptions}) async {
    cameraCaptureOptions ??= room.roomOptions.defaultCameraCaptureOptions;
    return setSourceEnabled(TrackSource.camera, enabled, cameraCaptureOptions: cameraCaptureOptions);
  }

  /// Shortcut for publishing a [TrackSource.microphone]
  Future<LocalTrackPublication?> setMicrophoneEnabled(bool enabled, {AudioCaptureOptions? audioCaptureOptions}) async {
    audioCaptureOptions ??= room.roomOptions.defaultAudioCaptureOptions;
    return setSourceEnabled(TrackSource.microphone, enabled, audioCaptureOptions: audioCaptureOptions);
  }

  /// Shortcut for publishing a [TrackSource.screenShareVideo]
  Future<LocalTrackPublication?> setScreenShareEnabled(
    bool enabled, {
    bool? captureScreenAudio,
    ScreenShareCaptureOptions? screenShareCaptureOptions,
  }) async {
    screenShareCaptureOptions ??= room.roomOptions.defaultScreenShareCaptureOptions;
    return setSourceEnabled(
      TrackSource.screenShareVideo,
      enabled,
      captureScreenAudio: captureScreenAudio,
      screenShareCaptureOptions: screenShareCaptureOptions,
    );
  }

  /// A convenience method to publish a track for a specific [TrackSource].
  /// This is the recommended method to publish tracks.
  /// GRAVIX (2026-10-21): the camera's last setCameraEnabled / setSourceEnabled
  /// request (true = on), whether or not its publish succeeded.
  bool gravixCameraWanted = false;

  Future<LocalTrackPublication?> setSourceEnabled(
    TrackSource source,
    bool enabled, {
    bool? captureScreenAudio,
    AudioCaptureOptions? audioCaptureOptions,
    CameraCaptureOptions? cameraCaptureOptions,
    ScreenShareCaptureOptions? screenShareCaptureOptions,
  }) async {
    if (_gravixJoinCameraBusy != null) await _gravixAfterJoinCamera(source);
    // GRAVIX (2026-10-21): what the app asked for last, so a region move after a
    // media refusal can publish the camera again (Room.gravixFailoverForMediaRefusal)
    if (source == TrackSource.camera) gravixCameraWanted = enabled;
    return _publishRunners.forSource(source).run(() async {
      if (TrackSource.screenShareVideo == source && lkPlatformIsWebMobile()) {
        throw TrackCreateException('Screen sharing is not supported on mobile devices');
      }

      logger.fine('setSourceEnabled(source: $source, enabled: $enabled)');

      final publication = getTrackPublicationBySource(source);
      if (publication != null) {
        final stopOnMute = switch (publication.source) {
          TrackSource.camera => cameraCaptureOptions?.stopCameraCaptureOnMute ?? true,
          TrackSource.microphone => audioCaptureOptions?.stopAudioCaptureOnMute ?? true,
          _ => true,
        };
        if (enabled) {
          await publication.unmute(stopOnMute: stopOnMute);
        } else {
          if (source == TrackSource.screenShareVideo) {
            await removePublishedTrack(publication.sid);
            final screenAudio = getTrackPublicationBySource(TrackSource.screenShareAudio);
            if (screenAudio != null) {
              await removePublishedTrack(screenAudio.sid);
            }
          } else {
            await publication.mute(stopOnMute: stopOnMute);
          }
        }
        return publication;
      } else if (enabled) {
        if (source == TrackSource.camera) {
          CameraCaptureOptions captureOptions = cameraCaptureOptions ?? room.roomOptions.defaultCameraCaptureOptions;
          // Capture no bigger than the plan allows: encoding pixels the SFU
          // won't forward wastes CPU/battery. The publish-time clamp still
          // covers tracks created outside this path.
          final cap = _videoCapFor(TrackSource.camera);
          if (cap != null) {
            captureOptions = captureOptions.copyWith(
              params: GravixVideoCap.clampParameters(captureOptions.params, cap),
            );
          }
          final track = await LocalVideoTrack.createCameraTrack(captureOptions);
          return await _publishVideoTrack(track);
        } else if (source == TrackSource.microphone) {
          final AudioCaptureOptions captureOptions = audioCaptureOptions ?? room.roomOptions.defaultAudioCaptureOptions;
          final track = await LocalAudioTrack.create(captureOptions);
          return await _publishAudioTrack(track);
        } else if (source == TrackSource.screenShareVideo) {
          ScreenShareCaptureOptions captureOptions =
              screenShareCaptureOptions ?? room.roomOptions.defaultScreenShareCaptureOptions;
          final screenCap = _videoCapFor(TrackSource.screenShareVideo);
          if (screenCap != null) {
            captureOptions = captureOptions.copyWith(
              params: GravixVideoCap.clampParameters(captureOptions.params, screenCap),
            );
          }

          if (lkPlatformIs(PlatformType.iOS) && !BroadcastManager().isBroadcasting) {
            // Wait until broadcasting to publish track
            await BroadcastManager().requestActivation();
            return null;
          }
          if (lkPlatformIs(PlatformType.iOS) && BroadcastManager().isBroadcasting) {
            // The broadcast runs in the app's Broadcast Upload Extension, so the
            // frames arrive over its socket, not from in-app ReplayKit capture.
            captureOptions = captureOptions.copyWith(useiOSBroadcastExtension: true);
          }

          // Android: consent + mediaProjection foreground service BEFORE
          // getDisplayMedia (required on API 34+). Released on unpublish, or
          // right here if creating/publishing the track fails.
          final androidCapture = lkPlatformIs(PlatformType.android);
          if (androidCapture) {
            await AndroidScreenCapture.prepare();
          }
          try {
            /// When capturing chrome table audio, we can't capture audio/video
            /// track separately, it has to be returned once in getDisplayMedia,
            /// so we publish it twice here, but only return videoTrack to user.
            if (captureScreenAudio ?? false) {
              captureOptions = captureOptions.copyWith(captureScreenAudio: true);
              final tracks = await LocalVideoTrack.createScreenShareTracksWithAudio(captureOptions);
              LocalTrackPublication<LocalVideoTrack>? publication;
              for (final track in tracks) {
                if (track is LocalVideoTrack) {
                  publication = await _publishVideoTrack(track);
                } else if (track is LocalAudioTrack) {
                  await _publishAudioTrack(track);
                }
              }

              /// just return the video track publication
              return publication;
            }
            final track = await LocalVideoTrack.createScreenShareTrack(captureOptions);
            return await _publishVideoTrack(track);
          } catch (_) {
            if (androidCapture) await AndroidScreenCapture.release();
            rethrow;
          }
        }
      }
      return null;
    });
  }

  bool _allParticipantsAllowed = true;
  List<ParticipantTrackPermission> _participantTrackPermissions = [];

  /// Control who can subscribe to LocalParticipant's published tracks.
  ///
  /// By default, all participants can subscribe. This allows fine-grained control over
  /// who is able to subscribe at a participant and track level.
  ///
  /// Note: if access is given at a track-level (i.e. both [allParticipantsAllowed] and
  /// [ParticipantTrackPermission.allTracksAllowed] are false), any newer published tracks
  /// will not grant permissions to any participants and will require a subsequent
  /// permissions update to allow subscription.
  ///
  /// [allParticipantsAllowed] Allows all participants to subscribe all tracks.
  /// Takes precedence over [trackPermissions] if set to true.
  /// By default this is set to true.
  ///
  /// [trackPermissions] Full list of individual permissions per
  /// participant/track. Any omitted participants will not receive any permissions.

  void setTrackSubscriptionPermissions({
    required bool allParticipantsAllowed,
    List<ParticipantTrackPermission> trackPermissions = const [],
  }) {
    _allParticipantsAllowed = allParticipantsAllowed;
    _participantTrackPermissions = trackPermissions;
    sendTrackSubscriptionPermissions();
  }

  void sendTrackSubscriptionPermissions() {
    if (room.engine.connectionState != ConnectionState.connected) {
      return;
    }
    room.engine.signalClient.sendUpdateSubscriptionPermissions(
      allParticipants: _allParticipantsAllowed,
      trackPermissions: _participantTrackPermissions.map((e) => e.toPBType()).toList(),
    );
  }

  @internal
  Iterable<lk_rtc.TrackPublishedResponse> publishedTracksInfo() =>
      trackPublications.values.map((e) => e.toPBTrackPublishedResponse());

  @internal
  @override
  ParticipantPermissions? setPermissions(ParticipantPermissions newValue) {
    final oldValue = super.setPermissions(newValue);
    if (oldValue != null) {
      // notify
      [
        events,
        room.events,
      ].emit(ParticipantPermissionsUpdatedEvent(participant: this, permissions: newValue, oldPermissions: oldValue));
    }
    return oldValue;
  }

  Future<void> publishAdditionalCodecForPublication(LocalTrackPublication publication, String backupCodec) async {
    if (publication.track is! LocalVideoTrack) {
      throw Exception('multi-codec simulcast is supported only for video');
    }
    final track = publication.track as LocalVideoTrack;

    final backupCodecOpts = publication.backupVideoCodec;
    if (backupCodecOpts == null) {
      throw Exception('backupCodec settings not specified');
    }

    var options = room.roomOptions.defaultVideoPublishOptions;
    options = options.copyWith(simulcast: backupCodecOpts.simulcast);

    if (backupCodec.toLowerCase() == publication.track?.codec?.toLowerCase()) {
      // not needed, same codec already published
      return;
    }

    if (backupCodec != backupCodecOpts.codec.toLowerCase()) {
      logger.warning(
        'requested a different codec than specified as backup serverRequested: ${backupCodec}, backup: ${backupCodecOpts.codec}',
      );
    }

    final encodings = Utils.computeTrackBackupEncodings(
      track,
      backupCodecOpts,
      maxShortEdge: _videoCapFor(track.source),
    );
    if (encodings == null) {
      logger.fine('backup codec has been disabled, ignoring request to add additional codec for track');
      return;
    }

    final simulcastTrack = track.addSimulcastTrack(backupCodec, encodings);
    final dimensions = track.currentOptions.params.dimensions;
    // Same plan-cap rule as the primary codec (see _publishVideoTrack).
    final backupCap = _videoCapFor(track.source);
    final publishedDimensions = backupCap == null ? dimensions : GravixVideoCap.clampDimensions(dimensions, backupCap);
    final backupIsSVC = isSVCCodec(backupCodec);
    final layers = Utils.computeVideoLayers(backupIsSVC ? publishedDimensions : dimensions, encodings, backupIsSVC);

    simulcastTrack.sender = await room.engine.createSimulcastTransceiverSender(
      track,
      simulcastTrack,
      encodings,
      publication,
      backupCodec,
    );

    // the backup codec publishes over its own sender, so it needs the same
    // degradation preference the primary sender resolved to.
    await track.applyDegradationPreference(simulcastTrack.sender);

    final cid = simulcastTrack.sender!.senderId;

    final req = lk_rtc.AddTrackRequest(
      cid: cid,
      name:
          options.name ??
          (track.source == TrackSource.screenShareVideo
              ? VideoPublishOptions.defaultScreenShareName
              : VideoPublishOptions.defaultCameraName),
      type: track.kind.toPBType(),
      source: track.source.toPBType(),
      muted: track.muted,
      layers: layers,
      sid: publication.sid,
      simulcastCodecs: <lk_rtc.SimulcastCodec>[lk_rtc.SimulcastCodec(codec: backupCodec.toLowerCase(), cid: cid)],
    );

    // video specific: announce the size actually sent (capped).
    if (publishedDimensions.width > 0 && publishedDimensions.height > 0) {
      req.width = publishedDimensions.width;
      req.height = publishedDimensions.height;
    }

    final trackInfo = await room.engine.addTrack(req);

    await room.engine.negotiate();

    logger.info('published backupCodec $backupCodec for track ${track.sid}, track info ${trackInfo}');
  }
}

extension DataStreamParticipantMethods on LocalParticipant {
  Future<TextStreamInfo> sendText(String text, {SendTextOptions? options}) async {
    final streamId = Uuid().v4();
    final textInBytes = text.codeUnits;
    final totalTextLength = textInBytes.length;

    final fileIds = options?.attachments.map((f) => Uuid().v4()).toList();
    var len = 0;
    if (fileIds != null && fileIds.isNotEmpty) {
      len = fileIds.length + 1;
    } else {
      len = 1;
    }
    final progresses = List<num>.filled(len, 0);

    handleProgress(num progress, int idx) {
      progresses[idx] = progress;
      final totalProgress = progresses.reduce((acc, val) => acc + val);
      options?.onProgress?.call(totalProgress.toDouble() / len);
    }

    final writer = await streamText(
      StreamTextOptions(
        streamId: streamId,
        totalSize: totalTextLength,
        destinationIdentities: options?.destinationIdentities ?? [],
        topic: options?.topic,
        attachedStreamIds: fileIds ?? [],
        attributes: options?.attributes ?? {},
      ),
    );

    await writer.write(text);
    // set text part of progress to 1
    handleProgress(1, 0);

    await writer.close();

    if (options?.attachments != null) {
      var idx = 0;
      await Future.wait<void>(
        options?.attachments.map((file) {
              final curIdx = idx++;
              return _sendFile(
                fileIds![curIdx],
                file,
                SendFileOptions(
                  topic: options.topic,
                  mimeType: mime(basename(file.path)),
                  onProgress: (progress) {
                    handleProgress(progress, curIdx + 1);
                  },
                ),
              );
            }).toList() ??
            [],
      );
    }
    return writer.info;
  }

  Future<TextStreamWriter> streamText(StreamTextOptions? options) async {
    final streamId = options?.streamId ?? Uuid().v4();
    final timestamp = DateTime.timestamp().millisecondsSinceEpoch;

    final info = TextStreamInfo(
      id: streamId,
      mimeType: 'text/plain',
      timestamp: timestamp,
      topic: options?.topic ?? '',
      size: options?.totalSize ?? 0,
      replyToStreamId: options?.replyToStreamId,
      attachedStreamIds: options?.attachedStreamIds ?? [],
      version: options?.version,
      generated: options?.generated ?? false,
      operationType: options?.type,
      sendingParticipantIdentity: identity,
    );

    final header = lk_models.DataStream_Header(
      streamId: streamId,
      mimeType: info.mimeType,
      topic: info.topic,
      timestamp: Int64(timestamp),
      totalLength: options?.totalSize != null ? Int64(options!.totalSize!) : null,
      attributes: options?.attributes.entries,
      textHeader: lk_models.DataStream_TextHeader(
        version: options?.version,
        attachedStreamIds: options?.attachedStreamIds,
        replyToStreamId: options?.replyToStreamId,
        generated: options?.generated ?? false,
        operationType: options?.type?.toPBType(),
      ),
    );

    final destinationIdentities = options?.destinationIdentities;
    final packet = lk_models.DataPacket(
      kind: lk_models.DataPacket_Kind.RELIABLE,
      destinationIdentities: destinationIdentities,
      streamHeader: header,
    );
    await room.engine.sendDataPacket(packet, reliability: Reliability.reliable);

    final writableStream = WritableStream<String>(
      destinationIdentities: destinationIdentities!,
      engine: room.engine,
      streamId: streamId,
    );

    onEngineClose() async {
      await writableStream.close();
    }

    final cancelFun = room.engine.events.once<EngineClosingEvent>((_) => onEngineClose);

    final writer = TextStreamWriter(writableStream: writableStream, info: info, onClose: cancelFun);

    return writer;
  }

  Future<Map<String, String>> sendFile(File file, {required SendFileOptions options}) async {
    final streamId = Uuid().v4();
    await _sendFile(streamId, file, options);
    return {'id': streamId};
  }

  Future<void> _sendFile(String streamId, File file, SendFileOptions options) async {
    final totalLength = await file.length();

    final streamBytesOptions = StreamBytesOptions(
      streamId: streamId,
      totalSize: totalLength,
      topic: options.topic,
      mimeType: options.mimeType ?? mime(basename(file.path)),
      name: basename(file.path),
      destinationIdentities: options.destinationIdentities,
      encryptionType: options.encryptionType,
    );

    final writer = await streamBytes(streamBytesOptions);

    final reader = ChunkedStreamReader(file.openRead());

    final totalChunks = (totalLength / kStreamChunkSize).ceil();
    for (var i = 0; i < totalChunks; i++) {
      final chunkData = await reader.readBytes(min((i + 1) * kStreamChunkSize, kStreamChunkSize));
      await writer.write(chunkData);
      options.onProgress?.call((i + 1) / totalChunks);
    }
    await writer.close();
  }

  Future<ByteStreamWriter> streamBytes(StreamBytesOptions? options) async {
    final streamId = options?.streamId ?? Uuid().v4();
    final timestamp = DateTime.timestamp().millisecondsSinceEpoch;

    final info = ByteStreamInfo(
      name: options?.name ?? 'unknown',
      id: streamId,
      mimeType: options?.mimeType ?? 'application/octet-stream',
      timestamp: timestamp,
      topic: options?.topic ?? '',
      size: options?.totalSize ?? 0,
      attributes: options?.attributes ?? {},
      sendingParticipantIdentity: identity,
    );

    final header = lk_models.DataStream_Header(
      totalLength: options?.totalSize != null ? Int64(options!.totalSize!) : null,
      mimeType: info.mimeType,
      streamId: streamId,
      topic: options?.topic,
      encryptionType: options?.encryptionType,
      timestamp: Int64(timestamp),
      byteHeader: lk_models.DataStream_ByteHeader(name: info.name),
      attributes: options?.attributes.entries,
    );

    final destinationIdentities = options?.destinationIdentities;
    final packet = lk_models.DataPacket(
      kind: lk_models.DataPacket_Kind.RELIABLE,
      destinationIdentities: destinationIdentities,
      streamHeader: header,
    );

    await room.engine.sendDataPacket(packet, reliability: Reliability.reliable);

    final writableStream = WritableStream<Uint8List>(
      destinationIdentities: destinationIdentities,
      streamId: streamId,
      engine: room.engine,
    );

    onEngineClose() async {
      await writableStream.close();
    }

    final cancelFun = room.engine.events.once<EngineClosingEvent>((_) => onEngineClose);

    final byteWriter = ByteStreamWriter(writableStream: writableStream, info: info, onClose: cancelFun);

    return byteWriter;
  }
}

/// The AddTrackRequest's `disableRed` for an audio publish. GRAVIX 2026-09-29: it
/// was `publishOptions.red ?? true`, i.e. RED DISABLED whenever it was asked for
/// (and by default), so no Flutter publisher ever sent redundant audio -- on the
/// Kuwaiti cellular uplink that lost ~15 % of packets. RED is on by default and
/// off when asked (`red: false`) or with E2EE (the SFU cannot rewrite encrypted
/// RED payloads).
bool gravixDisableRed({required bool e2ee, bool? red}) => e2ee ? true : !(red ?? true);
