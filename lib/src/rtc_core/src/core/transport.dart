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
import 'dart:math' as math;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:meta/meta.dart';
import 'package:sdp_transform/sdp_transform.dart' as sdp_transform;

import '../exceptions.dart';
import '../extensions.dart';
import '../internal/types.dart';
import '../logger.dart';
import '../options.dart';
import '../support/disposable.dart';
import '../support/platform.dart';
import '../types/other.dart';
import '../utils.dart';

const ddExtensionURI = 'https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension';

/*
 * Video codecs use a very low bitrate at the beginning and increase slowly by
 * the bandwidth estimator until they reach the target bitrate. The process commonly
 * costs more than 10 seconds causing subscribers to get blurry video at the first
 * few seconds. We use x-google-start-bitrate to hint the BWE to start higher.
 *
 * Why 90%: Gives ~10% headroom for bandwidth estimation while starting close to target.
 * Why same for all codecs: Target bitrate already accounts for codec efficiency
 * (e.g., users set lower targets for VP9/AV1 knowing they're more efficient).
 */
const startBitrateMultiplier = 0.9;

// GRAVIX (0.4.15): the rest of this block is upstream 2.13.1 (#1218, #1228;
// tag v2.13.1), used with GravixRecoveryOptions.startBitrateBySetupTime
// (Transport.gravixConnectionLevelStartBitrate). Off: the 0.4.14 per-track hint.

/// Maximum x-google-start-bitrate in kbps. 1 Mbps prevents BWE from starting too aggressively.
const maxStartBitrateKbps = 1000;

/// Minimum x-google-start-bitrate in kbps: libwebrtc's own default starting estimate. A target
/// below this gets no hint, since seeding above the real capacity costs more than the ramp it
/// saves, and a slow connection is seeded no higher than this.
const minTargetBitrateKbps = 300;

/// Connection setup times bounding the ramp in [computeTrackStartBitrate]: at or below the first
/// the hint is capped at [maxStartBitrateKbps], at or above the second at [minTargetBitrateKbps].
const setupTimeForMaxStartBitrate = Duration(milliseconds: 1500);
const setupTimeForMinStartBitrate = Duration(milliseconds: 3500);

class TrackBitrateInfo {
  String? cid;
  rtc.RTCRtpTransceiver? transceiver;
  String codec;
  int maxbr;
  bool isScreenShare;
  TrackBitrateInfo({
    required this.cid,
    required this.transceiver,
    required this.codec,
    required this.maxbr,
    this.isScreenShare = false,
  });
}

/// Codec payload for [codec] in this media section, when the section carries [cid].
///
/// Returns `null` when the section does not belong to the track, `0` when it does but does
/// not offer the requested codec, and the codec payload otherwise.
@internal
int? findTrackCodecPayload(Map<String, dynamic> media, String cid, String codec) {
  final msid = media['msid'];
  if (msid is! String || !msid.contains(cid)) {
    return null;
  }
  for (final rtp in (media['rtp'] as List? ?? const [])) {
    if ((rtp['codec'] as String?)?.toUpperCase() == codec.toUpperCase()) {
      return rtp['payload'] as int;
    }
  }
  return 0;
}

/// Cap on the start bitrate for a connection that took [connectionSetupTime] to set up: a
/// linear ramp from [maxStartBitrateKbps] at [setupTimeForMaxStartBitrate] down to
/// [minTargetBitrateKbps] at [setupTimeForMinStartBitrate]. Without a setup time, the ceiling.
@internal
int computeStartBitrateCap(Duration? connectionSetupTime) {
  if (connectionSetupTime == null) {
    return maxStartBitrateKbps;
  }
  final fast = setupTimeForMaxStartBitrate.inMilliseconds;
  final slow = setupTimeForMinStartBitrate.inMilliseconds;
  final ramp = ((connectionSetupTime.inMilliseconds - fast) / (slow - fast)).clamp(0.0, 1.0);
  return (maxStartBitrateKbps - ramp * (maxStartBitrateKbps - minTargetBitrateKbps)).round();
}

