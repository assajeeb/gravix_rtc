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
import 'gravix_pub_log.dart';
import '../support/gravix_native_gate.dart';

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

/// GRAVIX (2026-10-21, DTX): the answer's opus fmtp for one of our published
/// audio sections: `usedtx=1` when [dtx] is on (removed when off), `stereo=1`
/// only for a stereo publication. Other parameters are kept. Same rule as the
/// JS SDK's mungeOpusAnswerFmtp.
@internal
String gravixMungeOpusAnswerFmtp(String config, {required bool dtx, required bool stereo}) {
  bool keep(String attr, String name) => attr.split('=').first.trim() != name;
  final attrs = config
      .split(';')
      .map((a) => a.trim())
      .where((a) => a.isNotEmpty && keep(a, 'usedtx') && keep(a, 'stereo'))
      .toList();
  if (dtx) attrs.add('usedtx=1');
  if (stereo) attrs.add('stereo=1');
  return attrs.join(';');
}

/// What we publish on an audio section, for the answer pin.
@internal
class GravixOpusPin {
  const GravixOpusPin({required this.dtx, this.stereo = false});
  final bool dtx;
  final bool stereo;
}

/// GRAVIX (2026-10-21, DTX): pins the opus fmtp of our published audio sections
/// in the publisher's [answerSdp]. The SFU sometimes answers the mic section by
/// mirroring the offer (`stereo=1`, no `usedtx`): DTX off, a silent mic sent
/// ~37 kbps. [midCid] maps our offer's audio mids to the track cid in their
/// msid; [pins] is per cid. Null when nothing changes, or when the pin would give
/// one bundled payload type two different fmtp lines (libwebrtc rejects that):
/// the answer is then applied as it came.
@internal
String? gravixPinOpusAnswer(String answerSdp, Map<String, String> midCid, Map<String, GravixOpusPin> pins) {
  if (pins.isEmpty || midCid.isEmpty) return null;
  final parsed = sdp_transform.parse(answerSdp);
  final media = (parsed['media'] as List?) ?? const [];
  var changed = false;
  for (final m in media) {
    if (m['type'] != 'audio') continue;
    final cid = midCid['${m['mid']}'];
    final pin = cid == null ? null : pins[cid];
    if (pin == null) continue;
    int? opus;
    for (final rtp in (m['rtp'] as List? ?? const [])) {
      if ((rtp['codec'] as String?)?.toLowerCase() == 'opus') {
        opus = rtp['payload'] as int?;
        break;
      }
    }
    if (opus == null) continue;
    final fmtps = (m['fmtp'] as List?) ?? <dynamic>[];
    var found = false;
    for (final f in fmtps) {
      if (f['payload'] == opus) {
        final next = gravixMungeOpusAnswerFmtp('${f['config'] ?? ''}', dtx: pin.dtx, stereo: pin.stereo);
        if (next != f['config']) {
          f['config'] = next;
          changed = true;
        }
        found = true;
        break;
      }
    }
    if (!found) {
      final config = gravixMungeOpusAnswerFmtp('', dtx: pin.dtx, stereo: pin.stereo);
      if (config.isNotEmpty) {
        fmtps.add(<String, dynamic>{'payload': opus, 'config': config});
        m['fmtp'] = fmtps;
        changed = true;
      }
    }
  }
  if (!changed) return null;
  // one payload type, one fmtp across the bundle
  final byPayload = <int, String>{};
  for (final m in media) {
    for (final f in (m['fmtp'] as List? ?? const [])) {
      final pt = f['payload'] as int?;
      if (pt == null) continue;
      final prev = byPayload[pt];
      if (prev != null && prev != '${f['config']}') return null;
      byPayload[pt] = '${f['config']}';
    }
  }
  return sdp_transform.write(parsed, null);
}

typedef TransportOnOffer = void Function(rtc.RTCSessionDescription offer);
typedef TransportOnNegotiationError = void Function(Object error);
typedef PeerConnectionCreate = Future<rtc.RTCPeerConnection> Function(
  Map<String, dynamic> configuration, [
  Map<String, dynamic> constraints,
]);

/// a wrapper around PeerConnection
class Transport extends Disposable {
  final rtc.RTCPeerConnection pc;
  final List<rtc.RTCIceCandidate> _pendingCandidates = [];
  final List<TrackBitrateInfo> _bitrateTrackers = [];

