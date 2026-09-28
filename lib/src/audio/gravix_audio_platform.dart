// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../rtc_core/gravix_client.dart' show AudioManager, AudioSessionManagementMode, AudioSessionOptions;
import '../rtc_core/src/support/native.dart' show Native;

/// Android `AudioManager.MODE_*`, as a plain enum.
///
/// The reference reads `audio_session`'s `AndroidAudioHardwareMode` directly.
/// This SDK maps it to its own enum here so that all version-sensitive plugin
/// surface lives in this file and nowhere else in the routing stack — which is
/// what makes the 0.1.25 → 0.2.4 upgrade a one-line change (see
/// `doc/AUDIO_SESSION_MIGRATION.md`).
///
/// An earlier version of this comment said `AndroidAudioHardwareMode` is a
/// const-class in 0.1.25 and an enum in 0.2.4. That is not true — it is a
/// const-class in both, verified against the pub cache for each version. The
/// mapping is still worth keeping for the reason above, but it is insulation,
/// not a workaround for a shape change that never happened.
enum GravixAudioHardwareMode {
  normal,
  ringtone,
  inCall,
  inCommunication,
  invalid,
  unknown;

  /// Uppercase name as it appears in Android's own logs and in the route log.
  String get label => switch (this) {
    GravixAudioHardwareMode.normal => 'NORMAL',
    GravixAudioHardwareMode.ringtone => 'RINGTONE',
    GravixAudioHardwareMode.inCall => 'IN_CALL',
    GravixAudioHardwareMode.inCommunication => 'IN_COMMUNICATION',
    GravixAudioHardwareMode.invalid => 'INVALID',
    GravixAudioHardwareMode.unknown => 'UNKNOWN',
  };
}

/// An explicit, user-chosen audio output.
///
/// This is **not** a ranking. [GravixAudioPlatform.setDirectAudioOutput] sets
/// the device itself, so nothing about this enum can resurrect the sticky
/// preferred-device list that §1 of the internal audio-routing design notes is
/// about. See [GravixAudioRouteManager.setAudioOutput].
enum GravixAudioOutput {
  /// The built-in loudspeaker. The default, and the only output v2 selects on
  /// its own.
  speaker,

  /// The built-in earpiece / receiver — the top-of-handset speaker you hold to
  /// your ear. Only ever selected because the app asked for it.
  earpiece;

  /// Uppercase name as it appears in the route log.
  String get label => switch (this) {
    GravixAudioOutput.speaker => 'SPEAKER',
    GravixAudioOutput.earpiece => 'EARPIECE',
  };
}

/// A snapshot of the device fingerprint the routing stack reasons about.
@immutable
class GravixAudioDeviceSnapshot {
  const GravixAudioDeviceSnapshot({
    this.hasBluetoothSco = false,
    this.hasBluetoothA2dp = false,
    this.hasExternalOutput = false,
  });

  /// A Bluetooth telephony (HFP/SCO) output is present.
  final bool hasBluetoothSco;

  /// A Bluetooth media (A2DP) output is present.
  final bool hasBluetoothA2dp;

  /// Any non-handset output is present: BT, wired, USB, hearing aid, car, dock.
  final bool hasExternalOutput;
}

/// Everything the v2 routing stack needs from the platform.
///
/// Extracted so the routing logic — which is where the ported bug fixes live —
/// can be unit-tested without a device or a method channel. Production code
/// uses [GravixNativeAudioPlatform]; tests supply a fake.
abstract interface class GravixAudioPlatform {
  /// The routing stack's Android-only branches key off this rather than
  /// `defaultTargetPlatform`, so a test can exercise them.
  bool get isAndroid;

  /// Current Android audio mode. Non-Android returns
  /// [GravixAudioHardwareMode.unknown].
  Future<GravixAudioHardwareMode> getMode();

  /// `AudioManager.isBluetoothScoOn()`.
  Future<bool> isBluetoothScoOn();

  /// Type name of the API 31+ communication device, or null when unset or
  /// unsupported.
  Future<String?> getCommunicationDeviceType();

  /// Output devices only. An input-side device says nothing about where sound
  /// should come out.
  Future<GravixAudioDeviceSnapshot> getOutputs();

