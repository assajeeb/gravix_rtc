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

import 'package:flutter/services.dart' show MethodChannel, MethodCall, MissingPluginException, PlatformException;

import 'package:meta/meta.dart';

import '../audio/audio_manager.dart';
import '../logger.dart';
import '../managers/broadcast_manager.dart';
import 'native_audio.dart';
import '../../../noise/gravix_noise_native.dart' show GravixNoiseNative, gravixNsNormalizeIosEvent;

// Method channel methods to call native code.
class Native {
  @internal
  static final channel = _createChannel();

  static MethodChannel _createChannel() {
    final channel = MethodChannel('gravix_client');
    channel.setMethodCallHandler(_handleMethodCall);
    return channel;
  }

  @internal
  static bool bypassVoiceProcessing = false;

  static final StreamController<AppleAudioRouteChange> _appleAudioRouteChanges =
      StreamController<AppleAudioRouteChange>.broadcast();

  /// iOS audio route changes reported by the native plugin
  /// (`onAudioRouteChanged`). Informational: device-level routing decisions
  /// stay with the audio routing stack, which observes devices itself.
  @internal
  static Stream<AppleAudioRouteChange> get appleAudioRouteChanges => _appleAudioRouteChanges.stream;

  /// Configures (and caches) the Apple audio session.
  ///
  /// When [automatic] is true, the native audio-engine delegate owns activation
  /// timing: the configuration is cached and (re)applied on engine lifecycle
  /// events, and only applied immediately here if the engine is already
  /// running. When false (manual mode / explicit apply) it is applied
  /// immediately.
  @internal
  static Future<bool> configureAudio(
    NativeAudioConfiguration configuration, {
    bool automatic = false,
    bool selectCategoryByEngineState = false,
    bool forceSpeakerOutput = false,
  }) async {
    try {
      final result = await channel.invokeMethod<bool>('configureNativeAudio', <String, dynamic>{
        ...configuration.toMap(),
        'automatic': automatic,
        'selectCategoryByEngineState': selectCategoryByEngineState,
        'forceSpeakerOutput': forceSpeakerOutput,
      });
      return result == true;
    } catch (error) {
      logger.warning('configureNativeAudio did throw $error');
      return false;
    }
  }

  /// Applies runtime audio processing options to a local audio track.
  ///
  /// Resolved natively against the underlying WebRTC audio track owned by
  /// flutter_webrtc; [options] is the serialized [AudioProcessingOptions] map.
  /// Returns the native result map (`result`/`code`/`message`) so the Dart
  /// track API can translate native outcomes into typed exceptions.
  /// This plugin is registered on platforms that do not implement runtime audio
  /// processing, so missing or explicitly unimplemented hooks are normalized to
  /// `rejectedPlatformUnavailable`. Other channel errors propagate because they
  /// indicate unexpected native failures rather than an unsupported platform
  /// capability.
  @internal
  static Future<Map<String, dynamic>> setAudioProcessingOptions(String trackId, Map<String, dynamic> options) async {
    try {
      final response = await channel.invokeMethod<dynamic>('setAudioProcessingOptions', <String, dynamic>{
        'trackId': trackId,
        ...options,
      });
      if (response is Map) {
        return response.map((key, value) => MapEntry(key.toString(), value));
      }
      return <String, dynamic>{};
    } on MissingPluginException {
      return _audioProcessingPlatformUnavailable();
    } on PlatformException catch (error) {
      // Web registers the plugin but returns `Unimplemented` for methods it
      // does not support. Treat only that narrow case like a missing native
      // implementation; do not hide unrelated native/channel failures.
      if (error.code == 'Unimplemented') {
        return _audioProcessingPlatformUnavailable();
      }
      rethrow;
    }
  }

  static Map<String, dynamic> _audioProcessingPlatformUnavailable() => <String, dynamic>{
    'result': false,
    'code': 'rejectedPlatformUnavailable',
    'message': 'Audio processing options are unavailable on this platform.',
  };

  static PlatformException _audioProcessingPlatformUnavailableException() => PlatformException(
    code: 'rejectedPlatformUnavailable',
    message: 'Audio processing options are unavailable on this platform.',
  );

