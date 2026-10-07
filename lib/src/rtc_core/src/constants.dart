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

class Timeouts {
  final Duration connection;
  final Duration debounce;
  final Duration publish;
  final Duration subscribe;
  final Duration peerConnection;
  final Duration iceRestart;

  /// GRAVIX(0.4.13): how long a FRESH join waits for its primary peer
  /// connection to connect after the JoinResponse before it fails with
  /// `MediaConnectException`. Up to 0.4.12 this wait used [connection] (10 s).
  /// Field 2026-10-06/07: a phone in a transient stall (ICE RTT 3.9 s) failed
  /// this wait; ICE + DTLS on a fresh join take about four to five round trips
  /// (offer/answer, connectivity checks + nomination, two DTLS flights), ~16-20
  /// s at that RTT, so 10 s caps a join at an RTT of ~2-2.5 s. The SFU gives a
  /// fresh transport ~15 s of ICE checking and then 10-20 s for DTLS after ICE,
  /// so a client wait of 20 s is not cut short by the server. Resumes and full
  /// reconnects keep [connection]. Set it to 10 s for the 0.4.12 wait.
  final Duration mediaConnect;

  /// The [mediaConnect] default.
  static const Duration defaultMediaConnect = Duration(seconds: 20);

  const Timeouts({
    required this.connection,
    required this.debounce,
    required this.publish,
    required this.subscribe,
    required this.peerConnection,
    required this.iceRestart,
    this.mediaConnect = defaultMediaConnect,
  });

  static const Timeouts defaultTimeouts = Timeouts(
    connection: Duration(seconds: 10),
    debounce: Duration(milliseconds: 20),
    publish: Duration(seconds: 10),
    subscribe: Duration(seconds: 10),
    peerConnection: Duration(seconds: 10),
    iceRestart: Duration(seconds: 10),
    mediaConnect: defaultMediaConnect,
  );

  Timeouts copyWith({
    Duration? connection,
    Duration? debounce,
    Duration? publish,
    Duration? subscribe,
    Duration? peerConnection,
    Duration? iceRestart,
    Duration? mediaConnect,
  }) => Timeouts(
    connection: connection ?? this.connection,
    debounce: debounce ?? this.debounce,
    publish: publish ?? this.publish,
    subscribe: subscribe ?? this.subscribe,
    peerConnection: peerConnection ?? this.peerConnection,
    iceRestart: iceRestart ?? this.iceRestart,
    mediaConnect: mediaConnect ?? this.mediaConnect,
  );
}
