// Copyright Gravity Compile, Inc. Apache 2.0.
//
// Join timeline: where the time between "the user tapped join" and "the user
// hears someone" actually goes.
//
// Why this exists. The owner's standing complaint is that joining feels slower
// than Agora. Until 2026-09-19 the only join number either SDK produced was one
// figure — join-to-first-audio — and the two SDKs did not even mean the same
// thing by it (Flutter: a track was SUBSCRIBED; JS: an RTP packet ARRIVED;
// neither: audio was PLAYED). One number cannot say whether the wait is the
// app's own backend call, the token gateway, the region probe, the audio
// session, the WebSocket, ICE, DTLS, or the jitter buffer — and each of those
// has a different owner and a different fix. This splits the join into steps,
// names the owner of each, and reports the selected candidate pair so a silent
// TCP/TURN fallback (which costs hundreds of ms and is invisible otherwise)
// shows up as a flag instead of as "the network was slow".
//
// LOCAL OBSERVATION ONLY. Nothing here changes a byte on the wire, the SDP, or
// the signalling sequence; it timestamps events the engine already emits and
// reads getStats(). With the option off (the default) none of it runs.
//
// The JSON field names are a cross-SDK contract with the JS SDK's JoinTimeline.
// Do not rename one here without renaming it there.

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Step names — the keys of `t` in the JSON. Shared verbatim with the JS SDK.
abstract final class GravixJoinStep {
  /// App-supplied: the moment the user's finger went down on "join".
  static const tapAt = 'tapAt';
  static const tokenRequestStart = 'tokenRequestStart';
  static const tokenRequestEnd = 'tokenRequestEnd';

  /// `GravixRoomService.connect` entered.
  static const connectStart = 'connectStart';
  static const regionProbeStart = 'regionProbeStart';
  static const regionProbeEnd = 'regionProbeEnd';
  static const audioSessionStart = 'audioSessionStart';
  static const audioSessionEnd = 'audioSessionEnd';

  /// Around enabling the microphone, which is where the OS permission prompt
  /// (if any) is paid. Null for a listener join: a listener never asks.
  static const micPermissionStart = 'micPermissionStart';
  static const micPermissionEnd = 'micPermissionEnd';

  /// The signal client is about to dial the WebSocket.
  static const wsConnectStart = 'wsConnectStart';
  static const wsOpen = 'wsOpen';

  /// The JoinResponse ARRIVED (signal-client event), before the engine has
  /// built peer connections from it.
  static const joinResponse = 'joinResponse';

  /// Flutter-only extra: the engine finished creating peer connections from the
  /// JoinResponse (and kicked off negotiation when it is the offerer). The gap
  /// from [joinResponse] is local CPU on the phone, not network.
  static const pcSetupDone = 'pcSetupDone';

  /// ICE connected on the primary peer connection, OBSERVED IN getStats():
  /// the first stats snapshot whose `transport.iceState` is connected/completed
  /// (or, on a stack without that field, that has a succeeded candidate pair),
  /// stamped with the snapshot's own timestamp.
  ///
  /// NOT the `onIceConnectionState` callback. That was the first implementation
  /// and the first real phone join (2026-09-19, 2201117TG) showed it firing 2-23
  /// ms AFTER the peer connection reported connected, i.e. a negative DTLS time.
  /// flutter_webrtc forwards libwebrtc's LEGACY ice-connection callback (its
  /// `onStandardizedIceConnectionChange` is an empty method), and the legacy
  /// state only turns "connected" once the DTLS transport is WRITABLE - so that
  /// callback marks the END of DTLS, not the end of ICE.
  ///
  /// Null when no snapshot caught the in-between state (ICE up, DTLS not yet):
  /// libwebrtc caches a stats report for 50 ms, so an ICE-to-DTLS gap shorter
  /// than that (a LAN) cannot be resolved, and a guess is not reported. See
  /// `ice` in the report for the bounds that WERE observed.
  static const iceConnected = 'iceConnected';

  /// Primary peer connection `connected` = ICE + DTLS both done.
  static const pcConnected = 'pcConnected';

  /// First remote audio track SUBSCRIBED. What Flutter called "first audio"
  /// until now. It is a subscription, not audio.
  static const firstAudioSubscribed = 'firstAudioSubscribed';

  /// First inbound-rtp(audio) stats tick with `packetsReceived > 0`. What the JS
  /// SDK calls "first audio". A packet arrived; nothing says it was played.
  static const firstAudioPacket = 'firstAudioPacket';