/// Start bitrate hinted for a single track, or `null` when its target is too low to be
/// worth seeding. 90 % of the target; a camera capped by [computeStartBitrateCap]; screen
/// share exempt (its content needs the bitrate at once to stay legible).
@internal
int? computeTrackStartBitrate(TrackBitrateInfo trackbr, [Duration? connectionSetupTime]) {
  if (trackbr.maxbr < minTargetBitrateKbps) {
    return null;
  }
  final calculated = (trackbr.maxbr * startBitrateMultiplier).round();
  return trackbr.isScreenShare ? calculated : math.min(calculated, computeStartBitrateCap(connectionSetupTime));
}

/// The single start bitrate for this peer connection: the largest hint among the video
/// m-sections of [media] that can send and map to a published track. libwebrtc applies the
/// hint to the whole connection (last writer wins on m-section order), so every video section
/// gets the same number. `recvonly` / `inactive` sections (a removed sender keeps its msid)
/// are skipped.
@internal
int? computeConnectionStartBitrate(
  List<dynamic> media,
  List<TrackBitrateInfo> trackBitrates, [
  Duration? connectionSetupTime,
]) {
  int? connectionStartBitrate;
  for (final m in media) {
    final direction = m['direction'];
    if (m['type'] != 'video' || direction == 'recvonly' || direction == 'inactive') {
      continue;
    }
    for (final trackbr in trackBitrates) {
      final cid = trackbr.cid;
      if (cid == null) {
        continue;
      }
      final codecPayload = findTrackCodecPayload(m, cid, trackbr.codec);
      if (codecPayload == null) {
        continue;
      }
      final startBitrate = codecPayload > 0 ? computeTrackStartBitrate(trackbr, connectionSetupTime) : null;
      if (startBitrate != null && (connectionStartBitrate == null || startBitrate > connectionStartBitrate)) {
        connectionStartBitrate = startBitrate;
      }
      break;
    }
  }
  return connectionStartBitrate;
}

/// Declares `x-google-start-bitrate` on [codecPayload]'s fmtp (creating the fmtp line when
/// the codec has none, e.g. VP8).
@internal
void applyVideoStartBitrate(Map<String, dynamic> media, int codecPayload, int startBitrate) {
  final fmtpList = (media['fmtp'] as List? ?? []);
  for (final fmtp in fmtpList) {
    if (fmtp['payload'] == codecPayload) {
      // a payload type is shared across the bundle: a value written for one section is
      // already the connection-level one
      if (!(fmtp['config'] as String).contains('x-google-start-bitrate')) {
        fmtp['config'] += ';x-google-start-bitrate=$startBitrate';
      }
      return;
    }
  }
  fmtpList.add(<String, dynamic>{'payload': codecPayload, 'config': 'x-google-start-bitrate=$startBitrate'});
  media['fmtp'] = fmtpList;
}

typedef TransportOnOffer = void Function(rtc.RTCSessionDescription offer);
typedef TransportOnNegotiationError = void Function(Object error);
typedef PeerConnectionCreate =
    Future<rtc.RTCPeerConnection> Function(Map<String, dynamic> configuration, [Map<String, dynamic> constraints]);

/// a wrapper around PeerConnection
class Transport extends Disposable {
  final rtc.RTCPeerConnection pc;
  final List<rtc.RTCIceCandidate> _pendingCandidates = [];
  final List<TrackBitrateInfo> _bitrateTrackers = [];

  /// GRAVIX (0.4.15): GravixRecoveryOptions.startBitrateBySetupTime, set by the
  /// engine. False: the 0.4.14 per-track hint.
  bool gravixConnectionLevelStartBitrate = false;

  /// Whether an offer carrying the connection-level hint was accepted locally (written
  /// once per peer connection: libwebrtc keeps it and re-applies it on route changes).
  bool _hasAppliedVideoStartBitrate = false;

