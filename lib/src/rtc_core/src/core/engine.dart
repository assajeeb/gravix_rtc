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
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;

import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:meta/meta.dart';

import '../e2ee/e2ee_manager.dart';
import '../e2ee/options.dart';
import '../events.dart';
import '../exceptions.dart';
import '../extensions.dart';
import '../internal/events.dart';
import '../internal/types.dart';
import '../logger.dart' show logger;
import '../managers/event.dart';
import '../options.dart';
import '../proto/gravixcloud_models.pb.dart' as lk_models;
import '../proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import '../publication/local.dart';
import '../support/disposable.dart';
import '../support/http_client.dart' show sdkHttpHead;
import '../support/platform.dart' show lkPlatformIsTest, lkPlatformIs, PlatformType;
import '../support/region_url_provider.dart';
import '../support/websocket.dart';
import '../track/local/local.dart';
import '../track/local/video.dart';
import '../types/internal.dart';
import '../types/other.dart';
import '../utils/data_packet_buffer.dart';
import '../utils/ttl_map.dart';
import '../../../connect/gravix_answer_order.dart'; // GRAVIX: subscriber answer ordering (fastAnswer)
import '../../../connect/gravix_viewer_fast_start.dart'; // GRAVIX: viewer fast start (passive subscriber DTLS)
import 'add_track_rejection.dart';
import 'reconnect_policy.dart';
import 'signal_client.dart';
import 'gravix_ice_transport.dart';
import 'gravix_pub_log.dart';
import 'transport.dart';

// GRAVIX (2026-09-27): the retry delay table moved to DefaultReconnectPolicy
// (reconnect_policy.dart); RoomOptions.reconnectPolicy replaces it.

/// GRAVIX: chooses the region for a full reconnect. See
/// `GravixProbeRestartStrategy` for the probe-backed implementation.
abstract interface class GravixRestartRegionStrategy {
  /// The url a full reconnect should join, or null to keep the current one.
  Future<String?> getRestartUrl();

  /// The next url to try after the restart url refused, or null when done.
  Future<String?> getNextUrl();
}

/// GRAVIX (2026-10-11, resumeSatisfiesPeerFailure / resumePeerRestartWait): what a
/// successful resume does with a full-reconnect request made while it ran.
enum _GravixPcFailureVerdict { dispatch, satisfied, waitForOther, publisherWatch }

class Engine extends Disposable with EventsEmittable<EngineEvent> {
  static const _lossyDCLabel = '_lossy';
  static const _reliableDCLabel = '_reliable';
  @internal
  final SignalClient signalClient;

  final PeerConnectionCreate _peerConnectionCreate;

  @internal
  Transport? publisher;

  @internal
  Transport? subscriber;

  @internal
  Transport? get primary => _subscriberPrimary ? subscriber : publisher;

  rtc.RTCDataChannel? get dataChannel =>
      _subscriberPrimary ? _reliableDCSub ?? _lossyDCSub : _reliableDCPub ?? _lossyDCPub;

  // data channels for packets
  rtc.RTCDataChannel? _reliableDCPub;
  rtc.RTCDataChannel? _lossyDCPub;
  rtc.RTCDataChannel? _reliableDCSub;
  rtc.RTCDataChannel? _lossyDCSub;

  /// Connection state of the [Room].
  ConnectionState get connectionState => signalClient.connectionState;

  // true if publisher connection has already been established.
  // this is helpful to know if we need to restart ICE on the publisher connection
  bool _hasPublished = false;

  lk_models.ClientConfiguration? _clientConfiguration;

  // remember url and token for reconnect
  String? url;
  String? token;

  ConnectOptions connectOptions;
  RoomOptions roomOptions;
  FastConnectOptions? fastConnectOptions;

  bool _subscriberPrimary = false;

  String? _connectedServerAddress;
  String? get connectedServerAddress => _connectedServerAddress;

  /// A full-reconnect request. With
  /// [GravixRecoveryOptions.upstreamReconnectFixes] (upstream 2.13.0, #1199) it
  /// is the PENDING request: consumed when an attempt starts, so a true value
  /// while an attempt runs is a new request, dispatched when it ends. Use
  /// [gravixFullReconnectInProgress] to ask what the running attempt does.
  bool get fullReconnectOnNext => _fullReconnectOnNext;
  set fullReconnectOnNext(bool value) {
    // GRAVIX (0.4.15, F4): remember which peer connections the request was made
    // against (see the dispatch in attemptReconnect)
    if (value) _fullRequestTransportGen = _gravixTransportGen;
    // GRAVIX (2026-10-11, resumeSatisfiesPeerFailure): and how many times a peer
    // connection had come up by then. Any request counts as not made by a peer
    // connection failure; handleReconnect marks those itself, right after.
    if (value) _fullRequestPcUpSeq = _gravixPcUpSeq;
    _fullRequestPcFailuresOnly = false;
    _fullReconnectOnNext = value;
  }

  bool _fullReconnectOnNext = false;

  /// GRAVIX (2026-10-11, resumeSatisfiesPeerFailure): bumped every time a peer
  /// connection reports Connected (a join, a resume's ICE restart).
  int _gravixPcUpSeq = 0;

  /// The [_gravixPcUpSeq] of the latest full-reconnect request.
  int _fullRequestPcUpSeq = 0;

  /// Whether the pending full-reconnect request was made only by peer
  /// connections reporting Failed (no Leave, negotiation failure, config, ...).
  bool _fullRequestPcFailuresOnly = false;

  /// GRAVIX (0.4.15, F4): bumped every time a new pair of peer connections is
  /// created (a join, a full reconnect).
  int _gravixTransportGen = 0;

  /// The [_gravixTransportGen] of the latest full-reconnect request.
  int _fullRequestTransportGen = 0;

  /// GRAVIX (0.4.15, F4): bumped when a full reconnect starts replacing the
  /// session. Work started on the previous session (a republish waiting for its
  /// TrackPublished) checks it, and [addTrack] stops waiting at once.
  @internal
  int get gravixRestartGen => _gravixRestartGen;
  int _gravixRestartGen = 0;
  Completer<void> _gravixRestartSignal = Completer<void>();

  void _gravixSessionReplaced() {
    _gravixRestartGen++;
    final old = _gravixRestartSignal;
    _gravixRestartSignal = Completer<void>();
    if (!old.isCompleted) old.complete();
  }

  bool _attemptIsFullReconnect = false;

  /// GRAVIX: whether the session is being re-joined (a full reconnect running,
  /// or one pending). With the upstream fixes off this is [fullReconnectOnNext]
  /// alone, exactly what the room read before.
  @internal
  bool get gravixFullReconnectInProgress =>
      _upstreamReconnectFixes ? (_attemptIsFullReconnect || fullReconnectOnNext) : fullReconnectOnNext;

  bool get _upstreamReconnectFixes => roomOptions.recovery.upstreamReconnectFixes;

  // server-provided ice servers
  List<RTCIceServer> _serverProvidedIceServers = [];

  late EventsListener<SignalEvent> _signalListener = signalClient.createListener(synchronized: true);

  int _reconnectAttempts = 0;
  Timer? _reconnectTimeout;
  DateTime? _reconnectStart;

  bool _isClosed = false;

  bool get isClosed => _isClosed;

  bool get isPendingReconnect => _reconnectStart != null && _reconnectTimeout != null;

  /// GRAVIX (0.4.15, OBS-1): a reconnect (resume or full) is under way, from
  /// [handleReconnect] until it succeeds or the session ends -- including the
  /// attempt's own dial, when the signal client reads `disconnected` (its
  /// cleanUp) and [isPendingReconnect] is false (no timer is pending then).
  @internal
  bool get gravixReconnectInProgress => _reconnectStart != null || _attemptingReconnect || _isReconnecting;

  /// GRAVIX: the back-off in use; see [RoomOptions.reconnectPolicy].
  ReconnectPolicy get reconnectPolicy => roomOptions.reconnectPolicy ?? _defaultReconnectPolicy;
  static final _defaultReconnectPolicy = DefaultReconnectPolicy();

  bool _attemptingReconnect = false;

  /// GRAVIX (2026-10-21): the url the next full restart dials, once ([gravixRestartTo]).
  String? _gravixRestartUrl;

  RegionUrlProvider? _regionUrlProvider;

  /// GRAVIX: where a FULL reconnect goes (`regionReprobeOnRestart`). Consulted
  /// before the upstream [RegionUrlProvider], which the Gravix server cannot
  /// feed (it serves no `/regions`). Null keeps the upstream behaviour exactly.
  GravixRestartRegionStrategy? restartRegionStrategy;

  /// GRAVIX: observation hook for the join timeline. NOT upstream.
  ///
  /// The subscriber path between "peer connection connected" and "first audio
  /// packet" (offer received, setRemoteDescription, createAnswer,
  /// setLocalDescription, answer sent, onTrack) emits no event an observer could
  /// subscribe to, and on a phone that stretch was the largest single step of a
  /// LAN join (~500 ms at ~5 ms RTT, 2026-09-20). This is called at each of those
  /// points with a step name and an optional detail. It changes nothing on the
  /// wire and nothing in the sequence: null (the default) is a no-op, and a
  /// throwing hook is swallowed so a metric can never break a join.
  void Function(String step, Object? detail)? gravixTimelineHook;

  /// GRAVIX: send the subscriber answer as soon as createAnswer returns instead
  /// of after setLocalDescription resolves. NOT upstream. Default false = the
  /// upstream order. See `gravixAnswerSubscriberOffer` for why and for the risk.
  bool gravixFastAnswer = false;

  /// GRAVIX(viewer-fast-start): the subscriber's configuration to re-apply (without
  /// the connect-time ping interval) once it is connected; null = nothing to restore.
  RTCConfiguration? _gravixConnectPingRestore;

  void _gravixMark(String step, [Object? detail]) {
    final hook = gravixTimelineHook;
    if (hook == null) return;
    try {
      hook(step, detail);
    } catch (_) {}
  }

  /// GRAVIX: consecutive resumes that failed for a reason upstream does not
  /// escalate on (a timeout, not a refused socket); see [attemptReconnect].
  int _unrecoveredResumes = 0;

  /// Resumes that failed without a refusal (a dial timeout, not a refused or
  /// dead socket) before the next attempt is a full reconnect. Two dial timeouts
  /// are ~20 s: past the server's disconnect grace (15 s).
  static const _unrecoveredResumesBeforeFull = 2;

  /// GRAVIX(resume-rejected, 2026-10-05): completed when the resume in flight
  /// can no longer succeed -- the server answered it with a Leave, or closed its
  /// socket before the ReconnectResponse. Upstream only learnt that from the
  /// 10 s ReconnectResponse timeout, and the Leave's own reconnect was dropped
  /// by the [attemptReconnect] guard while the resume was still waiting; field
  /// 2026-10-05: 3-4 resume attempts and 10-17 s of extra outage before the full
  /// rejoin, each time the server had already closed the participant.
  Completer<GravixResumeRejectedException>? _resumeAbort;

  /// GRAVIX(one-session): bumped by a fresh [connect] and by [disconnect]. A
  /// reconnect attempt that started under an older generation was cancelled by
  /// them and must not schedule another one.
  int _sessionGen = 0;

  /// GRAVIX(one-session): set while [restartConnection] runs its own [connect].
  bool _inRestart = false;

  /// GRAVIX (2026-10-11, restartAbortsOnSignalLoss): armed by [restartConnection]
  /// around its connect and its publisher wait; completed when that signal
  /// socket closes (see the SignalDisconnectedEvent handler).
  Completer<void>? _gravixRestartSignalLost;

  /// Whether the running attempt's full reconnect was failed that way.
  bool _gravixAttemptSignalLost = false;

  /// [wait], failed with [GravixRestartSignalLostException] as soon as the full
  /// reconnect's signal socket closes (no-op when nothing is armed).
  Future<T> _gravixUnlessSignalLost<T>(Future<T> wait, String what) {
    final lost = _gravixRestartSignalLost;
    if (lost == null) return wait;
    return Future.any<T>([wait, lost.future.then<T>((_) => throw GravixRestartSignalLostException(what))]);
  }

  /// Tests only: flutter test skips the full reconnect's wait for the publisher
  /// connection (upstream); true runs it.
  @visibleForTesting
  bool gravixPublisherWaitInTests = false;

  /// Whether a resume is in flight (between its dial and its ReconnectResponse).
  @visibleForTesting
  bool get gravixResumeInFlight => _resumeAbort != null && !_resumeAbort!.isCompleted;

  void _abortResume(GravixResumeRejectedException reason) {
    final c = _resumeAbort;
    if (c != null && !c.isCompleted) {
      logger.info('resume aborted: ${reason.message}');
      _gravixAbortReason = reason;
      c.complete(reason);
    }
  }

  /// GRAVIX (0.4.15): the ReconnectResponse of the resume in flight arrived (its
  /// abort, if still held, covers the wait for the primary connection).
  bool _resumeAnswered = false;
  GravixResumeRejectedException? _gravixAbortReason;

  /// Cancels a scheduled reconnect and any resume in flight: a fresh connect or a
  /// disconnect owns the session now.
  void _cancelReconnect(String why) {
    _sessionGen++;
    _clearPendingReconnect();
    _abortResume(GravixResumeRejectedException('cancelled: $why', full: false, cancelled: true));
    _isReconnecting = false;
  }

  lk_models.ServerInfo? _serverInfo;

  lk_models.ServerInfo? get serverInfo => _serverInfo;

  final Map<Reliability, bool> _dcBufferStatus = {Reliability.reliable: true, Reliability.lossy: false};

  List<lk_models.Codec>? _enabledPublishCodecs;

  List<lk_models.Codec>? get enabledPublishCodecs => _enabledPublishCodecs;

  E2EEManager? _e2eeManager;

  E2EEManager? get e2eeManager => _e2eeManager;

  void setE2eeManager(E2EEManager? e2eeManager) {
    _e2eeManager = e2eeManager;
  }

  // E2E reliability for data channels
  int _reliableDataSequence = 1;
  final DataPacketBuffer _reliableMessageBuffer = DataPacketBuffer(
    maxBufferSize: 64 * 1024 * 1024, // 64MB
    maxPacketCount: 1000, // max 1000 packets
  );
  final TTLMap<String, int> _reliableReceivedState = TTLMap<String, int>(30000);
  bool _isReconnecting = false;

  Completer<void>? _publisherConnectionCompleter;

  String? _reliableParticipantKey(lk_models.DataPacket packet) {
    if (packet.hasParticipantSid() && packet.participantSid.isNotEmpty) {
      return packet.participantSid;
    }
    logger.fine(
      'Reliable packet missing participant SID (identity: ${packet.participantIdentity}), skipping dedupe handling',
    );
    return null;
  }

  void _clearReconnectTimeout() {
    if (_reconnectTimeout != null) {
      _reconnectTimeout?.cancel();
      _reconnectTimeout = null;
    }
  }

  void _clearPendingReconnect() {
    _clearReconnectTimeout();
    _reconnectAttempts = 0;
    _reconnectStart = null;
  }

  Engine({
    required this.connectOptions,
    required this.roomOptions,
    SignalClient? signalClient,
    PeerConnectionCreate? peerConnectionCreate,
    E2EEManager? e2eeManager,
  }) : signalClient = signalClient ?? SignalClient(GravixRtcWebSocket.connect),
       _peerConnectionCreate = peerConnectionCreate ?? rtc.createPeerConnection,
       _e2eeManager = e2eeManager {
    if (kDebugMode) {
      // log all EngineEvents
      events.listen((event) => logger.fine('[EngineEvent] $objectId $event'));
    }

    _setUpEngineListeners();
    _setUpSignalListeners();
    // GRAVIX (0.4.15, F6): a real connectivity change (not a same-type repeat)
    _gravixNetListener.on<SignalConnectivityChangedEvent>((event) {
      final before = event.oldState.toSet(), now = event.state.toSet();
      if (now.contains(ConnectivityResult.none) || before.length != now.length || !before.containsAll(now)) {
        _gravixNoteNetTrouble();
      }
    });

    onDispose(() async {
      _gravixIceWatch.stop();
      await _gravixNetListener.dispose();
      // GRAVIX: disposed while connected (no disconnect() first): leave, so the
      // SFU does not keep a ghost participant until its ping timeout
      gravixLeaveBestEffort();
      _isClosed = true;
      await cleanUp();
      await events.dispose();
      await _signalListener.dispose();
      _reliableReceivedState.dispose();
    });
  }

