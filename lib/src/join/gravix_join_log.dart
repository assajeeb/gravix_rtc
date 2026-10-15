// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixJoinLog (0.4.19): one secret-free line per step of a fast join, so a
// device log shows where a join spent its time or why it stopped (owner
// 2026-10-15: "properly log every step to catch the bugs").
//
//   [GravixJoin] <step> key=<room>|u<id hash>|pub=<bool> [+<ms since tap>ms] [<detail>]
//
// e.g.
//   [GravixJoin] prepare key=r1|u5c1e2a07|pub=false +0ms new
//   [GravixJoin] tokenOk key=r1|u5c1e2a07|pub=false +312ms via=fetched
//   [GravixJoin] urlChosen key=r1|u5c1e2a07|pub=false +313ms region=dac1 source=measured rtt=31 host=dac1.example.com
//   [GravixJoin] warmFail key=r9|u5c1e2a07|pub=false role=visible rank=0 not warmed (callback, cause OldAppRoomException)
//
// Never in a line: a token, a JWT, a url's path or query (hosts only), an error
// message (types and reasons only), a full identity (a short stable hash).
// Volume: a few lines per join, so it is on in release too (info); debug and
// profile builds add the per-rebuild lines (verbose: warm starts, standby
// reuse, defensive catches). Lines go to [GravixJoinLog.sink] (default
// debugPrint) or to the `log:` sink of a GravixJoin / GravixStandbyPool /
// GravixRejoinPolicy.

import 'package:flutter/foundation.dart';

import '../backend/gravix_token_provider.dart' show GravixTokenException, GravixTokenRequest;

/// How much [GravixJoinLog] writes.
enum GravixJoinLogLevel {
  /// Nothing.
  off,

  /// One line per join step (the default in release builds).
  info,

  /// Also the lines a list rebuild or a pool tick repeats (warm starts,
  /// standby reuse) and the defensive catches (the default in debug / profile).
  verbose,
}

/// Where a line goes.
typedef GravixJoinLogSink = void Function(String line);

/// See the file comment.
abstract final class GravixJoinLog {
  /// The stable prefix of every line (grep for it).
  static const String prefix = '[GravixJoin]';

  /// The default level: [GravixJoinLogLevel.info] in release, verbose otherwise.
  static GravixJoinLogLevel get defaultLevel => kReleaseMode ? GravixJoinLogLevel.info : GravixJoinLogLevel.verbose;

  /// The current level (all GravixJoin / GravixPrejoin / GravixStandbyPool /
  /// GravixRejoinPolicy lines).
  static GravixJoinLogLevel level = defaultLevel;

  /// On ([defaultLevel]) or off.
  static bool get enabled => level != GravixJoinLogLevel.off;
  static set enabled(bool on) => level = on ? defaultLevel : GravixJoinLogLevel.off;

  /// Where the lines go when the object writing them has no sink of its own:
  /// set it to send them to the app's own logger.
  static GravixJoinLogSink sink = _debugPrint;

  static void _debugPrint(String line) => debugPrint(line);

  /// Whether a line of level [at] is written now.
  static bool writes(GravixJoinLogLevel at) => at != GravixJoinLogLevel.off && level.index >= at.index;

  /// Writes one step line (see the file comment) to [to] (default [sink]).
  /// [key]: a session key (room \0 identity \0 publish right, as
  /// `GravixPrejoin.sessionKey`), or [request]. Never throws.
  static void step(
    String step, {
    String? key,
    GravixTokenRequest? request,
    Duration? sinceTap,
    String? detail,
    GravixJoinLogLevel at = GravixJoinLogLevel.info,
    GravixJoinLogSink? to,
  }) {
    if (!writes(at)) return;
    try {
      (to ?? sink)(
        format(
          step,
          key: key ?? (request == null ? null : '${request.room}\u0000${request.identity}\u0000${request.canPublish}'),
          sinceTap: sinceTap,
          detail: detail,
        ),
      );
    } catch (_) {
      // a log sink must never cost a join
    }
  }

  /// The line [step] writes (pure; scrubbed).
  static String format(String step, {String? key, Duration? sinceTap, String? detail}) {
    final b = StringBuffer('$prefix $step key=${key == null ? '-' : keyOf(key)}');
    if (sinceTap != null) b.write(' +${sinceTap.inMilliseconds}ms');
    if (detail != null && detail.isNotEmpty) b.write(' ${scrub(detail)}');
    return b.toString();
  }

  /// `<room>|u<hash>|pub=<bool>` of a session key; the identity as a short
  /// stable hash ([shortId]).
  static String keyOf(String sessionKey) {
    final p = sessionKey.split('\u0000');
    if (p.length != 3) return scrub(sessionKey.replaceAll('\u0000', '|'));
    return '${scrub(p[0])}|${shortId(p[1])}|pub=${p[2]}';
  }

  /// A short stable id for [identity]: `u` + FNV-1a 32 bit, hex (the same on
  /// every device and run, so two phones' lines can be matched).
  static String shortId(String identity) {
    var h = 0x811c9dc5;
    for (final c in identity.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return 'u${h.toRadixString(16).padLeft(8, '0')}';
  }

  /// The host of a url (never its path or query); `-` when there is none.
  static String host(String? url) {
    if (url == null || url.trim().isEmpty) return '-';
    try {
      final h = Uri.parse(url.trim()).host;
      return h.isEmpty ? '-' : h;
    } catch (_) {
      return '?';
    }
  }

  /// What a line says about an error: a [GravixTokenException]'s reason and the
  /// type of its cause, any other error's type. Never a message (a token
  /// callback's error text can carry a url, a header or a token).
  static String errorOf(Object e) {
    if (e is GravixTokenException) {
      final cause = e.cause;
      return cause == null ? e.reason.name : '${e.reason.name}, cause ${cause.runtimeType}';
    }
    return '${e.runtimeType}';
  }

  static final RegExp _jwt = RegExp(r'eyJ[A-Za-z0-9_\-]*(\.[A-Za-z0-9_\-]*)*');
  static final RegExp _secretParam = RegExp(
    r'((?:access_token|token|key|secret|sig|signature)=)[^&\s]+',
    caseSensitive: false,
  );

  /// Defence in depth on every detail: a JWT or a secret query parameter that
  /// slipped into a detail never reaches the sink.
  static String scrub(String s) =>
      s.replaceAll(_jwt, '<jwt>').replaceAllMapped(_secretParam, (m) => '${m.group(1)}<redacted>');
}
