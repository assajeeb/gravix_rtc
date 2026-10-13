// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// flutter_webrtc's cost on the app's event loop, modelled (2026-10-12,
// signal-isolate harness).
//
// On a phone every flutter_webrtc call is a method-channel round trip
// ('FlutterWebRTC.Method': Dart -> the platform thread -> a reply task on the
// UI isolate) and every native callback (onIceCandidate, onConnectionState,
// onTrack) is an EventChannel message to the ROOT isolate. Each one is a task
// on the app's event loop: when the app is busy (startup work in 40-80 ms
// blocks), each waits for the block in front of it. The plain fakes in
// fake_rtc.dart answer within the same task (microtasks), so they hide that
// cost entirely.
//
// Here every call and every callback crosses a helper isolate (the "platform
// thread", idle: only the app's isolate is busy) and comes back as a port
// message: one event-loop hop each, tagged `pc` so the harness can tell the
// hops a signalling isolate could never move from the ones it could.
//
// The native connection runs on the platform clock: once a peer connection has
// both descriptions and a remote candidate, its ICE is up [iceMs] later and
// ICE + DTLS [iceDtlsMs] later -- whatever the app's isolate is doing. That
// moment ([HopPeerConnection.nativeConnectedUs]) is when media could flow
// (first audio is native once DTLS is up); the Dart callback that reports it
// arrives one (busy) hop later.
import 'dart:async';
import 'dart:isolate';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'fake_rtc.dart';

class PlatformSim {
  PlatformSim._(this._iso, this._rx, this._tx, this.callLatency);

  final Isolate _iso;
  final ReceivePort _rx;
  final SendPort _tx;

  /// A method call's time on the (idle) platform thread.
  final Duration callLatency;

  final _pending = <int, void Function(int wallUs)>{};
  int _next = 0;

  /// Method-channel round trips and EventChannel callbacks delivered.
  int calls = 0, callbacks = 0;

  /// Sum of the method calls' round trips as the app's isolate saw them (µs):
  /// the platform's [callLatency] plus the wait for the app's event loop.
  int callWaitUs = 0;

  /// Per operation: count and summed round trip (µs).
  final byOp = <String, ({int n, int us})>{};

  static Future<PlatformSim> start({Duration callLatency = const Duration(milliseconds: 1)}) async {
    final rx = ReceivePort();
    final first = Completer<SendPort>();
    PlatformSim? sim;
    rx.listen((dynamic m) {
      if (m is SendPort) {
        first.complete(m);
        return;
      }
      final l = m as List;
      sim?._pending.remove(l[0] as int)?.call(l[1] as int);
    });
    final iso = await Isolate.spawn(_platformMain, rx.sendPort);
    return sim = PlatformSim._(iso, rx, await first.future, callLatency);
  }

  void resetCounters() {
    calls = 0;
    callbacks = 0;
    callWaitUs = 0;
    byOp.clear();
  }

  /// A method-channel call: resolves (on a later task of this isolate) with the
  /// platform's wall clock when it answered.
  Future<int> call(String op) {
    final c = Completer<int>();
    final id = _next++;
    final sw = Stopwatch()..start();
    _pending[id] = (wallUs) {
      final us = sw.elapsedMicroseconds;
      calls++;
      callWaitUs += us;
      final prev = byOp[op];
      byOp[op] = (n: (prev?.n ?? 0) + 1, us: (prev?.us ?? 0) + us);
      c.complete(wallUs);
    };
    _tx.send(<int>[id, callLatency.inMicroseconds]);
    return c.future;
  }

  /// A native callback [after] from now on the platform clock, delivered to
  /// this isolate as a message; [run] gets the platform's wall clock of the
  /// moment it happened natively.
  void callback(Duration after, void Function(int nativeWallUs) run) {
    final id = _next++;
    _pending[id] = (wallUs) {
      callbacks++;
      run(wallUs);
    };
    _tx.send(<int>[id, after.inMicroseconds]);
  }

  Future<void> stop() async {
    _iso.kill(priority: Isolate.immediate);
    _rx.close();
  }
}

void _platformMain(SendPort out) {
  final rx = ReceivePort();
  out.send(rx.sendPort);
  rx.listen((dynamic m) {
    final l = m as List<int>;
    void reply() => out.send(<int>[l[0], DateTime.now().microsecondsSinceEpoch]);
    if (l[1] <= 0) {
      reply();
    } else {
      Timer(Duration(microseconds: l[1]), reply);
    }
  });
}

/// A [FakePeerConnection] whose every flutter_webrtc call and callback costs one
/// event-loop hop of the app's isolate (see the file comment).
class HopPeerConnection extends FakePeerConnection {
  HopPeerConnection(super.index, this.sim, {this.iceMs = 15, this.iceDtlsMs = 25});

  final PlatformSim sim;
  final int iceMs, iceDtlsMs;

  int remoteCandidates = 0;
  bool _haveLocal = false, _haveRemote = false;
  bool _connectScheduled = false;
  bool _trackFired = false;

  /// Platform wall clock (µs) when ICE + DTLS were up natively; null until then.
  int? nativeConnectedUs;

  /// Called (on this isolate) when the subscriber's remote audio track arrives.
  void Function(int nativeWallUs)? onTrackNative;

