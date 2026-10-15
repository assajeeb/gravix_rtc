// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixJoin (0.4.19): fast joining with a few calls, for an app that drives the
// core Room. It puts together what every app had written by hand around
// Room.connect -- the token cache, the standby pre-connects, the tap-time
// prejoin, one session at a time and the room switch:
//
//   final join = GravixJoin(tokenProvider: GravixTokenProvider.callback(myTokenCall, reuse: GravixTokenReuse.fastJoin));
//   join.warm(request, role: GravixStandbyRole.visible, rank: i);   // a room on screen
//   join.warm(request);                                              // finger-down (touched)
//   join.prepare(request, createRoom: () => Room(roomOptions: o));   // the tap: connects now
//   final room = await join.attach(request);                         // the room screen
//   final room = await join.attachOrThrow(request, hooks: myHooks);  // ... throwing the app's own token error
//   join.switchTo(next, beforeConnect: closeOldScreen);              // room to room
//   join.adopt(guestRequest, myRoom);                                // the app's own reconnect (role change)
//   await join.leave();                                              // the real exit
//   join.isRefused(request);                                         // a room this SDK cannot join (a badge)
//
// An app that keeps its own connect passes it as one GravixJoinHooks value
// (`hooks:`) to prepare / attach / attachResult / attachOrThrow / switchTo /
// adopt, so the tap's join and a cold join from the room screen run the same
// steps (doc/FAST_JOIN.md "An app's join layer").
//
// Nothing here changes Room.connect, GravixRoomService or the token provider
// for an app that does not use it.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backend/gravix_token_provider.dart';
import '../connect/gravix_standby.dart';
import '../rtc_core/src/core/gravix_join_camera.dart';
import '../rtc_core/src/core/gravix_join_mic.dart';
import '../rtc_core/src/core/room.dart';
import '../rtc_core/src/exceptions.dart' show RetiredServerException;
import '../rtc_core/src/options.dart';
import '../rtc_core/src/support/websocket/standby_types.dart';
import '../rtc_core/src/types/other.dart' show ConnectionState;
import 'gravix_join_event.dart';
import 'gravix_join_hooks.dart';
import 'gravix_join_log.dart';
import 'gravix_join_url.dart';
import 'gravix_prejoin.dart';
import 'gravix_room_refused.dart';
import 'gravix_standby_pool.dart';

/// The app's beforeConnect of a room switch: its own work that must be done
/// before the new room connects (e.g. the old screen closed). False cancels the
/// switch (the old session is already left by then).
typedef GravixSwitchBeforeConnect = Future<bool> Function();

/// What `GravixJoin.attachResult` found: the room screen's join, never thrown.
@immutable
class GravixAttach {
  const GravixAttach({required this.room, required this.handle, required this.connectedBeforeAttach});

  /// The connected Room, or null: the join failed ([error]) or ended
  /// (`handle.ended`, e.g. [GravixPrejoinEndReason.neverShown]).
  final Room? room;

  /// The session's handle (`ended`, `error`, `markShown`, `leave`).
  final GravixPrejoin handle;

  /// The connect had finished before the screen attached: the Room's
  /// participant / track events of the connect went out before the screen
  /// bound its listeners (they are not replayed): read
  /// `room.remoteParticipants` now.
  final bool connectedBeforeAttach;

  /// Why the join failed, as the app knows it: the token callback's own
  /// exception unwrapped from the provider's [GravixTokenException]
  /// ([GravixJoin.unwrapError]), or the connect's error. Null when it did not
  /// fail (connected, or ended without an error).
  Object? get error {
    final e = handle.error;
    return e == null ? null : GravixJoin.unwrapError(e);
  }

  /// [room] is connected or reconnecting ([GravixJoin.isLive]).
  bool get isLive => GravixJoin.isLive(room);

  @override
  String toString() => 'GravixAttach(${room == null ? 'no room' : 'room'} ${handle.state.name})';
}