  /// See [kGravixFirstAudioDefinition].
  static const firstAudioPlayoutProxy = 'firstAudioPlayoutProxy';
  static const connectReturned = 'connectReturned';
  static const emittedAt = 'emittedAt';

  /// JSON order. Also the complete list: a step not named here is not reported.
  static const all = <String>[
    tapAt, tokenRequestStart, tokenRequestEnd, connectStart, regionProbeStart, regionProbeEnd, //
    audioSessionStart, audioSessionEnd, micPermissionStart, micPermissionEnd,
    wsConnectStart, wsOpen, joinResponse, pcSetupDone, iceConnected, pcConnected,
    firstAudioSubscribed, firstAudioPacket, firstAudioPlayoutProxy, connectReturned, emittedAt,
  ];

  /// Steps that belong to ONE connection attempt. A connect ladder that falls to
  /// its second url must not report the first url's WebSocket time next to the
  /// second url's ICE time.
  static const perAttempt = <String>[wsConnectStart, wsOpen, joinResponse, pcSetupDone, iceConnected, pcConnected];
}

/// The honest definition of "first audio played", carried in every report so a
/// number is never quoted without it.
///
/// WebRTC exposes no "a sample reached the speaker" callback to an app. The
/// closest observable is the inbound-rtp audio stats: `jitterBufferEmittedCount`
/// counts DECODED samples that came out of the jitter buffer towards playout.
/// The first stats tick where it is non-zero is therefore a PROXY for "audio is
/// being rendered": it is later than the first packet (the jitter buffer's
/// initial delay sits in between) and earlier than the speaker by the device's
/// output latency, which no stats field reports. Resolution is the poll interval
/// (`firstAudioPollMs`) plus libwebrtc's 50 ms stats cache.
///
/// `totalSamplesReceived` alone is NOT enough, and the first phone run showed
/// why: it includes CONCEALED samples (2201117TG, 2026-09-19: a first hit with
/// `totalSamplesReceived: 4320, concealedSamples: 1744`). Playout starts pulling
/// before the first packet is decodable and NetEq fills the gap with
/// concealment, so "totalSamplesReceived > 0" can be true while the user has
/// heard nothing real. It is used only where `jitterBufferEmittedCount` does not
/// exist, and then net of `concealedSamples`.
const String kGravixFirstAudioDefinition =
    'proxy:first inbound-rtp(audio) stats tick with jitterBufferEmittedCount>0 '
    '(without that field: totalSamplesReceived-concealedSamples>0); not a render callback';

/// This package's version, for the report. Kept in step with pubspec.yaml by
/// `test/connect/join_timeline_test.dart`, because a Dart package cannot read
/// its own pubspec at runtime.
const String kGravixSdkVersion = '0.4.2';

/// Default stats poll while waiting for first audio. 50 ms keeps the proxy's
/// resolution well under the ~100 ms differences the phone runs need to
/// resolve; it runs only while a timeline is being recorded and stops at first
/// audio, the 30 s timeout or disconnect, so its cost is bounded per join.
const Duration kGravixFirstAudioPoll = Duration(milliseconds: 50);

/// Something the app did BEFORE asking for a token — its own backend's
/// "may this user enter?" call, a Parse query, a payment check. The SDK cannot
/// see these; the app reports them so they show up in the same timeline as the
/// steps the SDK owns, instead of being silently charged to "the SDK is slow".
@immutable
class GravixAppSpan {
  const GravixAppSpan({required this.name, required this.start, required this.end});
  final String name;
  final DateTime start;
  final DateTime end;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'start': _iso(start),
    'end': _iso(end),
    'ms': end.difference(start).inMilliseconds,
  };
}

/// What the app knows that the SDK cannot. Passing one (even an empty one) to
/// `connect(joinTimeline: …)` is what turns the timeline on.
@immutable
class GravixJoinTimelineInput {
  const GravixJoinTimelineInput({
    this.tapAt,
    this.appSpans = const <GravixAppSpan>[],
    this.tokenRequestStart,
    this.tokenRequestEnd,
    this.tokenFromCache,
    this.context = const <String, Object?>{},
    this.firstAudioPoll = kGravixFirstAudioPoll,
  });

  /// Wall clock at pointer-DOWN on the join control. Not `onPressed`: that fires
  /// on pointer-up after the gesture arena resolves, tens of ms later.
  final DateTime? tapAt;
  final List<GravixAppSpan> appSpans;

