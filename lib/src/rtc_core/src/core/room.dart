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
import 'dart:typed_data' show Uint8List;

import 'package:collection/collection.dart';
import 'package:logging/logging.dart' show Level;
import 'package:meta/meta.dart';

import '../audio/audio_manager.dart';
import '../core/signal_client.dart';
import 'gravix_ice_transport.dart';
import 'gravix_join_camera.dart';
import 'gravix_join_mic.dart';
import '../data_stream/errors.dart';
import '../data_stream/stream_reader.dart';
import '../e2ee/e2ee_manager.dart';
import '../e2ee/options.dart';
import '../events.dart';
import '../exceptions.dart';
import '../extensions.dart';
import '../hardware/hardware.dart';
import '../internal/events.dart';
import '../logger.dart';
import '../managers/event.dart';
import '../managers/gravix_foreground_service.dart';
import '../options.dart';
import '../participant/local.dart';
import '../participant/participant.dart';
import '../participant/remote.dart';
import '../preconnect/pre_connect_audio_buffer.dart';
import '../proto/gravixcloud_models.pb.dart' as lk_models;
import '../proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import '../rpc/rpc_client_manager.dart';
import '../rpc/rpc_server_manager.dart';
import '../stats/stats.dart';
import '../support/disposable.dart';
import '../support/http_client.dart';
import '../support/platform.dart';
import '../support/region_url_provider.dart';
import '../support/websocket.dart' show WebSocketException;
import '../track/audio_management.dart';
import '../track/local/audio.dart';
import '../track/local/video.dart';
import '../track/track.dart';
import '../track/web/_audio_api.dart' if (dart.library.js_interop) '../track/web/_audio_html.dart' as audio;
import '../types/data_stream.dart';
import '../types/other.dart';
import '../types/rpc.dart';
import '../types/transcription_segment.dart';
import '../utils.dart' show isSVCCodec, unpackStreamId;
import '../participant/gravix_publish_runners.dart'; // GRAVIX (0.4.8)
import '../../../connect/gravix_region_failover.dart' show gravixRegionOfUrl; // GRAVIX (0.4.15)
import '../../../connect/gravix_region_report.dart' show GravixRegionUrl; // GRAVIX (0.4.15)
import '../publication/local.dart';
import '../publication/remote.dart';
import '../track/remote/audio.dart';
import '../track/remote/video.dart';
import 'gravix_media_watchdog.dart';
import 'gravix_uplink_watch.dart';
import 'engine.dart';
import 'participant_collection.dart';
import 'pending_track_queue.dart';

/// Room is the primary construct for GravixRtc conferences. It contains a
/// group of [Participant]s, each publishing and subscribing to [Track]s.
/// Notifies changes to its state via two ways, by assigning a delegate, or using
/// it as a provider.
/// Room will trigger a change notification update when
/// * state changes
/// * participant membership changes
/// * active speakers are different
/// {@category Room}
class Room extends DisposableChangeNotifier with EventsEmittable<RoomEvent> {
  // expose engine's params
  /// connection state of the room
  ConnectionState get connectionState => engine.connectionState;
  ConnectOptions get connectOptions => engine.connectOptions;
  RoomOptions get roomOptions => engine.roomOptions;

  final ParticipantCollection<RemoteParticipant> _remoteParticipants = ParticipantCollection();
  UnmodifiableMapView<String, RemoteParticipant> get remoteParticipants =>
      UnmodifiableMapView(_remoteParticipants.byIdentity);

  /// the current participant
  LocalParticipant? get localParticipant => _localParticipant;
  LocalParticipant? _localParticipant;

  /// Tests: a local participant without a join.
  @visibleForTesting
  set debugLocalParticipant(LocalParticipant? p) => _localParticipant = p;

  /// GRAVIX(0.4.12): a leave has started (disconnect, dispose, or
  /// GravixRoomService's disconnect, which marks it before its unpublish
  /// steps). Cleared by the next connect.
  bool _gravixLeaving = false;

  @internal
  bool get gravixLeaving => _gravixLeaving;

  @internal
  void gravixMarkLeaving() {
    _gravixLeaving = true;
    _gravixWakeJoinRetry();
  }

  /// GRAVIX(0.4.13): completes the wait before a join retry early (a leave).
  Completer<void>? _gravixJoinRetryWake;