  /// Starts the native WebRTC audio device module recording path with the
  /// capture-time audio processing options for the local microphone track.
  @internal
  static Future<void> startLocalRecording(Map<String, dynamic> audioProcessingOptions) async {
    try {
      await channel.invokeMethod<void>('startLocalRecording', audioProcessingOptions);
    } on PlatformException catch (error) {
      if (error.code == 'Unimplemented') {
        throw _audioProcessingPlatformUnavailableException();
      }
      rethrow;
    } on MissingPluginException {
      throw _audioProcessingPlatformUnavailableException();
    }
  }

  /// Mutes / unmutes the microphone inside the audio device module (Android),
  /// with the recorder left running: the captured PCM is zeroed on the record
  /// thread and the music mixer is held. True only when the native side
  /// confirmed it; false when the platform has no such method.
  @internal
  static Future<bool> setMicrophoneMute(bool mute) async {
    try {
      final ok = await channel.invokeMethod<bool>('setMicrophoneMute', <String, dynamic>{'mute': mute});
      return ok == true;
    } on PlatformException catch (error) {
      logger.warning('setMicrophoneMute($mute) did throw ${error.code}: ${error.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Stops recording that was explicitly started through [startLocalRecording].
  @internal
  static Future<void> stopLocalRecording() async {
    try {
      await channel.invokeMethod<void>('stopLocalRecording', <String, dynamic>{});
    } on PlatformException catch (error) {
      if (error.code == 'Unimplemented') {
        logger.warning('stopLocalRecording is not implemented on this platform');
        return;
      }
      logger.warning('stopLocalRecording did throw ${error.code}: ${error.message}');
    } on MissingPluginException {
      logger.warning('stopLocalRecording is not available on this platform');
    }
  }

  /// Reads the engine-wide audio processing state from the native peer
  /// connection factory. Returns `null` when unavailable (e.g. the factory
  /// does not exist yet, or the platform cannot provide it).
  @internal
  static Future<Map<String, dynamic>?> getAudioProcessingState() async {
    try {
      final response = await channel.invokeMethod<dynamic>('getAudioProcessingState', <String, dynamic>{});
      if (response is Map) {
        return response.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (error) {
      logger.warning('getAudioProcessingState did throw $error');
    }
    return null;
  }

  /// 2026-10-10 ECHO: media-profile echo experiments on WebRTC's audio device
  /// module (GravixMediaEcho.apply). Throws PlatformException when WebRTC is
  /// not initialized; returns the per-setting report.
  @internal
  static Future<Map<String, Object?>> applyMediaEchoTuning(Map<String, Object?> args) async {
    final reply = await channel.invokeMethod<dynamic>('applyMediaEchoTuning', args);
    return reply is Map ? reply.map((k, v) => MapEntry(k.toString(), v)) : const <String, Object?>{};
  }

  /// Configure and activate GravixRtc's Android audio session (mode/focus/routing).
  @internal
  static Future<void> configureAndroidAudioSession(Map<String, dynamic> configuration) async {
    try {
      await channel.invokeMethod<void>('configureAndroidAudioSession', configuration);
    } catch (error) {
      logger.warning('configureAndroidAudioSession did throw $error');
    }
  }

  /// Deactivate GravixRtc's Android audio session (release focus, restore mode).
  @internal
  static Future<void> stopAndroidAudioSession() async {
    try {
      await channel.invokeMethod<void>('stopAndroidAudioSession');
    } catch (error) {
      logger.warning('stopAndroidAudioSession did throw $error');
    }
  }

  /// Deactivate GravixRtc's Apple audio session.
  @internal
  static Future<void> deactivateAppleAudioSession() async {
    try {
      await channel.invokeMethod<void>('deactivateAppleAudioSession', <String, dynamic>{});
    } catch (error) {
      logger.warning('deactivateAppleAudioSession did throw $error');
    }
  }

  /// Route Android audio output to/from the speakerphone.
  @internal
  static Future<void> setAndroidSpeakerphoneOn(bool enable, {bool force = false}) async {
    try {
      await channel.invokeMethod<void>('setAndroidSpeakerphoneOn', <String, dynamic>{'enable': enable, 'force': force});
    } catch (error) {
      logger.warning('setAndroidSpeakerphoneOn did throw $error');
    }
  }

  /// Enable or disable GravixRtc's automatic iOS audio-session management from
  /// native WebRTC audio-engine lifecycle callbacks.
  ///
  /// [sessionActivationEnabled] controls whether GravixRtc may activate or
  /// deactivate the session at all. When false, GravixRtc only configures the
  /// category/mode and an external system (CallKit) owns activation timing.
  @internal
  static Future<void> setAppleAudioSessionAutomaticManagementEnabled(
    bool enabled, {
    bool sessionActivationEnabled = true,
  }) async {
    try {
      await channel.invokeMethod<void>('setAppleAudioSessionAutomaticManagementEnabled', <String, dynamic>{
        'enabled': enabled,
        'sessionActivationEnabled': sessionActivationEnabled,
      });
    } catch (error) {
      logger.warning('setAppleAudioSessionAutomaticManagementEnabled did throw $error');
    }
  }

  /// Sets how the audio device module mutes microphone input (iOS/macOS).
  ///
  /// Unlike most methods in this class this deliberately does not swallow
  /// platform errors: a failed change means muting behaves differently from
  /// what the caller selected, so the error must reach the caller.
  @internal
  static Future<void> setMicrophoneMuteMode(String mode) async {
    await channel.invokeMethod<void>('setMicrophoneMuteMode', <String, dynamic>{'mode': mode});
  }

  /// Reads the audio device module's microphone mute mode (iOS/macOS).
  /// Returns null when the native side cannot provide it.
  @internal
  static Future<String?> getMicrophoneMuteMode() async {
    try {
      return await channel.invokeMethod<String>('getMicrophoneMuteMode', <String, dynamic>{});
    } catch (error) {
      logger.warning('getMicrophoneMuteMode did throw $error');
      return null;
    }
  }

  /// Sets whether the WebRTC audio engine is allowed to run (iOS/macOS).
  ///
  /// Unlike most methods in this class this deliberately does not swallow
  /// platform errors: a failed availability change means the engine may run
  /// outside the window the caller intended (e.g. CallKit's
  /// didActivate/didDeactivate), so the error must reach the caller.
  @internal
  static Future<void> setEngineAvailability({required bool isInputAvailable, required bool isOutputAvailable}) async {
    await channel.invokeMethod<void>('setEngineAvailability', <String, dynamic>{
      'isInputAvailable': isInputAvailable,
      'isOutputAvailable': isOutputAvailable,
    });
  }

  /// Requests microphone permission before audio capture starts (iOS/macOS).
  ///
  /// GRAVIX 0.4.15 (ported from the upstream client SDK 2.12.0; the native
  /// handler was already in GravixClientPlugin.swift, nothing called it): the
  /// WebRTC audio device only checks the permission and fails when it is
  /// missing, so the SDK requests it here. On iOS the prompt is only shown
  /// while the app is active. Throws a [PlatformException] with code
  /// `deviceAccessDenied` when permission is denied, restricted, or could not
  /// be requested. A no-op where the platform does not implement it, or while
  /// the engine's input availability is disabled via [setEngineAvailability].
  @internal
  static Future<void> ensureMicrophoneAccess() async {
    try {
      await channel.invokeMethod<void>('ensureMicrophoneAccess', <String, dynamic>{});
    } on PlatformException catch (error) {
      if (error.code == 'Unimplemented') return;
      rethrow;
    } on MissingPluginException {
      return;
    }
  }

  /// Selects the iOS output directly: the loudspeaker when [speaker] is true,
  /// the receiver (earpiece) otherwise.
  ///
  /// Returns what the native side actually did. [AppleAudioOutputResult.applied]
  /// is true only when the live route matches the request;
  /// [AppleAudioOutputResult.deferred] means no call session exists yet and the
  /// selection is cached for when the audio engine starts. Platform errors
  /// propagate: a failed override must not look like a successful one.
  @internal
  static Future<AppleAudioOutputResult> setAppleAudioOutput({required bool speaker}) async {
    final response = await channel.invokeMethod<dynamic>('setAppleAudioOutput', <String, dynamic>{'speaker': speaker});
    if (response is! Map) {
      throw PlatformException(code: 'setAppleAudioOutput', message: 'unexpected native response: $response');
    }
    return AppleAudioOutputResult(
      applied: response['applied'] == true,
      deferred: response['deferred'] == true,
      route: response['route'] as String?,
      reason: response['reason'] as String?,
    );
  }

  /// Starts the Android MediaProjection foreground service and completes once
  /// it is actually in the foreground. Throws [PlatformException] when Android
  /// refuses it (for example consent was not obtained first on API 34+).
  @internal
  static Future<void> startScreenCaptureService({String? notificationTitle, String? notificationText}) async {
    await channel.invokeMethod<dynamic>('startScreenCaptureService', <String, dynamic>{
      'notificationTitle': ?notificationTitle,
      'notificationText': ?notificationText,
    });
  }

  static final StreamController<Map<String, Object?>> _micSignals = StreamController<Map<String, Object?>>.broadcast();

  /// Raw microphone signals from the native mic monitor (0.4.15): Android
  /// `recording`, `silenced`, `focus`, `phoneCall`, `sdkInt`; iOS
  /// `sessionInterrupted`. Read by GravixMicMonitor.
  @internal
  static Stream<Map<String, Object?>> get micSignals => _micSignals.stream;

  static final StreamController<Map<String, Object?>> _otherAppAudio =
      StreamController<Map<String, Object?>>.broadcast();

  /// Android other-app audio watcher events (2026-10-10): `playing` (bool,
  /// debounced), `players` (int). Read by GravixMicMonitor.
  @internal
  static Stream<Map<String, Object?>> get otherAppAudioEvents => _otherAppAudio.stream;

  /// Starts the Android other-app audio watcher (playback activity callback on
  /// its own thread). Events arrive as `onOtherAppAudio`. Never throws.
  @internal
  static Future<void> startOtherAppAudioMonitor() async {
    try {
      await channel.invokeMethod<void>('startOtherAppAudioMonitor', <String, dynamic>{});
    } catch (error) {
      logger.fine('startOtherAppAudioMonitor: $error');
    }
  }

  /// Stops the watcher. Never throws.
  @internal
  static Future<void> stopOtherAppAudioMonitor() async {
    try {
      await channel.invokeMethod<void>('stopOtherAppAudioMonitor', <String, dynamic>{});
    } catch (error) {
      logger.fine('stopOtherAppAudioMonitor: $error');
    }
  }

  /// Applies a capture action while another app plays: `none`,
  /// `platformEffects`, `voiceCommunication`, `mute`. Never throws.
  @internal
  static Future<void> setOtherAppCaptureAction(String action) async {
    try {
      await channel.invokeMethod<void>('setOtherAppCaptureAction', <String, dynamic>{'action': action});
    } catch (error) {
      logger.fine('setOtherAppCaptureAction($action): $error');
    }
  }

  /// Starts the native mic monitor; returns the first signals, or null.
  /// [recoverAfterInterruption] lets iOS re-activate the audio session after
  /// an interruption ends when WebRTC did not.
  @internal
  static Future<Map<String, Object?>?> startMicMonitor({required bool recoverAfterInterruption}) async {
    final reply = await channel.invokeMethod<dynamic>('startMicMonitor', <String, dynamic>{
      'recoverAfterInterruption': recoverAfterInterruption,
    });
    return reply is Map ? reply.cast<String, Object?>() : null;
  }

  /// Stops the native mic monitor. Never throws.
  @internal
  static Future<void> stopMicMonitor() async {
    try {
      await channel.invokeMethod<void>('stopMicMonitor', <String, dynamic>{});
    } catch (error) {
      logger.fine('stopMicMonitor: $error');
    }
  }

  /// Re-applies the platform audio session after an interruption (Android:
  /// deactivate + activate + route; iOS: re-activate if WebRTC did not).
  /// Never throws.
  @internal
  static Future<void> reassertAudioSession() async {
    try {
      await channel.invokeMethod<void>('reassertAudioSession', <String, dynamic>{});
    } catch (error) {
      logger.fine('reassertAudioSession: $error');
    }
  }

  static final StreamController<Map<String, Object?>> _noiseSuppression =
      StreamController<Map<String, Object?>>.broadcast();

  /// Noise-suppression processor events (switch, routeReset, musicBypass,
  /// watchdog, summary). Read by GravixNoiseSuppression.
  @internal
  static Stream<Map<String, Object?>> get noiseSuppressionEvents => _noiseSuppression.stream;

  /// A noise-suppression call on the gravix_client channel (`nsDeviceFacts`,
  /// `nsConfigure`, `nsStats`). Null when the platform has no implementation.
  @internal
  static Future<Map<String, dynamic>?> nsCall(String method, [Map<String, dynamic>? args]) async {
    try {
      final r = await channel.invokeMethod<dynamic>(method, args ?? const <String, dynamic>{});
      return r is Map ? r.map((k, v) => MapEntry(k.toString(), v)) : null;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      if (error.code == 'Unimplemented') return null;
      rethrow;
    }
  }

  static final StreamController<Map<String, Object?>> _audioRoutes = StreamController<Map<String, Object?>>.broadcast();

  /// Audio route changes from both platforms (0.4.15): `routes` (available
  /// route type names), `current`, `reason`. Read by GravixAudioDevice.
  @internal
  static Stream<Map<String, Object?>> get audioRouteEvents => _audioRoutes.stream;

  /// The available audio routes and the current one:
  /// `{routes: [speaker, earpiece, wiredHeadset, bluetooth, usb], current, mode}`.
  @internal
  static Future<Map<String, Object?>> getAudioRoutes() async {
    final reply = await channel.invokeMethod<dynamic>('getAudioRoutes', <String, dynamic>{});
    return reply is Map ? reply.cast<String, Object?>() : const <String, Object?>{};
  }

  /// Selects [route] (a route type name), or clears an explicit selection
  /// when null. Returns `{applied, reason?, current}`.
  @internal
  static Future<Map<String, Object?>> setAudioRoute(String? route) async {
    final reply = await channel.invokeMethod<dynamic>('setAudioRoute', <String, dynamic>{'route': route});
    return reply is Map ? reply.cast<String, Object?>() : const <String, Object?>{};
  }

  /// Android: the Bluetooth chatroom model (0.4.15, opt-in). [enabled] turns
  /// it on/off; [micActive] says whether the local microphone is published
  /// and unmuted. Never throws.
  @internal
  static Future<void> setBluetoothChatroom({required bool enabled, required bool micActive}) async {
    try {
      await channel.invokeMethod<void>('setBluetoothChatroom', <String, dynamic>{
        'enabled': enabled,
        'micActive': micActive,
      });
    } catch (error) {
      logger.fine('setBluetoothChatroom: $error');
    }
  }

  /// Android: starts/stops the silent background keep-alive player
  /// (GravixAudioDeviceOptions.backgroundKeepAlive, 0.4.15). Never throws.
  @internal
  static Future<void> setBackgroundKeepAlive({required bool active}) async {
    try {
      await channel.invokeMethod<void>('setBackgroundKeepAlive', <String, dynamic>{'active': active});
    } catch (error) {
      logger.fine('setBackgroundKeepAlive: $error');
    }
  }

  static final StreamController<String> _callServiceEvents = StreamController<String>.broadcast();

  /// Events from the Android call foreground service: `leave` (the
  /// notification's Leave action) and `stopped` (the service ended, for
  /// example swiped from Recents).
  @internal
  static Stream<String> get callServiceEvents => _callServiceEvents.stream;

  /// Starts the Android call foreground service (GravixCallService) and
  /// completes once it is in the foreground, with the applied types
  /// (`types` bit mask, `typeNames`). Throws [PlatformException]
  /// (`callServiceFailed`) when Android refuses it.
  @internal
  static Future<Map<String, Object?>> startCallService({
    String? notificationTitle,
    String? notificationText,
    bool showLeaveAction = false,
    String? leaveActionLabel,
    bool microphone = false,
    bool camera = false,
  }) async {
    final reply = await channel.invokeMethod<dynamic>('startCallService', <String, dynamic>{
      'notificationTitle': ?notificationTitle,
      'notificationText': ?notificationText,
      'showLeaveAction': showLeaveAction,
      'leaveActionLabel': ?leaveActionLabel,
      'microphone': microphone,
      'camera': camera,
    });
    return reply is Map ? reply.cast<String, Object?>() : const <String, Object?>{};
  }

  /// Re-applies the call service's types. The reply carries `error` when
  /// Android refused the new types (the service keeps its old ones).
  @internal
  static Future<Map<String, Object?>> updateCallService({bool? microphone, bool? camera}) async {
    final reply = await channel.invokeMethod<dynamic>('updateCallService', <String, dynamic>{
      'microphone': ?microphone,
      'camera': ?camera,
    });
    return reply is Map ? reply.cast<String, Object?>() : const <String, Object?>{};
  }

  /// Stops the call foreground service. Never throws.
  @internal
  static Future<void> stopCallService() async {
    try {
      await channel.invokeMethod<void>('stopCallService', <String, dynamic>{});
    } catch (error) {
      logger.warning('stopCallService did throw $error');
    }
  }

  /// Stops the Android MediaProjection foreground service. Never throws.
  @internal
  static Future<void> stopScreenCaptureService() async {
    try {
      await channel.invokeMethod<void>('stopScreenCaptureService', <String, dynamic>{});
    } catch (error) {
      logger.warning('stopScreenCaptureService did throw $error');
    }
  }

  @internal
  static Future<bool> startVisualizer(
    String trackId, {
    bool isCentered = true,
    int barCount = 7,
    String visualizerId = '',
    bool smoothTransition = true,
  }) async {
    try {
      final result = await channel.invokeMethod<bool>('startVisualizer', <String, dynamic>{
        'trackId': trackId,
        'isCentered': isCentered,
        'barCount': barCount,
        'visualizerId': visualizerId,
        'smoothTransition': smoothTransition,
      });
      return result == true;
    } catch (error) {
      logger.warning('startVisualizer did throw $error');
      return false;
    }
  }

  @internal
  static Future<void> stopVisualizer(String trackId, {required String visualizerId}) async {
    try {
      await channel.invokeMethod<void>('stopVisualizer', <String, dynamic>{
        'trackId': trackId,
        'visualizerId': visualizerId,
      });
    } catch (error) {
      logger.warning('stopVisualizer did throw $error');
    }
  }

  @internal
  static Future<bool> startAudioRenderer({
    required String trackId,
    required String rendererId,
    required Map<String, dynamic> format,
  }) async {
    try {
      final result = await channel.invokeMethod<bool>('startAudioRenderer', <String, dynamic>{
        'trackId': trackId,
        'rendererId': rendererId,
        'format': format,
      });
      return result == true;
    } catch (error) {
      logger.warning('startAudioRenderer did throw $error');
      return false;
    }
  }

  @internal
  static Future<void> stopAudioRenderer({required String rendererId}) async {
    try {
      await channel.invokeMethod<void>('stopAudioRenderer', <String, dynamic>{'rendererId': rendererId});
    } catch (error) {
      logger.warning('stopAudioRenderer did throw $error');
    }
  }

  /// Returns OS's version as a string
  /// Currently only for iOS, macOS
  @internal
  static Future<String?> osVersionString() async {
    try {
      return await channel.invokeMethod<String>('osVersionString', <String, dynamic>{});
    } catch (error) {
      logger.warning('appleOSVersionString did throw error: ${error}');
    }
    return null;
  }

  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'broadcastStateChanged':
        if (call.arguments is! bool) {
          logger.warning('broadcastStateChanged did not receive bool');
          return null;
        }
        _broadcastStateChanged(call.arguments as bool);
        return null;
      case 'onAudioRouteChanged':
        final args = call.arguments;
        if (args is Map) {
          final change = AppleAudioRouteChange(
            reason: args['reason'] as String? ?? 'unknown',
            outputs: args['outputs'] as String? ?? '',
            speakerReasserted: args['speakerReasserted'] == true,
          );
          logger.fine('audio route changed: $change');
          _appleAudioRouteChanges.add(change);
        }
        return null;
      case 'onAudioEngineState':
        final args = call.arguments;
        if (args is Map) {
          AudioManager.instance.handleAudioEngineState(
            isPlayoutEnabled: args['isPlayoutEnabled'] == true,
            isRecordingEnabled: args['isRecordingEnabled'] == true,
          );
        }
        return null;
      case 'onMicSignals':
        final args = call.arguments;
        if (args is Map) _micSignals.add(args.cast<String, Object?>());
        return null;
      case 'onOtherAppAudio':
        final args = call.arguments;
        if (args is Map) _otherAppAudio.add(args.cast<String, Object?>());
        return null;
      case 'onNoiseSuppression': // Android
        final args = call.arguments;
        if (args is Map) _noiseSuppression.add(args.cast<String, Object?>());
        return null;
      case 'onNsEvent': // iOS: same stream, normalized to the Android shape
        GravixNoiseNative.handleEvent(call.arguments);
        final args = call.arguments;
        if (args is Map) _noiseSuppression.add(gravixNsNormalizeIosEvent(args.cast<String, Object?>()));
        return null;
      case 'onAudioRoutesChanged':
        final args = call.arguments;
        if (args is Map) _audioRoutes.add(args.cast<String, Object?>());
        return null;
      case 'callServiceLeaveRequested':
        _callServiceEvents.add('leave');
        return null;
      case 'callServiceStopped':
        _callServiceEvents.add('stopped');
        return null;
      default:
        logger.warning('Method ${call.method} is not implemented.');
        return null;
    }
  }

  static void _broadcastStateChanged(bool isBroadcasting) {
    BroadcastManager().broadcastStateChanged(isBroadcasting);
  }

  /// Shows the iOS broadcast picker for the app's Broadcast Upload Extension.
  ///
  /// Throws [PlatformException] with code `broadcastExtensionNotConfigured`
  /// when the app's Info.plist does not name the extension
  /// (`RTCScreenSharingExtension`): nothing was shown, so screen sharing cannot
  /// start and the caller must know. Other failures are logged.
  @internal
  static Future<void> broadcastRequestActivation() async {
    try {
      await channel.invokeMethod('broadcastRequestActivation', <String, dynamic>{});
    } on PlatformException catch (error) {
      if (error.code == 'broadcastExtensionNotConfigured') rethrow;
      logger.warning('broadcastRequestActivation did throw error: ${error}');
    } catch (error) {
      logger.warning('broadcastRequestActivation did throw error: ${error}');
    }
  }

  @internal
  static Future<void> broadcastRequestStop() async {
    try {
      await channel.invokeMethod('broadcastRequestStop', <String, dynamic>{});
    } catch (error) {
      logger.warning('broadcastRequestStop did throw error: ${error}');
    }
  }
}

// Initialize the channel before first reference so method calls can be handled.
// ignore: unused_element
final _channelInitializer = Native.channel;

/// Outcome of [Native.setAppleAudioOutput].
@internal
class AppleAudioOutputResult {
  const AppleAudioOutputResult({required this.applied, required this.deferred, this.route, this.reason});

  /// The live route now matches the request.
  final bool applied;

  /// No call session yet: cached and applied when the audio engine starts.
  final bool deferred;

  /// Output port types after the change, comma-separated.
  final String? route;

  /// Why [applied] is false, when it is.
  final String? reason;

  @override
  String toString() => 'AppleAudioOutputResult(applied: $applied, deferred: $deferred, route: $route, reason: $reason)';
}

/// An iOS audio route change reported by the native plugin.
@internal
class AppleAudioRouteChange {
  const AppleAudioRouteChange({required this.reason, required this.outputs, required this.speakerReasserted});

  /// `AVAudioSession.RouteChangeReason` name, e.g. `newDeviceAvailable`.
  final String reason;

  /// Output port types after the change, comma-separated.
  final String outputs;

  /// The native side re-applied a forced loudspeaker the change had dropped.
  final bool speakerReasserted;

  @override
  String toString() =>
      'AppleAudioRouteChange(reason: $reason, outputs: $outputs, speakerReasserted: $speakerReasserted)';
}
