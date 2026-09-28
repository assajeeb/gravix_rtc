// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

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
