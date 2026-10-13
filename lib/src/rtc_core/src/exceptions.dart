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

/// Base class for Exceptions thrown by the GravixRtc SDK
abstract class GravixRtcException implements Exception {
  final String message;
  const GravixRtcException._(this.message);

  @override
  String toString() => 'GravixRtc Exception: [$runtimeType] $message';
}

enum ConnectionErrorReason { NotAllowed, InternalError, Timeout }

/// An exception occurred while attempting to connect.
/// Common reasons:
/// - Invalid token (make sure your token is generated correctly)
/// - Network condition is not good
/// - Server not set up correctly (not responding)
class ConnectException extends GravixRtcException {
  final ConnectionErrorReason reason;
  final int statusCode;
  ConnectException(String msg, {required this.reason, this.statusCode = 0}) : super._(msg);
}

/// The url names a host of Gravix's RETIRED server deployment (the media server
/// that ran before the current Gravix regions), so the SDK refuses it before any
/// network I/O: no DNS lookup, no HEAD, no region-list fetch, no WebSocket.
///
/// Why fail instead of connecting: an app that still has an old host as a
/// hard-coded url (or as a fallback for a token response without `url`) would
/// run whole calls outside the current regions - no region routing, no relay,
/// slow joins - and the old server's missing region list looks like an SDK
/// bug. A typed error at the first call says what is wrong; a slow call on the
/// wrong server says nothing.
///
/// Thrown by `Room.connect`, `Room.prepareConnection` and
/// `GravixRoomService.connect`; `GravixStandby.open` resolves false instead
/// (it never throws), a token response whose `url` is retired is a
/// `GravixTokenException` (malformed) with this as its `cause`, and region
/// entries on a retired host are dropped. Only the exact hosts in
/// [retiredHosts] are retired: the wire protocol, the current region hosts and
/// the gateway's `/v1/token` path are unchanged.
class RetiredServerException extends GravixRtcException {
  /// The retired host the url named, lower case.
  final String host;

  RetiredServerException(this.host) : super._('retired Gravix server ($host): use the url from your token response');

  /// The hosts of the retired deployment. Exact host names, not suffixes: a
  /// region host such as `sgp1.` + the same domain is current.
  static const List<String> retiredHosts = ['rtc.gravixcloud.com', 'rtc-blr1.gravixcloud.com', 'token.gravixcloud.com'];

  /// The retired host [url] points at, or null. Any scheme (`wss`, `ws`,
  /// `https`, `http`) or none (a bare `host[:port][/path]`); the host is
  /// compared case-insensitively, without its port or a trailing dot.
  static String? retiredHostOf(String url) {
    final trimmed = url.trim();
    var host = Uri.tryParse(trimmed)?.host ?? '';
    // A bare host has no authority, or parses as a scheme (`host:443`).
    if (host.isEmpty) host = Uri.tryParse('wss://$trimmed')?.host ?? '';
    host = host.toLowerCase();
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    return retiredHosts.contains(host) ? host : null;
  }

  /// Throws a [RetiredServerException] when [url] points at a retired host.
  static void check(String url) {
    final host = retiredHostOf(url);
    if (host != null) throw RetiredServerException(host);
  }
}

/// An exception occurred while attempting to disconnect.
/// Common reasons:
/// - Network condition is not good.
/// - SFU deploy behind a NAT and not configured correctly.
/// - Need a turn relay server but not configured.
class MediaConnectException extends GravixRtcException {
  MediaConnectException([String msg = 'Ice connection failed']) : super._(msg);
}

/// GRAVIX(0.4.13): whether a failed join may be tried again with the same url
/// and token (`ConnectOptions.joinRetries`): only when the server accepted the
/// join (its JoinResponse came) and the peer connection then did not connect
/// ([MediaConnectException]). Everything else is final, the JoinResponse
/// timeout included: a server refuses a join it accepted at the WebSocket
/// (room full, a failed join) with a Leave and no JoinResponse, which the client
/// sees as that timeout. Also final: a refusal at the WebSocket
/// ([ConnectionErrorReason.NotAllowed]: 401/403, expired token), no
/// connectivity, a certificate pinning failure, a superseded or refused
/// WebSocket.
bool gravixIsJoinRetryable(Object error) => error is MediaConnectException;

/// Certificate pinning validation failed for an SDK-owned TLS connection.
class CertificatePinningException extends GravixRtcException {
  final String host;
  final String? presentedPin;

  CertificatePinningException(String msg, {required this.host, this.presentedPin}) : super._(msg);
}

/// An internal state of the SDK is not correct and can not continue to execute.
/// This should not occur frequently.
class UnexpectedStateException extends GravixRtcException {
  UnexpectedStateException([String msg = 'Unexpected connection state']) : super._(msg);
}

/// Exception thrown when pc negotiation fails.
class NegotiationError extends GravixRtcException {
  NegotiationError([String msg = 'Negotiation Error']) : super._(msg);
}

/// Failed to create a local track.
/// Common reasons:
/// - Required permissions not yet granted to the platform.
/// - Constraints(Capture options) rejected by the platform.
class TrackCreateException extends GravixRtcException {
  TrackCreateException([String msg = 'Failed to create track']) : super._(msg);
}

/// The platform audio session could not be configured for, or does not permit,
/// the requested audio operation (iOS; macOS has no audio session, so engine
/// failures there keep their generic error codes).
/// Common reasons:
/// - Recording was started while the app-managed audio session
///   (`AudioSessionManagementMode.manual`) has a category without input.
/// - The system rejected the audio session configuration.
///
/// 0.4.15 (ported from the upstream client SDK 2.12.0): these used to surface
/// as an `AudioProcessingException`, which named a cause they never had.
class AudioSessionException extends GravixRtcException {
  AudioSessionException([String msg = 'Audio session error']) : super._(msg);
}

/// Failed to publish a local track.
/// Common reasons:
/// - Token does not have track publish permission.
/// - Network condition is not good.
class TrackPublishException extends GravixRtcException {
  TrackPublishException([String msg = 'Failed to publish track']) : super._(msg);
}

/// Failed to publish data.
/// Common reasons:
/// - Token does not have data publish permission.
/// - Network condition is not good.
class DataPublishException extends GravixRtcException {
  DataPublishException([String msg = 'Failed to publish data']) : super._(msg);
}

/// A certain time has passed while attempting to execute an operation.
class TimeoutException extends GravixRtcException {
  TimeoutException([String msg = 'Timeout']) : super._(msg);
}

/// An exception for End to End Encryption.
class GravixRtcE2EEException extends GravixRtcException {
  GravixRtcE2EEException([String msg = 'E2EE error']) : super._(msg);

  @override
  String toString() => 'E2EE Exception: [$runtimeType] $message';
}

class UnexpectedConnectionState extends GravixRtcException {
  UnexpectedConnectionState([String msg = 'Unexpected connection state']) : super._(msg);
}
