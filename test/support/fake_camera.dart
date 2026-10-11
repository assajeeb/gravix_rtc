// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Fakes for publishing a CAMERA over the fake engine (2026-10-11, data saver):
// a sender that keeps its parameters the way flutter_webrtc's native sender
// does (one cached object, stored by setParameters BEFORE the native call), a
// transceiver that accepts codec preferences, and a peer connection / factory
// that hand those out. The base fakes in fake_rtc.dart stay as they are.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'fake_rtc.dart';

/// FlutterWebRTC.Method calls a video publish makes (codec preferences read the
/// receiver capabilities). Install after [installRecoveryChannelMocks].
void installCameraChannelMocks() {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(
    const MethodChannel('FlutterWebRTC.Method'),
    (call) async => switch (call.method) {
      'getSources' => <String, dynamic>{'sources': <dynamic>[]},
      'getRtpReceiverCapabilities' => <String, dynamic>{
        'codecs': <dynamic>[],
        'headerExtensions': <dynamic>[],
        'fecMechanisms': <dynamic>[],
      },
      _ => null,
    },
  );
}

/// A video sender. [parameters] is ONE cached object, like the native sender's
/// (`RTCRtpSenderNative._parameters`): setParameters stores what it is given
/// before the native call, so a failed call leaves its values in the cache.
class FakeCamSender implements rtc.RTCRtpSender {
  FakeCamSender(this._track, List<rtc.RTCRtpEncoding>? encodings, this._id)
    : _parameters = rtc.RTCRtpParameters(
        encodings: [for (final e in encodings ?? const <rtc.RTCRtpEncoding>[]) rtc.RTCRtpEncoding.fromMap(e.toMap())],
      );

  final String _id;
  rtc.MediaStreamTrack? _track;
  rtc.RTCRtpParameters _parameters;

  /// setParameters throws (the native call failed).
  bool failSetParameters = false;

  /// Encodings (rid -> maxBitrate) of every setParameters that went through.
  final applied = <Map<String, int?>>[];
  int setParametersCalls = 0;

  /// What getStats returns.
  List<rtc.StatsReport> stats = const [];

  /// What getStats throws instead (null = nothing). flutter_webrtc throws a
  /// String for a sender whose native peer connection is gone.
  Object? statsError;

  @override
  String get senderId => _id;
  @override
  rtc.MediaStreamTrack? get track => _track;
  @override
  rtc.RTCRtpParameters get parameters => _parameters;

  @override
  Future<bool> setParameters(rtc.RTCRtpParameters parameters) async {
    setParametersCalls++;
    _parameters = parameters;
    if (failSetParameters) throw Exception('rtpSenderSetParameters failed');
    applied.add({for (final e in parameters.encodings ?? const <rtc.RTCRtpEncoding>[]) e.rid ?? '': e.maxBitrate});
    return true;
  }

  @override
  Future<void> replaceTrack(rtc.MediaStreamTrack? track) async => _track = track;
  @override
  Future<List<rtc.StatsReport>> getStats() async {
    if (statsError != null) throw statsError!;
    return stats;
  }

  /// Current maxBitrate per rid ('' = a single encoding without rid).
  Map<String, int?> get bitrates => {
    for (final e in _parameters.encodings ?? const <rtc.RTCRtpEncoding>[]) e.rid ?? '': e.maxBitrate,
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeCamTransceiver extends FakeTransceiver {
  FakeCamTransceiver(super.track, super.kind, this.camSender);
  final FakeCamSender camSender;
  @override
  rtc.RTCRtpSender get sender => camSender;
  @override
  Future<void> setCodecPreferences(List<rtc.RTCRtpCodecCapability> codecs) async {}
}

/// A peer connection whose transceivers carry [FakeCamSender]s.
class FakeCamPeerConnection extends FakePeerConnection {
  FakeCamPeerConnection(super.index);

  /// The next addTransceiver throws (a republish that fails).
  bool failNextAddTransceiver = false;
  int _senders = 0;

  List<FakeCamSender> get camSenders => [
    for (final t in added)
      if (t is FakeCamTransceiver) t.camSender,
  ];

  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver({
    rtc.MediaStreamTrack? track,
    rtc.RTCRtpMediaType? kind,
    rtc.RTCRtpTransceiverInit? init,
  }) async {
    // the native side: a track whose capture was stopped/disposed no longer
    // exists (iOS: "can't addTransceiver!", Android: "track is null")
    if (track is FakeMediaTrack && track.stopped) {
      throw Exception("Unable to RTCPeerConnection::addTransceiver: Error: can't addTransceiver!");
    }
    if (failNextAddTransceiver) {
      failNextAddTransceiver = false;
      throw Exception('Unable to RTCPeerConnection::addTransceiver: forced failure');
    }
    final t = FakeCamTransceiver(
      track,
      kind,
      FakeCamSender(track, init?.sendEncodings, 'sender-${index}-${_senders++}'),
    );
    added.add(t);
    return t;
  }
}

class FakeCamPcFactory extends FakePcFactory {
  FakeCamPeerConnection get camPublisher => publisher as FakeCamPeerConnection;

  @override
  Future<rtc.RTCPeerConnection> create(Map<String, dynamic> configuration, [Map<String, dynamic>? constraints]) async {
    final pc = FakeCamPeerConnection(all.length);
    all.add(pc);
    onCreate?.call(pc);
    return pc;
  }
}
