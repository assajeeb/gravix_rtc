// Copyright Gravity Compile, Inc. Apache 2.0.

import 'package:flutter/foundation.dart';

/// What `GravixRoomService.prewarm` managed to do, and what each part cost.
///
/// It is a report and not a bool because a prewarm never throws (a failed
/// prewarm must not be able to break the join that follows — the join simply
/// pays for whatever was not warmed), so this is the only place a failure can be
/// seen. The milliseconds here were spent BEFORE the tap; they are exactly what
/// the tap no longer pays.
@immutable
class GravixPrewarmReport {
  const GravixPrewarmReport({
    required this.total,
    this.token,
    this.tokenFromCache,
    this.region,
    this.regionFromCache,
    this.chosenUrl,
    this.prepareConnection,
    this.audioSession,
    this.micPermissionGranted,
    this.errors = const <String>[],
  });

  final Duration total;

  /// Token step; null when it failed (see [errors]).
  final Duration? token;
  final bool? tokenFromCache;

  /// Region decision; null when not asked for or no regions were offered.
  final Duration? region;
  final bool? regionFromCache;

  /// The signalling url the later join is expected to use.
  final String? chosenUrl;

  /// The DNS/TLS warm-up request to [chosenUrl]'s host.
  final Duration? prepareConnection;
  final Duration? audioSession;
  final bool? micPermissionGranted;

  /// `step: ErrorType` per failed step. Types only — never a token or a url
  /// with a query string.
  final List<String> errors;

  bool get ok => errors.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'totalMs': total.inMilliseconds,
    'tokenMs': token?.inMilliseconds,
    'tokenFromCache': tokenFromCache,
    'regionMs': region?.inMilliseconds,
    'regionFromCache': regionFromCache,
    'chosenUrl': chosenUrl,
    'prepareConnectionMs': prepareConnection?.inMilliseconds,
    'audioSessionMs': audioSession?.inMilliseconds,
    'micPermissionGranted': micPermissionGranted,
    'errors': errors,
  };

  @override
  String toString() => 'GravixPrewarmReport(${toJson()})';
}
