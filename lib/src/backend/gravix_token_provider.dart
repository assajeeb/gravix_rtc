import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../connect/gravix_region_report.dart';
import '../rtc_core/src/token_source/jwt.dart';
import '../rtc_core/src/token_source/token_source.dart';

// ═════════════════════════════════════════════════════════════════════════════
//  GravixTokenProvider — how an app gets a join token WITHOUT holding the
//  gateway api_secret.
// ═════════════════════════════════════════════════════════════════════════════
//
// Why this exists. A client that holds an api_key + api_secret posts the
// tenant's api_secret from the phone. Anything compiled into an app is
// readable by anyone with the binary, and a secret that can mint
// tokens can mint them for ANY room and ANY identity. The secret has to live on
// a server the tenant controls; the app only ever RECEIVES a token.
//
// Three ways to hand the SDK a token, all returning the same credentials type:
//   (a) literal  — the app already has a token (+ url, + region_urls)
//   (b) callback — the app fetches it however it likes (Parse SDK, gRPC, …)
//   (c) endpoint — the SDK POSTs {room, identity, name, can_publish} to the
//                  tenant's own backend, which answers with the gateway's
//                  /v1/token response, unchanged.
//
// Why not just use the vendored upstream TokenSource as-is. Its response type
// (`TokenSourceResponse`) has four fields and `region_urls` is not one of them,
// so mapping the gateway response into it silently drops the region list — the
// probe race and the connect ladder then go dark and every join lands on the
// pinned url, with no error anywhere. So the credentials type here is
// Gravix-owned and keeps the region entries; the provider still IMPLEMENTS the
// upstream `TokenSourceConfigurable` (it can be passed wherever upstream code
// takes a token source), reuses the upstream JWT helper for expiry, and
// [GravixTokenProvider.fromTokenSource] adapts any upstream source the other
// way. Nothing under `rtc_core/` is edited.
//
// No added round trip. A provider caches. `getCredentials` for a request
// whose token is still valid returns without touching the network, so an app
// that calls it (or `GravixRoomService.prewarm`) when the room list opens pays
// for the token BEFORE the tap, not after it.

/// What the app is asking a token for. The four gateway `/v1/token` request
/// fields, minus `api_key` / `api_secret` — those never leave the tenant's
/// server on this path.
@immutable
class GravixTokenRequest {
  const GravixTokenRequest({required this.room, required this.identity, this.name = '', this.canPublish = false});

  /// Room name.
  final String room;

  /// Participant identity (in this SDK: the app's uid as a string).
  final String identity;

  /// Display name.
  final String name;

  /// What the app is ASKING for. The tenant backend decides whether to grant
  /// it; a backend that trusts this field blindly has moved the problem, not
  /// solved it (see doc/MIGRATION_TOKEN_PROVIDER.md).
  final bool canPublish;

  /// The wire body of the endpoint variant. Same spelling as the gateway.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'room': room,
    'identity': identity,
    'name': name,
    'can_publish': canPublish,
  };

  /// Cache key. NUL-separated so no combination of field values can collide
  /// with another ("a|b" + "c" vs "a" + "b|c").
  String get cacheKey => '$room\u0000$identity\u0000$name\u0000$canPublish';

  @override
  bool operator ==(Object other) =>
      other is GravixTokenRequest &&
      other.room == room &&
      other.identity == identity &&
      other.name == name &&
      other.canPublish == canPublish;

  @override
  int get hashCode => Object.hash(room, identity, name, canPublish);

  @override
  String toString() => 'GravixTokenRequest(room: $room, identity: $identity, canPublish: $canPublish)';
}

/// Why a token could not be produced.
enum GravixTokenErrorReason {
  /// No answer within the provider's `timeout`. Before 2026-09-19 neither SDK
  /// had a token timeout at all: a gateway that accepted the TCP connection and
  /// then stalled held the join — and the user — forever.
  timeout,

  /// The endpoint answered with a non-2xx status ([GravixTokenException.statusCode]).
  http,

  /// The answer had no token or no url.
  malformed,

  /// The app's callback (or the transport under the endpoint) threw.
  callback,

  /// A literal token that has expired. A literal provider cannot refetch.
  expired,
}

/// The one error type every provider variant throws.
///
/// [message] never contains a token, a header value or a credential, so it is
/// safe to log and to show.
class GravixTokenException implements Exception {
  const GravixTokenException(this.reason, this.message, {this.statusCode, this.cause});

  final GravixTokenErrorReason reason;
  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => 'GravixTokenException(${reason.name}${statusCode == null ? '' : ' $statusCode'}): $message';
}

