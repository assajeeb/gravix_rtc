// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

/// What the routing layer needs to know about the room it is routing for.
///
/// The guard reads this instead of reaching into [GravixRoomService] directly,
/// so the routing stack stays independent of the room layer (and testable
/// without one). [GravixRoomService] implements it and registers itself when
/// `GravixAudioRouting.v2` is on.
abstract interface class GravixAudioHost {
  /// A room is connected right now.
  bool get isRoomConnected;

  /// The app released the audio session on purpose while backgrounded.
  /// `MODE_NORMAL` is the correct state then, and the guard must not "repair"
  /// it.
  bool get appBackgrounded;

  /// Something is actually playing or capturing — not a quiet room of muted
  /// seats. Android resets an IDLE communication-mode owner to `MODE_NORMAL`
  /// after ~6s, which is not a dead session.
  bool get audioFlowing;

  /// Room playout is on media usage (true) rather than voice communication.
  /// On the media profile `MODE_NORMAL` is the intended state, so the guard
  /// stands down entirely.
  bool get recordableRoomAudio;
}