/// See the file comment. One per app (or per signed-in user): the token cache
/// lives in [tokenProvider] and the standby memory here.
class GravixJoin {
  GravixJoin({
    required this.tokenProvider,
    GravixStandbyPool? standbyPool,
    Room Function()? createRoom,
    GravixPrejoinConnect? connect,
    GravixPrejoinLeave? leave,
    this.connectOptions,
    this.attachTimeout = GravixPrejoin.defaultAttachTimeout,
    this.abandonInBackground = true,
    bool bindStandbyLifecycle = true,
    this.onEvent,
    this.log,
    this.isRefusal,
    this.refusalMemo = defaultRefusalMemo,
    @visibleForTesting GravixStandbyState Function(String url, String token)? standbyState,
    @visibleForTesting DateTime Function()? now,
  }) : standbyPool = standbyPool ?? GravixStandbyPool.instance,
       _now = now ?? DateTime.now,
       _createRoom = createRoom,
       _connect = connect,
       _leave = leave,
       _standbyState = standbyState ?? GravixStandby.state {
    this.standbyPool.onOpened = _noteStandby;
    if (bindStandbyLifecycle) this.standbyPool.bindLifecycle();
  }

  /// Where the join tokens come from (and are cached: pass
  /// `reuse: GravixTokenReuse.fastJoin`).
  final GravixTokenProvider tokenProvider;

  /// The standby pre-connects [warm] feeds (default: [GravixStandbyPool.instance]).
  final GravixStandbyPool standbyPool;

  /// For the default connect (see [GravixPrejoin.start]).
  final ConnectOptions? connectOptions;

  /// See [GravixPrejoin.start]. The clock counts only the time the app is in
  /// front (paused while it is hidden / paused). Per call: the `attachTimeout`
  /// of [prepare] / [attach] / [attachResult] / [attachOrThrow].
  final Duration? attachTimeout;

  /// The default of the per-call `attachTimeout` ([prepare], [attach], ...):
  /// "the constructor's [attachTimeout]". Pass null for "never", or a duration.
  static const Duration inheritAttachTimeout = Duration(microseconds: -1);

  Duration? _attachTimeoutOf(Duration? perCall) => perCall == inheritAttachTimeout ? attachTimeout : perCall;

  /// See [GravixPrejoin.start].
  final bool abandonInBackground;

  /// Timing events of every join (and warm-ups).
  final void Function(GravixJoinEvent event)? onEvent;

  /// The app's own refusals: given the app's error unwrapped from the
  /// provider's [GravixTokenException] (e.g. `(e) => e is
  /// OldAppRoomException` for "a room hosted by an old app version"), true when
  /// the room cannot be joined with this SDK. Built in besides it: a
  /// [RetiredServerException] and a [GravixRoomRefused] (see [isRefusalError]).
  /// A refusal is not a failure: [warm] logs `warmRefused` (not `warmFail`) and
  /// remembers the room for [refusalMemo]; a join logs `refused` (not
  /// `connectFail`); event [GravixJoinEventKind.refused]. A predicate that
  /// throws counts as "not a refusal".
  final bool Function(Object unwrappedError)? isRefusal;

  /// How long a refused room is remembered ([isRefused]): [warm] for it does
  /// nothing meanwhile (no token call, no standby; one verbose `warmSkip
  /// reason=refused` line at most); [prepare] / [attach] still ask the token
  /// callback (the app may show its own message) and a refusal there renews it.
  /// A token for the room ends it, as does [forgetAll]. [Duration.zero]: never
  /// remembered.
  final Duration refusalMemo;

  /// The default [refusalMemo].
  static const Duration defaultRefusalMemo = Duration(seconds: 60);

  /// Where the step lines of this GravixJoin and its joins go ([GravixJoinLog]:
  /// `[GravixJoin] <step> key=...`; null: [GravixJoinLog.sink], debugPrint by
  /// default). The level is [GravixJoinLog.level].
  final GravixJoinLogSink? log;

  void _log(
    String step, {
    GravixTokenRequest? request,
    Duration? sinceTap,
    String? detail,
    GravixJoinLogLevel at = GravixJoinLogLevel.info,
  }) => GravixJoinLog.step(step, request: request, sinceTap: sinceTap, detail: detail, at: at, to: log);

