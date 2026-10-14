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

import 'core/engine.dart';
import 'core/gravix_ice_transport.dart' show GravixIceTransport;
import 'core/gravix_join_camera.dart' show GravixJoinCameraFailure;
import 'core/room.dart';
import 'core/signal_client.dart';
import 'participant/local.dart';
import 'participant/participant.dart';
import 'participant/remote.dart';
import 'publication/local.dart';
import 'publication/remote.dart';
import 'publication/track_publication.dart';
import 'stats/stats.dart';
import 'track/processor.dart';
import 'track/track.dart';
import 'types/other.dart';
import 'types/participant_permissions.dart';
import 'types/participant_state.dart' show ParticipantState;
import 'types/transcription_segment.dart';

/// Base type for all GravixRtc events.
mixin GravixRtcEvent {
  /// Every event must provide a useful textual representation for logging.
  @override
  String toString();
}

/// Base type for all [Room] events.
mixin RoomEvent implements GravixRtcEvent {}

/// Base type for all [Participant] events.
mixin ParticipantEvent implements GravixRtcEvent {}

/// Base type for all [Track] events.
mixin TrackEvent implements GravixRtcEvent {}

/// Base type for all [Engine] events.
mixin EngineEvent implements GravixRtcEvent {}

/// Base type for all [SignalClient] events.
mixin SignalEvent implements GravixRtcEvent {}

/// Base type for internal-only events.
mixin InternalEvent implements GravixRtcEvent {}

class RoomConnectedEvent with RoomEvent {
  final Room room;
  final String? metadata;
  const RoomConnectedEvent({required this.room, required this.metadata});

  @override
  String toString() => '${runtimeType}(room: ${room}, metadata: ${metadata})';
}

/// Base type for reconnecting events. Listen for this type to handle
/// both full reconnects and signal-only reconnects.
mixin ReconnectingEvent implements RoomEvent {}

/// When the connection to the server has been interrupted and it's attempting
/// a full reconnect (peer connections are reset, media is interrupted).
/// Emitted by [Room].
class RoomReconnectingEvent with RoomEvent, ReconnectingEvent {
  const RoomReconnectingEvent();

  @override
  String toString() => '${runtimeType}()';
}

/// When the signal connection has been interrupted and it's attempting
/// to resume. Peer connections remain active during this type of reconnect.
/// Emitted by [Room].
class RoomResumingEvent with RoomEvent, ReconnectingEvent {
  const RoomResumingEvent();

  @override
  String toString() => '${runtimeType}()';
}

/// report the number of attempts to reconnect to the room.
class RoomAttemptReconnectEvent with RoomEvent {
  final int attempt;

  /// Attempts the reconnect policy allows; -1 when a custom
  /// `RoomOptions.reconnectPolicy` decides as it goes.
  final int maxAttemptsRetry;
  final int nextRetryDelaysInMs;
  const RoomAttemptReconnectEvent({
    required this.attempt,
    required this.maxAttemptsRetry,
    required this.nextRetryDelaysInMs,
  });

  @override
  String toString() =>
      '${runtimeType}'
      '(attempt: ${attempt}, maxAttemptsRetry: ${maxAttemptsRetry}, '
      'nextRetryDelaysInMs: ${nextRetryDelaysInMs})';
}

/// GRAVIX(0.4.13): the initial join failed on the way to the media connection
/// and `Room.connect` joins again (`ConnectOptions.joinRetries`). Emitted once
/// per retry, before its [delay]. Show "reconnecting" / "still connecting" while
/// a connect is in flight and one of these has come in; the connect's own
/// future still decides the outcome (it completes once, after the last
/// attempt). Emitted by [Room].
class RoomJoinRetryEvent with RoomEvent {
  /// The retry about to run, 1-based (1 = the second join attempt).
  final int retry;

  /// Retries this connect allows (`ConnectOptions.joinRetries`).
  final int maxRetries;

  /// The wait before this retry.
  final Duration delay;

  /// Why the previous attempt failed (a `MediaConnectException`).
  final Object error;

  const RoomJoinRetryEvent({required this.retry, required this.maxRetries, required this.delay, required this.error});

