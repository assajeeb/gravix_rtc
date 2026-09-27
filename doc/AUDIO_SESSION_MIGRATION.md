# `audio_session` 0.1.25 → 0.2.4 — migration report

**Report only. Nothing in this repo was upgraded.** `pubspec.yaml` still reads
`audio_session: ^0.1.21` (resolving to 0.1.25) and `pubspec.lock` is unchanged.

## How this was measured

Not read off a changelog. A `dependency_overrides: audio_session: 0.2.4` was
added temporarily, `flutter pub get` / `flutter analyze` / `flutter test` were
run, the breakage was recorded, the one-line fix was applied to see what came
next, and then **`pubspec.yaml`, `pubspec.lock` and the source file were all
restored**. `git status` is clean of those three. The Dart-side API diff below
is a literal `diff` of `audio_session-0.1.25/lib` against
`audio_session-0.2.4/lib` in the pub cache.

## Result

**One compile error. One line. Inside the seam.**

```
error • The property 'type' can't be unconditionally accessed because the
        receiver can be 'null'.
      • lib/src/audio/gravix_audio_platform.dart:194:21
      • unchecked_use_of_nullable_value
```

`AndroidAudioManager.getCommunicationDevice()` changed return type:

```dart
// 0.1.25
Future<AndroidAudioDeviceInfo> getCommunicationDevice()
// 0.2.4
Future<AndroidAudioDeviceInfo?> getCommunicationDevice()
```

and `GravixNativeAudioPlatform.getCommunicationDeviceType` dereferences it. The
fix is `device?.type.name` — the method already returns `String?` and already
treats "no communication device" as a normal answer, so the null flows straight
out with no behaviour change and no call-site change.

With that one character applied: **0 analyze errors, 162/162 tests pass** under
0.2.4. Nothing else in the SDK needs touching.

## What the seam already absorbs

`GravixAudioPlatform` is the reason the blast radius is one line. Every use of
the `audio_session` package in the whole SDK is inside
`lib/src/audio/gravix_audio_platform.dart` and
`lib/src/room/gravix_room_service.dart`; the vendored RTC core does not import
the package at all (`lib/src/rtc_core/src/audio/audio_session.dart` is the RTC
core's own file of the same name, not this plugin).

Specifically, the seam absorbs:

| Change in 0.2.4 | Absorbed by |
| --- | --- |
| `getCommunicationDevice()` → nullable | the one line above — no caller sees it; `getCommunicationDeviceType()` already returns `String?` |
| `_decodeAudioDevice` → nullable, `getDevices` gains `.nonNulls` | internal to the package; `getOutputs()` already maps device types to three booleans |
| `AndroidAudioHardwareMode` | never crosses the seam — mapped to `GravixAudioHardwareMode` in `getMode()`, so the routing stack, the guard and the foreign-call detector never name the plugin's type |
| `AudioDeviceType` enum | never crosses the seam — collapsed into `GravixAudioDeviceSnapshot`'s three booleans |
| every `invokeMethod(name)` → `invokeMethod(name, <dynamic>[])` | internal to the package; no Dart API change |
| the whole Android plugin's Java → Kotlin rewrite (0.2.0) | no Dart API change |

And the routing logic is tested against `FakeAudioPlatform`, not the plugin, so
**the 162-test suite does not exercise `audio_session` at all** — it will stay
green through this upgrade whether or not the upgrade is correct on a device.
That is the seam working as designed, and it is also the limit of what these
tests can tell you. See "What the seam does not absorb".

## What the seam does NOT absorb

These are real and none of them are visible to `flutter analyze` or
`flutter test`.

1. **`audioAttributes` was silently ignored on Android in 0.1.x.** 0.2.3 fixed
   a typo in the plugin: the configuration key sent to the platform was
   `'audioAttribute'` (singular) and became `'audioAttributes'`. So every
   `AndroidAudioAttributes` this SDK sets in `_configureAudioSession` — usage,
   content type, flags — **has never reached Android** and starts taking effect
   on upgrade. This is the single biggest risk in the migration: it is not a
   break, it is previously-dead configuration coming alive, and it lands
   directly on the code path the v2 routing work is about. It needs a device
   pass, not a code review.
2. **iOS: `AUDIO_SESSION_MICROPHONE=0` by default (0.2.0, flagged breaking).**
   The podspec's microphone compilation flag defaults off, which strips the
   microphone-related session code unless the flag is set in the Podfile. An
   SDK that publishes a mic needs this verified on a real iOS build; it cannot
   fail in a unit test.
3. **Minimum versions.** 0.2.0 requires Flutter ≥ 3.27.0 / Dart ≥ 3.6.0 and AGP
   8.5.2; 0.2.4 supports AGP 9 and moves the Android build files to `.kts`.
   This package already requires Flutter ≥ 3.38.0 / Dart ≥ 3.10.0, so the
   Dart/Flutter floors are satisfied. **AGP is not checked here** — the example
   app's Gradle config would need a build to confirm, and no Android build was
   run for this report.
4. **`getCommunicationDevice` caching was removed (0.2.3, "Fix
   setCommunicationDevice by eliminating cache").** The 0.1.25 plugin cached
   the communication device on the platform side. Removing the cache means
   `getCommunicationDeviceType()` starts reflecting the real device state
   rather than the last value written — which is *more* correct, and is read by
   `GravixForeignCallDetector` as one of its corroborating signals. Expect the
   detector's behaviour to change on API 31+ devices, in the direction of being
   right. Worth re-running the A7/A8 device rows after upgrading.
5. **A constraint bump is needed.** `^0.1.21` does not admit 0.2.4; the upgrade
   is `audio_session: ^0.2.4`, not just a `pub upgrade`.

## Correction to an existing comment

`gravix_audio_platform.dart` claimed `AndroidAudioHardwareMode` "is a
const-class in the version this SDK pins (0.1.25) and an enum in the version
the reference was written against (0.2.4)". **That is false.** It is
`class AndroidAudioHardwareMode` in both — `audio_session-0.1.25/lib/src/android.dart:770`
and `audio_session-0.2.4/lib/src/android.dart:780`. The mapping to
`GravixAudioHardwareMode` is still worth keeping, for the reason this report
demonstrates, but it is insulation rather than a workaround for a shape change
that never happened. The comment has been corrected.

## Recommendation

The Dart-side upgrade is one line and is safe. The risk is entirely in items 1,
2 and 4 above, all of which are device-observable and none of which a test here
can catch. Upgrade together with a device pass of the Android rows of
the internal on-device audio-routing checklist — not as a routine dependency bump.
