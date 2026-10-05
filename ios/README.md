# gravix_rtc iOS

Registered class: `GravixCloudPlugin` (pubspec `pluginClass`). It registers:

| Channel | Implementation | What it does |
|---|---|---|
| `gravix_client` | `Sources/gravix_rtc/rtc/GravixClientPlugin.swift` | Audio session (engine-driven `RTCAudioSession` configuration and activation), speaker/receiver/Bluetooth routing, route-change reporting, CallKit engine gating and microphone mute modes, explicit recording start with audio-processing options, audio processing state, visualizer + PCM renderer event channels, `osVersionString`, broadcast picker + state |
| `com.gravitycompile.gravix_rtc/music` | `Sources/gravix_rtc/music/GravixMusicMixer.swift` | Background music mixed into the outgoing microphone signal |
| `gravix_cloud` | `GravixCloudPlugin.swift` | `getPlatformVersion` |

`ios/BroadcastExtension/` is a template for the app's screen-share Broadcast
Upload Extension; it is not part of the plugin build. See its README.

## Build integration

- **Swift Package Manager** (`gravix_rtc/Package.swift`): depends on the
  flutter_webrtc plugin package for its `flutter-webrtc` and `WebRTC`
  products. The dependency path is `../flutter_webrtc-1.6.0`, the name the
  Flutter tool gives flutter_webrtc's package symlink; it must match the exact
  flutter_webrtc version pinned in `pubspec.yaml`. Do not write it as the bare
  package name: the Flutter tool would then copy this whole package root into
  every app's build directory (see the comment in `Package.swift`). A
  `dependency_overrides` on flutter_webrtc needs the path updated too.
- **CocoaPods** (`gravix_rtc.podspec`): depends on `flutter_webrtc` and
  `WebRTC-SDK 144.7559.09` (the version flutter_webrtc 1.6.0 uses), static
  framework.
- Opening `ios/gravix_rtc` directly in Xcode does not resolve (the sibling
  flutter_webrtc package only exists inside an app's generated packages).
  That is also why `example/ios` no longer carries a folder reference to it.

## How the audio session works

flutter_webrtc 1.6.0 exposes two hooks for exactly this plugin:
`FlutterWebRTCPlugin.setAudioSessionManagementEnabled(false)` (it stops
touching the session) and `setAudioDeviceModuleObserver(_:)` (engine lifecycle
callbacks). The engine observer configures and activates the session when the
WebRTC audio engine enables playout or recording and deactivates it when both
stop, using the policy the Dart `AudioManager` pushes (`configureNativeAudio`):
automatic, manual, or `externalCallSystem` (CallKit activates; the plugin only
configures).

## Verification status

- Compiles in `flutter build ios --no-codesign` for `example/` and the demo app.
- Channel contract (method names, arguments, result shapes, error codes) is
  covered by Dart tests with a mocked channel (`test/native/`).
- Needs a real device + signing to confirm: speaker/receiver/Bluetooth
  switching, CallKit activation, background audio, the broadcast extension, and
  the music mixer's input-mixer path. The simulator cannot broadcast and has
  no receiver.