  @override
  String toString() =>
      '${runtimeType}(retry: ${retry}/${maxRetries}, delay: ${delay.inMilliseconds}ms, error: ${error})';
}

/// GRAVIX (2026-10-13): the camera of `Room.connect(joinCamera: ...)` was not
/// published by the join; the join itself went on (the room is connected). The
/// camera was released (stopped and disposed, `GravixJoinCamera.onReleased`
/// called). [reason] says why; the app may publish a camera the normal way
/// (`setCameraEnabled(true)`, `publishVideoTrack`) once the cause is fixed.
/// Emitted by [Room] once per `connect`, after it returned (a failure inside
/// an attempt that is retried, or a join that fails, emits nothing).
class GravixJoinCameraFailedEvent with RoomEvent {
  final GravixJoinCameraFailure reason;

  /// The error behind it, when there is one (the capture's, the server's refusal).
  final Object? error;

  /// The join attempt (1 = the first).
  final int attempt;

  const GravixJoinCameraFailedEvent({required this.reason, this.error, required this.attempt});

  @override
  String toString() => '${runtimeType}(reason: ${reason.name}, attempt: ${attempt}, error: ${error})';
}

/// GRAVIX (2026-10-14): the session's ICE transport changed
/// (`Room.selectedTransport`): [transport] is tcp when either peer connection
/// runs over ICE/TCP, relay when either is relayed, else udp. A host whose
/// session lands on tcp after a reconnect is often slow (see
/// RoomSlowTcpTransportEvent). Read from each connection's selected candidate
/// pair every `GravixRecoveryOptions.iceTransportWatch` (5 s). Emitted by [Room].
class RoomIceTransportChangedEvent with RoomEvent {
  final GravixIceTransport? transport;
  final GravixIceTransport? previous;

  /// Each connection's own transport (null: not known yet).
  final GravixIceTransport? publisher;
  final GravixIceTransport? subscriber;

  const RoomIceTransportChangedEvent({this.transport, this.previous, this.publisher, this.subscriber});

  @override
  String toString() =>
      '${runtimeType}(${previous?.name} -> ${transport?.name}, publisher: ${publisher?.name}, '
      'subscriber: ${subscriber?.name})';
}

/// GRAVIX (2026-10-14): the session runs over ICE/TCP and its round trip ([rtt],
/// the selected pair's) stayed above `GravixRecoveryOptions.slowTcpRtt` (1 s)
/// for [over] (at least `slowTcpFor`, 10 s). Once per episode (again after the
/// round trip came back below the threshold). Media is likely frozen or very
/// low quality; an app may show it or report it. Emitted by [Room].
class RoomSlowTcpTransportEvent with RoomEvent {
  final Duration rtt;
  final Duration over;

  const RoomSlowTcpTransportEvent({required this.rtt, required this.over});

  @override
  String toString() => '${runtimeType}(rtt: ${rtt.inMilliseconds} ms, over: ${over.inMilliseconds} ms)';
}

/// GRAVIX (2026-10-14): how a reconnect attempt recovers the session.
enum GravixReconnectMode {
  /// The same session: a new signal connection and an ICE restart of the peer
  /// connections (the participant and its tracks stay on the server).
  resume,

  /// A new session: a new join and new peer connections (RoomReconnectingEvent;
  /// the far side may see the participant leave and join again).
  full,
}

/// GRAVIX (2026-10-14): a reconnect attempt starts (one per attempt, before its
/// dial). [cause]: why the session is being recovered (e.g. `peerConnectionClosed`,
/// `peerConnectionFailed`, `signal`, `reconnectRetry`, `mediaStalled`).
/// [reconnectReason]: what a resume tells the server (`RR_SIGNAL_DISCONNECTED`,
/// `RR_PUBLISHER_FAILED`, ...; null for a full reconnect, a join carries none).
/// [attempt]: 1 for the first attempt of this outage. [afterNetworkChange]: the
/// phone's network changed (or read offline) shortly before or during it.
/// Emitted by [Room].
class RoomReconnectAttemptEvent with RoomEvent {
  final GravixReconnectMode mode;
  final String cause;
  final String? reconnectReason;
  final int attempt;
  final bool afterNetworkChange;