  Future<void> connect(
    String url,
    String token, {
    ConnectOptions? connectOptions,
    RoomOptions? roomOptions,
    FastConnectOptions? fastConnectOptions,
    RegionUrlProvider? regionUrlProvider,
  }) async {
    this.url = url;
    this.token = token;
    _gravixIceWatchOff = false; // GRAVIX (2026-10-14): a new session may be watched
    // update new options (if exists)
    this.connectOptions = connectOptions ?? this.connectOptions;
    this.roomOptions = roomOptions ?? this.roomOptions;
    this.fastConnectOptions = fastConnectOptions;

    if (regionUrlProvider != null) {
      _regionUrlProvider = regionUrlProvider;
    }

    // GRAVIX(one-session): a fresh connect never runs beside a resume. One that
    // is not the full reconnect's own cancels whatever reconnect is pending or in
    // flight first (its late socket is superseded in SignalClient.connect).
    if (!_inRestart && (_attemptingReconnect || isPendingReconnect || _isReconnecting)) {
      _cancelReconnect('fresh connect');
    }

    //reset state
    _isClosed = false;
    if (!_inRestart) _gravixRestartUrl = null; // a fresh connect: no move pending

    // GRAVIX(0.4.13): a fresh join waits longer for its peer connection than a
    // resume or a full reconnect does (Timeouts.mediaConnect; see there).
    final freshJoin = !_inRestart && !_isReconnecting && !_attemptingReconnect;

    signalClient.gravixNextDialTimeout = _gravixNextDialTimeout;
    _gravixNextDialTimeout = null;
    // upstream 2.13.1 (#1228): this attempt's setup time scales the video start bitrate hint
    final connectStopwatch = Stopwatch()..start();
    try {
      // wait for socket to connect rtc server
      await signalClient.connect(url, token, connectOptions: this.connectOptions, roomOptions: this.roomOptions);
      // GRAVIX (2026-10-11, slowPathPeerConnectWait): how long the signal path took
      final signalSetup = connectStopwatch.elapsed;

      // GRAVIX (2026-10-11, restartAbortsOnSignalLoss): during a full reconnect
      // these waits end when its signal socket closes (RECHECK Wi-Fi flapping:
      // they ran out their 10 s on a dead socket)
      Future<T> unlessSignalLost<T>(Future<T> wait, String what) =>
          _inRestart ? _gravixUnlessSignalLost(wait, what) : wait;

      // wait for join response
      await unlessSignalLost(
        events.waitFor<EngineJoinResponseEvent>(
          duration: this.connectOptions.timeouts.connection,
          onTimeout: () => throw ConnectException(
            'Timed out waiting for SignalJoinResponseEvent',
            reason: ConnectionErrorReason.Timeout,
          ),
        ),
        'the JoinResponse',
      );

      // the join response created the publisher; it derives the start bitrate hint from this
      // attempt's setup time (or the time elapsed so far, for an offer made before it ends)
      publisher?.setConnectStopwatch(connectStopwatch);

      logger.fine('Waiting for engine to connect...');

      // wait until primary pc is connected
      // GRAVIX (2026-10-11, fullReconnectMediaConnect): RECHECK r376, a full
      // reconnect's ICE connected after 4.2 s and its DTLS was still running at
      // the 10 s mark; a full reconnect now waits like a fresh join.
      final recovery = this.roomOptions.recovery;
      final timeouts = this.connectOptions.timeouts;
      await unlessSignalLost(
        _gravixWaitPrimaryConnected(
          freshJoin || recovery.fullReconnectMediaConnect ? timeouts.mediaConnect : timeouts.connection,
          ceiling: recovery.slowPathPeerConnectWait,
          // GRAVIX (2026-10-11, slowPathPeerConnectWait): RECHECK r376, the fresh
          // join's ICE still checking at the 20 s mark after a 10.7 s signal dial
          slowPath: () =>
              signalSetup >= recovery.slowSignalSetup || signalClient.rtt >= recovery.slowSignalRtt.inMilliseconds,
          signalSetup: signalSetup,
        ),
        'the primary connection',
      );
      connectStopwatch.stop();
      logger.info('connection setup took ${connectStopwatch.elapsedMilliseconds} ms');
      events.emit(const EngineConnectedEvent());
    } catch (error) {
      logger.fine('Connect Error $error');

      // during a reconnect this connect() runs inside restartConnection and
      // attemptReconnect owns disconnect emission, emitting here as well
      // would produce two events for one failure
      // GRAVIX(0.4.13): an attempt Room.connect may retry defers the event to
      // the room, which emits it itself when it gives up (one joinFailure per
      // failed connect, none for an attempt that is retried).
      if (!_isReconnecting && !_attemptingReconnect && !gravixDeferJoinFailure) {
        events.emit(EngineDisconnectedEvent(reason: gravixJoinFailureReason(error)));
      }
      rethrow;
    }
  }

  /// GRAVIX (2026-10-11, slowPathPeerConnectWait): the wait for the primary
  /// peer connection: [base]; when it runs out on a measurably slow signal path
  /// ([slowPath]), on up to [ceiling] in all (one listener, no gap between).
  Future<void> _gravixWaitPrimaryConnected(
    Duration base, {
    Duration? ceiling,
    required bool Function() slowPath,
    required Duration signalSetup,
  }) async {
    final done = Completer<void>();
    final cancel = events.on<EnginePeerStateUpdatedEvent>((_) {
      if (!done.isCompleted) done.complete();
    }, filter: (event) => event.isPrimary && event.state.isConnected());
    MediaConnectException timedOut() => MediaConnectException(
      'Timed out waiting for PeerConnection to connect, please check your network for ice connectivity',
    );
    try {
      var ranOut = false;
      await done.future.timeout(base, onTimeout: () => ranOut = true);
      if (!ranOut) return;
      if (ceiling == null || ceiling <= base || !slowPath()) throw timedOut();
      logger.info(
        'peer connection not connected after ${base.inMilliseconds} ms on a slow signal path '
        '(signal setup ${signalSetup.inMilliseconds} ms, rtt ${signalClient.rtt} ms): waiting up to '
        '${ceiling.inMilliseconds} ms',
      );
      ranOut = false;
      await done.future.timeout(ceiling - base, onTimeout: () => ranOut = true);
      if (ranOut) throw timedOut();
    } finally {
      await cancel();
    }
  }

  /// GRAVIX (0.4.15): the dial timeout of the next [connect] only (the
  /// same-url retry of a full reconnect).
  Duration? _gravixNextDialTimeout;

  /// GRAVIX (0.4.15): the next [restartConnection] is the same-url retry.
  bool _gravixSameUrlRetryNext = false;

  /// GRAVIX (0.4.15, F6): when the reconnect attempt in progress began, and when
  /// the device's network last changed or read offline (see
  /// [GravixRecoveryOptions.failoverNeedsEvidence]).
  DateTime? _gravixAttemptStartedAt;
  DateTime? _gravixLastNetTroubleAt;
  late final EventsListener<SignalEvent> _gravixNetListener = signalClient.createListener();

  void _gravixNoteNetTrouble() => _gravixLastNetTroubleAt = DateTime.timestamp();

  /// GRAVIX (2026-10-14, review F6): the connectivity reading, never throwing
  /// (it runs inside the reconnect's catch: an exception there left the session
  /// "reconnecting" with nothing scheduled).
  Future<bool> _gravixReadsOffline() async {
    try {
      return !await signalClient.networkIsAvailable();
    } catch (e) {
      logger.warning('connectivity reading failed ($e); taken as online');
      return false;
    }
  }

  /// GRAVIX (2026-10-14, review F2): the connection whose FAILED during a network
  /// change was given a resume (resumeBeforeFullOnNetworkFailure). When that
  /// resume succeeds with it not back, it gets the bounded resumePeerRestartWait.
  lk_models.ReconnectReason? _gravixNetFailResumeOf;

  /// GRAVIX (2026-10-14, resumeBeforeFullOnNetworkFailure): when the last resume
  /// started. A FAILED gets its one resume only when no resume ran since the
  /// network last changed: a session the network change's resume restored and
  /// that fails again is a full reconnect, as before.
  DateTime? _gravixLastResumeAt;

  bool _gravixResumedSinceNetChange() {
    final resumedAt = _gravixLastResumeAt, troubleAt = _gravixLastNetTroubleAt;
    return resumedAt != null && troubleAt != null && !resumedAt.isBefore(troubleAt);
  }

  /// GRAVIX (2026-10-14): the phone's network changed (or read offline) within
  /// GravixRecoveryOptions.resumeReasonNetworkWindow (30 s when that is off)
  /// before the reconnect began, or since.
  bool _gravixNetChangedRecently() {
    final at = _gravixLastNetTroubleAt;
    if (at == null) return false;
    final w = roomOptions.recovery.resumeReasonNetworkWindow;
    final window = w > Duration.zero ? w : const Duration(seconds: 30);
    final ref = (_isReconnecting ? _reconnectStart : null) ?? DateTime.timestamp();
    return !at.isBefore(ref.subtract(window));
  }

  /// GRAVIX (2026-10-14, GravixRecoveryOptions.resumeReasonNetworkWindow): the
  /// reason a resume tells the server. A peer connection failure right after the
  /// phone's own network changed is the network's doing: RR_SIGNAL_DISCONNECTED,
  /// so the SFU does not take it for "UDP blocked" and prefer ICE/TCP.
  lk_models.ReconnectReason? _gravixResumeReasonFor(lk_models.ReconnectReason? reason) {
    final window = roomOptions.recovery.resumeReasonNetworkWindow;
    if (window <= Duration.zero) return reason;
    if (reason != lk_models.ReconnectReason.RR_PUBLISHER_FAILED &&
        reason != lk_models.ReconnectReason.RR_SUBSCRIBER_FAILED) {
      return reason;
    }
    final at = _gravixLastNetTroubleAt;
    if (at == null) return reason;
    final start = _reconnectStart ?? DateTime.timestamp();
    if (at.isBefore(start.subtract(window))) return reason;
    logger.info('resume after a network change: RR_SIGNAL_DISCONNECTED (not ${reason!.name})');
    return lk_models.ReconnectReason.RR_SIGNAL_DISCONNECTED;
  }

  /// GRAVIX (2026-10-14, GravixRecoveryOptions.freshPeerFailedGrace): the peer
  /// connections that have been connected at least once, and a signal for each
  /// that connects.
  final Expando<bool> _gravixPcEverConnected = Expando('gravixPcEverConnected');
  final Expando<Completer<void>> _gravixPcConnected = Expando('gravixPcConnected');

  void _gravixNotePcConnected(Transport? t) {
    if (t == null) return;
    _gravixPcEverConnected[t] = true;
    final c = _gravixPcConnected[t];
    if (c != null && !c.isCompleted) c.complete();
  }

  /// True when the FAILED of [t] (a connection that never connected) is to be
  /// ignored: it connected within the grace, or it is not this engine's
  /// connection any more. False: ask for the reconnect as before.
  Future<bool> _gravixFreshPcFailureRecovered(Transport? t, String which) async {
    final grace = roomOptions.recovery.freshPeerFailedGrace;
    if (t == null || grace <= Duration.zero || (_gravixPcEverConnected[t] ?? false)) return false;
    logger.info('$which connection FAILED before it ever connected: waiting ${grace.inMilliseconds} ms for it');
    final connected = _gravixPcConnected[t] ??= Completer<void>();
    final ok = await connected.future.then((_) => true).timeout(grace, onTimeout: () => false);
    if (_isClosed || !(identical(t, publisher) || identical(t, subscriber))) return true;
    if (ok) logger.info('$which connection connected after its transient FAILED: no reconnect');
    return ok;
  }

  bool _gravixNetTroubleSince(DateTime? since) {
    final at = _gravixLastNetTroubleAt;
    return at != null && (since == null || !at.isBefore(since));
  }

  /// Evidence that [current] (the session's region) failed and [next] did not:
  /// the device's network steady since the attempt began, [current] not
  /// answering a probe, [next] answering one.
  Future<bool> _gravixRegionFailed(String current, String next) async {
    if (_gravixNetTroubleSince(_gravixAttemptStartedAt)) return false;
    if (!await signalClient.networkIsAvailable()) {
      _gravixNoteNetTrouble();
      return false;
    }
    const t = Duration(seconds: 2);
    final probes = await Future.wait([_gravixServerReachable(current, t), _gravixServerReachable(next, t)]);
    return !probes[0] && probes[1];
  }

  /// GRAVIX (0.4.15, F3, device test r017): waits for the network, re-checking
  /// the connectivity reading and probing the server every [every] instead of
  /// only waiting for a SignalConnectivityChangedEvent: lifting a per-app
  /// network block (and a stale reading) fires none, and the attempt sat out
  /// 10 x Timeouts.connection (100 s). Same overall limit and timeout error.
  Future<void> _gravixWaitForNetwork(Duration every, int gen) async {
    final limit = DateTime.timestamp().add(connectOptions.timeouts.connection * 10);
    while (true) {
      if (_isClosed || gen != _sessionGen) return; // a disconnect / fresh connect took over
      final left = limit.difference(DateTime.timestamp());
      if (left <= Duration.zero) {
        throw ConnectException(
          'attemptReconnect: Timed out waiting for SignalConnectivityChangedEvent',
          reason: ConnectionErrorReason.Timeout,
        );
      }
      try {
        await signalClient.events.waitFor<SignalConnectivityChangedEvent>(
          duration: left < every ? left : every,
          filter: (event) => !event.state.contains(ConnectivityResult.none),
        );
        return; // the platform said the network is back
      } catch (_) {
        // no event within [every] (waitFor only throws on its timeout)
      }
      if (await signalClient.networkIsAvailable()) {
        logger.info('network back (no connectivity event); reconnecting');
        return;
      }
      final target = url;
      if (target != null && await _gravixServerReachable(target, every)) {
        logger.info('server reachable although the connectivity reading says none; reconnecting');
        return;
      }
    }
  }

  /// One HTTP HEAD to the server; any answer (even an error status) means the
  /// path is up. Replaceable in tests.
  @visibleForTesting
  Future<bool> Function(String url, Duration timeout)? gravixReachabilityProbe;