/// Everything a join needs, as the gateway returned it.
@immutable
class GravixJoinCredentials {
  const GravixJoinCredentials({
    required this.token,
    required this.url,
    this.regionEntries = const <GravixRegionUrl>[],
    this.expiresAt,
    required this.fetchedAt,
    this.fromCache = false,
    this.raw = const <String, dynamic>{},
  });

  /// The join JWT.
  final String token;

  /// The pinned signalling url (`url` in the gateway response).
  final String url;

  /// `region_urls` from the response — region slug, signalling url and the
  /// gateway's `probe_url` — exactly what `connect(regionEntries: …)` takes.
  /// Empty when the backend sent none, which makes `connect` skip the race.
  final List<GravixRegionUrl> regionEntries;

  /// When the token stops being usable, as far as the client can tell: the
  /// JWT's `exp`, else `fetchedAt + expires_in`, else `fetchedAt +
  /// unknownExpiryTtl`. Null only for a literal whose expiry is unknowable.
  final DateTime? expiresAt;

  /// When this value came off the wire (or was handed over, for a literal).
  final DateTime fetchedAt;

  /// True when this exact value was served from the provider's cache, i.e. the
  /// call cost no round trip. Goes into the join timeline as `tokenFromCache`.
  final bool fromCache;

  /// The whole response body, for fields this SDK does not model (`home`,
  /// `room`, `identity`, `expires_in`, …).
  final Map<String, dynamic> raw;

  /// Bare signalling urls of [regionEntries].
  List<String> get regionUrls => [for (final e in regionEntries) e.url];

  GravixJoinCredentials _servedFromCache() => GravixJoinCredentials(
    token: token,
    url: url,
    regionEntries: regionEntries,
    expiresAt: expiresAt,
    fetchedAt: fetchedAt,
    fromCache: true,
    raw: raw,
  );

  /// True when the token has at least [minRemaining] of life left at [now] (and
  /// its `nbf`, if any, has passed). A join takes a second or two and the SFU
  /// validates the token when the WebSocket opens, so a token with three
  /// seconds left is a join that fails at the last step.
  bool isUsableAt(DateTime now, {Duration minRemaining = const Duration(seconds: 60)}) {
    final notBefore = _jwtPayload(token)?.notBefore;
    if (notBefore != null && now.toUtc().isBefore(notBefore)) return false;
    final exp = expiresAt;
    if (exp == null) return true;
    return exp.difference(now) >= minRemaining;
  }

  /// The upstream token-source shape, for interop. LOSSY: it has no slot for
  /// [regionEntries] — never feed the result back into a Gravix connect.
  TokenSourceResponse toTokenSourceResponse() => TokenSourceResponse(
    serverUrl: url,
    participantToken: token,
    participantName: raw['name'] is String ? raw['name'] as String : null,
    roomName: raw['room'] is String ? raw['room'] as String : null,
  );

  /// Parses a token response. Accepts, in this order:
  ///  1. the gateway `/v1/token` shape `{token, url, region_urls, expires_in?}`
  ///     (`jwt` is accepted for `token`, as the example app always did);
  ///  2. a Parse Cloud Function envelope `{result: <that shape>}` — Parse wraps
  ///     every cloud-function return value this way, and making every tenant
  ///     unwrap it by hand is how the region list gets dropped;
  ///  3. the upstream token-source shape `{participant_token, server_url}`.
  ///
  /// Throws [GravixTokenException] (`malformed`) when there is no token or url.
  factory GravixJoinCredentials.fromResponse(
    Map<String, dynamic> response, {
    DateTime? now,
    Duration unknownExpiryTtl = const Duration(minutes: 5),
  }) {
    var body = response;
    final result = body['result'];
    if (_stringAt(body, const ['token', 'jwt', 'participant_token', 'participantToken']) == null && result is Map) {
      body = Map<String, dynamic>.from(result);
    }
    final token = _stringAt(body, const ['token', 'jwt', 'participant_token', 'participantToken']);
    final url = _stringAt(body, const ['url', 'server_url', 'serverUrl']);
    if (token == null || url == null) {
      // Key NAMES only. The body may carry a token under a spelling this parser
      // does not know, and an error message ends up in logs.
      throw GravixTokenException(
        GravixTokenErrorReason.malformed,
        'token response has no ${token == null ? '"token"' : '"url"'} (keys: ${body.keys.join(', ')})',
      );
    }
    final fetchedAt = now ?? DateTime.now();
    DateTime? expiresAt = _jwtPayload(token)?.expiresAt;
    if (expiresAt == null) {
      final expiresIn = body['expires_in'];
      expiresAt = fetchedAt.add(
        expiresIn is num && expiresIn > 0 ? Duration(seconds: expiresIn.floor()) : unknownExpiryTtl,
      );
    }
    return GravixJoinCredentials(
      token: token,
      url: url,
      regionEntries: gravixRegionEntriesFrom(body),
      expiresAt: expiresAt,
      fetchedAt: fetchedAt,
      raw: Map<String, dynamic>.unmodifiable(body),
    );
  }