  const RoomReconnectAttemptEvent({
    required this.mode,
    required this.cause,
    this.reconnectReason,
    required this.attempt,
    required this.afterNetworkChange,
  });

  @override
  String toString() =>
      '${runtimeType}(${mode.name}, cause: $cause, reason: $reconnectReason, attempt: $attempt, '
      'afterNetworkChange: $afterNetworkChange)';
}

/// Connection to room is re-established. All existing state is preserved.
/// Emitted by [Room].
class RoomReconnectedEvent with RoomEvent {
  const RoomReconnectedEvent();

  @override
  String toString() => '${runtimeType}()';
}

/// A local track could not be published
/// again after a full rejoin. The rejoin itself goes on (the room still emits
/// [RoomReconnectedEvent]); the app may publish the source again. Before 0.4.15
/// the error escaped the rejoin unhandled ("addTransceiver(): track is null").
/// Emitted by [Room] and [LocalParticipant].
class LocalTrackRepublishFailedEvent with RoomEvent, ParticipantEvent {
  final LocalParticipant participant;
  final LocalTrackPublication publication;
  final Object error;

  const LocalTrackRepublishFailedEvent({required this.participant, required this.publication, required this.error});

  @override
  String toString() => '${runtimeType}(source: ${publication.source}, error: $error)';
}

/// GRAVIX (0.4.15): why [Room.connectedUrl] changed.
enum RoomConnectedUrlChangeReason {
  /// A [Room.connect] completed (also when it landed on another region than the
  /// url it was given: the core's region failover).
  connect,

  /// A full reconnect (a new session) joined another url than the previous one.
  rejoin,
}

/// The server the session is connected to
/// changed: the first connect, a region failover, or a full rejoin to another
/// region. An app's "server" indicator should follow this (or read
/// [Room.connectedUrl]) rather than the url it passed to [Room.connect]: the
/// session may be elsewhere. A resume keeps the url and emits nothing.
/// Emitted by [Room].
class RoomConnectedUrlChangedEvent with RoomEvent {
  /// The url the session is connected to now.
  final String url;

  /// Its region slug (e.g. `sgp1`) when known: the server's JoinResponse, else
  /// the region list / start-up measurement entry for [url]. Null when unknown.
  final String? region;

  /// The url before, null on the first connect.
  final String? previousUrl;
  final String? previousRegion;
  final RoomConnectedUrlChangeReason reason;

  const RoomConnectedUrlChangedEvent({
    required this.url,
    required this.region,
    required this.previousUrl,
    required this.previousRegion,
    required this.reason,
  });

  @override
  String toString() =>
      '${runtimeType}(url: $url, region: $region, previousUrl: $previousUrl, '
      'previousRegion: $previousRegion, reason: ${reason.name})';
}

/// Disconnected from the room
/// Emitted by [Room].
class RoomDisconnectedEvent with RoomEvent {
  DisconnectReason? reason;
  RoomDisconnectedEvent({this.reason});

  @override
  String toString() => '${runtimeType}(reason: ${reason})';
}

/// Room metadata has changed.
/// Emitted by [Room].
class RoomMetadataChangedEvent with RoomEvent {
  final String? metadata;

  const RoomMetadataChangedEvent({required this.metadata});

  @override
  String toString() => '${runtimeType}(metadata: ${metadata})';
}

/// Participant's attributes have changed.
/// Emitted by [Room].
class ParticipantAttributesChanged with RoomEvent, ParticipantEvent {
  final Participant participant;
  final Map<String, String> attributes;

  const ParticipantAttributesChanged({required this.participant, required this.attributes});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, attributes: ${attributes})';
}

/// Room recording status has changed.
/// Emitted by [Room].
class RoomRecordingStatusChanged with RoomEvent {
  final bool activeRecording;

  const RoomRecordingStatusChanged({required this.activeRecording});

  @override
  String toString() => '${runtimeType}(activeRecording: ${activeRecording})';
}

/// When a new [RemoteParticipant] joins *after* the current participant has connected
/// It will not fire for participants that are already in the room
/// Emitted by [Room].
class ParticipantConnectedEvent with RoomEvent {
  final RemoteParticipant participant;

  const ParticipantConnectedEvent({required this.participant});

  @override
  String toString() => '${runtimeType}(participant: ${participant})';
}