  Future<bool> _gravixServerReachable(String url, Duration timeout) async {
    final probe = gravixReachabilityProbe;
    if (probe != null) return probe(url, timeout);
    try {
      await sdkHttpHead(
        Uri.parse(toHttpUrl(url)),
        networkOptions: roomOptions.networkOptions,
        // GRAVIX (2026-10-11, boundedSignalConnect): the probe's socket is closed
        // at the timeout too; a `.timeout()` alone left every probe of a
        // blackholed path connecting until the OS gave up (~2 min, one more
        // socket per probe interval)
        timeout: roomOptions.recovery.boundedSignalConnect ? timeout : null,
      ).timeout(timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// GRAVIX (0.4.15, R1): a resume now, because subscribed media stopped
  /// arriving (no packet for ~2 s) before ICE noticed (~7 s). Ignored unless the
  /// session is connected with no reconnect pending or running.
  @internal
  bool gravixRequestResume(String why, {bool uplink = false}) {
    if (!_gravixCanRecover()) return false;
    logger.warning('media stalled ($why): resuming now');
    unawaited(
      handleReconnect(
        ClientDisconnectReason.mediaStalled,
        // GRAVIX (2026-10-11, uplinkFeedbackStallFor): an uplink the SFU stopped
        // answering is the publisher's connection
        reconnectReason: uplink
            ? lk_models.ReconnectReason.RR_PUBLISHER_FAILED
            : lk_models.ReconnectReason.RR_SUBSCRIBER_FAILED,
      ),
    );
    return true;
  }

  /// GRAVIX (0.4.15, S4): a full rejoin now, because a subscribed video decoded
  /// nothing after a resume (a resumed session with a dead server downtrack).
  @internal
  bool gravixRequestRejoin(String why) {
    if (!_gravixCanRecover()) return false;
    logger.warning('no video after the resume ($why): full rejoin');
    fullReconnectOnNext = true;
    unawaited(handleReconnect(ClientDisconnectReason.mediaStalled));
    return true;
  }

  /// GRAVIX (2026-10-14, GravixRecoveryOptions.iceTransportWatch): the selected
  /// candidate pair of each connected peer connection (Room.selectedTransport).
  late final GravixIceTransportWatch _gravixIceWatch = GravixIceTransportWatch(
    interval: roomOptions.recovery.iceTransportWatch,
    udpInterval: roomOptions.recovery.iceTransportWatchUdp,
    // GRAVIX (2026-10-14, review F1/F8): never during a join's tail, a reconnect,
    // a leave or after the engine closed
    paused: () =>
        _isClosed ||
        _gravixIceWatchOff ||
        _isReconnecting ||
        _attemptingReconnect ||
        _inRestart ||
        connectionState != ConnectionState.connected,
    background: _gravixAppInBackground,
    slowRtt: roomOptions.recovery.slowTcpRtt,
    slowFor: roomOptions.recovery.slowTcpFor,
    connections: () {
      rtc.RTCPeerConnection? up(Transport? t) => (t?.pc.connectionState?.isConnected() ?? false) ? t!.pc : null;
      return (publisher: up(publisher), subscriber: up(subscriber));
    },
    onChanged: (transport, previous, pub, sub) {
      logger.info('ICE transport: ${transport?.name} (publisher ${pub?.name}, subscriber ${sub?.name})');
      events.emit(
        EngineIceTransportChangedEvent(transport: transport, previous: previous, publisher: pub, subscriber: sub),
      );
    },
    onSlowTcp: (rtt, over) => events.emit(EngineSlowTcpTransportEvent(rtt: rtt, over: over)),
  );

  /// GRAVIX (2026-10-14, review F8): set by [cleanUp] (a leave), cleared by
  /// [connect]: a late Connected of a connection being disposed must not re-arm
  /// the watch.
  bool _gravixIceWatchOff = false;

  /// GRAVIX (2026-10-14, review F10): no stats reading while the app is in the
  /// background (no observer of our own: the binding's current state).
  static bool _gravixAppInBackground() {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == AppLifecycleState.paused || s == AppLifecycleState.hidden || s == AppLifecycleState.detached;
    } catch (_) {
      return false;
    }
  }

  /// GRAVIX (2026-10-14): see [GravixIceTransport]; null until read (or with
  /// GravixRecoveryOptions.iceTransportWatch off).
  @internal
  GravixIceTransport? get gravixSelectedTransport => _gravixIceWatch.transport;
  @internal
  GravixIceTransport? get gravixPublisherTransport => _gravixIceWatch.publisher;
  @internal
  GravixIceTransport? get gravixSubscriberTransport => _gravixIceWatch.subscriber;

  /// Whether the transport watch has a reading scheduled.
  @visibleForTesting
  bool get gravixIceWatchScheduled => _gravixIceWatch.scheduled;

  bool _gravixCanRecover() =>
      !_isClosed &&
      !_attemptingReconnect &&
      !isPendingReconnect &&
      !_isReconnecting &&
      connectionState == ConnectionState.connected;

  /// GRAVIX (0.4.15): whether the local participant has any unmuted published
  /// track. Set by the Room; null = unknown (treated as yes).
  @internal
  bool Function()? gravixHasUnmutedLocalMedia;

  /// GRAVIX(0.4.13): set by Room.connect around a join attempt it may retry
  /// (ConnectOptions.joinRetries). A failed [connect] then emits no
  /// EngineDisconnectedEvent; the room cleans the attempt up and either retries
  /// or emits the event itself.
  @internal
  bool gravixDeferJoinFailure = false;

  /// GRAVIX (2026-10-12, fast publish): set by Room.connect for a join attempt
  /// that publishes its microphone inside the join (GravixJoinMicrophone). The
  /// publisher offer a JoinResponse asks for (fastPublish, or a publisher-primary
  /// session) is then not made at once: the join's microphone publish makes it,
  /// with the audio transceiver in it, once its capture is ready. The future
  /// completes true when the publish asked for the offer itself, false when it
  /// gave up (no capture in time, no permission, a failure, the attempt ended):
  /// the engine then makes the data-channel-only offer as before. Without it
  /// the offer went out 20 ms (the debounce) after the JoinResponse, before any
  /// track could be added, and the microphone needed a second offer/answer
  /// (REAL Android, 6 ms to the SFU: the mic went live 0.93 s after the room
  /// connected). Null (default): exactly the old behaviour.
  @internal
  Future<bool> Function()? gravixJoinOfferHold;

  /// GRAVIX (2026-10-12, fast publish): whether this session's publisher has
  /// been asked to negotiate (an offer made or debouncing).
  @internal
  bool get gravixHasNegotiated => _hasPublished;

  /// The DisconnectReason a failed fresh [connect] reports for [error].
  @internal
  static DisconnectReason gravixJoinFailureReason(Object error) =>
      error is CertificatePinningException ? DisconnectReason.signalingConnectionFailure : DisconnectReason.joinFailure;

  // resets internal state to a re-usable state
  Future<void> cleanUp() async {
    logger.fine('[$objectId] cleanUp()');
    _gravixRestartUrl = null;
    _gravixIceWatchOff = true;
    _gravixIceWatch.stop();
    _gravixStopPublisherWatch();
    _gravixStopRestartWait(); // GRAVIX (2026-10-11, resumePeerRestartWait)

    await publisher?.dispose();
    publisher = null;
    _hasPublished = false;

    await subscriber?.dispose();
    subscriber = null;

    await signalClient.cleanUp();

    fullReconnectOnNext = false;
    _attemptingReconnect = false;

    // Reset reliability state
    _reliableDataSequence = 1;
    _reliableMessageBuffer.clear();
    _reliableReceivedState.clear();
    _isReconnecting = false;

    _clearPendingReconnect();
  }

  /// [gravixAbort] (GRAVIX, 2026-10-12): completing it ends the wait for the
  /// TrackPublished at once (a join attempt that failed: its socket will never
  /// deliver it, and the next attempt must not wait behind it).
  @internal
  Future<lk_models.TrackInfo> addTrack(lk_rtc.AddTrackRequest req, {Future<void>? gravixAbort}) async {
    // Race TrackPublished against a RequestResponse refusal for the same cid,
    // so a server rejection (e.g. video above the plan's resolution cap) fails
    // the publish promptly with the server's reason instead of a timeout.
    // Both listeners are registered before the request goes out.
    final completer = Completer<lk_models.TrackInfo>();
    final cancelPublished = _signalListener.on<SignalLocalTrackPublishedEvent>((event) {
      if (!completer.isCompleted) completer.complete(event.track);
    }, filter: (event) => event.cid == req.cid);
    final cancelRejected = _signalListener.on<SignalRequestResponseEvent>((event) {
      final reason = gravixAddTrackRejection(event.response, req.cid);
      if (reason != null && !completer.isCompleted) {
        logger.warning('[addTrack] $reason');
        completer.completeError(TrackPublishException(reason));
      }
    });

    // GRAVIX (0.4.15, F4): a full reconnect replacing this session ends the wait
    // at once (its socket will never deliver the TrackPublished); before, the
    // publish sat out timeouts.publish (10 s) and held the source's publish queue
    final replaced = _gravixRestartSignal.future;
    unawaited(
      replaced.then((_) {
        if (!completer.isCompleted) {
          completer.completeError(GravixSessionReplacedException('addTrack ${req.cid}: the session was replaced'));
        }
      }),
    );
    if (gravixAbort != null) {
      unawaited(
        gravixAbort.then((_) {
          if (!completer.isCompleted) {
            completer.completeError(TrackPublishException('addTrack ${req.cid}: the join attempt ended'));
          }
        }),
      );
    }
    try {
      signalClient.sendAddTrack(req);
      return await completer.future.timeout(
        connectOptions.timeouts.publish,
        onTimeout: () => throw TrackPublishException(),
      );
    } finally {
      await cancelPublished();
      await cancelRejected();
    }
  }

  Future<void> _onPublisherNegotiationError(Object error) async {
    if (error is NegotiationError) {
      fullReconnectOnNext = true;
    }
    await handleReconnect(
      ClientDisconnectReason.negotiationFailed,
      reconnectReason: lk_models.ReconnectReason.RR_UNKNOWN,
    );
  }

  @internal
  Future<void> negotiate({bool? iceRestart}) async {
    if (publisher == null) {
      return;
    }
    _hasPublished = true;
    try {
      publisher!.negotiate(null);
    } catch (error) {
      if (error is NegotiationError) {
        fullReconnectOnNext = true;
      }
      await handleReconnect(
        ClientDisconnectReason.negotiationFailed,
        reconnectReason: lk_models.ReconnectReason.RR_UNKNOWN,
      );
    }
  }

  bool? isBufferStatusLow(Reliability kind) {
    final dc = _publisherDataChannel(kind);
    if (dc != null) {
      return dc.bufferedAmount! <= dc.bufferedAmountLowThreshold!;
    }
    return null;
  }

  Future<void> waitForBufferStatusLow(Reliability kind) async {
    final Completer<void> completer = Completer();

    if (isBufferStatusLow(kind) == true) {
      completer.complete();
    } else {
      onClosing() {
        if (!completer.isCompleted) {
          completer.completeError('Engine disconnected');
        }
      }

      events.once<EngineClosingEvent>((e) => onClosing());

      while (!completer.isCompleted && !_dcBufferStatus[kind]!) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      if (completer.isCompleted) {
        return;
      }
      completer.complete();
    }

    return completer.future;
  }

  Future<void> _resendReliableMessagesForResume(int lastMessageSeq) async {
    logger.fine('Resending reliable messages from sequence $lastMessageSeq');

    final channel = _publisherDataChannel(Reliability.reliable);
    if (channel == null) {
      logger.warning('Reliable data channel is null, cannot resend messages');
      return;
    }

    // Remove acknowledged messages from buffer
    _reliableMessageBuffer.popToSequence(lastMessageSeq);

    // Get remaining messages to resend
    final messagesToResend = _reliableMessageBuffer.getAll();

    if (messagesToResend.isEmpty) {
      logger.fine('No reliable messages to resend');
      return;
    }

    logger.fine('Resending ${messagesToResend.length} reliable messages');

    for (final item in messagesToResend) {
      try {
        await channel.send(item.message);
        logger.fine('Resent reliable message with sequence ${item.sequence}');
      } catch (e) {
        logger.warning('Failed to resend reliable message ${item.sequence}: $e');
      }
    }
  }

  @internal
  Future<void> sendDataPacket(lk_models.DataPacket packet, {Reliability reliability = Reliability.lossy}) async {
    // Add sequence number for reliable packets
    if (reliability == Reliability.reliable) {
      packet.sequence = _reliableDataSequence++;
    }

    // construct the data channel message
    var message = rtc.RTCDataChannelMessage.fromBinary(packet.writeToBuffer());

    // GRAVIX (0.4.15): resumed on the subscriber alone; the data channels are on
    // the publisher connection, which is still recovering: wait for it (or for
    // the reconnect its watch starts) rather than write into a dead channel.
    final publisherRecovery = _gravixPublisherRecovery;
    if (!_subscriberPrimary && publisherRecovery != null) {
      await publisherRecovery.future;
    }

    if (_subscriberPrimary) {
      // make sure publisher transport is connected
      await ensurePublisherConnected();

      // wait for data channel to open (if not already)
      if (_publisherDataChannelState(reliability) != rtc.RTCDataChannelState.RTCDataChannelOpen) {
        logger.fine('Waiting for data channel ${reliability} to open...');
        await events.waitFor<PublisherDataChannelStateUpdatedEvent>(
          filter: (event) => event.type == reliability,
          duration: connectOptions.timeouts.connection,
        );
      }
    }

    // chose data channel
    final rtc.RTCDataChannel? channel = _publisherDataChannel(reliability);

    if (channel == null) {
      throw UnexpectedStateException('Data channel for ${packet.kind.toSDKType()} is null');
    }

    if (_e2eeManager != null && _e2eeManager!.isDataChannelEncryptionEnabled) {
      final encryptablePacket = asEncryptablePacket(packet);
      if (encryptablePacket != null) {
        final encryptedData = await _e2eeManager?.encryptData(data: encryptablePacket.writeToBuffer());

        if (encryptedData == null) {
          logger.warning('Failed to encrypt data packet');
          return;
        }

        final encryptedPacket = lk_models.EncryptedPacket(
          encryptionType: lk_models.Encryption_Type.GCM,
          encryptedValue: encryptedData.data,
          iv: encryptedData.iv,
          keyIndex: encryptedData.keyIndex,
        );

        final dataToSend = lk_models.DataPacket(
          participantIdentity: packet.participantIdentity,
          kind: packet.kind,
          encryptedPacket: encryptedPacket,
          destinationIdentities: packet.destinationIdentities,
          sequence: packet.hasSequence() ? packet.sequence : null,
          participantSid: packet.hasParticipantSid() ? packet.participantSid : null,
        );

        message = rtc.RTCDataChannelMessage.fromBinary(dataToSend.writeToBuffer());
      }
    }

    // Buffer reliable packets for potential resending
    if (reliability == Reliability.reliable) {
      _reliableMessageBuffer.push(BufferedDataPacket(packet: packet, message: message, sequence: packet.sequence));
    }

    // Don't send during reconnection, but keep message buffered for resending
    if (_isReconnecting) {
      logger.fine('Deferring data packet send during reconnection (will resend when resumed)');
      return;
    }

    logger.fine('sendDataPacket(label:${channel.label}, sequence:${packet.sequence})');
    await channel.send(message);

    _dcBufferStatus[reliability] = await channel.getBufferedAmount() <= channel.bufferedAmountLowThreshold!;

    // Align buffer with WebRTC buffer for reliable packets
    if (reliability == Reliability.reliable) {
      _reliableMessageBuffer.alignBufferedAmount(await channel.getBufferedAmount());
    }
  }

  Future<void> _publisherEnsureConnected() async {
    final state = await publisher?.pc.getConnectionState();
    if (state?.isConnected() != true) {
      logger.fine('Publisher is not connected...');

      // start negotiation
      if (state != rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting) {
        await negotiate();
      }
      if (!lkPlatformIsTest() || gravixPublisherWaitInTests) {
        logger.fine('Waiting for publisher to ice-connect...');
        await events.waitFor<EnginePublisherPeerStateUpdatedEvent>(
          filter: (event) => event.state.isConnected(),
          duration: connectOptions.timeouts.peerConnection,
        );
      }
    }
  }

  @internal
  Future<void> ensurePublisherConnected() {
    final existing = _publisherConnectionCompleter;
    if (existing != null && !existing.isCompleted) {
      return existing.future;
    }

    final completer = Completer<void>();
    _publisherConnectionCompleter = completer;

    unawaited(
      _publisherEnsureConnected()
          .then(
            (_) {
              if (!completer.isCompleted) {
                completer.complete();
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!completer.isCompleted) {
                completer.completeError(error, stackTrace);
              }
            },
          )
          .whenComplete(() {
            if (identical(_publisherConnectionCompleter, completer)) {
              _publisherConnectionCompleter = null;
            }
          }),
    );

    return completer.future;
  }

  void _resetPublisherConnection() {
    final completer = _publisherConnectionCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        ConnectException('Publisher connection reset', reason: ConnectionErrorReason.InternalError),
      );
    }
    _publisherConnectionCompleter = null;
  }

  lk_models.EncryptedPacketPayload? asEncryptablePacket(lk_models.DataPacket packet) {
    if ([
          lk_models.DataPacket_Value.sipDtmf,
          lk_models.DataPacket_Value.metrics,
          lk_models.DataPacket_Value.speaker,
          lk_models.DataPacket_Value.transcription,
          lk_models.DataPacket_Value.encryptedPacket,
        ].contains(packet.whichValue()) ==
        false) {
      switch (packet.whichValue()) {
        case lk_models.DataPacket_Value.user:
          return lk_models.EncryptedPacketPayload(user: packet.user);
        case lk_models.DataPacket_Value.rpcRequest:
          return lk_models.EncryptedPacketPayload(rpcRequest: packet.rpcRequest);
        case lk_models.DataPacket_Value.rpcResponse:
          return lk_models.EncryptedPacketPayload(rpcResponse: packet.rpcResponse);
        case lk_models.DataPacket_Value.rpcAck:
          return lk_models.EncryptedPacketPayload(rpcAck: packet.rpcAck);
        case lk_models.DataPacket_Value.streamHeader:
          return lk_models.EncryptedPacketPayload(streamHeader: packet.streamHeader);
        case lk_models.DataPacket_Value.streamChunk:
          return lk_models.EncryptedPacketPayload(streamChunk: packet.streamChunk);
        case lk_models.DataPacket_Value.streamTrailer:
          return lk_models.EncryptedPacketPayload(streamTrailer: packet.streamTrailer);
        default:
          return null;
      }
    }
    return null;
  }

  lk_models.DataPacket asDataPacket(lk_models.EncryptedPacketPayload packet) {
    switch (packet.whichValue()) {
      case lk_models.EncryptedPacketPayload_Value.user:
        return lk_models.DataPacket(user: packet.user);
      case lk_models.EncryptedPacketPayload_Value.rpcRequest:
        return lk_models.DataPacket(rpcRequest: packet.rpcRequest);
      case lk_models.EncryptedPacketPayload_Value.rpcResponse:
        return lk_models.DataPacket(rpcResponse: packet.rpcResponse);
      case lk_models.EncryptedPacketPayload_Value.rpcAck:
        return lk_models.DataPacket(rpcAck: packet.rpcAck);
      case lk_models.EncryptedPacketPayload_Value.streamHeader:
        return lk_models.DataPacket(streamHeader: packet.streamHeader);
      case lk_models.EncryptedPacketPayload_Value.streamChunk:
        return lk_models.DataPacket(streamChunk: packet.streamChunk);
      case lk_models.EncryptedPacketPayload_Value.streamTrailer:
        return lk_models.DataPacket(streamTrailer: packet.streamTrailer);
      default:
        throw Exception('Unknown encrypted packet type: ${packet.whichValue()}');
    }
  }

  Future<RTCConfiguration> _buildRtcConfiguration({
    required lk_models.ClientConfigSetting serverResponseForceRelay,
    required List<RTCIceServer> serverProvidedIceServers,
  }) async {
    // RTCConfiguration? config;
    RTCConfiguration rtcConfiguration = connectOptions.rtcConfiguration;

    // The server provided iceServers are only used if
    // the client's iceServers are not set.
    if (rtcConfiguration.iceServers == null && serverProvidedIceServers.isNotEmpty) {
      rtcConfiguration = connectOptions.rtcConfiguration.copyWith(iceServers: serverProvidedIceServers);
    }

    // set forceRelay if server response is enabled
    if (serverResponseForceRelay == lk_models.ClientConfigSetting.ENABLED) {
      rtcConfiguration = rtcConfiguration.copyWith(iceTransportPolicy: RTCIceTransportPolicy.relay);
    }

    if (kIsWeb && (roomOptions.e2eeOptions != null || roomOptions.encryption != null)) {
      rtcConfiguration = rtcConfiguration.copyWith(encodedInsertableStreams: true);
    }

    return rtcConfiguration;
  }

