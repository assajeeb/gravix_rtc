// 2026-10-10 ECHO: media-mode echo experiments for the device harness.
//
// Field finding (AUDIO-LEAK device run 2026-10-10): with the field app's media
// profile (WebRTC.initialize with the media configuration,
// androidUseHardwareAudioProcessing false, bypassVoiceProcessing true =
// MIC source, stereo, no low-latency playout, software AEC3) the room's own
// playout came back at +5.4/+3.8 dB over the user's voice on an Infinix and
// -1.7/-8.6 dB on a Xiaomi; the communication profile: -58 dB. Each variant
// below is one process configuration, chosen per launch (`aecVariant` extra),
// so one APK covers every arm. Nothing here runs without the extra/define.
import 'dart:async';

// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/event_channel.dart' show FlutterWebRTCEventChannel;
import 'package:gravix_rtc/gravix_rtc.dart';

/// logcat tag of every echo-experiment line.
const kEchoTag = 'GRAVIX_ECHO';

/// Default trials of the `pakhiTrials` arm when no `aec3Trials` extra is given:
/// the HMM transparent-mode classifier instead of the legacy one (the legacy one
/// turns suppression off after ~6 s of render without a converged filter), and
/// conservative high-band suppression.
const kDefaultEchoTrials = 'WebRTC-Aec3TransparentModeHmm/Enabled/WebRTC-Aec3EnforceConservativeHfSuppression/Enabled/';

/// The variants (each run's notes are kept with the test records).
const kEchoVariants = <String, String>{
  'pakhi': 'field settings: media, MIC, stereo, no low-latency, software AEC3',
  'pakhiLL': 'field settings + low-latency playout (b)',
  'pakhiMono': 'media, MIC, MONO, no low-latency, software AEC3 (a)',
  'pakhiTrials': 'field settings + AEC3 field trials (c)',
  'oldPakhi': 'media without bypass: VOICE_COMMUNICATION, mono, low-latency, platform AEC/NS (d)',
  'mediaVcSw': 'media without bypass, HW off: VOICE_COMMUNICATION, mono, low-latency, software AEC3',
  'nofx': 'media, MIC, stereo, all processing off (no-AEC reference)',
  'comm': 'SDK default communication profile (platform AEC reference)',
};

/// Initializes WebRTC for [variant] (must run before any room). [initialize]
/// is `rtc.WebRTC.initialize`; [mediaConfiguration] is
/// `rtc.AndroidAudioConfiguration.media.toMap()`.
Future<void> setupEchoVariant(
  String variant, {
  required Future<void> Function(Map<String, dynamic> options) initialize,
  required Map<String, dynamic> mediaConfiguration,
  String trials = '',
  String webrtcLog = '',
}) async {
  if (!kEchoVariants.containsKey(variant)) {
    await gravixLogLine(kEchoTag, 'variant=$variant UNKNOWN (known: ${kEchoVariants.keys.join(',')}); SDK defaults');
    return;
  }
  final log = <String, dynamic>{if (webrtcLog.isNotEmpty) 'logSeverity': webrtcLog};
  if (webrtcLog.isNotEmpty) _forwardWebRtcLog();
  // ignore: experimental_member_use
  const media = AudioSessionOptions.mediaPlayback();
  var tuning = const GravixMediaEchoTuning();
  switch (variant) {
    case 'pakhi' || 'pakhiLL' || 'pakhiTrials':
      await initialize({
        'androidAudioConfiguration': mediaConfiguration,
        'androidUseHardwareAudioProcessing': false,
        'bypassVoiceProcessing': true,
        ...log,
      });
      if (variant == 'pakhiLL') tuning = const GravixMediaEchoTuning(lowLatencyPlayout: true);
      if (variant == 'pakhiTrials') {
        tuning = GravixMediaEchoTuning(aec3FieldTrials: trials.isEmpty ? kDefaultEchoTrials : trials);
      }
    case 'pakhiMono':
      // Without bypass flutter_webrtc builds a mono module (VOICE_COMMUNICATION,
      // low-latency playout); the tuning moves it back to MIC / normal playout.
      await initialize({
        'androidAudioConfiguration': mediaConfiguration,
        'androidUseHardwareAudioProcessing': false,
        ...log,
      });
      tuning = const GravixMediaEchoTuning(captureSource: GravixCaptureAudioSource.mic, lowLatencyPlayout: false);
    case 'oldPakhi':
      await initialize({'androidAudioConfiguration': mediaConfiguration, ...log});
    case 'mediaVcSw':
      await initialize({
        'androidAudioConfiguration': mediaConfiguration,
        'androidUseHardwareAudioProcessing': false,
        ...log,
      });
    case 'nofx':
      // = GravixRtcClient.initialize(bypassVoiceProcessing: true, media), the
      // AUDIO-LEAK no-processing reference; the explicit call only adds logSeverity.
      if (log.isNotEmpty) {
        await initialize({'androidAudioConfiguration': mediaConfiguration, 'bypassVoiceProcessing': true, ...log});
      }
      await GravixRtcClient.initialize(bypassVoiceProcessing: true, initialAudioSessionOptions: media);
    case 'comm':
      if (log.isNotEmpty) await initialize(log);
  }
  if (variant != 'nofx' && variant != 'comm') {
    await GravixRtcClient.initialize(initialAudioSessionOptions: media);
  }
  final report = await GravixMediaEcho.apply(tuning);
  await gravixLogLine(kEchoTag, 'variant=$variant (${kEchoVariants[variant]}) tuning=$tuning report=$report');
}

