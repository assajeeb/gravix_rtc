// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

/// The 0.4.8 join-time publishing changes, behind ONE switch (the rollback).
///
/// Off by default in 0.4.8 (opt in): one field join stalled once with it on and the
/// cause is not yet known, so it ships disabled until proven on more devices.
///
/// On:
///  - the camera publishes beside the microphone, not behind it: up to 0.4.7 one
///    lock in `LocalParticipant` serialised every publish, camera open included,
///    so even `Future.wait([setMicrophoneEnabled(true), setCameraEnabled(true)])`
///    ran mic, then camera. Same-source publishes stay serialised;
///  - `FastConnectOptions` publishes (mic / camera / screen at the JoinResponse)
///    run side by side and no longer hold the rest of the JoinResponse handling
///    (remote participants, `RoomConnectedEvent`);
///  - `GravixRoomService.connect` starts the initial mic / camera publication at
///    the JoinResponse, while ICE + DTLS run, instead of after the peer
///    connection is up, and runs the mic and camera steps side by side.
///
/// Off (default): exactly the 0.4.7 order everywhere. Read at each publish / join, so set it
/// before `connect` (e.g. from a remote-config flag at app start).
///
/// Why: a video host's tap-to-camera-live on a phone was 1.7-2.6 s (a production
/// app, Android 13, Wi-Fi, 2026-10-03): after the JoinResponse the app waited for the
/// primary peer connection (0.7-1.06 s), then published the mic (0.2-0.55 s),
/// then the camera (0.2-0.5 s more), each step behind the previous one.
abstract final class GravixFastJoin {
  static bool enabled = false;
}
