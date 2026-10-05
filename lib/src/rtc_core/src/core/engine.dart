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

  bool fullReconnectOnNext = false;

  // server-provided ice servers
  List<RTCIceServer> _serverProvidedIceServers = [];

  late EventsListener<SignalEvent> _signalListener = signalClient.createListener(synchronized: true);

  int _reconnectAttempts = 0;
  Timer? _reconnectTimeout;
  DateTime? _reconnectStart;

  bool _isClosed = false;

  bool get isClosed => _isClosed;

  bool get isPendingReconnect => _reconnectStart != null && _reconnectTimeout != null;

  /// GRAVIX: the back-off in use; see [RoomOptions.reconnectPolicy].
  ReconnectPolicy get reconnectPolicy => roomOptions.reconnectPolicy ?? _defaultReconnectPolicy;
  static final _defaultReconnectPolicy = DefaultReconnectPolicy();

  bool _attemptingReconnect = false;

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

  /// Whether a resume is in flight (between its dial and its ReconnectResponse).
  @visibleForTesting
  bool get gravixResumeInFlight => _resumeAbort != null && !_resumeAbort!.isCompleted;

  void _abortResume(GravixResumeRejectedException reason) {
    final c = _resumeAbort;
    if (c != null && !c.isCompleted) {
      logger.info('resume aborted: ${reason.message}');
      c.complete(reason);
    }
  }

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

    onDispose(() async {
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

    try {
      // wait for socket to connect rtc server
      await signalClient.connect(url, token, connectOptions: this.connectOptions, roomOptions: this.roomOptions);

      // wait for join response
      await events.waitFor<EngineJoinResponseEvent>(
        duration: this.connectOptions.timeouts.connection,
        onTimeout: () => throw ConnectException(
          'Timed out waiting for SignalJoinResponseEvent',
          reason: ConnectionErrorReason.Timeout,
        ),
      );

      logger.fine('Waiting for engine to connect...');

      // wait until primary pc is connected
      await events.waitFor<EnginePeerStateUpdatedEvent>(
        filter: (event) => event.isPrimary && event.state.isConnected(),
        duration: this.connectOptions.timeouts.connection,
        onTimeout: () => throw MediaConnectException(
          'Timed out waiting for PeerConnection to connect, please check your network for ice connectivity',
        ),
      );
      events.emit(const EngineConnectedEvent());
    } catch (error) {
      logger.fine('Connect Error $error');

      // during a reconnect this connect() runs inside restartConnection and
      // attemptReconnect owns disconnect emission, emitting here as well
      // would produce two events for one failure
      if (!_isReconnecting && !_attemptingReconnect) {
        events.emit(
          EngineDisconnectedEvent(
            reason: error is CertificatePinningException
                ? DisconnectReason.signalingConnectionFailure
                : DisconnectReason.joinFailure,
          ),
        );
      }
      rethrow;
    }
  }

  // resets internal state to a re-usable state
  Future<void> cleanUp() async {
    logger.fine('[$objectId] cleanUp()');

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

  @internal
  Future<lk_models.TrackInfo> addTrack(lk_rtc.AddTrackRequest req) async {
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
      if (!lkPlatformIsTest()) {
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
    publisher = await Transport.create(
      _peerConnectionCreate,
      rtcConfig: rtcConfiguration,
      connectOptions: connectOptions,
    );
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

    publisher?.pc.onIceCandidate = (rtc.RTCIceCandidate candidate) {
      logger.fine('publisher onIceCandidate');
      signalClient.sendIceCandidate(candidate, lk_rtc.SignalTarget.PUBLISHER);
    };

    publisher?.pc.onIceConnectionState = (rtc.RTCIceConnectionState state) async {
      _gravixMark('pub:ice', state.name); // GRAVIX: Dart receipt, for the join timeline
      logger.fine('publisher iceConnectionState: $state');
      if (state == rtc.RTCIceConnectionState.RTCIceConnectionStateConnected) {
        await _handleGettingConnectedServerAddress(publisher!.pc);
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
        await _handleGettingConnectedServerAddress(subscriber!.pc);
      }
    };

    publisher?.onOffer = (offer) {
      logger.fine('publisher onOffer');
      signalClient.sendOffer(offer);
    };

    // in subscriber primary mode, server side opens sub data channels.
    if (_subscriberPrimary) {
      subscriber?.pc.onDataChannel = _onDataChannel;
    }

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
      events.emit(EngineSubscriberPeerStateUpdatedEvent(state: state, isPrimary: _subscriberPrimary));
      logger.fine('subscriber connectionState: $state');
      if (state.isDisconnected() || state.isFailed()) {
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
      events.emit(EnginePublisherPeerStateUpdatedEvent(state: state, isPrimary: !_subscriberPrimary));
      logger.fine('publisher connectionState: $state');
      if (state.isDisconnected() || state.isFailed()) {
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

  Future<void> _handleGettingConnectedServerAddress(rtc.RTCPeerConnection pc) async {
    try {
      final remoteAddress = await getConnectedAddress(pc);
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

    if (_clientConfiguration?.resumeConnection == lk_models.ClientConfigSetting.DISABLED ||
        [
          ClientDisconnectReason.leaveReconnect,
          ClientDisconnectReason.negotiationFailed,
          ClientDisconnectReason.peerConnectionFailed,
        ].contains(reason)) {
      fullReconnectOnNext = true;
    }

    final gen = _sessionGen;
    try {
      _attemptingReconnect = true;

      if (await signalClient.networkIsAvailable() == false) {
        logger.fine('no internet connection, waiting...');
        await signalClient.events.waitFor<SignalConnectivityChangedEvent>(
          duration: connectOptions.timeouts.connection * 10,
          filter: (event) => !event.state.contains(ConnectivityResult.none),
          onTimeout: () => throw ConnectException(
            'attemptReconnect: Timed out waiting for SignalConnectivityChangedEvent',
            reason: ConnectionErrorReason.Timeout,
          ),
        );
      }

      if (fullReconnectOnNext) {
        await restartConnection();
      } else {
        await resumeConnection(reason, reconnectReason: reconnectReason);
      }
      _clearPendingReconnect();
      _attemptingReconnect = false;
      _isReconnecting = false;
      _unrecoveredResumes = 0;
    } catch (e) {
      if (gen != _sessionGen || _isClosed || (e is GravixResumeRejectedException && e.cancelled)) {
        // GRAVIX(one-session): a fresh connect or a disconnect cancelled this
        // attempt; it owns the session now
        logger.fine('attemptReconnect: cancelled ($e)');
        return;
      }
      _reconnectAttempts = _reconnectAttempts + 1;
      bool recoverable = true;
      var immediate = false;
      if (e is GravixResumeRejectedException) {
        // GRAVIX(resume-rejected): the server closed this session (Leave
        // RECONNECT / socket closed before the ReconnectResponse): rejoin now,
        // no second resume. A Leave{RESUME} keeps resuming, also at once.
        logger.info('resume rejected (${e.message}); ${e.full ? 'full reconnect' : 'resume again'} now');
        fullReconnectOnNext = e.full;
        immediate = true;
        _unrecoveredResumes = 0;
      } else if (e is WebSocketException || e is MediaConnectException) {
        // cannot resume connection, need to do full reconnect
        fullReconnectOnNext = true;
      } else if (!fullReconnectOnNext && ++_unrecoveredResumes >= _unrecoveredResumesBeforeFull) {
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
    }
  }

  Future<void> resumeConnection(ClientDisconnectReason reason, {lk_models.ReconnectReason? reconnectReason}) async {
    if (_isClosed) {
      return;
    }

    events.emit(const EngineResumingEvent());

    final abort = Completer<GravixResumeRejectedException>();
    _resumeAbort = abort;
    try {
      // wait for socket to connect rtc server
      try {
        await signalClient.connect(
          url!,
          token!,
          connectOptions: connectOptions,
          roomOptions: roomOptions,
          reconnect: true,
          reconnectReason: reconnectReason,
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
    } finally {
      if (identical(_resumeAbort, abort)) _resumeAbort = null;
    }

    logger.fine('resumeConnection: reason: ${reason.name}');

    if (_hasPublished) {
      logger.fine('resumeConnection: negotiating publisher...');
      await publisher!.createAndSendOffer(const RTCOfferOptions(iceRestart: true));
    }

    final isConnected = (await primary?.pc.getConnectionState())?.isConnected() ?? false;

    logger.fine('resumeConnection: primary is connected: $isConnected');

    if (!isConnected) {
      subscriber!.restartingIce = true;
      logger.fine('resumeConnection: Waiting for primary to connect...');
      await events.waitFor<EnginePeerStateUpdatedEvent>(
        filter: (event) => event.isPrimary && event.state.isConnected(),
        duration: connectOptions.timeouts.peerConnection,
        onTimeout: () =>
            throw MediaConnectException('resumeConnection: Timed out waiting for EnginePeerStateUpdatedEvent'),
      );
      logger.fine('resumeConnection: primary connected');
    }

    _isReconnecting = false;
    events.emit(const EngineResumedEvent());
  }

  @internal
  Future<void> restartConnection({String? regionUrl}) async {
    if (_isClosed) {
      return;
    }

    try {
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

      _inRestart = true;
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
        await ensurePublisherConnected();
      }

      fullReconnectOnNext = false;
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
      final nextRegionUrl =
          await restartRegionStrategy?.getNextUrl() ?? await _regionUrlProvider?.getNextBestRegionUrl();
      if (nextRegionUrl != null) {
        await restartConnection(regionUrl: nextRegionUrl);
        return;
      } else {
        // no more regions to try (or we're not on cloud)
        _regionUrlProvider?.resetAttempts();
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
        await negotiate();
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
        // its ReconnectResponse: the session is gone
        _abortResume(GravixResumeRejectedException('socket closed before the ReconnectResponse'));
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
      logger.finer('sdp: ${event.sd.sdp}');

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
            logger.finer('sdp: ${answer.sdp}');
            return answer;
          },
          setLocalDescription: (answer) => subscriber!.pc.setLocalDescription(answer),
          sendAnswer: signalClient.sendAnswer,
          mark: _gravixMark,
        );
      } catch (e) {
        _gravixMark('answerFailed', e.toString()); // GRAVIX: a refused answer shows in the join timeline
        logger.severe('[$objectId] Failed to createAnswer(): $e');
      }
    })
    ..on<SignalAnswerEvent>((event) async {
      if (publisher == null) {
        return;
      }
      logger.fine('received answer (type: ${event.sd.type})');
      logger.finer('sdp: ${event.sd.sdp}');
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
        fullReconnectOnNext = false;
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
    List<rtc.RTCRtpEncoding>? encodings,
  ) async {
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
    final transceiver = await publisher!.pc.addTransceiver(
      track: track.mediaStreamTrack,
      kind: track is LocalVideoTrack
          ? rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo
          : rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: transceiverInit,
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

Future<String?> getConnectedAddress(rtc.RTCPeerConnection pc) async {
  var selectedCandidatePairId = '';
  final candidatePairs = <String, rtc.StatsReport>{};
  // id -> candidate ip
  final candidates = <String, String>{};
  final List<rtc.StatsReport> stats = await pc.getStats();
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
class GravixResumeRejectedException implements Exception {
  GravixResumeRejectedException(this.message, {this.full = true, this.cancelled = false});
  final String message;
  final bool full;
  final bool cancelled;
  @override
  String toString() => 'GravixResumeRejectedException: $message';
}
