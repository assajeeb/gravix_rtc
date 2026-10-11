// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Shared fakes for the reconnect / recovery tests (2026-10-10): a scriptable
// signal server, peer connections whose state the test drives, and a factory
// that records every peer connection the engine creates. Parts follow the
// shape of upstream's test/mock (peerconnection_mock.dart, websocket_mock.dart)
// but every state change here is explicit, so a test can hold a peer
// connection "not connected" for as long as it needs.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/constants.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/reconnect_policy.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';

/// Mocks the platform channels the engine and room touch in a unit test.
void installRecoveryChannelMocks() {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(Native.channel, (call) async => null);
  m.setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (call) async => null);
  for (final name in const ['com.ryanheise.android_audio_manager', 'com.ryanheise.av_audio_session']) {
    m.setMockMethodCallHandler(
      MethodChannel(name),
      (call) async => switch (call.method) {
        'getDevices' => <dynamic>[],
        'getMode' => 0,
        'isBluetoothScoOn' => false,
        _ => null,
      },
    );
  }
  m.setMockMethodCallHandler(
    const MethodChannel('FlutterWebRTC.Method'),
    (call) async => call.method == 'getSources' ? <String, dynamic>{'sources': <dynamic>[]} : null,
  );
  for (final ch in const ['dev.fluttercommunity.plus/device_info', 'dev.fluttercommunity.plus/package_info']) {
    m.setMockMethodCallHandler(MethodChannel(ch), (call) async => <String, dynamic>{});
  }
}

class FakeWs extends GravixRtcWebSocket {
  FakeWs(this.handlers, this.uri, [this.server]) {
    onDispose(() async {
      closed = true;
      handlers?.onDispose?.call();
    });
  }
  final WebSocketEventHandlers? handlers;
  final Uri uri;
  final FakeSignalServer? server;
  final sent = <lk_rtc.SignalRequest>[];
  bool closed = false;

  bool get isResume => uri.queryParameters['reconnect'] == '1';

  @override
  void send(List<int> data) {
    if (closed) return;
    final req = lk_rtc.SignalRequest.fromBuffer(data);
    sent.add(req);
    // the server answers a publisher offer
    if (req.hasOffer() && server?.answerOffers == true) {
      server!.offersSeen++;
      Timer(const Duration(milliseconds: 1), () {
        deliver(
          lk_rtc.SignalResponse(
            answer: lk_rtc.SessionDescription(
              type: 'answer',
              sdp: server!.answerSdp?.call(req.offer.sdp) ?? 'v=0\r\ns=-\r\nt=0 0\r\n',
            ),
          ),
        );
      });
    }
    // the server publishes an added track
    if (req.hasAddTrack() && !(server?.holdAddTrack?.call(this) ?? false)) {
      final a = req.addTrack;
      Timer(const Duration(milliseconds: 1), () {
        deliver(
          lk_rtc.SignalResponse(
            trackPublished: lk_rtc.TrackPublishedResponse(
              cid: a.cid,
              track: lk_models.TrackInfo(
                sid: 'TR_${a.cid.hashCode.toUnsigned(20)}',
                type: a.type,
                source: a.source,
                name: a.name,
                muted: a.muted,
              ),
            ),
          ),
        );
      });
    }
    // the server answers a leave with Leave{DISCONNECT} and closes the socket
    if (req.hasLeave()) {
      Timer(const Duration(milliseconds: 1), () async {
        deliver(
          lk_rtc.SignalResponse(
            leave: lk_rtc.LeaveRequest(
              reason: lk_models.DisconnectReason.CLIENT_INITIATED,
              action: lk_rtc.LeaveRequest_Action.DISCONNECT,
            ),
          ),
        );
        await serverClose();
      });
    }
  }

  void deliver(lk_rtc.SignalResponse r) {
    if (closed) return;
    handlers?.onData?.call(r.writeToBuffer());
  }

  Future<void> serverClose() => dispose();
}

/// A signal server. Every dial is recorded. [onDial] decides what a dial does
/// (throw = the dial fails); by default a resume is answered with a
/// ReconnectResponse and a fresh join with [joinResponse] (when set).
class FakeSignalServer {
  final sockets = <FakeWs>[];
  final dials = <Uri>[];

  /// What a fresh join is answered with; null = nothing (the test answers).
  lk_rtc.JoinResponse Function(Uri uri)? joinResponse;