  /// The single lever for automatic routing: select the preferred-device
  /// ranking. v2 only ever passes `true` — see [GravixAudioRouteManager.apply].
  Future<void> setSpeakerOutputPreferred(bool preferred, {bool force});

  /// Set the output device **directly**, bypassing the preferred-device
  /// ranking entirely.
  ///
  /// Returns true when the platform actually applied it. False means the
  /// device or OS version has no direct-selection API and the caller should
  /// leave the automatic route alone, not retry.
  ///
  /// Separate from [setSpeakerOutputPreferred] on purpose: a ranking that puts
  /// the earpiece above the loudspeaker is sticky and outlives the headset
  /// that justified it (§1 of the internal audio-routing design notes). Setting a
  /// device is not sticky in that way — it is re-asserted verbatim on every
  /// event, and one call to [GravixAudioOutput.speaker] undoes it.
  Future<bool> setDirectAudioOutput(GravixAudioOutput output);

  /// Hand session lifetime to the app (RTC core `manual` mode).
  Future<void> claimManualSessionManagement();

  /// Configure + activate the communication session.
  Future<void> startCommunicationSession();

  /// Release focus and restore the previous audio mode.
  Future<void> stopCommunicationSession();

  /// Devices added/removed. Payload is a short human-readable description.
  Stream<String> get devicesChanged;

  /// Wired/BT output yanked.
  Stream<void> get becomingNoisy;
}

/// Production [GravixAudioPlatform]: `audio_session` for observation,
/// the RTC core's [AudioManager] for control.
class GravixNativeAudioPlatform implements GravixAudioPlatform {
  GravixNativeAudioPlatform();

  /// One long-lived [AndroidAudioManager] for the life of the process.
  ///
  /// Deliberately never closed: `close()` tears down plugin state shared with
  /// every other reader, and the routing stack polls this several times a
  /// second while a foreign call is suspected.
  AndroidAudioManager? _am;
  AndroidAudioManager get _audio => _am ??= AndroidAudioManager();

  @override
  bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<GravixAudioHardwareMode> getMode() async {
    if (!isAndroid) return GravixAudioHardwareMode.unknown;
    final mode = await _audio.getMode();
    if (mode == AndroidAudioHardwareMode.normal) return GravixAudioHardwareMode.normal;
    if (mode == AndroidAudioHardwareMode.ringtone) return GravixAudioHardwareMode.ringtone;
    if (mode == AndroidAudioHardwareMode.inCall) return GravixAudioHardwareMode.inCall;
    if (mode == AndroidAudioHardwareMode.inCommunication) return GravixAudioHardwareMode.inCommunication;
    if (mode == AndroidAudioHardwareMode.invalid) return GravixAudioHardwareMode.invalid;
    return GravixAudioHardwareMode.unknown;
  }