  /// Times the connection attempt that created this transport (Engine.connect) until
  /// the primary connects; a slow setup lowers the hint.
  Stopwatch? _connectStopwatch;

  bool restartingIce = false;
  bool renegotiate = false;
  TransportOnOffer? onOffer;

  /// GRAVIX (0.4.15, BUG-3, REAL iPhone 2026-10-10 d7): GravixRecoveryOptions
  /// .deferNegotiateDuringResume, set by the engine: true while the signal
  /// socket cannot carry an offer (a resume is dialling). Offers are never
  /// queued while reconnecting, so an offer made then was applied locally and
  /// dropped, leaving the publisher in have-local-offer with an offer nobody
  /// would answer; the resume's ICE restart then re-applied the answer to the
  /// PREVIOUS offer and libwebrtc refused it ("Incompatible send direction":
  /// the data saver had removed the video sender in between), twice, so the
  /// session fell back to a full reconnect. A held offer is not created at all:
  /// it is marked [renegotiate] and goes out after the next answer (the
  /// restart's), whose offer already carries the current senders.
  /// Null (legacy): offers are made whatever the socket's state.
  bool Function()? gravixHoldOffers;

  /// GRAVIX (0.4.15, BUG-3): GravixRecoveryOptions.rollbackStaleOfferOnRestart.
  /// An ICE restart that finds an offer which LEFT but was never answered (the
  /// socket died after it) rolls that offer back instead of re-applying the
  /// current answer, which answers a different offer whenever the senders
  /// changed in between. False (legacy), or a native side that refuses the
  /// rollback: the answer is re-applied as before.
  bool gravixRollbackStaleOffer = false;

  /// GRAVIX (0.4.15): upstream 2.13.1 (#1226). Where a failed debounced or
  /// deferred offer goes (the engine: a reconnect). Null: the error propagates
  /// as before 0.4.15 (an unhandled error for the debounced one).
  TransportOnNegotiationError? onNegotiationError;
  Function? _cancelDebounce;
  ConnectOptions connectOptions;

  // private constructor
  Transport._(this.pc, this.connectOptions) {
    //
    onDispose(() async {
      _cancelDebounce?.call();
      _cancelDebounce = null;

      // Ensure callbacks won't fire any more
      pc.onRenegotiationNeeded = null;
      pc.onIceCandidate = null;
      pc.onConnectionState = null;
      pc.onIceConnectionState = null;
      pc.onTrack = null;

      // Remove all senders
      List<rtc.RTCRtpSender> senders = [];
      try {
        senders = await pc.getSenders();
      } catch (err) {
        logger.warning('getSenders() failed with error: $err');
      }

      for (final e in senders) {
        try {
          await pc.removeTrack(e);
        } catch (err) {
          logger.warning('removeTrack() failed with error: $err');
        }
      }

      await pc.close();
      await pc.dispose();
    });
  }

  static Future<Transport> create(
    PeerConnectionCreate peerConnectionCreate, {
    RTCConfiguration? rtcConfig,
    required ConnectOptions connectOptions,
  }) async {
    rtcConfig ??= const RTCConfiguration();
    logger.fine('[PCTransport] creating ${rtcConfig.toMap()}');
    final pc = await peerConnectionCreate(rtcConfig.toMap());
    return Transport._(pc, connectOptions);
  }

  void setConnectStopwatch(Stopwatch stopwatch) {
    _connectStopwatch = stopwatch;
  }

  /// The setup time the start bitrate hint is derived from: the completed setup time once
  /// the engine stopped the stopwatch, else the time elapsed so far (a lower bound).
  @internal
  Duration? get connectionSetupTimeForOffer => _connectStopwatch?.elapsed;

  late final negotiate = Utils.createDebounceFunc(
    (void _) => _createAndSendOfferReportingErrors(),
    cancelFunc: (f) => _cancelDebounce = f,
    wait: connectOptions.timeouts.debounce,
  );