  void _gravixWakeJoinRetry() {
    final wake = _gravixJoinRetryWake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// GRAVIX(0.4.12): whether the local microphone may still be republished (a
  /// room-music DTX swap, RED auto). False from the moment a leave starts:
  /// a republish racing the leave could fail repeatedly and leave a capture
  /// running after the room was gone.
  @internal
  bool get gravixCanRepublish =>
      !_gravixLeaving && !isDisposed && _localParticipant != null && connectionState == ConnectionState.connected;

  /// name of the room
  String? get name => _name;
  String? _name;

  /// metadata of the room
  String? get metadata => _metadata;
  String? _metadata;

  /// Server version
  String? get serverVersion => _serverVersion;
  String? _serverVersion;

  /// Server region
  String? get serverRegion => _serverRegion;
  String? _serverRegion;

  /// The url the session is connected to --
  /// after a region failover or a full rejoin to another region, NOT the url
  /// passed to [connect]. Kept through a resume (which reuses it) and while
  /// reconnecting; null when not connected. An app's server indicator should read
  /// this (or follow [RoomConnectedUrlChangedEvent]).
  ///
  /// A reconnect under way keeps the url, although the signal connection reads
  /// `disconnected` while a resume dials.
  String? get connectedUrl =>
      connectionState == ConnectionState.disconnected && !engine.gravixReconnectInProgress ? null : _connectedUrl;
  String? _connectedUrl;

  /// GRAVIX (0.4.15): the region of [connectedUrl] when known: the region the
  /// server named in its JoinResponse, else the entry for the url in the region
  /// list the SDK has (the server's `/settings/regions`, [gravixRegionHints]),
  /// else the start-up measurement (`gravixStartRegionMeasurement`). Null when
  /// unknown or not connected.
  String? get connectedRegion => connectedUrl == null ? null : _connectedRegion;
  String? _connectedRegion;

  /// GRAVIX (0.4.15): region / url pairs this room may connect to (e.g. the
  /// token's region list), used to name [connectedRegion]. GravixRoomService
  /// sets it from its region entries.
  List<GravixRegionUrl> gravixRegionHints = const [];

  String? _gravixRegionFor(String url) {
    final server = _serverRegion;
    if (server != null && server.isNotEmpty) return server;
    final known = <GravixRegionUrl>[
      ...gravixRegionHints,
      for (final r in _regionUrlProvider?.regionSettings?.regions ?? const <lk_rtc.RegionInfo>[])
        GravixRegionUrl(region: r.region, url: r.url),
    ];
    return gravixRegionOfUrl(url, known: known);
  }

  /// Records the url the engine is connected to now; emits
  /// [RoomConnectedUrlChangedEvent] when it differs from the previous one.
  void _gravixNoteConnectedUrl(RoomConnectedUrlChangeReason reason) {
    final url = engine.url;
    if (url == null) return;
    final region = _gravixRegionFor(url);
    final previousUrl = _connectedUrl;
    final previousRegion = _connectedRegion;
    _connectedUrl = url;
    _connectedRegion = region;
    if (previousUrl == url && previousRegion == region) return;
    if (previousUrl == url && reason == RoomConnectedUrlChangeReason.rejoin) return; // same server, region named late
    logger.info('connected url: $url (region ${region ?? 'unknown'}; was ${previousUrl ?? 'none'})');
    events.emit(
      RoomConnectedUrlChangedEvent(
        url: url,
        region: region,
        previousUrl: previousUrl,
        previousRegion: previousRegion,
        reason: reason,
      ),
    );
  }

  E2EEManager? get e2eeManager => _e2eeManager;

  E2EEManager? _e2eeManager;
  bool get isRecording => _isRecording;
  bool _isRecording = false;

  /// GRAVIX 2026-10-02: identities announced with a [ParticipantConnectedEvent]
  /// since the current full restart began; null outside one. A full restart
  /// drops every remote participant (one [ParticipantDisconnectedEvent] each) and
  /// re-creates them from the new JoinResponse, which used to announce nobody:
  /// after a full reconnect an app that keeps its participant list from these
  /// events ended up with an empty list while everyone was still in the room
  /// (emulator proof 2026-10-02: participant_left for the observer, no join).
  ///
  /// The state of the full
  /// restart in progress, one object per restart; null outside one. Handlers
  /// capture it and touch only their own: a restart that started while the
  /// previous one was still finishing used to have its state nulled by the old
  /// one's tail (an unhandled null-check crash, and the host announced as
  /// joined although it never left).
  _GravixRestartState? _restart;
  bool _audioEnabled = true;

  // Whether the one-time RoomOptions speaker preference bridge has run.
  bool _legacySpeakerBridged = false;

  lk_models.Room? _roomInfo;

  // Pending getSid() waiters, completed with '' at disposal so a Room.dispose
  // without a disconnect event can't leave them hanging. Tracked as a field
  // (and drained by the constructor's dispose routine) so repeated getSid()
  // calls don't accumulate per-call onDispose closures.
  final Set<Completer<String>> _pendingSidCompleters = {};

  /// a list of participants that are actively speaking, including local participant.
  UnmodifiableListView<Participant> get activeSpeakers => UnmodifiableListView<Participant>(_activeSpeakers);
  List<Participant> _activeSpeakers = [];

  @internal
  final Engine engine;
  // suppport for multiple event listeners
  late final EventsListener<EngineEvent> _engineListener;
  //
  late EventsListener<SignalEvent> _signalListener;

  RegionUrlProvider? _regionUrlProvider;
  String? _regionUrl;

  /// GRAVIX (0.4.15, R1 + S4): see GravixVideoStallWatch.
  late final GravixVideoStallWatch _gravixStallWatch = GravixVideoStallWatch(options: roomOptions.recovery);

  /// GRAVIX (2026-10-11, uplinkFeedbackStallFor): see GravixUplinkFeedbackWatch.
  final GravixUplinkFeedbackWatch _gravixUplinkWatch = GravixUplinkFeedbackWatch();

  /// The sender-stats listener of each published local track (one per track
  /// object: a republish after a full rejoin reuses the track) and the track's
  /// current publication (a republish makes a new one).
  final Map<Track, EventsListener<TrackEvent>> _gravixUplinkListeners = {};
  final Map<Track, LocalTrackPublication> _gravixUplinkPubs = {};

  /// GRAVIX (2026-10-11, uplinkFeedbackStallFor): every published local track
  /// feeds the uplink watch from the sender stats it already polls: a host whose
  /// uplink the server stopped answering (RTCP into a dead UDP pair after
  /// libwebrtc moved to ICE-TCP) stayed black for its viewers; a resume makes the
  /// server select again.
  void _gravixWatchUplink(LocalTrackPublication pub) {
    final track = pub.track;
    if (track == null) return;
    _gravixUplinkPubs[track] = pub; // a republish: the new publication counts
    if (_gravixUplinkListeners.containsKey(track)) return;
    final listener = track.createListener();
    _gravixUplinkListeners[track] = listener;
    bool eligible() {
      final p = _gravixUplinkPubs[track];
      return p != null &&
          connectionState == ConnectionState.connected &&
          identical(localParticipant?.trackPublications[p.sid], p) &&
          !p.muted &&
          track.isActive;
    }

    void feed(String key, SenderStats s) {
      final stall = roomOptions.recovery.uplinkFeedbackStallFor;
      if (_gravixUplinkWatch.sample(
        key,
        eligible: eligible(),
        packetsSent: s.packetsSent,
        feedback: s.remoteReportMarker,
        stallFor: stall,
      )) {
        engine.gravixRequestResume(
          'uplink ${track.source.name}: no receiver report from the server for ${stall.inSeconds} s while sending',
          uplink: true,
        );
      }
    }

    if (track is LocalAudioTrack) {
      listener.on<AudioSenderStatsEvent>((e) => feed(track.objectId.toString(), e.stats));
    } else if (track is LocalVideoTrack) {
      listener.on<VideoSenderStatsEvent>((e) {
        e.stats.forEach((rid, s) => feed('${track.objectId}:$rid', s));
      });
    }
    track.onDispose(() async {
      _gravixUplinkListeners.remove(track);
      _gravixUplinkPubs.remove(track);
      await listener.dispose();
    });
  }

  /// Whether subscribed [pub] of [participant] should be receiving media now:
  /// the session connected, the publisher still in the room publishing it,
  /// subscribed, enabled (adaptiveStream disables an invisible one), unmuted,
  /// and not paused by the server (a paused stream sends nothing; a stream
  /// whose state the server never reported counts as flowing).
  /// Video: camera only (a static screen share may legitimately send nothing).
  bool _gravixShouldFlow(RemoteParticipant participant, RemoteTrackPublication pub) =>
      connectionState == ConnectionState.connected &&
      identical(_remoteParticipants.byIdentity[participant.identity], participant) &&
      identical(participant.trackPublications[pub.sid], pub) &&
      pub.subscribed &&
      pub.enabled &&
      !pub.muted &&
      !pub.gravixServerPaused &&
      (pub.kind == TrackType.AUDIO || pub.source == TrackSource.camera);

  void _gravixWatchTrack(RemoteParticipant participant, RemoteTrackPublication pub, Track track) {
    if (!_gravixStallWatch.enabled) return;
    final sid = pub.sid;
    void act(GravixStallAction action) {
      switch (action) {
        case GravixStallAction.resume:
          engine.gravixRequestResume('${participant.identity}/${pub.source.name}: no packet');
        case GravixStallAction.rejoin:
          engine.gravixRequestRejoin('${participant.identity}/${pub.source.name}: no new frame');
        case GravixStallAction.none:
          break;
      }
    }

    final listener = track.createListener();
    if (track is RemoteVideoTrack) {
      listener.on<VideoReceiverStatsEvent>((e) {
        _gravixStallWatch.options = roomOptions.recovery;
        act(
          _gravixStallWatch.sample(
            sid,
            video: true,
            eligible: _gravixShouldFlow(participant, pub),
            packetsReceived: e.stats.packetsReceived,
            framesDecoded: e.stats.framesDecoded,
          ),
        );
      });
    } else if (track is RemoteAudioTrack) {
      listener.on<AudioReceiverStatsEvent>((e) {
        act(
          _gravixStallWatch.sample(
            sid,
            video: false,
            eligible: _gravixShouldFlow(participant, pub),
            packetsReceived: e.stats.packetsReceived,
          ),
        );
      });
    }
    track.onDispose(() async {
      _gravixStallWatch.forget(sid);
      await listener.dispose();
    });
  }

  // Agents
  final Map<String, DateTime> _transcriptionReceivedTimes = {};

  // RPC managers (caller and handler roles)
  late final RpcClientManager _rpcClientManager;
  late final RpcServerManager _rpcServerManager;

  final Map<String, DataStreamController<lk_models.DataStream_Chunk>> _byteStreamControllers = {};

  final Map<String, DataStreamController<lk_models.DataStream_Chunk>> _textStreamControllers = {};

  final Map<String, ByteStreamHandler> _byteStreamHandlers = {};

  final Map<String, TextStreamHandler> _textStreamHandlers = {};

  @internal
  late final PreConnectAudioBuffer preConnectAudioBuffer;

  // Pending subscriber tracks keyed by participantSid, for tracks arriving before metadata or before the room connected.
  late final PendingTrackQueue _pendingTrackQueue;

  // for testing — pass-through to the server manager's handler map.
  @internal
  Map<String, RpcRequestHandler> get rpcHandlers => Map.unmodifiable(_rpcServerManager.handlers);

  // Internal RPC v2 reserved topics are also stored in `_textStreamHandlers` so
  // they ride the same dispatch path, but exposing them via the public-facing
  // getter would surprise SDK consumers — filter them out here.
  @internal
  Map<String, TextStreamHandler> get textStreamHandlers => Map.fromEntries(
    _textStreamHandlers.entries.where((e) => e.key != kRpcRequestTopic && e.key != kRpcResponseTopic),
  );

  @internal
  Map<String, ByteStreamHandler> get byteStreamHandlers => _byteStreamHandlers;

  Room({
    @Deprecated('deprecated, please use connectOptions in room.connect()')
    ConnectOptions connectOptions = const ConnectOptions(),
    RoomOptions roomOptions = const RoomOptions(),
    Engine? engine,
  }) : engine = engine ?? Engine(connectOptions: connectOptions, roomOptions: roomOptions) {
    //
    _engineListener = this.engine.createListener();
    _setUpEngineListeners();

    _signalListener = this.engine.signalClient.createListener();
    _setUpSignalListeners();

    // GRAVIX (0.4.15, S3): what the resume needs to know to call the subscriber
    // connection enough (nothing live on the wire: a voice-only mute for room
    // music is live, so wireMuted, not the publication's mute)
    this.engine.gravixHasUnmutedLocalMedia = () =>
        _localParticipant?.trackPublications.values.any((p) => !(p.track?.wireMuted ?? p.muted)) ?? false;

    _rpcClientManager = RpcClientManager(this);
    _rpcServerManager = RpcServerManager(this);

    _pendingTrackQueue = PendingTrackQueue(
      ttl: this.engine.connectOptions.timeouts.subscribe,
      emitException: (event) => events.emit(event),
    );

    // Any event emitted will trigger ChangeNotifier
    events.listen((event) {
      // GRAVIX (2026-10-11, perf): guarded; the interpolation ran every room
      // event's toString() even when FINER is off (the default).
      if (logger.isLoggable(Level.FINER)) logger.finer('[RoomEvent] $event, will notifyListeners()');
      notifyListeners();
    });
    // Keep a connected flush as a fallback in case tracks arrive pre-connected but before metadata.
    events.on<RoomConnectedEvent>((event) => _flushPendingTracks());

    // GRAVIX (0.4.15, R1 + S4): every subscribed remote track feeds the stall
    // watch from the receiver stats it already polls
    events.on<TrackSubscribedEvent>((event) {
      final pub = event.publication;
      _gravixWatchTrack(event.participant, pub, event.track);
    });
    // GRAVIX (2026-10-11, uplinkFeedbackStallFor)
    events.on<LocalTrackPublishedEvent>((event) => _gravixWatchUplink(event.publication));

    _setupRpcListeners();

    _setupDataStreamListeners();

    preConnectAudioBuffer = PreConnectAudioBuffer(this);

    onDispose(() async {
      _gravixLeaving = true;
      _gravixWakeJoinRetry();
      // GRAVIX: disposed while still connected: the leave goes out before the
      // cleanup below (which unpublishes tracks and closes the socket without one)
      this.engine.gravixLeaveBestEffort();
      // complete pending getSid() waiters so they don't hang on teardown
      for (final completer in _pendingSidCompleters) {
        if (!completer.isCompleted) {
          completer.complete('');
        }
      }
      _pendingSidCompleters.clear();
      // clean up routine
      await _cleanUp();
      // reject any in-flight RPC calls
      _rpcClientManager.dispose();
      // dispose preConnectAudioBuffer
      await preConnectAudioBuffer.dispose();
      // dispose events
      await events.dispose();
      // dispose local participant
      await localParticipant?.dispose();
      // dispose all listeners for SignalClient
      await _signalListener.dispose();
      // dispose all listeners for Engine
      await _engineListener.dispose();
      // dispose the engine
      await this.engine.dispose();
    });
  }

  /// prepareConnection should be called as soon as the page is loaded, in order
  /// to speed up the connection attempt. This function will
  /// - perform DNS resolution and pre-warm the DNS cache
  /// - establish TLS connection and cache TLS keys
  ///
  /// With GravixRtc Cloud, it will also determine the best edge data center for
  /// the current client to connect to if a token is provided.

  Future<void> prepareConnection(String url, String? token) async {
    // GRAVIX (2026-10-12): a retired Gravix host gets no HEAD and no region-list
    // fetch; the typed error says why (RetiredServerException).
    RetiredServerException.check(url);
    if (engine.connectionState != ConnectionState.disconnected) {
      return;
    }
    logger.info('prepareConnection to $url');
    try {
      if (isCloudUrl(Uri.parse(url)) && token != null) {
        _regionUrlProvider = RegionUrlProvider(token: token, url: url, networkOptions: roomOptions.networkOptions);
        final regionUrl = await _regionUrlProvider!.getNextBestRegionUrl(
          measuredOrder: roomOptions.recovery.measuredRegionFailover,
        );
        // we will not replace the regionUrl if an attempt had already started
        // to avoid overriding regionUrl after a new connection attempt had started
        if (regionUrl != null && connectionState == ConnectionState.disconnected) {
          _regionUrl = regionUrl;
          await sdkHttpHead(Uri.parse(toHttpUrl(regionUrl)), networkOptions: roomOptions.networkOptions);
          logger.fine('prepared connection to ${regionUrl}');
        }
      } else {
        await sdkHttpHead(Uri.parse(toHttpUrl(url)), networkOptions: roomOptions.networkOptions);
      }
    } catch (e) {
      logger.warning('could not prepare connection: $e');
    }
  }

  Future<void> connect(
    String url,
    String token, {
    ConnectOptions? connectOptions,
    @Deprecated('deprecated, please use roomOptions in Room constructor') RoomOptions? roomOptions,
    FastConnectOptions? fastConnectOptions,
    // GRAVIX (2026-10-12, fast publish): see [GravixJoinMicrophone]
    GravixJoinMicrophone? joinMicrophone,
    // GRAVIX (2026-10-13, fast publish for video): see [GravixJoinCamera]
    GravixJoinCamera? joinCamera,
  }) async {
    // GRAVIX (2026-10-12): first, before any state changes or I/O - in
    // particular before isCloudUrl below, which would fetch the retired
    // server's (missing) region list. See RetiredServerException.
    RetiredServerException.check(url);
    var effectiveRoomOptions = roomOptions ?? this.roomOptions;
    if (lkPlatformIs(PlatformType.web) &&
        (effectiveRoomOptions.networkOptions.certificatePinning?.isEnabled ?? false)) {
      throw UnsupportedError(
        'Certificate pinning is not supported on Flutter web, '
        'remove certificatePinning from NetworkOptions when targeting web',
      );
    }
    connectOptions ??= ConnectOptions();
    _gravixLeaving = false;
    _pendingTrackQueue.updateTtl(connectOptions.timeouts.subscribe);
    // ignore: deprecated_member_use_from_same_package
    if ((effectiveRoomOptions.encryption != null || effectiveRoomOptions.e2eeOptions != null) &&
        engine.e2eeManager == null) {
      if (!lkPlatformSupportsE2EE()) {
        throw GravixRtcE2EEException('E2EE is not supported on this platform');
      }
      // ignore: deprecated_member_use_from_same_package
      final e2eeOptions = effectiveRoomOptions.encryption ?? effectiveRoomOptions.e2eeOptions;
      _e2eeManager = E2EEManager(
        e2eeOptions!.keyProvider,
        dcEncryptionEnabled: effectiveRoomOptions.encryption != null,
      );
      await _e2eeManager!.setup(this);
      engine.setE2eeManager(_e2eeManager);
    } else {
      _e2eeManager = engine.e2eeManager;
    }

    if (_e2eeManager != null) {
      // Disable backup codec when e2ee is enabled
      effectiveRoomOptions = effectiveRoomOptions.copyWith(
        defaultVideoPublishOptions: effectiveRoomOptions.defaultVideoPublishOptions.copyWith(
          backupVideoCodec: const BackupVideoCodec(enabled: false),
        ),
      );
    }

    if (_regionUrlProvider?.getServerUrl().toString() != url) {
      _regionUrl = null;
      _regionUrlProvider = null;
    }
    if (isCloudUrl(Uri.parse(url))) {
      if (_regionUrlProvider == null) {
        _regionUrlProvider = RegionUrlProvider(
          url: url,
          token: token,
          networkOptions: effectiveRoomOptions.networkOptions,
        );
      } else {
        _regionUrlProvider?.updateToken(token);
      }
      // trigger the first fetch without waiting for a response
      // if initial connection fails, this will speed up picking regional url
      // on subsequent runs
      unawaited(
        _regionUrlProvider
            // GRAVIX (2026-10-11, boundedSignalConnect): bounded like the dial.
            // signalDialCap: given as long as the join's dial (nothing waits for
            // it; device recheck "Very Bad Network": a 10 s bound dropped a list
            // a later failover could use)
            ?.fetchRegionSettings(
              timeout: effectiveRoomOptions.recovery.boundedSignalConnect
                  ? _gravixLonger(effectiveRoomOptions.recovery.signalDialCap, connectOptions.timeouts.connection)
                  : null,
            )
            .then((settings) {
              _regionUrlProvider?.setServerReportedRegions(settings);
            })
            .catchError((e) {
              logger.warning('could not fetch region settings $e');
            }),
      );
    }

    // Bridge a legacy RoomOptions speaker preference into the process-wide
    // AudioManager once, on the first connect. Skipping it on a later manual
    // connect of the same Room keeps a runtime speaker change from being
    // reverted. New code should call setSpeakerOutputPreferred directly.
    final legacySpeakerOn = effectiveRoomOptions.defaultAudioOutputOptions.speakerOn;
    if (legacySpeakerOn != null && !_legacySpeakerBridged && lkPlatformIsMobile()) {
      _legacySpeakerBridged = true;
      await AudioManager.instance.setSpeakerOutputPreferred(legacySpeakerOn);
    }

    // configure audio for native platform
    await NativeAudioManagement.start();

    // GRAVIX (2026-10-06): the Android call foreground service, when enabled
    // (off by default). Not awaited: the join never waits for it.
    unawaited(GravixForegroundService.roomConnecting(this, effectiveRoomOptions.foregroundService));

    var didConnect = false;
    // GRAVIX(0.4.13): a join that failed on the way to the media connection is
    // joined again (ConnectOptions.joinRetries). Field 2026-10-06/07: a phone in
    // a transient network stall (ICE RTT 3.9 s) timed out its peer connection
    // and the join gave up at once. joinRetries 0 = exactly the 0.4.12 path.
    // Not with a fast connect or a recording pre-connect buffer: those publish a
    // microphone inside the join (its capture can be live before the publish
    // lands), and a retry must never leave a capture behind (0.4.12 lesson).
    final maxRetries = connectOptions.joinRetries < 0 || fastConnectOptions != null || preConnectAudioBuffer.isRecording
        ? 0
        : connectOptions.joinRetries;
    // GRAVIX (2026-10-12, fast publish): the microphone published inside the
    // join (GravixJoinMicrophone). Unlike the two above it keeps the retries:
    // each attempt owns its capture and its publication, and a failed attempt's
    // are undone before the next one starts. Not beside them: they publish a
    // microphone inside the join already.
    final joinMic =
        joinMicrophone != null &&
            !preConnectAudioBuffer.isRecording &&
            !(fastConnectOptions != null &&
                (fastConnectOptions.microphone.enabled == true || fastConnectOptions.microphone.track != null))
        ? joinMicrophone
        : null;
    if (joinMicrophone != null && joinMic == null) {
      logger.warning('joinMicrophone ignored: FastConnectOptions or the pre-connect buffer publish the microphone');
    }
    // GRAVIX (2026-10-13, fast publish for video): the camera published inside
    // the join (GravixJoinCamera), beside the join microphone when both are set
    // (one first offer). Like the microphone it keeps the retries. Not beside a
    // FastConnectOptions camera: that one publishes a camera inside the join.
    final joinCam =
        joinCamera != null &&
            !(fastConnectOptions != null &&
                (fastConnectOptions.camera.enabled == true || fastConnectOptions.camera.track != null))
        ? joinCamera
        : null;
    if (joinCamera != null && joinCam == null) {
      logger.warning('joinCamera ignored: FastConnectOptions publish the camera');
    }
    // a previous connect's camera publish still in flight is abandoned (no await
    // on the connect path when there is none)
    if (_gravixJoinCamInFlight != null) await _gravixAbandonJoinCameraInFlight();
    try {
      for (var attempt = 0; ; attempt++) {
        final mayRetry = attempt < maxRetries;
        engine.gravixDeferJoinFailure = mayRetry;
        _gravixArmJoin(
          mic: joinMic == null ? null : GravixJoinMicAttempt(joinMic, attempt: attempt + 1),
          cam: joinCam == null ? null : _gravixNewJoinCamera(joinCam, attempt + 1),
        );
        try {
          await _gravixConnectAttempt(url, token, connectOptions, effectiveRoomOptions, fastConnectOptions);
          didConnect = true;
          _connectedUrl = null; // a new connect: its first url is a change
          _gravixNoteConnectedUrl(RoomConnectedUrlChangeReason.connect);
          return;
        } catch (e) {
          // the attempt is over: the join microphone's waits end now
          final micAttempt = _gravixJoinMic;
          micAttempt?.abort();
          final camAttempt = _gravixJoinCam;
          camAttempt?.abort();
          // the last attempt: the engine reported the failure itself, as before
          if (!mayRetry) rethrow;
          final retry = attempt + 1;
          // not a media-connect failure, a leave (ours, or the server's Leave,
          // which closes the engine), or an attempt that published a local
          // track (other than the join's own microphone): no retry, the join
          // fails as it always did
          if (!gravixIsJoinRetryable(e) ||
              _gravixLeaving ||
              isDisposed ||
              engine.isClosed ||
              _gravixHasPublications(except: micAttempt, exceptCamera: camAttempt)) {
            _gravixGiveUpJoin(e);
            rethrow;
          }
          await _gravixCleanUpFailedJoinAttempt();
          // after the engine's clean-up (no publisher left to renegotiate): the
          // attempt's microphone publication and capture; the next attempt
          // captures and publishes again on its own session
          final failed = micAttempt;
          if (failed != null) {
            await failed.undo(unpublish: (pub) async => _localParticipant?.removePublishedTrack(pub.sid));
          }
          // the attempt's camera too (privacy: released before the retry opens
          // the next one)
          await camAttempt?.undo(unpublish: (pub) async => _localParticipant?.removePublishedTrack(pub.sid));
          final delay = connectOptions.joinRetryDelay(retry);
          logger.warning(
            'join attempt ${attempt + 1} failed ($e); joining again in ${delay.inMilliseconds} ms '
            '(retry $retry of $maxRetries)',
          );
          events.emit(RoomJoinRetryEvent(retry: retry, maxRetries: maxRetries, delay: delay, error: e));
          if (!await _gravixWaitJoinRetry(delay)) {
            // left (disconnect / dispose) while waiting: nothing is retried
            _gravixGiveUpJoin(e);
            rethrow;
          }
        }
      }
    } finally {
      engine.gravixDeferJoinFailure = false;
      engine.gravixJoinOfferHold = null;
      final micAttempt = _gravixJoinMic;
      _gravixJoinMic = null;
      final camAttempt = _gravixJoinCam;
      _gravixJoinCam = null;
      if (didConnect && camAttempt != null) _gravixFinishJoinCamera(camAttempt);
      if (!didConnect) {
        // GRAVIX (2026-10-13): the failed join's camera is released before
        // connect() fails (privacy: no camera left open after a failed join),
        // with its publication, as the microphone below
        await camAttempt?.undo(unpublish: (pub) async => _localParticipant?.removePublishedTrack(pub.sid));
        // GRAVIX (2026-10-12): the failed join's microphone capture stops before
        // connect() fails (privacy: no microphone indicator after a failed
        // join). Its publication is removed here too: the room's own clean-up
        // (on the join failure's EngineDisconnectedEvent) may have run before a
        // publish still in flight added it, and a publication left behind on the
        // kept local participant would be found by the next join.
        await micAttempt?.undo(unpublish: (pub) async => _localParticipant?.removePublishedTrack(pub.sid));
        await NativeAudioManagement.stop();
        GravixForegroundService.roomReleased(this);
      }
    }
  }

  /// GRAVIX (2026-10-12, fast publish): the join attempt's microphone
  /// (GravixJoinMicrophone), while Room.connect runs it.
  GravixJoinMicAttempt? _gravixJoinMic;

  /// GRAVIX (2026-10-13, fast publish for video): the join attempt's camera
  /// (GravixJoinCamera), while Room.connect runs it.
  GravixJoinCameraAttempt? _gravixJoinCam;

  /// The join's camera after connect() returned, until its publish settled (a
  /// camera still opening, or a publish with an offer of its own): a leave
  /// meanwhile releases it.
  GravixJoinCameraAttempt? _gravixJoinCamInFlight;

  GravixJoinCameraAttempt _gravixNewJoinCamera(GravixJoinCamera options, int attempt) {
    final create =
        options.createTrack ??
        () {
          return GravixJoinCamera.openCamera(options.captureOptions ?? roomOptions.defaultCameraCaptureOptions);
        };
    return GravixJoinCameraAttempt(options, attempt: attempt, create: create);
  }

  /// Arms one join attempt's publishes. The microphone alone holds the
  /// publisher's first offer as before (0.4.16). With the camera, the offer is
  /// held until both have added their transceiver or given up, and each waits
  /// for the other before it negotiates: ONE first offer carries both.
  void _gravixArmJoin({GravixJoinMicAttempt? mic, GravixJoinCameraAttempt? cam}) {
    _gravixJoinMic = mic;
    _gravixJoinCam = cam;
    if (cam == null) {
      engine.gravixJoinOfferHold = mic?.offerHold;
      return;
    }
    if (mic == null) {
      engine.gravixJoinOfferHold = cam.offerHold;
      return;
    }
    mic.peersReady = cam.offerHold;
    cam.peersReady = mic.offerHold;
    engine.gravixJoinOfferHold = () async {
      final tookOver = await Future.wait<bool>([mic.offerHold(), cam.offerHold()]);
      return tookOver.any((t) => t);
    };
  }

  /// The core's region fallback dials another url within the same attempt: a
  /// microphone (camera) the first url's session already took is undone and
  /// captured afresh for the new session (one that was not started yet is kept).
  Future<void> _gravixRenewJoinMicForFallback() async {
    var m = _gravixJoinMic;
    var c = _gravixJoinCam;
    if (m != null && (m.started || m.isAborted)) {
      m.abort();
      await m.undo(unpublish: (pub) async => _localParticipant?.removePublishedTrack(pub.sid));
      m = GravixJoinMicAttempt(m.options, attempt: m.attempt);
    }
    if (c != null && (c.started || c.isAborted)) {
      c.abort();
      await c.undo(unpublish: (pub) async => _localParticipant?.removePublishedTrack(pub.sid));
      c = _gravixNewJoinCamera(c.options, c.attempt);
    }
    if (m == null && c == null) return;
    // re-armed even when kept: the hold and the pairing belong to the new session
    m?.peersReady = null;
    c?.peersReady = null;
    _gravixArmJoin(mic: m, cam: c);
  }

  /// Whether the local participant has a publication other than [except]'s
  /// microphone and [exceptCamera]'s camera (they are undone before a retry).
  bool _gravixHasPublications({GravixJoinMicAttempt? except, GravixJoinCameraAttempt? exceptCamera}) {
    final pubs = _localParticipant?.trackPublications.values;
    if (pubs == null || pubs.isEmpty) return false;
    final mic = except?.createdTrack;
    final cam = exceptCamera?.createdTrack;
    return pubs.any((p) => !(mic != null && identical(p.track, mic)) && !(cam != null && identical(p.track, cam)));
  }

  static bool _gravixMayPublishCamera(lk_models.ParticipantInfo info) {
    // no permission block: nothing says no (the server decides)
    if (!info.hasPermission()) return true;
    final p = info.permission;
    if (!p.canPublish) return false;
    return p.canPublishSources.isEmpty || p.canPublishSources.contains(lk_models.TrackSource.CAMERA);
  }

  static GravixJoinCameraFailure _gravixJoinCameraFailureOf(Object e) {
    if (e is GravixSessionReplacedException) return GravixJoinCameraFailure.sessionReplaced;
    if (e is TrackPublishException && e.message.startsWith('addTrack rejected')) {
      return GravixJoinCameraFailure.rejected;
    }
    return GravixJoinCameraFailure.publishFailed;
  }

  /// GRAVIX (2026-10-13, fast publish for video): starts the join attempt's
  /// camera publish at its JoinResponse (see [_gravixStartJoinMicrophone]).
  /// Every way that does not end in a publication releases the camera.
  void _gravixStartJoinCamera(GravixJoinCameraAttempt join, lk_models.ParticipantInfo info) {
    final local = _localParticipant;
    if (local == null || join.started || join.isAborted) return;
    join.publishing = () async {
      try {
        if (!_gravixMayPublishCamera(info)) {
          logger.info('join camera: this participant may not publish a camera; not published');
          join.fail(GravixJoinCameraFailure.notAllowed);
          join.releaseOffer(false);
          await join.release();
          return null;
        }
        final pub = await local.gravixPublishJoinCamera(join);
        if (pub == null) {
          // nothing published (not wanted, the capture failed or ended, the
          // attempt ended, a camera published otherwise): release it
          join.releaseOffer(false);
          await join.release();
          return null;
        }
        join.notePublished(pub);
        if (join.isAborted) return pub; // the attempt's undo unpublishes it
        if (join.hasEnded) {
          // ended while it was being published (before the publication listened)
          join.fail(GravixJoinCameraFailure.trackEnded);
          join.publication = null;
          await local.removePublishedTrack(pub.sid);
          await join.release();
          return null;
        }
        engine.events.emit(
          EngineJoinCameraPublishedEvent(inFirstOffer: join.inFirstOffer ?? false, attempt: join.attempt),
        );
        return pub;
      } catch (e) {
        if (!join.isAborted) {
          logger.warning('join camera: publish failed ($e); the join goes on without it');
          join.fail(_gravixJoinCameraFailureOf(e), e);
        }
        join.releaseOffer(false);
        await join.release();
        return null;
      }
    }();
  }

  /// connect() returned: the camera's publish may still be in flight. Its
  /// failure is reported once it settled (on a connected room).
  void _gravixFinishJoinCamera(GravixJoinCameraAttempt c) {
    final p = c.publishing;
    if (p == null) {
      // never started (no JoinResponse handling reached it): not needed
      c.abort();
      unawaited(c.release());
      return;
    }
    _gravixJoinCamInFlight = c;
    unawaited(
      p.then((_) {
        if (identical(_gravixJoinCamInFlight, c)) _gravixJoinCamInFlight = null;
        final reason = c.failure;
        if (reason != null && !c.isAborted && !isDisposed && !_gravixLeaving) {
          events.emit(GravixJoinCameraFailedEvent(reason: reason, error: c.failureError, attempt: c.attempt));
        }
      }),
    );
  }

  /// A leave (or a new connect) while the join's camera publish is in flight:
  /// it is abandoned and the camera released (unpublished if it got that far).
  Future<void> _gravixAbandonJoinCameraInFlight() async {
    final c = _gravixJoinCamInFlight;
    _gravixJoinCamInFlight = null;
    if (c == null) return;
    await c.undo(unpublish: (pub) async => _localParticipant?.removePublishedTrack(pub.sid));
  }

  static bool _gravixMayPublishMicrophone(lk_models.ParticipantInfo info) {
    // no permission block: nothing says no (the server decides)
    if (!info.hasPermission()) return true;
    final p = info.permission;
    if (!p.canPublish) return false;
    return p.canPublishSources.isEmpty || p.canPublishSources.contains(lk_models.TrackSource.MICROPHONE);
  }

  /// GRAVIX (2026-10-12, fast publish): starts the join attempt's microphone
  /// publish at its JoinResponse, without holding the rest of the JoinResponse
  /// handling. Its AddTrack and transceiver make the publisher's held first
  /// offer (Engine.gravixJoinOfferHold).
  void _gravixStartJoinMicrophone(GravixJoinMicAttempt join, lk_models.ParticipantInfo info) {
    final local = _localParticipant;
    if (local == null || join.started || join.isAborted) return;
    if (!_gravixMayPublishMicrophone(info)) {
      logger.info('join microphone: this participant may not publish a microphone; not published');
      join.releaseOffer(false);
      join.disposeCapture();
      return;
    }
    join.publishing = () async {
      try {
        final pub = await local.gravixPublishJoinMicrophone(join);
        if (pub == null) {
          // nothing published (not wanted, the capture failed, the attempt ended,
          // a microphone published otherwise): the capture is not needed
          join.disposeCapture();
          return null;
        }
        join.publication = pub;
        if (!join.isAborted) {
          engine.events.emit(
            EngineJoinMicPublishedEvent(inFirstOffer: join.inFirstOffer ?? false, attempt: join.attempt),
          );
        }
        return pub;
      } catch (e) {
        if (!join.isAborted) logger.warning('join microphone: publish failed ($e); the join goes on without it');
        join.releaseOffer(false);
        join.disposeCapture();
        return null;
      }
    }();
  }

  /// One join attempt: the url (or the region the provider picked), and on a
  /// cloud url one other region when that refuses (the core's own fallback).
  Future<void> _gravixConnectAttempt(
    String url,
    String token,
    ConnectOptions connectOptions,
    RoomOptions roomOptions,
    FastConnectOptions? fastConnectOptions,
  ) async {
    try {
      await engine.connect(
        _regionUrl ?? url,
        token,
        connectOptions: connectOptions,
        roomOptions: roomOptions,
        fastConnectOptions: fastConnectOptions,
        regionUrlProvider: _regionUrlProvider,
      );
    } catch (e) {
      logger.warning('could not connect to $url $e');
      if (_regionUrlProvider != null &&
          (e is WebSocketException || (e is ConnectException && e.reason != ConnectionErrorReason.NotAllowed))) {
        String? nextUrl;
        try {
          nextUrl = await _regionUrlProvider!.getNextBestRegionUrl(
            currentUrl: _regionUrl ?? url,
            measuredOrder: roomOptions.recovery.measuredRegionFailover,
            // GRAVIX (2026-10-11, boundedSignalConnect): bounded like the dial
            fetchTimeout: roomOptions.recovery.boundedSignalConnect ? connectOptions.timeouts.connection : null,
            // GRAVIX (2026-10-11, lastGoodRegionList): a list kept from an
            // earlier connect of this room to the same url
            lastGoodFallback: roomOptions.recovery.lastGoodRegionList,
            // (a WebSocketException or a non-refusal ConnectException at that url)
            currentUrlFailed: true,
          );
        } catch (error) {
          if (error is ConnectException && (error.statusCode == 401)) {
            rethrow;
          }
        }
        if (nextUrl != null) {
          logger.fine('Initial connection failed with ConnectionError: $e. Retrying with another region: ${nextUrl}');
          // a deferred failure was not cleaned up by the event handler
          if (engine.gravixDeferJoinFailure) await _gravixCleanUpFailedJoinAttempt();
          await _gravixRenewJoinMicForFallback();
          await engine.connect(
            nextUrl,
            token,
            connectOptions: connectOptions,
            roomOptions: roomOptions,
            fastConnectOptions: fastConnectOptions,
            regionUrlProvider: _regionUrlProvider,
          );
        } else {
          rethrow;
        }
      } else {
        rethrow;
      }
    }
  }

  /// GRAVIX(0.4.13): undoes a failed join attempt before the next one, without
  /// touching what the join as a whole holds (audio session, foreground service,
  /// the local participant object): the leave on the attempt's socket (the
  /// server may already have the participant; the next join must not meet it as
  /// a duplicate identity), then its remote participants, socket and peer
  /// connections. Awaited, so nothing of it can close the next attempt's dial.
  Future<void> _gravixCleanUpFailedJoinAttempt() async {
    final signal = engine.signalClient;
    if (signal.connectionState == ConnectionState.connected) {
      try {
        await signal.sendLeave();
      } catch (_) {}
    }
    final participants = _remoteParticipants.toList();
    _remoteParticipants.clear();
    for (final participant in participants) {
      await participant.removeAllPublishedTracks(notify: false);
      await participant.dispose();
    }
    _pendingTrackQueue.clear();
    _activeSpeakers.clear();
    await engine.cleanUp();
  }

  /// GRAVIX(0.4.13): a retryable join gives up: the leave on its socket (best
  /// effort), then the failure the engine deferred, so the room cleans up and
  /// emits RoomDisconnectedEvent exactly as for a join that is never retried.
  void _gravixGiveUpJoin(Object error) {
    final signal = engine.signalClient;
    if (signal.connectionState == ConnectionState.connected) {
      try {
        unawaited(signal.sendLeave());
      } catch (_) {}
    }
    engine.events.emit(EngineDisconnectedEvent(reason: Engine.gravixJoinFailureReason(error)));
  }

  /// Waits [delay] before a join retry; false when the room was left
  /// (disconnect / dispose) meanwhile, which ends the wait at once.
  Future<bool> _gravixWaitJoinRetry(Duration delay) async {
    if (_gravixLeaving || isDisposed) return false;
    final wake = _gravixJoinRetryWake = Completer<void>();
    final timer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    try {
      await wake.future;
    } finally {
      timer.cancel();
      if (identical(_gravixJoinRetryWake, wake)) _gravixJoinRetryWake = null;
    }
    return !_gravixLeaving && !isDisposed;
  }

  void _setUpSignalListeners() => _signalListener
    ..on<SignalParticipantUpdateEvent>((event) => _onParticipantUpdateEvent(event.participants))
    ..on<SignalSpeakersChangedEvent>((event) => _onSignalSpeakersChangedEvent(event.speakers))
    ..on<SignalConnectionQualityUpdateEvent>((event) => _onSignalConnectionQualityUpdateEvent(event.updates))
    ..on<SignalStreamStateUpdatedEvent>((event) => _onSignalStreamStateUpdateEvent(event.updates))
    ..on<SignalSubscribedQualityUpdatedEvent>((event) async {
      // Dynacast is off or is unsupported
      if (!roomOptions.dynacast || _serverVersion == '0.15.1') {
        logger.fine(
          'Received subscribed quality update'
          ' but Dynacast is off or server version is not supported.',
        );
        return;
      }
      // Find the publication
      final publication = localParticipant?.trackPublications[event.trackSid];
      if (publication == null) {
        logger.warning('Received subscribed quality update for unknown track (${event.trackSid})');
        return;
      }
      if (event.subscribedCodecs.isNotEmpty) {
        if (publication.track! is! LocalVideoTrack) {
          return;
        }
        final videoTrack = publication.track as LocalVideoTrack;
        final newCodecs = await videoTrack.setPublishingCodecs(event.subscribedCodecs, videoTrack);
        for (var codec in newCodecs) {
          if (isBackupCodec(codec)) {
            logger.info('publishing backup codec ${codec} for ${publication.track?.sid}');
            await localParticipant?.publishAdditionalCodecForPublication(publication, codec);
          }
        }
      } else if (event.subscribedQualities.isNotEmpty) {
        final videoTrack = publication.track as LocalVideoTrack;
        await videoTrack.setPublishingLayers(
          videoTrack,
          event.subscribedQualities,
          isSVC: isSVCCodec(videoTrack.codec ?? ''),
        );
      }
    })
    ..on<SignalSubscriptionPermissionUpdateEvent>((event) async {
      logger.fine(
        'SignalSubscriptionPermissionUpdateEvent '
        'participantSid:${event.participantSid} '
        'trackSid:${event.trackSid} '
        'allowed:${event.allowed}',
      );

      // find participant
      final participant = _remoteParticipants.bySid[event.participantSid];
      if (participant == null) {
        return;
      }
      // find track
      final publication = participant.getTrackPublicationBySid(event.trackSid);
      if (publication == null) {
        return;
      }
      //
      await publication.updateSubscriptionAllowed(event.allowed);
      emitWhenConnected(
        TrackSubscriptionPermissionChangedEvent(
          participant: participant,
          publication: publication,
          state: publication.subscriptionState,
        ),
      );
    })
    ..on<SignalRoomUpdateEvent>((event) async => _applyRoomUpdate(event.room))
    ..on<SignalRemoteMuteTrackEvent>((event) async {
      final publication = localParticipant?.trackPublications[event.sid];

      final stopOnMute = switch (publication?.source) {
        TrackSource.camera => roomOptions.defaultCameraCaptureOptions.stopCameraCaptureOnMute,
        TrackSource.microphone => roomOptions.defaultAudioCaptureOptions.stopAudioCaptureOnMute,
        _ => true,
      };

      if (event.muted) {
        await publication?.mute(stopOnMute: stopOnMute);
      } else {
        await publication?.unmute(stopOnMute: stopOnMute);
      }
    })
    ..on<SignalTrackUnpublishedEvent>((event) async {
      // unpublish local track
      await localParticipant?.removePublishedTrack(event.trackSid);
    });

  void _setUpEngineListeners() => _engineListener
    ..on<EngineJoinResponseEvent>((event) async {
      _applyRoomUpdate(event.response.room);
      _serverVersion = event.response.serverVersion;
      _serverRegion = event.response.serverRegion;

      logger.fine(
        '[Engine] Received JoinResponse, '
        'serverVersion: ${event.response.serverVersion}',
      );

      final existingLocal = _localParticipant;
      _localParticipant ??= await LocalParticipant.createFromInfo(room: this, info: event.response.participant);

      // GRAVIX(0.4.13): a join again on the same Room after a failed attempt
      // (join retry, region fallback, the service's connect ladder) gets a new
      // participant sid; the kept local participant takes it over.
      if (engine.gravixFullReconnectInProgress ||
          (existingLocal != null && existingLocal.sid != event.response.participant.sid)) {
        await _localParticipant!.updateFromInfo(event.response.participant);
      }

      // GRAVIX (2026-10-12, fast publish): the join's microphone, into the
      // publisher's first offer (a fresh join only: a full reconnect republishes
      // what is published)
      final joinMic = _gravixJoinMic;
      if (joinMic != null && !engine.gravixFullReconnectInProgress) {
        _gravixStartJoinMicrophone(joinMic, event.response.participant);
      }
      // GRAVIX (2026-10-13): the join's camera, beside it (after updateFromInfo:
      // the plan's video cap is read from the participant's attributes)
      final joinCam = _gravixJoinCam;
      if (joinCam != null && !engine.gravixFullReconnectInProgress) {
        _gravixStartJoinCamera(joinCam, event.response.participant);
      }

      // Check if preconnect buffer is recording and publish its track
      if (preConnectAudioBuffer.isRecording && preConnectAudioBuffer.localTrack != null) {
        logger.info('Publishing preconnect audio track');
        await _localParticipant!.publishAudioTrack(
          preConnectAudioBuffer.localTrack!,
          publishOptions: roomOptions.defaultAudioPublishOptions.copyWith(preConnect: true),
        );
      }

      if (connectOptions.protocolVersion.index >= ProtocolVersion.v8.index &&
          engine.fastConnectOptions != null &&
          !engine.gravixFullReconnectInProgress) {
        final options = engine.fastConnectOptions!;
        final local = _localParticipant!;
        // GRAVIX (0.4.8): collected as steps and run by gravixRunJoinPublishes --
        // side by side and without holding the rest of this handler under
        // GravixFastJoin (default), one after another and awaited here when it is
        // off (upstream). Upstream awaited mic, then camera, then screen, and only
        // then created the remote participants and emitted RoomConnectedEvent.
        final steps = <Future<void> Function()>[];

        final audio = options.microphone;
        final bool audioEnabled = audio.enabled == true || audio.track != null;

        // Only enable microphone if preconnect buffer is not active
        if (audioEnabled && !preConnectAudioBuffer.isRecording) {
          if (audio.track != null) {
            steps.add(
              () => local.publishAudioTrack(
                audio.track as LocalAudioTrack,
                publishOptions: roomOptions.defaultAudioPublishOptions,
              ),
            );
          } else {
            steps.add(
              () => local.setMicrophoneEnabled(true, audioCaptureOptions: roomOptions.defaultAudioCaptureOptions),
            );
          }
        }

        final video = options.camera;
        final bool videoEnabled = video.enabled == true || video.track != null;
        if (videoEnabled) {
          if (video.track != null) {
            steps.add(
              () => local.publishVideoTrack(
                video.track as LocalVideoTrack,
                publishOptions: roomOptions.defaultVideoPublishOptions,
              ),
            );
          } else {
            steps.add(
              () => local.setCameraEnabled(true, cameraCaptureOptions: roomOptions.defaultCameraCaptureOptions),
            );
          }
        }

        final screen = options.screen;
        final bool screenEnabled = screen.enabled == true || screen.track != null;
        if (screenEnabled) {
          if (screen.track != null) {
            steps.add(
              () => local.publishVideoTrack(
                screen.track as LocalVideoTrack,
                publishOptions: roomOptions.defaultVideoPublishOptions,
              ),
            );
          } else {
            steps.add(
              () => local.setScreenShareEnabled(
                true,
                screenShareCaptureOptions: roomOptions.defaultScreenShareCaptureOptions,
              ),
            );
          }
        }

        final sequential = gravixRunJoinPublishes(
          steps,
          onError: (e) => logger.warning('FastConnectOptions publish failed: $e'),
        );
        if (sequential != null) await sequential;
      }

      final restart = _restart;
      final kept = restart?.kept;
      restart?.kept = null;
      for (final info in event.response.otherParticipants) {
        // GRAVIX (0.4.15, S5): a participant kept across the rejoin is updated in
        // place (sid, tracks); its publications stay the same objects.
        final keptParticipant = kept != null && kept.contains(info.identity)
            ? _remoteParticipants.byIdentity[info.identity]
            : null;
        if (keptParticipant != null) {
          final oldSid = keptParticipant.sid;
          await keptParticipant.updateFromInfo(info);
          _remoteParticipants.rekey(keptParticipant, oldSid);
          await _flushPendingTracks(participant: keptParticipant);
          continue;
        }
        logger.fine(
          'Creating RemoteParticipant: sid = ${info.sid}(identity:${info.identity}) '
          'tracks:${info.tracks.map((e) => e.sid)}',
        );
        await _getOrCreateRemoteParticipant(info);
      }
      if (kept != null) {
        // the ones the new session does not list left during the outage -- or,
        // on a node where the room was just created, arrive through the relay a
        // moment later (F6, device r127 / r149: the host reported left, then
        // joined, 2 ms apart): they get rejoinAbsentGrace to reappear
        final present = {for (final info in event.response.otherParticipants) info.identity};
        final grace = roomOptions.recovery.rejoinAbsentGrace;
        for (final identity in kept.where((i) => !present.contains(i)).toList()) {
          if (grace > Duration.zero) {
            _gravixAbsentAfterRejoin[identity]?.cancel();
            _gravixAbsentAfterRejoin[identity] = Timer(grace, () => unawaited(_gravixDropAbsent(identity)));
          } else {
            await _gravixDropAbsent(identity);
          }
        }
      }

      if (e2eeManager != null && event.response.sifTrailer.isNotEmpty) {
        await e2eeManager!.keyProvider.setSifTrailer(Uint8List.fromList(event.response.sifTrailer));
      }

      logger.fine('Room Connect completed');

      events.emit(RoomConnectedEvent(room: this, metadata: _metadata));
    })
    ..on<EngineResumedEvent>((event) async {
      _gravixStallWatch.noteResumed(); // GRAVIX (0.4.15, S4): the no-video window starts
      _gravixUplinkWatch.reset(); // GRAVIX (2026-10-11): restarted connections, fresh clocks
      // re-send tracks permissions
      localParticipant?.sendTrackSubscriptionPermissions();
      events.emit(const RoomReconnectedEvent());
      notifyListeners();
    })
    ..on<EngineFullRestartingEvent>((event) async {
      _gravixStallWatch.reset(); // GRAVIX (0.4.15): new receivers follow
      _gravixUplinkWatch.reset(); // GRAVIX (2026-10-11): new senders follow
      _gravixCancelAbsent(); // still kept: the new JoinResponse decides again
      final restart = _restart = _GravixRestartState();
      events.emit(const RoomReconnectingEvent());

      // reset params
      _name = null;
      _metadata = null;
      _serverVersion = null;
      _serverRegion = null;

      _activeSpeakers.clear();
      if (roomOptions.recovery.keepParticipantsOnRejoin) {
        // GRAVIX (0.4.15, S5, field 2026-10-09: the app logged the host as
        // "left / offline" on every full rejoin): keep the participants. Their
        // tracks belong to the old subscriber connection: unsubscribe them; the
        // new connection's tracks are subscribed on the same publications.
        // Who really left is decided by the new JoinResponse.
        // decided before any await: the new JoinResponse may arrive meanwhile
        final participants = _remoteParticipants.toList();
        final kept = {for (final p in participants) p.identity};
        restart.kept = kept;
        restart.announced.addAll(kept); // never re-announced
        for (final participant in participants) {
          for (final pub in participant.trackPublications.values.toList()) {
            final track = pub.track;
            if (track != null) {
              await track.stop();
              [
                participant.events,
                events,
              ].emit(TrackUnsubscribedEvent(participant: participant, track: track, publication: pub));
              await pub.updateTrack(null);
            }
            pub.gravixResetStreamState();
          }
        }
        _pendingTrackQueue.clear();
      } else {
        final participants = _remoteParticipants.toList();
        _remoteParticipants.clear();
        for (final participant in participants) {
          _rpcClientManager.onParticipantDisconnected(participant.identity);
          events.emit(ParticipantDisconnectedEvent(participant: participant));
          await participant.removeAllPublishedTracks(notify: false);
          await participant.dispose();
        }
      }

      notifyListeners();
    })
    ..on<EngineRestartedEvent>((event) async {
      final restart = _restart;
      // re-publish all tracks
      await localParticipant?.rePublishAllTracks();
      if (restart != null && !identical(_restart, restart)) {
        // GRAVIX (0.4.15, F5): a newer full restart began while this one was
        // finishing (its republish was abandoned): that one announces and
        // reports "reconnected"; this tail must not touch its state
        logger.info('restart superseded by a newer one; not reporting it as reconnected');
        return;
      }

      for (var participant in _remoteParticipants.toList()) {
        for (var pub in participant.trackPublications.values.toList()) {
          if (pub.subscribed) {
            pub.sendUpdateTrackSettings();
          }
        }
      }
      // Every participant present now was dropped (or never announced) during the
      // restart: announce the ones not announced yet, before RoomReconnectedEvent,
      // so a list kept from the events is whole again when "reconnected" arrives.
      // They are NEW objects; whoever held the old ones must take these.
      // GRAVIX (0.4.15): the rejoin may have landed on another region.
      _gravixNoteConnectedUrl(RoomConnectedUrlChangeReason.rejoin);
      final announced = restart?.announced;
      if (identical(_restart, restart)) _restart = null;
      if (announced != null) {
        for (final participant in _remoteParticipants.toList()) {
          if (announced.contains(participant.identity)) continue;
          events.emit(ParticipantConnectedEvent(participant: participant));
        }
      }
      events.emit(const RoomReconnectedEvent());
      notifyListeners();
    })
    ..on<EngineResumingEvent>((event) async {
      events.emit(const RoomResumingEvent());
      notifyListeners();
    })
    ..on<SignalReconnectedEvent>((event) async {
      await _sendSyncState();
    })
    // GRAVIX (2026-10-14): the session's ICE transport (GravixIceTransport)
    ..on<EngineIceTransportChangedEvent>(
      (e) => events.emit(
        RoomIceTransportChangedEvent(
          transport: e.transport,
          previous: e.previous,
          publisher: e.publisher,
          subscriber: e.subscriber,
        ),
      ),
    )
    ..on<EngineSlowTcpTransportEvent>((e) => events.emit(RoomSlowTcpTransportEvent(rtt: e.rtt, over: e.over)))
    // GRAVIX (2026-10-14): every reconnect attempt
    ..on<EngineReconnectAttemptEvent>(
      (e) => events.emit(
        RoomReconnectAttemptEvent(
          mode: e.full ? GravixReconnectMode.full : GravixReconnectMode.resume,
          cause: e.cause,
          reconnectReason: e.reconnectReason,
          attempt: e.attempt,
          afterNetworkChange: e.afterNetworkChange,
        ),
      ),
    )
    ..on<EngineAttemptReconnectEvent>((event) async {
      events.emit(
        RoomAttemptReconnectEvent(
          attempt: event.attempt,
          maxAttemptsRetry: event.maxAttempts,
          nextRetryDelaysInMs: event.nextRetryDelaysInMs,
        ),
      );
      notifyListeners();
    })
    ..on<EngineDisconnectedEvent>((event) async {
      if (!engine.gravixFullReconnectInProgress || event.reason == DisconnectReason.clientInitiated) {
        _restart = null;
        _gravixCancelAbsent();
        await _cleanUp(disposeLocalParticipant: false);
        events.emit(RoomDisconnectedEvent(reason: event.reason));
        notifyListeners();
      }
    })
    ..on<EngineLocalTrackSubscribedEvent>((event) => events.emit(LocalTrackSubscribedEvent(trackSid: event.trackSid)))
    ..on<EngineActiveSpeakersUpdateEvent>((event) => _onEngineActiveSpeakersUpdateEvent(event.speakers))
    ..on<EngineDataPacketReceivedEvent>(_onDataMessageEvent)
    ..on<EngineTranscriptionReceivedEvent>(_onTranscriptionEvent)
    ..on<EngineRequestResponseEvent>((event) {
      localParticipant?.handleSignalRequestResponse(event.response);
    })
    ..on<EngineRoomMovedEvent>((event) async {
      final response = event.response;
      logger.fine('Room moved to: ${response.room.name}');

      // Apply room info from move response
      if (response.hasRoom()) {
        _applyRoomUpdate(response.room);
      }

      // Disconnect all remote participants
      final identities = _remoteParticipants.byIdentity.keys.toList();
      for (final identity in identities) {
        await _handleParticipantDisconnect(identity);
      }

      // Emit public event
      events.emit(RoomMovedEvent(roomName: response.room.name));

      // Update local participant info
      if (response.hasParticipant()) {
        await localParticipant?.updateFromInfo(response.participant);
      }

      // Add new participants
      if (response.otherParticipants.isNotEmpty) {
        await _onParticipantUpdateEvent(response.otherParticipants);
      }

      notifyListeners();
    })
    ..on<AudioPlaybackStarted>((event) {
      _handleAudioPlaybackStarted();
    })
    ..on<AudioPlaybackFailed>((event) {
      _handleAudioPlaybackFailed();
    })
    ..on<EngineTrackAddedEvent>((event) async {
      logger.fine('EngineTrackAddedEvent trackSid:${event.track.id}');

      final idParts = unpackStreamId(event.stream.id);
      final participantSid = idParts[0];
      final streamId = idParts[1];
      var trackSid = event.track.id;

      // firefox will get streamId (pID|trackId) instead of (pID|streamId) as it doesn't support sync tracks by stream
      // and generates its own track id instead of infer from sdp track id.
      if (streamId.isNotEmpty && streamId.startsWith('TR')) {
        trackSid = streamId;
      }

      final participant = _remoteParticipants.bySid[participantSid];
      try {
        if (trackSid == null || trackSid.isEmpty) {
          throw TrackSubscriptionExceptionEvent(
            participant: participant,
            reason: TrackSubscribeFailReason.invalidServerResponse,
          );
        }

        final shouldDefer = connectionState != ConnectionState.connected || participant == null;
        if (shouldDefer) {
          _pendingTrackQueue.enqueue(
            track: event.track,
            stream: event.stream,
            receiver: event.receiver,
            participantSid: participantSid,
            trackSid: trackSid,
            connectionState: connectionState,
          );
          return;
        }
        await participant.addSubscribedMediaTrack(
          event.track,
          event.stream,
          trackSid,
          receiver: event.receiver,
          audioOutputOptions: roomOptions.defaultAudioOutputOptions,
        );
      } on TrackSubscriptionExceptionEvent catch (event) {
        logger.severe('addSubscribedMediaTrack() throwed ${event}');
        events.emit(event);
      } catch (exception) {
        // We don't want to pass up any exception so catch everything here.
        logger.warning('Unknown exception on addSubscribedMediaTrack() ${exception}');
      }
    });

  /// GRAVIX (2026-10-14): how this session's media travels, from each peer
  /// connection's selected ICE candidate pair: tcp when either connection runs
  /// over ICE/TCP, relay when either is relayed, else udp. Null until the first
  /// reading (or with `GravixRecoveryOptions.iceTransportWatch` off). Changes
  /// are RoomIceTransportChangedEvent; a slow TCP session is
  /// RoomSlowTcpTransportEvent.
  GravixIceTransport? get selectedTransport => engine.gravixSelectedTransport;

  /// The publisher connection's transport (see [selectedTransport]).
  GravixIceTransport? get publisherTransport => engine.gravixPublisherTransport;

  /// The subscriber connection's transport (see [selectedTransport]).
  GravixIceTransport? get subscriberTransport => engine.gravixSubscriberTransport;

  /// Disconnects from the room, notifying server of disconnection.
  Future<void> disconnect() async {
    _gravixLeaving = true;
    _gravixWakeJoinRetry();
    final bool isPendingReconnect = engine.isPendingReconnect;
    if (engine.isClosed && !isPendingReconnect && engine.connectionState == ConnectionState.disconnected) {
      logger.warning('Engine is already closed');
      return;
    }
    // GRAVIX(0.4.13): listening starts before the engine disconnects. An engine
    // that is not connected (a failed or retrying join) emits the event inside
    // engine.disconnect(), before a listener added after it could see it: the
    // leave then waited 10 s and threw TimeoutException.
    final disconnected = isPendingReconnect
        ? null
        : _engineListener.waitFor<EngineDisconnectedEvent>(duration: const Duration(seconds: 10));
    disconnected?.ignore();
    await engine.disconnect();
    if (disconnected != null) await disconnected;
    await _cleanUp();
  }

  Future<void> setE2EEEnabled(bool enabled) async {
    if (_e2eeManager != null) {
      await _e2eeManager!.setEnabled(enabled);
    } else {
      throw GravixRtcE2EEException('_e2eeManager not setup!');
    }
  }

  /// retrieves a participant by identity
  Participant? getParticipantByIdentity(String identity) {
    if (_localParticipant?.identity == identity) {
      return _localParticipant;
    }
    return _remoteParticipants.byIdentity[identity];
  }

  Future<ParticipantCreationResult> _getOrCreateRemoteParticipant(lk_models.ParticipantInfo info) async {
    if (!info.hasIdentity() || !info.hasSid()) {
      throw Exception('ParticipantInfo must have identity and sid');
    }

    final participant = _remoteParticipants.byIdentity[info.identity];
    if (participant != null) {
      // Return existing participant with no new publications; caller handles updates.
      return ParticipantCreationResult(participant: participant, newPublications: const []);
    }

    final result = await RemoteParticipant.createFromInfo(room: this, info: info);

    _remoteParticipants.set(result.participant);
    await _flushPendingTracks(participant: result.participant);
    return result;
  }

  /// GRAVIX (0.4.15, F6): kept participants a rejoin's JoinResponse did not
  /// list, waiting (rejoinAbsentGrace) for a participant update before they are
  /// reported gone.
  final Map<String, Timer> _gravixAbsentAfterRejoin = {};

  void _gravixCancelAbsent() {
    for (final t in _gravixAbsentAfterRejoin.values) {
      t.cancel();
    }
    _gravixAbsentAfterRejoin.clear();
  }

  /// A kept participant that is really gone: as _handleParticipantDisconnect, but
  /// emitted directly (the room may not count as connected yet during a rejoin).
  Future<void> _gravixDropAbsent(String identity) async {
    _gravixAbsentAfterRejoin.remove(identity)?.cancel();
    final participant = _remoteParticipants.removeByIdentity(identity);
    if (participant == null) return;
    _rpcClientManager.onParticipantDisconnected(identity);
    await validateParticipantHasNoActiveDataStreams(identity);
    await participant.removeAllPublishedTracks(notify: true);
    events.emit(ParticipantDisconnectedEvent(participant: participant));
    await participant.dispose();
    notifyListeners();
  }

  Future<void> _onParticipantUpdateEvent(List<lk_models.ParticipantInfo> updates) async {
    // trigger change notifier only if list of participants membership is changed
    var hasChanged = false;
    for (final info in updates) {
      // The local participant is not ready yet, waiting for the
      // `RoomConnectedEvent` to create the local participant.
      if (_localParticipant == null) {
        await events.waitFor<RoomConnectedEvent>(duration: const Duration(seconds: 10));
      }

      if (localParticipant?.identity == info.identity) {
        await localParticipant?.updateFromInfo(info);
        continue;
      }

      // GRAVIX (0.4.15, F6): a kept participant the rejoin's JoinResponse did not
      // list is back (relayed in a moment later): the same object, updated in
      // place, no ParticipantConnected; or it really left.
      final absent = _gravixAbsentAfterRejoin.remove(info.identity);
      if (absent != null) {
        absent.cancel();
        if (info.state == lk_models.ParticipantInfo_State.DISCONNECTED) {
          await _gravixDropAbsent(info.identity);
          hasChanged = true;
          continue;
        }
        final kept = _remoteParticipants.byIdentity[info.identity];
        if (kept != null) {
          final oldSid = kept.sid;
          await kept.updateFromInfo(info);
          _remoteParticipants.rekey(kept, oldSid);
          await _flushPendingTracks(participant: kept);
          continue;
        }
      }

      final isNew = !_remoteParticipants.containsIdentity(info.identity);

      if (info.state == lk_models.ParticipantInfo_State.DISCONNECTED) {
        hasChanged = await _handleParticipantDisconnect(info.identity);
        continue;
      }

      final result = await _getOrCreateRemoteParticipant(info);

      if (isNew) {
        hasChanged = true;
        // announced now (connected) or at the end of a full restart (not yet)
        if (connectionState == ConnectionState.connected) _restart?.announced.add(info.identity);
        // Emit connected event
        emitWhenConnected(ParticipantConnectedEvent(participant: result.participant));
        // Emit TrackPublishedEvent for each new track
        if (connectionState == ConnectionState.connected) {
          for (final pub in result.newPublications) {
            final event = TrackPublishedEvent(participant: result.participant, publication: pub);
            [result.participant.events, events].emit(event);
          }
        }
        _remoteParticipants.set(result.participant);
        await _flushPendingTracks(participant: result.participant);
      } else {
        final wasUpdated = await result.participant.updateFromInfo(info);
        if (wasUpdated) {
          _remoteParticipants.set(result.participant);
          await _flushPendingTracks(participant: result.participant);
        }
      }
    }

    if (hasChanged) {
      notifyListeners();
    }
  }

  void _onSignalSpeakersChangedEvent(List<lk_models.SpeakerInfo> speakers) {
    final lastSpeakers = {for (final p in _activeSpeakers) p.sid: p};

    for (final speaker in speakers) {
      Participant? p = _remoteParticipants.bySid[speaker.sid];
      if (speaker.sid == localParticipant?.sid) p = localParticipant;
      if (p == null) continue;

      p.audioLevel = speaker.level;
      p.isSpeaking = speaker.active;
      if (speaker.active) {
        lastSpeakers[speaker.sid] = p;
      } else {
        lastSpeakers.remove(speaker.sid);
      }
    }

    final activeSpeakers = lastSpeakers.values.toList();
    activeSpeakers.sort((a, b) => b.audioLevel.compareTo(a.audioLevel));
    _activeSpeakers = activeSpeakers;
    emitWhenConnected(ActiveSpeakersChangedEvent(speakers: activeSpeakers));
  }

  Future<void> _flushPendingTracks({RemoteParticipant? participant}) => _pendingTrackQueue.flush(
    isConnected: connectionState == ConnectionState.connected,
    participantSid: participant?.sid,
    subscriber: (pending) async {
      final target = participant ?? _remoteParticipants.bySid[pending.participantSid];
      if (target == null) return false;
      try {
        await target.addSubscribedMediaTrack(
          pending.track,
          pending.stream,
          pending.trackSid,
          receiver: pending.receiver,
          audioOutputOptions: roomOptions.defaultAudioOutputOptions,
        );
        return true;
      } on TrackSubscriptionExceptionEvent catch (event) {
        logger.severe('Track subscription failed during flush: ${event}');
        events.emit(event);
        return true;
      } catch (exception) {
        logger.warning('Unknown exception during pending track flush: ${exception}');
        return false;
      }
    },
  );

  // from data channel
  // updates are sent only when there's a change to speaker ordering
  void _onEngineActiveSpeakersUpdateEvent(List<lk_models.SpeakerInfo> speakers) {
    final List<Participant> activeSpeakers = [];

    // localParticipant & remote participants
    final allParticipants = <String, Participant>{
      ?localParticipant?.sid: ?localParticipant,
      ..._remoteParticipants.bySid,
    };

    for (final speaker in speakers) {
      final p = allParticipants[speaker.sid];
      if (p != null) {
        p.audioLevel = speaker.level;
        p.isSpeaking = true;
        activeSpeakers.add(p);
      }
    }

    // clear if not in the speakers list
    final speakerSids = speakers.map((e) => e.sid).toSet();
    for (final p in allParticipants.values) {
      if (!speakerSids.contains(p.sid)) {
        p.audioLevel = 0;
        p.isSpeaking = false;
      }
    }

    _activeSpeakers = activeSpeakers;
    emitWhenConnected(ActiveSpeakersChangedEvent(speakers: activeSpeakers));
  }

  void _onSignalConnectionQualityUpdateEvent(List<lk_rtc.ConnectionQualityInfo> updates) {
    for (final entry in updates) {
      Participant? participant;
      if (entry.participantSid == localParticipant?.sid) {
        participant = localParticipant;
      } else {
        participant = _remoteParticipants.bySid[entry.participantSid];
      }

      if (participant != null) {
        // update the connection quality if the participant is found
        participant.updateConnectionQuality(entry.quality.toLKType());
      }
    }
  }

  void _onSignalStreamStateUpdateEvent(List<lk_rtc.StreamStateInfo> updates) async {
    for (final update in updates) {
      // try to find RemoteParticipant
      final participant = _remoteParticipants.bySid[update.participantSid];
      if (participant == null) {
        logger.warning('Participant not found for sid ${update.participantSid}');
        continue;
      }
      // try to find RemoteTrackPublication
      final trackPublication = participant.trackPublications[update.trackSid];
      if (trackPublication == null) continue;
      // update the stream state
      await trackPublication.updateStreamState(update.state.toLKType());
      emitWhenConnected(
        TrackStreamStateUpdatedEvent(
          participant: participant,
          publication: trackPublication,
          streamState: update.state.toLKType(),
        ),
      );
    }
  }

  void _onTranscriptionEvent(EngineTranscriptionReceivedEvent event) {
    final participant = getParticipantByIdentity(event.transcription.transcribedParticipantIdentity);
    if (participant == null || event.transcription.segments.isEmpty) {
      return;
    }

    final publication = participant.getTrackPublicationBySid(event.transcription.trackId);

    final segments = event.transcription.segments.map((segment) {
      return TranscriptionSegment(
        text: segment.text,
        id: segment.id,
        firstReceivedTime: _transcriptionReceivedTimes[segment.id] ?? DateTime.timestamp(),
        lastReceivedTime: DateTime.timestamp(),
        isFinal: segment.final_5,
        language: segment.language,
      );
    }).toList();

    for (var segment in segments) {
      segment.isFinal
          ? _transcriptionReceivedTimes.remove(segment.id)
          : _transcriptionReceivedTimes[segment.id] = DateTime.timestamp();
    }

    final transcription = TranscriptionEvent(participant: participant, publication: publication, segments: segments);

    participant.events.emit(transcription);
    events.emit(transcription);
  }

  void _onDataMessageEvent(EngineDataPacketReceivedEvent dataPacketEvent) {
    // participant may be null if data is sent from Server-API
    RemoteParticipant? senderParticipant;
    if (dataPacketEvent.identity.isNotEmpty) {
      senderParticipant = getParticipantByIdentity(dataPacketEvent.identity) as RemoteParticipant?;
    }

    final event = DataReceivedEvent(
      participant: senderParticipant,
      data: dataPacketEvent.packet.payload,
      topic: dataPacketEvent.packet.topic,
    );

    senderParticipant?.events.emit(event);
    events.emit(event);
  }

  Future<bool> _handleParticipantDisconnect(String identity) async {
    final participant = _remoteParticipants.removeByIdentity(identity);
    if (participant == null) return false;

    _rpcClientManager.onParticipantDisconnected(identity);

    await validateParticipantHasNoActiveDataStreams(identity);

    await participant.removeAllPublishedTracks(notify: true);

    emitWhenConnected(ParticipantDisconnectedEvent(participant: participant));
    return true;
  }

  Future<void> _sendSyncState() async {
    final autoSubscribe = connectOptions.autoSubscribe;

    final trackSids = <String>[];
    final trackSidsDisabled = <String>[];

    for (var participant in _remoteParticipants.toList()) {
      for (var track in participant.trackPublications.values.toList()) {
        if (track.subscribed != autoSubscribe) {
          trackSids.add(track.sid);
        }
        if (!track.enabled) {
          trackSidsDisabled.add(track.sid);
        }
      }
    }

    await engine.sendSyncState(
      subscription: lk_rtc.UpdateSubscription(participantTracks: [], trackSids: trackSids, subscribe: !autoSubscribe),
      trackSidsDisabled: trackSidsDisabled,
      publishTracks: localParticipant?.publishedTracksInfo(),
    );
  }
}

extension RoomPrivateMethods on Room {
  // resets internal state to a re-usable state
  Future<void> _cleanUp({bool disposeLocalParticipant = true}) async {
    logger.fine('[${objectId}] cleanUp()');

    // GRAVIX (2026-10-13): the join's camera still being published after
    // connect() returned is released (privacy: no camera left open by a leave)
    if (_gravixJoinCamInFlight != null) await _gravixAbandonJoinCameraInFlight();

    // clean up RemoteParticipants
    _gravixCancelAbsent();
    final participants = _remoteParticipants.toList();
    _remoteParticipants.clear();
    for (final participant in participants) {
      await participant.removeAllPublishedTracks(notify: false);
      // RemoteParticipant is responsible for disposing resources
      await participant.dispose();
    }
    _pendingTrackQueue.clear();

    // clean up LocalParticipant
    localParticipant?.gravixForgetRepublish(); // GRAVIX (0.4.15, F4)
    await localParticipant?.unpublishAllTracks();

    if (disposeLocalParticipant) {
      await localParticipant?.dispose();
      _localParticipant = null;
    }

    _activeSpeakers.clear();

    await preConnectAudioBuffer.reset();

    // clean up engine
    await engine.cleanUp();

    if (disposeLocalParticipant) {
      // GRAVIX(0.4.12): the room is left; no recorder the explicit start
      // pre-warmed may outlive it (Android; WebRTC's own recording, stopped
      // with the engine above, is not touched). Before the audio session stop
      // and the foreground-service release, whatever their timing.
      await gravixReleaseExplicitRecording();
    }

    await NativeAudioManagement.stop();

    // the room is gone (disconnect, dispose, lost): its foreground-service hold too
    GravixForegroundService.roomReleased(this);

    // reset params
    _roomInfo = null;
    _name = null;
    _metadata = null;
    _isRecording = false;
    _serverVersion = null;
    _serverRegion = null;
  }