  Future<void> _createPeerConnections(RTCConfiguration rtcConfiguration) async {
    _gravixTransportGen++; // GRAVIX (0.4.15, F4)
    publisher = await Transport.create(
      _peerConnectionCreate,
      rtcConfig: rtcConfiguration,
      connectOptions: connectOptions,
    );
    publisher!.gravixConnectionLevelStartBitrate = roomOptions.recovery.startBitrateBySetupTime; // GRAVIX (0.4.15)
    publisher!.gravixLogLabel = 'pub#$_gravixTransportGen'; // GRAVIX (0.4.19): GravixPubLog lines
    // GRAVIX (0.4.15, BUG-3): an offer the socket cannot carry is held (not made
    // and dropped), and a restart rolls back an offer that left unanswered.
    if (roomOptions.recovery.deferNegotiateDuringResume) {
      publisher!.gravixHoldOffers = () => signalClient.connectionState != ConnectionState.connected;
    }
    publisher!.gravixRollbackStaleOffer = roomOptions.recovery.rollbackStaleOfferOnRestart;
    // GRAVIX(viewer-fast-start): the subscriber connection checks its pair
    // again soon after it is writable, so the SFU nominates at once; restored to
    // the libwebrtc default when it is connected. See
    // GravixViewerFastStart.subscriberConnectPingIntervalMs.
    final connectPing = GravixViewerFastStart.subscriberConnectPingIntervalMs;
    subscriber = await Transport.create(
      connectPing == null
          ? _peerConnectionCreate
          : (config, [constraints = const {}]) =>
                _peerConnectionCreate(gravixWithSubscriberConnectPing(config, connectPing), constraints),
      rtcConfig: rtcConfiguration,
      connectOptions: connectOptions,
    );
    _gravixConnectPingRestore = connectPing == null ? null : rtcConfiguration;
    subscriber!.gravixLogLabel = 'sub#$_gravixTransportGen';

    publisher?.pc.onIceCandidate = (rtc.RTCIceCandidate candidate) {
      logger.fine('publisher onIceCandidate');
      signalClient.sendIceCandidate(candidate, lk_rtc.SignalTarget.PUBLISHER);
    };

    publisher?.pc.onIceConnectionState = (rtc.RTCIceConnectionState state) async {
      _gravixMark('pub:ice', state.name); // GRAVIX: Dart receipt, for the join timeline
      logger.fine('publisher iceConnectionState: $state');
      if (state == rtc.RTCIceConnectionState.RTCIceConnectionStateConnected) {
        await _handleGettingConnectedServerAddress(publisher!.pc, isPublisher: true);
      }
    };

    subscriber?.pc.onIceCandidate = (rtc.RTCIceCandidate candidate) {
      logger.fine('subscriber onIceCandidate');
      signalClient.sendIceCandidate(candidate, lk_rtc.SignalTarget.SUBSCRIBER);
    };

    subscriber?.pc.onIceConnectionState = (rtc.RTCIceConnectionState state) async {
      _gravixMark('sub:ice', state.name); // GRAVIX: Dart receipt, for the join timeline
      logger.fine('subscriber iceConnectionState: $state');
      if (state == rtc.RTCIceConnectionState.RTCIceConnectionStateConnected) {
        await _handleGettingConnectedServerAddress(subscriber!.pc, isPublisher: false);
      }
    };

    publisher?.onOffer = (offer) {
      logger.fine('publisher onOffer');
      signalClient.sendOffer(offer);
    };

    // GRAVIX (0.4.15): upstream 2.13.1 (#1226): the catch in [negotiate] never saw
    // a failed debounced offer (unhandled error, no reconnect); route it here.
    if (_upstreamReconnectFixes) publisher?.onNegotiationError = _onPublisherNegotiationError;

    // in subscriber primary mode, server side opens sub data channels.
    if (_subscriberPrimary) {
      subscriber?.pc.onDataChannel = _onDataChannel;
    }

    final sub = subscriber, pub = publisher;
    subscriber?.pc.onConnectionState = (state) async {
      _gravixMark('sub:pc', state.name); // GRAVIX: Dart receipt, for the join timeline
      final restore = _gravixConnectPingRestore; // GRAVIX(viewer-fast-start)
      if (restore != null && state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _gravixConnectPingRestore = null;
        unawaited(
          subscriber?.pc
              .setConfiguration(restore.toMap())
              .then((_) => _gravixMark('sub:connectPingRestored'))
              .catchError((Object e) => logger.warning('restoring the subscriber ping interval failed: $e')),
        );
      }
      if (state.isConnected()) _gravixPcUpSeq++; // GRAVIX (2026-10-11, resumeSatisfiesPeerFailure)
      if (state.isConnected()) _gravixNotePcConnected(sub);
      events.emit(EngineSubscriberPeerStateUpdatedEvent(state: state, isPrimary: _subscriberPrimary));
      logger.fine('subscriber connectionState: $state');
      if (state.isConnected() && identical(sub, subscriber)) _gravixIceWatch.poke();
      if (state.isDisconnected() || state.isFailed()) {
        if (state.isFailed() && await _gravixFreshPcFailureRecovered(sub, 'subscriber')) return;
        await handleReconnect(
          state.isFailed() ? ClientDisconnectReason.peerConnectionFailed : ClientDisconnectReason.peerConnectionClosed,
          reconnectReason: lk_models.ReconnectReason.RR_SUBSCRIBER_FAILED,
        );
      }
    };

    publisher?.pc.onConnectionState = (state) async {
      _gravixMark('pub:pc', state.name); // GRAVIX: Dart receipt, for the join timeline
      if ([
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed,
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed,
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
      ].contains(state)) {
        _resetPublisherConnection();
      }
      if (state.isConnected()) _gravixPcUpSeq++; // GRAVIX (2026-10-11, resumeSatisfiesPeerFailure)
      if (state.isConnected()) _gravixNotePcConnected(pub);
      events.emit(EnginePublisherPeerStateUpdatedEvent(state: state, isPrimary: !_subscriberPrimary));
      logger.fine('publisher connectionState: $state');
      if (state.isConnected() && identical(pub, publisher)) _gravixIceWatch.poke();
      if (state.isDisconnected() || state.isFailed()) {
        if (state.isFailed() && await _gravixFreshPcFailureRecovered(pub, 'publisher')) return;
        await handleReconnect(
          state.isFailed() ? ClientDisconnectReason.peerConnectionFailed : ClientDisconnectReason.peerConnectionClosed,
          reconnectReason: lk_models.ReconnectReason.RR_PUBLISHER_FAILED,
        );
      }
    };

    subscriber?.pc.onTrack = (rtc.RTCTrackEvent event) {
      logger.fine('[WebRTC] pc.onTrack');
      _gravixMark(
        'onTrack',
        '${event.track.kind}:${signalClient.connectionState.name}:${connectionState.name}',
      ); // GRAVIX

      final stream = event.streams.firstOrNull;
      if (stream == null) {
        // we need the stream to get the track's id
        logger.severe('received track without mediastream');
        return;
      }

      // doesn't get called reliably
      event.track.onEnded = () {
        logger.fine('[WebRTC] track.onEnded');
      };

      // doesn't get called reliably
      stream.onRemoveTrack = (_) {
        logger.fine('[WebRTC] stream.onRemoveTrack');
      };

      if (signalClient.connectionState == ConnectionState.reconnecting ||
          signalClient.connectionState == ConnectionState.connecting) {
        final track = event.track;
        final receiver = event.receiver;
        events.once<EngineConnectedEvent>((event) async {
          Timer(const Duration(milliseconds: 10), () {
            events.emit(EngineTrackAddedEvent(track: track, stream: stream, receiver: receiver));
          });
        });
        return;
      }

      if (connectionState == ConnectionState.disconnected) {
        logger.warning('skipping incoming track after Room disconnected');
        return;
      }

      events.emit(EngineTrackAddedEvent(track: event.track, stream: stream, receiver: event.receiver));
    };

    // doesn't get called reliably, doesn't work on mac
    subscriber?.pc.onRemoveTrack = (rtc.MediaStream stream, rtc.MediaStreamTrack track) {
      logger.fine('[WebRTC] ${track.id} pc.onRemoveTrack');
    };

    // also handle messages over the pub channel, for backwards compatibility
    try {
      final lossyInit = rtc.RTCDataChannelInit()
        ..binaryType = 'binary'
        ..ordered = false
        ..maxRetransmits = 0;
      _lossyDCPub = await publisher?.pc.createDataChannel(_lossyDCLabel, lossyInit);
      _lossyDCPub?.onMessage = _onDCMessage;
      _lossyDCPub?.stateChangeStream.listen(
        (state) => events.emit(
          PublisherDataChannelStateUpdatedEvent(isPrimary: !_subscriberPrimary, state: state, type: Reliability.lossy),
        ),
      );
      // _onDCStateUpdated(Reliability.lossy, state)
      _lossyDCPub?.bufferedAmountLowThreshold = 2 * 1024 * 1024;
      _lossyDCPub?.onBufferedAmountLow = (_) {
        _dcBufferStatus[Reliability.lossy] = (_lossyDCPub!.bufferedAmount! <= _lossyDCPub!.bufferedAmountLowThreshold!);
      };
    } catch (err) {
      logger.severe('[$objectId] createDataChannel() did throw $err');
    }

    try {
      final reliableInit = rtc.RTCDataChannelInit()
        ..binaryType = 'binary'
        ..ordered = true;
      _reliableDCPub = await publisher?.pc.createDataChannel(_reliableDCLabel, reliableInit);
      _reliableDCPub?.onMessage = _onDCMessage;
      _reliableDCPub?.stateChangeStream.listen(
        (state) => events.emit(
          PublisherDataChannelStateUpdatedEvent(
            isPrimary: !_subscriberPrimary,
            state: state,
            type: Reliability.reliable,
          ),
        ),
      );
      _reliableDCPub?.bufferedAmountLowThreshold = 2 * 1024 * 1024;
      _reliableDCPub?.onBufferedAmountLow = (_) {
        _dcBufferStatus[Reliability.reliable] =
            (_reliableDCPub!.bufferedAmount! <= _reliableDCPub!.bufferedAmountLowThreshold!);
      };
    } catch (err) {
      logger.severe('[$objectId] createDataChannel() did throw $err');
    }
  }

  void _onDataChannel(rtc.RTCDataChannel dc) {
    switch (dc.label) {
      case _reliableDCLabel:
        logger.fine('Server opened DC label: ${dc.label}');
        _reliableDCSub = dc;
        _reliableDCSub?.onMessage = _onDCMessage;
        _reliableDCSub?.stateChangeStream.listen(
          (state) => events.emit(
            SubscriberDataChannelStateUpdatedEvent(
              isPrimary: _subscriberPrimary,
              state: state,
              type: Reliability.reliable,
            ),
          ),
        );
        break;
      case _lossyDCLabel:
        logger.fine('Server opened DC label: ${dc.label}');
        _lossyDCSub = dc;
        _lossyDCSub?.onMessage = _onDCMessage;
        _lossyDCSub?.stateChangeStream.listen(
          (state) => events.emit(
            SubscriberDataChannelStateUpdatedEvent(
              isPrimary: _subscriberPrimary,
              state: state,
              type: Reliability.lossy,
            ),
          ),
        );
        break;
      default:
        logger.warning('Unknown DC label: ${dc.label}');
        break;
    }
  }

  Future<void> _handleGettingConnectedServerAddress(rtc.RTCPeerConnection pc, {required bool isPublisher}) async {
    try {
      // GRAVIX (2026-10-14, review F3): one read for both the connected address
      // and the session's ICE transport (no read of the watch's own to know it)
      final stats = await pc.getStats();
      final remoteAddress = gravixConnectedAddressOf(stats);
      if (identical(pc, (isPublisher ? publisher : subscriber)?.pc)) {
        _gravixIceWatch.observe(isPublisher: isPublisher, stats: stats);
      }
      logger.fine('Connected address: $remoteAddress');
      if (_connectedServerAddress == null || _connectedServerAddress != remoteAddress) {
        _connectedServerAddress = remoteAddress;
      }
    } catch (e) {
      logger.warning('could not get connected server address ${e.toString()}');
    }
  }

  void _onDCMessage(rtc.RTCDataChannelMessage message) async {
    // always expect binary
    if (!message.isBinary) {
      logger.warning('Data message is not binary');
      return;
    }
    final dp = lk_models.DataPacket.fromBuffer(message.binary);
    if (dp.whichValue() == lk_models.DataPacket_Value.encryptedPacket) {
      if (_e2eeManager == null) {
        logger.warning('Received encrypted packet but E2EE not set up');
        return;
      }
      final decryptedData = await _e2eeManager?.handleEncryptedData(
        data: Uint8List.fromList(dp.encryptedPacket.encryptedValue),
        iv: Uint8List.fromList(dp.encryptedPacket.iv),
        participantIdentity: dp.participantIdentity,
        keyIndex: dp.encryptedPacket.keyIndex,
      );
      if (decryptedData == null) {
        logger.warning('Failed to decrypt data packet');
        return;
      }
      final decryptedPacketPayload = lk_models.EncryptedPacketPayload.fromBuffer(decryptedData);
      final newDp = asDataPacket(decryptedPacketPayload);

      // Handle sequence numbers for reliable packets (encrypted outer packet)
      if (dp.kind == lk_models.DataPacket_Kind.RELIABLE && dp.hasSequence()) {
        final participantKey = _reliableParticipantKey(dp);
        if (participantKey != null) {
          final sequence = dp.sequence;
          final lastReceived = _reliableReceivedState.get(participantKey) ?? 0;
          if (sequence <= lastReceived) {
            logger.fine(
              'Ignoring duplicate or out-of-order packet: '
              'sequence=$sequence, lastReceived=$lastReceived, participantSid=$participantKey',
            );
            return;
          }
          _reliableReceivedState.set(participantKey, sequence);
        }
      }

      // Preserve metadata from the outer packet on the decrypted packet
      newDp
        ..kind = dp.kind
        ..sequence = dp.sequence
        ..participantIdentity = dp.participantIdentity
        ..participantSid = dp.participantSid
        ..destinationIdentities.addAll(dp.destinationIdentities);

      _emitDataPacket(newDp, encryptionType: dp.encryptedPacket.encryptionType.toLkType());
    } else {
      // Handle sequence numbers for reliable packets (plaintext)
      if (dp.kind == lk_models.DataPacket_Kind.RELIABLE && dp.hasSequence()) {
        final participantKey = _reliableParticipantKey(dp);
        if (participantKey != null) {
          final sequence = dp.sequence;
          final lastReceived = _reliableReceivedState.get(participantKey) ?? 0;
          if (sequence <= lastReceived) {
            logger.fine(
              'Ignoring duplicate or out-of-order packet: '
              'sequence=$sequence, lastReceived=$lastReceived, participantSid=$participantKey',
            );
            return;
          }
          _reliableReceivedState.set(participantKey, sequence);
        } else {
          logger.fine('Reliable packet without participant SID, skipping dedupe');
        }
      }

      _emitDataPacket(dp);
    }
  }

  void _emitDataPacket(lk_models.DataPacket dp, {EncryptionType encryptionType = EncryptionType.kNone}) {
    if (dp.whichValue() == lk_models.DataPacket_Value.speaker) {
      // Speaker packet
      events.emit(EngineActiveSpeakersUpdateEvent(speakers: dp.speaker.speakers));
    } else if (dp.whichValue() == lk_models.DataPacket_Value.user) {
      // User packet
      events.emit(EngineDataPacketReceivedEvent(packet: dp.user, kind: dp.kind, identity: dp.participantIdentity));
    } else if (dp.whichValue() == lk_models.DataPacket_Value.transcription) {
      // Transcription packet
      events.emit(EngineTranscriptionReceivedEvent(transcription: dp.transcription, identity: dp.participantIdentity));
    } else if (dp.whichValue() == lk_models.DataPacket_Value.sipDtmf) {
      // SIP DTMF packet
      events.emit(EngineSipDtmfReceivedEvent(dtmf: dp.sipDtmf, identity: dp.participantIdentity));
    } else if (dp.whichValue() == lk_models.DataPacket_Value.rpcRequest) {
      // RPC Request
      events.emit(EngineRPCRequestReceivedEvent(request: dp.rpcRequest, identity: dp.participantIdentity));
    } else if (dp.whichValue() == lk_models.DataPacket_Value.rpcResponse) {
      // RPC Response
      events.emit(EngineRPCResponseReceivedEvent(response: dp.rpcResponse, identity: dp.participantIdentity));
    } else if (dp.whichValue() == lk_models.DataPacket_Value.rpcAck) {
      // RPC Ack
      events.emit(EngineRPCAckReceivedEvent(ack: dp.rpcAck, identity: dp.participantIdentity));
    } else if (dp.whichValue() == lk_models.DataPacket_Value.streamHeader) {
      // Data Stream Header
      events.emit(
        EngineDataStreamHeaderEvent(
          header: dp.streamHeader,
          identity: dp.participantIdentity,
          encryptionType: encryptionType,
        ),
      );
    } else if (dp.whichValue() == lk_models.DataPacket_Value.streamChunk) {
      // Data Stream Chunk
      events.emit(
        EngineDataStreamChunkEvent(
          chunk: dp.streamChunk,
          identity: dp.participantIdentity,
          encryptionType: encryptionType,
        ),
      );
    } else if (dp.whichValue() == lk_models.DataPacket_Value.streamTrailer) {
      // Data Stream trailer
      events.emit(
        EngineDataStreamTrailerEvent(
          trailer: dp.streamTrailer,
          identity: dp.participantIdentity,
          encryptionType: encryptionType,
        ),
      );
    } else {
      logger.warning('Unknown data packet type: ${dp.whichValue()}');
    }
  }