  /// The debouncer and the offer deferred until the answer arrives have no caller
  /// that handles errors: hand a failure to [onNegotiationError]. Without a
  /// handler it propagates exactly as before. Direct [createAndSendOffer]
  /// callers still get the error.
  Future<void> _createAndSendOfferReportingErrors() async {
    try {
      await createAndSendOffer();
    } catch (error) {
      final handler = onNegotiationError;
      if (handler == null) rethrow;
      logger.warning('[$objectId] negotiate() failed with error: $error');
      handler(error);
    }
  }

  Future<void> setRemoteDescription(rtc.RTCSessionDescription sd) async {
    if (isDisposed) {
      logger.warning('[$objectId] setRemoteDescription() already disposed');
      return;
    }

    try {
      await pc.setRemoteDescription(sd);
    } catch (e) {
      logger.warning('[$objectId] setRemoteDescription() failed with error: $e');
    }

    for (final candidate in _pendingCandidates) {
      await pc.addCandidate(candidate);
    }

    _pendingCandidates.clear();
    restartingIce = false;

    if (renegotiate) {
      renegotiate = false;
      await _createAndSendOfferReportingErrors();
    }
  }

  /// GRAVIX (0.4.15, device run A4 2026-10-10): an offer still in flight when
  /// the transport is disposed fails with "Called in wrong state: closed" (a
  /// leave unpublishes the microphone, the debounced renegotiation fires, then
  /// the leave closes the peer connection). That is not a negotiation failure:
  /// a closed connection has nothing to negotiate, so the failure is dropped
  /// instead of surfacing as an unhandled NegotiationError (or a reconnect
  /// request after the leave). A live transport's failure propagates as before.
  Future<void> createAndSendOffer([RTCOfferOptions? options]) async {
    try {
      await _createAndSendOffer(options);
    } catch (error) {
      if (!isDisposed) rethrow;
      logger.fine('[$objectId] offer dropped: the transport was disposed while it was in flight ($error)');
    }
  }

  Future<void> _createAndSendOffer([RTCOfferOptions? options]) async {
    if (isDisposed) {
      logger.warning('[$objectId] createAndSendOffer() already disposed');
      return;
    }

    if (onOffer == null) {
      logger.warning('onOffer is null');
      return;
    }

    final iceRestart = options?.iceRestart ?? false;
    if (!iceRestart && (gravixHoldOffers?.call() ?? false)) {
      logger.fine(
        '[$objectId] offer held: the signal socket cannot carry it (a reconnect is dialling); '
        'it goes out after the next answer',
      );
      renegotiate = true;
      return;
    }

    if (iceRestart) {
      logger.fine('restarting ICE');
      restartingIce = true;
    }

    if (await pc.getSignalingState() == rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      // we're waiting for the peer to accept our offer, so we'll just wait
      // the only exception to this is when ICE restart is needed
      final currentSD = await getRemoteDescription();
      if (iceRestart && currentSD != null) {
        // TODO: handle when ICE restart is needed but we don't have a remote description
        // the best thing to do is to recreate the peerconnection
        if (!(gravixRollbackStaleOffer && await _gravixRollbackLocalOffer())) {
          await pc.setRemoteDescription(currentSD);
        }
      } else {
        renegotiate = true;
        return;
      }
    }

    if (restartingIce && !lkPlatformIs(PlatformType.web)) {
      await pc.restartIce();
    }

    // actually negotiate
    logger.fine('starting to negotiate');
    final offer = await pc.createOffer(options?.toMap() ?? <String, dynamic>{});

    final sdpParsed = sdp_transform.parse(offer.sdp ?? '');
    if (gravixConnectionLevelStartBitrate) {
      await _setOfferWithConnectionStartBitrate(offer, sdpParsed);
      onOffer?.call(offer);
      return;
    }
    sdpParsed['media']?.forEach((media) {
      if (media['type'] == 'video') {
        ensureVideoDDExtensionForSVC(media, media['type'], media['port'], media['protocol'], media['payloads']);

        // mung sdp for codec bitrate setting that can't apply by sendEncoding
        for (var trackbr in _bitrateTrackers) {
          if (media['msid'] == null || trackbr.cid == null || !(media['msid'] as String).contains(trackbr.cid!)) {
            continue;
          }

          var codecPayload = 0;
          for (var rtp in media['rtp']) {
            if (rtp['codec']?.toUpperCase() == trackbr.codec.toUpperCase()) {
              codecPayload = rtp['payload'];
              continue;
            }
            continue;
          }

          if (codecPayload == 0) {
            continue;
          }

          for (var fmtp in media['fmtp']) {
            if (fmtp['payload'] == codecPayload) {
              if (!(fmtp['config'] as String).contains('x-google-start-bitrate')) {
                fmtp['config'] += ';x-google-start-bitrate=${(trackbr.maxbr * startBitrateMultiplier).toInt()}';
              }
              break;
            }
          }
          continue;
        }
      }
    });

    try {
      await setMungedSDP(sd: offer, munged: sdp_transform.write(sdpParsed, null));
    } catch (e) {
      throw NegotiationError(e.toString());
    }
    onOffer?.call(offer);
  }