  /// Answer resumes with a ReconnectResponse (default true).
  bool answerResumes = true;

  /// Runs right after a fresh join was answered (e.g. a relayed participant's
  /// update that follows the JoinResponse).
  void Function(FakeWs ws)? afterJoin;

  /// Runs right after a resume was answered (e.g. the server's subscriber
  /// ICE-restart offer, a Leave).
  void Function(FakeWs ws)? afterResumeAnswer;

  /// True for a socket whose AddTrack requests the server never answers.
  bool Function(FakeWs ws)? holdAddTrack;

  /// Answer publisher offers (default false: the test answers or not).
  bool answerOffers = false;
  int offersSeen = 0;

  /// The SDP of the answer to an offer (default: a fixed one).
  String Function(String offerSdp)? answerSdp;

  /// Called before the socket is created; throw to fail the dial; return a
  /// future to delay it.
  Future<void> Function(Uri uri)? onDial;

  FakeWs get last => sockets.last;

  Future<GravixRtcWebSocket> connect(
    Uri uri, {
    WebSocketEventHandlers? options,
    Map<String, String>? headers,
    NetworkOptions? networkOptions,
    Object? preconnected,
  }) async {
    dials.add(uri);
    await onDial?.call(uri);
    final ws = FakeWs(options, uri, this);
    sockets.add(ws);
    if (ws.isResume) {
      if (answerResumes) {
        scheduleMicrotask(() {
          ws.deliver(lk_rtc.SignalResponse(reconnect: lk_rtc.ReconnectResponse()));
          afterResumeAnswer?.call(ws);
        });
      }
    } else if (joinResponse != null) {
      final join = joinResponse!(uri);
      Timer(const Duration(milliseconds: 1), () {
        ws.deliver(lk_rtc.SignalResponse(join: join));
        afterJoin?.call(ws);
      });
    }
    return ws;
  }
}

lk_rtc.JoinResponse fakeJoinResponse({
  bool subscriberPrimary = false,
  List<lk_models.ParticipantInfo> others = const [],
  String identity = 'me',
  String sid = 'PA_me',
  String serverRegion = '',
}) => lk_rtc.JoinResponse(
  room: lk_models.Room(name: 'r', sid: 'RM_r'),
  participant: lk_models.ParticipantInfo(sid: sid, identity: identity),
  otherParticipants: others,
  subscriberPrimary: subscriberPrimary,
  serverVersion: '1.9.0',
  serverRegion: serverRegion,
);