  /// For an app that fetches its own token. `connectWithTokenProvider` fills
  /// these in itself.
  final DateTime? tokenRequestStart;
  final DateTime? tokenRequestEnd;
  final bool? tokenFromCache;

  /// Copied verbatim into the report (`cold`, `run`, `network`, …). Must be
  /// JSON-encodable.
  final Map<String, Object?> context;
  final Duration firstAudioPoll;

  GravixJoinTimelineInput copyWith({DateTime? tokenRequestStart, DateTime? tokenRequestEnd, bool? tokenFromCache}) =>
      GravixJoinTimelineInput(
        tapAt: tapAt,
        appSpans: appSpans,
        tokenRequestStart: tokenRequestStart ?? this.tokenRequestStart,
        tokenRequestEnd: tokenRequestEnd ?? this.tokenRequestEnd,
        tokenFromCache: tokenFromCache ?? this.tokenFromCache,
        context: context,
        firstAudioPoll: firstAudioPoll,
      );
}

/// One getStats() entry, reduced to what the walkers below read. A record and
/// not flutter_webrtc's `StatsReport` so the walkers are pure and a test can
/// feed them a literal. [timestampUs] is the report's own capture time (µs since
/// the epoch on Android/iOS), null when the platform gives none.
typedef GravixStat = ({String id, String type, double? timestampUs, Map<dynamic, dynamic> values});

/// How old a stats snapshot already was when Dart received it.
///
/// Measured on the phone: a getStats() round trip over the platform channel
/// takes 6-12 ms when idle and 70-230 ms while a connection is being set up,
/// which is exactly when the timeline needs it. Stamping a mark with the time
/// the answer ARRIVED would book that latency as join time; the snapshot says
/// when it was TAKEN, so marks are moved back by this much. Clamped to
/// [0, [max]]: a clock step or a platform that reports another unit must not be
/// able to move a mark by minutes.
Duration gravixStatsStaleness(Iterable<GravixStat> stats, DateTime now, {Duration max = const Duration(seconds: 1)}) {
  double? newest;
  for (final s in stats) {
    final t = s.timestampUs;
    if (t != null && (newest == null || t > newest)) newest = t;
  }
  if (newest == null) return Duration.zero;
  // Web reports milliseconds; anything this small cannot be µs since 1970.
  final us = newest < 1e14 ? newest * 1000 : newest;
  final stale = now.microsecondsSinceEpoch - us.round();
  if (stale <= 0) return Duration.zero;
  return stale > max.inMicroseconds ? max : Duration(microseconds: stale);
}

/// ICE / DTLS state of the primary transport in one stats snapshot.
///
/// `iceUp` prefers `transport.iceState`; a stack without that field falls back
/// to "some candidate pair has succeeded", which is what ICE-connected means.
({bool iceUp, bool dtlsUp, bool known}) gravixConnectivityFrom(Iterable<GravixStat> stats) {
  String? iceState, dtlsState;
  var pairSucceeded = false;
  var sawTransport = false;
  for (final s in stats) {
    if (s.type == 'transport') {
      sawTransport = true;
      final ice = s.values['iceState'];
      if (ice is String) iceState = ice;
      final dtls = s.values['dtlsState'];
      if (dtls is String) dtlsState = dtls;
    } else if (s.type == 'candidate-pair' && s.values['state'] == 'succeeded') {
      pairSucceeded = true;
    }
  }
  final iceUp = iceState != null ? (iceState == 'connected' || iceState == 'completed') : pairSucceeded;
  return (iceUp: iceUp, dtlsUp: dtlsState == 'connected', known: sawTransport || pairSucceeded);
}

/// The selected ICE candidate pair, classified.
@immutable
class GravixSelectedPair {
  const GravixSelectedPair({
    required this.localType,
    required this.remoteType,
    required this.protocol,
    this.relayProtocol,
  });

  /// `host` | `srflx` | `prflx` | `relay` (local candidate).
  final String localType;
  final String remoteType;

  /// `udp` | `tcp` — the pair's transport as the LOCAL candidate reports it.
  /// For a relay candidate this is the relay→peer leg, which is always udp; the
  /// leg that matters to the user is [relayProtocol].
  final String protocol;

  /// Relay candidates only: how the client reaches the TURN server —
  /// `udp` | `tcp` | `tls`.
  final String? relayProtocol;

  bool get isRelay => localType == 'relay' || remoteType == 'relay';

  /// `udp` | `tcp` | `turn-udp` | `turn-tcp` | `turn-tls`.
  String get transport => isRelay ? 'turn-${relayProtocol ?? protocol}' : protocol;