  /// GRAVIX (2026-10-21, DTX): what each published audio track (by cid) wants
  /// in the answer, and our last offer's audio mid -> cid (see
  /// [gravixPinOpusAnswer]).
  final Map<String, GravixOpusPin> _opusPins = {};
  Map<String, String> _audioMidCid = const {};

  /// An audio publication's answer pin: `usedtx=1` unless [dtx] is off, `stereo`
  /// only when [stereo]. Kept per cid (a republish replaces it).
  void gravixSetOpusPin(String cid, {required bool dtx, bool stereo = false}) {
    _opusPins[cid] = GravixOpusPin(dtx: dtx, stereo: stereo);
  }

  void _noteAudioMids(Map<String, dynamic> sdpParsed) {
    final map = <String, String>{};
    for (final m in (sdpParsed['media'] as List? ?? const [])) {
      if (m['type'] != 'audio') continue;
      final msid = m['msid'];
      if (msid is! String) continue;
      for (final cid in _opusPins.keys) {
        if (msid.contains(cid)) {
          map['${m['mid']}'] = cid;
          break;
        }
      }
    }
    _audioMidCid = map;
  }

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

  /// GRAVIX (0.4.19): the name in this transport's [GravixPubLog] lines (the
  /// engine sets `pub#<generation>`).
  String gravixLogLabel = 'pc';

  /// GRAVIX (0.4.19, MUSIC-SDP, device 2026-10-15): one offer at a time. Offer
  /// creation (createOffer, munging, setLocalDescription, onOffer) and the
  /// answer's application run one after the other on this chain. Before, a
  /// debounced negotiate() that fired while the previous offer was still being
  /// created (60-200 ms on a phone), or while the answer's [renegotiate] replay
  /// was, also found the connection stable and created a second offer from the
  /// same state. libwebrtc names a transceiver that has no mid yet afresh in
  /// every createOffer, so the second offer's m-lines did not match the first
  /// (now pending) one: "Failed to set local offer sdp: The order of m-lines in
  /// subsequent offer doesn't match order from previous offer/answer" (munged
  /// and unmunged), a NegotiationError and a full rejoin. Room music republishes
  /// the microphone twice per track change, which made it frequent (7 full
  /// rejoins in one host session). Now the later call waits, finds the offer
  /// pending, and is replayed after the answer ([renegotiate]).
  Future<void> _offerChain = Future<void>.value();
  int _offerChainDepth = 0;

  /// GRAVIX (0.4.19, HOST-CAMERA, device 2026-10-15): a local offer is set and
  /// its answer not yet applied (Dart-side; no native read). While it is set, a
  /// non-restart offer request only marks [renegotiate] (`offerDefer`) and
  /// returns WITHOUT entering the offer chain: a camera published while the
  /// first (mic) offer was out queued in front of that offer's answer, only to
  /// read have-local-offer natively and defer, and that round trip under
  /// main-thread load held the answer 24-423 ms (mic and camera live slipped
  /// by the same, 4 of 10 cold host joins).
  bool _offerPending = false;

  /// The sender set of the last offer set locally ([gravixSenderSet]): a
  /// replay whose fresh offer has the same set is skipped (`offerReplaySkip`), not sent as an
  /// identical extra round trip. Not after an ICE restart offer: a change
  /// held during a resume is still replayed after the restart's answer (BUG-3).
  String? _lastOfferSenders;
  // the raw lines of the last offer set locally (only for `offerReplayDiff`)
  String? _lastOfferSdp;
  bool _lastOfferWasRestart = false;

  /// GRAVIX (0.4.19, HOST-VIDEO-COLD, device 2026-10-15): offer requests made
  /// so far ([negotiate] / [createAndSendOffer] calls), and how many of them the
  /// last offer set locally covers (the count when its createOffer was issued:
  /// every change behind those requests was made before it). A request deferred
  /// while that offer is out and already covered by it needs no replay
  /// (`offerCovered`).
  int _offerRequests = 0;
  int _coveredRequests = -1;

  /// A remote description was applied (Dart-side): a remote candidate is added
  /// at once, with no native getRemoteDescription round trip per candidate.
  bool _remoteSet = false;

