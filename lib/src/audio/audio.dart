// Copyright 2024 Gravity Compile
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

/// v2 audio-routing stack. Opt in with `GravixAudioRouting.v2 = true`.
library;

export 'gravix_android_audio_session_guard.dart';
export 'gravix_android_audio_session_owner.dart';
export 'gravix_audio_host.dart';
export 'gravix_audio_platform.dart'
    show
        GravixAudioPlatform,
        GravixAudioHardwareMode,
        GravixAudioOutput,
        GravixAudioDeviceSnapshot,
        GravixNativeAudioPlatform;
export 'gravix_audio_route_log.dart';
export 'gravix_early_call_audio.dart';
export 'gravix_audio_route_manager.dart';
export 'gravix_audio_routing.dart';
export 'gravix_foreign_call_detector.dart';
