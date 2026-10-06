import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:collection/collection.dart'; // firstOrNull
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCPeerConnection, RTCPeerConnectionState;
import 'package:uuid/uuid.dart';

import '../audio/gravix_audio_host.dart';
import '../audio/gravix_audio_routing.dart';
import '../audio/gravix_early_call_audio.dart';
import '../backend/gravix_token_provider.dart';
import '../beauty/gravix_beauty_filter.dart';
import '../beauty/gravix_video_effect.dart';
import '../connect/gravix_analytics.dart';
import '../connect/gravix_connection_report.dart';
import '../connect/gravix_fast_join.dart';
import '../connect/gravix_join_phases.dart';
import '../connect/gravix_join_timeline.dart';
import '../connect/gravix_join_timeline_log.dart';
import '../connect/gravix_prewarm.dart';
import '../connect/gravix_init_measure.dart';
import '../connect/gravix_region_cache.dart';
import '../connect/gravix_restart_strategy.dart';
import '../connect/gravix_region_prober.dart';
import '../connect/gravix_region_report.dart';
import '../connect/gravix_standby.dart';
import '../music/gravix_music_controller.dart';
import '../music/gravix_room_music.dart';
import '../rtc_core/gravix_client.dart';
import '../rtc_core/src/support/http_client.dart' show sdkHttpHead;
import '../rtc_core/src/support/region_url_provider.dart' show toHttpUrl;
import '../rtc_core/src/support/websocket/standby.dart';
import 'gravix_red_mode.dart';
import '../large_room/gravix_publish_presets.dart' show GravixPublishPresets;
import '../rtc_core/src/track/local/engine_mic_mute.dart' show GravixEngineMicMute;
import '../rtc_core/src/track/local/mic_republish.dart';
import '../rtc_core/src/internal/events.dart'
    show
        EngineJoinResponseEvent,
        EnginePeerStateUpdatedEvent,
        SignalConnectedEvent,
        SignalConnectingEvent,
        EngineTrackAddedEvent,
        SignalJoinResponseEvent,
        SignalOfferEvent,
        SignalParticipantUpdateEvent;

/// ════════════════════════════════════════════════════════════════════════════
///  GravixRoomService — ONE service for ALL room/call work in the app.
/// ════════════════════════════════════════════════════════════════════════════
///
/// Used by the audio room, video room, and multi-room. It replaces the legacy
/// Agora `RtcEngine` everywhere. Nothing about Parse / LiveQuery / seats /
/// gifts / PK lives here — this layer is pure RTC transport.
///
/// State management is agnostic: every observable field is a [ValueNotifier],
/// so apps built on GetX, BLoC, Riverpod, or plain `StatefulWidget`s can
/// subscribe however they like. Instantiate it with whatever DI the app
/// already uses and call [dispose] when the app tears down.
///
/// ── Why a single service ─────────────────────────────────────────────────────
/// The RTC core gives you ONE `Room` object. This service is the direct
/// equivalent: one `Room` at a time, one set of event callbacks, one
/// mic/role API. Each room screen calls `connect(...)` on entry and
/// `disconnect()` on exit and wires its callbacks. Video rooms additionally
/// use the video helpers at the bottom; audio rooms ignore them.
///
/// ── Identity model (IMPORTANT) ───────────────────────────────────────────────
/// Users are identified by an integer `uid` across the app (CohostList
/// ['userId'], BlockListUids, activeSpeakers as a Set, etc.). The room
/// `identity` is therefore the uid as a string: identity == uid.toString().
/// The token server MUST set the same identity. Events here parse identity
/// back to a String uid so the rest of the app code is unchanged.
///
/// ── Roles ────────────────────────────────────────────────────────────────────
/// Publishing vs not publishing: there is no role call — you just enable or
/// disable the mic (or camera). The PERMISSION to publish comes from the token
/// (canPublish), granted server-side. A listener token has canPublish=false;
/// a host/cohost token has canPublish=true. To promote a viewer to speaker
/// mid-room: reconnect with a publish-token (see [reconnectWithToken]) or have
/// the server call its participant-update API.
///
/// ── Optional layers ──────────────────────────────────────────────────────────
/// - [roomMusic]: room music (a local file mixed into the published mic), bound
///   to each room this service connects; [music] is its low-level bridge.
/// - [videoEffect]: an optional [GravixVideoEffect] (beauty, blur, …) on the
///   local camera track, from an effect package. None by default: the service
///   then calls no effect code and [videoEffectActive] stays false.
class GravixRoomService implements GravixAudioHost {
  GravixRoomService({
    GravixVideoEffect? videoEffect,
    @Deprecated('Pass videoEffect: (a GravixVideoEffect). Removal no earlier than 2027-09.') GravixBeautyFilter? beauty,
    GravixMusicController? music,
    GravixRoomMusic? roomMusic,
    this.analytics,
    this.reconnectPolicy,
    GravixRegionProber? regionProber,
    GravixRegionDecisionCache? regionDecisionCache,
    @visibleForTesting Future<void> Function(Room room, String url, String token)? connectRoom,
    @visibleForTesting Future<void> Function(String httpUrl)? prepareConnection,
    @visibleForTesting Future<bool> Function()? requestMicPermission,
    @visibleForTesting Future<void> Function(bool enabled)? applyMic,
  }) : _applyMic = applyMic,
       _prepareConnection = prepareConnection ?? _defaultPrepareConnection,
       _requestMicPermission = requestMicPermission ?? _defaultRequestMicPermission,
       assert(videoEffect == null || beauty == null, 'pass videoEffect OR the deprecated beauty, not both'),
       _effect = GravixVideoEffectBinding(videoEffect ?? (beauty == null ? null : GravixBeautyFilterEffect(beauty))),
       music = music ?? GravixMusicController(),
       roomMusic = roomMusic ?? GravixRoomMusic(null),
       _regionProber = regionProber ?? GravixRegionProber(),
       _regionCache = regionDecisionCache ?? GravixRegionDecisionCache.shared,
       _connectRoom = connectRoom ?? ((room, url, token) => room.connect(url, token));

  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  bool _wasMicEnabledBeforeInterruption = false;

  // ══ v2 AUDIO ROUTING (GravixAudioRouting.v2) ═══════════════════════════════
  // Everything below is inert while the flag is false; the v1 path above and
  // in _configureAudioSession is then byte-for-byte unchanged.

  /// Captured once per connect, so a mid-room flag flip cannot leave the
  /// service half-wired (v2 started but torn down on the v1 path, or worse).
  bool _v2Active = false;

  bool _appBackgrounded = false;

  /// Tell the routing stack the app went to / came back from the background.
  ///
  /// The session guard stands down while backgrounded: an app that released
  /// the audio session on purpose so other apps can record is *supposed* to be
  /// in `MODE_NORMAL`, and "repairing" that would grab the session straight
  /// back. The SDK installs no lifecycle observer of its own — call this from
  /// the app's `didChangeAppLifecycleState` — except while the Android call
  /// foreground service is enabled for the connect ([GravixForegroundService]):
  /// then the SDK forwards it (calling it from the app as well is harmless).
  ///
  /// No-op unless [GravixAudioRouting.v2] is on.
  void setAppBackgrounded(bool backgrounded) {
    _appBackgrounded = backgrounded;
    if (!_v2Active) return;
    if (!backgrounded) {
      // Coming back to the foreground is one of the moments another app's call
      // most often has just ended.
      GravixAudioRouting.foreignCall.probeSoon();
      GravixAudioRouting.routeManager.applyAfterTrackStart(reason: 'foreground');
    }
  }

  @override
  bool get isRoomConnected => isConnected.value;

  @override
  bool get appBackgrounded => _appBackgrounded;