  final Room Function()? _createRoom;
  final GravixPrejoinConnect? _connect;
  final GravixPrejoinLeave? _leave;
  final GravixStandbyState Function(String url, String token) _standbyState;
  final DateTime Function() _now;

  // room -> until when it is remembered as refused, and whether its warmSkip
  // line was written (one per memo)
  final Map<String, ({DateTime until, bool skipLogged})> _refusedRooms =
      <String, ({DateTime until, bool skipLogged})>{};
  static const int _maxRefusedRooms = 256;

  // token -> the url its standby is open at (the standby override)
  final Map<String, String> _standbyUrlByToken = <String, String>{};

  GravixPrejoin? _current;

  /// The session this GravixJoin started last, while it is live (not ended,
  /// its Room not gone: see [GravixPrejoinEndReason.roomGone]).
  GravixPrejoin? get current {
    final c = _current;
    if (c == null || c.state == GravixPrejoinState.ended) return null;
    return identical(GravixPrejoin.pendingFor(c.key), c) ? c : null;
  }

  /// The live handle for [request]'s session, if any.
  GravixPrejoin? pending(GravixTokenRequest request) => GravixPrejoin.pendingFor(GravixPrejoin.sessionKey(request));

  void _noteStandby(String url, String token) {
    if (token.isEmpty) return;
    _standbyUrlByToken.remove(token);
    _standbyUrlByToken[token] = url;
    while (_standbyUrlByToken.length > 16) {
      _standbyUrlByToken.remove(_standbyUrlByToken.keys.first);
    }
  }

  GravixJoinUrlChoice _choose(GravixJoinCredentials c) {
    var choice = gravixJoinUrl(c);
    final sb = _standbyUrlByToken[c.token];
    if (sb != null) {
      choice = choice.withStandby(
        standbyUrl: sb,
        pickedOpen: _standbyState(choice.url, c.token).isOpen,
        standbyOpen: _standbyState(sb, c.token).isOpen,
      );
    }
    return choice;
  }

  /// Ahead of a tap, no connect: the token for [request] into the cache and a
  /// standby pre-connect to the server it dials. [role]: the room under the
  /// finger (default), a room on screen at [rank], or the user's own region.
  /// [roomId] keys the pool's entry (default: the request's room). [activity]:
  /// false for a periodic refresh that is not the user's doing (e.g. the own
  /// room's token every 40 s): the token is fetched and the pool's entry
  /// updated, but it does not count as user activity, so it neither wakes an
  /// idle pool nor keeps it rotating (as [GravixStandbyPool.setOwnJoin]'s
  /// `activity`). Never throws; the credentials, or null when no token could
  /// be had.
  Future<GravixJoinCredentials?> warm(
    GravixTokenRequest request, {
    GravixStandbyRole role = GravixStandbyRole.touched,
    int rank = 0,
    String? roomId,
    bool activity = true,
  }) async {
    final what = 'role=${role.name} rank=$rank${activity ? '' : ' refresh'}';
    final memo = _refusalOf(request);
    if (memo != null) {
      // a room refused moments ago: no token call, no standby, one line per memo
      if (!memo.skipLogged) {
        _refusedRooms[request.room] = (until: memo.until, skipLogged: true);
        _log('warmSkip', request: request, detail: '$what reason=refused', at: GravixJoinLogLevel.verbose);
      }
      return null;
    }
    _log('warmStart', request: request, detail: what, at: GravixJoinLogLevel.verbose);
    try {
      final c = await tokenProvider.getCredentials(request);
      _clearRefused(request);
      final choice = _choose(c);
      final id = roomId ?? request.room;
      switch (role) {
        case GravixStandbyRole.touched:
          await standbyPool.touchCard(id, url: choice.url, token: c.token, rttMs: choice.rttMs, activity: activity);
        case GravixStandbyRole.visible:
          await standbyPool.noteCard(
            id,
            url: choice.url,
            token: c.token,
            rank: rank,
            rttMs: choice.rttMs,
            activity: activity,
          );
        case GravixStandbyRole.ownRegion:
          await standbyPool.setOwnJoin(url: choice.url, token: c.token, rttMs: choice.rttMs, activity: activity);
      }
      _log(
        'warmOk',
        request: request,
        detail: '$what via=${c.fromCache ? 'cached' : 'fetched'} host=${GravixJoinLog.host(choice.url)}',
      );
      _event(
        GravixJoinEventKind.warm,
        request,
        '${role.name} ${c.fromCache ? 'cached' : 'fetched'}${activity ? '' : ' refresh'}',
      );
      return c;
    } catch (e) {
      if (isRefusalError(e)) {
        _noteRefused(request);
        final type = '${unwrapError(e).runtimeType}';
        _log('warmRefused', request: request, detail: '$what reason=$type');
        _event(GravixJoinEventKind.refused, request, type);
        return null;
      }
      _log('warmFail', request: request, detail: '$what not warmed (${warmFailure(e)})');
      return null;
    }
  }