  @internal
  Future<void> handleReconnect(
    ClientDisconnectReason reason, {
    lk_models.ReconnectReason? reconnectReason,
    // GRAVIX: retry at once (the server said how: a Leave, or a refused resume)
    bool immediate = false,
  }) async {
    if (_isClosed) {
      logger.fine('handleReconnect: engine is closed, skip');
      return;
    }

    logger.info('onDisconnected state:${connectionState} reason:${reason.name}');

    // GRAVIX (upstream 2.13.0 #1197/#1199): the escalation is decided when the
    // request is made, not when its timer fires: a later request replaces the
    // pending timer AND its reason, so a peer-connection failure followed by the
    // socket close was downgraded to a resume. `leaveReconnect` is not escalated:
    // a Leave{RECONNECT} sets the flag itself, and a Leave{RESUME} (migration)
    // must stay a resume.
    // GRAVIX (2026-10-14, GravixRecoveryOptions.resumeBeforeFullOnNetworkFailure):
    // a connection that FAILED while the phone's network changed gets one resume
    // (its ICE restart) before the full reconnect
    final netFailResume =
        _upstreamReconnectFixes &&
        reason == ClientDisconnectReason.peerConnectionFailed &&
        roomOptions.recovery.resumeBeforeFullOnNetworkFailure &&
        !fullReconnectOnNext &&
        // an attempt already running keeps the queued request: its resume's ICE
        // restart may satisfy it (resumeSatisfiesPeerFailure)
        !_attemptingReconnect &&
        _gravixNetChangedRecently() &&
        !_gravixResumedSinceNetChange();
    if (netFailResume) {
      _gravixNetFailResumeOf = reconnectReason;
      logger.info('a peer connection FAILED during a network change: one resume (ICE restart) first');
    }
    if (_upstreamReconnectFixes &&
        !netFailResume &&
        (reason == ClientDisconnectReason.negotiationFailed || reason == ClientDisconnectReason.peerConnectionFailed)) {
      // GRAVIX (2026-10-11, resumeSatisfiesPeerFailure): a request only peer
      // connection failures made can be satisfied by a resume's ICE restart
      // (see attemptReconnect); one any other source joined cannot
      final pcFailuresOnly =
          reason == ClientDisconnectReason.peerConnectionFailed && (!fullReconnectOnNext || _fullRequestPcFailuresOnly);
      fullReconnectOnNext = true;
      _fullRequestPcFailuresOnly = pcFailuresOnly;
    }

    _isReconnecting = true;

    if (_reconnectAttempts == 0) {
      _reconnectStart = DateTime.timestamp();
    }

    final policy = reconnectPolicy;
    int? nextDelay;
    try {
      nextDelay = policy.nextRetryDelayInMs(
        ReconnectContext(
          retryCount: _reconnectAttempts,
          elapsedMs: DateTime.timestamp().difference(_reconnectStart ?? DateTime.timestamp()).inMilliseconds,
          retryReason: reason.name,
          serverUrl: url,
        ),
      );
    } catch (e) {
      // An error in the app's policy stops reconnecting (React parity).
      logger.warning('reconnect policy threw, stopping: $e');
      nextDelay = null;
    }

    if (nextDelay == null) {
      logger.fine('reconnectAttempts exceeded, disconnecting...');
      _isClosed = true;
      await cleanUp();

      events.emit(EngineDisconnectedEvent(reason: DisconnectReason.reconnectAttemptsExceeded));
      return;
    }

    // Jitter (against a thundering herd) is the policy's job now; the default
    // policy adds it exactly as this code used to.
    // GRAVIX: a reconnect the server asked for (Leave) or a resume it refused
    // goes at once, as the JS SDK does for a Leave.
    final delay = (immediate || reason == ClientDisconnectReason.leaveReconnect || nextDelay < 0) ? 0 : nextDelay;

    events.emit(
      EngineAttemptReconnectEvent(
        attempt: _reconnectAttempts + 1,
        maxAttempts: policy is DefaultReconnectPolicy ? policy.maxAttempts : -1,
        nextRetryDelaysInMs: delay,
      ),
    );

    _clearReconnectTimeout();
    if (token != null && _regionUrlProvider != null) {
      // token may have been refreshed, we do not want to recreate the regionUrlProvider
      // since the current engine may have inherited a regional url
      _regionUrlProvider!.updateToken(token!);
    }
    logger.fine('WebSocket reconnecting in $delay ms, retry times $_reconnectAttempts');
    _reconnectTimeout = Timer(Duration(milliseconds: delay), () async {
      await attemptReconnect(reason, reconnectReason: reconnectReason);
    });
  }

  @internal
  Future<void> attemptReconnect(ClientDisconnectReason reason, {lk_models.ReconnectReason? reconnectReason}) async {
    if (_isClosed) {
      return;
    }

    // guard for attempting reconnection multiple times while one attempt is still not finished
    if (_attemptingReconnect) {
      return;
    }

    final upstreamFixes = _upstreamReconnectFixes;
    if (upstreamFixes) {
      // reason-based escalation happened in handleReconnect; the server switch is
      // config, checked here so the latest ClientConfiguration wins
      if (_clientConfiguration?.resumeConnection == lk_models.ClientConfigSetting.DISABLED) {
        fullReconnectOnNext = true;
      }
    } else if (_clientConfiguration?.resumeConnection == lk_models.ClientConfigSetting.DISABLED ||
        [
          ClientDisconnectReason.leaveReconnect,
          ClientDisconnectReason.negotiationFailed,
          ClientDisconnectReason.peerConnectionFailed,
        ].contains(reason)) {
      fullReconnectOnNext = true;
    }

    // GRAVIX (upstream 2.13.0 #1199): consume the request up front. This
    // attempt's mode is fixed now; a true flag from here on is a NEW request
    // that arrived while it ran (a peer failure mid-resume), dispatched in the
    // finally block instead of being dropped by the guard above.
    final fullReconnect = fullReconnectOnNext;
    if (upstreamFixes) {
      fullReconnectOnNext = false;
      _attemptIsFullReconnect = fullReconnect;
    }

    final gen = _sessionGen;
    var succeeded = false;
    _gravixAttemptStartedAt = DateTime.timestamp(); // GRAVIX (0.4.15, F6)
    _gravixAttemptSignalLost = false; // GRAVIX (2026-10-11, restartAbortsOnSignalLoss)
    // a new attempt owns the publisher now
    _gravixStopPublisherWatch();
    try {
      _attemptingReconnect = true;

      if (await signalClient.networkIsAvailable() == false) {
        _gravixNoteNetTrouble(); // GRAVIX (0.4.15, F6)
        logger.fine('no internet connection, waiting...');
        final probeEvery = roomOptions.recovery.networkWaitProbeInterval;
        if (probeEvery == null) {
          await signalClient.events.waitFor<SignalConnectivityChangedEvent>(
            duration: connectOptions.timeouts.connection * 10,
            filter: (event) => !event.state.contains(ConnectivityResult.none),
            onTimeout: () => throw ConnectException(
              'attemptReconnect: Timed out waiting for SignalConnectivityChangedEvent',
              reason: ConnectionErrorReason.Timeout,
            ),
          );
        } else {
          await _gravixWaitForNetwork(probeEvery, gen);
        }
      }

      // GRAVIX (2026-10-14): every attempt is reported (RoomReconnectAttemptEvent)
      final isFull = upstreamFixes ? fullReconnect : fullReconnectOnNext;
      final sent = isFull ? null : _gravixResumeReasonFor(reconnectReason);
      events.emit(
        EngineReconnectAttemptEvent(
          full: isFull,
          cause: reason.name,
          reconnectReason: sent?.name,
          attempt: _reconnectAttempts + 1,
          afterNetworkChange: _gravixNetChangedRecently(),
        ),
      );
      if (isFull) {
        await restartConnection();
      } else {
        await resumeConnection(reason, reconnectReason: sent);
      }
      _clearPendingReconnect();
      _attemptingReconnect = false;
      _isReconnecting = false;
      _unrecoveredResumes = 0;
      succeeded = true;
      // GRAVIX (2026-10-14, review F1): the transport watch resumes after the
      // reconnect, firstReadDelay later
      _gravixIceWatch.poke();
    } catch (e) {
      if (gen != _sessionGen || _isClosed || (e is GravixResumeRejectedException && e.cancelled)) {
        // GRAVIX(one-session): a fresh connect or a disconnect cancelled this
        // attempt; it owns the session now
        logger.fine('attemptReconnect: cancelled ($e)');
        return;
      }
      // GRAVIX (2026-10-11, restartAbortsOnSignalLoss): a full reconnect that lost
      // its signal socket while the device's network changed failed because of the
      // network, at once; counting it climbed the back-off by one step per Wi-Fi
      // flap (to 7 s) and, after 10 flaps, ended the session. The attempt's own
      // network wait absorbs the outage. With the network steady it counts.
      if (roomOptions.recovery.restartAbortsOnSignalLoss &&
          _gravixAttemptSignalLost &&
          _gravixNetTroubleSince(_gravixAttemptStartedAt)) {
        logger.info('attemptReconnect: the full reconnect lost its signal while the network changed; not counted');
      } else {
        _reconnectAttempts = _reconnectAttempts + 1;
      }
      logger.fine('attemptReconnect: ${fullReconnect ? 'full reconnect' : 'resume'} failed: $e');
      bool recoverable = true;
      var immediate = false;
      if (upstreamFixes && fullReconnect) {
        // a failed full reconnect stays a full reconnect (js / rust parity)
        fullReconnectOnNext = true;
      }
      if (e is GravixResumeRejectedException) {
        // GRAVIX(resume-rejected): the server closed this session (Leave
        // RECONNECT / socket closed before the ReconnectResponse): rejoin now,
        // no second resume. A Leave{RESUME} keeps resuming, also at once.
        logger.info('resume rejected (${e.message}); ${e.full ? 'full reconnect' : 'resume again'} now');
        // with the upstream fixes an escalation is sticky: a Leave{RESUME} does not
        // downgrade a full-reconnect request made while the resume ran
        fullReconnectOnNext = upstreamFixes ? (fullReconnectOnNext || e.full) : e.full;
        immediate = true;
        _unrecoveredResumes = 0;
      } else if (e is WebSocketException &&
          !(upstreamFixes ? fullReconnect : fullReconnectOnNext) &&
          roomOptions.recovery.resumeAfterNetworkSocketError &&
          (_gravixNetChangedRecently() || await _gravixReadsOffline())) {
        // GRAVIX (2026-10-14, resumeAfterNetworkSocketError): the resume's dial
        // failed because the phone's network is changing, not because the
        // session is gone: the next attempt waits for the network and resumes.
        // Two such failures in a row still become a full reconnect.
        if (++_unrecoveredResumes >= _unrecoveredResumesBeforeFull) {
          logger.info('resume dial failed $_unrecoveredResumes times during a network change; full reconnect');
          fullReconnectOnNext = true;
          _unrecoveredResumes = 0;
        } else {
          logger.info('resume dial failed during a network change ($e); resuming again');
        }
      } else if (e is WebSocketException || e is MediaConnectException) {
        // cannot resume connection, need to do full reconnect
        fullReconnectOnNext = true;
      } else if (!(upstreamFixes ? fullReconnect || fullReconnectOnNext : fullReconnectOnNext) &&
          ++_unrecoveredResumes >= _unrecoveredResumesBeforeFull) {
        // GRAVIX (regionReprobeOnRestart, 2026-09-19): a resume against an
        // UNREACHABLE region times out rather than being refused, and upstream
        // keeps resuming. The JS SDK's live test (pinned SFU stopped) showed the
        // re-probe, which only runs on a full reconnect, then never happens.
        // GRAVIX (2026-10-05): for every session, not only with the re-probe: two
        // resume dials that timed out (10 s each) outlast the server's disconnect
        // grace (15 s), so the participant is gone and a third resume can only be
        // refused. Field 2026-10-05: 3-4 resumes before the full rejoin.
        logger.info('resume failed $_unrecoveredResumes times; full reconnect');
        fullReconnectOnNext = true;
        _unrecoveredResumes = 0;
      }

      if (e is UnexpectedConnectionState || e is CertificatePinningException) {
        // certificate pinning failures are deterministic, retrying would only
        // repeat TLS handshakes against an untrusted endpoint
        recoverable = false;
      }

      if (recoverable) {
        unawaited(handleReconnect(ClientDisconnectReason.reconnectRetry, immediate: immediate));
      } else {
        logger.fine('attemptReconnect: disconnecting...');
        // clean up before emitting, room's EngineDisconnectedEvent handler
        // drops the event while fullReconnectOnNext is still true and
        // cleanUp() is what resets it
        await cleanUp();
        events.emit(
          EngineDisconnectedEvent(
            reason: e is CertificatePinningException
                ? DisconnectReason.signalingConnectionFailure
                : DisconnectReason.disconnected,
          ),
        );
      }
    } finally {
      _attemptingReconnect = false;
      _attemptIsFullReconnect = false;
      // GRAVIX (upstream 2.13.0 #1199): a full reconnect requested while this
      // attempt ran, which a successful attempt did not act on: dispatch it now.
      // The failure path retries by itself. Not after a fresh connect or a
      // disconnect took the session over (one-session).
      if (upstreamFixes && succeeded && fullReconnectOnNext && !_isClosed && gen == _sessionGen) {
        if (_fullRequestTransportGen != _gravixTransportGen) {
          // GRAVIX (0.4.15, F4, device r056 / r059): the request was made against
          // peer connections this (full) attempt has replaced -- the old ones
          // reported failed while the attempt waited for the network. The new
          // session satisfies it; dispatching it started a second full rejoin
          // 23 ms after the first one connected.
          logger.info('attemptReconnect: a full reconnect requested against the replaced connections; already done');
          fullReconnectOnNext = false;
        } else {
          final verdict = !fullReconnect && roomOptions.recovery.resumeSatisfiesPeerFailure
              ? _gravixResumePcFailureVerdict()
              : _GravixPcFailureVerdict.dispatch;
          switch (verdict) {
            case _GravixPcFailureVerdict.satisfied:
              // GRAVIX (2026-10-11, resumeSatisfiesPeerFailure; iOS real device,
              // Airplane Mode 5 s, 2/2): the request came from the OLD ICE session
              // failing as the network returned, while this resume started; the
              // resume keeps the same peer connections, so F4 above cannot tell. Its
              // ICE restart brought them back: dispatching it rejoined 1 ms after the
              // resume succeeded and the far side saw the host leave and join again.
              logger.info(
                'attemptReconnect: the peer connection failure mid-resume was satisfied by the resume; no rejoin',
              );
              fullReconnectOnNext = false;
            case _GravixPcFailureVerdict.waitForOther:
              // GRAVIX (2026-10-11, resumePeerRestartWait; iPhone recheck run 3): the
              // primary is back, the other connection's ICE restart is still running
              // (iOS reported it Disconnected 140 ms before the primary connected);
              // rejoining now was the fake leave/join. The request is held aside, not
              // left pending: a Disconnected report of the restarting connection
              // starts a new attempt, which would consume it as a FULL reconnect.
              fullReconnectOnNext = false;
              _gravixWaitForRestartingPc(gen);
            case _GravixPcFailureVerdict.publisherWatch:
              // GRAVIX (2026-10-11, resumePeerRestartWait): the subscriber was enough
              // (nothing unmuted published) and the publisher is still restarting:
              // the publisher watch rejoins if it is not back in time
              logger.info(
                'attemptReconnect: the peer connection failure mid-resume: the publisher is still restarting; '
                'the publisher watch decides',
              );
              fullReconnectOnNext = false;
            case _GravixPcFailureVerdict.dispatch:
              logger.info('attemptReconnect: full reconnect requested mid-attempt, dispatching');
              unawaited(handleReconnect(ClientDisconnectReason.reconnectRetry));
          }
        }
      }
      // GRAVIX (2026-10-14, review F2): the resume given to a FAILED connection
      // during a network change succeeded on the primary alone: the failed
      // non-primary connection gets the bounded wait, then the full reconnect
      final netFail = _gravixNetFailResumeOf;
      if (succeeded || fullReconnect) _gravixNetFailResumeOf = null;
      if (upstreamFixes &&
          succeeded &&
          !fullReconnect &&
          netFail != null &&
          !fullReconnectOnNext &&
          !_isClosed &&
          gen == _sessionGen &&
          _gravixRestartWaitTimer == null) {
        final failedIsPrimary = (netFail == lk_models.ReconnectReason.RR_SUBSCRIBER_FAILED) == _subscriberPrimary;
        final other = _subscriberPrimary ? publisher : subscriber;
        if (!failedIsPrimary && !(other?.pc.connectionState?.isConnected() ?? true)) {
          if (roomOptions.recovery.resumePeerRestartWait > Duration.zero) {
            _gravixWaitForRestartingPc(gen);
          } else {
            logger.info('attemptReconnect: the connection that failed is not back after the resume; full reconnect');
            fullReconnectOnNext = true;
            unawaited(handleReconnect(ClientDisconnectReason.reconnectRetry));
          }
        }
      }
    }
  }