/// When a [RemoteParticipant] leaves the room
/// Emitted by [Room].
class ParticipantDisconnectedEvent with RoomEvent {
  final RemoteParticipant participant;
  const ParticipantDisconnectedEvent({required this.participant});

  @override
  String toString() => '${runtimeType}(participant: ${participant})';
}

/// Active speakers changed. List of speakers are ordered by their audio level.
/// loudest speakers first. This will include the [LocalParticipant] too.
class ActiveSpeakersChangedEvent with RoomEvent {
  final List<Participant> speakers;
  const ActiveSpeakersChangedEvent({required this.speakers});

  @override
  String toString() =>
      '${runtimeType}'
      '(speakers: ${speakers.map((e) => e.toString()).join(', ')})';
}

/// When a new [Track] is published to [Room] *after* the current participant has
/// joined. It will not fire for tracks that are already published.
/// Emitted by [Room] and [RemoteParticipant].
class TrackPublishedEvent with RoomEvent, ParticipantEvent {
  final RemoteParticipant participant;
  final RemoteTrackPublication publication;
  const TrackPublishedEvent({required this.participant, required this.publication});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, publication: ${publication})';
}

/// The participant has unpublished one of their [Track].
/// Emitted by [Room] and [RemoteParticipant].
class TrackUnpublishedEvent with RoomEvent, ParticipantEvent {
  final RemoteParticipant participant;
  final RemoteTrackPublication publication;
  const TrackUnpublishedEvent({required this.participant, required this.publication});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, publication: ${publication})';
}

/// When the local participant publishes a new [Track] to the room.
/// Emitted by [Room] and [LocalParticipant].
class LocalTrackPublishedEvent with RoomEvent, ParticipantEvent {
  final LocalParticipant participant;
  final LocalTrackPublication publication;
  const LocalTrackPublishedEvent({required this.participant, required this.publication});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, publication: ${publication})';
}

class LocalTrackSubscribedEvent with RoomEvent, ParticipantEvent {
  final String trackSid;
  const LocalTrackSubscribedEvent({required this.trackSid});

  @override
  String toString() => '${runtimeType}(trackSid: ${trackSid})';
}

/// The local participant has unpublished one of their [Track].
/// Emitted by [Room] and [LocalParticipant].
class LocalTrackUnpublishedEvent with RoomEvent, ParticipantEvent {
  final LocalParticipant participant;
  final LocalTrackPublication publication;
  const LocalTrackUnpublishedEvent({required this.participant, required this.publication});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, publication: ${publication})';
}

/// [LocalParticipant] has subscribed to a new track published by a
/// [RemoteParticipant].
/// Emitted by [Room] and [RemoteParticipant].
class TrackSubscribedEvent with RoomEvent, ParticipantEvent {
  final RemoteParticipant participant;
  final RemoteTrackPublication publication;
  final Track track;
  const TrackSubscribedEvent({required this.participant, required this.publication, required this.track});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, publication: ${publication}, '
      'track: ${track})';
}

/// An error has occurred during track subscription.
/// Emitted by [Room] and [RemoteParticipant].
class TrackSubscriptionExceptionEvent with RoomEvent, ParticipantEvent {
  final RemoteParticipant? participant;
  final String? sid;
  final TrackSubscribeFailReason reason;
  const TrackSubscriptionExceptionEvent({this.participant, this.sid, required this.reason});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, sid: ${sid}, reason: ${reason})';
}

/// The [LocalParticipant] has unsubscribed from a track published by a
/// [RemoteParticipant]. This event is fired when the track was unpublished.
/// Emitted by [Room] and [RemoteParticipant].
class TrackUnsubscribedEvent with RoomEvent, ParticipantEvent {
  final RemoteParticipant participant;
  final RemoteTrackPublication publication;
  final Track track;
  const TrackUnsubscribedEvent({required this.participant, required this.publication, required this.track});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, publication: ${publication}, '
      'track: ${track})';
}

/// A Participant has muted one of the tracks.
/// Emitted by [RemoteParticipant] and [LocalParticipant].
class TrackMutedEvent with RoomEvent, ParticipantEvent {
  final Participant participant;
  final TrackPublication publication;
  const TrackMutedEvent({required this.participant, required this.publication});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, publication: ${publication})';
}