  @visibleForTesting
  bool get gravixOfferPending => _offerPending;

  /// The longest a step waits for the one ahead of it: a native call that never
  /// returns must not hold every later offer, answer and ICE restart forever.
  @visibleForTesting
  Duration gravixOfferChainWait = const Duration(seconds: 10);

  Future<T> _serialised<T>(String what, Future<T> Function() body) {
    if (_offerChainDepth > 0) {
      GravixPubLog.step('${what}Wait', pc: gravixLogLabel, detail: '(${_offerChainDepth} step(s) ahead)');
    }
    _offerChainDepth++;
    final result = _offerChain
        .timeout(
          gravixOfferChainWait,
          onTimeout: () => GravixPubLog.step(
            '${what}WaitTimeout',
            pc: gravixLogLabel,
            detail: 'the step ahead did not finish in ${gravixOfferChainWait.inMilliseconds} ms: going ahead',
          ),
        )
        .then((_) => body());
    _offerChain = result.then<void>((_) {}, onError: (Object _) {}).whenComplete(() => _offerChainDepth--);
    return result;
  }

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

  late final _negotiateDebounced = Utils.createDebounceFunc(
    (void _) => _createAndSendOfferReportingErrors(),
    cancelFunc: (f) => _cancelDebounce = f,
    wait: connectOptions.timeouts.debounce,
  );

  /// A debounced offer request (a sender changed).
  void negotiate(void _) {
    _offerRequests++;
    _negotiateDebounced(null);
  }