  /// [error] (a token or connect error of a join, as thrown) says the room
  /// cannot be joined with this SDK: a [RetiredServerException] or a
  /// [GravixRoomRefused] (also inside a [GravixTokenException]), or what
  /// [isRefusal] says of the unwrapped error. Never throws.
  bool isRefusalError(Object error) => GravixRoomRefused.classify(error, isRefusal);

  /// [request]'s room was refused within [refusalMemo] (no I/O): e.g. a badge
  /// on its card ("needs the host's app update"); [warm] does nothing for it.
  bool isRefused(GravixTokenRequest request) => _refusalOf(request) != null;

  ({DateTime until, bool skipLogged})? _refusalOf(GravixTokenRequest request) {
    final m = _refusedRooms[request.room];
    if (m == null) return null;
    if (!_now().isBefore(m.until)) {
      _refusedRooms.remove(request.room);
      return null;
    }
    return m;
  }

  void _noteRefused(GravixTokenRequest request) {
    if (refusalMemo <= Duration.zero) return;
    _refusedRooms.remove(request.room);
    _refusedRooms[request.room] = (until: _now().add(refusalMemo), skipLogged: false);
    while (_refusedRooms.length > _maxRefusedRooms) {
      _refusedRooms.remove(_refusedRooms.keys.first);
    }
  }

  void _clearRefused(GravixTokenRequest request) => _refusedRooms.remove(request.room);

  /// What [warm]'s failure line says about [e]: a [GravixTokenException]'s
  /// reason and the type of its cause (e.g. `callback, cause
  /// OldAppRoomException` for an app's refusal), any other error's type.
  /// Never a message: a token callback's error text can carry a url, a header
  /// or a token.
  @visibleForTesting
  static String warmFailure(Object e) => GravixJoinLog.errorOf(e);

  void _event(GravixJoinEventKind kind, GravixTokenRequest request, String? detail) {
    final cb = onEvent;
    if (cb == null) return;
    try {
      cb(
        GravixJoinEvent(
          kind: kind,
          key: GravixPrejoin.sessionKey(request),
          at: DateTime.now(),
          sinceTap: Duration.zero,
          detail: detail,
        ),
      );
    } catch (e) {
      _log('error', request: request, detail: 'onEvent threw ${e.runtimeType} (ignored)');
    }
  }