  /// Applies room info from server. Skips metadata event on first join
  /// since there is no previous state to compare against.
  void _applyRoomUpdate(lk_models.Room room) {
    final oldRoom = _roomInfo;
    _roomInfo = room;
    _name = room.name;
    _metadata = room.metadata;
    if (oldRoom != null && oldRoom.metadata != room.metadata) {
      emitWhenConnected(RoomMetadataChangedEvent(metadata: room.metadata));
    }
    if (oldRoom?.activeRecording != room.activeRecording) {
      _isRecording = room.activeRecording;
      emitWhenConnected(RoomRecordingStatusChanged(activeRecording: _isRecording));
    }
  }

  @internal
  void emitWhenConnected(RoomEvent event) {
    if (connectionState == ConnectionState.connected) {
      events.emit(event);
    }
  }

  /// server assigned unique room id.
  /// returns once a sid has been issued by the server.
  Future<String> getSid() async {
    if (engine.connectionState == ConnectionState.disconnected) {
      return '';
    }

    if (_roomInfo != null && _roomInfo!.sid.isNotEmpty) {
      return _roomInfo!.sid;
    }

    final completer = Completer<String>();

    // SignalRoomUpdateEvent is emitted on the signal client's emitter (and
    // consumed by _setUpSignalListeners) — it never appears on the Room's
    // [events], so listen where it actually fires or the future returned
    // here never completes. Created via createListener() so it is cancelled
    // with its owner.
    final roomUpdateListener = engine.signalClient.createListener();
    roomUpdateListener.on<SignalRoomUpdateEvent>((event) {
      if (event.room.sid.isNotEmpty && !completer.isCompleted) {
        completer.complete(event.room.sid);
      }
    });

    // A caller waiting while the connection is still being established: the
    // sid may arrive inside the JoinResponse, which is applied via
    // EngineJoinResponseEvent without a SignalRoomUpdateEvent.
    final joinListener = engine.createListener();
    joinListener.on<EngineJoinResponseEvent>((event) {
      if (event.response.room.sid.isNotEmpty && !completer.isCompleted) {
        completer.complete(event.response.room.sid);
      }
    });

    final cancelDisconnectListen = events.once<RoomDisconnectedEvent>((event) {
      if (!completer.isCompleted) {
        completer.complete('');
      }
    });

    // Disposal without a disconnect event (Room.dispose during teardown)
    // cancels the listeners above — the constructor's dispose routine
    // completes every tracked waiter with '' instead of leaving the returned
    // future pending forever.
    _pendingSidCompleters.add(completer);

    // The update may have been applied between the check above and the
    // listener registration.
    if (_roomInfo != null && _roomInfo!.sid.isNotEmpty && !completer.isCompleted) {
      completer.complete(_roomInfo!.sid);
    }

    return completer.future.whenComplete(() async {
      _pendingSidCompleters.remove(completer);
      await roomUpdateListener.dispose();
      await joinListener.dispose();
      await cancelDisconnectListen?.call();
    });
  }
}

extension RoomDebugMethods on Room {
  /// To be used for internal testing purposes only.
  Future<void> sendSimulateScenario({
    int? speakerUpdate,
    bool? nodeFailure,
    bool? migration,
    bool? serverLeave,
    bool? switchCandidate,
    bool? signalReconnect,
    bool? fullReconnect,
    int? subscriberBandwidth,
  }) async {
    if (signalReconnect != null && signalReconnect) {
      await engine.signalClient.cleanUp();
      return;
    }
    if (fullReconnect != null && fullReconnect) {
      engine.fullReconnectOnNext = true;
      await engine.signalClient.cleanUp();
      return;
    }
    engine.signalClient.sendSimulateScenario(
      speakerUpdate: speakerUpdate,
      nodeFailure: nodeFailure,
      migration: migration,
      serverLeave: serverLeave,
      switchCandidate: switchCandidate,
    );
  }
}

/// Room extension methods for managing audio, video.
extension RoomHardwareManagementMethods on Room {
  /// Get current audio output device.
  String? get selectedAudioOutputDeviceId =>
      roomOptions.defaultAudioOutputOptions.deviceId ?? Hardware.instance.selectedAudioOutput?.deviceId;

