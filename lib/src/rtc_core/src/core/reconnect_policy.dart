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
//
// GRAVIX (2026-09-27): pluggable reconnect back-off, parity with the React SDK's
// ReconnectPolicy / DefaultReconnectPolicy (src/core/room/ReconnectPolicy.ts,
// DefaultReconnectPolicy.ts). The engine used to hard-code the delay table below;
// the default policy reproduces it exactly.
import 'dart:math' as math;

/// What the engine knows when it asks a [ReconnectPolicy] for the next delay.
class ReconnectContext {
  const ReconnectContext({required this.retryCount, required this.elapsedMs, this.retryReason, this.serverUrl});

  /// Number of failed reconnect attempts so far (0 on the first call after a
  /// disconnect).
  final int retryCount;

  /// Milliseconds since the disconnect was detected.
  final int elapsedMs;

  /// Why the engine is reconnecting (e.g. `signalingDisconnected`,
  /// `peerConnectionFailed`), when known.
  final String? retryReason;

  /// The signalling url the session was connected to.
  final String? serverUrl;

  @override
  String toString() => 'ReconnectContext(retryCount: $retryCount, elapsedMs: $elapsedMs, retryReason: $retryReason)';
}

/// Controls reconnecting after the connection to the server is lost.
///
/// Pass one as `RoomOptions(reconnectPolicy: …)` (or
/// `GravixRoomService(reconnectPolicy: …)`).
abstract class ReconnectPolicy {
  /// The delay in ms before the next reconnect attempt; null to stop retrying
  /// (the room then disconnects with `DisconnectReason.reconnectAttemptsExceeded`).
  /// A policy that throws is treated as null.
  int? nextRetryDelayInMs(ReconnectContext context);
}

const _maxRetryDelay = 7000;

/// The SDK's delay table: 0, 300, 1200, 2700, 4800, then 7000 ms × 5 — ten
/// attempts in all.
const List<int> kDefaultReconnectDelaysInMs = [
  0,
  300,
  2 * 2 * 300,
  3 * 3 * 300,
  4 * 4 * 300,
  _maxRetryDelay,
  _maxRetryDelay,
  _maxRetryDelay,
  _maxRetryDelay,
  _maxRetryDelay,
];

/// Walks a delay table, one entry per attempt, and gives up after the last.
/// From the third attempt on, up to 1 s of random jitter is added so a fleet of
/// clients dropped together does not reconnect in lock step.
class DefaultReconnectPolicy implements ReconnectPolicy {
  DefaultReconnectPolicy([List<int>? retryDelays, math.Random? random])
    : retryDelays = List<int>.unmodifiable(retryDelays ?? kDefaultReconnectDelaysInMs),
      _random = random ?? math.Random();

  final List<int> retryDelays;
  final math.Random _random;

  /// How many attempts this policy allows.
  int get maxAttempts => retryDelays.length;

  @override
  int? nextRetryDelayInMs(ReconnectContext context) {
    if (context.retryCount >= retryDelays.length) return null;
    final delay = retryDelays[context.retryCount];
    if (context.retryCount <= 1) return delay;
    return delay + _random.nextInt(1000);
  }
}