  /// The tap: starts [request]'s join now and returns its handle (the same
  /// handle while that session is live). Another session of this GravixJoin is
  /// left first: the new connect starts only after that leave returned (the
  /// token is fetched meanwhile). [createRoom] / [connect] / [leave] override
  /// the constructor's for this join; [joinMicrophone] / [joinCamera] are for the
  /// default connect. [abandonInBackground] overrides the constructor's for this
  /// one handle (false: e.g. a host's own Go Live join started at the tap whose
  /// room screen is pushed only after the app's Go Live flow: a Home press in
  /// that window keeps it, and the screen may attach while the app is still in
  /// the background; attachTimeout still applies, counting only the time the
  /// app is in front). [attachTimeout] overrides the constructor's for this one
  /// handle (null: never; omitted: the constructor's). Both are ignored when
  /// the session's handle is live already. [hooks]: the app's createRoom /
  /// connect / leave as one value ([GravixJoinHooks]; an explicit argument
  /// wins).
  GravixPrejoin prepare(
    GravixTokenRequest request, {
    GravixJoinHooks? hooks,
    Room Function()? createRoom,
    GravixPrejoinConnect? connect,
    GravixPrejoinLeave? leave,
    GravixJoinMicrophone? joinMicrophone,
    GravixJoinCamera? joinCamera,
    bool? abandonInBackground,
    Duration? attachTimeout = inheritAttachTimeout,
  }) => _start(
    request,
    createRoom: createRoom ?? hooks?.createRoom,
    connect: connect ?? hooks?.connect,
    leave: leave ?? hooks?.leave,
    joinMicrophone: joinMicrophone,
    joinCamera: joinCamera,
    abandonInBackground: abandonInBackground,
    attachTimeout: attachTimeout,
  );

  /// A room switch (the tap in the old room): the new room's token and server
  /// are warmed now, the old session is stopped now (its microphone, camera and
  /// connection: the app's leave), the app's own [beforeConnect] runs beside it,
  /// and the new room connects the moment both are done -- never two sessions.
  /// Timing events: `switchStart` (+0), `switchOldLeft`, `switchConnected`.
  /// [hooks]: the new room's createRoom / connect / leave, as for [prepare].
  GravixPrejoin switchTo(
    GravixTokenRequest request, {
    GravixSwitchBeforeConnect? beforeConnect,
    GravixJoinHooks? hooks,
    Room Function()? createRoom,
    GravixPrejoinConnect? connect,
    GravixPrejoinLeave? leave,
    GravixJoinMicrophone? joinMicrophone,
    GravixJoinCamera? joinCamera,
  }) => _start(
    request,
    isSwitch: true,
    beforeConnect: beforeConnect,
    createRoom: createRoom ?? hooks?.createRoom,
    connect: connect ?? hooks?.connect,
    leave: leave ?? hooks?.leave,
    joinMicrophone: joinMicrophone,
    joinCamera: joinCamera,
  );