/// This participant has unmuted one of their tracks
/// Emitted by [RemoteParticipant] and [LocalParticipant].
class TrackUnmutedEvent with RoomEvent, ParticipantEvent {
  final Participant participant;
  final TrackPublication publication;
  const TrackUnmutedEvent({required this.participant, required this.publication});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, publication: ${publication})';
}

/// The [StreamState] on the [RemoteTrackPublication] has updated by the server.
/// See [RemoteTrackPublication.streamState] for more information.
/// Emitted by [Room] and [RemoteParticipant].
class TrackStreamStateUpdatedEvent with RoomEvent, ParticipantEvent {
  final RemoteParticipant participant;
  final RemoteTrackPublication publication;
  final StreamState streamState;
  const TrackStreamStateUpdatedEvent({required this.participant, required this.publication, required this.streamState});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, publication: ${publication}, '
      'streamState: ${streamState})';
}

/// Participant metadata is a simple way for app-specific state to be pushed to
/// all users. When RoomService.UpdateParticipantMetadata is called to change a
/// [Participant]'s state, *all* [Participant]s in the room will fire this event.
/// Emitted by [Room] and [Participant].
class ParticipantMetadataUpdatedEvent with RoomEvent, ParticipantEvent {
  final Participant participant;
  final String metadata;
  const ParticipantMetadataUpdatedEvent({required this.participant, required this.metadata});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, metadata: ${metadata})';
}

class ParticipantStateUpdatedEvent with RoomEvent, ParticipantEvent {
  final Participant participant;
  final ParticipantState state;
  const ParticipantStateUpdatedEvent({required this.participant, required this.state});

  @override
  String toString() => '${runtimeType}(participant: ${participant}, state: ${state})';
}

/// [Pariticpant]'s [ConnectionQuality] has updated.
/// Emitted by [Room] and [Participant].
class ParticipantConnectionQualityUpdatedEvent with RoomEvent, ParticipantEvent {
  final Participant participant;
  final ConnectionQuality connectionQuality;
  const ParticipantConnectionQualityUpdatedEvent({required this.participant, required this.connectionQuality});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, connectionQuality: ${connectionQuality})';
}

/// Data received from  [RemoteParticipant].
/// Data packets provides the ability to use GravixRtc to send/receive arbitrary
/// payloads.
/// Emitted by [Room] and [RemoteParticipant].
class DataReceivedEvent with RoomEvent, ParticipantEvent {
  /// Sender of the data. This may be null if data is sent from Server API.
  final RemoteParticipant? participant;
  final List<int> data;
  final String? topic;
  const DataReceivedEvent({required this.participant, required this.data, required this.topic});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, topic: ${topic}, data: ${data})';
}

/// The participant's isSpeaking property has changed
/// Emitted by [Participant].
class SpeakingChangedEvent with ParticipantEvent {
  final Participant participant;
  final bool speaking;
  const SpeakingChangedEvent({required this.participant, required this.speaking});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, speaking: ${speaking})';
}

/// One of subscribed tracks have changed its permissions for the current
/// participant. If permission was revoked, then the track will no longer
/// be subscribed. If permission was granted, a TrackSubscribed event will
/// be emitted.
class TrackSubscriptionPermissionChangedEvent with RoomEvent, ParticipantEvent {
  final Participant participant;
  final RemoteTrackPublication publication;
  final TrackSubscriptionState state;
  const TrackSubscriptionPermissionChangedEvent({
    required this.participant,
    required this.publication,
    required this.state,
  });

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, publication: ${publication}, '
      'state: ${state})';
}

/// The [ParticipantPermissions] updated for the [Participant].
/// Currently, only for [LocalParticipant].
/// Emitted by [Room] and [LocalParticipant].
class ParticipantPermissionsUpdatedEvent with RoomEvent, ParticipantEvent {
  final Participant participant;
  final ParticipantPermissions permissions;
  final ParticipantPermissions oldPermissions;
  const ParticipantPermissionsUpdatedEvent({
    required this.participant,
    required this.permissions,
    required this.oldPermissions,
  });

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, permissions: ${permissions}, '
      'oldPermissions: ${oldPermissions})';
}

