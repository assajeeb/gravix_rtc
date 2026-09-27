import 'dart:async';

import 'package:gravix_rtc/gravix_rtc.dart';

/// In-memory [GravixAudioPlatform] so the routing logic can be tested without
/// a device or a method channel.
class FakeAudioPlatform implements GravixAudioPlatform {
  FakeAudioPlatform({this.isAndroid = true});

  @override
  bool isAndroid;

  GravixAudioHardwareMode mode = GravixAudioHardwareMode.normal;
  bool scoOn = false;
  String? communicationDeviceType;
  GravixAudioDeviceSnapshot outputs = const GravixAudioDeviceSnapshot();

  /// Every `setSpeakerOutputPreferred` call, in order.
  final List<({bool preferred, bool force})> speakerCalls = [];
  final List<String> sessionCalls = [];

  /// When set, the next [setSpeakerOutputPreferred] throws this.
  Object? speakerError;

  /// Every `setDirectAudioOutput` call, in order.
  final List<GravixAudioOutput> directOutputCalls = [];

  /// What [setDirectAudioOutput] returns — false stands in for a handset with
  /// no earpiece, or an API-31 call the platform refused.
  bool directOutputSupported = true;

  /// When set, the next [setDirectAudioOutput] throws this.
  Object? directOutputError;

  final StreamController<String> devices = StreamController<String>.broadcast();
  final StreamController<void> noisy = StreamController<void>.broadcast();

  @override
  Future<GravixAudioHardwareMode> getMode() async => mode;

  @override
  Future<bool> isBluetoothScoOn() async => scoOn;

  @override
  Future<String?> getCommunicationDeviceType() async => communicationDeviceType;

  @override
  Future<GravixAudioDeviceSnapshot> getOutputs() async => outputs;

  @override
  Future<void> setSpeakerOutputPreferred(bool preferred, {bool force = false}) async {
    final error = speakerError;
    if (error != null) {
      speakerError = null;
      throw error;
    }
    speakerCalls.add((preferred: preferred, force: force));
  }

  @override
  Future<bool> setDirectAudioOutput(GravixAudioOutput output) async {
    final error = directOutputError;
    if (error != null) {
      directOutputError = null;
      throw error;
    }
    directOutputCalls.add(output);
    return directOutputSupported;
  }

  @override
  Future<void> claimManualSessionManagement() async => sessionCalls.add('claim');

  @override
  Future<void> startCommunicationSession() async {
    sessionCalls.add('start');
    mode = GravixAudioHardwareMode.inCommunication;
  }

  @override
  Future<void> stopCommunicationSession() async {
    sessionCalls.add('stop');
    mode = GravixAudioHardwareMode.normal;
  }

  @override
  Stream<String> get devicesChanged => devices.stream;

  @override
  Stream<void> get becomingNoisy => noisy.stream;

  Future<void> close() async {
    await devices.close();
    await noisy.close();
  }
}

/// Mutable [GravixAudioHost] stand-in for guard tests.
class FakeAudioHost implements GravixAudioHost {
  FakeAudioHost({
    this.isRoomConnected = true,
    this.appBackgrounded = false,
    this.audioFlowing = true,
    this.recordableRoomAudio = false,
  });

  @override
  bool isRoomConnected;
  @override
  bool appBackgrounded;
  @override
  bool audioFlowing;
  @override
  bool recordableRoomAudio;
}