  /// The debouncer and the offer deferred until the answer arrives have no caller
  /// that handles errors: hand a failure to [onNegotiationError]. Without a
  /// handler it propagates exactly as before. Direct [createAndSendOffer]
  /// callers still get the error.
  Future<void> _createAndSendOfferReportingErrors({bool replay = false}) async {
    try {
      await _offerOnChain(null, replay: replay);
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

    // GRAVIX (0.4.19, MUSIC-SDP): on the offer chain, so an offer being
    // created when the answer lands is applied first (and a negotiate() that
    // read have-local-offer has set [renegotiate] before it is read below).
    await _serialised('remote', () async {
      try {
        // GRAVIX (2026-10-21, DTX): our audio sections' opus fmtp pinned
        final pinned = sd.type == 'answer' ? gravixPinOpusAnswer(sd.sdp ?? '', _audioMidCid, _opusPins) : null;
        if (pinned != null) {
          try {
            await GravixNativeGate.remoteDescription(
              () => pc.setRemoteDescription(rtc.RTCSessionDescription(pinned, 'answer')),
              pc: gravixLogLabel,
            );
            GravixPubLog.step('answerPin', pc: gravixLogLabel, detail: 'opus usedtx/stereo pinned');
          } catch (e) {
            GravixPubLog.step(
              'answerPin',
              pc: gravixLogLabel,
              detail: 'refused (${GravixPubLog.reason(e)}), as answered',
            );
            await GravixNativeGate.remoteDescription(() => pc.setRemoteDescription(sd), pc: gravixLogLabel);
          }
        } else {
          await GravixNativeGate.remoteDescription(() => pc.setRemoteDescription(sd), pc: gravixLogLabel);
        }
        _remoteSet = true;
        if (sd.type == 'answer') _offerPending = false;
        GravixPubLog.step(
          'remoteSet',
          pc: gravixLogLabel,
          detail: '${sd.type} ok replay=$renegotiate mlines=${GravixPubLog.mlines(sd.sdp)}',
        );
      } catch (e) {
        GravixPubLog.step('remoteSet', pc: gravixLogLabel, detail: '${sd.type} FAIL reason=${GravixPubLog.reason(e)}');
        logger.warning('[$objectId] setRemoteDescription() failed with error: $e');
      }

      for (final candidate in _pendingCandidates) {
        await pc.addCandidate(candidate);
      }

      _pendingCandidates.clear();
      restartingIce = false;
    });

    if (renegotiate) {
      // GRAVIX (0.4.19, MUSIC-SDP): [renegotiate] is read again when the replay's
      // turn on the chain comes: an offer that got there first already carried
      // the change (and cleared it), so the replay is skipped, not sent empty
      GravixPubLog.step('offerReplay', pc: gravixLogLabel, detail: 'a sender change waited for this answer');
      await _createAndSendOfferReportingErrors(replay: true);
    }
  }

  /// GRAVIX (0.4.15, device run A4 2026-10-10): an offer still in flight when
  /// the transport is disposed fails with "Called in wrong state: closed" (a
  /// leave unpublishes the microphone, the debounced renegotiation fires, then
  /// the leave closes the peer connection). That is not a negotiation failure:
  /// a closed connection has nothing to negotiate, so the failure is dropped
  /// instead of surfacing as an unhandled NegotiationError (or a reconnect
  /// request after the leave). A live transport's failure propagates as before.
  Future<void> createAndSendOffer([RTCOfferOptions? options]) {
    _offerRequests++;
    return _offerOnChain(options);
  }

  // A non-restart offer request while an offer is out: covered by that offer
  // (nothing to do) or marked for the replay after its answer.
  void _deferWhilePending(String where) {
    if (!_lastOfferWasRestart && _offerRequests <= _coveredRequests) {
      GravixPubLog.step('offerCovered', pc: gravixLogLabel, detail: '$where: the pending offer carries it');
      return;
    }
    GravixPubLog.step('offerDefer', pc: gravixLogLabel, detail: '$where: replayed after the answer');
    renegotiate = true;
  }

  Future<void> _offerOnChain(RTCOfferOptions? options, {bool replay = false}) async {
    // GRAVIX (0.4.19, HOST-CAMERA): an offer is out: the change goes in the
    // replay after its answer, with no chain step and no native call in front
    // of that answer. ICE restarts (and a held-offer check) keep the chain path.
    if (_offerPending && !replay && !(options?.iceRestart ?? false) && !isDisposed) {
      _deferWhilePending('offer pending');
      return;
    }
    try {
      // GRAVIX (0.4.19, MUSIC-SDP): one offer at a time (see [_offerChain])
      await _serialised('offer', () => _createAndSendOffer(options, replay));
    } catch (error) {
      if (!isDisposed) rethrow;
      logger.fine('[$objectId] offer dropped: the transport was disposed while it was in flight ($error)');
    }
  }

  Future<void> _createAndSendOffer([RTCOfferOptions? options, bool replay = false]) async {
    if (isDisposed) {
      logger.warning('[$objectId] createAndSendOffer() already disposed');
      return;
    }

    if (replay && !renegotiate) {
      GravixPubLog.step('offerReplaySkip', pc: gravixLogLabel, detail: 'an offer since the answer carried the change');
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
      GravixPubLog.step('offerHold', pc: gravixLogLabel, detail: 'signal socket not connected: after the next answer');
      renegotiate = true;
      return;
    }

    if (iceRestart) {
      logger.fine('restarting ICE');
      restartingIce = true;
    }

    // GRAVIX (0.4.19, HOST-VIDEO-COLD): a non-restart offer reads the Dart-side
    // pending mark, not the native signaling state: that round trip under
    // main-thread load was most of the 0.5 s between an answer and its replay
    // offer on a cold host join. An ICE restart still reads the native state.
    if (!iceRestart) {
      if (_offerPending) {
        _deferWhilePending('have-local-offer');
        return;
      }
    } else if (await pc.getSignalingState() == rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      // we're waiting for the peer to accept our offer, so we'll just wait
      // the only exception to this is when ICE restart is needed
      final currentSD = await getRemoteDescription();
      if (currentSD != null) {
        // TODO: handle when ICE restart is needed but we don't have a remote description
        // the best thing to do is to recreate the peerconnection
        if (!(gravixRollbackStaleOffer && await _gravixRollbackLocalOffer())) {
          await GravixNativeGate.remoteDescription(() => pc.setRemoteDescription(currentSD), pc: gravixLogLabel);
        }
        _offerPending = false; // stable again: the restart offer is next
      } else {
        GravixPubLog.step('offerDefer', pc: gravixLogLabel, detail: 'have-local-offer: replayed after the answer');
        renegotiate = true;
        return;
      }
    }

    if (restartingIce && !lkPlatformIs(PlatformType.web)) {
      await pc.restartIce();
    }

    // actually negotiate
    logger.fine('starting to negotiate');
    // GRAVIX (0.4.19, MUSIC-SDP): this offer carries every sender change made
    // so far, so a replay asked for earlier is satisfied by it (a change made
    // after the snapshot finds the offer pending and asks again). An ICE
    // restart keeps the BUG-3 behaviour: a held offer is replayed after it.
    if (!iceRestart) renegotiate = false;
    final covers = _offerRequests;
    final offer = await pc.createOffer(options?.toMap() ?? <String, dynamic>{});
    GravixPubLog.step(
      'offerCreate',
      pc: gravixLogLabel,
      detail: 'restart=$iceRestart mlines=${GravixPubLog.mlines(offer.sdp)}',
    );
    final senders = gravixSenderSet(offer.sdp);
    if (replay && !iceRestart && !_lastOfferWasRestart) {
      if (senders == _lastOfferSenders) {
        // GRAVIX (0.4.19, HOST-CAMERA): the answered offer already carried this
        // sender set (the change was in it): nothing to negotiate
        GravixPubLog.step(
          'offerReplaySkip',
          pc: gravixLogLabel,
          detail: 'sender set unchanged since the last offer${_diffDetail(_lastOfferSdp, offer.sdp, ' other lines')}',
        );
        return;
      }
      GravixPubLog.step(
        'offerReplayDiff',
        pc: gravixLogLabel,
        detail: _diffDetail(_lastOfferSdp, offer.sdp, '').trim(),
      );
    }

    final sdpParsed = sdp_transform.parse(offer.sdp ?? '');
    _noteAudioMids(sdpParsed);
    if (gravixConnectionLevelStartBitrate) {
      await _setOfferWithConnectionStartBitrate(offer, sdpParsed);
      _noteLocalOffer(senders, iceRestart, covers, offer.sdp);
      _gravixLogOfferSent(offer);
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
      throw NegotiationError(GravixPubLog.safeError(e));
    }
    _noteLocalOffer(senders, iceRestart, covers, offer.sdp);
    _gravixLogOfferSent(offer);
    onOffer?.call(offer);
  }

  void _noteLocalOffer(String senders, bool iceRestart, int covers, String? rawSdp) {
    _offerPending = true;
    _lastOfferSenders = senders;
    _lastOfferSdp = rawSdp;
    _lastOfferWasRestart = iceRestart;
    _coveredRequests = covers;
  }

  /// The attribute NAMES (never values: ice-pwd, fingerprint) of the lines that
  /// differ between two offers: ` attrs=a=ice-ufrag,a=mid,m=` (for a field log
  /// of why a replay was or was not skipped). Empty when none.
  static String _diffDetail(String? a, String? b, String label) {
    Set<String> lines(String? sdp) =>
        (sdp ?? '').split('\n').map((l) => l.trimRight()).where((l) => l.isNotEmpty).toSet();
    final la = lines(a), lb = lines(b);
    final names = <String>{for (final l in la.difference(lb).union(lb.difference(la))) _attrName(l)}.toList()..sort();
    return names.isEmpty ? '' : '$label attrs=${names.join(',')}';
  }

  static String _attrName(String line) {
    if (line.startsWith('a=')) {
      final end = line.indexOf(RegExp('[: ]'));
      return end < 0 ? line : line.substring(0, end);
    }
    return line.length >= 2 ? line.substring(0, 2) : line;
  }

  /// GRAVIX (0.4.19, HOST-CAMERA / HOST-VIDEO-COLD): the senders an offer
  /// negotiates, per m-section: its kind and whether it is rejected (port 0
  /// without `a=bundle-only`), `a=mid`, the direction, `a=msid`, `a=ssrc` /
  /// `a=ssrc-group` and `a=rid` / `a=simulcast`. Everything else is left out:
  /// transport lines (ICE credentials, candidates, `c=`, `a=rtcp`, DTLS, ports,
  /// BUNDLE) and the codec and header-extension lists. The first offer of a
  /// fresh connection (one transport per m-section) and a re-offer after
  /// BUNDLE was accepted (one) differed in some line the device log could not
  /// name (SDP bodies are never logged; `offerReplayDiff` names it now), with
  /// the same senders. Codecs: this SDK sets codec preferences only on a new
  /// transceiver (a new mid), and a re-offer may list the codecs differently
  /// after the answer.
  @visibleForTesting
  static String gravixSenderSet(String? sdp) {
    final out = <String>[];
    var bundleOnly = false;
    String? mline;
    final section = <String>[];
    void flush() {
      final m = mline;
      if (m == null) return;
      final p = m.split(' ');
      final rejected = p.length > 1 && p[1] == '0' && !bundleOnly;
      out
        ..add('m=${p.first.substring(2)}${rejected ? ' rejected' : ''}')
        ..addAll(section);
      section.clear();
      bundleOnly = false;
    }

    for (final raw in (sdp ?? '').split('\n')) {
      final line = raw.trimRight();
      if (line.startsWith('m=')) {
        flush();
        mline = line;
        continue;
      }
      if (mline == null) continue;
      if (line == 'a=bundle-only') {
        bundleOnly = true;
      } else if (line.startsWith('a=mid:') ||
          line.startsWith('a=msid:') ||
          line.startsWith('a=ssrc:') ||
          line.startsWith('a=ssrc-group:') ||
          line.startsWith('a=rid:') ||
          line.startsWith('a=simulcast:') ||
          line == 'a=sendrecv' ||
          line == 'a=sendonly' ||
          line == 'a=recvonly' ||
          line == 'a=inactive') {
        section.add(line);
      }
    }
    flush();
    return out.join('\n');
  }

  void _gravixLogOfferSent(rtc.RTCSessionDescription offer) => GravixPubLog.step(
    'offerSent',
    pc: gravixLogLabel,
    detail: onOffer == null ? 'no signal handler' : 'mlines=${GravixPubLog.mlines(offer.sdp)}',
  );

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
      if (stable) _offerPending = false;
      GravixPubLog.step(
        'offerRollback',
        pc: gravixLogLabel,
        detail: 'ICE restart: unanswered offer dropped stable=$stable',
      );
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
      throw NegotiationError(GravixPubLog.safeError(e));
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

    // GRAVIX (0.4.19, HOST-VIDEO-COLD): the Dart-side mark, not a native
    // getRemoteDescription per candidate: that round trip could also return
    // "none" while the answer was being applied and land after the answer step
    // flushed the pending list, leaving the candidate unused until the next
    // answer. The answer step sets the mark before it flushes.
    if (_remoteSet && !restartingIce) {
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
        // GRAVIX (0.4.19): never an SDP body in a log (ice-pwd, fingerprint)
        logger.finer('description munged: ${GravixPubLog.describe(sd.type, munged)}');
        if (remote == true) {
          await GravixNativeGate.remoteDescription(() => pc.setRemoteDescription(sd), pc: gravixLogLabel);
        } else {
          await pc.setLocalDescription(sd);
        }
        _gravixLogSet(remote, sd, 'ok munged=${munged != originalSdp}');
        return;
      } catch (e) {
        _gravixLogSet(remote, sd, 'FAIL munged=true reason=${GravixPubLog.reason(e)} (retrying unmunged)');
        logger.warning(
          'not able to set ${sd.type}, falling back to unmodified sdp error: ${GravixPubLog.safeError(e)}, '
          'sdp: ${GravixPubLog.describe(sd.type, munged)}',
        );
        sd.sdp = originalSdp;
      }
    }

    try {
      if (remote == true) {
        await GravixNativeGate.remoteDescription(() => pc.setRemoteDescription(sd), pc: gravixLogLabel);
      } else {
        await pc.setLocalDescription(sd);
      }
      _gravixLogSet(remote, sd, 'ok munged=false');
    } catch (e) {
      _gravixLogSet(remote, sd, 'FAIL munged=false reason=${GravixPubLog.reason(e)}');
      // this error cannot always be caught.ght
      logger.warning(
        'unable to set ${sd.type}, error: ${GravixPubLog.safeError(e)}, sdp: ${GravixPubLog.describe(sd.type, sd.sdp)}',
      );
      rethrow;
    }
  }

  void _gravixLogSet(bool? remote, rtc.RTCSessionDescription sd, String result) => GravixPubLog.step(
    remote == true ? 'setRemote' : 'setLocal',
    pc: gravixLogLabel,
    detail: '${sd.type} $result mlines=${GravixPubLog.mlines(sd.sdp)}',
  );
}
