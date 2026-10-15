// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixPubLog (0.4.19, MUSIC-SDP): one secret-free line per publisher
// negotiation step, so a device log shows which offer was made from which
// state and why libwebrtc refused one (owner 2026-10-15: "properly log every
// step to catch the bugs").
//
//   [GravixPub] <step> pc=<label> [<detail>]
//
// e.g.
//   [GravixPub] trackPublish pc=pub#2 kind=audio source=microphone
//   [GravixPub] offerCreate pc=pub#2 restart=false mlines=audio:0/sendonly,application:1,audio:2/sendonly
//   [GravixPub] setLocal pc=pub#2 ok munged=false mlines=audio:0/sendonly,application:1,audio:2/sendonly
//   [GravixPub] offerWait pc=pub#2 restart=false (an offer is being created)
//   [GravixPub] offerDefer pc=pub#2 have-local-offer: replayed after the answer
//   [GravixPub] remoteSet pc=pub#2 answer ok replay=true mlines=audio:0/recvonly,application:1
//
// Never in a line: an SDP body (ice-pwd / fingerprints), a token, an error's
// free text beyond libwebrtc's own fixed reason (shortened). An m-line list is
// "<kind>:<mid>/<direction>" per section, in order; "/rejected" = port 0.

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Where a [GravixPubLog] line goes.
typedef GravixPubLogSink = void Function(String line);

/// See the file comment.
abstract final class GravixPubLog {
  /// The stable prefix of every line (grep for it).
  static const String prefix = '[GravixPub]';

  /// On by default (a few lines per negotiation; publishes are rare).
  static bool enabled = true;

  /// Where the lines go (default debugPrint): set it to the app's own logger.
  static GravixPubLogSink sink = _debugPrint;

  static void _debugPrint(String line) => debugPrint(line);

  /// Writes one step line. Never throws.
  static void step(String step, {String? pc, String? detail}) {
    if (!enabled) return;
    try {
      final b = StringBuffer(prefix)
        ..write(' ')
        ..write(step);
      if (pc != null) b.write(' pc=$pc');
      if (detail != null && detail.isNotEmpty) b.write(' $detail');
      sink(b.toString());
    } catch (_) {
      // a log line must never break a negotiation
    }
  }

  /// The m-sections of [sdp] in order, as `kind:mid/direction` (see the file
  /// comment). Reads only m=, a=mid and direction lines.
  static String mlines(String? sdp) {
    if (sdp == null || sdp.isEmpty) return '-';
    final out = <String>[];
    String? kind;
    String? mid;
    String? dir;
    var rejected = false;
    void flush() {
      if (kind == null) return;
      final d = rejected ? 'rejected' : (kind == 'application' ? null : (dir ?? 'sendrecv'));
      out.add('$kind:${mid ?? '?'}${d == null ? '' : '/$d'}');
    }

    for (final raw in sdp.split('\n')) {
      final line = raw.trimRight();
      if (line.startsWith('m=')) {
        flush();
        final parts = line.substring(2).split(' ');
        kind = parts.isNotEmpty ? parts[0] : '?';
        rejected = parts.length > 1 && parts[1] == '0';
        mid = null;
        dir = null;
      } else if (kind != null && line.startsWith('a=mid:')) {
        mid = line.substring(6);
      } else if (kind != null &&
          (line == 'a=sendrecv' || line == 'a=sendonly' || line == 'a=recvonly' || line == 'a=inactive')) {
        dir = line.substring(2);
      }
    }
    flush();
    return out.join(',');
  }

  /// [transceiver]'s mid, '-' when it has none (or it cannot be read). Never throws.
  static String midOf(rtc.RTCRtpTransceiver? transceiver) {
    try {
      final String? mid = transceiver?.mid;
      return mid != null && mid.isNotEmpty ? mid : '-';
    } catch (_) {
      return '-';
    }
  }

  static final RegExp _sdpStart = RegExp(r'v=0\r?\n|\r?\nm=|\r?\na=|^a=', multiLine: true);
  static final RegExp _secretAttr = RegExp(
    r'(ice-pwd|ice-ufrag|fingerprint|crypto)(?::|\s)\s*[^\s,;)\]]+(?:\s+[0-9A-Fa-f:]{8,})?',
    caseSensitive: false,
  );

  /// [error] as text that is safe for a log line: an SDP body in it is cut off
  /// (`<sdp omitted>`), ice-pwd / ice-ufrag / fingerprint / crypto values are
  /// redacted, line breaks folded, the length capped at [max]. Never throws.
  static String safeError(Object? error, {int max = 300}) {
    try {
      var s = '$error';
      final start = _sdpStart.firstMatch(s);
      if (start != null) s = '${s.substring(0, start.start).trimRight()} <sdp omitted>';
      s = s.replaceAllMapped(_secretAttr, (m) => '${m[1]}:<redacted>');
      s = s.replaceAll(RegExp(r'[\r\n]+'), ' ');
      return s.length > max ? '${s.substring(0, max)}...' : s;
    } catch (_) {
      return error.runtimeType.toString();
    }
  }

  /// A session description as a log value: its type and m-line list, never its body.
  static String describe(String? type, String? sdp) => '${type ?? '-'} mlines=${mlines(sdp)}';

  /// libwebrtc's fixed reason in [error], shortened (never an SDP).
  static String reason(Object error) {
    final s = '$error';
    if (s.contains('order of m-lines')) return 'm-line-order';
    if (s.contains('wrong state')) return 'wrong-state';
    if (s.contains('Incompatible send direction')) return 'send-direction';
    if (s.contains('codec collision') || s.contains('payload type')) return 'payload-type';
    return error.runtimeType.toString();
  }
}