  /// Anything other than plain UDP. ICE-TCP and TURN both mean direct UDP to the
  /// SFU did not work (blocked port, symmetric NAT, captive network); the join
  /// still succeeds, but later and with a worse path, and nothing else in the
  /// SDK says so.
  bool get isFallback => transport != 'udp';

  Map<String, Object?> toJson() => <String, Object?>{
    'localType': localType,
    'remoteType': remoteType,
    'protocol': protocol,
    'relayProtocol': relayProtocol,
    'transport': transport,
  };
}

/// Walks a stats list to the selected candidate pair and the DTLS state.
///
/// The same walk as the core's `getConnectedAddress` (rtc_core engine.dart):
/// `transport.selectedCandidatePairId`, falling back to the `candidate-pair`
/// marked `selected` for stacks that do not fill the transport stat — but it
/// keeps the candidate TYPES and protocols instead of only the remote address.
/// A sibling rather than an edit because `rtc_core/` is vendored and re-synced.
({GravixSelectedPair? pair, String? dtlsState}) gravixSelectedPairFrom(Iterable<GravixStat> stats) {
  String? selectedId;
  String? dtlsState;
  final pairs = <String, Map<dynamic, dynamic>>{};
  final candidates = <String, Map<dynamic, dynamic>>{};
  String? flaggedSelected;
  for (final s in stats) {
    switch (s.type) {
      case 'transport':
        final id = s.values['selectedCandidatePairId'];
        if (id is String && id.isNotEmpty) selectedId = id;
        final dtls = s.values['dtlsState'];
        if (dtls is String) dtlsState = dtls;
      case 'candidate-pair':
        pairs[s.id] = s.values;
        if (s.values['selected'] == true) flaggedSelected ??= s.id;
      case 'local-candidate' || 'remote-candidate':
        candidates[s.id] = s.values;
    }
  }
  final pair = pairs[selectedId ?? flaggedSelected];
  if (pair == null) return (pair: null, dtlsState: dtlsState);
  final local = candidates[pair['localCandidateId']];
  final remote = candidates[pair['remoteCandidateId']];
  if (local == null) return (pair: null, dtlsState: dtlsState);
  String text(Object? v, String fallback) => v is String && v.isNotEmpty ? v.toLowerCase() : fallback;
  final relayProtocol = local['relayProtocol'];
  return (
    pair: GravixSelectedPair(
      localType: text(local['candidateType'], 'unknown'),
      remoteType: text(remote?['candidateType'], 'unknown'),
      protocol: text(local['protocol'], 'unknown'),
      relayProtocol: relayProtocol is String && relayProtocol.isNotEmpty ? relayProtocol.toLowerCase() : null,
    ),
    dtlsState: dtlsState,
  );
}

bool _isInboundAudio(GravixStat s) =>
    s.type == 'inbound-rtp' && (s.values['kind'] == 'audio' || s.values['mediaType'] == 'audio');

bool _positive(Object? v) => v is num && v > 0;

/// An inbound audio RTP packet has arrived (the JS SDK's first-audio test).
bool gravixHasInboundAudioPacket(Iterable<GravixStat> stats) =>
    stats.any((s) => _isInboundAudio(s) && _positive(s.values['packetsReceived']));

/// Samples have left the jitter buffer — see [kGravixFirstAudioDefinition].
bool gravixHasPlayedAudio(Iterable<GravixStat> stats) => stats.any((s) => _isInboundAudio(s) && _playedRealAudio(s));

bool _playedRealAudio(GravixStat s) {
  final emitted = s.values['jitterBufferEmittedCount'];
  if (emitted is num) return emitted > 0;
  final total = s.values['totalSamplesReceived'];
  final concealed = s.values['concealedSamples'];
  return total is num && total - (concealed is num ? concealed : 0) > 0;
}

/// The counters behind a playout-proxy hit, copied into the report so the number
/// can be checked: e.g. `totalSamplesReceived: 2400` at 48 kHz says playout had
/// already been running for 50 ms when this snapshot was taken.
Map<String, Object?> gravixInboundAudioEvidence(Iterable<GravixStat> stats, Duration staleBy) {
  for (final s in stats) {
    if (!_isInboundAudio(s) || !_playedRealAudio(s)) continue;
    return <String, Object?>{
      // packetsLost / packetsDiscarded: what did not survive to playout BEFORE the
      // first sample - the numbers that say whether answering early (fastAnswer)
      // made the first packets arrive somewhere that could not take them.
      for (final k in const [
        'packetsReceived', 'packetsLost', 'packetsDiscarded', 'totalSamplesReceived', 'concealedSamples', //
        'jitterBufferEmittedCount', 'jitterBufferDelay',
      ])
        k: s.values[k],
      'snapshotStaleMs': staleBy.inMilliseconds,
    };
  }
  return const <String, Object?>{};
}

