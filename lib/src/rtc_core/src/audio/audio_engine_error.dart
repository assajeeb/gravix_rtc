// Copyright 2026 LiveKit, Inc.
// Modifications Copyright 2026 Gravity Compile
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

// GRAVIX 0.4.15: ported from the upstream client SDK 2.12.0
// (lib/src/audio/audio_engine_error.dart). The native side already answers
// with these codes (GravixClientPlugin.swift, flutterError(forAudioEngineResult:)),
// so only the Dart mapping was missing.

import 'package:flutter/services.dart' show PlatformException;

import 'package:meta/meta.dart';

import '../exceptions.dart' show AudioSessionException, GravixRtcException, TrackCreateException;

/// Error codes the native plugin uses for audio device module failures with a
/// known cause. Anything else keeps the caller-specific fallback code.
@internal
const String audioEngineErrorCodeDeviceAccessDenied = 'deviceAccessDenied';
@internal
const String audioEngineErrorCodeAudioSessionInvalidCategory = 'audioSessionInvalidCategory';
@internal
const String audioEngineErrorCodeAudioSessionConfigureFailed = 'audioSessionConfigureFailed';

/// Maps a [PlatformException] from an audio device module call to the
/// [GravixRtcException] describing its cause, or `null` when the code is not
/// one of the known audio engine failures and the caller should apply its own
/// mapping.
@internal
GravixRtcException? audioEngineExceptionFrom(PlatformException error) {
  final native = error.message?.trim() ?? '';
  String message(String fallback) => native.isEmpty ? fallback : native;
  switch (error.code) {
    case audioEngineErrorCodeDeviceAccessDenied:
      return TrackCreateException(message('Microphone permission is not granted'));
    case audioEngineErrorCodeAudioSessionInvalidCategory:
      return AudioSessionException(message('Audio session category does not support recording'));
    case audioEngineErrorCodeAudioSessionConfigureFailed:
      return AudioSessionException(message('Failed to configure the audio session'));
    default:
      return null;
  }
}