  /// Get current audio input device.
  String? get selectedAudioInputDeviceId =>
      roomOptions.defaultAudioCaptureOptions.deviceId ?? Hardware.instance.selectedAudioInput?.deviceId;

  /// Get current video input device.
  String? get selectedVideoInputDeviceId =>
      roomOptions.defaultCameraCaptureOptions.deviceId ?? Hardware.instance.selectedVideoInput?.deviceId;

  /// Get mobile device's speaker status.
  @Deprecated('Use AudioManager.instance.isSpeakerOutputPreferred instead')
  bool? get speakerOn => AudioManager.instance.isSpeakerOutputPreferred;

  /// Set audio output device.
  Future<void> setAudioOutputDevice(MediaDevice device) async {
    if (lkPlatformIs(PlatformType.web)) {
      for (final participant in _remoteParticipants.toList()) {
        for (final audioTrack in participant.audioTrackPublications) {
          audioTrack.track?.setSinkId(device.deviceId);
        }
      }
      Hardware.instance.selectedAudioOutput = device;
    } else {
      await Hardware.instance.selectAudioOutput(device);
    }
    engine.roomOptions = engine.roomOptions.copyWith(
      defaultAudioOutputOptions: roomOptions.defaultAudioOutputOptions.copyWith(deviceId: device.deviceId),
    );
  }