/// `audio=<m=audio sections>/<of which the server is SENDING>` for an SDP offer.
/// Says which offer first carried the audio the join is waiting for, without
/// putting an SDP in a report.
String gravixOfferAudioSummary(String? sdp) {
  if (sdp == null) return 'audio=?';
  var sections = 0, sending = 0;
  for (final section in sdp.split(RegExp(r'\r?\nm='))..removeAt(0)) {
    if (!section.startsWith('audio')) continue;
    sections++;
    if (section.contains('a=sendonly') || section.contains('a=sendrecv')) sending++;
  }
  return 'audio=$sections/$sending';
}

/// [url] as it may appear in a report: scheme, host, port and path only. A
/// signalling url can carry a token or a key in its query string (some
/// deployments put one there) or credentials in its userinfo, and a timeline is
/// written to the device log.
String? gravixUrlWithoutSecrets(String? url) {
  if (url == null) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority) return url.split('?').first.split('#').first;
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: uri.path).toString();
}

String _iso(DateTime t) => t.toUtc().toIso8601String();

/// Why the report was emitted when it was.
enum GravixJoinTimelineEnd { firstAudio, timeout, disconnect }

/// Collects marks for one join. Pure: no timers, no plugins — the service drives
/// it, a test can drive it with a fake clock.
class GravixJoinTimelineRecorder {
  GravixJoinTimelineRecorder({
    required this.connectionId,
    this.input = const GravixJoinTimelineInput(),
    DateTime Function()? wallClock,
    Duration Function()? monotonic,
  }) : _wall = wallClock ?? DateTime.now,
       _mono = monotonic ?? _defaultMonotonic() {
    final i = input;
    if (i.tapAt != null) _wallAt[GravixJoinStep.tapAt] = i.tapAt!;
    if (i.tokenRequestStart != null) _wallAt[GravixJoinStep.tokenRequestStart] = i.tokenRequestStart!;
    if (i.tokenRequestEnd != null) _wallAt[GravixJoinStep.tokenRequestEnd] = i.tokenRequestEnd!;
  }

  static Duration Function() _defaultMonotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final String connectionId;
  final GravixJoinTimelineInput input;
  final DateTime Function() _wall;
  final Duration Function() _mono;

  final Map<String, DateTime> _wallAt = <String, DateTime>{};
  // Only for marks the SDK itself observed. App-supplied times (tapAt, token
  // times from the app) have a wall clock only, and any delta touching one is
  // computed on the wall clock — stated in the docs, because a wall clock can
  // step (NTP) and a monotonic one cannot.
  final Map<String, Duration> _monoAt = <String, Duration>{};

  bool? regionFromCache;
  bool regionProbeEnabled = false;
  String? connectedUrl;
  GravixSelectedPair? pair;
  String? dtlsState;
  int attempts = 0;

  bool has(String step) => _wallAt.containsKey(step);

  /// First write wins: `firstAudioSubscribed` means the FIRST subscription, and
  /// an event that fires twice must not move a mark.
  ///
  /// [staleBy]: the observation is already this old (a stats snapshot, see
  /// [gravixStatsStaleness]); the mark is placed when it was true, not when the
  /// SDK heard about it.
  void mark(String step, {Duration staleBy = Duration.zero}) {
    if (_wallAt.containsKey(step)) return;
    _wallAt[step] = _wall().subtract(staleBy);
    _monoAt[step] = _mono() - staleBy;
  }

  // ── What the stats polls saw. Evidence, so a number can be checked. ────────

  /// Round-trip time of every getStats() call this timeline made.
  final List<int> statsCallMs = <int>[];

  /// The last snapshot in which ICE was NOT yet connected, and the first in
  /// which it was (with whether DTLS was already up in that same snapshot).
  DateTime? iceLastSeenDown;
  DateTime? iceFirstSeenUp;

  /// Snapshots taken while looking for the boundary. With [iceLastSeenDown] and
  /// [iceFirstSeenUp] this is the REAL resolution of `ms.ice`/`ms.dtls` for this
  /// join - on a busy phone (and in a debug build) the 50 ms poll does not get to
  /// run every 50 ms.
  int icePolls = 0;
  bool? dtlsUpWhenIceFirstSeenUp;

