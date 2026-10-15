// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixRoomRefused (0.4.19): a room this SDK cannot join, e.g. a live room an
// old app build hosts on the retired server (owner 2026-10-15: "all the apps'
// rooms still exist on the old LiveKit -- handle that also, not to count"). A
// refusal is not a failure: GravixJoin remembers the room for a while instead
// of warming it again on every list refresh, logs `warmRefused` / `refused`
// (not `warmFail` / `connectFail`), and GravixRejoinPolicy does not count it as
// a failed attempt. See doc/FAST_JOIN.md "Rooms this SDK cannot join (old
// servers)".

import '../backend/gravix_token_provider.dart' show GravixTokenException;
import '../rtc_core/src/exceptions.dart' show RetiredServerException;

/// Thrown by an app's token callback (or its connect hook) for a room this SDK
/// cannot join, e.g. one hosted by an old app version on another server:
///
/// ```dart
/// GravixTokenProvider.callback((r) async {
///   final answer = await myBackend.token(r);
///   if (answer.hostAppOutdated) throw const GravixRoomRefused('host_app_outdated');
///   return answer.json;
/// });
/// ```
///
/// The provider wraps it like any callback exception (a [GravixTokenException]
/// with `reason: callback` and this as its `cause`); GravixJoin and
/// GravixRejoinPolicy unwrap it. An app that keeps its own exception type passes
/// `GravixJoin(isRefusal: (e) => e is MyOldAppRoomException)` instead.
class GravixRoomRefused implements Exception {
  const GravixRoomRefused([this.reason]);

  /// The app's short code for why (e.g. `host_app_outdated`), for the app's own
  /// UI. Log lines name only the type, never this.
  final String? reason;

  /// The app's own error behind [e]: the cause inside a [GravixTokenException]
  /// (the token callback's exception), else [e] itself.
  static Object unwrap(Object e) {
    var cur = e;
    for (var i = 0; i < 4 && cur is GravixTokenException; i++) {
      final cause = cur.cause;
      if (cause == null) break;
      cur = cause;
    }
    return cur;
  }

  /// The built-in refusals, after [unwrap]: a [RetiredServerException] (the
  /// token answer or the connect named a retired Gravix server) or a
  /// [GravixRoomRefused].
  static bool isBuiltIn(Object e) {
    final u = unwrap(e);
    return u is RetiredServerException || u is GravixRoomRefused;
  }

  /// [e] is a refusal: built in ([isBuiltIn]) or as the app's [isRefusal] says
  /// of the unwrapped error. Never throws: an [isRefusal] that throws counts as
  /// "not a refusal".
  static bool classify(Object e, [bool Function(Object unwrappedError)? isRefusal]) {
    if (isBuiltIn(e)) return true;
    if (isRefusal == null) return false;
    try {
      return isRefusal(unwrap(e));
    } catch (_) {
      return false;
    }
  }

  @override
  String toString() => reason == null ? 'GravixRoomRefused' : 'GravixRoomRefused($reason)';
}