/// Transcription event received from the server.
class TranscriptionEvent with RoomEvent, ParticipantEvent {
  final Participant participant;
  final TrackPublication<Track>? publication;
  final List<TranscriptionSegment> segments;
  const TranscriptionEvent({required this.participant, required this.publication, required this.segments});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, publication: ${publication}, '
      'segments: ${segments})';
}

class ParticipantNameUpdatedEvent with RoomEvent, ParticipantEvent {
  final Participant participant;
  final String name;
  const ParticipantNameUpdatedEvent({required this.participant, required this.name});

  @override
  String toString() =>
      '${runtimeType}'
      '(participant: ${participant}, name: ${name})';
}

class AudioPlaybackStatusChanged with RoomEvent {
  final bool isPlaying;
  const AudioPlaybackStatusChanged({required this.isPlaying});

  @override
  String toString() => '${runtimeType}(isPlaying: ${isPlaying})';
}

class AudioSenderStatsEvent with TrackEvent {
  final AudioSenderStats stats;
  final num currentBitrate;
  const AudioSenderStatsEvent({required this.stats, required this.currentBitrate});

  @override
  String toString() =>
      '${runtimeType}'
      '(stats: ${stats}, currentBitrate: ${currentBitrate})';
}

class VideoSenderStatsEvent with TrackEvent {
  final Map<String, VideoSenderStats> stats;
  final Map<String, num> bitrateForLayers;
  final num currentBitrate;
  const VideoSenderStatsEvent({required this.stats, required this.currentBitrate, required this.bitrateForLayers});

  @override
  String toString() =>
      '${runtimeType}'
      '(stats: ${stats}, bitrateForLayers: ${bitrateForLayers}, '
      'currentBitrate: ${currentBitrate})';
}

class AudioReceiverStatsEvent with TrackEvent {
  final AudioReceiverStats stats;
  final num currentBitrate;
  const AudioReceiverStatsEvent({required this.stats, required this.currentBitrate});

  @override
  String toString() =>
      '${runtimeType}'
      '(stats: ${stats}, currentBitrate: ${currentBitrate})';
}

class VideoReceiverStatsEvent with TrackEvent {
  final VideoReceiverStats stats;
  final num currentBitrate;
  const VideoReceiverStatsEvent({required this.stats, required this.currentBitrate});

  @override
  String toString() =>
      '${runtimeType}'
      '(stats: ${stats}, currentBitrate: ${currentBitrate})';
}

class AudioVisualizerEvent with TrackEvent {
  final Track track;
  final List<Object?> event;
  const AudioVisualizerEvent({required this.track, required this.event});

  @override
  String toString() => '${runtimeType}(track: ${track}, event: ${event})';
}

class TrackProcessorUpdateEvent with TrackEvent {
  final Track track;
  final TrackProcessor? processor;
  const TrackProcessorUpdateEvent({required this.track, this.processor});

  @override
  String toString() =>
      '${runtimeType}'
      '(track: ${track}, processor: ${processor})';
}

/// Pre-connect audio buffer has started recording.
/// Emitted by [Room].
class PreConnectAudioBufferStartedEvent with RoomEvent {
  final int sampleRate;
  final Duration timeout;
  const PreConnectAudioBufferStartedEvent({required this.sampleRate, required this.timeout});

  @override
  String toString() =>
      '${runtimeType}'
      '(sampleRate: ${sampleRate}, timeout: ${timeout})';
}

/// Pre-connect audio buffer has stopped recording.
/// Emitted by [Room].
class PreConnectAudioBufferStoppedEvent with RoomEvent {
  final int bufferedSize;
  final bool isBufferSent;
  const PreConnectAudioBufferStoppedEvent({required this.bufferedSize, required this.isBufferSent});

  @override
  String toString() =>
      '${runtimeType}'
      '(bufferedSize: ${bufferedSize}, isDataSent: ${isBufferSent})';
}

/// Fired when the participant has been moved to a different room by the server.
/// Emitted by [Room].
class RoomMovedEvent with RoomEvent {
  final String roomName;
  const RoomMovedEvent({required this.roomName});

  @override
  String toString() => '${runtimeType}(roomName: $roomName)';
}