  GravixPrejoin _start(
    GravixTokenRequest request, {
    bool isSwitch = false,
    GravixSwitchBeforeConnect? beforeConnect,
    Room Function()? createRoom,
    GravixPrejoinConnect? connect,
    GravixPrejoinLeave? leave,
    GravixJoinMicrophone? joinMicrophone,
    GravixJoinCamera? joinCamera,
    bool? abandonInBackground,
    Duration? attachTimeout = inheritAttachTimeout,
  }) {
    final key = GravixPrejoin.sessionKey(request);
    final live = GravixPrejoin.pendingFor(key);
    if (live != null) {
      live.logStep('prepare', 'same handle state=${live.state.name}${isSwitch ? ' switch' : ''}');
      _current = live;
      return live;
    }
    // never two sessions: the current one is stopped NOW (its mic, camera and
    // connection), the new connect waits for it below (also a session that
    // ended by itself: its leave may still be running)
    final prev = _current;
    _log(
      'prepare',
      request: request,
      sinceTap: Duration.zero,
      detail:
          'new${isSwitch ? ' switch' : ''}'
          '${prev == null || prev.state == GravixPrejoinState.ended ? '' : ' supersedes=${GravixJoinLog.keyOf(prev.key)}'}',
    );
    final Future<void> prevDown = prev == null ? Future<void>.value() : prev.abandon(GravixPrejoinEndReason.superseded);
    // the token meanwhile (a cache hit after a warm)
    _log('tokenStart', request: request, sinceTap: Duration.zero);
    final Future<GravixJoinCredentials> credentials = tokenProvider.getCredentials(request);
    // a token for the room ends its refusal memo
    unawaited(credentials.then<void>((_) => _clearRefused(request), onError: (Object _) {}));
    // a switch also pre-connects the new room's server while the old one closes
    if (isSwitch) unawaited(warm(request));
    final Future<bool> appDone = beforeConnect == null
        ? Future<bool>.value(true)
        : Future<bool>.sync(beforeConnect).catchError((Object e) {
            _log('switchCancelled', request: request, detail: 'beforeConnect threw ${e.runtimeType}');
            return false;
          });
    late final GravixPrejoin handle;
    handle = GravixPrejoin.start(
      key: key,
      target: () async {
        await prevDown;
        final ok = await appDone;
        if (!ok) {
          handle.logStep('switchCancelled', 'beforeConnect said no');
          unawaited(handle.abandon(GravixPrejoinEndReason.cancelled));
          throw StateError('switch cancelled');
        }
        if (isSwitch) handle.mark(GravixJoinEventKind.switchOldLeft);
        final GravixJoinCredentials c;
        try {
          c = await credentials;
        } catch (e) {
          // a refusal's line is the handle's `refused`
          if (!isRefusalError(e)) handle.logStep('tokenFail', GravixJoinLog.errorOf(e));
          rethrow;
        }
        handle.mark(GravixJoinEventKind.tokenReady, c.fromCache ? 'cached' : 'fetched');
        final choice = _choose(c);
        handle.mark(
          GravixJoinEventKind.urlChosen,
          '${choice.region ?? '-'} ${choice.source.name}',
          'region=${choice.region ?? '-'} source=${choice.source.name} rtt=${choice.rttMs ?? '-'} '
              'host=${GravixJoinLog.host(choice.url)}',
        );
        return GravixJoinTarget(url: choice.url, token: c.token);
      },
      createRoom: createRoom ?? _createRoom,
      connect: connect ?? _connect,
      leave: leave ?? _leave,
      connectOptions: connectOptions,
      joinMicrophone: joinMicrophone,
      joinCamera: joinCamera,
      attachTimeout: _attachTimeoutOf(attachTimeout),
      abandonInBackground: abandonInBackground ?? this.abandonInBackground,
      onEvent: onEvent,
      log: log,
      isRefusal: (e) {
        final refused = isRefusalError(e);
        if (refused) _noteRefused(request);
        return refused;
      },
    );
    if (isSwitch) {
      handle.mark(GravixJoinEventKind.switchStart);
      unawaited(
        handle.connected.then((ok) {
          if (ok) handle.mark(GravixJoinEventKind.switchConnected);
        }),
      );
    }
    _current = handle;
    return handle;
  }

  /// The app connected [request]'s session itself, outside this GravixJoin
  /// (its own reconnect: a role change with a new token whose `canPublish`
  /// differs, so the session key changed): [room] becomes the current session,
  /// already attached. [pending] / [attach] / `GravixPrejoin.pendingFor` return
  /// it; the next [prepare] / [switchTo] for another session and [leave] leave
  /// it with [leave] (default: the constructor's, else
  /// [GravixPrejoin.defaultLeave], as for [prepare]). No lifecycle guard, no
  /// never-shown watch, no attach timeout: it is on screen.
  ///
  /// The previous current session ends with [GravixPrejoinEndReason.replaced]
  /// WITHOUT its leave when a screen had it (the app tore it down) or its Room
  /// is [room]; one still joining (or connected, never attached) is abandoned
  /// normally (`superseded`, its leave runs). The same [request] and [room]
  /// again return the same handle. Event: [GravixJoinEventKind.adopted].
  /// [hooks]: only its `leave` is used (an explicit [leave] wins).
  GravixPrejoin adopt(GravixTokenRequest request, Room room, {GravixPrejoinLeave? leave, GravixJoinHooks? hooks}) {
    final h = GravixPrejoin.adopt(
      key: GravixPrejoin.sessionKey(request),
      room: room,
      leave: leave ?? hooks?.leave ?? _leave,
      replaces: _current,
      onEvent: onEvent,
      log: log,
    );
    _current = h;
    return h;
  }