  /// GRAVIX (0.4.15, BUG-3): drops the pending local offer (an SDP rollback,
  /// Unified Plan) so the restart offer starts from the last applied pair. The
  /// rollback does not undo sender changes (removeTrack sets the transceiver's
  /// direction, which a rollback keeps), so the restart offer still carries
  /// them. True when the connection is stable afterwards; false (logged) when
  /// the native side refused it, and the caller keeps the old behaviour.
  Future<bool> _gravixRollbackLocalOffer() async {
    try {
      // '' rather than null: the Android plugin builds a SessionDescription
      // from the map's string, and the type alone is what a rollback reads.
      await pc.setLocalDescription(rtc.RTCSessionDescription('', 'rollback'));
      final stable = await pc.getSignalingState() == rtc.RTCSignalingState.RTCSignalingStateStable;
      logger.fine('[$objectId] ICE restart: rolled back an unanswered local offer (stable: $stable)');
      return stable;
    } catch (error) {
      logger.warning(
        '[$objectId] ICE restart: rollback of the unanswered local offer refused ($error); '
        're-applying the current answer',
      );
      return false;
    }
  }

  /// Upstream 2.13.1 (#1218/#1228) munging: one connection-level hint, written once.
  Future<void> _setOfferWithConnectionStartBitrate(
    rtc.RTCSessionDescription offer,
    Map<String, dynamic> sdpParsed,
  ) async {
    final setupCompleted = !(_connectStopwatch?.isRunning ?? false);
    final connectionSetupTime = connectionSetupTimeForOffer;
    final connectionStartBitrate = _hasAppliedVideoStartBitrate
        ? null
        : computeConnectionStartBitrate(sdpParsed['media'] ?? const [], _bitrateTrackers, connectionSetupTime);
    if (connectionStartBitrate != null) {
      logger.info(
        'Applying x-google-start-bitrate=$connectionStartBitrate kbps '
        '(connection setup ${connectionSetupTime?.inMilliseconds} ms${setupCompleted ? '' : ', still connecting'})',
      );
    }
    var appliedVideoStartBitrate = false;
    sdpParsed['media']?.forEach((media) {
      if (media['type'] == 'video') {
        ensureVideoDDExtensionForSVC(media, media['type'], media['port'], media['protocol'], media['payloads']);
        for (var trackbr in _bitrateTrackers) {
          final cid = trackbr.cid;
          if (cid == null) continue;
          final codecPayload = findTrackCodecPayload(media, cid, trackbr.codec);
          if (codecPayload == null) continue;
          if (codecPayload > 0 && connectionStartBitrate != null) {
            applyVideoStartBitrate(media, codecPayload, connectionStartBitrate);
            appliedVideoStartBitrate = true;
          }
          break;
        }
      }
    });
    final mungedSdp = sdp_transform.write(sdpParsed, null);
    try {
      await setMungedSDP(sd: offer, munged: mungedSdp);
    } catch (e) {
      throw NegotiationError(e.toString());
    }
    // setMungedSDP falls back to the unmunged SDP on rejection: consume the one-shot hint
    // only once the SDP carrying it was accepted
    if (appliedVideoStartBitrate && offer.sdp == mungedSdp) {
      _hasAppliedVideoStartBitrate = true;
    }
  }