  /// The inbound-audio counters in the snapshot that satisfied the playout proxy.
  Map<String, Object?>? firstAudioEvidence;

  /// Every SDP offer the server sent, ms after connectStart. A track that was
  /// not in the first offer costs a whole extra offer/answer round before its
  /// first packet, and nothing else in the timeline shows that.
  final List<int> offersMs = <int>[];

  void noteOffer() {
    final start = _monoAt[GravixJoinStep.connectStart];
    if (start != null) offersMs.add((_mono() - start).inMilliseconds);
  }

  /// The subscriber path, event by event, ms after connectStart (monotonic).
  ///
  /// Why: on a phone the stretch from "peer connection connected" to "first
  /// audio packet" was ~500 ms on a 5 ms-RTT LAN - a delay that does not scale
  /// with RTT is a timer, a debounce, a serialised await or a second negotiation,
  /// i.e. the removable kind. The named marks cannot say which; this can:
  ///   offerArrived n      the WebSocket delivered SDP offer n
  ///   offerHandlerStart n the engine STARTED handling it (its signal handlers run
  ///                       one at a time, so this can be much later than arrival)
  ///   signalingStateRead / setRemoteDescriptionDone / createAnswerDone /
  ///   setLocalDescriptionDone / answerSent   (each a platform-channel round trip)
  ///   onTrack, trackAdded, participantUpdate, trackPublished, trackSubscribed
  /// `d` carries a detail (offer: `audio=<m-lines>/<sending>`; onTrack: kind and
  /// the connection states that decide whether the core defers it).
  final List<Map<String, Object?>> subscriberPath = <Map<String, Object?>>[];
  int _offersArrived = 0;
  int _offersHandled = 0;

  /// Bounded: a long-lived room keeps renegotiating, the timeline is about the
  /// join. Nothing is recorded once the report is out or past this many events.
  static const int _maxPathEvents = 60;

  void notePath(String event, {Object? detail}) {
    final start = _monoAt[GravixJoinStep.connectStart];
    if (start == null || subscriberPath.length >= _maxPathEvents) return;
    int? n;
    if (event == 'offerArrived') n = ++_offersArrived;
    if (event == 'offerHandlerStart') n = ++_offersHandled;
    if (const {
      'signalingStateRead',
      'setRemoteDescriptionDone',
      'createAnswerDone',
      'setLocalDescriptionDone',
      'answerSent',
    }.contains(event)) {
      n = _offersHandled;
    }
    subscriberPath.add(<String, Object?>{'e': event, 'ms': (_mono() - start).inMilliseconds, 'n': ?n, 'd': ?detail});
  }

  /// First inbound audio packet, estimated from the receiver's own clock instead
  /// of from when a 50 ms poll noticed it: `lastPacketReceivedTimestamp` of the
  /// first snapshot with packets, minus 20 ms per earlier packet (Opus ptime; an
  /// ESTIMATE when the sender uses another ptime). ms after connectStart.
  Map<String, Object?>? firstPacketEstimate;

  void noteFirstPacket(Iterable<GravixStat> stats) {
    if (firstPacketEstimate != null) return;
    final startWall = _wallAt[GravixJoinStep.connectStart];
    if (startWall == null) return;
    for (final s in stats) {
      if (!_isInboundAudio(s) || !_positive(s.values['packetsReceived'])) continue;
      final last = s.values['lastPacketReceivedTimestamp'];
      final packets = s.values['packetsReceived'] as num;
      if (last is! num) return;
      final firstAtMs = last - (packets - 1) * 20;
      firstPacketEstimate = <String, Object?>{
        'ms': (firstAtMs - startWall.microsecondsSinceEpoch / 1000).round(),
        'packetsReceived': packets,
        'assumedPtimeMs': 20,
      };
      return;
    }
  }

  /// A new connection attempt (connect ladder): forget the previous attempt's
  /// transport marks so the report describes the attempt that succeeded.
  void beginAttempt() {
    attempts++;
    for (final step in GravixJoinStep.perAttempt) {
      _wallAt.remove(step);
      _monoAt.remove(step);
    }
    pair = null;
    dtlsState = null;
    iceLastSeenDown = null;
    iceFirstSeenUp = null;
    dtlsUpWhenIceFirstSeenUp = null;
    icePolls = 0;
    offersMs.clear();
    // Per ATTEMPT, like the marks above - except the service's own per-join
    // events, which happen once whatever the ladder does.
    subscriberPath.removeWhere((e) => !(e['e']! as String).startsWith('svc:early'));
    _offersArrived = 0;
    _offersHandled = 0;
    firstPacketEstimate = null;
  }

