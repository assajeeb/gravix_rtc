/// Gravix Cloud — Gravity Compile's white-label real-time video/audio SDK.
///
/// Single import for consuming apps:
///
/// ```dart
/// import 'package:gravix_rtc/gravix_rtc.dart';
/// ```
///
/// Exposes:
/// - the vendored RTC core surface (`Room`, `RoomOptions`, `VideoTrack`,
///   `VideoTrackRenderer`, `CameraPosition`, events, ...),
/// - [GravixRoomService] — the one-stop room/call controller with mic/camera
///   control, remote mute, active-speaker tracking, connection-quality
///   auto data-saver, camera-facing sync and audio-session handling,
/// - [GravixMusicController] — background-music mixing (Android and iOS),
/// - [GravixVideoEffect] — the hook an effect package (beauty, blur, …) plugs
///   into to process the local camera track (none by default),
/// - [GravixTokenProvider] — how the app hands the SDK a join token (literal,
///   callback, or your own backend's url) without holding the gateway secret,
///   (the deprecated key+secret-on-the-device client is not part of
///   gravix_rtc; see `doc/MIGRATION_TOKEN_PROVIDER.md`),
/// - [GravixAudioRouting] — opt-in v2 audio routing (`v2 = true`).
///
/// No state-management framework is required: observable fields are
/// [ValueNotifier]s, and the services are plain classes you instantiate with
/// your own DI and dispose explicitly.
library;

export 'src/audio/audio.dart';
export 'src/backend/gravix_token_provider.dart';
export 'src/connect/gravix_analytics.dart';
export 'src/connect/gravix_connection_report.dart';
export 'src/connect/gravix_init_measure.dart' hide gravixClearRegionMeasurement, gravixResetDefaultRegionListStore;
export 'src/connect/gravix_join_timeline.dart';
export 'src/connect/gravix_join_timeline_log.dart';
export 'src/connect/gravix_prewarm.dart';
export 'src/connect/gravix_region_cache.dart';
export 'src/connect/gravix_region_prober.dart';
export 'src/connect/gravix_region_report.dart';
export 'src/connect/gravix_restart_strategy.dart';
export 'src/beauty/default_gravix_beauty_filter.dart';
export 'src/beauty/gravix_beauty_filter.dart';
export 'src/beauty/gravix_video_effect.dart' hide GravixVideoEffectBinding;
export 'src/large_room/large_room.dart';
export 'src/music/gravix_music_controller.dart';
export 'src/room/gravix_audio_first.dart';
export 'src/room/gravix_red_mode.dart';
export 'src/room/gravix_room_service.dart';
export 'src/rtc_core/gravix_client.dart';
export 'src/rtc_core/src/support/websocket/standby_types.dart' show GravixStandbyState, kGravixStandbyJoinWait;