  Future<void> _hop(String op) => sim.call(op);

  void _maybeConnect() {
    if (_connectScheduled || remoteCandidates == 0 || !_haveLocal || !_haveRemote) return;
    if (signalingState != rtc.RTCSignalingState.RTCSignalingStateStable) return;
    _connectScheduled = true;
    sim.callback(Duration(milliseconds: iceMs), (_) {
      if (closed) return;
      onIceConnectionState?.call(rtc.RTCIceConnectionState.RTCIceConnectionStateConnected);
    });
    sim.callback(Duration(milliseconds: iceDtlsMs), (wall) {
      if (closed) return;
      nativeConnectedUs = wall;
      connect();
    });
  }

  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async {
    await _hop('createOffer');
    return super.createOffer(constraints);
  }

  @override
  Future<rtc.RTCSessionDescription> createAnswer([Map<String, dynamic>? constraints]) async {
    await _hop('createAnswer');
    return super.createAnswer(constraints);
  }

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription description) async {
    await _hop('setLocalDescription');
    await super.setLocalDescription(description);
    _haveLocal = true;
    // the native side gathers: two host candidates, each an EventChannel message
    for (final ms in const [2, 4]) {
      sim.callback(Duration(milliseconds: ms), (_) {
        if (closed) return;
        onIceCandidate?.call(rtc.RTCIceCandidate('candidate:$ms 1 udp 2122260223 10.0.0.2 5$ms typ host', '0', 0));
      });
    }
    _maybeConnect();
  }

  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription description) async {
    await _hop('setRemoteDescription');
    await super.setRemoteDescription(description);
    _haveRemote = true;
    if (description.type == 'offer' && (description.sdp ?? '').contains('m=audio') && !_trackFired) {
      _trackFired = true;
      sim.callback(const Duration(milliseconds: 1), (wall) {
        if (closed) return;
        final track = FakeMediaTrack('TR_hostaudio');
        onTrack?.call(
          rtc.RTCTrackEvent(
            streams: [
              _HopStream([track], id: 'PA_host|TR_hostaudio'),
            ],
            track: track,
            receiver: FakeReceiver(),
          ),
        );
        onTrackNative?.call(wall);
      });
    }
    _maybeConnect();
  }

  @override
  Future<void> addCandidate(rtc.RTCIceCandidate candidate) async {
    await _hop('addCandidate');
    await super.addCandidate(candidate);
    remoteCandidates++;
    _maybeConnect();
  }

  @override
  Future<rtc.RTCPeerConnectionState?> getConnectionState() async {
    await _hop('getConnectionState');
    return super.getConnectionState();
  }

  @override
  Future<rtc.RTCSignalingState?> getSignalingState() async {
    await _hop('getSignalingState');
    return signalingState;
  }

  @override
  Future<rtc.RTCDataChannel> createDataChannel(String label, rtc.RTCDataChannelInit dataChannelDict) async {
    await _hop('createDataChannel');
    return super.createDataChannel(label, dataChannelDict);
  }

  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver({
    rtc.MediaStreamTrack? track,
    rtc.RTCRtpMediaType? kind,
    rtc.RTCRtpTransceiverInit? init,
  }) async {
    await _hop('addTransceiver');
    return super.addTransceiver(track: track, kind: kind, init: init);
  }

  @override
  Future<void> setConfiguration(Map<String, dynamic> configuration) async {
    await _hop('setConfiguration');
  }

  @override
  Future<List<rtc.StatsReport>> getStats([rtc.MediaStreamTrack? track]) async {
    await _hop('getStats');
    return super.getStats(track);
  }

  @override
  Future<List<rtc.RTCRtpSender>> getSenders() async {
    await _hop('getSenders');
    return super.getSenders();
  }

  @override
  Future<List<rtc.RTCRtpTransceiver>> getTransceivers() async {
    await _hop('getTransceivers');
    return super.getTransceivers();
  }

  @override
  Future<void> close() async {
    await _hop('close');
    await super.close();
  }
}

/// A remote stream the engine can hang its (unreliable) track callbacks on.
class _HopStream extends FakeMediaStream {
  _HopStream(super.tracks, {super.id});
  Function(rtc.MediaStreamTrack track)? _onAdd, _onRemove;
  @override
  Function(rtc.MediaStreamTrack track)? get onAddTrack => _onAdd;
  @override
  set onAddTrack(Function(rtc.MediaStreamTrack track)? f) => _onAdd = f;
  @override
  Function(rtc.MediaStreamTrack track)? get onRemoveTrack => _onRemove;
  @override
  set onRemoveTrack(Function(rtc.MediaStreamTrack track)? f) => _onRemove = f;
}

/// Creates [HopPeerConnection]s (each creation a method-channel round trip too).
class HopPcFactory {
  HopPcFactory(this.sim);
  final PlatformSim sim;
  final all = <HopPeerConnection>[];
  void Function(HopPeerConnection pc)? onCreate;

  Future<rtc.RTCPeerConnection> create(Map<String, dynamic> configuration, [Map<String, dynamic>? constraints]) async {
    await sim.call('createPeerConnection');
    final pc = HopPeerConnection(all.length, sim);
    all.add(pc);
    onCreate?.call(pc);
    return pc;
  }
}