/// A capture track; [stop] is what a stopOnMute mute does to the native track.
class FakeMediaTrack implements rtc.MediaStreamTrack {
  FakeMediaTrack(this.id, {this.kind = 'audio'});
  @override
  final String? id;
  @override
  final String? kind;
  @override
  bool enabled = true;
  bool stopped = false;
  @override
  Function()? onEnded;
  @override
  Future<void> stop() async => stopped = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeMediaStream implements rtc.MediaStream {
  FakeMediaStream(this.tracks, {this.id = 'stream'});
  final List<FakeMediaTrack> tracks;
  bool disposed = false;
  @override
  final String id;
  @override
  Future<void> dispose() async => disposed = true;
  @override
  List<rtc.MediaStreamTrack> getTracks() => tracks;
  @override
  List<rtc.MediaStreamTrack> getAudioTracks() => [
    for (final t in tracks)
      if (t.kind == 'audio') t,
  ];
  @override
  List<rtc.MediaStreamTrack> getVideoTracks() => [
    for (final t in tracks)
      if (t.kind == 'video') t,
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A remote track's receiver; its own stats poll finds nothing (the tests emit
/// the stats events themselves).
class FakeReceiver implements rtc.RTCRtpReceiver {
  int getStatsCalls = 0;
  @override
  Future<List<rtc.StatsReport>> getStats() async {
    getStatsCalls++;
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSender implements rtc.RTCRtpSender {
  FakeSender(this._track);
  rtc.MediaStreamTrack? _track;
  @override
  rtc.MediaStreamTrack? get track => _track;
  final replaced = <rtc.MediaStreamTrack?>[];
  @override
  rtc.RTCRtpParameters get parameters => rtc.RTCRtpParameters(encodings: []);
  @override
  Future<bool> setParameters(rtc.RTCRtpParameters parameters) async => true;
  @override
  Future<void> replaceTrack(rtc.MediaStreamTrack? track) async {
    replaced.add(track);
    _track = track;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTransceiver implements rtc.RTCRtpTransceiver {
  FakeTransceiver(this.track, this.kind) : _sender = FakeSender(track);
  final rtc.MediaStreamTrack? track;
  final rtc.RTCRtpMediaType? kind;
  final FakeSender _sender;
  @override
  rtc.RTCRtpSender get sender => _sender;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDataChannel implements rtc.RTCDataChannel {
  FakeDataChannel(this._label, this._id);
  final String _label;
  final int _id;
  final sentMessages = <rtc.RTCDataChannelMessage>[];
  @override
  String? get label => _label;
  @override
  int? get id => _id;
  @override
  rtc.RTCDataChannelState? get state => rtc.RTCDataChannelState.RTCDataChannelOpen;
  @override
  Function(rtc.RTCDataChannelState state)? onDataChannelState;
  @override
  Function(rtc.RTCDataChannelMessage data)? onMessage;
  @override
  Function(int currentAmount, int changedAmount)? onBufferedAmountChange;
  @override
  Function(int currentAmount)? onBufferedAmountLow;
  @override
  int? bufferedAmountLowThreshold = 0;
  @override
  int? get bufferedAmount => 0;
  @override
  Future<int> getBufferedAmount() async => 0;
  @override
  Future<void> send(rtc.RTCDataChannelMessage message) async => sentMessages.add(message);
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A peer connection whose connection state only the test changes.
class FakePeerConnection extends rtc.RTCPeerConnection {
  FakePeerConnection(this.index);
  final int index;

  rtc.RTCSessionDescription? _local;
  rtc.RTCSessionDescription? _remote;
  rtc.RTCPeerConnectionState _state = rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew;
  bool closed = false;
  int restartIceCalls = 0;

  /// The constraints of every createOffer, in order.
  final offers = <Map<String, dynamic>>[];
  final added = <FakeTransceiver>[];
  final dataChannels = <FakeDataChannel>[];

  /// Remote candidates added to the native side, in order.
  final addedCandidates = <rtc.RTCIceCandidate>[];

  /// Delays [getConnectionState] (to order it after a concurrent signal event).
  Duration? connectionStateDelay;

  /// Every setRemoteDescription / setLocalDescription, in order (type:sdp tag).
  final descriptionLog = <String>[];

  /// Delays setRemoteDescription (an answer being applied slowly).
  Duration? remoteDescriptionDelay;

  /// Stats returned by [getStats].
  List<rtc.StatsReport> stats = const [];
  int getStatsCalls = 0;

  int get iceRestartOffers => offers.where((o) => o['iceRestart'] == true).length;

  /// Drives the connection state, firing onConnectionState like the native side.
  void setState(rtc.RTCPeerConnectionState s) {
    if (_state == s) return;
    _state = s;
    onConnectionState?.call(s);
  }

  void connect() => setState(rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected);
  void disconnect() => setState(rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);

  @override
  rtc.RTCPeerConnectionState? get connectionState => _state;
  @override
  rtc.RTCIceConnectionState? get iceConnectionState => null;
  @override
  rtc.RTCIceGatheringState? get iceGatheringState => null;

  @override
  rtc.RTCSignalingState? get signalingState {
    if (closed) return rtc.RTCSignalingState.RTCSignalingStateClosed;
    if (_local?.type == 'offer' && _remote?.type != 'answer') {
      return rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer;
    }
    if (_remote?.type == 'offer' && _local?.type != 'answer') {
      return rtc.RTCSignalingState.RTCSignalingStateHaveRemoteOffer;
    }
    return rtc.RTCSignalingState.RTCSignalingStateStable;
  }

  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async {
    offers.add(Map.of(constraints ?? const {}));
    return rtc.RTCSessionDescription('v=0\r\ns=-\r\nt=0 0\r\n', 'offer');
  }

  @override
  Future<rtc.RTCSessionDescription> createAnswer([Map<String, dynamic>? constraints]) async =>
      rtc.RTCSessionDescription('v=0\r\ns=-\r\nt=0 0\r\n', 'answer');

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription description) async {
    descriptionLog.add('local:${description.type}');
    _local = description;
    if (description.type == 'offer') _remote = null;
  }

  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription description) async {
    descriptionLog.add('remote:${description.type}:start:${_tag(description.sdp)}');
    if (remoteDescriptionDelay != null) await Future<void>.delayed(remoteDescriptionDelay!);
    _remote = description;
    if (description.type == 'offer') _local = null;
    descriptionLog.add('remote:${description.type}:done:${_tag(description.sdp)}');
  }

  static String _tag(String? sdp) => RegExp(r'a=tag:(\w+)').firstMatch(sdp ?? '')?.group(1) ?? '-';

  @override
  Future<rtc.RTCPeerConnectionState?> getConnectionState() async {
    if (connectionStateDelay != null) await Future<void>.delayed(connectionStateDelay!);
    return _state;
  }

  @override
  Future<rtc.RTCSessionDescription?> getLocalDescription() async => _local;
  @override
  Future<rtc.RTCSessionDescription?> getRemoteDescription() async => _remote;
  @override
  Future<void> addCandidate(rtc.RTCIceCandidate candidate) async {
    addedCandidates.add(candidate);
    final f = RegExp(r'^candidate:(\S+)').firstMatch(candidate.candidate ?? '')?.group(1) ?? '?';
    descriptionLog.add('cand:$f');
  }

  @override
  Future<void> restartIce() async => restartIceCalls++;
  @override
  Future<void> setConfiguration(Map<String, dynamic> configuration) async {}
  @override
  Map<String, dynamic> get getConfiguration => const {};
  @override
  Future<rtc.RTCDataChannel> createDataChannel(String label, rtc.RTCDataChannelInit dataChannelDict) async {
    final dc = FakeDataChannel(label, dataChannelDict.id);
    dataChannels.add(dc);
    return dc;
  }

  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver({
    rtc.MediaStreamTrack? track,
    rtc.RTCRtpMediaType? kind,
    rtc.RTCRtpTransceiverInit? init,
  }) async {
    // the native side: a track whose capture was stopped no longer exists
    // (field 2026-10-09: "addTransceiver(): track is null")
    if (track is FakeMediaTrack && track.stopped) {
      throw Exception('Unable to RTCPeerConnection::addTransceiver: addTransceiver(): track is null');
    }
    final t = FakeTransceiver(track, kind);
    added.add(t);
    return t;
  }

  @override
  Future<List<rtc.StatsReport>> getStats([rtc.MediaStreamTrack? track]) async {
    getStatsCalls++;
    return stats;
  }

  @override
  Future<List<rtc.RTCRtpSender>> getSenders() async => [for (final t in added) t.sender];
  @override
  Future<List<rtc.RTCRtpReceiver>> getReceivers() async => const [];
  @override
  Future<List<rtc.RTCRtpTransceiver>> getTransceivers() async => added;
  @override
  Future<bool> removeTrack(rtc.RTCRtpSender sender) async => true;
  @override
  Future<void> close() async => closed = true;
  @override
  Future<void> dispose() async => closed = true;
  @override
  Future<void> addStream(rtc.MediaStream stream) async {}
  @override
  Future<void> removeStream(rtc.MediaStream stream) async {}
  @override
  List<rtc.MediaStream?> getLocalStreams() => const [];
  @override
  List<rtc.MediaStream?> getRemoteStreams() => const [];
  @override
  Future<rtc.RTCRtpSender> addTrack(rtc.MediaStreamTrack track, [rtc.MediaStream? stream]) =>
      throw UnimplementedError();
  @override
  rtc.RTCDTMFSender createDtmfSender(rtc.MediaStreamTrack track) => throw UnimplementedError();
}

/// Records the peer connections an engine creates: the first of each pair is the
/// publisher, the second the subscriber (Engine._createPeerConnections order).
class FakePcFactory {
  final all = <FakePeerConnection>[];

  /// Called with every new peer connection (e.g. [autoConnectPcs]).
  void Function(FakePeerConnection pc)? onCreate;

  FakePeerConnection get publisher => all[all.length - 2];
  FakePeerConnection get subscriber => all[all.length - 1];

  Future<rtc.RTCPeerConnection> create(Map<String, dynamic> configuration, [Map<String, dynamic>? constraints]) async {
    final pc = FakePeerConnection(all.length);
    all.add(pc);
    onCreate?.call(pc);
    return pc;
  }
}

/// Fixed small delays so a scheduled retry is visible but quick.
class FastPolicy extends ReconnectPolicy {
  @override
  int? nextRetryDelayInMs(ReconnectContext context) => context.retryCount >= 8 ? null : 10;
}

Timeouts fastTimeouts({
  Duration peerConnection = const Duration(seconds: 10),
  Duration connection = const Duration(seconds: 5),
  Duration mediaConnect = const Duration(seconds: 5),
}) => Timeouts(
  connection: connection,
  debounce: const Duration(milliseconds: 5),
  publish: const Duration(seconds: 5),
  subscribe: const Duration(seconds: 5),
  peerConnection: peerConnection,
  iceRestart: const Duration(seconds: 5),
  mediaConnect: mediaConnect,
);

/// An engine joined over [server] with fake peer connections, the primary one
/// connected. Returns once [Engine.connect] completed.
Future<Engine> connectedFakeEngine(
  FakeSignalServer server,
  FakePcFactory pcs, {
  SignalClient? signalClient,
  bool subscriberPrimary = false,
  RoomOptions? roomOptions,
  Duration peerConnection = const Duration(seconds: 10),
  Duration connection = const Duration(seconds: 5),
  // (2026-10-11: a full reconnect waits mediaConnect for its peer connection,
  // GravixRecoveryOptions.fullReconnectMediaConnect)
  Duration mediaConnect = const Duration(seconds: 5),
  String url = 'wss://blr1.example',
}) async {
  final sc = signalClient ?? SignalClient(server.connect);
  final engine = Engine(
    connectOptions: ConnectOptions(
      timeouts: fastTimeouts(peerConnection: peerConnection, connection: connection, mediaConnect: mediaConnect),
    ),
    roomOptions: roomOptions ?? RoomOptions(reconnectPolicy: FastPolicy()),
    signalClient: sc,
    peerConnectionCreate: pcs.create,
  );
  server.joinResponse ??= (_) => fakeJoinResponse(subscriberPrimary: subscriberPrimary);
  final connecting = engine.connect(url, 'tok');
  // the join response creates the peer connections; connect the primary
  for (var i = 0; i < 200 && pcs.all.length < 2; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  (subscriberPrimary ? pcs.subscriber : pcs.publisher).connect();
  (subscriberPrimary ? pcs.publisher : pcs.subscriber).connect();
  await connecting;
  return engine;
}

Future<void> settle([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));

/// Polls [cond] up to [timeout].
Future<bool> eventually(bool Function() cond, {Duration timeout = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return cond();
}

/// A Room over a fake engine (fake signal server and peer connections), joined
/// to [url]: the peer connections of the join are connected as soon as they exist.
Future<Room> connectedFakeRoom(
  FakeSignalServer server,
  FakePcFactory pcs, {
  bool subscriberPrimary = false,
  RoomOptions? roomOptions,
  Duration peerConnection = const Duration(seconds: 10),
  String url = 'wss://blr1.example',
  String serverRegion = '',
}) async {
  final sc = SignalClient(server.connect);
  final options = roomOptions ?? RoomOptions(reconnectPolicy: FastPolicy());
  final engine = Engine(
    connectOptions: ConnectOptions(timeouts: fastTimeouts(peerConnection: peerConnection)),
    roomOptions: options,
    signalClient: sc,
    peerConnectionCreate: pcs.create,
  );
  final room = Room(engine: engine, roomOptions: options);
  server.joinResponse ??= (_) => fakeJoinResponse(subscriberPrimary: subscriberPrimary, serverRegion: serverRegion);
  autoConnectPcs(pcs);
  await room.connect(
    url,
    'tok',
    connectOptions: ConnectOptions(timeouts: fastTimeouts(peerConnection: peerConnection), joinRetries: 0),
  );
  return room;
}

/// Connects every peer connection the factory creates from now on, right after
/// it is created (a join or a full reconnect that the test does not hold).
void autoConnectPcs(FakePcFactory pcs) => pcs.onCreate = (pc) {
  Timer(const Duration(milliseconds: 30), pc.connect);
};

/// A signal client whose connectivity reading the test sets (the real one
/// always reports "available" under flutter test).
class FakeConnectivitySignalClient extends SignalClient {
  FakeConnectivitySignalClient(super.wsConnector);
  bool online = true;
  int checks = 0;
  @override
  Future<bool> networkIsAvailable() async {
    checks++;
    return online;
  }
}