  /// Set audio input device.
  Future<void> setAudioInputDevice(MediaDevice device) async {
    if (lkPlatformIs(PlatformType.web) && localParticipant != null) {
      for (var audioTrack in localParticipant!.audioTrackPublications) {
        await audioTrack.track?.setDeviceId(device.deviceId);
      }
      Hardware.instance.selectedAudioInput = device;
    } else {
      await Hardware.instance.selectAudioInput(device);
    }
    engine.roomOptions = engine.roomOptions.copyWith(
      defaultAudioCaptureOptions: roomOptions.defaultAudioCaptureOptions.copyWith(deviceId: device.deviceId),
    );
  }

  /// Set video input device.
  Future<void> setVideoInputDevice(MediaDevice device) async {
    final track = localParticipant?.videoTrackPublications.firstOrNull?.track;

    final currentDeviceId = engine.roomOptions.defaultCameraCaptureOptions.deviceId;

    // Always update roomOptions so future tracks use the correct device
    engine.roomOptions = engine.roomOptions.copyWith(
      defaultCameraCaptureOptions: roomOptions.defaultCameraCaptureOptions.copyWith(deviceId: device.deviceId),
    );

    try {
      if (track != null && currentDeviceId != device.deviceId) {
        await track.switchCamera(device.deviceId);
        Hardware.instance.selectedVideoInput = device;
      }
    } catch (e) {
      // if the switching actually fails, reset it to the previous deviceId
      engine.roomOptions = engine.roomOptions.copyWith(
        defaultCameraCaptureOptions: roomOptions.defaultCameraCaptureOptions.copyWith(deviceId: currentDeviceId),
      );
    }
  }