  /// The room screen: the connected Room of [request]'s session -- the one the
  /// tap started, or a join started now when there is none (a cold join). Null
  /// when it failed or ended (see the handle's `error` / `ended`; a failed
  /// handle is not [pending] any more: read [pending] before, or use
  /// `prepare(request).attach()` to keep the handle).
  ///
  /// [createRoom] / [connect] / [leave] / [joinMicrophone] / [joinCamera] /
  /// [abandonInBackground] / [attachTimeout]: as for [prepare], used only when attach starts the
  /// cold join (a live handle keeps what it was started with); [hooks] as for
  /// [prepare]. The screen claims the session at this call (see
  /// `GravixPrejoin.attach`). [attachResult] / [attachOrThrow] keep the handle
  /// and its error.
  Future<Room?> attach(
    GravixTokenRequest request, {
    bool leaveIfNeverShown = true,
    GravixJoinHooks? hooks,
    Room Function()? createRoom,
    GravixPrejoinConnect? connect,
    GravixPrejoinLeave? leave,
    GravixJoinMicrophone? joinMicrophone,
    GravixJoinCamera? joinCamera,
    bool? abandonInBackground,
    Duration? attachTimeout = inheritAttachTimeout,
  }) => _handleForAttach(
    request,
    createRoom: createRoom ?? hooks?.createRoom,
    connect: connect ?? hooks?.connect,
    leave: leave ?? hooks?.leave,
    joinMicrophone: joinMicrophone,
    joinCamera: joinCamera,
    abandonInBackground: abandonInBackground,
    attachTimeout: attachTimeout,
  ).attach(leaveIfNeverShown: leaveIfNeverShown);

  // The live handle of [request]'s session, or the cold join started now.
  GravixPrejoin _handleForAttach(
    GravixTokenRequest request, {
    Room Function()? createRoom,
    GravixPrejoinConnect? connect,
    GravixPrejoinLeave? leave,
    GravixJoinMicrophone? joinMicrophone,
    GravixJoinCamera? joinCamera,
    bool? abandonInBackground,
    Duration? attachTimeout = inheritAttachTimeout,
  }) {
    final h = pending(request);
    if (h != null) return h;
    _log(
      'attachCold',
      request: request,
      detail: 'no live handle: joining now${createRoom != null || connect != null ? ' (hooks passed)' : ''}',
    );
    return prepare(
      request,
      createRoom: createRoom,
      connect: connect,
      leave: leave,
      joinMicrophone: joinMicrophone,
      joinCamera: joinCamera,
      abandonInBackground: abandonInBackground,
      attachTimeout: attachTimeout,
    );
  }

  /// The room screen, as [attach], with the session's handle kept: never
  /// throws (a failed token or connect is [GravixAttach.error], already
  /// unwrapped to the app's own exception). Safe to start before awaiting
  /// something else (a permission dialog): there is no error to leave
  /// unobserved. [GravixAttach.connectedBeforeAttach] tells the screen the
  /// connect's participant events went out before it listened.
  Future<GravixAttach> attachResult(
    GravixTokenRequest request, {
    bool leaveIfNeverShown = true,
    GravixJoinHooks? hooks,
    GravixJoinMicrophone? joinMicrophone,
    GravixJoinCamera? joinCamera,
    bool? abandonInBackground,
    Duration? attachTimeout = inheritAttachTimeout,
  }) async {
    final h = _handleForAttach(
      request,
      createRoom: hooks?.createRoom,
      connect: hooks?.connect,
      leave: hooks?.leave,
      joinMicrophone: joinMicrophone,
      joinCamera: joinCamera,
      abandonInBackground: abandonInBackground,
      attachTimeout: attachTimeout,
    );
    final before = h.state == GravixPrejoinState.connected;
    final room = await h.attach(leaveIfNeverShown: leaveIfNeverShown);
    return GravixAttach(room: room, handle: h, connectedBeforeAttach: before);
  }