  @visibleForTesting
  List<TrackBitrateInfo> get bitrateTrackers => List.unmodifiable(_bitrateTrackers);

  Future<void> addIceCandidate(rtc.RTCIceCandidate candidate) async {
    if (isDisposed) {
      logger.warning('[$objectId] addIceCandidate() already disposed');
      return;
    }

    final desc = await getRemoteDescription();

    if (desc != null && !restartingIce) {
      await pc.addCandidate(candidate);
      return;
    }

    _pendingCandidates.add(candidate);
  }

  Future<rtc.RTCSessionDescription?> getRemoteDescription() async {
    if (isDisposed) {
      logger.warning('[$objectId] getRemoteDescription() already disposed');
      return null;
    }

    // Checking agains null doesn't work as intended
    // if (pc.iceConnectionState == null) return null;

    try {
      final result = await pc.getRemoteDescription();
      return result;
    } catch (err) {
      logger.warning('pc.getRemoteDescription failed with error: $err');
    }
    return null;
  }

  void setTrackBitrateInfo(TrackBitrateInfo info) {
    // upstream 2.13.1: one entry per cid (a republished track keeps its cid; a
    // leftover entry would shadow the new target)
    if (gravixConnectionLevelStartBitrate) {
      _bitrateTrackers.removeWhere((e) => e.cid != null && e.cid == info.cid);
    }
    _bitrateTrackers.add(info);
  }

  bool ensureVideoDDExtensionForSVC(
    Map<String, dynamic> media,
    String? type,
    num port,
    String protocol,
    String? payloads,
  ) {
    final codec = media['rtp']?[0]?['codec']?.toLowerCase();
    if (!isSVCCodec(codec)) {
      return false;
    }

    var maxID = 0;
    bool ddFound = false;
    final List<dynamic>? ext = media['ext'];
    if (ext != null) {
      for (var e in ext) {
        if (e['uri'] == ddExtensionURI) {
          ddFound = true;
          continue;
        }
        if (e['value'] > maxID) {
          maxID = e['value'];
        }
      }
    }

    if (!ddFound) {
      ext?.add({'value': maxID + 1, 'uri': ddExtensionURI});
    }

    return ddFound;
  }

  Future<void> setMungedSDP({required rtc.RTCSessionDescription sd, String? munged, bool? remote}) async {
    if (munged != null) {
      final originalSdp = sd.sdp;
      sd.sdp = munged;
      try {
        logger.fine('setting munged ${remote == true ? 'remote' : 'local'}');
        logger.finer('description munged: $munged ');
        if (remote == true) {
          await pc.setRemoteDescription(sd);
        } else {
          await pc.setLocalDescription(sd);
        }
        return;
      } catch (e) {
        logger.warning('not able to set ${sd.type}, falling back to unmodified sdp error: $e, sdp: $munged ');
        sd.sdp = originalSdp;
      }
    }

    try {
      if (remote == true) {
        await pc.setRemoteDescription(sd);
      } else {
        await pc.setLocalDescription(sd);
      }
    } catch (e) {
      // this error cannot always be caught.ght
      logger.warning('unable to set ${sd.type}, error: $e, sdp: ${sd.sdp}');
      rethrow;
    }
  }
}