  /// [speakerOn] set speakerphone on or off, by default wired/bluetooth headsets will still
  /// be prioritized even if set to true.
  /// [forceSpeakerOutput] if true, will force speaker output even if headphones
  /// or bluetooth is connected.
  @Deprecated('Use AudioManager.instance.setSpeakerOutputPreferred instead')
  Future<void> setSpeakerOn(bool speakerOn, {bool forceSpeakerOutput = false}) =>
      AudioManager.instance.setSpeakerOutputPreferred(speakerOn, force: forceSpeakerOutput);

  Future<void> startAudio() async {
    try {
      final audioContextRunning = await audio.startAllAudioElement();
      if (audioContextRunning) {
        _handleAudioPlaybackStarted();
      } else {
        _handleAudioPlaybackFailed();
      }
    } catch (err) {
      logger.warning('could not playback audio $err');
      _handleAudioPlaybackFailed();
    }
  }

  bool get canPlaybackAudio {
    return _audioEnabled;
  }

  void _handleAudioPlaybackStarted() {
    if (canPlaybackAudio) {
      return;
    }
    _audioEnabled = true;
    events.emit(const AudioPlaybackStatusChanged(isPlaying: true));
  }

  void _handleAudioPlaybackFailed() {
    if (!canPlaybackAudio) {
      return;
    }
    _audioEnabled = false;
    events.emit(const AudioPlaybackStatusChanged(isPlaying: false));
  }
}

extension RoomRPCMethods on Room {
  void _setupRpcListeners() {
    // listen for incoming v1 packet-based requests/acks/responses
    _engineListener
      ..on<EngineRPCRequestReceivedEvent>((event) async {
        final request = event.request;
        await _rpcServerManager.handleIncomingV1Request(
          event.identity,
          request.id,
          request.method,
          request.payload,
          request.responseTimeoutMs,
          request.version,
        );
      })
      ..on<EngineRPCAckReceivedEvent>((event) {
        _rpcClientManager.handleIncomingRpcAck(event.requestId);
      })
      ..on<EngineRPCResponseReceivedEvent>((event) {
        String? payload;
        RpcError? error;

        if (event.payload.isNotEmpty) {
          payload = event.response.payload;
        } else if (event.error != null) {
          error = RpcError.fromProto(event.error!);
        }
        _rpcClientManager.handleIncomingRpcResponse(event.requestId, payload, error);
      });

    // Register v2 data-stream-based request/response handlers. These topics
    // are reserved by the SDK, so bypass the public registration guard.
    _textStreamHandlers[kRpcRequestTopic] = _rpcServerManager.handleIncomingV2RequestStream;
    _textStreamHandlers[kRpcResponseTopic] = _rpcClientManager.handleIncomingV2ResponseStream;
  }