final _webrtcLogFilter = RegExp(
  r'AudioProcessing|AEC3|Aec3|ApplyOptions|audio processing|EchoCanceller|field trial|WebRtcAudioTrack|'
  r'WebRtcAudioRecord|initPlayout|initRecording|AudioTrack:|AudioRecord:|underrun|low.latency|buffer size|'
  r'audio source|BuiltInAEC|platform effect',
);

void _forwardWebRtcLog() {
  FlutterWebRTCEventChannel.instance.handleEvents.stream.listen((data) {
    final map = data.values.first;
    if (map is Map && map['event'] == 'onLogData') {
      final line = '${map['data']}';
      if (_webrtcLogFilter.hasMatch(line)) unawaited(gravixLogLine(kEchoTag, 'webrtc: ${line.trim()}'));
    }
  });
}

/// Every 2 s while a room holds: the published microphone's echo statistics
/// (libwebrtc's APM: echoReturnLoss = how much quieter the echo is than the
/// render reference at the microphone; echoReturnLossEnhancement = what AEC3's
/// linear filter removes; null when the software AEC is not running), its
/// level, and once the engine's audio processing state. One logcat line each.
class EchoDiagnostics {
  EchoDiagnostics(this._room);
  final Room? Function() _room;
  Timer? _timer;
  bool _stateLogged = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final room = _room();
    final pub = room?.localParticipant?.audioTrackPublications.firstOrNull;
    final track = pub?.track;
    if (track == null) return;
    if (!_stateLogged) {
      _stateLogged = true;
      // ignore: experimental_member_use
      final state = await AudioManager.instance.getAudioProcessingState();
      // ignore: experimental_member_use
      String c(AudioProcessingComponentState x) =>
          '${x.effective.name}(sw=${x.isSoftwareActive} hwAvail=${x.isPlatformAvailable} hw=${x.isPlatformActive})';
      await gravixLogLine(
        kEchoTag,
        state == null
            ? 'processingState=unavailable'
            : 'processingState aec=${c(state.echoCancellation)} ns=${c(state.noiseSuppression)} '
                  'agc=${c(state.autoGainControl)} hpf=${c(state.highPassFilter)}',
      );
    }
    final stats = await track.getSenderStats();
    final s = stats?.audioSourceStats;
    if (s == null) return;
    await gravixLogLine(
      kEchoTag,
      'stats t=${DateTime.now().millisecondsSinceEpoch} erl=${s.echoReturnLoss} erle=${s.echoReturnLossEnhancement} '
      'level=${s.audioLevel} energy=${s.totalAudioEnergy} dur=${s.totalSamplesDuration}',
    );
  }
}
