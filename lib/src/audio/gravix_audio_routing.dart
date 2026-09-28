// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'gravix_android_audio_session_guard.dart';
import 'gravix_android_audio_session_owner.dart';
import 'gravix_audio_platform.dart' show GravixAudioOutput;
import 'gravix_audio_route_log.dart';
import 'gravix_audio_route_manager.dart';
import 'gravix_foreign_call_detector.dart';

/// Feature flag and entry point for the v2 audio-routing stack.
///
/// v2 is a port of the routing implementation in a production app's performance
/// upgrade: an app-owned Android audio session, a single serialized route
/// apply, device hot-plug handling, and a foreign-call detector. What changed
/// and what each change claims to fix is written up in
/// the internal audio-routing design notes; the on-device evidence for those claims
/// belongs in the internal on-device audio-routing checklist, which is **not yet filled
/// in**.
///
/// ```dart
/// GravixAudioRouting.v2 = true;   // before constructing GravixRoomService
/// ```
///
/// Default **false** this release. Nothing about [GravixRoomService]'s audio
/// behaviour changes while it is false — the v1 path is untouched.
///
/// ## Behavioural difference to know about before enabling
///
/// v2 has **no automatic earpiece ranking, and never will**. v1 called
/// `setSpeakerOutputPreferred(false)` whenever an external output was present,
/// which installs the preferred-device list `[BT, Wired, Earpiece, Speaker]`.
/// That list is sticky and outlives the headset that justified it, so the
/// earpiece wins the moment the headset disconnects — nobody asked for it, and
/// the room goes "silent" in the user's hand. That is §1 of the comparison doc
/// and it is deliberately, permanently gone.
///
/// [setAudioOutput] is the **deliberate replacement**, and it is a different
/// thing: it names a device (`setCommunicationDevice` on API 31+) instead of
/// ordering a list, so it only ever happens because the user asked for it and
/// nothing is left behind for a later hot-plug to re-resolve into a surprise.
/// An app with a private/1:1 listening mode wires that toggle to it.
///
/// Routing is automatic until [setAudioOutput] is called: the speaker is
/// preferred unconditionally and a connected headset wins by ranking. An app
/// that never calls it behaves exactly as it did before the method existed.
class GravixAudioRouting {
  GravixAudioRouting._();

  /// Enable the v2 routing stack. Read at `GravixRoomService.connect` time, so
  /// set it before connecting. Default false.
  static bool v2 = false;

  /// One owner for "where does the sound come out".
  static GravixAudioRouteManager get routeManager => GravixAudioRouteManager.instance;

  /// App-owned Android audio session (Android only; a no-op elsewhere).
  static GravixAndroidAudioSessionOwner get sessionOwner => GravixAndroidAudioSessionOwner.instance;

  /// Liveness check for a session torn down under a live room.
  static GravixAndroidAudioSessionGuard get sessionGuard => GravixAndroidAudioSessionGuard.instance;

  /// "Is another app holding a voice call right now?"
  static GravixForeignCallDetector get foreignCall => GravixForeignCallDetector.instance;

  /// Bounded breadcrumb trail of every routing decision — put
  /// `GravixAudioRouting.log.dump()` in your bug-report payload.
  static GravixAudioRouteLog get log => GravixAudioRouteLog.instance;

  /// Force the built-in loudspeaker even with a headset connected.
  static set forceSpeakerOverHeadset(bool value) => routeManager.forceSpeakerOverHeadset = value;
  static bool get forceSpeakerOverHeadset => routeManager.forceSpeakerOverHeadset;

  /// Whether the effective output is the loudspeaker. Bind a speaker icon to
  /// `routeManager.speakerOnListenable` instead if you need a listenable.
  static bool get speakerOn => routeManager.speakerOn;

  // ── explicit output selection ─────────────────────────────────────────────

  /// Select the audio output explicitly — the deliberate replacement for the
  /// automatic earpiece ranking removed in v2.
  ///
  /// ```dart
  /// GravixAudioRouting.v2 = true;                                 // opt in
  /// await GravixAudioRouting.setAudioOutput(GravixAudioOutput.earpiece);
  /// ```
  ///
  /// Returns false and does nothing when [v2] is off — the v1 path has no
  /// route owner to hold the selection, so an explicit output there would be
  /// overwritten by the next thing that touches AudioManager. It also returns
  /// false when the handset has no such output or the native call failed.
  ///
  /// This is **not** the ranking that was removed: it sets a device rather
  /// than a preferred-device list, so it cannot become the sticky fallback
  /// that §1 of the internal audio-routing design notes describes. Full rationale
  /// on [GravixAudioRouteManager.setAudioOutput].
  static Future<bool> setAudioOutput(GravixAudioOutput output) async {
    if (!v2) return false;
    return routeManager.setAudioOutput(output);
  }

  /// Drop an explicit [setAudioOutput] selection and return to automatic
  /// routing (speaker preferred unconditionally).
  static Future<void> clearAudioOutput() async {
    if (!v2) return;
    await routeManager.clearAudioOutput();
  }

  /// The explicitly selected output, or null while routing is automatic.
  /// Bind a toggle to `routeManager.audioOutputListenable` for a listenable.
  static GravixAudioOutput? get audioOutput => routeManager.audioOutput;
}