  /// GRAVIX (2026-10-11, resumeSatisfiesPeerFailure): what to do with the
  /// pending full-reconnect request, made while a resume ran that has just
  /// succeeded. It is satisfied by that resume's ICE restart when only peer
  /// connections reporting Failed made it, a peer connection came back AFTER the
  /// last of those reports (a request with no recovery behind it is still
  /// dispatched), and right now the primary is connected and the other
  /// connection is too (or was never used). A connection still restarting
  /// (Connecting / Disconnected: [GravixRecoveryOptions.resumePeerRestartWait])
  /// gets a bounded wait; with the subscriber enough for an idle publisher the
  /// publisher watch decides. A failure of the restarted session (Failed), or a
  /// connection still Failed, keeps the rejoin (#1199). Read from the cached
  /// states: no await here, a new attempt may start as soon as this one ended.
  _GravixPcFailureVerdict _gravixResumePcFailureVerdict() {
    const dispatch = _GravixPcFailureVerdict.dispatch;
    if (!_fullRequestPcFailuresOnly || _fullRequestPcUpSeq == _gravixPcUpSeq) return dispatch;
    bool up(Transport? t) => t?.pc.connectionState?.isConnected() ?? false;
    bool restarting(Transport? t) => const [
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
    ].contains(t?.pc.connectionState);
    final mayWait = roomOptions.recovery.resumePeerRestartWait > Duration.zero;
    if (!up(primary)) {
      // the subscriber was enough ([_gravixWaitPrimaryAfterResume]): the
      // publisher watch is armed and rejoins if the publisher is not back
      final watched = !_subscriberPrimary && _gravixPublisherWatch != null && up(subscriber) && restarting(publisher);
      return mayWait && watched ? _GravixPcFailureVerdict.publisherWatch : dispatch;
    }
    final other = _subscriberPrimary ? publisher : subscriber;
    final otherState = other?.pc.connectionState;
    final otherUnused = otherState == null || otherState == rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew;
    if (otherUnused || up(other)) return _GravixPcFailureVerdict.satisfied;
    return mayWait && restarting(other) ? _GravixPcFailureVerdict.waitForOther : dispatch;
  }

  /// GRAVIX (2026-10-11, resumePeerRestartWait): the bounded wait for the
  /// connection that was still restarting when the resume succeeded. A passive
  /// observer: a new attempt does not stop it (a Disconnected report of the
  /// restarting connection starts one); a full reconnect that replaced the
  /// connections, a fresh connect or a disconnect does.
  Timer? _gravixRestartWaitTimer;
  EventsListener<EngineEvent>? _gravixRestartWaitListener;

  void _gravixWaitForRestartingPc(int gen) {
    _gravixStopRestartWait();
    final bound = roomOptions.recovery.resumePeerRestartWait;
    final subscriberPrimary = _subscriberPrimary;
    final other = subscriberPrimary ? publisher : subscriber;
    if (other == null) return;
    final name = subscriberPrimary ? 'publisher' : 'subscriber';
    final transportGen = _gravixTransportGen;
    final started = DateTime.timestamp();
    bool stale() =>
        _isClosed ||
        gen != _sessionGen ||
        transportGen != _gravixTransportGen ||
        !identical(other, subscriberPrimary ? publisher : subscriber);
    logger.info(
      'attemptReconnect: resumed; the $name connection is still restarting '
      '(${other.pc.connectionState?.name}); waiting up to ${bound.inMilliseconds} ms before a full reconnect',
    );
    final listener = createListener();
    _gravixRestartWaitListener = listener;
    listener.on<EnginePeerStateUpdatedEvent>((_) {
      if (!identical(_gravixRestartWaitListener, listener)) return;
      if (stale()) {
        _gravixStopRestartWait();
        return;
      }
      final state = other.pc.connectionState;
      if (state?.isConnected() ?? false) {
        logger.info(
          'attemptReconnect: the $name connection is back '
          '${DateTime.timestamp().difference(started).inMilliseconds} ms after the resume; '
          'the peer connection failure mid-resume was satisfied by the resume; no rejoin',
        );
        _gravixStopRestartWait();
      } else if (state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        // the restarted session failed: its own onConnectionState handler has
        // requested the reconnect (a Failed escalates to a full one)
        logger.info('attemptReconnect: the $name connection failed after its restart; reconnecting');
        _gravixStopRestartWait();
      }
    });
    _gravixRestartWaitTimer = Timer(bound, () {
      if (!identical(_gravixRestartWaitListener, listener)) return;
      _gravixStopRestartWait();
      if (stale() || (other.pc.connectionState?.isConnected() ?? false)) return;
      // a full reconnect already requested or running acts for it
      if (fullReconnectOnNext || _attemptIsFullReconnect) return;
      logger.info(
        'attemptReconnect: the $name connection is not back ${bound.inMilliseconds} ms after the resume '
        '(${other.pc.connectionState?.name}); full reconnect',
      );
      fullReconnectOnNext = true;
      unawaited(handleReconnect(ClientDisconnectReason.reconnectRetry));
    });
  }

  void _gravixStopRestartWait() {
    _gravixRestartWaitTimer?.cancel();
    _gravixRestartWaitTimer = null;
    final listener = _gravixRestartWaitListener;
    _gravixRestartWaitListener = null;
    unawaited(listener?.dispose());
  }

  Future<void> resumeConnection(ClientDisconnectReason reason, {lk_models.ReconnectReason? reconnectReason}) async {
    if (_isClosed) {
      return;
    }

    events.emit(const EngineResumingEvent());
    _gravixLastResumeAt = DateTime.timestamp(); // GRAVIX (2026-10-14)

    final recovery = roomOptions.recovery;
    // GRAVIX (0.4.15, F1 root cause, device r023 / r025 / r032): the subscriber
    // holds remote candidates from NOW until the server's ICE-restart offer is
    // applied (setRemoteDescription clears the flag and adds them). Upstream set
    // it after the ReconnectResponse, the publisher offer and
    // getConnectionState(); by then the server's one restart offer was often
    // applied already, so every later trickle candidate waited in the pending
    // list forever and the phone kept pairing with the OLD server candidate
    // ("bad remote username" x22-24) until the resume timed out. Set before the
    // resume request goes out (livekit-client JS order), it also holds the
    // candidates that race ahead of the offer instead of adding them against the
    // old remote description.
    subscriber?.restartingIce = true;
    final abort = Completer<GravixResumeRejectedException>();
    _resumeAbort = abort;
    _resumeAnswered = false;
    // GRAVIX (0.4.15, F2): with leaveAbortsResumeWait the abort also covers the
    // wait for the primary connection below (released at the end)
    var keepAbort = false;
    try {
      // wait for socket to connect rtc server
      try {
        await signalClient.connect(
          url!,
          token!,
          connectOptions: connectOptions,
          roomOptions: roomOptions,
          reconnect: true,
          reconnectReason: _gravixResumeReasonFor(reconnectReason),
        );
      } catch (_) {
        // a Leave that arrived before the server closed the socket says why
        if (abort.isCompleted) throw await abort.future;
        rethrow;
      }
      if (abort.isCompleted) throw await abort.future;

      // GRAVIX(resume-rejected): the ReconnectResponse, or the server's refusal,
      // whichever comes first. The socket is open here, so no answer within the
      // timeout is a refusal too (the server answers a resume it accepts at once).
      final reconnected = events.waitFor<SignalReconnectedEvent>(
        duration: connectOptions.timeouts.connection,
        onTimeout: () => throw GravixResumeRejectedException('no ReconnectResponse within the connect timeout'),
      );
      final outcome = await Future.any<Object?>([reconnected, abort.future]);
      if (outcome is GravixResumeRejectedException) {
        reconnected.ignore();
        throw outcome;
      }
      _resumeAnswered = true;
      keepAbort = recovery.leaveAbortsResumeWait;
    } finally {
      if (!keepAbort && identical(_resumeAbort, abort)) _resumeAbort = null;
    }
    try {
      await _gravixResumeMedia(reason, abort: keepAbort ? abort : null);
    } finally {
      if (identical(_resumeAbort, abort)) _resumeAbort = null;
    }
  }

  /// GRAVIX (0.4.15): the media half of [resumeConnection], after the
  /// ReconnectResponse. [abort] (F2): a Leave or a closed socket during the wait
  /// for the primary ends it at once (field r029: a Leave{RESUME} 87 ms after
  /// the ReconnectResponse, then 10 s of "Waiting for primary to connect...").
  Future<void> _gravixResumeMedia(
    ClientDisconnectReason reason, {
    Completer<GravixResumeRejectedException>? abort,
  }) async {
    void checkAbort() {
      if (abort != null && abort.isCompleted) throw _gravixAbortReason!;
    }

    logger.fine('resumeConnection: reason: ${reason.name}');

    if (_hasPublished) {
      logger.fine('resumeConnection: negotiating publisher...');
      await publisher!.createAndSendOffer(const RTCOfferOptions(iceRestart: true));
    }
    checkAbort();

    final isConnected = (await primary?.pc.getConnectionState())?.isConnected() ?? false;

    logger.fine('resumeConnection: primary is connected: $isConnected');
    checkAbort();

    if (!isConnected) {
      // (subscriber.restartingIce was set before the resume request: see
      // resumeConnection; setting it here, after the restart offer may already
      // be applied, is what stranded the candidates)
      logger.fine('resumeConnection: Waiting for primary to connect...');
      await _gravixWaitPrimaryAfterResume(abort: abort);
      logger.fine('resumeConnection: primary connected (or the subscriber is enough)');
    }
    checkAbort();

    // GRAVIX (upstream 2.13.0 #1199): the socket can drop while the peer
    // connections were being restored. Reporting that as resumed cancelled the
    // retry the drop needed and dropped every trickle candidate of the ICE
    // restart; it is a failure the retry path resumes again.
    if (_upstreamReconnectFixes && signalClient.connectionState != ConnectionState.connected) {
      throw ConnectException(
        'resumeConnection: signal connection severed during resume',
        reason: ConnectionErrorReason.InternalError,
      );
    }

    await _gravixSendHeldOffer();

    _isReconnecting = false;
    events.emit(const EngineResumedEvent());
  }

  /// GRAVIX (0.4.15, BUG-3): a renegotiation held while the resume dialled
  /// (Transport.gravixHoldOffers) normally goes out after the restart answer
  /// (Transport.setRemoteDescription). When nothing will answer any more -- no
  /// restart offer was made, or its answer was applied before the hold was
  /// marked -- it would wait for the next unrelated negotiation: send it now.
  Future<void> _gravixSendHeldOffer() async {
    final p = publisher;
    if (p == null || p.gravixHoldOffers == null || !p.renegotiate) return;
    // an answer still pending replays it when it lands
    if (await p.pc.getSignalingState() != rtc.RTCSignalingState.RTCSignalingStateStable) return;
    p.renegotiate = false;
    logger.fine('resumeConnection: sending the renegotiation held during the resume');
    p.negotiate(null);
  }

  /// GRAVIX (0.4.15, S3/R2): the resume's wait for the primary connection.
  ///
  /// Field 2026-10-09 03:50:01: the publisher was primary (a muted mic was
  /// published); the subscriber connection was back in 0.7 s, the publisher's
  /// ICE restart never completed ("bad remote username" x22), and the resume
  /// waited Timeouts.peerConnection (10 s) before a full rejoin. Now, publisher
  /// primary only:
  ///  - [GravixRecoveryOptions.publisherRestartRetryAfter]: the subscriber is
  ///    connected and the publisher is not -> ONE fresh publisher ICE-restart
  ///    offer, and only from a stable signaling state (never a second offer on
  ///    top of an unanswered one: the server re-keys a restart offer that
  ///    arrives while it gathers, the suspected cause of the bad ufrag);
  ///  - [GravixRecoveryOptions.subscriberSufficientWhenIdle]: nothing unmuted
  ///    published -> the subscriber connection is enough to call the session
  ///    resumed; the publisher keeps recovering ([_gravixWatchPublisher]).
  /// Both off (or subscriber primary): the upstream wait, unchanged.
  Future<void> _gravixWaitPrimaryAfterResume({Completer<GravixResumeRejectedException>? abort}) async {
    final recovery = roomOptions.recovery;
    final timeout = connectOptions.timeouts.peerConnection;
    final publisherPrimary = !_subscriberPrimary;
    final retryAfter = publisherPrimary ? recovery.publisherRestartRetryAfter : null;
    final idleOk = publisherPrimary && recovery.subscriberSufficientWhenIdle && gravixHasUnmutedLocalMedia != null;
    // GRAVIX (0.4.15, F1, field r023): the primary not connected this long after
    // the ReconnectResponse while the signal is up -> a full rejoin now instead
    // of after Timeouts.peerConnection. A healthy ICE restart takes well under a
    // second; r023 never completed (the server's agent and the applied offer
    // disagreed on the ufrag) and the viewer sat 10 s in the dark. With a fresh
    // publisher restart pending ([publisherRestartRetryAfter]) the deadline
    // counts from that restart's due time.
    final deadlineAfter = recovery.resumePrimaryDeadline;
    final escalateAfter = deadlineAfter == null ? null : (retryAfter ?? Duration.zero) + deadlineAfter;
    if (retryAfter == null && !idleOk && escalateAfter == null && abort == null) {
      await events.waitFor<EnginePeerStateUpdatedEvent>(
        filter: (event) => event.isPrimary && event.state.isConnected(),
        duration: timeout,
        onTimeout: () =>
            throw MediaConnectException('resumeConnection: Timed out waiting for EnginePeerStateUpdatedEvent'),
      );
      return;
    }

    final started = DateTime.timestamp();
    final done = Completer<bool>(); // true: the primary connected; false: the subscriber is enough
    var retryDue = false;
    var retrySent = false;
    var checking = false;
    Future<bool> isConnected(Transport? t) async => (await t?.pc.getConnectionState())?.isConnected() ?? false;

    Future<void> check() async {
      if (done.isCompleted || checking) return;
      checking = true;
      try {
        if (await isConnected(primary)) {
          if (!done.isCompleted) done.complete(true);
          return;
        }
        if (!publisherPrimary) return; // the subscriber is the primary: nothing else to do but wait
        final subscriberUp = await isConnected(subscriber);
        if (!subscriberUp) return;
        if (idleOk && !(gravixHasUnmutedLocalMedia?.call() ?? true)) {
          logger.info('resume: nothing unmuted published; the subscriber connection is enough');
          if (!done.isCompleted) done.complete(false);
          return;
        }
        if (retryDue && !retrySent && publisher != null) {
          final signaling = await publisher!.pc.getSignalingState();
          if (signaling == rtc.RTCSignalingState.RTCSignalingStateStable && !done.isCompleted) {
            retrySent = true;
            logger.info('resume: subscriber connected, publisher not: one fresh publisher ICE restart');
            try {
              await publisher!.createAndSendOffer(const RTCOfferOptions(iceRestart: true));
            } catch (e) {
              logger.warning('resume: the fresh publisher ICE restart failed: $e');
            }
          }
        }
      } finally {
        checking = false;
      }
    }

    final listener = createListener();
    listener.on<EnginePeerStateUpdatedEvent>((_) => check());
    Timer? retryTicker;
    if (retryAfter != null) {
      retryTicker = Timer(retryAfter, () {
        retryDue = true;
        unawaited(check());
        // the subscriber may come back, or the signaling settle, later
        retryTicker = Timer.periodic(const Duration(milliseconds: 250), (t) {
          if (retrySent || done.isCompleted) {
            t.cancel();
          } else {
            unawaited(check());
          }
        });
      });
    }
    final deadline = Timer(timeout, () {
      if (!done.isCompleted) {
        done.completeError(
          MediaConnectException('resumeConnection: Timed out waiting for EnginePeerStateUpdatedEvent'),
        );
      }
    });
    final escalate = escalateAfter == null || escalateAfter >= timeout
        ? null
        : Timer(escalateAfter, () {
            if (done.isCompleted) return;
            logger.warning(
              'resume: the primary connection is not back ${escalateAfter.inMilliseconds} ms after the '
              'ReconnectResponse; full rejoin now',
            );
            done.completeError(
              MediaConnectException('resumeConnection: primary not connected within $escalateAfter (rejoining early)'),
            );
          });
    // F2: a Leave / a closed socket ends the wait at once
    unawaited(
      abort?.future.then((reason) {
        if (!done.isCompleted) done.completeError(reason);
      }),
    );
    try {
      unawaited(check());
      final viaPrimary = await done.future;
      if (!viaPrimary) {
        final elapsed = DateTime.timestamp().difference(started);
        final left = timeout - elapsed;
        // the field case (a muted mic published) is exactly this branch: the
        // publisher still gets its one fresh ICE restart while it recovers
        final retryIn = retryAfter == null || retrySent ? null : retryAfter - elapsed;
        _gravixWatchPublisher(
          left.isNegative ? Duration.zero : left,
          retryIn: retryIn == null ? null : (retryIn.isNegative ? Duration.zero : retryIn),
        );
      }
    } finally {
      retryTicker?.cancel();
      deadline.cancel();
      escalate?.cancel();
      await listener.dispose();
    }
  }

  /// GRAVIX (0.4.15): set while a resumed session waits for its publisher
  /// connection (the subscriber was enough, [_gravixWaitPrimaryAfterResume]).
  /// Data sends wait on it: the data channels live on the publisher connection.
  Completer<void>? _gravixPublisherRecovery;
  Timer? _gravixPublisherWatch;
  EventsListener<EngineEvent>? _gravixPublisherWatchListener;