  /// Register a handler for incoming RPC requests.
  /// @param method, the method name to listen for.
  /// When a request with this method name is received, the handler will be called.
  /// The handler should return a string payload to send back to the caller.
  /// If the handler returns null, an error will be sent back to the caller.
  void registerRpcMethod(String method, RpcRequestHandler handler) {
    _rpcServerManager.registerMethod(method, handler);
  }

  /// Unregister a handler for incoming RPC requests.
  /// @param method, the method name to unregister.
  void unregisterRpcMethod(String method) {
    _rpcServerManager.unregisterMethod(method);
  }
}

extension RPCMethods on LocalParticipant {
  /// Initiate an RPC call to a remote participant.
  /// @param [params] - RPC call parameters.
  /// @returns A future that resolves with the response payload or rejects with [RpcError].
  /// @throws [RpcError] on failure. Details in `message`.
  Future<String> performRpc(PerformRpcParams params) {
    return room._rpcClientManager.performRpc(params);
  }
}

const _reservedRpcTopicPrefix = 'lk.rpc';

extension DataStreamRoomMethods on Room {
  void _setupDataStreamListeners() {
    _engineListener
      ..on<EngineDataStreamHeaderEvent>((event) async {
        await handleStreamHeader(event.header, event.identity, event.encryptionType);
      })
      ..on<EngineDataStreamChunkEvent>((event) async {
        handleStreamChunk(event.chunk, event.encryptionType);
      })
      ..on<EngineDataStreamTrailerEvent>((event) async {
        await handleStreamTrailer(event.trailer, event.encryptionType);
      });
  }