  int? _delta(String from, String to) {
    final a = _wallAt[from], b = _wallAt[to];
    if (a == null || b == null) return null;
    final ma = _monoAt[from], mb = _monoAt[to];
    if (ma != null && mb != null) return (mb - ma).inMilliseconds;
    return b.difference(a).inMilliseconds;
  }

  GravixJoinTimeline build(GravixJoinTimelineEnd endReason, {String sdkVersion = ''}) {
    mark(GravixJoinStep.emittedAt);
    const s = GravixJoinStep.tapAt; // keeps the table below readable
    return GravixJoinTimeline._(
      connectionId: connectionId,
      sdkVersion: sdkVersion,
      t: <String, DateTime?>{for (final step in GravixJoinStep.all) step: _wallAt[step]},
      ms: <String, int?>{
        'tapToConnectStart': _delta(s, GravixJoinStep.connectStart),
        'token': _delta(GravixJoinStep.tokenRequestStart, GravixJoinStep.tokenRequestEnd),
        'regionProbe': _delta(GravixJoinStep.regionProbeStart, GravixJoinStep.regionProbeEnd),
        'audioSession': _delta(GravixJoinStep.audioSessionStart, GravixJoinStep.audioSessionEnd),
        'micPermission': _delta(GravixJoinStep.micPermissionStart, GravixJoinStep.micPermissionEnd),
        'wsOpen': _delta(GravixJoinStep.wsConnectStart, GravixJoinStep.wsOpen),
        'joinResponse': _delta(GravixJoinStep.wsOpen, GravixJoinStep.joinResponse),
        'pcSetup': _delta(GravixJoinStep.joinResponse, GravixJoinStep.pcSetupDone),
        'ice': _delta(GravixJoinStep.joinResponse, GravixJoinStep.iceConnected),
        'dtls': _delta(GravixJoinStep.iceConnected, GravixJoinStep.pcConnected),
        // Always available, whether or not the ICE/DTLS boundary was resolved.
        'iceAndDtls': _delta(GravixJoinStep.joinResponse, GravixJoinStep.pcConnected),
        'pcToFirstAudioPlayoutProxy': _delta(GravixJoinStep.pcConnected, GravixJoinStep.firstAudioPlayoutProxy),
        'connectStartToFirstAudioPlayoutProxy': _delta(
          GravixJoinStep.connectStart,
          GravixJoinStep.firstAudioPlayoutProxy,
        ),
        'tapToFirstAudioSubscribed': _delta(s, GravixJoinStep.firstAudioSubscribed),
        'tapToFirstAudioPacket': _delta(s, GravixJoinStep.firstAudioPacket),
        'tapToFirstAudioPlayoutProxy': _delta(s, GravixJoinStep.firstAudioPlayoutProxy),
      },
      appSpans: input.appSpans,
      tokenFromCache: input.tokenFromCache,
      regionFromCache: regionFromCache,
      regionProbeEnabled: regionProbeEnabled,
      connectedUrl: connectedUrl,
      attempts: attempts,
      pair: pair,
      dtlsState: dtlsState,
      firstAudioPollMs: input.firstAudioPoll.inMilliseconds,
      ice: <String, Object?>{
        'source': 'getStats transport.iceState (not the legacy callback)',
        'lastSeenDown': iceLastSeenDown == null ? null : _iso(iceLastSeenDown!),
        'firstSeenUp': iceFirstSeenUp == null ? null : _iso(iceFirstSeenUp!),
        'dtlsAlreadyUpThen': dtlsUpWhenIceFirstSeenUp,
        'polls': icePolls,
        'resolved': _wallAt.containsKey(GravixJoinStep.iceConnected),
      },
      stats: <String, Object?>{
        'calls': statsCallMs.length,
        'p50Ms': statsCallMs.isEmpty ? null : (List<int>.of(statsCallMs)..sort())[statsCallMs.length ~/ 2],
        'maxMs': statsCallMs.isEmpty ? null : statsCallMs.reduce((a, b) => a > b ? a : b),
      },
      firstAudioEvidence: firstAudioEvidence,
      offersMs: List<int>.unmodifiable(offersMs),
      subscriberPath: List<Map<String, Object?>>.unmodifiable(subscriberPath),
      firstPacketEstimate: firstPacketEstimate,
      endReason: endReason,
      complete: _wallAt.containsKey(GravixJoinStep.firstAudioPlayoutProxy),
      context: input.context,
    );
  }
}