  /// The publisher keeps recovering after the resume; still not connected after
  /// [left] (the rest of Timeouts.peerConnection) -> a reconnect as a failed
  /// peer connection (a full rejoin): what 0.4.14 did at that moment, but the
  /// video has been back since the subscriber reconnected.
  void _gravixWatchPublisher(Duration left, {Duration? retryIn}) {
    _gravixStopPublisherWatch();
    final recovery = Completer<void>();
    _gravixPublisherRecovery = recovery;
    final listener = createListener();
    _gravixPublisherWatchListener = listener;
    listener.on<EnginePublisherPeerStateUpdatedEvent>((event) {
      if (event.state.isConnected()) {
        logger.info('resume: the publisher connection is back');
        _gravixStopPublisherWatch();
      }
    });
    if (retryIn != null) {
      // [publisherRestartRetryAfter], continued: one fresh publisher ICE restart,
      // only from a stable signaling state (polled until then)
      var sent = false;
      var busy = false;
      Future<void> tryRetry(Timer? ticker) async {
        if (sent || busy || !identical(_gravixPublisherRecovery, recovery)) {
          ticker?.cancel();
          return;
        }
        busy = true;
        try {
          final pub = publisher;
          if (pub == null || ((await pub.pc.getConnectionState())?.isConnected() ?? false)) {
            sent = true;
            return;
          }
          if (await pub.pc.getSignalingState() != rtc.RTCSignalingState.RTCSignalingStateStable) return;
          sent = true;
          logger.info('resume: publisher still not connected: one fresh publisher ICE restart');
          try {
            await pub.createAndSendOffer(const RTCOfferOptions(iceRestart: true));
          } catch (e) {
            logger.warning('resume: the fresh publisher ICE restart failed: $e');
          }
        } finally {
          busy = false;
          if (sent) ticker?.cancel();
        }
      }

      _gravixPublisherRetry = Timer(retryIn, () {
        unawaited(tryRetry(null));
        _gravixPublisherRetry = Timer.periodic(const Duration(milliseconds: 250), (t) => unawaited(tryRetry(t)));
      });
    }
    _gravixPublisherWatch = Timer(left, () async {
      if (_isClosed || connectionState != ConnectionState.connected) {
        _gravixStopPublisherWatch();
        return;
      }
      if ((await publisher?.pc.getConnectionState())?.isConnected() ?? false) {
        _gravixStopPublisherWatch();
        return;
      }
      logger.warning('resume: the publisher connection did not recover; reconnecting');
      // the reconnect first (its synchronous start marks the engine reconnecting),
      // then release the data sends waiting on the publisher: they are buffered
      // for the reconnect instead of written into the dead channel
      final reconnecting = handleReconnect(
        ClientDisconnectReason.peerConnectionFailed,
        reconnectReason: lk_models.ReconnectReason.RR_PUBLISHER_FAILED,
      );
      _gravixStopPublisherWatch();
      await reconnecting;
    });
  }

  Timer? _gravixPublisherRetry;

  void _gravixStopPublisherWatch() {
    _gravixPublisherRetry?.cancel();
    _gravixPublisherRetry = null;
    _gravixPublisherWatch?.cancel();
    _gravixPublisherWatch = null;
    unawaited(_gravixPublisherWatchListener?.dispose());
    _gravixPublisherWatchListener = null;
    final recovery = _gravixPublisherRecovery;
    _gravixPublisherRecovery = null;
    if (recovery != null && !recovery.isCompleted) recovery.complete();
  }

  /// GRAVIX (2026-10-21, per-region media): moves the session to [url] through
  /// the reconnect machinery (JS `gravixRestartTo`, Android
  /// `gravixRestartConnection`): a full reconnect whose first dial is [url]. A
  /// failed dial is the reconnect's to handle (region failover, retry, back-off),
  /// never a dead session. False when the engine is closed, has no session, or a
  /// reconnect is already under way (it owns the session).
  @internal
  bool gravixRestartTo(String url) {
    if (_isClosed || this.url == null || token == null || gravixReconnectInProgress || isPendingReconnect) {
      return false;
    }
    _gravixRestartUrl = url;
    fullReconnectOnNext = true;
    unawaited(handleReconnect(ClientDisconnectReason.mediaRefusal, immediate: true));
    return true;
  }

  @internal
  Future<void> restartConnection({String? regionUrl}) async {
    // GRAVIX (0.4.15): this call is the same-url retry of a failed full reconnect
    final gravixSameUrlRetry = _gravixSameUrlRetryNext;
    _gravixSameUrlRetryNext = false;
    // GRAVIX (2026-10-21): a move asked for by gravixRestartTo, once; a ladder
    // step (a url handed in) drops it
    final gravixMoveTo = _gravixRestartUrl;
    _gravixRestartUrl = null;
    if (regionUrl == null && gravixMoveTo != null) {
      logger.info('full reconnect: media move to $gravixMoveTo');
      regionUrl = gravixMoveTo;
    }
    if (_isClosed) {
      return;
    }
    final recovery = roomOptions.recovery;
    // the url the session was on (connect() overwrites [url] at its start)
    final sessionUrl = url;
    final enteredWithRegion = regionUrl != null;
    if (!enteredWithRegion && !gravixSameUrlRetry && !_attemptingReconnect) {
      _gravixAttemptStartedAt = DateTime.timestamp(); // a restart outside an attempt
    }

    try {
      _gravixSessionReplaced(); // GRAVIX (0.4.15, F4)
      // GRAVIX (2026-10-14, review F1/F7): the replaced session's watch ends here;
      // the new one starts after the rejoin completed
      _gravixIceWatch.stop();
      events.emit(const EngineFullRestartingEvent());

      // GRAVIX: a full reconnect re-probes when asked to, instead of re-joining
      // the region the session was on. Only for a restart that names no region:
      // one handed in below is already the ladder's answer.
      if (regionUrl == null) {
        final reprobed = await restartRegionStrategy?.getRestartUrl();
        if (reprobed != null && reprobed != url) {
          logger.info('full reconnect re-probed regions; moving to $reprobed');
          regionUrl = reprobed;
        }
      }

      if (signalClient.connectionState == ConnectionState.connected) {
        // GRAVIX(one-session): tell the server this session is over before the new
        // join (JS parity). Otherwise the old session lives on until the new join
        // evicts it as a DUPLICATE_IDENTITY -- across nodes, that moved the room's
        // origin (field 2026-10-05).
        await signalClient.sendLeave();
        await signalClient.cleanUp();
      }

      await publisher?.dispose();
      publisher = null;

      _resetPublisherConnection();

      await subscriber?.dispose();
      subscriber = null;

      _reliableDCSub = null;
      _reliableDCPub = null;
      _lossyDCSub = null;
      _lossyDCPub = null;

      await _signalListener.cancelAll();

      _signalListener = signalClient.createListener(synchronized: true);
      _setUpSignalListeners();

      // GRAVIX (2026-10-11, restartAbortsOnSignalLoss): this restart's signal
      // socket closing fails the restart at once (RECHECK Wi-Fi flapping, 9/9
      // runs: the restart lost its socket and waited 10 s for the primary, or 10 s
      // for the publisher whose offer could not be sent)
      final signalLost = recovery.restartAbortsOnSignalLoss ? Completer<void>() : null;
      _gravixRestartSignalLost = signalLost;
      try {
        _inRestart = true;
        // GRAVIX (0.4.15): the same-url retry dials with a short timeout
        _gravixNextDialTimeout = gravixSameUrlRetry ? recovery.sameUrlRetryDialTimeout : null;
        try {
          await connect(
            regionUrl ?? url!,
            token!,
            roomOptions: roomOptions,
            connectOptions: connectOptions,
            fastConnectOptions: fastConnectOptions,
          );
        } finally {
          _inRestart = false;
        }

        if (_hasPublished) {
          await _gravixUnlessSignalLost(ensurePublisherConnected(), 'the publisher connection');
        }
      } finally {
        if (identical(_gravixRestartSignalLost, signalLost)) _gravixRestartSignalLost = null;
      }

      // GRAVIX (upstream 2.13.0 #1199): with the fixes the request that started
      // this restart was consumed; a true flag now is a NEW request (a
      // Leave{RECONNECT} from the node just joined) that attemptReconnect
      // dispatches, so it is not cleared here.
      if (!_upstreamReconnectFixes) fullReconnectOnNext = false;
      _regionUrlProvider?.resetAttempts();
      events.emit(const EngineRestartedEvent());
    } catch (error) {
      // Certificate pinning failures skip region failover. The pin set is
      // client-wide config, so every region would be validated against the
      // same pins and each attempt is another TLS handshake with an endpoint
      // that already failed validation. Initial connect behaves the same way,
      // room.connect only fails over on WebSocketException/ConnectException.
      if (error is CertificatePinningException) {
        _regionUrlProvider?.resetAttempts();
        rethrow;
      }
      // GRAVIX (0.4.15, field 2026-10-09): a full reconnect that failed at the
      // url the session is on tries it once more, with a short dial, before it
      // leaves: a short path drop must not move the session to another region
      // for the rest of its life. Not after a refusal (401/403: the token).
      final atSessionUrl = !enteredWithRegion && (regionUrl ?? sessionUrl) == sessionUrl;
      final refused = error is ConnectException && error.reason == ConnectionErrorReason.NotAllowed;
      if (recovery.retrySameUrlFirst && atSessionUrl && !gravixSameUrlRetry && !refused && sessionUrl != null) {
        logger.info('full reconnect at $sessionUrl failed ($error); retrying it once before another region');
        _gravixSameUrlRetryNext = true;
        await restartConnection(regionUrl: sessionUrl);
        return;
      }
      final nextRegionUrl =
          await restartRegionStrategy?.getNextUrl() ??
          await _regionUrlProvider?.getNextBestRegionUrl(
            currentUrl: url,
            measuredOrder: recovery.measuredRegionFailover,
            // GRAVIX (2026-10-11, boundedSignalConnect): soak 2026-10-11, the
            // guest's fetch of the region list waited 31 s for the OS
            fetchTimeout: recovery.boundedSignalConnect ? connectOptions.timeouts.connection : null,
            // GRAVIX (2026-10-11, lastGoodRegionList): the list comes from the
            // connect url, usually the region that just failed; EMU-OLD: that
            // fetch failing ended every attempt, 0 of 9 runs left a dead blr1
            lastGoodFallback: recovery.lastGoodRegionList,
            currentUrlFailed: !refused,
          );
      if (nextRegionUrl != null) {
        // GRAVIX (0.4.15, F6, device r127 / r149): leaving the session's url
        // needs evidence that the region failed; the PHONE's flapping Wi-Fi moved
        // a blr1 viewer to sgp1 for good. Without it the same url is retried
        // (the reconnect back-off and the network wait).
        final leavingSessionUrl = atSessionUrl || gravixSameUrlRetry;
        if (leavingSessionUrl &&
            recovery.failoverNeedsEvidence &&
            !refused &&
            sessionUrl != null &&
            !await _gravixRegionFailed(sessionUrl, nextRegionUrl)) {
          logger.info(
            'full reconnect at $sessionUrl failed ($error), but nothing shows the region failed '
            '(the device network changed, or the server answers): staying on it',
          );
          _regionUrlProvider?.resetAttempts();
          // GRAVIX (2026-10-11, silentHostFailFast): staying: the next attempt races
          // its dial again (a slow path, not a dead host)
          signalClient.gravixForgetSilentHost();
          rethrow;
        }
        await restartConnection(regionUrl: nextRegionUrl);
        return;
      } else {
        // no more regions to try (or we're not on cloud)
        _regionUrlProvider?.resetAttempts();
        // GRAVIX (2026-10-11, silentHostFailFast): nowhere else to go: the next
        // attempt races its dial again
        signalClient.gravixForgetSilentHost();
        rethrow;
      }
    }
  }

  @internal
  Future<void> sendSyncState({
    required lk_rtc.UpdateSubscription subscription,
    required Iterable<lk_rtc.TrackPublishedResponse>? publishTracks,
    required List<String> trackSidsDisabled,
  }) async {
    final previousAnswer = (await subscriber?.pc.getLocalDescription())?.toPBType();
    final previousOffer = (await subscriber?.pc.getRemoteDescription())?.toPBType();

    // Build data channel receive states for reliability
    final dataChannelReceiveStates = <lk_rtc.DataChannelReceiveState>[];
    for (final participantId in List.of(_reliableReceivedState.keys)) {
      final lastSequence = _reliableReceivedState.get(participantId);
      if (lastSequence != null) {
        final receiveState = lk_rtc.DataChannelReceiveState();
        receiveState.publisherSid = participantId;
        receiveState.lastSeq = lastSequence;
        dataChannelReceiveStates.add(receiveState);
      }
    }
    signalClient.sendSyncState(
      answer: previousAnswer,
      offer: previousOffer,
      subscription: subscription,
      publishTracks: publishTracks,
      dataChannelInfo: dataChannelInfo(),
      trackSidsDisabled: trackSidsDisabled,
      dataChannelReceiveStates: dataChannelReceiveStates,
    );
  }

  void _setUpEngineListeners() => events.on<SignalReconnectedEvent>((event) async {
    // send queued requests if engine re-connected
    signalClient.sendQueuedRequests();
  });