  // Deliberately no token in toString: this object gets debugPrinted.
  @override
  String toString() =>
      'GravixJoinCredentials(url: $url, regions: ${regionEntries.length}, expiresAt: $expiresAt, fromCache: $fromCache)';
}

String? _stringAt(Map<String, dynamic> body, List<String> keys) {
  for (final key in keys) {
    final value = body[key];
    if (value is String && value.isNotEmpty) return value;
  }
  return null;
}

/// The vendored upstream JWT reader, made total. It returns null for a
/// non-JWT, but only catches its own exception type; an opaque token that is
/// not even three dot-separated parts can surface a FormatException instead,
/// and a token provider must not fall over on a token it merely cannot read.
GravixRtcJwtPayload? _jwtPayload(String token) {
  try {
    return GravixRtcJwtPayload.fromToken(token);
  } catch (_) {
    return null;
  }
}

/// (b) — the app's own fetch. Return the gateway-shaped response map (the
/// gateway's `/v1/token` JSON body) or a ready
/// [GravixJoinCredentials].
typedef GravixTokenCallback = FutureOr<Object> Function(GravixTokenRequest request);

/// See the file comment. Construct ONE per app (or per logged-in user) and keep
/// it: the cache lives in the instance, and a provider rebuilt for every join
/// caches nothing.
class GravixTokenProvider implements TokenSourceConfigurable {
  GravixTokenProvider._(
    this._load, {
    required this.timeout,
    required this.minRemainingValidity,
    required this.unknownExpiryTtl,
    required this.maxEntries,
    required bool refetchable,
    DateTime Function()? now,
  }) : _refetchable = refetchable,
       _now = now ?? DateTime.now;

  /// Default request timeout. Long enough for a cold TLS handshake to a far
  /// region over mobile data plus a slow backend, short enough that a stalled
  /// one turns into an error the UI can show while the user is still looking.
  static const Duration defaultTimeout = Duration(seconds: 8);

  /// (a) A token the app already holds. Never refetches; [getCredentials]
  /// throws `expired` once the token's own `exp` is inside
  /// [minRemainingValidity].
  factory GravixTokenProvider.literal({
    required String token,
    required String url,
    List<GravixRegionUrl> regionEntries = const <GravixRegionUrl>[],
    Duration minRemainingValidity = Duration.zero,
    @visibleForTesting DateTime Function()? now,
  }) {
    final clock = now ?? DateTime.now;
    final fixed = GravixJoinCredentials(
      token: token,
      url: url,
      regionEntries: List<GravixRegionUrl>.unmodifiable(regionEntries),
      // Only what the token itself says. A pasted token with no readable exp is
      // taken at face value: the SFU is the judge, and inventing a TTL here
      // would refuse a join the server would have accepted.
      expiresAt: _jwtPayload(token)?.expiresAt,
      fetchedAt: clock(),
    );
    return GravixTokenProvider._(
      (_) async => fixed,
      timeout: defaultTimeout,
      minRemainingValidity: minRemainingValidity,
      unknownExpiryTtl: const Duration(minutes: 5),
      maxEntries: 1,
      refetchable: false,
      now: now,
    );
  }

  /// (b) The app fetches; the provider adds the timeout, the cache and the
  /// in-flight de-duplication.
  factory GravixTokenProvider.callback(
    GravixTokenCallback callback, {
    Duration timeout = defaultTimeout,
    Duration minRemainingValidity = const Duration(seconds: 60),
    Duration unknownExpiryTtl = const Duration(minutes: 5),
    int maxEntries = 16,
    @visibleForTesting DateTime Function()? now,
  }) {
    final clock = now ?? DateTime.now;
    return GravixTokenProvider._(
      (request) async {
        final Object answer;
        try {
          answer = await callback(request);
        } on GravixTokenException {
          rethrow;
        } catch (e) {
          throw GravixTokenException(
            GravixTokenErrorReason.callback,
            'token callback threw ${e.runtimeType}',
            cause: e,
          );
        }
        if (answer is GravixJoinCredentials) return answer;
        if (answer is Map) {
          return GravixJoinCredentials.fromResponse(
            Map<String, dynamic>.from(answer),
            now: clock(),
            unknownExpiryTtl: unknownExpiryTtl,
          );
        }
        throw GravixTokenException(
          GravixTokenErrorReason.malformed,
          'token callback returned ${answer.runtimeType}; expected a Map or GravixJoinCredentials',
        );
      },
      timeout: timeout,
      minRemainingValidity: minRemainingValidity,
      unknownExpiryTtl: unknownExpiryTtl,
      maxEntries: maxEntries,
      refetchable: true,
      now: now,
    );
  }