/// One join, step by step. Emitted once per `connect(joinTimeline: …)`.
@immutable
class GravixJoinTimeline {
  const GravixJoinTimeline._({
    required this.connectionId,
    required this.sdkVersion,
    required this.t,
    required this.ms,
    required this.appSpans,
    required this.tokenFromCache,
    required this.regionFromCache,
    required this.regionProbeEnabled,
    required this.connectedUrl,
    required this.attempts,
    required this.pair,
    required this.dtlsState,
    required this.firstAudioPollMs,
    required this.ice,
    required this.stats,
    required this.firstAudioEvidence,
    required this.offersMs,
    required this.subscriberPath,
    required this.firstPacketEstimate,
    required this.endReason,
    required this.complete,
    required this.context,
  });

  static const int schema = 1;
  final String connectionId;
  final String sdkVersion;

  /// Absolute wall-clock time of every step; null when the step did not happen.
  final Map<String, DateTime?> t;

  /// Deltas in ms; null when either end is missing.
  final Map<String, int?> ms;
  final List<GravixAppSpan> appSpans;
  final bool? tokenFromCache;
  final bool? regionFromCache;
  final bool regionProbeEnabled;
  final String? connectedUrl;

  /// Connection attempts this join took (> 1 = the connect ladder was used).
  final int attempts;
  final GravixSelectedPair? pair;

  /// `transport.dtlsState` read when the primary peer connection reported
  /// connected. `connected` is the expected value; anything else at that moment
  /// is worth a look.
  final String? dtlsState;
  final int firstAudioPollMs;

  /// How `iceConnected` was (or was not) resolved: the last stats snapshot with
  /// ICE down, the first with ICE up, and whether DTLS was already up in it.
  /// When `resolved` is false, ICE and DTLS both completed between those two
  /// snapshots and `ms.ice` / `ms.dtls` are null rather than guessed;
  /// `joinResponse -> pcConnected` (`ms.iceAndDtls`) is still exact.
  final Map<String, Object?> ice;

  /// getStats() calls made for this timeline and what they cost (round trip).
  final Map<String, Object?> stats;

  /// The inbound-rtp counters that satisfied the playout proxy.
  final Map<String, Object?>? firstAudioEvidence;

  /// SDP offers received, ms after connectStart.
  final List<int> offersMs;

  /// See [GravixJoinTimelineRecorder.subscriberPath]. `pcConnected` and the other
  /// named marks are in the same clock: `t.connectStart` + `ms`.
  final List<Map<String, Object?>> subscriberPath;

  /// See [GravixJoinTimelineRecorder.firstPacketEstimate].
  final Map<String, Object?>? firstPacketEstimate;
  final GravixJoinTimelineEnd endReason;

  /// True when the playout proxy was observed. False = timeout/disconnect first.
  final bool complete;
  final Map<String, Object?> context;

  /// The pair is TCP or TURN: direct UDP to the SFU did not work for this join.
  bool get fallbackDetected => pair?.isFallback ?? false;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': schema,
    'sdk': 'flutter',
    'sdkVersion': sdkVersion,
    'connectionId': connectionId,
    't': <String, Object?>{for (final e in t.entries) e.key: e.value == null ? null : _iso(e.value!)},
    'appSpans': [for (final s in appSpans) s.toJson()],
    'ms': ms,
    'tokenFromCache': tokenFromCache,
    'regionFromCache': regionFromCache,
    'regionProbeEnabled': regionProbeEnabled,
    'connectedUrl': gravixUrlWithoutSecrets(connectedUrl),
    'attempts': attempts,
    'pair': pair?.toJson(),
    'fallbackDetected': fallbackDetected,
    'dtlsState': dtlsState,
    'firstAudioDefinition': kGravixFirstAudioDefinition,
    'firstAudioPollMs': firstAudioPollMs,
    'ice': ice,
    'stats': stats,
    'firstAudioEvidence': firstAudioEvidence,
    'offersMs': offersMs,
    'subscriberPath': subscriberPath,
    'firstPacketEstimate': firstPacketEstimate,
    'complete': complete,
    'endReason': endReason.name,
    'context': context,
  };

  /// One line, for a log.
  String toJsonLine() => jsonEncode(toJson());

  @override
  String toString() => 'GravixJoinTimeline(${toJsonLine()})';
}
