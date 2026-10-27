// Copyright Gravity Compile, Inc. Apache 2.0.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

// ═════════════════════════════════════════════════════════════════════════════
//  GravixTokenBuilder — signs a join token on the device (2026-10-27).
// ═════════════════════════════════════════════════════════════════════════════
//
// The Dart twin of the `gravix-rtc-token` npm package (and the Go / Java token
// libraries): same claims, same key order, same HS256 signature, so a token made
// here is byte-for-byte the token the npm `createToken` makes for the same
// inputs and clock (test/fixtures/token_vectors.json comes from the JS build).
//
// Why it exists. A per-join token request to the app's backend is a round trip
// on every room tap, and a big app with many rooms turns that into a load spike
// on its own servers. Signing on the device costs microseconds and no network.
//
// What it costs (the owner's call, 2026-10-27): the App Certificate is then on
// the device. Whoever reads it — from the binary, from memory, from the request
// that delivered it — can sign a token for ANY identity and ANY room of that
// app, publisher and room-admin grants included, until the certificate is
// rotated in the console (which breaks every installed copy holding the old
// one). Deliver it to signed-in users only, from the app's own server, and
// never commit it to the app's source.

/// The default token lifetime (same as the npm package).
const Duration kGravixTokenDefaultTtl = Duration(hours: 6);

/// The longest lifetime the server accepts.
const Duration kGravixTokenMaxTtl = Duration(hours: 24);

/// Separator between the App ID and the room in the server-side room name.
const String kGravixRoomSeparator = '_';

/// What the token grants. Field for field the npm package's `TokenOptions`, with
/// the same defaults.
@immutable
class GravixTokenOptions {
  const GravixTokenOptions({
    required this.room,
    required this.identity,
    this.name,
    this.metadata,
    this.attributes,
    this.ttl = kGravixTokenDefaultTtl,
    this.canPublish = true,
    this.canSubscribe = true,
    this.canPublishData = true,
    this.canUpdateOwnMetadata = true,
    this.canPublishSources,
    this.hidden = false,
    this.roomAdmin = false,
  });

  /// Room to join; the `<AppID>_` prefix is added if missing.
  final String room;

  /// The user's unique id within the room.
  final String identity;

  /// Display name other participants see.
  final String? name;

  /// Opaque string visible to other participants.
  final String? metadata;

  /// Key/value pairs visible to others. "gravix.app" is reserved (the server sets it).
  final Map<String, String>? attributes;

  /// How long the token can be used to join. Default 6 h, max 24 h; whole seconds.
  final Duration ttl;

  /// Default true; false makes a listener.
  final bool canPublish;

  final bool canSubscribe;

  /// Data messages and chat.
  final bool canPublishData;

  /// The user may change its own name, metadata and attributes (the Gravix SDKs
  /// publish e.g. the camera facing). `gravix.*` attributes stay the server's.
  final bool canUpdateOwnMetadata;

  /// Limit publishing to these sources ("camera", "microphone", "screen_share",
  /// "screen_share_audio").
  final List<String>? canPublishSources;

  /// Invisible to others (recorders, bots).
  final bool hidden;

  /// May mute/remove others in THIS room only.
  final bool roomAdmin;
}

/// Thrown for inputs the server would refuse anyway. The message never carries
/// the certificate.
class GravixTokenBuildException implements Exception {
  const GravixTokenBuildException(this.message);

  final String message;

  @override
  String toString() => 'GravixTokenBuildException: $message';
}

/// Signs Gravix join tokens locally. See the file comment for what holding the
/// certificate on a device means.
abstract final class GravixTokenBuilder {
  /// The server-side name of an app's room (`<AppID>_<room>`).
  static String roomName(String appId, String room) =>
      room.startsWith('$appId$kGravixRoomSeparator') ? room : '$appId$kGravixRoomSeparator$room';

  /// Strips the app prefix, for showing a room name to users.
  static String displayName(String appId, String room) {
    final prefix = '$appId$kGravixRoomSeparator';
    return room.startsWith(prefix) ? room.substring(prefix.length) : room;
  }

  /// A signed join token (HS256 JWT) for [options]. Synchronous: one HMAC, no I/O.
  /// [now] is the clock (default: the device clock).
  ///
  /// Throws [GravixTokenBuildException] on an empty or malformed App ID, a
  /// certificate shorter than 32 characters, a missing room or identity, or a
  /// ttl outside (0, 24 h].
  static String create(String appId, String appCertificate, GravixTokenOptions options, {DateTime Function()? now}) {
    final nowSeconds = (now ?? DateTime.now)().millisecondsSinceEpoch ~/ 1000;
    final input = _signingInput(_claims(appId, appCertificate, options, nowSeconds));
    final sig = Hmac(sha256, utf8.encode(appCertificate)).convert(utf8.encode(input)).bytes;
    return '$input.${_b64url(sig)}';
  }

  // Key order is the npm package's (JSON.stringify keeps insertion order, and so
  // does a Dart map literal): the signature covers the exact bytes.
  static Map<String, Object> _claims(String appId, String cert, GravixTokenOptions o, int now) {
    if (appId.isEmpty) throw const GravixTokenBuildException('app ID is empty');
    if (appId.contains(kGravixRoomSeparator)) {
      throw const GravixTokenBuildException('app ID must not contain "$kGravixRoomSeparator"');
    }
    if (cert.length < 32) throw const GravixTokenBuildException('app certificate is shorter than 32 characters');
    if (o.room.isEmpty) throw const GravixTokenBuildException('room is required');
    if (o.identity.isEmpty) throw const GravixTokenBuildException('identity is required');
    final ttl = o.ttl.inSeconds;
    if (ttl <= 0 || ttl > kGravixTokenMaxTtl.inSeconds) {
      throw GravixTokenBuildException('ttl must be in (0, ${kGravixTokenMaxTtl.inSeconds}] seconds');
    }
    final sources = o.canPublishSources;
    final attributes = o.attributes;
    return <String, Object>{
      'iss': appId,
      'sub': o.identity,
      'iat': now,
      'nbf': now,
      'exp': now + ttl,
      'video': <String, Object>{
        'roomJoin': true,
        'room': roomName(appId, o.room),
        'canPublish': o.canPublish,
        'canSubscribe': o.canSubscribe,
        'canPublishData': o.canPublishData,
        'canUpdateOwnMetadata': o.canUpdateOwnMetadata,
        if (o.roomAdmin) 'roomAdmin': true,
        if (sources != null && sources.isNotEmpty) 'canPublishSources': sources,
        if (o.hidden) 'hidden': true,
      },
      if (o.name?.isNotEmpty ?? false) 'name': o.name!,
      if (o.metadata?.isNotEmpty ?? false) 'metadata': o.metadata!,
      if (attributes != null && attributes.isNotEmpty) 'attributes': attributes,
    };
  }

  static String _signingInput(Map<String, Object> claims) =>
      '${_b64url(utf8.encode('{"alg":"HS256","typ":"JWT"}'))}.${_b64url(utf8.encode(jsonEncode(claims)))}';

  static String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
}