  void _setUpSignalListeners() => _signalListener
    ..on<SignalJoinResponseEvent>((event) async {
      // create peer connections
      _subscriberPrimary = event.response.subscriberPrimary;
      _serverInfo = event.response.serverInfo;
      final iceServersFromServer = event.response.iceServers.map((e) => e.toSDKType()).toList();

      if (iceServersFromServer.isNotEmpty) {
        _serverProvidedIceServers = iceServersFromServer;
      }

      _clientConfiguration = event.response.clientConfiguration;

      logger.fine(
        'onConnected subscriberPrimary: ${_subscriberPrimary}, '
        'serverVersion: ${event.response.serverVersion}, '
        'iceServers: ${event.response.iceServers}, '
        'forceRelay: ${event.response.clientConfiguration.forceRelay}',
      );

      final rtcConfiguration = await _buildRtcConfiguration(
        serverResponseForceRelay: event.response.clientConfiguration.forceRelay,
        serverProvidedIceServers: _serverProvidedIceServers,
      );

      if (publisher == null && subscriber == null) {
        await _createPeerConnections(rtcConfiguration);
      }

      if (!_subscriberPrimary || event.response.fastPublish) {
        _enabledPublishCodecs = event.response.enabledPublishCodecs;

        /// for subscriberPrimary, we negotiate when necessary (lazy)
        /// and if `response.fastPublish == true`, we need to negotiate
        /// immediately
        final hold = gravixFullReconnectInProgress ? null : gravixJoinOfferHold;
        if (hold == null) {
          await negotiate();
        } else {
          // GRAVIX (2026-10-12, fast publish): the join's microphone makes this
          // offer (see gravixJoinOfferHold). Not awaited: the JoinResponse is
          // handled on (the room creates its participants meanwhile). Only on
          // the publisher it was held for: a failed attempt's late release must
          // not negotiate the next attempt's connection.
          final heldFor = publisher;
          unawaited(
            hold().then((tookOver) async {
              if (tookOver || _isClosed || publisher == null || !identical(publisher, heldFor)) return;
              await negotiate();
            }),
          );
        }
      }

      events.emit(EngineJoinResponseEvent(response: event.response));
    })
    ..on<SignalReconnectResponseEvent>((event) async {
      final iceServersFromServer = event.response.iceServers.map((e) => e.toSDKType()).toList();

      if (iceServersFromServer.isNotEmpty) {
        _serverProvidedIceServers = iceServersFromServer;
      }

      _clientConfiguration = event.response.clientConfiguration;

      logger.fine(
        'Handle ReconnectResponse: '
        'iceServers: ${event.response.iceServers}, '
        'forceRelay: ${event.response.clientConfiguration.forceRelay}, '
        'lastMessageSeq: ${event.response.lastMessageSeq}',
      );

      final rtcConfiguration = await _buildRtcConfiguration(
        serverResponseForceRelay: event.response.clientConfiguration.forceRelay,
        serverProvidedIceServers: _serverProvidedIceServers,
      );

      await publisher?.pc.setConfiguration(rtcConfiguration.toMap());
      await subscriber?.pc.setConfiguration(rtcConfiguration.toMap());

      if (!_subscriberPrimary) {
        await negotiate();
      }

      // Handle reliable message resending
      if (event.response.hasLastMessageSeq()) {
        await _resendReliableMessagesForResume(event.response.lastMessageSeq);
      }

      events.emit(const SignalReconnectedEvent());
    })
    ..on<SignalConnectedEvent>((event) async {
      logger.fine('Signal connected');
      // GRAVIX: not during a reconnect -- a resume whose socket opens and is then
      // refused reset the count every time, so maxAttempts was never reached.
      // A reconnect that succeeds resets it in attemptReconnect.
      if (!_isReconnecting) _reconnectAttempts = 0;
      events.emit(const EngineConnectedEvent());
    })
    ..on<SignalConnectingEvent>((event) async {
      logger.fine('Signal connecting');
      events.emit(const EngineConnectingEvent());
    })
    ..on<SignalReconnectingEvent>((event) async {
      logger.fine('Signal reconnecting');
      events.emit(const EngineReconnectingEvent());
    })
    ..on<SignalDisconnectedEvent>((event) async {
      logger.fine('Signal disconnected ${event.reason}');
      if (gravixResumeInFlight) {
        // GRAVIX(resume-rejected): the server closed the resume's socket before
        // its ReconnectResponse: the session is gone. (0.4.15, F2) After it, while
        // waiting for the primary connection: the resume is retried at once (the
        // upstream "severed resume" rule, without the 10 s wait).
        _abortResume(
          _resumeAnswered
              ? GravixResumeRejectedException('socket closed while waiting for the primary connection', full: false)
              : GravixResumeRejectedException('socket closed before the ReconnectResponse'),
        );
        return;
      }
      // GRAVIX (2026-10-11, restartAbortsOnSignalLoss): the full reconnect's own
      // socket closed: nothing it waits for (JoinResponse, the peer connections'
      // offers and answers) can arrive any more. It used to wait 10 s anyway.
      final restartLost = _gravixRestartSignalLost;
      if (restartLost != null && !restartLost.isCompleted && event.reason == DisconnectReason.disconnected) {
        logger.info('Signal disconnected during the full reconnect; failing it now');
        _gravixAttemptSignalLost = true;
        restartLost.complete();
        return;
      }
      if (_attemptingReconnect || isPendingReconnect) {
        // GRAVIX: a reconnect is already under way and owns the retry; scheduling
        // here again would replace its (possibly immediate) retry with the
        // back-off's delay
        logger.fine('Signal disconnected during a reconnect; the reconnect handles it');
        return;
      }
      if (event.reason == DisconnectReason.disconnected && !_isClosed) {
        await handleReconnect(
          ClientDisconnectReason.signal,
          reconnectReason: lk_models.ReconnectReason.RR_SIGNAL_DISCONNECTED,
        );
      }
      // signalingConnectionFailure is intentionally not relayed as
      // EngineDisconnectedEvent here. The signal client emits it while the
      // connect() call is failing, so connect()'s own catch (initial connect)
      // or attemptReconnect (reconnect) already emits the engine event, and
      // relaying here produced a duplicate disconnect per failure.
    })
    ..on<SignalOfferEvent>((event) async {
      if (subscriber == null) {
        logger.warning('[$objectId] subscriber is null');
        return;
      }
      _gravixMark('offerReceived', event.sd.sdp); // GRAVIX
      final signalingState = await subscriber!.pc.getSignalingState();
      _gravixMark('signalingStateRead'); // GRAVIX
      logger.fine(
        '[$objectId] Received server offer(type: ${event.sd.type}, '
        '$signalingState)',
      );
      logger.finer('sdp: ${GravixPubLog.describe(event.sd.type, event.sd.sdp)}'); // GRAVIX: never the body

      await subscriber!.setRemoteDescription(event.sd);
      _gravixMark('setRemoteDescriptionDone'); // GRAVIX

      try {
        // GRAVIX: upstream did createAnswer -> setLocalDescription -> sendAnswer
        // inline here. Same three calls, same order when [gravixFastAnswer] is
        // false (the default); the order lives in gravixAnswerSubscriberOffer so
        // it can be tested without a native peer connection.
        await gravixAnswerSubscriberOffer<rtc.RTCSessionDescription>(
          fastAnswer: gravixFastAnswer,
          createAnswer: () async {
            var answer = await subscriber!.pc.createAnswer();
            // GRAVIX(viewer-fast-start): the phone is the DTLS server of the
            // subscriber connection; see GravixViewerFastStart.passiveSubscriberDtls.
            final sdp = answer.sdp;
            if (GravixViewerFastStart.passiveSubscriberDtls && sdp != null) {
              answer = rtc.RTCSessionDescription(gravixPassiveDtlsAnswer(sdp), answer.type);
            }
            logger.fine('Created answer');
            logger.finer('sdp: ${GravixPubLog.describe(answer.type, answer.sdp)}');
            return answer;
          },
          setLocalDescription: (answer) => subscriber!.pc.setLocalDescription(answer),
          sendAnswer: signalClient.sendAnswer,
          mark: _gravixMark,
        );
      } catch (e) {
        // GRAVIX: a refused answer shows in the join timeline (never an SDP body)
        _gravixMark('answerFailed', GravixPubLog.safeError(e));
        logger.severe('[$objectId] Failed to createAnswer(): ${GravixPubLog.safeError(e)}');
      }
    })
    ..on<SignalAnswerEvent>((event) async {
      if (publisher == null) {
        return;
      }
      logger.fine('received answer (type: ${event.sd.type})');
      logger.finer('sdp: ${GravixPubLog.describe(event.sd.type, event.sd.sdp)}');
      await publisher!.setRemoteDescription(event.sd);
    })
    ..on<SignalTrickleEvent>((event) async {
      if (publisher == null || subscriber == null) {
        logger.warning('Received ${SignalTrickleEvent} but publisher or subscriber was null.');
        return;
      }
      logger.fine('got ICE candidate from peer (target: ${event.target})');
      if (event.target == lk_rtc.SignalTarget.SUBSCRIBER) {
        await subscriber!.addIceCandidate(event.candidate);
      } else if (event.target == lk_rtc.SignalTarget.PUBLISHER) {
        await publisher!.addIceCandidate(event.candidate);
      }
    })
    ..on<SignalLocalTrackSubscribedEvent>((event) async {
      events.emit(EngineLocalTrackSubscribedEvent(trackSid: event.trackSid));
    })
    ..on<SignalTokenUpdatedEvent>((event) {
      logger.fine('Server refreshed the token');
      token = event.token;
    })
    ..on<SignalLeaveEvent>((event) async {
      logger.fine('[Signal] Leave received, action: ${event.action}, reason: ${event.reason}');
      if (event.regions != null && _regionUrlProvider != null) {
        logger.fine('updating regions');
        _regionUrlProvider?.setServerReportedRegions(event.regions!);
      }
      // Protocol v13: LeaveRequest.action replaces the deprecated canReconnect boolean.
      // canReconnect is still checked for backward compatibility with v12 servers
      // (where action defaults to DISCONNECT=0 since it's unset).
      // GRAVIX(resume-rejected): a Leave that answers a resume in flight fails that
      // resume now; attemptReconnect then reconnects as the action says, at once.
      // (Upstream scheduled a reconnect here that the attemptReconnect guard
      // dropped, and the resume sat out its 10 s timeout.)
      final resuming = gravixResumeInFlight;
      if (event.action == lk_rtc.LeaveRequest_Action.RESUME) {
        // GRAVIX (upstream 2.13.0 #1197): with the fixes the flag is left alone:
        // an escalation from an already-failed resume must not be downgraded here
        if (!_upstreamReconnectFixes) fullReconnectOnNext = false;
        if (resuming) {
          _abortResume(GravixResumeRejectedException('Leave{RESUME} during the resume', full: false));
          return;
        }
        // reconnect immediately instead of waiting for next attempt
        await handleReconnect(ClientDisconnectReason.leaveReconnect);
      } else if (event.action == lk_rtc.LeaveRequest_Action.RECONNECT || event.canReconnect) {
        fullReconnectOnNext = true;
        if (resuming) {
          _abortResume(GravixResumeRejectedException('Leave{RECONNECT} (${event.reason}) during the resume'));
          return;
        }
        // reconnect immediately instead of waiting for next attempt
        await handleReconnect(ClientDisconnectReason.leaveReconnect);
      } else {
        // DISCONNECT or v12 server with canReconnect=false
        if (resuming) {
          _abortResume(
            GravixResumeRejectedException('Leave{DISCONNECT} during the resume', full: false, cancelled: true),
          );
        }
        await signalClient.cleanUp();
        fullReconnectOnNext = false;
        await disconnect(reason: event.reason.toSDKType());
      }
    })
    ..on<SignalRequestResponseEvent>((event) async {
      events.emit(EngineRequestResponseEvent(response: event.response));
    })
    ..on<SignalRoomMovedEvent>((event) async {
      logger.fine('[Signal] RoomMoved received, room: ${event.response.room.name}');
      if (event.response.hasParticipant()) {
        signalClient.participantSid = event.response.participant.sid;
      }
      events.emit(EngineRoomMovedEvent(response: event.response));
    });

  /// GRAVIX: writes the leave now, if the signal socket is connected and no leave
  /// went out on it yet (engine/room disposed while connected, app detached).
  /// Marks the engine closed first: the server closing the socket in answer is
  /// then not a reason to reconnect. A later [disconnect] does not send it again.
  /// Never throws.
  void gravixLeaveBestEffort() {
    if (_isClosed || signalClient.connectionState != ConnectionState.connected) return;
    _isClosed = true;
    signalClient.gravixLeaveOnDispose();
  }

  Future<void> disconnect({DisconnectReason reason = DisconnectReason.clientInitiated}) async {
    _isClosed = true;
    _gravixStopPublisherWatch();
    final pendingReconnect = isPendingReconnect;
    // GRAVIX(one-session): a resume in flight ends here too (its late socket is
    // superseded by the cleanUp below, or closed by the server after the leave)
    _cancelReconnect('disconnect');
    events.emit(EngineClosingEvent());
    if (connectionState == ConnectionState.connected) {
      await signalClient.sendLeave();
    } else {
      if (pendingReconnect) {
        logger.fine('disconnect: Cancel the reconnection processing!');
        await signalClient.cleanUp();
        await _signalListener.cancelAll();
        _clearPendingReconnect();
      }
      await cleanUp();
      events.emit(EngineDisconnectedEvent(reason: reason));
    }
  }

  /// GRAVIX (2026-10-21): the region list the session fails over with (null on a
  /// non-cloud url); Room.gravixFailoverForMediaRefusal uses it when the Room
  /// has none of its own.
  RegionUrlProvider? get gravixRegionUrlProvider => _regionUrlProvider;

  void setRegionUrlProvider(RegionUrlProvider provider) {
    _regionUrlProvider = provider;
  }
}

extension EnginePrivateMethods on Engine {
  // publisher data channel for the reliability
  rtc.RTCDataChannel? _publisherDataChannel(Reliability reliability) =>
      reliability == Reliability.reliable ? _reliableDCPub : _lossyDCPub;

  // state of the publisher data channel
  rtc.RTCDataChannelState _publisherDataChannelState(Reliability reliability) =>
      _publisherDataChannel(reliability)?.state ?? rtc.RTCDataChannelState.RTCDataChannelClosed;
}

extension EngineInternalMethods on Engine {
  @internal
  Future<rtc.RTCRtpTransceiver> createTransceiverRTCRtpSender(
    LocalTrack track,
    PublishOptions opts,
    List<rtc.RTCRtpEncoding>? encodings, {
    // GRAVIX (0.4.15): a transceiver with no track (a muted track whose capture
    // is stopped, republished after a rejoin); the unmute replaces the track
    bool gravixDetached = false,
  }) async {
    if (publisher == null) {
      throw UnexpectedConnectionState('publisher is closed');
    }

    if (track.mediaStreamTrack.kind == 'video' && opts is VideoPublishOptions) {
      track.codec = opts.videoCodec;
    }
    final transceiverInit = rtc.RTCRtpTransceiverInit(direction: rtc.TransceiverDirection.SendOnly);
    if (encodings != null) {
      transceiverInit.sendEncodings = encodings;
    }
    final kind = track is LocalVideoTrack
        ? rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo
        : rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio;
    final transceiver = gravixDetached
        ? await publisher!.pc.addTransceiver(kind: kind, init: transceiverInit)
        : await publisher!.pc.addTransceiver(track: track.mediaStreamTrack, kind: kind, init: transceiverInit);
    // GRAVIX (0.4.19): no mid yet: the next applied offer gives it one
    GravixPubLog.step(
      'senderAdd',
      pc: publisher!.gravixLogLabel,
      detail:
          'kind=${kind == rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo ? 'video' : 'audio'} '
          'source=${track.source.name} detached=$gravixDetached',
    );
    return transceiver;
  }

  @internal
  List<lk_rtc.DataChannelInfo> dataChannelInfo() =>
      [_reliableDCPub, _lossyDCPub].nonNulls.where((e) => e.id != -1).map((e) => e.toLKInfoType()).toList();

  @internal
  Future<rtc.RTCRtpSender> createSimulcastTransceiverSender(
    LocalVideoTrack track,
    SimulcastTrackInfo simulcastTrack,
    List<rtc.RTCRtpEncoding>? encodings,
    LocalTrackPublication publication,
    String videoCodec,
  ) async {
    if (publisher == null) {
      throw Exception('publisher is closed');
    }
    final transceiverInit = rtc.RTCRtpTransceiverInit(direction: rtc.TransceiverDirection.SendOnly);
    if (encodings != null) {
      transceiverInit.sendEncodings = encodings;
    }
    final transceiver = await publisher!.pc.addTransceiver(
      track: simulcastTrack.mediaStreamTrack,
      kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: transceiverInit,
    );
    await setPreferredCodec(transceiver, track.kind.toString().toLowerCase(), videoCodec);
    return transceiver.sender;
  }

  Future<void> setPreferredCodec(rtc.RTCRtpTransceiver transceiver, String kind, String videoCodec) async {
    // when setting codec preferences, the capabilites need to be read from
    // the RTCRtpReceiver
    final caps = await rtc.getRtpReceiverCapabilities(kind);
    if (caps.codecs == null) return;

    logger.fine('get capabilities ${caps.codecs}');

    final List<rtc.RTCRtpCodecCapability> matched = [];
    final List<rtc.RTCRtpCodecCapability> partialMatched = [];
    final List<rtc.RTCRtpCodecCapability> unmatched = [];
    for (var c in caps.codecs!) {
      final codec = c.mimeType.toLowerCase();
      if (codec == 'audio/opus') {
        matched.add(c);
        continue;
      }

      final matchesVideoCodec = codec == 'video/$videoCodec';
      if (!matchesVideoCodec) {
        if (lkPlatformIs(PlatformType.android) && codec == 'video/vp9') {
          if (c.sdpFmtpLine != null &&
              (c.sdpFmtpLine!.contains('profile-id=0') || c.sdpFmtpLine!.contains('profile-id=1'))) {
            unmatched.add(c);
          }
        } else {
          unmatched.add(c);
        }
        continue;
      }
      // for h264 codecs that have sdpFmtpLine available, use only if the
      // profile-level-id is 42e01f for cross-browser compatibility
      if (videoCodec.toLowerCase() == 'h264') {
        if (c.sdpFmtpLine != null && c.sdpFmtpLine!.contains('profile-level-id=42e01f')) {
          matched.add(c);
        } else {
          partialMatched.add(c);
        }
        continue;
      }
      if (lkPlatformIs(PlatformType.android) && codec == 'video/vp9') {
        if (c.sdpFmtpLine != null &&
            (c.sdpFmtpLine!.contains('profile-id=0') || c.sdpFmtpLine!.contains('profile-id=1'))) {
          matched.add(c);
        }
      } else {
        matched.add(c);
      }
    }
    matched.addAll([...partialMatched, ...unmatched]);
    try {
      await transceiver.setCodecPreferences(matched);
    } catch (e) {
      logger.warning('setCodecPreferences failed: $e');
    }
  }
}

Future<String?> getConnectedAddress(rtc.RTCPeerConnection pc) async => gravixConnectedAddressOf(await pc.getStats());

/// The remote address of the selected candidate pair in [stats] (GRAVIX: split
/// out of [getConnectedAddress] so that one read serves both it and the ICE
/// transport watch).
@internal
String? gravixConnectedAddressOf(List<rtc.StatsReport> stats) {
  var selectedCandidatePairId = '';
  final candidatePairs = <String, rtc.StatsReport>{};
  // id -> candidate ip
  final candidates = <String, String>{};
  for (var v in stats) {
    switch (v.type) {
      case 'transport':
        selectedCandidatePairId = v.values['selectedCandidatePairId'] as String;
        break;
      case 'candidate-pair':
        if (selectedCandidatePairId == '') {
          if (v.values['selected'] != null && v.values['selected'] == true) {
            selectedCandidatePairId = v.id;
          }
        }
        candidatePairs[v.id] = v;
        break;
      case 'remote-candidate':
        var address = '';
        var port = 0;
        if (v.values['address'] != null) {
          address = v.values['address'] as String;
        }
        if (v.values['port'] != null) {
          port = v.values['port'] as int;
        }
        candidates[v.id] = '$address:$port';
        break;
      default:
    }
  }

  if (selectedCandidatePairId == '') {
    return null;
  }

  final report = candidatePairs[selectedCandidatePairId];
  if (report == null) {
    return null;
  }
  final selectedID = report.values['remoteCandidateId'] as String;
  return candidates[selectedID];
}

/// GRAVIX(resume-rejected): a resume that cannot succeed (see Engine._resumeAbort).
/// [full]: rejoin with a new session (the server closed this one) rather than
/// resume again. [cancelled]: a fresh connect / disconnect took over; nothing is
/// retried.
@internal
/// GRAVIX (0.4.15, F4): work of a session that a full reconnect replaced.
class GravixSessionReplacedException extends TrackPublishException {
  GravixSessionReplacedException(String message) : super(message);
}

/// GRAVIX (2026-10-11, restartAbortsOnSignalLoss): the full reconnect's signal
/// socket closed while it waited (for the JoinResponse, the primary connection
/// or the publisher connection).
class GravixRestartSignalLostException extends ConnectException {
  GravixRestartSignalLostException(String what)
    : super(
        'the signal connection closed while the full reconnect waited for $what',
        reason: ConnectionErrorReason.InternalError,
      );
}

class GravixResumeRejectedException implements Exception {
  GravixResumeRejectedException(this.message, {this.full = true, this.cancelled = false});
  final String message;
  final bool full;
  final bool cancelled;
  @override
  String toString() => 'GravixResumeRejectedException: $message';
}