  void registerTextStreamHandler(String topic, TextStreamHandler callback) {
    _ensureNotReservedRpcTopic(topic);
    if (_textStreamHandlers.containsKey(topic)) {
      throw DataStreamError(
        message: 'A text stream handler for topic "${topic}" has already been set.',
        reason: DataStreamErrorReason.HandlerAlreadyRegistered,
      );
    }
    _textStreamHandlers[topic] = callback;
  }

  void unregisterTextStreamHandler(String topic) {
    if (_isReservedRpcTopic(topic)) return;
    _textStreamHandlers.remove(topic);
  }

  void registerByteStreamHandler(String topic, ByteStreamHandler callback) {
    _ensureNotReservedRpcTopic(topic);
    if (_byteStreamHandlers.containsKey(topic)) {
      throw DataStreamError(
        message: 'A byte stream handler for topic "${topic}" has already been set.',
        reason: DataStreamErrorReason.HandlerAlreadyRegistered,
      );
    }
    _byteStreamHandlers[topic] = callback;
  }

  void unregisterByteStreamHandler(String topic) {
    if (_isReservedRpcTopic(topic)) return;
    _byteStreamHandlers.remove(topic);
  }

  void _ensureNotReservedRpcTopic(String topic) {
    if (_isReservedRpcTopic(topic)) {
      throw DataStreamError(
        message: 'The stream topic prefix "$_reservedRpcTopicPrefix" is reserved for internal SDK use.',
        reason: DataStreamErrorReason.HandlerAlreadyRegistered,
      );
    }
  }

  bool _isReservedRpcTopic(String topic) => topic.startsWith(_reservedRpcTopicPrefix);

  @internal
  Future<void> handleStreamHeader(
    lk_models.DataStream_Header streamHeader,
    String participantIdentity,
    EncryptionType encryptionType,
  ) async {
    if (streamHeader.hasByteHeader()) {
      final streamHandlerCallback = _byteStreamHandlers[streamHeader.topic];

      if (streamHandlerCallback == null) {
        logger.info('ignoring incoming byte stream due to no handler for topic ${streamHeader.topic}');
        return;
      }

      final info = ByteStreamInfo(
        id: streamHeader.streamId,
        name: streamHeader.byteHeader.name,
        mimeType: streamHeader.mimeType,
        size: streamHeader.hasTotalLength() ? streamHeader.totalLength.toInt() : 0,
        topic: streamHeader.topic,
        timestamp: streamHeader.timestamp.toInt(),
        attributes: streamHeader.attributes,
        encryptionType: encryptionType,
        sendingParticipantIdentity: participantIdentity,
      );

      final streamController = DataStreamController<lk_models.DataStream_Chunk>(
        info: info,
        streamController: StreamController<lk_models.DataStream_Chunk>(),
        startTime: DateTime.timestamp().millisecondsSinceEpoch,
      );

      if (_byteStreamControllers.containsKey(streamHeader.streamId)) {
        throw DataStreamError(
          message: 'A data stream read is already in progress for a stream with id ${streamHeader.streamId}.',
          reason: DataStreamErrorReason.AlreadyOpened,
        );
      }

      _byteStreamControllers[streamHeader.streamId] = streamController;

      streamHandlerCallback(
        ByteStreamReader(info, streamController, streamHeader.totalLength.toInt()),
        participantIdentity,
      );
    } else if (streamHeader.hasTextHeader()) {
      final streamHandlerCallback = _textStreamHandlers[streamHeader.topic];

      if (streamHandlerCallback == null) {
        logger.warning('ignoring incoming text stream due to no handler for topic ${streamHeader.topic}');
        return;
      }

      final info = TextStreamInfo(
        id: streamHeader.streamId,
        mimeType: streamHeader.mimeType,
        size: streamHeader.hasTotalLength() ? streamHeader.totalLength.toInt() : 0,
        topic: streamHeader.topic,
        timestamp: streamHeader.timestamp.toInt(),
        attributes: streamHeader.attributes,
        replyToStreamId: streamHeader.textHeader.hasReplyToStreamId() ? streamHeader.textHeader.replyToStreamId : null,
        attachedStreamIds: streamHeader.textHeader.attachedStreamIds.toList(),
        version: streamHeader.textHeader.hasVersion() ? streamHeader.textHeader.version : null,
        generated: streamHeader.textHeader.hasGenerated() ? streamHeader.textHeader.generated : false,
        operationType: streamHeader.textHeader.hasOperationType()
            ? TextStreamOperationType.fromPBType(streamHeader.textHeader.operationType)
            : null,
        encryptionType: encryptionType,
        sendingParticipantIdentity: participantIdentity,
      );

      final streamController = DataStreamController<lk_models.DataStream_Chunk>(
        info: info,
        streamController: StreamController<lk_models.DataStream_Chunk>(),
        startTime: DateTime.timestamp().millisecondsSinceEpoch,
      );

      if (_textStreamControllers.containsKey(streamHeader.streamId)) {
        throw DataStreamError(
          message: 'A data stream read is already in progress for a stream with id ${streamHeader.streamId}.',
          reason: DataStreamErrorReason.AlreadyOpened,
        );
      }

      _textStreamControllers[streamHeader.streamId] = streamController;

      streamHandlerCallback(
        TextStreamReader(info, streamController, streamHeader.totalLength.toInt()),
        participantIdentity,
      );
    }
  }

  @internal
  void handleStreamChunk(lk_models.DataStream_Chunk chunk, EncryptionType encryptionType) {
    final fileBuffer = _byteStreamControllers[chunk.streamId];

    if (fileBuffer != null) {
      if (fileBuffer.info.encryptionType != encryptionType) {
        fileBuffer.error(
          DataStreamError(
            message:
                'Encryption type mismatch for stream ${chunk.streamId}. Expected ${encryptionType}, got ${fileBuffer.info.encryptionType}',
            reason: DataStreamErrorReason.EncryptionTypeMismatch,
          ),
        );

        _byteStreamControllers.remove(chunk.streamId);
      } else if (chunk.content.isNotEmpty) {
        fileBuffer.write(chunk);
      }
    }
    final textBuffer = _textStreamControllers[chunk.streamId];
    if (textBuffer != null) {
      if (textBuffer.info.encryptionType != encryptionType) {
        textBuffer.error(
          DataStreamError(
            message:
                'Encryption type mismatch for stream ${chunk.streamId}. Expected ${encryptionType}, got ${textBuffer.info.encryptionType}',
            reason: DataStreamErrorReason.EncryptionTypeMismatch,
          ),
        );

        logger.warning('encryption type mismatch for text stream ${chunk.streamId}');
        _textStreamControllers.remove(chunk.streamId);
      } else if (chunk.content.isNotEmpty) {
        textBuffer.write(chunk);
      }
    }
  }

  @internal
  Future<void> handleStreamTrailer(lk_models.DataStream_Trailer trailer, EncryptionType encryptionType) async {
    final textBuffer = _textStreamControllers[trailer.streamId];
    if (textBuffer != null) {
      if (textBuffer.info.encryptionType != encryptionType) {
        textBuffer.error(
          DataStreamError(
            message:
                'Encryption type mismatch for stream ${trailer.streamId}. Expected ${encryptionType}, got ${textBuffer.info.encryptionType}',
            reason: DataStreamErrorReason.EncryptionTypeMismatch,
          ),
        );

        _textStreamControllers.remove(trailer.streamId);
        return;
      } else {
        textBuffer.info.attributes = {...textBuffer.info.attributes, ...trailer.attributes};
        await textBuffer.close();
        _textStreamControllers.remove(trailer.streamId);
      }
    }

    final fileBuffer = _byteStreamControllers[trailer.streamId];
    if (fileBuffer != null) {
      if (fileBuffer.info.encryptionType != encryptionType) {
        fileBuffer.error(
          DataStreamError(
            message:
                'Encryption type mismatch for stream ${trailer.streamId}. Expected ${encryptionType}, got ${fileBuffer.info.encryptionType}',
            reason: DataStreamErrorReason.EncryptionTypeMismatch,
          ),
        );

        _byteStreamControllers.remove(trailer.streamId);
        return;
      } else {
        fileBuffer.info.attributes = {...fileBuffer.info.attributes, ...trailer.attributes};
        await fileBuffer.close();
        _byteStreamControllers.remove(trailer.streamId);
      }
    }
  }

  @internal
  Future<void> validateParticipantHasNoActiveDataStreams(String participantIdentity) async {
    // Terminate any in flight data stream receives from the given participant
    final textStreamsBeingSentByDisconnectingParticipant = _textStreamControllers.values
        .where((controller) => controller.info.sendingParticipantIdentity == participantIdentity)
        .toList();

    final byteStreamsBeingSentByDisconnectingParticipant = _byteStreamControllers.values
        .where((controller) => controller.info.sendingParticipantIdentity == participantIdentity)
        .toList();
    if (textStreamsBeingSentByDisconnectingParticipant.isNotEmpty ||
        byteStreamsBeingSentByDisconnectingParticipant.isNotEmpty) {
      final abnormalEndError = DataStreamError(
        message: 'Participant ${participantIdentity} unexpectedly disconnected in the middle of sending data',
        reason: DataStreamErrorReason.AbnormalEnd,
      );
      for (var controller in byteStreamsBeingSentByDisconnectingParticipant) {
        controller.error(abnormalEndError);
        await controller.close();
        _byteStreamControllers.remove(controller.info.id);
      }
      for (var controller in textStreamsBeingSentByDisconnectingParticipant) {
        controller.error(abnormalEndError);
        await controller.close();
        _textStreamControllers.remove(controller.info.id);
      }
    }
  }
}

/// GRAVIX (0.4.15, F5): one full restart's own state (see Room._restart).
class _GravixRestartState {
  /// Identities announced (or never to be re-announced) during this restart.
  final Set<String> announced = <String>{};

  /// keepParticipantsOnRejoin: identities kept across it, until its JoinResponse.
  Set<String>? kept;
}

/// GRAVIX (2026-10-11): the longer of [a] (when set) and [b].
Duration _gravixLonger(Duration? a, Duration b) => a != null && a > b ? a : b;
