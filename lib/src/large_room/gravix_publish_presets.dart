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

import '../rtc_core/gravix_client.dart'
    show DegradationPreference, VideoEncoding, VideoParametersPresets, VideoPublishOptions;

/// Publish profiles for large rooms.
///
/// **Opt-in.** [GravixRoomService] does not use these; its own defaults are
/// unchanged. Pass one explicitly:
///
/// ```dart
/// await localParticipant.publishVideoTrack(
///   track,
///   publishOptions: GravixPublishPresets.host,
/// );
/// ```
///
/// ## Why H.264 here, and why it is not the default
///
/// H.264 is hardware-encoded on effectively every phone, which matters when one
/// host publishes to a large audience for a long time: the encoder is the
/// thermal budget. It is also the codec every device can decode, so a large
/// room does not have to fall back per-viewer.
///
/// It is not free. Changing the codec changes the offer, so a host publishing
/// with this preset produces different SDP from one publishing with the
/// service's defaults — same protocol and same signalling, but a different
/// negotiated codec. That is a deployment decision, not something an SDK should
/// make for an app on upgrade, which is why nothing applies this for you.
abstract final class GravixPublishPresets {
  /// Large-room host: two simulcast layers, H.264.
  ///
  /// Two layers, not three. The capture resolution is published as `f`
  /// automatically and [VideoPublishOptions.videoSimulcastLayers] adds the rest,
  /// so one entry here is two layers on the wire. A third rung costs encoder
  /// pixels and uplink on the publisher — the one participant in a large room
  /// who cannot afford either — to serve a band of viewers that the 180p rung
  /// already covers acceptably.
  static const VideoPublishOptions host = VideoPublishOptions(
    videoCodec: 'h264',
    simulcast: true,
    videoEncoding: VideoEncoding(maxBitrate: 800_000, maxFramerate: 24),
    // f = capture resolution (~540p), q = 180p. Two layers total.
    videoSimulcastLayers: [VideoParametersPresets.h180_169],
    degradationPreference: DegradationPreference.balanced,
  );

  /// [host] for a publisher whose own uplink is the bottleneck: single layer,
  /// still H.264. The analogue of the service's data-saver profile.
  static const VideoPublishOptions hostLowData = VideoPublishOptions(
    videoCodec: 'h264',
    simulcast: false,
    videoEncoding: VideoEncoding(maxBitrate: 600_000, maxFramerate: 24),
    videoSimulcastLayers: [],
    degradationPreference: DegradationPreference.balanced,
  );
}