  /// Something is actually playing or capturing. Android resets an IDLE
  /// communication-mode owner to `MODE_NORMAL` after ~6s, and the guard must
  /// not read that as a dead session — see [GravixAndroidAudioSessionGuard].
  @override
  bool get audioFlowing {
    if (!isConnected.value) return false;
    if (!isMicMuted.value) return true;
    final room = _room;
    if (room == null) return false;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        if (pub.subscribed && !pub.muted) return true;
      }
    }
    return false;
  }

  /// This SDK always publishes and plays out on the voice-communication
  /// profile (see `_configureAudioSession`), so the media-usage path the
  /// reference guards against does not arise here.
  @override
  bool get recordableRoomAudio => false;

  Room? _room;
  Timer? _statsTimer; // debug video stats loop

  // ══ AUTO DATA-SAVER (host uplink protection) ═══════════════════════════════
  // Simulcast serves weak VIEWERS; this protects weak HOSTS. A 3s monitor
  // watches the host's own connectionQuality:
  //   poor/lost for ≥10s  → republish single-layer @600kbps (data saver ON)
  //   excellent for ≥45s  → republish full profile      (data saver OFF)
  // Hysteresis + a 60s minimum gap between switches prevent oscillation.
  final ValueNotifier<bool> lowDataActive = ValueNotifier<bool>(false);
  Timer? _qualityTimer;
  DateTime? _poorSince;
  DateTime? _goodSince;
  DateTime _lastProfileSwitch = DateTime.fromMillisecondsSinceEpoch(0);
  bool _switchingProfile = false;
  static const _poorEngage = Duration(seconds: 10);
  static const _goodRestore = Duration(seconds: 45);
  static const _minSwitchGap = Duration(seconds: 60);

  /// Background-music mixing bridge. Playback
  /// (start/pause/resume/stop/seek/volume) is app-controlled through this
  /// field; the native callback is installed automatically on connect.
  final GravixMusicController music;

  /// Room music for the connected room: `start`, `pause`, `stop`, volumes,
  /// ducking, loop and a state listenable. Re-bound to every room this service
  /// connects; a disconnect stops the music. See [GravixRoomMusic].
  final GravixRoomMusic roomMusic;

  /// How the engine backs off (and when it gives up) after the connection is
  /// lost mid-session. Null = the SDK default ([DefaultReconnectPolicy]).
  final ReconnectPolicy? reconnectPolicy;

  /// Join-report upload to a Gravix analytics collector (ANALYTICS_CONTRACT §2).
  /// Null = off (the default). A connect's `analyticsUrl:` overrides it for that
  /// join. The upload never delays or fails a join.
  final GravixAnalytics? analytics;

  /// The report of the current join, held until its timeline is final when the
  /// join records one (first audio, [kGravixFirstAudioTimeout], or disconnect —
  /// whichever comes first), so the upload can carry it.
  ({GravixAnalytics sink, String token, GravixJoinAnalyticsReport report})? _pendingAnalytics;

  /// Uploads made by this service, for tests. Completed uploads only.
  @visibleForTesting
  Future<bool>? debugLastAnalyticsUpload;

  void _queueJoinAnalytics(GravixAnalytics? sink, String token, GravixJoinAnalyticsReport report) {
    if (sink == null) return;
    // Anything still held belongs to an earlier join: send it as it is.
    _flushJoinAnalytics(null);
    // Sent at once, like the React SDK's report: waiting for the join timeline
    // (up to kGravixFirstAudioTimeout) lost the report whenever the app was closed
    // in that window. A timeline that has already been emitted still rides along.
    final t = joinTimeline.value?.connectionId == report.connectionId ? joinTimeline.value : null;
    debugLastAnalyticsUpload = sink.reportJoin(report.withTimeline(t?.toJson()), token: token);
  }

  void _flushJoinAnalytics(GravixJoinTimeline? timeline) {
    final p = _pendingAnalytics;
    if (p == null) return;
    _pendingAnalytics = null;
    debugLastAnalyticsUpload = p.sink.reportJoin(p.report.withTimeline(timeline?.toJson()), token: p.token);
  }

  /// The local-camera effect hook; see [GravixVideoEffect].
  final GravixVideoEffectBinding _effect;

  /// The effect passed to the constructor (a deprecated `beauty:` filter shows
  /// up wrapped in a [GravixBeautyFilterEffect]); null when none.
  GravixVideoEffect? get videoEffect => _effect.effect;

  /// True while [videoEffect] reports that it is processing the live camera
  /// track (its `attach` answered true). Always false with no effect, with the
  /// camera off, or when the effect's native side is missing.
  ValueListenable<bool> get videoEffectActive => _effect.active;

  /// Turn [videoEffect] on/off (a bypass; the processor stays attached).
  /// Remembered and applied at the next attach when the camera is off.
  Future<void> setVideoEffectEnabled(bool enabled) => _effect.setEnabled(enabled);

  /// Effect-specific parameters for [videoEffect]. Remembered and replayed after
  /// every attach.
  Future<void> setVideoEffectParams(Map<String, Object?> params) => _effect.setParams(params);

  bool _disposed = false;

  // ══ PROBE-RACE CONNECT (connect(regionProbe: true)) ════════════════════════
  final GravixRegionProber _regionProber;
  final GravixRegionDecisionCache _regionCache;

  /// The one place a url becomes a connection. A seam so the connect ladder can be
  /// tested without a transport.
  final Future<void> Function(Room room, String url, String token) _connectRoom;

  /// True while (and after) a connect() that has more than one url to try. A
  /// failed ladder attempt makes the core emit RoomDisconnectedEvent(joinFailure);
  /// passing that on would tell the app the session dropped - and let it tear the
  /// screen down - while the next region is still being tried. A connected room
  /// never emits joinFailure later, so it is safe to keep ignoring for the
  /// session. If the WHOLE ladder fails, connect() reports it exactly once itself.
  bool _ignoreJoinFailureEvents = false;

  /// What happened during the most recent [connect]: which region won the probe
  /// race (or why the pinned URL was used), and how long the user waited to
  /// hear the first remote participant.
  ///
  /// `joinToFirstAudio` lands after connect returns, so read this again once
  /// audio has started rather than caching the value seen at connect time.
  /// Null before the first connect.
  GravixConnectionReport? get lastConnectionReport => connectionReport.value;

  /// [lastConnectionReport] as a listenable, for a diagnostics panel.
  final ValueNotifier<GravixConnectionReport?> connectionReport = ValueNotifier<GravixConnectionReport?>(null);

  /// Wall clock for the current join, used for join-to-first-audio.
  Stopwatch? _joinWatch;
  bool _firstAudioSeen = false;

  // ══ SPLIT PROBE TELEMETRY (cross-SDK contract) ═════════════════════════════
  //
  // Two events, not one. The combined [GravixConnectionReport] below carries
  // join-to-first-audio, so it cannot be final until first audio arrives or
  // its 30s timeout elapses — which loses every session that ends inside that
  // window, i.e. exactly the sessions where region selection went wrong.
  // [regionReport] is emitted at connectedAt and waits on nothing;
  // [firstAudioReport] follows later and is correlated by `connectionId`.
  // See `lib/src/connect/gravix_region_report.dart` and
  // `doc/PROBE_RACE_PARITY.md`.

  /// The region decision for the most recent probed connect, emitted at
  /// connect time and never withheld. Null when the connect did not probe.
  final ValueNotifier<GravixRegionReport?> regionReport = ValueNotifier<GravixRegionReport?>(null);

  /// First-audio timing for the most recent probed connect. Arrives after
  /// [regionReport]; correlate on `connectionId`. Emitted exactly once per
  /// probed connect, with null audio fields when nothing was heard.
  final ValueNotifier<GravixFirstAudioReport?> firstAudioReport = ValueNotifier<GravixFirstAudioReport?>(null);

  /// Called as soon as the region decision is known — at connectedAt, with no
  /// dependency on audio. Ship this to telemetry.
  void Function(GravixRegionReport report)? onRegionReport;

  /// Called once first audio arrives, or once [kGravixFirstAudioTimeout]
  /// elapses, or on disconnect — whichever happens first. Join to
  /// [onRegionReport] on `connectionId`.
  void Function(GravixFirstAudioReport report)? onFirstAudioReport;

  /// Per-connect correlation id shared by the two events above.
  String? _connectionId;

  /// Everything the region event needs that is only known before connect.
  DateTime? _connectStartedAt;
  DateTime? _probeStartedAt;
  DateTime? _connectedAt;
  List<GravixRegionUrl> _regionEntries = const [];
  Timer? _firstAudioTimeout;
  bool _firstAudioEmitted = false;

  EventsListener<RoomEvent>? _listener;

  // ══ JOIN TIMELINE (connect(joinTimeline: …)) ═══════════════════════════════
  // Off unless the app passes a GravixJoinTimelineInput. See
  // lib/src/connect/gravix_join_timeline.dart for what it measures and why.

  /// The step-by-step timeline of the most recent `connect(joinTimeline: …)`.
  /// Set once per join: at the first-audio playout proxy, else at
  /// [kGravixFirstAudioTimeout], else at disconnect.
  final ValueNotifier<GravixJoinTimeline?> joinTimeline = ValueNotifier<GravixJoinTimeline?>(null);

  /// Called with the same value as [joinTimeline]. `report.toJsonLine()` is the
  /// one-line form for a log.
  void Function(GravixJoinTimeline report)? onJoinTimeline;

  /// 0.4.8: every [GravixJoinPhase] of each [connect] as it is reached (WS open,
  /// JoinResponse, peer connections connected, first local publish and first
  /// remote track per kind) -- the same hooks an app that drives `Room` itself
  /// gets from `room.watchJoinPhases()`. `elapsed` counts from the
  /// `joinTimeline.tapAt` when one is passed, else from connect(). Set before
  /// connect(); null (default) attaches nothing.
  void Function(GravixJoinPhaseEvent event)? onJoinPhase;

  /// The join-phase hooks of the current / last room (with [onJoinPhase] set).
  GravixJoinPhases? get joinPhases => _joinPhases;
  GravixJoinPhases? _joinPhases;

  /// Write every join timeline to the device log (tag `GRAVIX_JOIN_TIMELINE`,
  /// one line of JSON, RELEASE builds included) — see [gravixLogJoinTimeline].
  /// The one switch a production app flips to be measurable by a
  /// logcat-scraping script. Off by default. A join still
  /// needs `joinTimeline:` passed to [connect] for there to be a timeline.
  bool logJoinTimelines = false;

  GravixJoinTimelineRecorder? _timeline;

  /// The join's mic/camera publication while it runs behind a connect() that
  /// already returned (`publishInBackground`). setMicEnabled / setCameraEnabled /
  /// disconnect wait for it, so a fast toggle never races the initial publish.
  Future<void>? _initialPublish;
  bool _timelineEmitted = false;
  Timer? _timelinePoll;
  Timer? _timelineIcePoll;
  Timer? _timelineTimeout;
  // <candidate:earlyCallAudio>
  /// Whether the current/last connect() activated call audio early.
  @visibleForTesting
  bool earlyCallAudioStarted = false;
  CancelListenFunc? _earlyCallAudioCancel;
  // </candidate:earlyCallAudio>
  bool _timelinePolling = false;
  bool _timelineIcePolling = false;

  /// The selected-pair read started at PC-connected. It may still be retrying
  /// past the stats cache when first audio arrives; the report waits for it
  /// (bounded) rather than going out with `pair: null` on a connected join.
  Future<void>? _timelinePairRead;
  final List<CancelListenFunc> _timelineCancels = <CancelListenFunc>[];

  /// Reads getStats() of a peer connection as plain records. A seam, so the
  /// timeline wiring can be tested without a native peer connection.
  @visibleForTesting
  Future<List<GravixStat>> Function(Room room, {required bool inbound})? debugTimelineStats;

  // Cached connect params so we can reconnect on role promotion / token refresh.
  String? _url;

  Room? get room => _room;
  LocalParticipant? get localParticipant => _room?.localParticipant;

  /// Mirrors `AgoraRtcEngine.activeSpeakers` — uids currently speaking.
  /// Wire your seat-glow / sound-wave UI to `.value` / `.addListener`.
  final ValueNotifier<Set<String>> activeSpeakers = ValueNotifier<Set<String>>(<String>{});

  /// True once connected to a room.
  final ValueNotifier<bool> isConnected = ValueNotifier<bool>(false);

  /// Local mic muted (not publishing audio).
  final ValueNotifier<bool> isMicMuted = ValueNotifier<bool>(true);

  /// Local camera enabled (video rooms only).
  final ValueNotifier<bool> isCameraEnabled = ValueNotifier<bool>(false);

  /// Latest `cameraFacing` attribute ('front'/'back') per remote uid.
  final ValueNotifier<Map<String, String>> remoteFacing = ValueNotifier<Map<String, String>>(<String, String>{});

  /// Current camera facing. The RTC core has no getter for this, so we track
  /// it ourselves and flip it in [switchCamera].
  CameraPosition cameraPosition = CameraPosition.front;

  // ── Callbacks the screens assign (replaces the engine event handler) ────────
  void Function(String uid)? onUserJoined; // ≈ onUserJoined
  void Function(String uid)? onUserOffline; // ≈ onUserOffline
  void Function(String uid, bool muted)? onUserMuteAudio;
  void Function()? onDisconnected; // terminal disconnect
  /// Video rooms: a remote track is ready to render. Build a VideoTrackRenderer.
  void Function(String uid, VideoTrack track)? onRemoteVideoTrack;
  void Function(String uid)? onRemoteVideoTrackRemoved;

  VideoPublishOptions _videoPublishOptions(bool lowData) => videoPublishOptionsFor(lowData: lowData);

  /// The publish options [GravixRoomService] uses for the camera: normal, or the
  /// data saver's (`lowData`).
  @visibleForTesting
  static VideoPublishOptions videoPublishOptionsFor({required bool lowData}) {
    // ══ SIMULCAST, COST-MINIMIZED ══
    // History: simulcast was OFF because it previously made SIM-data hosts
    // lag — that pain was the old h720 ladder bug (TWO full-res encodings,
    // limit=cpu), not simulcast itself. Beauty is NOT rendered per layer:
    // the GL pipeline runs once; layers are encoder downscales.
    //  • Normal: one extra 180p rung (~+11% encoder pixels / +160kbps worst
    //    case), and dynacast pauses it whenever no weak viewer needs it. The
    //    rung runs at the top layer's 24 fps (GravixPublishPresets.lowLayer):
    //    layers with different maxFramerate kept cross-region viewers on the
    //    lowest layer (server relay bug, fixed separately).
    //  • Data saver (auto): single layer @600kbps for hosts whose own
    //    uplink is the bottleneck.
    return VideoPublishOptions(
      simulcast: !lowData,
      videoEncoding: VideoEncoding(maxBitrate: lowData ? 600_000 : 800_000, maxFramerate: 24),
      degradationPreference: DegradationPreference.balanced,
      // f=540p is added automatically at capture res; q=180p is the only
      // extra encoding.
      videoSimulcastLayers: lowData ? const [] : const [GravixPublishPresets.lowLayer],
    );
  }

  void _startQualityMonitor() {
    _qualityTimer?.cancel();
    _poorSince = null;
    _goodSince = null;
    _qualityTimer = Timer.periodic(const Duration(seconds: 3), (_) => _checkQuality());
  }

  void _checkQuality() {
    final lp = _room?.localParticipant;
    if (lp == null || !isCameraEnabled.value || _switchingProfile) return;
    final q = lp.connectionQuality;
    final now = DateTime.now();

    final isPoor = q == ConnectionQuality.poor || q == ConnectionQuality.lost;
    final isExcellent = q == ConnectionQuality.excellent;

    _poorSince = isPoor ? (_poorSince ?? now) : null;
    _goodSince = isExcellent ? (_goodSince ?? now) : null;

    if (now.difference(_lastProfileSwitch) < _minSwitchGap) return;

    if (!lowDataActive.value && _poorSince != null && now.difference(_poorSince!) >= _poorEngage) {
      _applyPublishProfile(lowData: true);
    } else if (lowDataActive.value && _goodSince != null && now.difference(_goodSince!) >= _goodRestore) {
      _applyPublishProfile(lowData: false);
    }
  }

  /// Republish the live camera track with a new profile — no reconnect.
  Future<void> _applyPublishProfile({required bool lowData}) async {
    if (_switchingProfile) return;
    _switchingProfile = true;
    try {
      final lp = _room?.localParticipant;
      final pub = lp?.getTrackPublicationBySource(TrackSource.camera);
      final track = pub?.track;
      if (lp == null || pub == null || track is! LocalVideoTrack) return;

      debugPrint(
        '📶 auto data-saver: switching to '
        '${lowData ? "LOW (single-layer 600k)" : "NORMAL (simulcast 800k)"} '
        '(quality=${lp.connectionQuality})',
      );
      // stopLocalTrackOnUnpublish=false keeps the capturer + beauty processor
      // alive; viewers see at most a sub-second gap while layers renegotiate.
      await lp.removePublishedTrack(pub.sid);
      await lp.publishVideoTrack(track, publishOptions: _videoPublishOptions(lowData));
      lowDataActive.value = lowData;
      _lastProfileSwitch = DateTime.now();
      _poorSince = null;
      _goodSince = null;
    } catch (e) {
      debugPrint('Error applying publish profile: $e');
    } finally {
      _switchingProfile = false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CONNECT  — replaces createRtcEngine + initialize + joinChannel
  // ═══════════════════════════════════════════════════════════════════════════
  /// [url]        e.g. 'wss://rtc.example.com'
  /// [token]      JWT from your token server (room + identity=uid + canPublish)
  /// [publishMic] start publishing audio immediately (host = true, viewer = false)
  /// [enableVideo]video rooms only — start publishing camera too
  /// [lowDataMode] host escape hatch for very weak SIM-data uplinks:
  ///   single-layer publish at 600kbps (no simulcast). Wire to a "Data
  ///   saver" toggle in the go-live sheet, or set automatically when
  ///   connectionQuality stays poor.
  /// [regionUrls] the `region_urls` from the token response, if the gateway
  ///   sent any — `gravixRegionUrlsFrom(tokenResponse)` pulls them out.
  /// [regionProbe] race a lightweight HEAD at each of [regionUrls] and connect
  ///   to the first responder, falling back to [url] on timeout. Opt-in. With
  ///   it off, or with [regionUrls] empty, the connect is exactly the connect
  ///   it was before this option existed: [url] is used, no probe is sent, and
  ///   no extra await is introduced.
  /// [regionDecisionCache] with [regionProbe]: a repeat join connects to the
  ///   region the last race picked (10 min memory) without racing again; the
  ///   race runs in the background to keep the memory fresh. ON by default since
  ///   2026-09-19 (JS parity; it removed the probe's round trips from repeat
  ///   joins in a real-browser measurement). Pass `false` to race on every join.
  ///   See [GravixRegionDecisionCache].
  /// [regionReprobeOnRestart] with [regionProbe]: when the engine has to do a
  ///   FULL reconnect (a new session, not a resume) it races the regions again
  ///   instead of re-joining the region it was on. Opt-in, JS parity. See
  ///   [GravixProbeRestartStrategy].
  /// [parallelAudioSession] run the audio-session bring-up alongside the network
  ///   steps instead of before them. Opt-in. v1 routing: alongside the probe race
  ///   AND the transport. v2 routing: alongside the probe race only (v2 must own
  ///   the session before a Room exists). The session is always ready before the
  ///   mic is enabled or the route is applied. One known edge: on v1, a remote
  ///   track that is subscribed before a very slow session bring-up finishes
  ///   starts playout under the platform's previous session settings until it
  ///   does.
  /// (The experimental fast-connect options are documented at their parameters below.)
  Future<bool> connect({
    required String url,
    required String token,
    bool publishMic = false,
    bool enableVideo = false,
    bool lowDataMode = false,
    List<String> regionUrls = const <String>[],
    List<GravixRegionUrl> regionEntries = const <GravixRegionUrl>[],
    // The room's home region (a viewer / guest in someone else's room; the
    // token's `home_region`): the start-up measurement's pick moves to it when it
    // is within max(25 ms, 30 %) of the fastest region, so the join skips the
    // relay hop to the host's region. Hosts pass none. See gravixPickMeasuredRegion.
    String? homeRegion,
    bool regionProbe = false,
    bool regionDecisionCache = true,
    bool regionReprobeOnRestart = false,
    GravixJoinTimelineInput? joinTimeline,
    bool parallelAudioSession = false,
    // [analyticsUrl] the analytics collector's base url for THIS join's report
    //   (overrides the service's [analytics]); see [GravixAnalytics].
    String? analyticsUrl,
    // <candidate:fastAnswer>
    // [fastAnswer] EXPERIMENTAL, opt-in. Send the subscriber answer as soon as it
    //   is created instead of after `setLocalDescription` returns. On a phone the
    //   first audio offer's `setLocalDescription` takes ~350 ms (audio playout
    //   starts inside it) and the SFU forwards nothing until it has the answer.
    //   Risk: media can arrive before the local description is applied - see
    //   `gravixAnswerSubscriberOffer` and doc/FAST_CONNECT_INTEGRATION.md.
    bool fastAnswer = false,
    // </candidate:fastAnswer>
    // <candidate:earlyCallAudio>
    // [earlyCallAudio] EXPERIMENTAL, opt-in, Android only. Activate call audio
    //   (focus, communication mode, route) at the WebSocket dial instead of when the
    //   first remote audio track arrives - see [GravixEarlyCallAudio]. The user
    //   hears other apps' audio pause ~0.5 s earlier than today; the microphone is
    //   not touched. Ignored under audio routing v2.
    bool earlyCallAudio = false,
    // </candidate:earlyCallAudio>
    // [publishInBackground] opt-in (2026-09-29). connect() returns once the peer
    //   connection is up; the mic (and camera) publication, the music-mixer
    //   install and the audio route run behind it. Field logs (Android, Kuwait ->
    //   doh1, ~50 ms RTT): ~0.5 s between pcConnected and connect() returning,
    //   spent publishing the mic (track create + capture start + AddTrack round
    //   trip + publisher renegotiation) and, in a video room, opening and
    //   publishing the camera. Nothing the user hears depends on it: remote audio
    //   plays from the subscriber side. The timeline's `micPublished` mark says
    //   when the mic went live; setMicEnabled / setCameraEnabled / disconnect wait
    //   for the initial publication. Off = exactly the old order.
    bool publishInBackground = false,
    // [red] RED (redundant audio) for the microphone: on (default, as 0.4.3), off,
    //   or auto = plain Opus until the uplink loses >= [redLossThresholdPct] % for
    //   ~20 s (not with an RTT above 1.5 s), then the mic is republished with RED
    //   once. RED roughly doubles the
    //   audio upload (field 2026-09-30: ~125 vs ~50 kbps) and recovers lost
    //   packets instead of concealing them; see gravix_red_mode.dart.
    GravixRedMode red = GravixRedMode.on,
    double redLossThresholdPct = kGravixRedLossThresholdPct,
    // [earlyMicTrack] opt-in (2026-09-30). With [publishMic]: the microphone track
    //   (capture start, the slow part of the mic step: 140-490 ms in the field) is
    //   created right after the audio session, IN PARALLEL with the signalling, and
    //   the join's mic step only publishes it. Field Android joins: micPublished
    //   came 145-494 ms after pcConnected. Pass it only when the microphone
    //   permission is already granted (otherwise the OS dialog would come up in
    //   the middle of the join). Not before the tap: a capture running on the
    //   room-code screen lights the OS privacy indicator and takes the audio mode
    //   from other apps while the user has not joined anything.
    bool earlyMicTrack = false,
    // [dtx] Opus DTX for the microphone (2026-10-05, opt-in): during silence the
    //   encoder sends a comfort-noise frame every ~400 ms instead of 50 frames/s.
    //   Field: a seated speaker sent ~118-128 kbps continuously (64 kbps Opus x
    //   RED), silence included. Speech rooms only: Opus' voice detector can treat
    //   quiet background music as silence (singing hosts, the music mixer), so
    //   leave it off where music matters. Kept across RED auto republishes.
    bool dtx = false,
    // [foregroundService] the Android call foreground service for THIS connect
    //   (2026-10-06): keeps the mic, the room playback and room music alive in
    //   the background. Null = GravixForegroundService.defaults (disabled unless
    //   the app enabled it). When enabled, the service also forwards app
    //   background/foreground to [setAppBackgrounded].
    GravixForegroundServiceOptions? foregroundService,
  }) {
    // GRAVIX(one-session, 2026-10-05): one session per room + identity. Field: a
    // second join for the same identity raced the first one's resume on another
    // node, moved the room's origin and cost ~2.5 min of instability.
    //  * the same room + identity + token while a connect is in flight: that
    //    connect's result (a double tap / re-entry is not a second session);
    //  * the same room + identity + token while connected or reconnecting: the
    //    current session is kept (true). disconnect() first forces a new one;
    //    reconnectWithToken (another token) reconnects as before;
    //  * anything else waits for a connect in flight to settle, then tears the
    //    previous session down (leave first) before joining: never two at once.
    final key = gravixSessionKey(token);
    final inFlight = _connectInFlight;
    if (inFlight != null && key != null && inFlight.key == key && inFlight.token == token) {
      debugPrint('Gravix connect: the same room/identity is already joining; not starting a second session');
      return inFlight.done.future;
    }
    final room = _room;
    if (inFlight == null &&
        gravixKeepSession(
          key: key,
          token: token,
          sessionKey: _sessionKey,
          sessionToken: _sessionToken,
          state: room?.connectionState,
        )) {
      debugPrint('Gravix connect: already in this room as this identity (${room?.connectionState.name}); session kept');
      return Future<bool>.value(true);
    }
    final mine = _ConnectInFlight(key, token);
    _connectInFlight = mine;
    () async {
      try {
        if (inFlight != null) await inFlight.done.future.then((_) {}, onError: (Object _) {});
        final ok = await _connectOnce(
          url: url,
          token: token,
          publishMic: publishMic,
          enableVideo: enableVideo,
          lowDataMode: lowDataMode,
          regionUrls: regionUrls,
          regionEntries: regionEntries,
          homeRegion: homeRegion,
          regionProbe: regionProbe,
          regionDecisionCache: regionDecisionCache,
          regionReprobeOnRestart: regionReprobeOnRestart,
          joinTimeline: joinTimeline,
          parallelAudioSession: parallelAudioSession,
          analyticsUrl: analyticsUrl,
          fastAnswer: fastAnswer,
          earlyCallAudio: earlyCallAudio,
          publishInBackground: publishInBackground,
          red: red,
          redLossThresholdPct: redLossThresholdPct,
          earlyMicTrack: earlyMicTrack,
          dtx: dtx,
          foregroundService: foregroundService,
        );
        if (ok) {
          _sessionKey = key;
          _sessionToken = token;
        }
        mine.done.complete(ok);
      } catch (e, st) {
        mine.done.completeError(e, st);
      } finally {
        if (identical(_connectInFlight, mine)) _connectInFlight = null;
      }
    }();
    return mine.done.future;
  }

  /// Whether a connect() for [key] / [token] keeps the current session (same
  /// room, identity and token, and that session is connected or reconnecting).
  @visibleForTesting
  static bool gravixKeepSession({
    required String? key,
    required String token,
    required String? sessionKey,
    required String? sessionToken,
    required ConnectionState? state,
  }) =>
      key != null &&
      key == sessionKey &&
      token == sessionToken &&
      (state == ConnectionState.connected || state == ConnectionState.reconnecting);

  _ConnectInFlight? _connectInFlight;
  String? _sessionKey;
  String? _sessionToken;

  /// `room \u0000 identity` of a join token; null when it cannot be read (then no
  /// dedupe applies and connect() behaves as before).
  @visibleForTesting
  static String? gravixSessionKey(String token) {
    try {
      final p = GravixRtcJwtPayload.fromToken(token);
      final room = p?.video?.room;
      final identity = p?.identity;
      if (room == null || room.isEmpty || identity == null || identity.isEmpty) return null;
      return '$room\u0000$identity';
    } catch (_) {
      return null;
    }
  }

  Future<bool> _connectOnce({
    required String url,
    required String token,
    bool publishMic = false,
    bool enableVideo = false,
    bool lowDataMode = false,
    List<String> regionUrls = const <String>[],
    List<GravixRegionUrl> regionEntries = const <GravixRegionUrl>[],
    // The room's home region (a viewer / guest in someone else's room; the
    // token's `home_region`): the start-up measurement's pick moves to it when it
    // is within max(25 ms, 30 %) of the fastest region, so the join skips the
    // relay hop to the host's region. Hosts pass none. See gravixPickMeasuredRegion.
    String? homeRegion,
    bool regionProbe = false,
    bool regionDecisionCache = true,
    bool regionReprobeOnRestart = false,
    GravixJoinTimelineInput? joinTimeline,
    bool parallelAudioSession = false,
    // [analyticsUrl] the analytics collector's base url for THIS join's report
    //   (overrides the service's [analytics]); see [GravixAnalytics].
    String? analyticsUrl,
    // <candidate:fastAnswer>
    // [fastAnswer] EXPERIMENTAL, opt-in. Send the subscriber answer as soon as it
    //   is created instead of after `setLocalDescription` returns. On a phone the
    //   first audio offer's `setLocalDescription` takes ~350 ms (audio playout
    //   starts inside it) and the SFU forwards nothing until it has the answer.
    //   Risk: media can arrive before the local description is applied - see
    //   `gravixAnswerSubscriberOffer` and doc/FAST_CONNECT_INTEGRATION.md.
    bool fastAnswer = false,
    // </candidate:fastAnswer>
    // <candidate:earlyCallAudio>
    // [earlyCallAudio] EXPERIMENTAL, opt-in, Android only. Activate call audio
    //   (focus, communication mode, route) at the WebSocket dial instead of when the
    //   first remote audio track arrives - see [GravixEarlyCallAudio]. The user
    //   hears other apps' audio pause ~0.5 s earlier than today; the microphone is
    //   not touched. Ignored under audio routing v2.
    bool earlyCallAudio = false,
    // </candidate:earlyCallAudio>
    // [publishInBackground] opt-in (2026-09-29). connect() returns once the peer
    //   connection is up; the mic (and camera) publication, the music-mixer
    //   install and the audio route run behind it. Field logs (Android, Kuwait ->
    //   doh1, ~50 ms RTT): ~0.5 s between pcConnected and connect() returning,
    //   spent publishing the mic (track create + capture start + AddTrack round
    //   trip + publisher renegotiation) and, in a video room, opening and
    //   publishing the camera. Nothing the user hears depends on it: remote audio
    //   plays from the subscriber side. The timeline's `micPublished` mark says
    //   when the mic went live; setMicEnabled / setCameraEnabled / disconnect wait
    //   for the initial publication. Off = exactly the old order.
    bool publishInBackground = false,
    // [red] RED (redundant audio) for the microphone: on (default, as 0.4.3), off,
    //   or auto = plain Opus until the uplink loses >= [redLossThresholdPct] % for
    //   ~20 s (not with an RTT above 1.5 s), then the mic is republished with RED
    //   once. RED roughly doubles the
    //   audio upload (field 2026-09-30: ~125 vs ~50 kbps) and recovers lost
    //   packets instead of concealing them; see gravix_red_mode.dart.
    GravixRedMode red = GravixRedMode.on,
    double redLossThresholdPct = kGravixRedLossThresholdPct,
    // [earlyMicTrack] opt-in (2026-09-30). With [publishMic]: the microphone track
    //   (capture start, the slow part of the mic step: 140-490 ms in the field) is
    //   created right after the audio session, IN PARALLEL with the signalling, and
    //   the join's mic step only publishes it. Field Android joins: micPublished
    //   came 145-494 ms after pcConnected. Pass it only when the microphone
    //   permission is already granted (otherwise the OS dialog would come up in
    //   the middle of the join). Not before the tap: a capture running on the
    //   room-code screen lights the OS privacy indicator and takes the audio mode
    //   from other apps while the user has not joined anything.
    bool earlyMicTrack = false,
    // [dtx] Opus DTX for the microphone (2026-10-05, opt-in): during silence the
    //   encoder sends a comfort-noise frame every ~400 ms instead of 50 frames/s.
    //   Field: a seated speaker sent ~118-128 kbps continuously (64 kbps Opus x
    //   RED), silence included. Speech rooms only: Opus' voice detector can treat
    //   quiet background music as silence (singing hosts, the music mixer), so
    //   leave it off where music matters. Kept across RED auto republishes.
    bool dtx = false,
    GravixForegroundServiceOptions? foregroundService,
  }) async {
    _dtx = dtx;
    _foregroundService = foregroundService;
    final joinWatch = Stopwatch()..start();
    // latched for this join: flipping the switch mid-join changes nothing
    final fastJoin = GravixFastJoin.enabled;
    final analyticsSink = analyticsUrl != null ? GravixAnalytics(url: analyticsUrl) : analytics;
    var attemptedUrl = url;
    // a new room: nothing applied to its mic yet, and the join's mic step is ahead
    // (a tap from here on is a wish the initial publication honours)
    _wantedMic = null;
    _micApplied = null;
    final micGate = Completer<void>();
    _initialMicGate = micGate;
    // Taken (and cleared) up front, whichever path this connect then follows: an
    // early race left behind by a join that ended up not racing (remembered
    // decision, probe off, token error) must never be picked up, minutes stale,
    // by some later connect().
    final earlyRace = _earlyRace;
    _earlyRace = null;
    // Region slugs, when the caller passed them. `gravixRegionEntriesFrom`
    // pulls them straight out of the token response and keeps the slug that
    // `gravixRegionUrlsFrom` throws away; without them the cross-SDK report
    // still emits, with `unknown` slugs.
    _regionEntries = regionEntries.isNotEmpty
        ? regionEntries
        : [for (final u in regionUrls) GravixRegionUrl(region: kGravixUnknownRegion, url: u)];
    final effectiveRegionUrls = [for (final e in _regionEntries) e.url];
    _connectionId = _newConnectionId();
    _connectStartedAt = DateTime.now();
    final timeline = joinTimeline == null
        ? null
        : (GravixJoinTimelineRecorder(connectionId: _connectionId!, input: joinTimeline)
            ..mark(GravixJoinStep.connectStart)
            ..regionProbeEnabled = regionProbe);
    _probeStartedAt = null;
    _connectedAt = null;
    _firstAudioEmitted = false;
    _ignoreJoinFailureEvents = false;
    _firstAudioTimeout?.cancel();
    _firstAudioTimeout = null;
    regionReport.value = null;
    firstAudioReport.value = null;
    var report = GravixConnectionReport(
      startedAt: DateTime.now(),
      pinnedUrl: url,
      connectedUrl: url,
      regionProbeEnabled: regionProbe,
      candidateUrls: List<String>.unmodifiable(effectiveRegionUrls),
      probeResults: const [],
      fallbackReason: !regionProbe
          ? GravixRegionFallbackReason.disabled
          : effectiveRegionUrls.isEmpty
          ? GravixRegionFallbackReason.noRegionUrls
          : GravixRegionFallbackReason.none,
    );
    try {
      await disconnect(); // tear down any prior room (re-entry / minimize safety)
      // Latched for the whole connect/disconnect cycle: flipping the flag
      // mid-room must not leave v2 started and torn down on the v1 path.
      _v2Active = GravixAudioRouting.v2;
      // Assigned only now: disconnect() above ends the PREVIOUS join's timeline
      // (emitting it, if it never got its first audio) and must not see this one.
      _stopTimeline();
      _timelineEmitted = false;
      _timeline = timeline;
      // <candidate:earlyCallAudio>
      earlyCallAudioStarted = false;
      // </candidate:earlyCallAudio>
      timeline?.mark(GravixJoinStep.audioSessionStart);
      // Until 2026-09-19 this was awaited HERE, before any network work: every
      // join paid the audio-session bring-up (a platform round trip or several,
      // more on a cold start) before it sent its first byte, although nothing
      // on the network path needs the session. With [parallelAudioSession] it
      // runs alongside instead. Off = exactly the old order.
      final audioReady = (_v2Active ? _configureAudioSessionV2() : _configureAudioSession()).then(
        (_) => timeline?.mark(GravixJoinStep.audioSessionEnd),
      );
      if (parallelAudioSession) {
        // Awaited further down; if the join fails first, the rethrow below must
        // not leave this future's own error unhandled.
        audioReady.ignore();
      } else {
        await audioReady;
      }

      // The mic track, created while the signalling runs (earlyMicTrack). After
      // the audio session (the capture must open in call mode) and the mixer
      // install (its callback must be in before recording starts); the join's mic
      // step publishes it, or disposes it when the mic is not wanted by then.
      // a leftover of an earlier connect is stopped, never just dropped (it would
      // keep capturing, with the OS privacy indicator on)
      final leftover = _earlyMic;
      _earlyMic = null;
      if (leftover != null) unawaited(_disposeEarlyMic(leftover));
      if (earlyMicTrack && publishMic && _applyMic == null) {
        final early = audioReady.then((_) async {
          try {
            await music.install();
          } catch (_) {}
          timeline?.notePath('svc:earlyMicStart');
          await GravixEngineMicMute.release();
          final t = await LocalAudioTrack.create(_audioCaptureOptions);
          timeline?.notePath('svc:earlyMicReady');
          return t;
        });
        early.ignore();
        _earlyMic = early;
      }

      // The race runs only when explicitly enabled AND the gateway actually
      // sent regions. Either condition absent and we never touch the network:
      // same URL, same call sequence, no added latency.
      var connectUrl = url;
      var connectLadder = const <String>[];
      GravixRegionRaceOutcome? raceOutcome;
      var fromCache = false;
      final remembered = regionProbe && regionDecisionCache && effectiveRegionUrls.isNotEmpty
          ? _regionCache.read(url, effectiveRegionUrls)
          : null;
      // Start-up measurement first (parity with React 0.4.0/0.5.0, 2026-09-27):
      // when the app ran gravixStartRegionMeasurement and it is fresh, the join
      // goes to the fastest measured region -- a lookup, nothing sent. A token
      // minted by the app's own backend carries no region list: the measured
      // regions are the list then (only when [url] is one of them).
      final measuredList = _regionEntries.isNotEmpty ? _regionEntries : gravixMeasuredCandidates(url);
      final measuredPick = gravixPickMeasuredRegion(url, measuredList, homeRegion: homeRegion);
      if (measuredPick != null) {
        if (_regionEntries.isEmpty) _regionEntries = measuredList;
        _probeStartedAt = DateTime.now();
        timeline
          ?..regionFromCache = true
          ..mark(GravixJoinStep.regionProbeStart)
          ..mark(GravixJoinStep.regionProbeEnd);
        raceOutcome = GravixRegionRaceOutcome(
          results: const [],
          elapsed: Duration.zero,
          winner: measuredPick.url,
          fallbackReason: GravixRegionFallbackReason.none,
        );
        connectUrl = measuredPick.url;
        connectLadder = gravixRegionFallbackLadder(
          outcome: raceOutcome,
          candidates: [for (final e in measuredList) e.url],
          pinnedUrl: url,
        );
        report = report.copyWith(connectedUrl: connectUrl, winningRegionUrl: measuredPick.url);
        connectionReport.value = report;
        debugPrint('🌍 region: ${measuredPick.url} measured at start-up');
      } else if (remembered != null) {
        // Repeat join: go now, and let the race run behind it. The background
        // race is never awaited and cannot fail this connect; it only decides
        // what the NEXT join remembers.
        _probeStartedAt = DateTime.now();
        fromCache = true;
        timeline?.regionFromCache = true;
        final entries = _regionEntries;
        unawaited(
          _regionProber
              .raceEntries(entries, pinnedUrl: url)
              .then((fresh) => _regionCache.record(url, fresh, candidates: entries), onError: (Object _) {}),
        );
        raceOutcome = GravixRegionRaceOutcome(
          results: const [],
          elapsed: Duration.zero,
          winner: remembered.url,
          fallbackReason: GravixRegionFallbackReason.none,
        );
        connectUrl = remembered.url;
        // Nothing probed, nothing failed: the other candidates in gateway
        // order, then the pinned url.
        connectLadder = gravixRegionFallbackLadder(
          outcome: raceOutcome,
          candidates: effectiveRegionUrls,
          pinnedUrl: url,
        );
        report = report.copyWith(connectedUrl: connectUrl, winningRegionUrl: remembered.url);
        connectionReport.value = report;
        debugPrint('🌍 region: ${remembered.url} from memory (${remembered.rtt.inMilliseconds}ms last race)');
      } else if (regionProbe && effectiveRegionUrls.isNotEmpty) {
        _probeStartedAt = DateTime.now();
        // raceEntries, not race: an entry carrying the gateway's probe_url is
        // probed at that endpoint and region-verified. With no probe_url on any
        // entry it is exactly race(). The pinned url gets the 15ms tie-break
        // (JS parity): it keeps the join unless another region is clearly faster.
        timeline
          ?..regionFromCache = false
          ..mark(GravixJoinStep.regionProbeStart);
        // With parallelTokenAndProbe the race may already be running (or done):
        // what is awaited here is then only what is LEFT of it, and that
        // remainder is what `ms.regionProbe` reports - the tap-path cost.
        final outcome =
            await (_matchingEarlyRace(earlyRace, url, _regionEntries) ??
                _regionProber.raceEntries(_regionEntries, pinnedUrl: url));
        timeline?.mark(GravixJoinStep.regionProbeEnd);
        raceOutcome = outcome;
        if (regionDecisionCache) _regionCache.record(url, outcome, candidates: _regionEntries);
        connectUrl = outcome.winner ?? url;
        // What to try if the winner's WebSocket refuses: the remaining
        // candidates, then the pinned url. Empty when there is nothing else.
        connectLadder = gravixRegionFallbackLadder(outcome: outcome, candidates: effectiveRegionUrls, pinnedUrl: url);
        report = report.copyWith(
          connectedUrl: connectUrl,
          winningRegionUrl: outcome.winner,
          probeResults: outcome.results,
          regionSelection: outcome.elapsed,
          fallbackReason: outcome.fallbackReason,
        );
        connectionReport.value = report;
        debugPrint(
          outcome.winner == null
              ? '🌍 region probe: no responder (${outcome.fallbackReason.name}), using pinned $url'
              : '🌍 region probe: ${outcome.winner} won in ${outcome.elapsed.inMilliseconds}ms',
        );
      }

      _url = url;
      _joinWatch = joinWatch;
      _firstAudioSeen = false;

      // v2 routing must own the session BEFORE a Room exists: it captures its
      // foreign-call baseline before anything of ours writes AudioManager, and
      // takes the session off Room lifecycle (see _configureAudioSessionV2). So
      // under v2 the overlap is limited to the pure-HTTP step above (the probe
      // race); only v1 also overlaps the WebSocket/ICE/DTLS below.
      if (parallelAudioSession && _v2Active) await audioReady;

      final room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: enableVideo, // only meaningful for video
          dynacast: true, // server stops forwarding unsubscribed tracks → CPU saver
          defaultAudioCaptureOptions: _audioCaptureOptions,
          defaultAudioPublishOptions: _audioPublishOptions(red: red == GravixRedMode.on),
          defaultVideoPublishOptions: _videoPublishOptions(lowDataMode),
          // AUTO DATA-SAVER needs republish-with-new-options WITHOUT killing
          // the capturer (and the beauty processor attached to its source):
          // unpublish must NOT stop the local track.
          stopLocalTrackOnUnpublish: false,
          reconnectPolicy: reconnectPolicy,
          foregroundService: foregroundService,
          // (RoomOptions.fastPublish used to be set here. Nothing reads it - not
          // in this fork and not upstream; publisher negotiation is started early
          // by the SERVER's JoinResponse.fastPublish, in engine.dart. Setting it
          // only suggested a join-time optimisation that was not happening.)
        ),
      );

      // <candidate:fastAnswer>
      room.engine.gravixFastAnswer = fastAnswer;
      // </candidate:fastAnswer>
      // <candidate:earlyCallAudio>
      // WHEN matters as much as whether. The activation occupies Android's main
      // thread (Flutter's platform thread) for ~200 ms wherever it is put, and
      // every platform-channel call made meanwhile waits behind it. Started at the
      // top of connect() it simply moved the wait: the audio-session step went from
      // 18 to 230 ms (phone, LAN, 2026-09-20). The one stretch of a join that needs
      // no platform call is the WebSocket dial (DNS + TCP + TLS + upgrade, in
      // dart:io) - so it starts when the signal client says it is about to dial,
      // once per connect() even if the connect ladder dials again. Not under
      // routing v2, which owns session activation itself.
      if (earlyCallAudio && !_v2Active) {
        var fired = false;
        final cancel = room.engine.signalClient.events.on<SignalConnectingEvent>((_) {
          if (fired) return;
          fired = true;
          timeline?.notePath('svc:earlyCallAudioStart');
          unawaited(
            GravixEarlyCallAudio.start().then((started) {
              earlyCallAudioStarted = started;
              timeline?.notePath('svc:earlyCallAudioDone', detail: started);
            }),
          );
        });
        _earlyCallAudioCancel = cancel;
      }
      // </candidate:earlyCallAudio>
      final phaseSink = onJoinPhase;
      if (phaseSink != null) {
        unawaited(_joinPhases?.dispose());
        _joinPhases = room.watchJoinPhases(startedAt: joinTimeline?.tapAt ?? _connectStartedAt, onPhase: phaseSink);
      }
      _listener = room.createListener();
      _bindEvents(room, _listener!);
      if (timeline != null) _attachTimeline(room, timeline);

      // The winner first, then down the ladder. A probe answers over HTTPS and
      // the join goes over a WebSocket, so the winner can pass one and refuse the
      // other; this used to log the error and return false with every other
      // region - and the pinned url - untried. Re-connecting the same Room after
      // a failed attempt is what the core's own region retry does.
      final winnerUrl = connectUrl;
      attemptedUrl = connectUrl;
      _ignoreJoinFailureEvents = connectLadder.isNotEmpty;
      try {
        connectUrl = await gravixConnectWithLadder(
          urls: [connectUrl, ...connectLadder],
          attempt: (candidate) {
            attemptedUrl = candidate;
            timeline?.beginAttempt();
            return _connectRoom(room, candidate, token);
          },
        );
      } catch (_) {
        // Whatever was remembered for this pin just refused; keep the refuser
        // out of the memory for a while (it will still pass its probe).
        if (regionDecisionCache) _regionCache.forget(url, refusedUrl: winnerUrl);
        rethrow;
      }
      if (connectUrl != winnerUrl) {
        report = report.copyWith(connectedUrl: connectUrl);
        if (regionDecisionCache && raceOutcome != null) {
          // The winner refused and the ladder rescued the join. Penalise the
          // refuser, and remember where the join LANDED: a WebSocket that
          // connected beats any probe.
          _regionCache.forget(url, refusedUrl: winnerUrl);
          final landed = connectUrl;
          _regionCache.recordLanded(
            url,
            url: landed,
            region: _regionEntries
                .firstWhere(
                  (e) => e.url == landed,
                  orElse: () => GravixRegionUrl(region: kGravixUnknownRegion, url: landed),
                )
                .region,
            rtt: raceOutcome.results.where((r) => r.url == landed && r.ok).firstOrNull?.elapsed,
          );
        }
      }

      // Everything after this point (mic, routing) needs the session. Normally it
      // finished long ago: the transport above took hundreds of ms.
      if (parallelAudioSession) await audioReady;

      report = report.copyWith(connected: true, joinToConnected: joinWatch.elapsed);
      connectionReport.value = report;
      timeline?.connectedUrl = connectUrl;
      final joinMs = joinWatch.elapsedMilliseconds;

      // The region decision, the moment it is final. No await on audio, no
      // timeout, no session-length condition — a join that dies two seconds
      // later still reports which edge it landed on. This is the whole reason
      // the report is split in two.
      _connectedAt = DateTime.now();
      if (raceOutcome != null) {
        _emitRegionReport(pinnedUrl: url, chosenUrl: connectUrl, outcome: raceOutcome, cached: fromCache);
        _armFirstAudioTimeout();
      }

      _room = room;
      roomMusic.attach(room);
      if (regionProbe && regionReprobeOnRestart && effectiveRegionUrls.isNotEmpty) {
        room.engine.restartRegionStrategy = GravixProbeRestartStrategy(
          pinnedUrl: url,
          entries: _regionEntries,
          prober: _regionProber,
          cache: regionDecisionCache ? _regionCache : null,
        );
      }
      _seedRemoteFacing();
      isConnected.value = true;
      if (GravixForegroundService.effective(_foregroundService).enabled) {
        // the SDK's own lifecycle observer, only while the service is enabled
        GravixForegroundService.addBackgroundSink(this, setAppBackgrounded);
      }

      // Debug: periodic video stats so quality problems are diagnosable from
      // logcat (which layer viewers get, and what limits the publisher).
      // No-op in release builds — dumpVideoStats returns immediately.
      if (kDebugMode && enableVideo) {
        _statsTimer?.cancel();
        _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) => dumpVideoStats());
      }
      // Auto data-saver: hosts only (video publish), runs in release too.
      if (enableVideo) {
        lowDataActive.value = lowDataMode;
        _startQualityMonitor();
      }

      // Replicate legacy onUserJoined firing for everyone already present.
      for (final p in room.remoteParticipants.values) {
        final uid = p.identity;
        onUserJoined?.call(uid);
        // Surface any video tracks already published.
        for (final pub in p.videoTrackPublications) {
          final t = pub.track;
          if (t != null) onRemoteVideoTrack?.call(uid, t);
        }
      }

      timeline?.publishInBackground = publishInBackground;
      Future<void> publishInitial() async {
        // Music mixing: install the native mixer callback before the mic may
        // start recording (cheap no-op when the feature is unused).
        // The service's own post-connect platform calls go into the subscriber-path
        // log: they share the platform thread with the core's offer/answer handling
        // for the offer that carries the first audio track, and a serialised await is
        // one of the things that path log exists to find.
        timeline?.notePath('svc:musicInstallStart');
        try {
          await music.install();
        } catch (e) {
          debugPrint('Music mixer install skipped: $e');
        }
        timeline?.notePath('svc:musicInstallEnd');

        // Only a publisher pays this step: enabling the mic is where the OS
        // permission prompt (first run) and the capture start are paid.
        if (publishMic) timeline?.mark(GravixJoinStep.micPermissionStart);
        // Through the same serializer as every toggle (0.4.4 left this one
        // outside it: a toggle that came in while this step was blocked on the
        // permission dialog ran a second transition beside it, and a
        // setMicEnabled(false) then never returned). A tap during the join set
        // _wantedMic already and wins over [publishMic].
        _wantedMic ??= publishMic;
        if (!micGate.isCompleted) micGate.complete();
        Future<void> micStep() async {
          await (_micWorker ??= _runMicWorker());
          if (publishMic) timeline?.mark(GravixJoinStep.micPermissionEnd);
          if (publishMic) timeline?.mark(GravixJoinStep.micPublished);
          timeline?.notePath('svc:setMicDone');
        }

        // The RTC core opens the camera; the video effect (if any) is attached
        // to the new track inside setCameraEnabled.
        if (enableVideo && fastJoin) {
          // 0.4.8 (GravixFastJoin): mic and camera side by side. They are
          // independent captures, and the core no longer serialises a camera
          // publish behind a microphone one. Up to 0.4.7 the camera waited for
          // the whole mic step (capture start + AddTrack round trip), 0.2-0.55 s
          // on a phone. eagerError false: both steps finish before an error of
          // either one surfaces (the camera step reports its own errors).
          await Future.wait([micStep(), _setCameraEnabledNow(true)]);
        } else {
          await micStep();
          if (enableVideo) await _setCameraEnabledNow(true);
        }

        if (_v2Active) {
          // AFTER the track is live, and on BOTH paths. WebRTC reprograms
          // AudioManager when playout starts, so a single apply gets overwritten;
          // the ladder re-asserts once the ADM has settled. v1 applied once and
          // skipped video rooms entirely.
          GravixAudioRouting.foreignCall.ourSessionActive = true;
          GravixAudioRouting.foreignCall.start();
          GravixAudioRouting.routeManager.applyAfterTrackStart(reason: 'connect');
        } else if (!enableVideo) {
          await _routeAudioPreferringExternal();
        }
        timeline?.notePath('svc:audioRouteDone');
      }

      if (publishInBackground) {
        final publishing = publishInitial()
            .whenComplete(() {
              // a publication that failed before its mic step must not hold toggles
              if (!micGate.isCompleted) micGate.complete();
            })
            .catchError((Object e) {
              debugPrint('Gravix background publish failed: $e');
            });
        _initialPublish = publishing;
        unawaited(
          publishing.whenComplete(() {
            if (identical(_initialPublish, publishing)) _initialPublish = null;
          }),
        );
      } else {
        await publishInitial();
      }

      _redMode = red;
      if (red == GravixRedMode.auto && publishMic) _startRedAuto(redLossThresholdPct);

      debugPrint('✅ Gravix connected room="${room.name}" id="${localParticipant?.identity}"');

      if (timeline != null) {
        timeline.mark(GravixJoinStep.connectReturned);
        _armTimelineTimeout();
      }
      _queueJoinAnalytics(
        analyticsSink,
        token,
        GravixJoinAnalyticsReport(
          connectionId: _connectionId!,
          url: connectUrl,
          region: _regionOf(connectUrl),
          participantSid: room.localParticipant?.sid,
          joinMs: joinMs,
          success: true,
          regionsMeasured: _regionsMeasuredForReport(),
        ),
      );
      return true;
    } catch (e) {
      debugPrint('❌ Gravix connect error: $e');
      // earlyMicTrack: a join that failed before its mic step must not leave the
      // capture running (the app may not call disconnect() after a failed join)
      final early = _earlyMic;
      _earlyMic = null;
      if (early != null) unawaited(_disposeEarlyMic(early));
      // <candidate:earlyCallAudio>
      // A join that died before a peer connection existed leaves nothing whose
      // disposal would make flutter_webrtc give call audio back.
      if (earlyCallAudioStarted) unawaited(GravixEarlyCallAudio.stop());
      unawaited(_earlyCallAudioCancel?.call());
      _earlyCallAudioCancel = null;
      // </candidate:earlyCallAudio>
      // A join that failed still reports how far it got.
      _queueJoinAnalytics(
        analyticsSink,
        token,
        GravixJoinAnalyticsReport(
          connectionId: _connectionId!,
          url: attemptedUrl,
          region: _regionOf(attemptedUrl),
          joinMs: joinWatch.elapsedMilliseconds,
          success: false,
          error: gravixRedactError(e.toString(), token: token),
          regionsMeasured: _regionsMeasuredForReport(),
        ),
      );
      _emitTimeline(GravixJoinTimelineEnd.disconnect);
      connectionReport.value = report;
      isConnected.value = false;
      if (_ignoreJoinFailureEvents) {
        // Every url on the ladder refused. The per-attempt joinFailure events were
        // swallowed so the app was not told "disconnected" mid-retry; tell it now,
        // ONCE - which is what a single failed attempt always did.
        onDisconnected?.call();
      }
      return false;
    }
  }

  // ══ STANDBY (pre-connect the signalling host) ══════════════════════════════
  /// Opens the signalling connection's TCP + TLS for a later [connect] to [url]
  /// with [token], ahead of the user's tap; the join's WebSocket upgrade then
  /// goes over it (one round trip instead of TCP + TLS + upgrade). Resolves true
  /// when one is open; never throws. Same contract as the JS SDK's
  /// `room.standby(url, token)`: the exact url + token of the join, used for at
  /// most 110 s, a call on one older than 45 s opens a replacement, at most 4
  /// kept, a join waits up to 1.5 s for one still opening, idempotent (call it
  /// every 15-20 s from the lobby as a liveness tick). Unlike the JS SDK it is
  /// NOT a protocol-level standby socket (that one is a single-peer-connection
  /// join on the server, which this SDK does not speak): see
  /// lib/src/rtc_core/src/support/websocket/standby_io.dart. No-op on web.
  ///
  /// Also reads the device info the join's URL carries, so the tap does not.
  ///
  /// [rttMs]: the round trip to that host if the app knows it (its region probe).
  /// The join's upgrade over the standby connection gets 3 x RTT (0.5-1.5 s;
  /// 1.5 s unknown) before a fresh dial races it, and the connection that did
  /// not answer is closed (timeline `standby.outcome: stalled_redialed`).
  ///
  /// Same as [GravixStandby.open] (0.4.8), which needs no service.
  ///
  /// Not while this service is already joining or in that room as that identity
  /// (2026-10-05): nothing to warm then; resolves false.
  Future<bool> standby(String url, String token, {int? rttMs}) {
    final key = gravixSessionKey(token);
    if (key != null &&
        (_connectInFlight?.key == key ||
            gravixKeepSession(
              key: key,
              token: token,
              sessionKey: _sessionKey,
              sessionToken: _sessionToken,
              state: _room?.connectionState,
            ))) {
      return Future<bool>.value(false);
    }
    return GravixStandby.open(url, token, rttMs: rttMs);
  }

  /// Call when the app comes back to the foreground: every standby connection is
  /// closed and opened again. One opened while the app was paused (behind a
  /// permission dialog, field 2026-09-30) is not trusted -- the join's upgrade
  /// over such a connection went unanswered. Never throws.
  Future<void> reopenStandby() => GravixStandby.reopenAll();

  /// Closes every standby connection (the app goes to the background; reopen by
  /// calling [standby] again, or [reopenStandby]).
  Future<void> closeStandby() => GravixStandby.closeAll();

  /// The standby connection for (url, token): `open` (with its age), `opening`,
  /// `dead` or `none`.
  GravixStandbyState standbyState(String url, String token) => GravixStandby.state(url, token);

  // ══ CALL STATS ═════════════════════════════════════════════════════════════
  /// Round-trip time of the selected ICE candidate pair of each peer connection,
  /// ms (see [gravixSelectedPairRttMs]); null for a PC that is missing or has no
  /// measurement yet. Never throws.
  Future<({double? publisherMs, double? subscriberMs})> selectedPairRtt() async {
    final room = _room;
    if (room == null) return (publisherMs: null, subscriberMs: null);
    Future<double?> read(RTCPeerConnection? pc) async {
      if (pc == null) return null;
      try {
        final reports = await pc.getStats();
        return gravixSelectedPairRttMs([
          for (final r in reports) (id: r.id, type: r.type, timestampUs: r.timestamp, values: r.values),
        ]);
      } catch (_) {
        return null;
      }
    }

    final engine = room.engine;
    final pub = await read(engine.publisher?.pc);
    final sub = await read(engine.subscriber?.pc);
    return (publisherMs: pub, subscriberMs: sub);
  }

  // ══ PREWARM (call when the room list opens) ════════════════════════════════

  final Future<void> Function(String httpUrl) _prepareConnection;
  final Future<bool> Function() _requestMicPermission;

  /// The core's `Room.prepareConnection`, minus the Room: one HEAD to the
  /// signalling host. A Room cannot be used for this here because [connect]
  /// tears down and rebuilds its Room on every join, which would throw the
  /// warmed object away.
  ///
  /// What this is KNOWN to buy on a phone: the DNS answer is in the OS resolver
  /// cache when the WebSocket dials a moment later. What it is NOT known to
  /// buy: a TLS session resumption — the HEAD and the WebSocket use different
  /// dart:io clients, and whether the session ticket survives between them is
  /// unverified. Measure it (`ms.wsOpen` with and without); do not assume it.
  static Future<void> _defaultPrepareConnection(String httpUrl) async {
    await sdkHttpHead(Uri.parse(httpUrl)).timeout(const Duration(seconds: 3));
  }

  /// Asks for the microphone the only way available without adding a
  /// permissions plugin to every app that depends on this SDK: open an audio
  /// capture and close it at once. First run = the OS prompt, away from the tap;
  /// later runs = a few ms. It DOES light the mic indicator briefly, which is
  /// why it is off unless asked for. Apps with their own permission flow should
  /// use that and leave this off.
  static Future<bool> _defaultRequestMicPermission() async {
    final track = await LocalAudioTrack.create();
    await track.stop();
    await track.dispose();
    return true;
  }

  /// Does, BEFORE the tap, everything a join can do before the tap — so the tap
  /// itself pays only for WebSocket + ICE + DTLS.
  ///
  /// Call it when the room list opens (or a room row becomes visible):
  ///
  /// ```dart
  /// unawaited(room.prewarm(tokenProvider: provider, request: request, regionProbe: true));
  /// // … user taps …
  /// await room.connectWithTokenProvider(tokenProvider: provider, request: request, regionProbe: true);
  /// ```
  ///
  ///  1. **token** — fetched into [tokenProvider]'s cache; the join then issues
  ///     no token request.
  ///  2. **region** — with [regionProbe]: the probe race runs now and its winner
  ///     goes into the region decision cache, so the join takes the "from
  ///     memory" path and awaits no probe. (Needs `regionDecisionCache: true` on
  ///     the join, which is the default.)
  ///  3. **prepareConnection** — a HEAD to the chosen signalling host (DNS, and
  ///     whatever TLS state the platform keeps; see [_defaultPrepareConnection]).
  ///  4. **audio** — [warmAudioSession] instantiates the audio-session plugin
  ///     (its first call is the slow one) without changing any audio state.
  ///     [configureAudioSession] additionally APPLIES the call category now; on
  ///     iOS that interrupts other apps' audio the moment the list opens, so it
  ///     is off unless asked for. Ignored under audio routing v2, whose session
  ///     bring-up is tied to a room.
  ///  5. **mic** — [requestMicPermission], see [_defaultRequestMicPermission].
  ///
  /// Steps 1→2→3 run in order (each needs the previous one's answer); 4 and 5
  /// run alongside them. Never throws. Pass the SAME [regionProbe] the join will
  /// use. Safe to call repeatedly: a second call within the token's and the
  /// decision's lifetime costs one HEAD and nothing else.
  ///
  /// Nothing here touches a connected room; audio steps are skipped while one is
  /// connected.
  Future<GravixPrewarmReport> prewarm({
    required GravixTokenProvider tokenProvider,
    required GravixTokenRequest request,
    bool regionProbe = false,
    bool prepareConnection = true,
    bool warmAudioSession = true,
    bool configureAudioSession = false,
    bool requestMicPermission = false,
  }) async {
    final total = Stopwatch()..start();
    final errors = <String>[];
    Duration? tokenTook, regionTook, prepareTook, audioTook;
    bool? tokenFromCache, regionFromCache, micGranted;
    String? chosenUrl;

    Future<void> network() async {
      final GravixJoinCredentials credentials;
      final watch = Stopwatch()..start();
      try {
        credentials = await tokenProvider.getCredentials(request);
      } catch (e) {
        errors.add('token: ${e is GravixTokenException ? e.reason.name : e.runtimeType}');
        return;
      }
      tokenTook = watch.elapsed;
      tokenFromCache = credentials.fromCache;
      chosenUrl = credentials.url;

      final entries = credentials.regionEntries;
      if (regionProbe && entries.isNotEmpty) {
        watch
          ..reset()
          ..start();
        try {
          final remembered = _regionCache.read(credentials.url, credentials.regionUrls);
          if (remembered != null) {
            regionFromCache = true;
            chosenUrl = remembered.url;
          } else {
            regionFromCache = false;
            final outcome = await _regionProber.raceEntries(entries, pinnedUrl: credentials.url);
            _regionCache.record(credentials.url, outcome, candidates: entries);
            chosenUrl = outcome.winner ?? credentials.url;
          }
          regionTook = watch.elapsed;
        } catch (e) {
          errors.add('region: ${e.runtimeType}');
        }
      }

      if (prepareConnection) {
        watch
          ..reset()
          ..start();
        try {
          await _prepareConnection(toHttpUrl(chosenUrl!));
          prepareTook = watch.elapsed;
        } catch (e) {
          errors.add('prepareConnection: ${e.runtimeType}');
        }
      }
    }

    Future<void> audio() async {
      if (isConnected.value) return;
      if (warmAudioSession || configureAudioSession) {
        final watch = Stopwatch()..start();
        try {
          final session = await AudioSession.instance;
          if (configureAudioSession && !GravixAudioRouting.v2) await session.configure(_v1AudioSessionConfiguration);
          audioTook = watch.elapsed;
        } catch (e) {
          errors.add('audioSession: ${e.runtimeType}');
        }
      }
      if (requestMicPermission) {
        try {
          micGranted = await _requestMicPermission();
        } catch (e) {
          micGranted = false;
          errors.add('micPermission: ${e.runtimeType}');
        }
      }
    }

    await Future.wait<void>([network(), audio()]);
    final report = GravixPrewarmReport(
      total: total.elapsed,
      token: tokenTook,
      tokenFromCache: tokenFromCache,
      region: regionTook,
      regionFromCache: regionFromCache,
      chosenUrl: chosenUrl,
      prepareConnection: prepareTook,
      audioSession: audioTook,
      micPermissionGranted: micGranted,
      errors: List<String>.unmodifiable(errors),
    );
    debugPrint('🔥 Gravix prewarm: ${report.toJson()}');
    return report;
  }

  /// [connect], with the token coming from a [GravixTokenProvider] instead of
  /// the app. The url, the token and the `region_urls` (slug + `probe_url`
  /// included) all come out of the provider's credentials, so the probe race
  /// and the connect ladder get exactly what the gateway sent — nothing for the
  /// app to thread through by hand, and nothing to drop on the way.
  ///
  /// No added round trip: when the provider already holds a usable token
  /// for [request] — because the app called `getCredentials` or [prewarm] when
  /// the room list opened — this issues no token request at all and goes
  /// straight to [connect]. Only a cold provider pays for the token here, which
  /// is the same one request a key+secret client always paid.
  ///
  /// Returns false (and does not throw) when the token cannot be obtained, to
  /// match [connect]'s contract; the reason is in [lastTokenError].
  Future<bool> connectWithTokenProvider({
    required GravixTokenProvider tokenProvider,
    required GravixTokenRequest request,
    bool publishMic = false,
    bool enableVideo = false,
    bool lowDataMode = false,
    bool regionProbe = false,
    bool regionDecisionCache = true,
    bool regionReprobeOnRestart = false,
    bool parallelTokenAndProbe = false,
    GravixJoinTimelineInput? joinTimeline,
    bool parallelAudioSession = false,
    String? analyticsUrl,
    // <candidate:fastAnswer>
    bool fastAnswer = false,
    // </candidate:fastAnswer>
    // <candidate:earlyCallAudio>
    bool earlyCallAudio = false,
    // </candidate:earlyCallAudio>
    // see connect's `dtx`
    bool dtx = false,
    // see connect's `foregroundService`
    GravixForegroundServiceOptions? foregroundService,
  }) async {
    lastTokenError = null;
    final GravixJoinCredentials credentials;
    final tokenStart = DateTime.now();
    _earlyRace = null;
    if (parallelTokenAndProbe && regionProbe) _startEarlyRace(tokenProvider, request, regionDecisionCache);
    try {
      credentials = await tokenProvider.getCredentials(request);
    } on GravixTokenException catch (e) {
      _earlyRace = null;
      debugPrint('❌ Gravix token error: $e');
      lastTokenError = e;
      return false;
    }
    return connect(
      url: credentials.url,
      token: credentials.token,
      publishMic: publishMic,
      enableVideo: enableVideo,
      lowDataMode: lowDataMode,
      regionEntries: credentials.regionEntries,
      homeRegion: credentials.homeRegion,
      regionProbe: regionProbe,
      regionDecisionCache: regionDecisionCache,
      regionReprobeOnRestart: regionReprobeOnRestart,
      // The token step belongs to the same timeline as the join it was for. On a
      // cache hit it is ~0 ms and `tokenFromCache` says why.
      joinTimeline: joinTimeline?.copyWith(
        tokenRequestStart: tokenStart,
        tokenRequestEnd: DateTime.now(),
        tokenFromCache: credentials.fromCache,
      ),
      parallelAudioSession: parallelAudioSession,
      analyticsUrl: analyticsUrl,
      // <candidate:fastAnswer>
      fastAnswer: fastAnswer,
      // </candidate:fastAnswer>
      // <candidate:earlyCallAudio>
      earlyCallAudio: earlyCallAudio,
      // </candidate:earlyCallAudio>
      dtx: dtx,
      foregroundService: foregroundService,
    );
  }

  /// Why the last [connectWithTokenProvider] could not get a token; null when
  /// it could (or has not run).
  GravixTokenException? lastTokenError;

  // ══ TOKEN AND PROBE IN PARALLEL (parallelTokenAndProbe) ════════════════════
  //
  // The probe race needs the region list, and the region list arrives IN the
  // token response — so on a cold start the two are inherently sequential and
  // nothing here changes that. But the list changes on the scale of deployments
  // while a token lives for minutes: when this provider has ALREADY seen a
  // response for this request (now expired), the race can start on that list
  // while the fresh token is fetched. The result is used only if the fresh
  // response names the same pinned url and the same region entries; otherwise it
  // is dropped and the join races normally, as if the flag were off.
  ({String pinnedUrl, List<GravixRegionUrl> entries, Future<GravixRegionRaceOutcome> outcome})? _earlyRace;

  void _startEarlyRace(GravixTokenProvider provider, GravixTokenRequest request, bool decisionCache) {
    // A usable token means no token wait to overlap with.
    if (provider.peek(request) != null) return;
    final stale = provider.lastKnown(request);
    if (stale == null || stale.regionEntries.isEmpty) return; // cold start
    // A remembered decision means the join will not race at all.
    if (decisionCache && _regionCache.read(stale.url, stale.regionUrls) != null) return;
    final outcome = _regionProber.raceEntries(stale.regionEntries, pinnedUrl: stale.url);
    // The join may never collect it (token error, list changed).
    outcome.ignore();
    _earlyRace = (pinnedUrl: stale.url, entries: stale.regionEntries, outcome: outcome);
  }

  /// The early race, if it was run on exactly what this join would race on.
  static Future<GravixRegionRaceOutcome>? _matchingEarlyRace(
    ({String pinnedUrl, List<GravixRegionUrl> entries, Future<GravixRegionRaceOutcome> outcome})? early,
    String pinnedUrl,
    List<GravixRegionUrl> entries,
  ) {
    if (early == null || early.pinnedUrl != pinnedUrl || early.entries.length != entries.length) return null;
    for (var i = 0; i < entries.length; i++) {
      final a = early.entries[i], b = entries[i];
      if (a.url != b.url || a.region != b.region || a.probeUrl != b.probeUrl) return null;
    }
    return early.outcome;
  }

  /// v2 session bring-up. See the internal audio-routing design notes for why each
  /// step is ordered the way it is.
  Future<void> _configureAudioSessionV2() async {
    // The guard needs a room to guard; without one it does nothing.
    GravixAudioRouting.sessionGuard.host = this;

    // BEFORE anything in our stack writes AudioManager, and only while no room
    // is connected — inside a room the communication profile legitimately holds
    // MODE_IN_COMMUNICATION, and recording that as the baseline would make the
    // foreign-call detector's signal B fire forever.
    await GravixAudioRouting.foreignCall.captureBaseline();
    GravixAudioRouting.foreignCall.noteConnectStarted();

    // Take the session off Room lifecycle. `disconnect()` above is exactly the
    // stale-Room teardown that kills a live session in automatic mode.
    await GravixAudioRouting.sessionOwner.claim();
    await GravixAudioRouting.sessionOwner.start('connect');

    // The route manager owns becomingNoisy and device changes from here, so the
    // v1 becomingNoisy listener is deliberately not installed on this path.
    await GravixAudioRouting.routeManager.start();

    // Interruptions are still ours: the detector treats one as a corroborator,
    // never a verdict, and the mic-restore behaviour is unchanged from v1.
    final session = await AudioSession.instance;
    await _interruptionSub?.cancel();
    _interruptionSub = session.interruptionEventStream.listen((event) {
      GravixAudioRouting.foreignCall.onInterruptionSeen();
      _onInterruption(event);
    });
  }

  /// One definition, so a prewarm that configures the session early applies
  /// exactly what [connect] applies a moment later (values unchanged).
  static final AudioSessionConfiguration _v1AudioSessionConfiguration = AudioSessionConfiguration(
    avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
    avAudioSessionCategoryOptions:
        AVAudioSessionCategoryOptions.allowBluetooth | AVAudioSessionCategoryOptions.allowBluetoothA2dp,
    avAudioSessionMode: AVAudioSessionMode.videoChat,
    avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
    androidAudioAttributes: const AndroidAudioAttributes(
      contentType: AndroidAudioContentType.speech,
      usage: AndroidAudioUsage.voiceCommunication,
    ),
    androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    androidWillPauseWhenDucked: false,
  );

  Future<void> _configureAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(_v1AudioSessionConfiguration);

    await _interruptionSub?.cancel();
    _interruptionSub = session.interruptionEventStream.listen(_onInterruption);

    await _becomingNoisySub?.cancel();
    _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
      // Headphones unplugged mid-call — not a call interruption, just route
      // change. The OS / RTC core usually fall back to speaker on their own;
      // log it so it's visible if users report sudden loud audio.
      debugPrint('🔌 Audio route becoming noisy (headphones unplugged?)');
    });
  }

  void _onInterruption(AudioInterruptionEvent event) {
    // Pulling the status bar / notification shade or briefly minimizing fires a
    // TRANSIENT or DUCK focus loss — NOT a real interruption. Recovering from
    // those toggles the mic off and is the cause of the auto-mute. Ignore them;
    // only handle a genuine interruption (incoming phone call = unknown/pause).
    if (event.type == AudioInterruptionType.duck) {
      debugPrint('🔉 Transient duck — ignoring, keeping mic as-is');
      return;
    }

    if (event.begin) {
      debugPrint('☎️ Audio interruption STARTED (type=${event.type})');
      _wasMicEnabledBeforeInterruption = !isMicMuted.value;
    } else {
      debugPrint('✅ Audio interruption ENDED — restoring mic/session');
      _recoverAfterInterruption();
    }
  }

  @visibleForTesting
  Future<void> debugRecoverAfterInterruption({required bool micWasEnabled}) {
    _wasMicEnabledBeforeInterruption = micWasEnabled;
    return _recoverAfterInterruption();
  }

  Future<void> _recoverAfterInterruption() async {
    if (!isConnected.value) return;
    try {
      final session = await AudioSession.instance;
      await session.setActive(true); // reclaim the session from the OS

      // Force the RTC core to recreate the native audio track rather than
      // trust a track object that was bound to a now-dead session. Through the
      // mic serializer (field review 2026-09-30: this path called the core
      // directly, beside the toggle worker): off, 250 ms, then the wanted state
      // -- the state before the interruption, unless the user toggled since.
      _micRecycle = true;
      _wantedMic ??= _wasMicEnabledBeforeInterruption;
      isMicMuted.value = !_wantedMic!;
      await (_micWorker ??= _runMicWorker());
      if (_v2Active) {
        // The mic was just re-enabled, which reprograms AudioManager — this is
        // a track start like any other, so it gets the ladder, not one shot.
        GravixAudioRouting.routeManager.applyAfterTrackStart(reason: 'interruptionEnd');
      } else {
        await _routeAudioPreferringExternal(); // re-assert route post-call
      }

      debugPrint(
        '🎤 Mic state restored after interruption: '
        'enabled=$_wasMicEnabledBeforeInterruption',
      );
    } catch (e) {
      debugPrint('Error recovering audio after interruption: $e');
    }
  }

  Future<void> _disposeAudioSession() async {
    await _interruptionSub?.cancel();
    _interruptionSub = null;
    await _becomingNoisySub?.cancel();
    _becomingNoisySub = null;
    if (!_v2Active) return;
    _v2Active = false;
    final foreignCall = GravixAudioRouting.foreignCall;
    foreignCall.ourSessionActive = false;
    // Drops the baseline with it: it describes a moment that has passed, and
    // keeping it across a teardown is what let one bad reading confirm a
    // foreign call on every later join for the rest of the app's life.
    foreignCall.stop();
    await GravixAudioRouting.routeManager.dispose();
    await GravixAudioRouting.sessionOwner.stop('leave');
    GravixAudioRouting.sessionGuard.host = null;
  }

  /// Reconnect with a fresh token. Use for:
  ///  • role promotion (viewer→cohost: pass a token with canPublish=true)
  ///  • token expiry refresh
  /// There's a brief (~sub-second) audio gap. For seamless promotion, use the
  /// server-side participant update instead and skip this.
  Future<bool> reconnectWithToken(
    String newToken, {
    bool publishMic = false,
    bool enableVideo = false,
    bool lowDataMode = false,
    List<String> regionUrls = const <String>[],
    List<GravixRegionUrl> regionEntries = const <GravixRegionUrl>[],
    String? homeRegion,
    bool regionProbe = false,
    bool regionDecisionCache = true,
    bool regionReprobeOnRestart = false,
    // null = the current call's (connect's `dtx`)
    bool? dtx,
    // null = the current call's (connect's `foregroundService`)
    GravixForegroundServiceOptions? foregroundService,
  }) async {
    if (_url == null) return false;
    // regionEntries is forwarded too. Until 2026-09-19 only the bare url strings
    // were, so a reconnect lost the region slugs (the report said "unknown") and
    // every probe_url (the race fell back to HEAD on the signalling origin).
    return connect(
      url: _url!,
      token: newToken,
      publishMic: publishMic,
      enableVideo: enableVideo,
      lowDataMode: lowDataMode,
      regionUrls: regionUrls,
      regionEntries: regionEntries,
      homeRegion: homeRegion,
      regionProbe: regionProbe,
      regionDecisionCache: regionDecisionCache,
      regionReprobeOnRestart: regionReprobeOnRestart,
      dtx: dtx ?? _dtx,
      foregroundService: foregroundService ?? _foregroundService,
    );
  }

  Future<bool> _hasExternalAudioRoute() async {
    final session = await AudioSession.instance;
    final devices = await session.getDevices();
    return devices.any(
      (d) =>
          d.type == AudioDeviceType.bluetoothA2dp ||
          d.type == AudioDeviceType.bluetoothSco ||
          d.type == AudioDeviceType.bluetoothLe ||
          d.type == AudioDeviceType.wiredHeadset ||
          d.type == AudioDeviceType.wiredHeadphones,
    );
  }

  Future<void> _routeAudioPreferringExternal() async {
    if (await _hasExternalAudioRoute()) {
      await Hardware.instance.setSpeakerphoneOn(false); // let BT/wired take it
    } else {
      await Hardware.instance.setSpeakerphoneOn(true);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  EVENTS  — replaces registerEventHandler(RtcEngineEventHandler(...))
  // ═══════════════════════════════════════════════════════════════════════════
  /// Identities the core dropped during the full restart in progress that have
  /// not come back yet (null: no full restart in progress).
  Set<String>? _restartDropped;

  void _flushRestartDropped() {
    final gone = _restartDropped;
    _restartDropped = null;
    if (gone == null) return;
    for (final uid in gone) {
      debugPrint('Remote user $uid left (during the reconnect)');
      onUserOffline?.call(uid);
    }
  }

  void _bindEvents(Room room, EventsListener<RoomEvent> listener) {
    _restartDropped = null; // a new room never inherits a restart in progress
    listener
      ..on<ParticipantConnectedEvent>((e) {
        final uid = e.participant.identity;
        // re-announced after a full restart and never really gone: no callback
        if (_restartDropped?.remove(uid) ?? false) return;
        debugPrint('Remote user $uid joined');
        onUserJoined?.call(uid);
      })
      ..on<ParticipantDisconnectedEvent>((e) {
        final uid = e.participant.identity;
        activeSpeakers.value = {...activeSpeakers.value}..remove(uid);
        final dropped = _restartDropped;
        if (dropped != null) {
          // a full restart drops everyone; who really left is known at the end
          dropped.add(uid);
          return;
        }
        debugPrint('Remote user $uid left');
        onUserOffline?.call(uid);
      })
      // ActiveSpeakers gives the full speaking set each change → replace
      // wholesale.
      ..on<ActiveSpeakersChangedEvent>((e) {
        final speaking = <String>{};
        for (final p in e.speakers) {
          final uid = p.identity;
          speaking.add(uid);
        }
        // ✅ Also include local participant if they're in the speakers list
        // (the SFU sometimes excludes local from e.speakers).
        final local = _room?.localParticipant;
        if (local != null) {
          final localSpeaking = e.speakers.any((p) => p.identity == local.identity);
          if (localSpeaking) speaking.add(local.identity);
        }
        activeSpeakers.value = speaking;
      })
      // Track muted/unmuted by the remote — ≈ onUserMuteAudio.
      ..on<TrackMutedEvent>((e) {
        final uid = e.participant.identity;
        if (e.publication.kind == TrackType.AUDIO) {
          activeSpeakers.value = {...activeSpeakers.value}..remove(uid);
          onUserMuteAudio?.call(uid, true);
        }
      })
      ..on<TrackUnmutedEvent>((e) {
        final uid = e.participant.identity;
        if (e.publication.kind == TrackType.AUDIO) {
          onUserMuteAudio?.call(uid, false);
        }
      })
      // Video track ready (video rooms).
      //   ..on<TrackSubscribedEvent>((e) {
      //     final track = e.track;
      //     final uid = e.participant.identity;
      //     if (track is VideoTrack) {
      //       onRemoteVideoTrack?.call(uid, track);
      //     }
      //   })
      ..on<TrackUnsubscribedEvent>((e) {
        final uid = e.participant.identity;
        if (e.track is VideoTrack) {
          onRemoteVideoTrackRemoved?.call(uid);
        }
      })
      ..on<RoomDisconnectedEvent>((e) {
        if (_ignoreJoinFailureEvents && e.reason == DisconnectReason.joinFailure) {
          debugPrint('🌍 a region refused the join; the connect ladder is handling it');
          return;
        }
        debugPrint('⚠️ Gravix disconnected: ${e.reason}');
        _flushRestartDropped();
        isConnected.value = false;
        onDisconnected?.call();
      })
      // RoomReconnectingEvent = a FULL restart (a resume is RoomResumingEvent): the
      // core drops every remote participant and re-creates the ones still in the
      // room, announcing them again before RoomReconnectedEvent (room.dart). The
      // identity callbacks report only the real changes: onUserOffline for who
      // left during the outage, onUserJoined for who joined, nothing for the rest
      // (0.4.6; before, everyone got onUserOffline and nobody onUserJoined).
      ..on<RoomReconnectingEvent>((_) {
        debugPrint('Gravix reconnecting…');
        _restartDropped ??= <String>{};
      })
      ..on<RoomReconnectedEvent>((_) {
        debugPrint('Gravix reconnected');
        _flushRestartDropped();
      })
      ..on<ParticipantAttributesChanged>((e) {
        final uid = e.participant.identity;
        final facing = e.participant.attributes['cameraFacing'];
        if (facing != null) {
          remoteFacing.value = {...remoteFacing.value, uid: facing};
        }
      })
      ..on<TrackSubscribedEvent>((e) {
        final uid = e.participant.identity;
        final track = e.track;
        if (track is AudioTrack) {
          _timeline?.mark(GravixJoinStep.firstAudioSubscribed);
          _noteFirstRemoteAudio();
        }
        if (track is VideoTrack) {
          final facing = e.participant.attributes['cameraFacing'];
          if (facing != null) {
            remoteFacing.value = {...remoteFacing.value, uid: facing};
          }
          onRemoteVideoTrack?.call(uid, track);
        }
      });
  }

  /// Stamps join-to-first-audio the first time a remote audio track is
  /// subscribed — the first moment the user could actually hear someone else.
  /// Only the first one counts; later subscriptions are not a new join.
  void _noteFirstRemoteAudio() {
    _emitFirstAudioReport(DateTime.now());
    if (_firstAudioSeen) return;
    final watch = _joinWatch;
    final report = connectionReport.value;
    if (watch == null || report == null) return;
    _firstAudioSeen = true;
    connectionReport.value = report.copyWith(joinToFirstAudio: watch.elapsed);
  }

  // ══ SPLIT PROBE TELEMETRY ══════════════════════════════════════════════════

  // ══ JOIN TIMELINE ══════════════════════════════════════════════════════════

  /// Subscribes to the events the engine ALREADY emits; nothing under rtc_core/
  /// is edited for this. The one step with no usable event is ICE-connected:
  /// the `onIceConnectionState` callback looks like it, and the first real phone
  /// join showed it firing AFTER the peer connection was connected (see
  /// [GravixJoinStep.iceConnected] for why). It is read from getStats() instead,
  /// by [_startIcePoll].
  void _attachTimeline(Room room, GravixJoinTimelineRecorder timeline) {
    final engine = room.engine;
    // The one observation point that needed a line in the vendored core: the
    // offer/answer steps emit no event. See Engine.gravixTimelineHook.
    engine.gravixTimelineHook = (step, detail) {
      if (!identical(_timeline, timeline)) return;
      switch (step) {
        case 'offerReceived':
          timeline.notePath('offerHandlerStart', detail: gravixOfferAudioSummary(detail as String?));
        default:
          timeline.notePath(step, detail: detail);
      }
    };
    _timelineCancels
      ..add(engine.signalClient.events.on<SignalConnectingEvent>((_) => timeline.mark(GravixJoinStep.wsConnectStart)))
      ..add(
        engine.signalClient.events.on<SignalConnectedEvent>((_) {
          timeline
            ..mark(GravixJoinStep.wsOpen)
            ..standby = engine.signalClient.gravixStandby;
        }),
      )
      // The signal client's event, not the engine's: the engine re-emits its own
      // only after it has built the peer connections, which is tens of ms of
      // phone CPU that would otherwise be booked as server time.
      ..add(engine.signalClient.events.on<SignalJoinResponseEvent>((_) => timeline.mark(GravixJoinStep.joinResponse)))
      ..add(
        engine.signalClient.events.on<SignalOfferEvent>((_) {
          timeline
            ..noteOffer()
            ..notePath('offerArrived');
        }),
      )
      ..add(engine.signalClient.events.on<SignalParticipantUpdateEvent>((_) => timeline.notePath('participantUpdate')))
      ..add(engine.events.on<EngineTrackAddedEvent>((e) => timeline.notePath('trackAdded', detail: e.track.kind)))
      ..add(
        room.events.on<TrackPublishedEvent>(
          (e) => timeline.notePath('trackPublished', detail: e.publication.kind.name),
        ),
      )
      ..add(
        room.events.on<TrackSubscribedEvent>(
          (e) => timeline.notePath('trackSubscribed', detail: e.publication.kind.name),
        ),
      )
      ..add(
        engine.events.on<EngineJoinResponseEvent>((_) {
          timeline.mark(GravixJoinStep.pcSetupDone);
          // The peer connections exist from here on, so there is something to poll.
          _startIcePoll(room, timeline);
        }),
      )
      ..add(
        engine.events.on<EnginePeerStateUpdatedEvent>((event) {
          if (!event.isPrimary ||
              event.state != RTCPeerConnectionState.RTCPeerConnectionStateConnected ||
              timeline.has(GravixJoinStep.pcConnected)) {
            return;
          }
          timeline
            ..mark(GravixJoinStep.pcConnected)
            ..notePath('pcConnected');
          // If the ICE mark is missing here it STAYS missing and `ms.dtls` is
          // null. Back-filling it with this timestamp would report a 0 ms DTLS
          // handshake, which is a fabricated number.
          _timelineIcePoll?.cancel();
          _timelineIcePoll = null;
          _timelinePairRead = _readSelectedPair(room, timeline);
          _startFirstAudioPoll(room, timeline);
        }),
      );
  }

  /// libwebrtc serves getStats() from a cache for 50 ms, so polling faster than
  /// this returns the same snapshot again and resolves nothing.
  static const Duration _icePollInterval = Duration(milliseconds: 50);

  /// Finds the moment ICE is up and DTLS is not yet, between the JoinResponse and
  /// the peer connection reporting connected. Runs only for that window (a few
  /// hundred ms) and only while a timeline is recording.
  void _startIcePoll(Room room, GravixJoinTimelineRecorder timeline) {
    _timelineIcePoll?.cancel();
    Future<void> tick() async {
      if (_timelineIcePolling || !identical(_timeline, timeline) || timeline.dtlsFirstSeenUp != null) return;
      _timelineIcePolling = true;
      try {
        _noteConnectivity(timeline, await _timelineStats(room, timeline, inbound: false));
      } catch (_) {
        // A metric. The PC may be mid-teardown on a failed attempt.
      } finally {
        _timelineIcePolling = false;
      }
    }

    _timelineIcePoll = Timer.periodic(_icePollInterval, (_) => tick());
    unawaited(tick());
  }

  void _noteConnectivity(GravixJoinTimelineRecorder timeline, List<GravixStat> stats, {bool fromPoll = true}) {
    final iceDone = timeline.iceFirstSeenUp != null;
    if (iceDone && (!fromPoll || timeline.dtlsFirstSeenUp != null)) return;
    final seen = gravixConnectivityFrom(stats);
    timeline.icePolls++;
    if (!seen.known) return;
    final now = DateTime.now();
    final staleBy = gravixStatsStaleness(stats, now);
    final takenAt = now.subtract(staleBy);
    if (fromPoll && timeline.nominatedFirstSeen == null) {
      final nominated = stats.any((st) => st.type == 'candidate-pair' && st.values['nominated'] == true);
      if (nominated) {
        timeline.nominatedFirstSeen = takenAt;
      } else {
        timeline.nominatedLastUnseen = takenAt;
      }
    }
    for (final st in stats) {
      if (st.type != 'transport') continue;
      final role = st.values['dtlsRole'];
      if (role is String) timeline.dtlsRole = role;
      final changes = st.values['selectedCandidatePairChanges'];
      if (changes is num) timeline.pairChanges = changes.toInt();
    }
    if (!iceDone) {
      if (!seen.iceUp) {
        timeline.iceLastSeenDown = takenAt;
        return;
      }
      timeline
        ..iceFirstSeenUp = takenAt
        ..dtlsUpWhenIceFirstSeenUp = seen.dtlsUp;
      // Only a snapshot of the in-between state pins the boundary. One that shows
      // DTLS up as well only says "both happened since the last snapshot".
      if (!seen.dtlsUp) timeline.mark(GravixJoinStep.iceConnected, staleBy: staleBy);
    }
    // Field review 2026-09-30 (Android ICE -> pcConnected 540-935 ms at 10 ms
    // RTT): the poll runs on until the STATS show DTLS connected, so the handshake
    // is told apart from the `connected` callback's trip to Dart. Only from the
    // poll that runs BEFORE pcConnected: a read after it proves nothing.
    if (!fromPoll) return;
    if (seen.dtlsUp) {
      timeline
        ..dtlsFirstSeenUp = takenAt
        ..notePath('stats:dtlsConnected');
      _timelineIcePoll?.cancel();
      _timelineIcePoll = null;
    } else {
      timeline.dtlsLastSeenDown = takenAt;
    }
  }

  Future<List<GravixStat>> _timelineStats(
    Room room,
    GravixJoinTimelineRecorder timeline, {
    required bool inbound,
  }) async {
    final watch = Stopwatch()..start();
    try {
      return await _readStats(room, inbound: inbound);
    } finally {
      timeline.statsCallMs.add(watch.elapsedMilliseconds);
    }
  }

  Future<List<GravixStat>> _readStats(Room room, {required bool inbound}) async {
    final seam = debugTimelineStats;
    if (seam != null) return seam(room, inbound: inbound);
    final engine = room.engine;
    // Inbound media arrives on the subscriber PC; the pair that gated the join is
    // the primary's. They are the same PC for a subscriber-primary session.
    final transport = inbound ? (engine.subscriber ?? engine.publisher) : engine.primary;
    final pc = transport?.pc;
    if (pc == null) return const <GravixStat>[];
    final reports = await pc.getStats();
    return [for (final r in reports) (id: r.id, type: r.type, timestampUs: r.timestamp, values: r.values)];
  }

  Future<void> _readSelectedPair(Room room, GravixJoinTimelineRecorder timeline) async {
    try {
      // libwebrtc answers getStats() from a cache for 50 ms. This read comes right
      // after the PC connected, so it can be handed the ICE poll's snapshot from
      // BEFORE it connected - seen on the phone as `pair: null, dtlsState: "new"`
      // on a join that was plainly connected. Read again until the snapshot has
      // caught up with the event; give up after ~300 ms and report what was seen.
      var stats = await _timelineStats(room, timeline, inbound: false);
      for (var i = 0; i < 5 && identical(_timeline, timeline); i++) {
        final seen = gravixConnectivityFrom(stats);
        if (seen.dtlsUp && gravixSelectedPairFrom(stats).pair != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        stats = await _timelineStats(room, timeline, inbound: false);
      }
      if (!identical(_timeline, timeline)) return;
      // Also the last chance to learn that ICE came up (unresolved, by then).
      _noteConnectivity(timeline, stats, fromPoll: false);
      final found = gravixSelectedPairFrom(stats);
      timeline
        ..pair = found.pair
        ..dtlsState = found.dtlsState;
      if (found.pair?.isFallback ?? false) {
        // Loud, because nothing else in the SDK says it: this join did not get
        // direct UDP to the SFU. It will have been slower, and media quality on
        // TCP/TURN is worse under loss.
        debugPrint('⚠️ Gravix join fell back to ${found.pair!.transport} (no direct UDP path to the SFU)');
      }
    } catch (e) {
      debugPrint('join timeline: could not read the selected pair: $e');
    }
  }

  void _startFirstAudioPoll(Room room, GravixJoinTimelineRecorder timeline) {
    _timelinePoll?.cancel();
    _timelinePoll = Timer.periodic(timeline.input.firstAudioPoll, (_) async {
      // getStats() on a busy phone can take longer than the interval; never
      // stack a second call on top of one that has not come back.
      if (_timelinePolling || !identical(_timeline, timeline)) return;
      _timelinePolling = true;
      try {
        final stats = await _timelineStats(room, timeline, inbound: true);
        if (!identical(_timeline, timeline)) return;
        final staleBy = gravixStatsStaleness(stats, DateTime.now());
        if (gravixHasInboundAudioPacket(stats)) {
          timeline
            ..mark(GravixJoinStep.firstAudioPacket, staleBy: staleBy)
            ..noteFirstPacket(stats);
        }
        if (gravixHasPlayedAudio(stats)) {
          timeline.mark(GravixJoinStep.firstAudioPlayoutProxy, staleBy: staleBy);
          // A packet must have arrived for a sample to be played; if the two
          // were first seen in the same tick they share its timestamp.
          timeline.mark(GravixJoinStep.firstAudioPacket, staleBy: staleBy);
          timeline.firstAudioEvidence = gravixInboundAudioEvidence(stats, staleBy);
          // The marks above are already taken, so waiting here moves no number.
          await _timelinePairRead?.timeout(const Duration(milliseconds: 500), onTimeout: () {});
          // publishInBackground: first audio can come before the mic is live; wait
          // (bounded) so the report carries `micPublished` too
          await _initialPublish?.timeout(const Duration(seconds: 3), onTimeout: () {});
          if (!identical(_timeline, timeline)) return;
          _emitTimeline(GravixJoinTimelineEnd.firstAudio);
        }
      } catch (_) {
        // Stats can throw while the PC is closing. It is a metric: keep going
        // until the timeout rather than break anything.
      } finally {
        _timelinePolling = false;
      }
    });
  }

  void _armTimelineTimeout() {
    _timelineTimeout?.cancel();
    _timelineTimeout = Timer(kGravixFirstAudioTimeout, () => _emitTimeline(GravixJoinTimelineEnd.timeout));
  }

  /// Exactly once per join, whichever comes first: the playout proxy, the
  /// timeout, the disconnect. An empty room or a failed join still reports.
  void _emitTimeline(GravixJoinTimelineEnd end) {
    final timeline = _timeline;
    if (timeline == null || _timelineEmitted) return;
    _timelineEmitted = true;
    final report = timeline.build(end, sdkVersion: kGravixSdkVersion);
    _stopTimeline();
    _flushJoinAnalytics(report);
    if (_disposed) return;
    joinTimeline.value = report;
    if (logJoinTimelines) unawaited(gravixLogJoinTimeline(report));
    onJoinTimeline?.call(report);
  }

  void _stopTimeline() {
    _timelinePoll?.cancel();
    _timelinePoll = null;
    _timelineIcePoll?.cancel();
    _timelineIcePoll = null;
    _timelineTimeout?.cancel();
    _timelineTimeout = null;
    _timelinePairRead = null;
    for (final cancel in _timelineCancels) {
      unawaited(cancel());
    }
    _timelineCancels.clear();
    _timeline = null;
  }

  /// Opaque per-connect correlation id. `connect()`-scoped and never reused,
  /// so the two events of one join can be joined and two joins cannot be
  /// confused for one.
  String _newConnectionId() => const Uuid().v4();

  /// Builds and emits the region event. Called exactly once per probed
  /// connect, at the moment the transport reports connected. The building
  /// itself is [buildGravixRegionReport] — a pure function, because that half
  /// is the cross-SDK contract and has to be testable on its own.
  void _emitRegionReport({
    required String pinnedUrl,
    required String chosenUrl,
    required GravixRegionRaceOutcome outcome,
    bool cached = false,
  }) {
    final id = _connectionId;
    final startedAt = _connectStartedAt;
    final connectedAt = _connectedAt;
    if (id == null || startedAt == null || connectedAt == null) return;

    final report = buildGravixRegionReport(
      connectionId: id,
      candidates: _regionEntries,
      pinnedUrl: pinnedUrl,
      chosenUrl: chosenUrl,
      anyResponder: outcome.winner != null,
      results: {for (final r in outcome.results) r.url: (ok: r.ok, elapsed: r.elapsed)},
      probeStartedAt: _probeStartedAt ?? startedAt,
      connectStartedAt: startedAt,
      connectedAt: connectedAt,
      cached: cached,
      regionsMeasured: _regionsMeasuredForReport(),
    );
    regionReport.value = report;
    onRegionReport?.call(report);
  }

  /// Guarantees the first-audio event fires even in a silent room, so a
  /// consumer joining the two events never waits forever for a row that is
  /// never coming.
  void _armFirstAudioTimeout() {
    _firstAudioTimeout?.cancel();
    _firstAudioTimeout = Timer(kGravixFirstAudioTimeout, () => _emitFirstAudioReport(null));
  }

  /// Emits the first-audio event exactly once per probed connect: on the first
  /// remote audio track, on the timeout, or on disconnect — whichever is
  /// first. [at] is null when no audio was ever heard.
  void _emitFirstAudioReport(DateTime? at) {
    if (_firstAudioEmitted) return;
    final id = _connectionId;
    final connectedAt = _connectedAt;
    // No region event was emitted (an unprobed connect), so there is nothing
    // to correlate with and nothing to report.
    if (id == null || connectedAt == null || regionReport.value?.connectionId != id) return;
    _firstAudioEmitted = true;
    _firstAudioTimeout?.cancel();
    _firstAudioTimeout = null;

    final report = buildGravixFirstAudioReport(connectionId: id, connectedAt: connectedAt, firstAudioAt: at);
    firstAudioReport.value = report;
    onFirstAudioReport?.call(report);
  }

  Future<void> _seedRemoteFacing() async {
    final participants = _room?.remoteParticipants.values ?? [];
    debugPrint("got remote users ${participants.map((e) => e.attributes)}");
    for (final p in participants) {
      final uid = p.identity;
      final facing = p.attributes['cameraFacing'];
      if (facing != null) {
        debugPrint("got user cameraFacing ${uid} ${facing}");
        remoteFacing.value = {...remoteFacing.value, uid: facing};
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  RED (redundant audio)  — gravix_red_mode.dart
  // ═══════════════════════════════════════════════════════════════════════════
  static const AudioCaptureOptions _audioCaptureOptions = AudioCaptureOptions(
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: true,
    highPassFilter: true, // cuts low-frequency room rumble
    typingNoiseDetection: false,
    stopAudioCaptureOnMute: false,
  );

  /// The mic track created during the join (connect's earlyMicTrack), until the
  /// join's mic step takes it.
  Future<LocalAudioTrack>? _earlyMic;

  /// The microphone's publish options. [dtx] off (the default) keeps
  /// transmitting during silence (no clipped word onsets for singing hosts);
  /// on, silence costs ~1-2 kbps instead of the full rate (connect's `dtx`).
  @visibleForTesting
  static AudioPublishOptions audioPublishOptionsFor({required bool red, bool dtx = false}) =>
      AudioPublishOptions(encoding: const AudioEncoding(maxBitrate: 64000), dtx: dtx, red: red);

  AudioPublishOptions _audioPublishOptions({required bool red}) => audioPublishOptionsFor(red: red, dtx: _dtx);

  /// DTX for this call's microphone (connect's `dtx`); kept by every republish.
  bool _dtx = false;

  /// connect's `foregroundService` (null = GravixForegroundService.defaults),
  /// kept for reconnectWithToken.
  GravixForegroundServiceOptions? _foregroundService;
  bool get dtx => _dtx;

  GravixRedMode _redMode = GravixRedMode.on;
  Timer? _redAutoTimer;

  /// The RED mode of the current call, and whether auto mode switched RED on.
  GravixRedMode get redMode => _redMode;
  bool get redAutoEnabled => _redAuto?.fired ?? false;
  GravixRedAuto? _redAuto;

  void _startRedAuto(double thresholdPct) {
    final auto = GravixRedAuto(thresholdPct: thresholdPct);
    _redAuto = auto;
    _redAutoTimer?.cancel();
    var busy = false;
    _redAutoTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (busy || !identical(_redAuto, auto) || auto.fired) return;
      busy = true;
      try {
        final pub = localParticipant?.getTrackPublicationBySource(TrackSource.microphone);
        final track = pub?.track;
        if (track is! LocalAudioTrack) return;
        final st = await track.getSenderStats();
        final rtt = st?.roundTripTime;
        if (!auto.feed(st?.packetsSent, st?.packetsLost, rttMs: rtt == null ? null : rtt * 1000.0)) return;
        debugPrint(
          '🔁 uplink loss ${auto.lastLossPct?.toStringAsFixed(1)} % >= $thresholdPct %: republishing the mic with RED',
        );
        await _republishMicWithRed(track);
        _redAutoTimer?.cancel();
        _redAutoTimer = null;
      } catch (e) {
        debugPrint('RED auto: $e');
      } finally {
        busy = false;
      }
    });
  }

  /// The mic again with RED, on a NEW track on the same capture: the old one
  /// is disposed by its unpublish, so republishing it lost the microphone
  /// (0.4.10 fix, same as the room-music DTX swap). Waits for a mic transition
  /// in flight; the mute state is kept; a refused publish is retried without
  /// RED, so the host keeps a microphone.
  Future<void> _republishMicWithRed(LocalAudioTrack track) async {
    final w = _micWorker;
    if (w != null) await w;
    final local = localParticipant;
    if (local == null) return;
    final room = _room;
    final (fresh, ok) = await gravixRepublishMic(
      local,
      track,
      wanted: _audioPublishOptions(red: true),
      fallback: track.lastPublishOptions ?? _audioPublishOptions(red: false),
      stillWanted: () => identical(_room, room),
    );
    debugPrint('RED auto: microphone republished=${fresh != null} red=$ok');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  MIC / ROLE  — replaces setClientRole + enableLocalAudio + muteLocalAudio
  // ═══════════════════════════════════════════════════════════════════════════

  /// Become a speaker (true) or listener (false).
  /// Requires token canPublish=true to actually publish.
  ///
  /// Toggles coalesce (field 2026-09-30: ~30 taps in 30 s): the LAST requested
  /// state wins, at most one mic transition runs at a time, and calls made
  /// while one runs only update the wanted state. [isMicMuted] follows the
  /// request at once (what the user tapped) and is corrected if it fails.
  /// Every caller's future completes once the wanted state is applied.
  ///
  /// A mute while nothing is live yet (the join's first enable still blocked,
  /// e.g. on a permission dialog that ends in a denial) returns at once: there is
  /// nothing to stop, and the wanted state is applied when the pending step
  /// returns. 0.4.3 had this call wait behind the blocked enable, i.e. never
  /// return.
  Future<void> setMicEnabled(bool enabled) {
    _wantedMic = enabled;
    isMicMuted.value = !enabled;
    final worker = _micWorker ??= _runMicWorker();
    if (!enabled && _micApplied != true) return Future<void>.value();
    return worker;
  }

  bool? _wantedMic;
  Future<void>? _micWorker;

  /// The mic state last applied successfully in this room (null: none yet).
  bool? _micApplied;

  /// Completed when the join's publication reaches its mic step (or ends): a
  /// toggle waits for that instead of racing the initial publish.
  Completer<void>? _initialMicGate;

  /// Audio interruption ended: re-create the native track (off, a pause, then
  /// the wanted state) as ONE step of the serializer, so a user toggle can
  /// neither interleave with it nor be undone by it.
  bool _micRecycle = false;

  Future<void> _runMicWorker() async {
    try {
      // once per burst, not per tap
      final gate = _initialMicGate;
      if (gate != null && !gate.isCompleted) {
        await gate.future.timeout(const Duration(seconds: 3), onTimeout: () {});
      }
      bool? done;
      while (true) {
        if (_micRecycle) {
          _micRecycle = false;
          try {
            await localParticipant?.setMicrophoneEnabled(false);
          } catch (e) {
            debugPrint('Error recycling the mic: $e');
          }
          await Future<void>.delayed(_micRecyclePause);
          _micApplied = false;
          done = null; // whatever was applied before, apply the wanted state again
          continue;
        }
        final want = _wantedMic;
        if (want == null || want == done) break;
        await _setMicEnabledNow(want);
        done = want;
      }
    } finally {
      // no await between the last check above and here: a tap cannot slip in
      _micWorker = null;
    }
  }

  static const Duration _micRecyclePause = Duration(milliseconds: 250);

  final Future<void> Function(bool enabled)? _applyMic;

  Future<void> _awaitInitialPublish() async {
    final p = _initialPublish;
    if (p != null) await p.timeout(const Duration(seconds: 3), onTimeout: () {});
  }

  Future<void> _setMicEnabledNow(bool enabled) async {
    try {
      final apply = _applyMic;
      final early = _earlyMic;
      _earlyMic = null;
      final local = localParticipant;
      if (apply != null) {
        await apply(enabled);
      } else if (early != null && local != null && local.getTrackPublicationBySource(TrackSource.microphone) == null) {
        // earlyMicTrack: the capture is already running (or starting); publish it
        LocalAudioTrack? track;
        try {
          track = await early;
        } catch (e) {
          debugPrint('early mic track failed ($e), creating it now');
        }
        if (track == null) {
          await local.setMicrophoneEnabled(enabled);
        } else if (enabled) {
          await local.publishAudioTrack(track);
        } else {
          await track.stop();
          await track.dispose();
        }
      } else {
        if (early != null) unawaited(_disposeEarlyMic(early));
        await local?.setMicrophoneEnabled(enabled);
      }
      isMicMuted.value = !enabled;
      _micApplied = enabled;
      // Enabling the mic opens a new AudioTrack, which reprograms AudioManager
      // and wipes the speakerphone flag. Re-assert on the ladder.
      if (_v2Active && enabled) {
        GravixAudioRouting.routeManager.applyAfterTrackStart(reason: 'micEnable');
      }
    } catch (e) {
      debugPrint('Error setMicEnabled($enabled): $e');
      // show what is actually published, not the request that failed
      final pub = localParticipant?.getTrackPublicationBySource(TrackSource.microphone);
      isMicMuted.value = pub == null || pub.muted;
    }
  }

  static Future<void> _disposeEarlyMic(Future<LocalAudioTrack> early) async {
    try {
      final t = await early;
      await t.stop();
      await t.dispose();
    } catch (_) {}
  }

  /// Direct analogue of muteLocalAudioStream(mute) — note the inverted arg.
  Future<void> muteLocalAudio(bool mute) => setMicEnabled(!mute);

  // ═══════════════════════════════════════════════════════════════════════════
  //  CAMERA  — video rooms only (audio room never calls these)
  // ═══════════════════════════════════════════════════════════════════════════
  Future<void> setCameraEnabled(bool enabled) async {
    await _awaitInitialPublish();
    await _setCameraEnabledNow(enabled);
  }

  Future<void> _setCameraEnabledNow(bool enabled) async {
    try {
      await localParticipant?.setCameraEnabled(
        enabled,
        cameraCaptureOptions: CameraCaptureOptions(
          cameraPosition: cameraPosition,
          // Capture at ~540p, not 720p. 720p is ~2x the pixels and was
          // overloading the encoder on weak links.
          params: VideoParametersPresets.h540_169,
          // 24, or the video effect's minFps hint when that is higher.
          maxFrameRate: _effect.captureFps(24),
          processor: null,
          stopCameraCaptureOnMute: false,
        ),
      );
      await _publishFacing();
      isCameraEnabled.value = enabled;

      if (enabled) {
        final pub = localParticipant?.getTrackPublicationBySource(TrackSource.camera);
        final videoTrack = pub?.track;
        if (videoTrack is LocalVideoTrack && videoTrack.mediaStreamTrack.id != null) {
          await _effect.onCameraTrack(GravixVideoEffectTarget.fromTrack(videoTrack));
        }
      } else {
        await _effect.onCameraStopped();
      }
    } catch (e) {
      debugPrint('Error setCameraEnabled($enabled): $e');
    }
  }

  Future<void> switchCamera() async {
    try {
      final pub = _room?.localParticipant?.videoTrackPublications.firstOrNull;
      final track = pub?.track;
      if (track is! LocalVideoTrack) return;

      cameraPosition = cameraPosition == CameraPosition.front ? CameraPosition.back : CameraPosition.front;

      // setCameraPosition keeps the SAME VideoSource, so the processor
      // we already attached survives. Do NOT disable() — that just sets
      // bypass=true and forces a racy re-enable.
      await track.setCameraPosition(cameraPosition);
      await _publishFacing();

      // Safety re-attach in case this device tore down the capturer. A video
      // effect's attach is idempotent for the same track id.
      if (_effect.effect != null && track.mediaStreamTrack.id != null) {
        await Future.delayed(const Duration(milliseconds: 250));
        await _effect.onCameraTrack(GravixVideoEffectTarget.fromTrack(track));
      }

      print("switch camera done");
    } catch (e) {
      debugPrint('Error switchCamera: $e');
    }
  }

  /// Local renderer for your own camera preview (video room).
  LocalVideoTrack? get localVideoTrack {
    final t = localParticipant?.videoTrackPublications.firstOrNull?.track;
    return t is LocalVideoTrack ? t : null;
  }

  // Best effort: the facing only mirrors remote tiles. A token without
  // canUpdateOwnMetadata refuses the write, and that must not turn a camera that
  // is already publishing into "camera off" (2026-09-27: setCameraEnabled threw
  // after the track was up, and isCameraEnabled stayed false).
  Future<void> _publishFacing() async {
    final isFront = cameraPosition == CameraPosition.front;
    try {
      await _room?.localParticipant?.setAttributes({'cameraFacing': isFront ? 'front' : 'back'});
    } catch (e) {
      debugPrint('cameraFacing attribute not published: $e');
    }
  }

  /// Fetch a remote user's current video track (video room) to build a
  /// renderer.
  VideoTrack? remoteVideoTrack(String uid) {
    final p = _remoteByUid(uid);
    final t = p?.videoTrackPublications.firstOrNull?.track;
    return t is VideoTrack ? t : null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  REMOTE MUTE  — replaces muteRemoteAudioStream / muteAllRemoteAudioStreams
  // ═══════════════════════════════════════════════════════════════════════════
  /// Locally stop/start hearing one remote user (client-side, like Agora).
  /// For server-enforced mute-for-everyone, keep using the server ToggleMic
  /// flow.
  Future<void> muteRemoteAudio(String uid, bool mute) async {
    final p = _remoteByUid(uid);
    if (p == null) return;
    for (final pub in p.audioTrackPublications) {
      try {
        if (mute) {
          await pub.unsubscribe();
        } else {
          await pub.subscribe();
        }
      } catch (e) {
        debugPrint('Error muteRemoteAudio($uid,$mute): $e');
      }
    }
    if (mute) {
      activeSpeakers.value = {...activeSpeakers.value}..remove(uid);
    }
  }

  void requestHighQuality(String uid) {
    // ⚠️ Forcing HIGH pins the viewer to the top simulcast layer and DEFEATS
    // adaptiveStream — on a weak downlink that layer can't arrive and the
    // video freezes. Only call this for users you know are on strong wifi, or
    // drop it and let adaptiveStream pick the layer automatically.
    final p = _remoteByUid(uid);
    final pub = p?.videoTrackPublications.firstOrNull;
    if (pub is RemoteTrackPublication) {
      pub?.setVideoQuality(VideoQuality.HIGH);
    }
  }

  Future<void> dumpVideoStats() async {
    if (!kDebugMode) return; // release: do nothing, allocate nothing

    final room = _room;
    if (room == null) return;

    // Outbound (your own publish) — one entry per simulcast layer.
    final localPub = room.localParticipant?.getTrackPublicationBySource(TrackSource.camera);
    final localTrack = localPub?.track;
    if (localTrack is LocalVideoTrack) {
      final stats = await localTrack.getSenderStats();
      for (final s in stats) {
        debugPrint(
          '📤 OUT layer=${s.rid ?? "-"} '
          '${s.frameWidth}x${s.frameHeight} @${s.framesPerSecond}fps  '
          'limit=${s.qualityLimitationReason}',
        );
      }
    }

    // Inbound (remote hosts you're watching).
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        final t = pub.track;
        if (t is RemoteVideoTrack) {
          final s = await t.getReceiverStats();
          debugPrint(
            '📥 IN ${p.identity} '
            '${s?.frameWidth}x${s?.frameHeight} @${s?.framesPerSecond}fps',
          );
        }
      }
    }
  }

  /// The receiver's own counters for inbound audio, straight from getStats():
  /// packets received / lost / discarded, samples played, concealed, inserted or
  /// removed by the jitter buffer. Null when not connected or nothing is inbound.
  ///
  /// For a measurement harness: a change that gets audio out sooner by starting
  /// it with a burst of concealment or discarded packets has not improved the
  /// join, and this is where that shows.
  Future<Map<String, Object?>?> inboundAudioCounters() async {
    final room = _room;
    if (room == null) return null;
    try {
      final pc = (room.engine.subscriber ?? room.engine.publisher)?.pc;
      if (pc == null) return null;
      for (final r in await pc.getStats()) {
        if (r.type != 'inbound-rtp' || (r.values['kind'] != 'audio' && r.values['mediaType'] != 'audio')) continue;
        return <String, Object?>{
          for (final k in const [
            'packetsReceived', 'packetsLost', 'packetsDiscarded', 'totalSamplesReceived', 'concealedSamples', //
            'silentConcealedSamples', 'concealmentEvents', 'removedSamplesForAcceleration',
            'insertedSamplesForDeceleration', 'jitterBufferEmittedCount', 'jitterBufferDelay',
          ])
            k: r.values[k],
        };
      }
    } catch (_) {
      // A metric; the room may be going away.
    }
    return null;
  }

  Future<void> muteAllRemoteAudio(bool mute) async {
    final room = _room;
    if (room == null) return;
    for (final p in room.remoteParticipants.values) {
      await muteRemoteAudio(p.identity, mute);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  LEAVE  — replaces leaveChannel + release
  // ═══════════════════════════════════════════════════════════════════════════

  /// The leave for an app going away (lifecycle `detached`, a terminating
  /// process, a foreground service's task removed): the signal leave is written
  /// FIRST, then the normal [disconnect] runs, bounded by [timeout]. Best-effort,
  /// never throws. No-op when not in a room.
  ///
  /// Field 2026-09-30: the tester app restarted mid-call six times without a
  /// leave; each left a ghost participant the others saw for 10-20 s (the SFU's
  /// ping timeout). [disconnect] sends its leave only after the publication, the
  /// audio session and the unpublish steps; a process being torn down does not
  /// live that long.
  Future<void> leaveNow({Duration timeout = const Duration(milliseconds: 1500)}) async {
    final room = _room;
    if (room == null) return;
    try {
      room.engine.gravixLeaveBestEffort();
    } catch (_) {}
    try {
      await disconnect().timeout(timeout);
    } catch (_) {}
  }

  Future<void> disconnect() async {
    // a publication still running behind connect() finishes first: tearing the
    // tracks down under it could leave a camera capturing after the leave
    await _awaitInitialPublish();
    try {
      // A session that ends before audio arrives still gets the event, with
      // null audio fields — otherwise the short sessions this split exists to
      // catch would be exactly the ones missing a first-audio row.
      _emitFirstAudioReport(null);
      _emitTimeline(GravixJoinTimelineEnd.disconnect);
      await _effect.onCameraStopped();
      await _disposeAudioSession();
      await _listener?.dispose();
      _listener = null;
      final local = _room?.localParticipant;
      if (local != null) {
        // Disable mic first — stops the encoder and releases audio focus
        await local.setMicrophoneEnabled(false);
        await local.setCameraEnabled(false);
        await local.unpublishAllTracks(notify: true);
      }
      await _room?.disconnect();
      await _room?.dispose();
    } catch (e) {
      debugPrint('Error during Gravix disconnect: $e');
    } finally {
      _statsTimer?.cancel();
      _statsTimer = null;
      _qualityTimer?.cancel();
      _qualityTimer = null;
      _redAutoTimer?.cancel();
      _redAutoTimer = null;
      _poorSince = null;
      _goodSince = null;
      if (!_disposed) {
        lowDataActive.value = false;
        isConnected.value = false;
        activeSpeakers.value = <String>{};
        remoteFacing.value = <String, String>{};
      }
      final early = _earlyMic;
      _earlyMic = null;
      if (early != null) await _disposeEarlyMic(early);
      _room = null;
      _joinWatch = null;
      GravixForegroundService.removeBackgroundSink(this);
      cameraPosition = CameraPosition.front;
      // the mic may have been muted in the audio device module (engine-wide);
      // the next room's microphone must not start silent
      await GravixEngineMicMute.release();
    }
  }

  /// Tears the service down. Disconnects, stops the music bridge, and releases
  /// every [ValueNotifier]. Call once when the app/service lifecycle ends.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // the leave first: the teardown below awaits a publication still running and
    // the audio session, and an app being disposed may not live that long
    _room?.engine.gravixLeaveBestEffort();
    await disconnect();
    await _joinPhases?.dispose();
    await _effect.dispose();
    music.dispose();
    await roomMusic.dispose();
    lowDataActive.dispose();
    activeSpeakers.dispose();
    isConnected.dispose();
    isMicMuted.dispose();
    isCameraEnabled.dispose();
    remoteFacing.dispose();
    connectionReport.dispose();
    _firstAudioTimeout?.cancel();
    _firstAudioTimeout = null;
    regionReport.dispose();
    firstAudioReport.dispose();
    _stopTimeline();
    joinTimeline.dispose();
  }

  /// Region slug of [u] from the current join's region list; '' when unknown.
  String _regionOf(String u) {
    String norm(String x) => x.replaceAll(RegExp(r'/+$'), '');
    for (final e in _regionEntries) {
      if (norm(e.url) == norm(u) && e.region != kGravixUnknownRegion) return e.region;
    }
    return '';
  }

  RemoteParticipant? _remoteByUid(String uid) {
    final room = _room;
    if (room == null) return null;
    final id = uid.toString();
    for (final p in room.remoteParticipants.values) {
      if (p.identity == id) return p;
    }
    return null;
  }
}

/// The fresh start-up region measurement for a report; a broken metric must not
/// break a join.
Map<String, Object?>? _regionsMeasuredForReport() {
  try {
    return gravixRegionsMeasuredReport();
  } catch (_) {
    return null;
  }
}

class _ConnectInFlight {
  _ConnectInFlight(this.key, this.token);
  final String? key;
  final String token;
  final Completer<bool> done = Completer<bool>();
}