  /// (c) The tenant's own backend. The SDK POSTs [GravixTokenRequest.toJson]
  /// as JSON with [headers] (the app's session — a cookie, a bearer token, a
  /// Parse session token; NEVER the gateway secret) and expects the gateway's
  /// `/v1/token` response back. See [GravixJoinCredentials.fromResponse] for
  /// the accepted shapes.
  factory GravixTokenProvider.endpoint(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration timeout = defaultTimeout,
    Duration minRemainingValidity = const Duration(seconds: 60),
    Duration unknownExpiryTtl = const Duration(minutes: 5),
    int maxEntries = 16,
    http.Client? client,
    @visibleForTesting DateTime Function()? now,
  }) {
    final clock = now ?? DateTime.now;
    return GravixTokenProvider._(
      (request) async {
        final httpClient = client ?? http.Client();
        final http.Response response;
        try {
          response = await httpClient.post(
            url,
            headers: <String, String>{'Content-Type': 'application/json', ...headers},
            body: jsonEncode(request.toJson()),
          );
        } catch (e) {
          // The exception text of a failed socket can carry the full uri, which
          // for some tenants carries a key in the query string. Type only.
          throw GravixTokenException(
            GravixTokenErrorReason.callback,
            'token endpoint request failed (${e.runtimeType})',
            cause: e,
          );
        } finally {
          // An injected client belongs to whoever injected it.
          if (client == null) httpClient.close();
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw GravixTokenException(
            GravixTokenErrorReason.http,
            'token endpoint answered ${response.statusCode}',
            statusCode: response.statusCode,
          );
        }
        final Object? decoded;
        try {
          decoded = jsonDecode(response.body);
        } catch (e) {
          throw GravixTokenException(GravixTokenErrorReason.malformed, 'token endpoint did not answer JSON', cause: e);
        }
        if (decoded is! Map) {
          throw const GravixTokenException(
            GravixTokenErrorReason.malformed,
            'token endpoint answered JSON that is not an object',
          );
        }
        return GravixJoinCredentials.fromResponse(
          Map<String, dynamic>.from(decoded),
          now: clock(),
          unknownExpiryTtl: unknownExpiryTtl,
        );
      },
      timeout: timeout,
      minRemainingValidity: minRemainingValidity,
      unknownExpiryTtl: unknownExpiryTtl,
      maxEntries: maxEntries,
      refetchable: true,
      now: now,
    );
  }

  /// Adapter: any vendored upstream token source (`EndpointTokenSource`,
  /// `CustomTokenSource`, `CachingTokenSource`, a `TokenSourceFixed`, …).
  ///
  /// The upstream response shape has no region list, so credentials from this
  /// variant always have empty [GravixJoinCredentials.regionEntries] and the
  /// probe race never runs. Use it to keep an existing upstream-style token
  /// server working, not for a multi-region deployment.
  factory GravixTokenProvider.fromTokenSource(
    Object source, {
    Duration timeout = defaultTimeout,
    Duration minRemainingValidity = const Duration(seconds: 60),
    Duration unknownExpiryTtl = const Duration(minutes: 5),
    int maxEntries = 16,
    @visibleForTesting DateTime Function()? now,
  }) {
    if (source is! TokenSourceConfigurable && source is! TokenSourceFixed) {
      throw ArgumentError.value(source, 'source', 'must be a TokenSourceConfigurable or a TokenSourceFixed');
    }
    return GravixTokenProvider.callback(
      (request) async {
        final TokenSourceResponse response = source is TokenSourceConfigurable
            ? await source.fetch(
                TokenRequestOptions(
                  roomName: request.room,
                  participantIdentity: request.identity,
                  participantName: request.name.isEmpty ? null : request.name,
                ),
              )
            : await (source as TokenSourceFixed).fetch();
        return <String, dynamic>{'token': response.participantToken, 'url': response.serverUrl};
      },
      timeout: timeout,
      minRemainingValidity: minRemainingValidity,
      unknownExpiryTtl: unknownExpiryTtl,
      maxEntries: maxEntries,
      now: now,
    );
  }

  final Future<GravixJoinCredentials> Function(GravixTokenRequest request) _load;
  final bool _refetchable;
  final DateTime Function() _now;

  /// Upper bound on one token request, callback variants included.
  final Duration timeout;

  /// A cached token is reused only while it has at least this much life left.
  final Duration minRemainingValidity;

  /// Lifetime assumed for a token that is not a readable JWT and came with no
  /// `expires_in`. Short on purpose: guessing long serves a dead token.
  final Duration unknownExpiryTtl;

  /// Cache bound (least-recently-used eviction). A room list can prewarm a
  /// handful of rooms; it must not be able to grow a map without limit for the
  /// life of the process.
  final int maxEntries;

  // Insertion-ordered; re-inserting on a hit makes "first key" the LRU entry.
  final LinkedHashMap<String, GravixJoinCredentials> _cache = LinkedHashMap<String, GravixJoinCredentials>();
  final Map<String, Future<GravixJoinCredentials>> _inflight = <String, Future<GravixJoinCredentials>>{};

  /// The token for [request]: from the cache when it is still usable (no I/O,
  /// no round trip), otherwise fetched — once, however many callers are
  /// waiting — under [timeout].
  ///
  /// Throws [GravixTokenException]. A failed fetch is never cached.
  Future<GravixJoinCredentials> getCredentials(GravixTokenRequest request, {bool forceRefresh = false}) {
    final key = request.cacheKey;
    if (!forceRefresh) {
      final hit = peek(request);
      if (hit != null) return Future<GravixJoinCredentials>.value(hit);
      // Two screens asking for the same room at once (the list prewarming while
      // the user taps) must be ONE request: the second would otherwise race the
      // first and, on a metered backend, bill twice.
      final pending = _inflight[key];
      if (pending != null) return pending;
    }
    final future = _fetch(request);
    _inflight[key] = future;
    // whenComplete returns a NEW future that carries the same error; without a
    // handler on it a failed fetch is reported twice, once as unhandled.
    unawaited(
      future
          .whenComplete(() {
            if (identical(_inflight[key], future)) _inflight.remove(key);
          })
          .then<void>((_) {}, onError: (Object _) {}),
    );
    return future;
  }

  Future<GravixJoinCredentials> _fetch(GravixTokenRequest request) async {
    final GravixJoinCredentials fresh;
    try {
      fresh = await _load(request).timeout(timeout);
    } on TimeoutException {
      throw GravixTokenException(GravixTokenErrorReason.timeout, 'no token within ${timeout.inMilliseconds}ms');
    }
    if (!_refetchable) {
      if (!fresh.isUsableAt(_now(), minRemaining: minRemainingValidity)) {
        throw const GravixTokenException(
          GravixTokenErrorReason.expired,
          'the literal token has expired; a literal provider cannot fetch another',
        );
      }
      return fresh;
    }
    final key = request.cacheKey;
    _cache.remove(key);
    _cache[key] = fresh;
    while (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return fresh;
  }

  /// The cached credentials for [request] if they are still usable, else null.
  /// Never touches the network.
  GravixJoinCredentials? peek(GravixTokenRequest request) {
    final key = request.cacheKey;
    final held = _cache[key];
    if (held == null) return null;
    if (!held.isUsableAt(_now(), minRemaining: minRemainingValidity)) return null;
    _cache.remove(key);
    _cache[key] = held; // most recently used
    return held._servedFromCache();
  }

  /// The last credentials seen for [request], EVEN IF EXPIRED. The token in it
  /// must not be used; its `url` and `regionEntries` are what a parallel
  /// token+probe start needs (the region list outlives the token by hours).
  GravixJoinCredentials? lastKnown(GravixTokenRequest request) => _cache[request.cacheKey];

  /// Drops the cached token for [request], or every cached token.
  void invalidate([GravixTokenRequest? request]) {
    if (request == null) {
      _cache.clear();
    } else {
      _cache.remove(request.cacheKey);
    }
  }

  /// Upstream `TokenSourceConfigurable`. `roomName` → room,
  /// `participantIdentity` → identity, `participantName` → name. The upstream
  /// options have no publish flag, so this path always asks for a listener
  /// token, and the upstream response drops the region list: prefer
  /// [getCredentials].
  @override
  Future<TokenSourceResponse> fetch(TokenRequestOptions options) async {
    final credentials = await getCredentials(
      GravixTokenRequest(
        room: options.roomName ?? '',
        identity: options.participantIdentity ?? '',
        name: options.participantName ?? '',
      ),
    );
    return credentials.toTokenSourceResponse();
  }
}