  /// The room screen, as [attach], for a screen that handles a failed join with
  /// try / catch: the connected Room; null when the session ended without an
  /// error (abandoned, superseded, [GravixPrejoinEndReason.neverShown], ...);
  /// THROWS when the join failed: the token callback's own exception (e.g. the
  /// app's "room of an old app version"), unwrapped from the provider's
  /// [GravixTokenException] ([unwrapError]), or the connect's error.
  ///
  /// [throwIf]: which (unwrapped) errors are thrown (default: all); return
  /// false for a failure the app's connect hook reported itself, and the call
  /// returns null for it. [onHandle]: the session's handle, right at the call
  /// (before the connect returned; e.g. to watch `ended`).
  ///
  /// The returned future may be started before the screen awaits something
  /// else (a permission dialog): a failure meanwhile is not reported as an
  /// unhandled error, it is thrown by the later `await`. A future nobody ever
  /// awaits drops its error silently (the handle's `error` and the
  /// [GravixJoinLog] lines keep it).
  Future<Room?> attachOrThrow(
    GravixTokenRequest request, {
    bool leaveIfNeverShown = true,
    GravixJoinHooks? hooks,
    void Function(GravixPrejoin handle)? onHandle,
    bool Function(Object error)? throwIf,
    GravixJoinMicrophone? joinMicrophone,
    GravixJoinCamera? joinCamera,
    bool? abandonInBackground,
    Duration? attachTimeout = inheritAttachTimeout,
  }) {
    final h = _handleForAttach(
      request,
      createRoom: hooks?.createRoom,
      connect: hooks?.connect,
      leave: hooks?.leave,
      joinMicrophone: joinMicrophone,
      joinCamera: joinCamera,
      abandonInBackground: abandonInBackground,
      attachTimeout: attachTimeout,
    );
    if (onHandle != null) {
      try {
        onHandle(h);
      } catch (e) {
        _log('error', request: request, detail: 'onHandle threw ${e.runtimeType} (ignored)');
      }
    }
    final Future<Room?> result = h.attach(leaveIfNeverShown: leaveIfNeverShown).then((room) {
      final err = room == null ? h.error : null;
      if (err == null) return room;
      final cause = unwrapError(err);
      if (throwIf != null && !throwIf(cause)) return null;
      throw cause;
    });
    // observed here: a failure before the screen's await is not an unhandled
    // error (the await still gets it)
    unawaited(result.then<void>((_) {}, onError: (Object _) {}));
    return result;
  }

  /// The app's own error behind a failed join: the cause inside a
  /// [GravixTokenException] (the token callback's exception, e.g. an app's
  /// refusal of a room), else [e] itself (also a [GravixTokenException] without
  /// a cause).
  static Object unwrapError(Object e) => GravixRoomRefused.unwrap(e);

  /// [room] is connected or reconnecting: not null, not a session the server
  /// ended between the connect and the screen's attach.
  static bool isLive(Room? room) => room != null && room.connectionState != ConnectionState.disconnected;

  /// A usable token for [request] is in the provider's cache (no I/O): a list
  /// warm-up landed.
  bool hasToken(GravixTokenRequest request) => tokenProvider.peek(request) != null;

  /// Forgets [request]'s cached token (e.g. before a viewer's rejoin: the
  /// cached one may name a server that just went away).
  void dropToken(GravixTokenRequest request) => tokenProvider.invalidate(request);

  /// A gate refused [request]'s room after the tap (password, payment, a ban):
  /// its join is ended and left.
  Future<void> abandon(GravixTokenRequest request) {
    final h = pending(request);
    if (h == null) {
      _log('abandon', request: request, detail: 'nothing pending', at: GravixJoinLogLevel.verbose);
      return Future<void>.value();
    }
    return h.abandon();
  }

  /// The real exit of the current session.
  Future<void> leave() async {
    final c = _current;
    _current = null;
    if (c == null) {
      _log('left', detail: 'no current session', at: GravixJoinLogLevel.verbose);
      return;
    }
    await c.leave();
  }

  /// Another account signed in: every cached token, standby candidate,
  /// standby memory and refused room ([isRefused]) of the previous one is dropped (the open sockets close with
  /// the pool's next idle / background, or with [GravixStandby.closeAll]).
  void forgetAll() {
    _log('forgetAll', detail: 'tokens, standby candidates, memory and refused rooms dropped');
    tokenProvider.invalidate();
    standbyPool.forgetAll();
    _standbyUrlByToken.clear();
    _refusedRooms.clear();
  }
}