  @override
  Future<bool> isBluetoothScoOn() async {
    if (!isAndroid) return false;
    try {
      return await _audio.isBluetoothScoOn();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> getCommunicationDeviceType() async {
    if (!isAndroid) return null;
    try {
      // setCommunicationDevice / getCommunicationDevice landed in API 31.
      // Older devices throw, and that is not an error worth reporting — the
      // concept simply does not exist there.
      final device = await _audio.getCommunicationDevice();
      return device.type.name;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<GravixAudioDeviceSnapshot> getOutputs() async {
    try {
      final session = await AudioSession.instance;
      final devices = await session.getDevices(includeInputs: false);
      var sco = false;
      var a2dp = false;
      var external = false;
      for (final d in devices) {
        switch (d.type) {
          case AudioDeviceType.bluetoothSco:
            sco = true;
            external = true;
          case AudioDeviceType.bluetoothA2dp:
            a2dp = true;
            external = true;
          case AudioDeviceType.bluetoothLe:
          case AudioDeviceType.wiredHeadset:
          case AudioDeviceType.wiredHeadphones:
          case AudioDeviceType.usbAudio:
          case AudioDeviceType.hearingAid:
          case AudioDeviceType.carAudio:
          case AudioDeviceType.dock:
            external = true;
          default:
            break;
        }
      }
      return GravixAudioDeviceSnapshot(hasBluetoothSco: sco, hasBluetoothA2dp: a2dp, hasExternalOutput: external);
    } catch (e) {
      debugPrint('device enumeration failed: $e');
      return const GravixAudioDeviceSnapshot();
    }
  }

  @override
  Future<void> setSpeakerOutputPreferred(bool preferred, {bool force = false}) =>
      AudioManager.instance.setSpeakerOutputPreferred(preferred, force: force);

  @override
  Future<bool> setDirectAudioOutput(GravixAudioOutput output) async {
    if (!isAndroid) {
      // iOS. Two steps:
      //  1. Keep the RTC core's cached Apple session policy in step (mode
      //     videoChat vs voiceChat, forced speaker), so the next audio-engine
      //     lifecycle re-apply lands on the same output instead of undoing it.
      //     An explicit loudspeaker is forced, like Android's named-device
      //     selection, which also wins over a connected headset.
      //  2. Ask the native plugin to route NOW (overrideOutputAudioPort /
      //     receiver) and report what the route actually became.
      // Until 0.3.x this returned true after step 1 alone, although nothing
      // native answered the call: the speaker/earpiece toggle was a silent
      // no-op that claimed success.
      final speaker = output == GravixAudioOutput.speaker;
      try {
        await AudioManager.instance.setSpeakerOutputPreferred(speaker, force: speaker);
        final result = await Native.setAppleAudioOutput(speaker: speaker);
        if (!result.applied && !result.deferred) {
          debugPrint('setDirectAudioOutput($output) declined: $result');
        }
        // Deferred = no call session yet; the cached policy applies it when the
        // engine starts, so the selection holds (not a "leave it alone").
        return result.applied || result.deferred;
      } catch (e) {
        debugPrint('setDirectAudioOutput($output) failed: $e');
        return false;
      }
    }

    // API 31+: name the device. This is the only Android API that selects an
    // output rather than ordering a list of them.
    final wanted = switch (output) {
      GravixAudioOutput.speaker => AndroidAudioDeviceType.builtInSpeaker,
      GravixAudioOutput.earpiece => AndroidAudioDeviceType.builtInEarpiece,
    };
    try {
      final available = await _audio.getAvailableCommunicationDevices();
      for (final device in available) {
        if (device.type == wanted) {
          return await _audio.setCommunicationDevice(device);
        }
      }
      // API 31+ but the handset has no such output (a tablet with no
      // earpiece). Not an error, and not something a legacy fallback fixes.
      if (available.isNotEmpty) {
        debugPrint('setDirectAudioOutput($output): no ${wanted.name} among ${available.map((d) => d.type.name)}');
        return false;
      }
    } catch (_) {
      // Pre-31: getAvailableCommunicationDevices / setCommunicationDevice do
      // not exist and throw. Fall through to the legacy write.
    }

    // Pre-31 fallback. `AudioManager.setSpeakerphoneOn` is a direct write to
    // the platform AudioManager — it is NOT the RTC core's
    // setSpeakerOutputPreferred, which is the audioswitch ranking. Below API 31
    // "not the speaker" is the earpiece whenever no headset is attached, which
    // is what an explicit earpiece request means on those handsets.
    try {
      await _audio.setSpeakerphoneOn(output == GravixAudioOutput.speaker);
      return true;
    } catch (e) {
      debugPrint('setDirectAudioOutput($output) failed: $e');
      return false;
    }
  }

  @override
  Future<void> claimManualSessionManagement() =>
      AudioManager.instance.setAudioSessionManagementMode(AudioSessionManagementMode.manual);

  @override
  Future<void> startCommunicationSession() =>
      AudioManager.instance.setAudioSessionOptions(const AudioSessionOptions.communication());

  @override
  Future<void> stopCommunicationSession() => AudioManager.instance.deactivateAudioSession();

  @override
  Stream<String> get devicesChanged async* {
    final session = await AudioSession.instance;
    yield* session.devicesChangedEventStream.map(
      (e) =>
          '+${e.devicesAdded.map((d) => d.type.name).join(',')} '
          '-${e.devicesRemoved.map((d) => d.type.name).join(',')}',
    );
  }

  @override
  Stream<void> get becomingNoisy async* {
    final session = await AudioSession.instance;
    yield* session.becomingNoisyEventStream;
  }
}
