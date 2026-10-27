// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixPrejoin (0.4.19, fast join): one join of one Room, started at the user's
// tap and handed to the room screen when it is ready -- the mechanism every app
// had written by hand around Room.connect.
//
// Why each rule is here (field, 2026-10):
//  - The tap starts the connect at once, beside the app's own work (the room
//    row fetch, its server calls, the navigation); the room screen's attach()
//    gets that same connect. A screen that connected on its own after the route
//    paid the token + WebSocket + ICE + DTLS after the app's own work.
//  - One session per room + identity + publish right: the screen's own connect,
//    a double tap or a refreshed token for the same session joins the handle
//    already running (pendingFor / start with the same key) instead of opening a
//    second Room (a second session for one identity raced the first one's
//    resume on another server and cost ~2.5 min of instability).
//  - A Back ~170 ms after a tap sent the app to the background before the room
//    screen opened; the prejoin connected anyway and a ghost viewer stayed in the
//    room ~30 s with no screen to leave it. The handle abandons itself when the
//    app is hidden / paused / detached before attach().
//  - A slightly later Back: the room screen was already built but never shown,
//    and connected in the background (a ghost for 30-33 s). attach() keeps
//    watching until a frame was shown with the app resumed (leaveIfNeverShown).
//  - The screen claims the session when it CALLS attach() (fix 2026-10-15,
//    an app's migration): the screen calls it in initState and is visible while the connect
//    runs; counting it only once attach() returned ended the join on a Home
//    press with the room on screen. From the call, only "background before the
//    screen's first frame was shown with the app resumed" leaves; markShown()
//    for an app that knows better.
//  - A Room the server ended (a kick: its RoomDisconnectedEvent) or the app
//    disposed is not handed out again (fix 2026-10-15, an app): the handle ends
//    (`roomGone`) when it is looked up, and the next start joins fresh. Its
//    leave hook never runs on a dead Room (also when superseded / abandoned):
//    the app's own disconnect handling owns that cleanup, and a viewer rejoin
//    after a drop must not stop and restart the audio session.
//  - A handle nobody attaches (a gate refused the room after the tap and the app
//    forgot to abandon) leaves after attachTimeout. Its clock counts only the
//    time the app is in front (fix 2026-10-15, device run): a host's Go Live
//    join kept through a Home press (abandonInBackground: false) was timed out
//    at +20 s while away, because the app's flow that pushes the room screen
//    does not progress in the background.
//  - The signal leave goes first (fix 2026-10-15, device run): Back right after
//    a tap sent the app to the background, the join was abandoned and the app's
//    leave hook started, but the engine detached ~20 ms later and the hook
//    never reached its disconnect: a ghost viewer until the server timeout
//    (~34 s). An abandon of a connecting / connected handle, or for the
//    background, now calls room.disconnect() (the Leave is written
//    synchronously) before the hook; a detach ends a handle no screen showed.
//  - abandon() while joining leaves at once: Room.disconnect() ends the join's
//    retries (0.4.13), instead of waiting up to ~65 s for a join nobody wants.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart' hide ConnectionState;

import '../backend/gravix_token_provider.dart' show GravixTokenRequest;
import '../rtc_core/src/core/room.dart';
import '../rtc_core/src/core/gravix_join_camera.dart';
import '../rtc_core/src/core/gravix_join_mic.dart';
import '../rtc_core/src/exceptions.dart' show ConnectException;
import '../rtc_core/src/events.dart' show RoomConnectedEvent, RoomDisconnectedEvent;
import '../rtc_core/src/options.dart';
import '../rtc_core/src/token_source/jwt.dart';
import '../rtc_core/src/types/other.dart' show ConnectionState;
import 'gravix_join_event.dart';
import 'gravix_join_log.dart';
import 'gravix_room_refused.dart';

/// What a join dials.
@immutable
class GravixJoinTarget {
  const GravixJoinTarget({required this.url, required this.token});
  final String url;
  final String token;

  @override
  String toString() => 'GravixJoinTarget($url)'; // never the token
}

/// Where a [GravixPrejoin] is.
enum GravixPrejoinState {
  /// Waiting for its target (the token).
  starting,

  /// The room's connect is running.
  connecting,

  /// Connected, not yet taken by a screen.
  connected,

  /// Taken by a screen ([GravixPrejoin.attach]).
  attached,

  /// Over ([GravixPrejoin.ended] says why).
  ended,
}

/// Why a [GravixPrejoin] ended.
enum GravixPrejoinEndReason {
  /// [GravixPrejoin.abandon] (a gate refused the room, the user went elsewhere).
  abandoned,

  /// The app went to the background before the room screen took the room.
  background,

  /// The room screen took the room but the app went to the background before a
  /// frame of it was shown.
  neverShown,

  /// Nobody attached within the handle's attachTimeout.
  attachTimeout,

  /// The token or the connect failed ([GravixPrejoin.error]); also a refused
  /// room ([GravixPrejoin.refused]: not joinable with this SDK, not a failure).
  failed,

  /// [GravixPrejoin.leave]: the real exit of an attached room.
  left,

  /// Another session replaced it (`GravixJoin`: never two sessions at once).
  superseded,

  /// A room switch was cancelled by the app before the new room connected.
  cancelled,

  /// The app connected the session again itself and adopted the new Room
  /// ([GravixPrejoin.adopt], `GravixJoin.adopt`: e.g. a role change with a new
  /// token). Its room was NOT left here: the app tore it down (or kept it, when
  /// it adopted this same Room). A screen does not close on it.
  replaced,

  /// Its Room is dead: after the connect it was disconnected (the server ended
  /// the session, a kick, the room closed, the app's own disconnect: the Room's
  /// `RoomDisconnectedEvent`, or `disconnected` with its engine closed) or it
  /// was disposed outside the handle. Not a resume or a full reconnect under
  /// way. Found when the session is looked up again ([GravixPrejoin.pendingFor],
  /// [GravixPrejoin.start], [GravixPrejoin.attach], `GravixJoin.prepare` /
  /// `attach` / `pending` / `current`) or when the handle is superseded /
  /// abandoned; the next start of the key is a fresh join. The leave hook does
  /// NOT run (the app's own disconnect handling owns that cleanup); only a Room
  /// the handle built with the default createRoom and the default leave is
  /// cleaned up ([GravixPrejoin.defaultLeave]). A screen does not need to close
  /// on it: it already heard the Room's own disconnect.
  roomGone;

  /// The user left before the room was shown ([background] / [neverShown]: the
  /// app went to the background before the room screen claimed the session or
  /// before a frame of it was shown): a room screen of the session closes
  /// normally. Every other reason keeps the screen (a role change `replaced`
  /// the Room, the real exit `left` it, the server ended it `roomGone`, ...).
  bool get leftBeforeShown => this == background || this == neverShown;
}

/// The connect of a [GravixPrejoin]: the app's own (audio session beside it,
/// listeners bound before it, its join microphone) or the default
/// `room.connect(target.url, target.token, ...)`.
typedef GravixPrejoinConnect = Future<void> Function(Room room, GravixJoinTarget target);

/// The leave of a [GravixPrejoin]'s room. Default: the local tracks stopped (a
/// room may run with `stopLocalTrackOnUnpublish: false`), `disconnect()`,
/// `dispose()`.
typedef GravixPrejoinLeave = Future<void> Function(Room room);

/// One join of one Room, started at the tap (see the file comment).
///
/// ```dart
/// // the tap
/// final h = GravixPrejoin.start(
///   key: GravixPrejoin.sessionKey(request),
///   target: () async { final c = await tokens.getCredentials(request); return GravixJoinTarget(url: c.url, token: c.token); },
///   createRoom: () => Room(roomOptions: myOptions),
/// );
/// // the room screen (finds it by key; no second connect)
/// final room = await GravixPrejoin.pendingFor(key)?.attach();
/// ```
/// `GravixJoin` does the token, the url, the standby and "one session at a time"
/// around it.
///
/// Room events between the connect and [attach] are not replayed: the screen
/// reads `room.remoteParticipants` (and their tracks) and `room.connectionState`
/// after [attach], then listens. A session whose Room is gone (the server ended
/// it after the connect, or the Room was disposed) is not handed out: the
/// handle ends with [GravixPrejoinEndReason.roomGone] when it is looked up.
class GravixPrejoin {
  GravixPrejoin._({
    required this.key,
    required FutureOr<GravixJoinTarget> Function() target,
    required Room Function() createRoom,
    required GravixPrejoinConnect connect,
    required GravixPrejoinLeave leave,
    required this.attachTimeout,
    required this.abandonInBackground,
    required this.onEvent,
    this.log,
    bool Function(Object error)? isRefusal,
    this.retryCapacityRefusals = false,
    bool ownsRoom = false,
    DateTime Function()? clock,
  }) : _isRefusal = isRefusal,
       _ownsRoom = ownsRoom,
       _target = target,
       _createRoom = createRoom,
       _connectFn = connect,
       _leaveFn = leave,
       _clockInjected = clock != null,
       _clock = clock ?? DateTime.now;

  /// Starts a join now, or returns the live handle with the same [key] (the same
  /// session: the screen's own connect, a double tap, a refreshed token).
  ///
  /// [target]: the url + token (may wait for the token). [createRoom]: the app's
  /// Room, listeners bound (called once, when the target is in hand).
  /// [connect] / [leave]: see [GravixPrejoinConnect] / [GravixPrejoinLeave];
  /// [connectOptions], [joinMicrophone] and [joinCamera] are for the default
  /// connect. [attachTimeout]: leave when no screen called [attach] by then
  /// (null: never); counted only while the app is not hidden / paused (it
  /// starts paused when the handle starts in the background).
  /// [abandonInBackground]: the lifecycle guard (false for a join the app makes
  /// in the background on purpose, e.g. a call answered from a notification).
  /// [isRefusal]: which token / connect errors mean "this room cannot be joined
  /// with this SDK" (given the raw error; e.g. `GravixRoomRefused.classify`):
  /// such a handle ends `failed` with [refused] true, its line and event are
  /// `refused` instead of `connectFail` / [GravixJoinEventKind.connectFailed].
  /// Null: [GravixRoomRefused.isBuiltIn].
  factory GravixPrejoin.start({
    required String key,
    required FutureOr<GravixJoinTarget> Function() target,
    Room Function()? createRoom,
    GravixPrejoinConnect? connect,
    GravixPrejoinLeave? leave,
    ConnectOptions? connectOptions,
    GravixJoinMicrophone? joinMicrophone,
    GravixJoinCamera? joinCamera,
    Duration? attachTimeout = defaultAttachTimeout,
    bool abandonInBackground = true,
    void Function(GravixJoinEvent event)? onEvent,
    GravixJoinLogSink? log,
    bool Function(Object error)? isRefusal,
    bool retryCapacityRefusals = false,
    @visibleForTesting DateTime Function()? clock,
  }) {
    final live = pendingFor(key);
    if (live != null) return live;
    final h = GravixPrejoin._(
      key: key,
      target: target,
      createRoom: createRoom ?? Room.new,
      connect:
          connect ??
          (room, t) => room.connect(
            t.url,
            t.token,
            connectOptions: connectOptions,
            joinMicrophone: joinMicrophone,
            joinCamera: joinCamera,
          ),
      leave: leave ?? defaultLeave,
      attachTimeout: attachTimeout,
      abandonInBackground: abandonInBackground,
      onEvent: onEvent,
      log: log,
      isRefusal: isRefusal,
      retryCapacityRefusals: retryCapacityRefusals,
      ownsRoom: createRoom == null && leave == null,
      clock: clock,
    );
    _live[key] = h;
    h._begin();
    return h;
  }

  /// A Room the app connected itself (its own reconnect: a role change with a
  /// new token whose publish right differs, a refreshed session) recorded as the
  /// live handle of [key], already attached: [pendingFor] finds it, [attach]
  /// returns [room] (no connect), [leave] / [abandon] leave it with [leave]
  /// (default [defaultLeave]). It is on screen already: no lifecycle guard, no
  /// never-shown watch, no attach timeout. `room.connectionState` is not checked.
  ///
  /// The handle it replaces -- [replaces] (the app's previous session) and a
  /// live handle of [key] with another Room -- ends with
  /// [GravixPrejoinEndReason.replaced] WITHOUT its leave when a screen had it
  /// (attached) or its Room is [room]: the app tore that room down (or kept it).
  /// One no screen had yet (its token, its connect, or connected and waiting) is
  /// abandoned normally (`superseded`, its leave runs: the connect must stop).
  ///
  /// The live handle of [key] with this same [room] is returned as it is (an
  /// adopt twice is one handle; one connected and not yet attached becomes
  /// attached without the guards).
  factory GravixPrejoin.adopt({
    required String key,
    required Room room,
    GravixPrejoinLeave? leave,
    GravixPrejoin? replaces,
    void Function(GravixJoinEvent event)? onEvent,
    GravixJoinLogSink? log,
    @visibleForTesting DateTime Function()? clock,
  }) {
    // not pendingFor: a live handle whose Room the app tore down is replaced
    // below (never left again), not dropped as gone
    final live = _live[key];
    if (live != null && identical(live._room, room)) {
      if (replaces != null && !identical(replaces, live)) replaces._replacedBy(room);
      live._adoptInPlace();
      return live;
    }
    // the replaced ones end before the new one is registered (their finish
    // removes their key from _live)
    live?._replacedBy(room);
    if (replaces != null && !identical(replaces, live)) replaces._replacedBy(room);
    final h = GravixPrejoin._(
      key: key,
      target: () => throw StateError('adopted: no target'),
      createRoom: () => room,
      connect: (r, t) async {},
      leave: leave ?? defaultLeave,
      attachTimeout: null,
      abandonInBackground: false,
      onEvent: onEvent,
      log: log,
      clock: clock,
    );
    h._startedAt = h._clock();
    h._watch.start();
    h._room = room;
    h._state = GravixPrejoinState.attached;
    h._claimed = true;
    h._shown = true;
    h._connected.complete(true);
    h._watchRoom();
    _live[key] = h;
    h.mark(GravixJoinEventKind.adopted);
    return h;
  }

  /// Long enough for a route with a gate or two (a dialog, a fetch) before the
  /// screen; short enough that a forgotten handle does not sit in a room.
  static const Duration defaultAttachTimeout = Duration(seconds: 20);

  static final Map<String, GravixPrejoin> _live = <String, GravixPrejoin>{};

  /// The live (not ended) handle for [key], if any: what a room screen attaches
  /// to without the handle being passed through the route. A handle whose Room
  /// is gone ([GravixPrejoinEndReason.roomGone]) is ended here and not returned;
  /// a handle that failed ([GravixPrejoinEndReason.failed]) is not returned
  /// either: its [error] is read on the handle [start] returned.
  static GravixPrejoin? pendingFor(String key) {
    final h = _live[key];
    if (h == null || h._dropIfRoomGone()) return null;
    return h;
  }

  /// The session key of [request]: room + identity + publish right. Two tokens
  /// with one key join one session.
  static String sessionKey(GravixTokenRequest request) =>
      '${request.room}\u0000${request.identity}\u0000${request.canPublish}';

  /// The room / identity / publish right of a session key ([sessionKey]'s
  /// shape); null when [key] is not one. For a join trace keyed by
  /// `GravixJoinEvent.key` (see `GravixJoinEvent.session`).
  static ({String room, String identity, bool canPublish})? parseSessionKey(String key) {
    final p = key.split('\u0000');
    if (p.length != 3) return null;
    return (room: p[0], identity: p[1], canPublish: p[2] == 'true');
  }

  /// The session key of a join token (the same shape as [sessionKey]), read
  /// without verifying it; null when it cannot be read. A grant without
  /// `canPublish` may publish (the server's default), while [sessionKey]'s
  /// request defaults to `canPublish: false`: an app that derives keys from both
  /// requests and tokens passes an explicit `canPublish` in its requests.
  static String? sessionKeyOf(String token) {
    try {
      final p = GravixRtcJwtPayload.fromToken(token);
      final room = p?.video?.room;
      final identity = p?.identity;
      if (room == null || room.isEmpty || identity == null || identity.isEmpty) return null;
      // the grant as tokens carry it (camelCase), or the snake_case the vendored
      // parser reads
      final raw = p?.claims['video'];
      final publish = raw is Map ? (raw['canPublish'] ?? raw['can_publish']) : null;
      return '$room\u0000$identity\u0000${publish is bool ? publish : true}';
    } catch (e) {
      GravixJoinLog.step(
        'error',
        detail: 'sessionKeyOf: unreadable token (${e.runtimeType})',
        at: GravixJoinLogLevel.verbose,
      );
      return null;
    }
  }

  /// The default [GravixPrejoinLeave].
  static Future<void> defaultLeave(Room room) async {
    final lp = room.localParticipant;
    if (lp != null) {
      for (final pub in lp.trackPublications.values.toList()) {
        try {
          await pub.track?.stop();
        } catch (e) {
          GravixJoinLog.step('error', detail: 'defaultLeave: track stop threw ${e.runtimeType}');
        }
      }
    }
    try {
      await room.disconnect();
    } catch (e) {
      GravixJoinLog.step('error', detail: 'defaultLeave: disconnect threw ${e.runtimeType}');
    }
    try {
      if (!room.isDisposed) await room.dispose();
    } catch (e) {
      GravixJoinLog.step('error', detail: 'defaultLeave: dispose threw ${e.runtimeType}');
    }
  }

  /// Ends every live handle (tests).
  @visibleForTesting
  static Future<void> debugEndAll() async {
    for (final h in _live.values.toList()) {
      await h.abandon();
    }
    _live.clear();
  }

  /// The session key.
  final String key;

  /// See [GravixPrejoin.start].
  final Duration? attachTimeout;

  /// See [GravixPrejoin.start].
  final bool abandonInBackground;

  /// Timing events of this join (see [GravixJoinEvent]).
  final void Function(GravixJoinEvent event)? onEvent;

  /// Where this join's step lines go ([GravixJoinLog]; null: [GravixJoinLog.sink]).
  final GravixJoinLogSink? log;

  final FutureOr<GravixJoinTarget> Function() _target;
  final Room Function() _createRoom;
  final GravixPrejoinConnect _connectFn;
  final GravixPrejoinLeave _leaveFn;
  final bool Function(Object error)? _isRefusal;

  /// See [GravixJoin.retryCapacityRefusals].
  final bool retryCapacityRefusals;

  /// The waits between capacity retries ([retryCapacityRefusals]); the last one
  /// repeats. Each is spread by +-20 % so refused viewers do not come back in
  /// step.
  static List<Duration> capacityRetryBackoff = const [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 8),
    Duration(seconds: 10),
  ];

  static final math.Random _jitter = math.Random();

  /// The SFU refused the join because the app's owner is at its concurrent-user
  /// cap (HTTP 403 "app user limit reached"). Not the billing refusal ("app
  /// plan limit reached"): that one does not clear while the screen is open.
  static bool isCapacityRefusal(Object e) =>
      e is ConnectException && e.statusCode == 403 && e.message.contains('app user limit reached');
  bool _refused = false;
  // built with the default createRoom AND the default leave: the only Room the
  // handle cleans up after it died (see [GravixPrejoinEndReason.roomGone])
  final bool _ownsRoom;
  final DateTime Function() _clock;
  final bool _clockInjected;
  late final DateTime _startedAt;
  final Stopwatch _watch = Stopwatch();

  final Completer<bool> _connected = Completer<bool>();
  final Completer<GravixPrejoinEndReason> _ended = Completer<GravixPrejoinEndReason>();
  GravixPrejoinState _state = GravixPrejoinState.starting;
  Room? _room;
  GravixJoinTarget? _resolved;
  Object? _error;
  AppLifecycleListener? _lifecycle;
  // the background guard is on (abandonInBackground and a lifecycle listener)
  bool _guard = false;
  // the attach timeout: the budget left, counted only while the app is not
  // hidden / paused (null: none, or over)
  Timer? _timeout;
  Duration? _timeoutLeft;
  Duration _timeoutFrom = Duration.zero;
  bool _timeoutPaused = false;
  // the signal leave (room.disconnect()) was sent ahead of the leave hook
  bool _signalSent = false;
  // watches for a detach while a leave hook runs without the signal leave first
  AppLifecycleListener? _leaveWatch;
  // abandoned while connecting: a connect that still joins is left at once
  Future<void> Function()? _cancelLateWatch;
  bool _lateLeft = false;
  // a screen called attach() (or adopt): the pre-attach guard is over
  bool _claimed = false;
  bool _watchShown = false;
  bool _shown = false;
  bool _roomLeft = false;
  // the Room's RoomDisconnectedEvent after the connect (the session is over)
  bool _roomDisconnected = false;
  // the Room read connected (or reconnecting) after the connect: from then on a
  // `disconnected` with no reconnect under way is the end of its session
  bool _roomWasLive = false;
  Future<void> Function()? _cancelRoomWatch;
  Future<void>? _leaving;
  int _connectStartMs = 0;
  GravixPrejoinEndReason? _endReason;
  // why the leave hook is not run (a dead Room)
  String? _leaveSkip;

  /// Where it is.
  GravixPrejoinState get state => _state;

  /// The Room, once the target is in hand (connecting or later).
  Room? get room => _room;

  /// What it dials, once known.
  GravixJoinTarget? get target => _resolved;

  /// Why the token or the connect failed (the connect's own exception, e.g. a
  /// `RetiredServerException`, or a `GravixTokenException`).
  Object? get error => _error;

  /// The join was refused: [error] says this room cannot be joined with this
  /// SDK (see [GravixRoomRefused]; e.g. a room an old app version hosts on
  /// another server). A refusal, not a failure: the handle ended
  /// [GravixPrejoinEndReason.failed], its event was [GravixJoinEventKind.refused].
  bool get refused => _refused;

  /// When it started (the tap).
  DateTime get startedAt => _startedAt;

  /// The join gate: true once connected; false when it failed or ended first.
  /// Seat / microphone / camera actions wait on it instead of polling.
  Future<bool> get connected => _connected.future;

  /// Completes once, with why it ended. A screen that attached listens to it
  /// (e.g. [GravixPrejoinEndReason.neverShown]: close the screen).
  Future<GravixPrejoinEndReason> get ended => _ended.future;

  bool get _isEnded => _state == GravixPrejoinState.ended;

  /// Adds a timing event to this join's clock (an app may add its own marks;
  /// `GravixJoin` adds the token and url steps), and its step line
  /// ([GravixJoinLog]; [logDetail] instead of [detail] in the line).
  void mark(GravixJoinEventKind kind, [String? detail, String? logDetail]) {
    final (step, at) = _stepOf(kind);
    _log(step, logDetail ?? _logDetailOf(kind, detail), at: at);
    final cb = onEvent;
    if (cb == null) return;
    try {
      cb(GravixJoinEvent(kind: kind, key: key, at: _clock(), sinceTap: _watch.elapsed, detail: detail));
    } catch (e) {
      _log('error', 'onEvent threw ${e.runtimeType} (ignored)');
    }
  }

  /// Writes one step line of this join (see [GravixJoinLog]), on its tap clock.
  void logStep(String step, [String? detail, GravixJoinLogLevel at = GravixJoinLogLevel.info]) =>
      _log(step, detail, at: at);

  void _log(String step, String? detail, {GravixJoinLogLevel at = GravixJoinLogLevel.info}) {
    if (!GravixJoinLog.writes(at)) return;
    GravixJoinLog.step(step, key: key, sinceTap: _watch.elapsed, detail: detail, at: at, to: log);
  }

  static (String, GravixJoinLogLevel) _stepOf(GravixJoinEventKind kind) => switch (kind) {
    GravixJoinEventKind.warm => ('warmOk', GravixJoinLogLevel.info),
    GravixJoinEventKind.prejoinStart => ('handleStart', GravixJoinLogLevel.verbose),
    GravixJoinEventKind.tokenReady => ('tokenOk', GravixJoinLogLevel.info),
    GravixJoinEventKind.urlChosen => ('urlChosen', GravixJoinLogLevel.info),
    GravixJoinEventKind.connectStart => ('connectStart', GravixJoinLogLevel.info),
    GravixJoinEventKind.connected => ('connectOk', GravixJoinLogLevel.info),
    GravixJoinEventKind.connectFailed => ('connectFail', GravixJoinLogLevel.info),
    GravixJoinEventKind.attached => ('attached', GravixJoinLogLevel.info),
    GravixJoinEventKind.shown => ('shown', GravixJoinLogLevel.info),
    GravixJoinEventKind.abandoned => ('abandon', GravixJoinLogLevel.info),
    GravixJoinEventKind.left => ('left', GravixJoinLogLevel.info),
    GravixJoinEventKind.switchStart => ('switchStart', GravixJoinLogLevel.info),
    GravixJoinEventKind.switchOldLeft => ('switchOldLeft', GravixJoinLogLevel.info),
    GravixJoinEventKind.switchConnected => ('switchConnected', GravixJoinLogLevel.info),
    GravixJoinEventKind.adopted => ('adopt', GravixJoinLogLevel.info),
    GravixJoinEventKind.refused => ('refused', GravixJoinLogLevel.info),
  };

  String? _logDetailOf(GravixJoinEventKind kind, String? detail) => switch (kind) {
    GravixJoinEventKind.tokenReady => detail == null ? null : 'via=$detail',
    GravixJoinEventKind.abandoned => detail == null ? null : 'reason=$detail',
    GravixJoinEventKind.connected => 'in=${_watch.elapsedMilliseconds - _connectStartMs}ms',
    _ => detail,
  };

  static bool _inBackground(AppLifecycleState? s) =>
      s == AppLifecycleState.hidden || s == AppLifecycleState.paused || s == AppLifecycleState.detached;

  // the app is away and will come back (the attach timeout pauses); not
  // `inactive` (a shade, a dialog) and not `detached` (no view: the handle ends
  // or, shown, keeps counting)
  static bool _hiddenOrPaused(AppLifecycleState? s) => s == AppLifecycleState.hidden || s == AppLifecycleState.paused;

  Duration _elapsed() => _clockInjected ? _clock().difference(_startedAt) : _watch.elapsed;

  void _runTimeout() {
    final left = _timeoutLeft;
    if (left == null) return;
    _timeoutPaused = false;
    _timeoutFrom = _elapsed();
    _timeout?.cancel();
    _timeout = Timer(left, () {
      _timeout = null;
      _timeoutLeft = null;
      if (_state != GravixPrejoinState.attached) unawaited(abandon(GravixPrejoinEndReason.attachTimeout));
    });
  }

  void _pauseTimeout() {
    final left = _timeoutLeft;
    if (left == null || _timeoutPaused) return;
    _timeout?.cancel();
    _timeout = null;
    final rest = left - (_elapsed() - _timeoutFrom);
    _timeoutLeft = rest.isNegative ? Duration.zero : rest;
    _timeoutPaused = true;
    _log('attachTimeoutPaused', 'left=${_timeoutLeft!.inMilliseconds}ms');
  }

  void _resumeTimeout() {
    if (_timeoutLeft == null || !_timeoutPaused) return;
    _log('attachTimeoutResumed', 'left=${_timeoutLeft!.inMilliseconds}ms');
    _runTimeout();
  }

  void _stopTimeout() {
    _timeout?.cancel();
    _timeout = null;
    _timeoutLeft = null;
    _timeoutPaused = false;
  }

  static AppLifecycleState? _lifecycleState() {
    try {
      return WidgetsBinding.instance.lifecycleState;
    } catch (e) {
      GravixJoinLog.step('error', detail: 'no lifecycle state (${e.runtimeType})', at: GravixJoinLogLevel.verbose);
      return null;
    }
  }

  void _begin() {
    _startedAt = _clock(); // the tap's time
    _watch.start();
    mark(GravixJoinEventKind.prejoinStart);
    final now = _lifecycleState();
    if (abandonInBackground && _inBackground(now)) {
      // started behind the user's back: nothing is dialled
      _finish(GravixPrejoinEndReason.background);
      return;
    }
    // the background guard (abandonInBackground), the attach timeout's pause
    // while the app is away, and the detach (every handle)
    try {
      _lifecycle = AppLifecycleListener(
        onHide: _onHidden,
        onPause: _onHidden,
        onDetach: _onDetached,
        onResume: _onResume,
      );
      _guard = abandonInBackground;
    } catch (e) {
      _log('error', 'no lifecycle guard (${e.runtimeType})');
    }
    final t = attachTimeout;
    if (t != null) {
      _timeoutLeft = t;
      if (_hiddenOrPaused(now)) {
        // e.g. a join the app makes in the background on purpose: the clock
        // starts when the app is in front
        _timeoutPaused = true;
        _log('attachTimeoutPaused', 'left=${t.inMilliseconds}ms at start');
      } else {
        _runTimeout();
      }
    }
    unawaited(_join());
  }

  Future<void> _join() async {
    final GravixJoinTarget t;
    try {
      t = await _target();
    } catch (e) {
      if (_isEnded) return;
      _error = e;
      if (!_markRefused(e)) {
        mark(GravixJoinEventKind.connectFailed, e.runtimeType.toString(), 'no target (${GravixJoinLog.errorOf(e)})');
      }
      _finish(GravixPrejoinEndReason.failed);
      return;
    }
    if (_isEnded) return;
    _resolved = t;
    final Room room;
    try {
      room = _room = _createRoom();
    } catch (e) {
      _error = e;
      mark(GravixJoinEventKind.connectFailed, e.runtimeType.toString(), 'createRoom threw ${e.runtimeType}');
      _finish(GravixPrejoinEndReason.failed);
      return;
    }
    _state = GravixPrejoinState.connecting;
    _connectStartMs = _watch.elapsedMilliseconds;
    mark(GravixJoinEventKind.connectStart, null, 'host=${GravixJoinLog.host(t.url)}');
    try {
      await _connectRetryingCapacity(room, t);
    } catch (e) {
      if (_isEnded) {
        // abandoned during the connect: already left
        _log('connectFail', 'after the end (${GravixJoinLog.errorOf(e)})', at: GravixJoinLogLevel.verbose);
        _leaveLateConnect(room, 'connect threw');
        _unwatchLate();
        return;
      }
      _error = e;
      if (!_markRefused(e)) {
        mark(
          GravixJoinEventKind.connectFailed,
          e.runtimeType.toString(),
          '${GravixJoinLog.errorOf(e)} in=${_watch.elapsedMilliseconds - _connectStartMs}ms',
        );
      }
      _finish(GravixPrejoinEndReason.failed);
      await (_leaving = _leaveRoom());
      return;
    }
    if (_isEnded) {
      // abandoned during the connect: left there, not adopted; a connect that
      // joined anyway (the hook connected after the leave) is left now
      _log('connectOk', 'after the end: not kept', at: GravixJoinLogLevel.verbose);
      _leaveLateConnect(room, 'connect returned');
      _unwatchLate();
      return;
    }
    _state = GravixPrejoinState.connected;
    _watchRoom();
    _logStandby(room);
    mark(GravixJoinEventKind.connected);
    if (!_connected.isCompleted) _connected.complete(true);
  }

  // [retryCapacityRefusals]: a join the SFU refused at the owner's user cap is
  // tried again on the same Room after a wait, silently (the handle stays
  // `connecting`, the screen's attach keeps waiting), until it connects, fails
  // otherwise, or the handle ends (left, superseded, abandoned). One
  // `capacityRetry` line per wait.
  Future<void> _connectRetryingCapacity(Room room, GravixJoinTarget t) async {
    var n = 0;
    while (true) {
      try {
        await _connectFn(room, t);
        if (n > 0) _log('capacityRetryOk', 'after=$n waited=${_watch.elapsedMilliseconds - _connectStartMs}ms');
        return;
      } catch (e) {
        if (!retryCapacityRefusals || _isEnded || !isCapacityRefusal(e)) rethrow;
        final steps = capacityRetryBackoff;
        final base = steps[n < steps.length ? n : steps.length - 1];
        final wait = Duration(milliseconds: (base.inMilliseconds * (0.8 + 0.4 * _jitter.nextDouble())).round());
        n++;
        _log('capacityRetry', 'n=$n in=${wait.inMilliseconds}ms (app user limit reached)');
        await Future<void>.delayed(wait);
        if (_isEnded) rethrow;
      }
    }
  }

  // What the join's dial did with a standby connection (the signal client's
  // `gravixStandby` block; device run 2026-10-15: two host joins paid ~3 s on a
  // stalled standby and the log could not say where): `standbyTaken`, plus
  // `standbyRaceWon=fresh|standby` when a fresh dial raced it and
  // `standbyStale reason=...` when it could not carry the join. Never throws.
  void _logStandby(Room room) {
    try {
      final sb = room.engine.signalClient.gravixStandby;
      final outcome = sb?['outcome'];
      if (sb == null || outcome == null || outcome == 'none') return;
      String ms(String k) => sb[k] == null ? '-' : '${sb[k]}ms';
      final path = sb['path'];
      _log(
        'standbyTaken',
        'outcome=$outcome age=${ms('ageMs')} waited=${ms('waitedMs')} path=${path ?? '-'} '
            'bound=${ms('boundMs')} dial=${ms('dialMs')} reused=${sb['reused'] ?? '-'}',
      );
      if (path == 'redial' || path == 'standby_late') {
        _log(
          'standbyRaceWon=${path == 'redial' ? 'fresh' : 'standby'}',
          'stalledAfter=${ms('stalledAfterMs')} dial=${ms('dialMs')}',
        );
      }
      final stale = switch ((outcome, path, sb['reused'])) {
        ('expired', _, _) => 'expired',
        ('dead', _, _) => 'dead',
        (_, 'redial', _) => 'stalled',
        (_, 'cold_after_error', _) => 'failed',
        (_, _, false) => 'reopened',
        _ => null,
      };
      if (stale != null) _log('standbyStale', 'reason=$stale');
    } catch (e) {
      _log('error', 'standby block unreadable (${e.runtimeType})', at: GravixJoinLogLevel.verbose);
    }
  }

  // A refusal (see [refused]): the `refused` line and event instead of
  // connectFail. Never throws.
  bool _markRefused(Object e) {
    bool yes;
    try {
      final f = _isRefusal;
      yes = f == null ? GravixRoomRefused.isBuiltIn(e) : f(e);
    } catch (err) {
      _log('error', 'isRefusal threw ${err.runtimeType} (not a refusal)', at: GravixJoinLogLevel.verbose);
      yes = false;
    }
    if (!yes) return false;
    _refused = true;
    final type = '${GravixRoomRefused.unwrap(e).runtimeType}';
    mark(GravixJoinEventKind.refused, type, 'reason=$type');
    return true;
  }

  /// The connected Room for the room screen, or null when the join failed or
  /// the handle ended (then the screen joins normally or shows the failure).
  /// The same Room for every call.
  ///
  /// The screen claims the session the moment it CALLS attach (call it in
  /// initState: the screen is up while the connect runs): from then on the
  /// pre-attach guard (background = abandon) is over and the attach timeout no
  /// longer runs. [leaveIfNeverShown] (with the lifecycle guard on): the room is
  /// left when the app goes to the background before a frame was shown with the
  /// app resumed (a frame drawn while `inactive` does not count; the next one
  /// after the resume does); [ended] then completes with
  /// [GravixPrejoinEndReason.neverShown] and a pending attach returns null. Once
  /// a frame was shown (or [markShown]), the background never leaves. The first
  /// call's [leaveIfNeverShown] holds. A handle whose Room is gone returns null
  /// ([GravixPrejoinEndReason.roomGone]).
  Future<Room?> attach({bool leaveIfNeverShown = true}) async {
    if (_isEnded || _dropIfRoomGone()) {
      _log('attachCall', 'ended (${_endReason?.name ?? 'roomGone'}): null');
      return null;
    }
    _log('attachCall', '${_claimed ? 'again' : 'claimed'} state=${_state.name}');
    _claim(leaveIfNeverShown);
    final ok = await _connected.future;
    if (!ok || _isEnded) return null;
    if (_state == GravixPrejoinState.attached) return _room;
    _state = GravixPrejoinState.attached;
    mark(GravixJoinEventKind.attached);
    return _room;
  }

  // The screen took the session (attach() called): see [attach].
  void _claim(bool leaveIfNeverShown) {
    if (_claimed) return;
    _claimed = true;
    _stopTimeout();
    if (_shown) {
      // markShown() came first: nothing to watch
      _disposeLifecycle();
      return;
    }
    if (leaveIfNeverShown && _guard) {
      _watchShown = true;
      _awaitShownFrame();
    } else {
      _disposeLifecycle();
    }
  }

  /// A screen of this session is shown to the user (for an app that knows
  /// better than the frame watch, e.g. a room screen drawn under an overlay):
  /// from now on going to the background never leaves the room, before or
  /// after [attach]. Taken as said (the app's lifecycle state is not checked).
  /// Does not attach (the attach timeout still runs until [attach]). Nothing on
  /// an ended handle or when already shown. Event: [GravixJoinEventKind.shown].
  void markShown() {
    if (_isEnded || _shown) return;
    _shown = true;
    mark(GravixJoinEventKind.shown, null, 'markShown');
    // the attach timeout (until attach) still pauses while the app is away
    if (_timeoutLeft == null) _disposeLifecycle();
  }

  // hidden / paused
  void _onHidden() {
    if (_isEnded) return;
    if (_guard && !_shown) {
      if (!_claimed) {
        unawaited(abandon(GravixPrejoinEndReason.background));
        return;
      }
      if (_watchShown) {
        unawaited(abandon(GravixPrejoinEndReason.neverShown));
        return;
      }
    }
    _pauseTimeout(); // a handle allowed to survive the background
  }

  // The engine is losing its view (a Back that finished the activity): the
  // process may be gone within milliseconds. A handle no screen has shown ends
  // now with the signal leave first -- also one allowed to survive the
  // background (its screen can no longer come). A shown handle stays (its
  // attach timeout, if any, counts again).
  void _onDetached() {
    if (_isEnded) return;
    if (_shown || (_claimed && !_watchShown)) {
      _resumeTimeout();
      return;
    }
    _log('detached', 'not shown: leaving');
    unawaited(abandon(_claimed ? GravixPrejoinEndReason.neverShown : GravixPrejoinEndReason.background));
  }

  void _onResume() {
    if (_isEnded) return;
    _resumeTimeout();
    if (_claimed && _watchShown && !_shown) _awaitShownFrame();
  }

  // Watches the connected Room for the end of its session (not a resume or a
  // full reconnect: the Room emits RoomDisconnectedEvent only when it is over).
  void _watchRoom() {
    final room = _room;
    if (room == null || _cancelRoomWatch != null) return;
    _roomIsDead(); // notes whether it reads live now
    try {
      _cancelRoomWatch = room.events.on<RoomDisconnectedEvent>((_) => _roomDisconnected = true);
    } catch (e) {
      _log('error', 'Room not watched (${e.runtimeType})');
    }
  }

  void _unwatchRoom() {
    final cancel = _cancelRoomWatch;
    _cancelRoomWatch = null;
    if (cancel == null) return;
    try {
      unawaited(
        cancel().catchError((Object e) {
          _log('error', 'room unwatch threw ${e.runtimeType}', at: GravixJoinLogLevel.verbose);
        }),
      );
    } catch (e) {
      _log('error', 'room unwatch threw ${e.runtimeType}', at: GravixJoinLogLevel.verbose);
    }
  }

  // Whether the connected (or attached) handle's Room is dead: disposed, its
  // RoomDisconnectedEvent seen, or `disconnected` after it read live with its
  // engine closed and no reconnect under way (a resume's dial also reads
  // `disconnected`).
  bool _roomIsDead() {
    if (_state != GravixPrejoinState.connected && _state != GravixPrejoinState.attached) return false;
    final room = _room;
    if (room == null) return false;
    if (room.isDisposed || _roomDisconnected) return true;
    try {
      if (room.connectionState != ConnectionState.disconnected) {
        _roomWasLive = true;
        return false;
      }
      // closed: the engine gave the session up (a resume's dial reads
      // `disconnected` too, with the engine still open)
      return _roomWasLive && room.engine.isClosed && !room.engine.gravixReconnectInProgress;
    } catch (e) {
      _log('error', 'room state unreadable (${e.runtimeType})', at: GravixJoinLogLevel.verbose);
      return false;
    }
  }

  // A connected (or attached) handle whose Room is dead ends here: true when it
  // did (see [GravixPrejoinEndReason.roomGone]).
  bool _dropIfRoomGone() {
    if (_isEnded || !_roomIsDead()) return false;
    unawaited(abandon(GravixPrejoinEndReason.roomGone));
    return true;
  }

  void _awaitShownFrame() {
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_shown || _isEnded) return;
        final s = _lifecycleState();
        if (s == null || s == AppLifecycleState.resumed) {
          _shown = true;
          mark(GravixJoinEventKind.shown, null, 'frame');
          _disposeLifecycle(); // claimed: no attach timeout left
        }
        // otherwise wait for onResume (its frame) or a background
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    } catch (e) {
      _log('error', 'no frame watch (${e.runtimeType})');
    }
  }

  /// Ends the handle and leaves its room (if one exists: connecting or
  /// connected). A join still running is ended at once. Idempotent.
  ///
  /// A handle whose Room is dead (see [GravixPrejoinEndReason.roomGone]) ends
  /// with `roomGone` (a [leave] stays `left`) and its leave hook does NOT run:
  /// the app's own disconnect handling owns that cleanup. Only a Room the
  /// handle built with the default createRoom and the default leave is cleaned
  /// up ([defaultLeave]).
  Future<void> abandon([GravixPrejoinEndReason reason = GravixPrejoinEndReason.abandoned]) {
    if (_isEnded) return _leaving ?? Future<void>.value();
    final was = _state;
    final dead = _roomIsDead();
    if (dead && reason != GravixPrejoinEndReason.left) reason = GravixPrejoinEndReason.roomGone;
    mark(
      reason == GravixPrejoinEndReason.left ? GravixJoinEventKind.left : GravixJoinEventKind.abandoned,
      reason == GravixPrejoinEndReason.left ? null : reason.name,
    );
    _finish(reason);
    if (dead && !_ownsRoom) {
      _roomLeft = true; // never the app's leave hook on a dead Room
      _leaveSkip = 'dead room';
    }
    // the signal leave before the app's hook: the app may be losing its engine
    // (background / neverShown), or the join was never on screen (connecting /
    // connected); the real exit of an attached room keeps the hook's order
    if (was == GravixPrejoinState.connecting) _guardLateConnect();
    final signalFirst =
        !dead &&
        (reason == GravixPrejoinEndReason.background ||
            reason == GravixPrejoinEndReason.neverShown ||
            was == GravixPrejoinState.connecting ||
            was == GravixPrejoinState.connected);
    return _leaving = _leaveRoom(signalFirst: signalFirst ? reason.name : null);
  }

  /// The real exit of an attached room (also ends a handle that was not attached).
  Future<void> leave() => abandon(GravixPrejoinEndReason.left);

  // [adopt] replaced this handle with [room]: see there.
  void _replacedBy(Room room) {
    if (_isEnded) return;
    if (_state == GravixPrejoinState.attached || identical(_room, room)) {
      _roomLeft = true; // the app's room now: never left here
      mark(GravixJoinEventKind.abandoned, GravixPrejoinEndReason.replaced.name);
      _finish(GravixPrejoinEndReason.replaced);
    } else {
      unawaited(abandon(GravixPrejoinEndReason.superseded));
    }
  }

  // [adopt] of this handle's own Room under its own key.
  void _adoptInPlace() {
    if (_state != GravixPrejoinState.connected) return;
    _state = GravixPrejoinState.attached;
    _claimed = true;
    _shown = true;
    _stopTimeout();
    _disposeLifecycle();
    mark(GravixJoinEventKind.adopted);
  }

  // [signalFirst]: why the signal leave goes ahead of the hook (null: the hook
  // first, with the signal leave sent at once if the app detaches meanwhile).
  Future<void> _leaveRoom({String? signalFirst}) async {
    final room = _room;
    if (room == null) {
      _log('leaveSkipped', 'no room yet');
      return;
    }
    if (_roomLeft) {
      _log('leaveSkipped', _leaveSkip ?? 'already left');
      return;
    }
    _roomLeft = true;
    final t0 = _watch.elapsedMilliseconds;
    _log('leaveStart', 'after=${_endReason?.name ?? '-'}');
    if (signalFirst != null) {
      _sendLeaveSignal(room, signalFirst);
    } else {
      _watchDetachDuringLeave(room);
    }
    try {
      await _leaveFn(room);
      _log('leaveDone', 'in=${_watch.elapsedMilliseconds - t0}ms');
    } catch (e) {
      _log('leaveFail', 'threw ${e.runtimeType} in=${_watch.elapsedMilliseconds - t0}ms (ignored)');
    } finally {
      _leaveWatch?.dispose();
      _leaveWatch = null;
    }
  }

  // The Leave on the wire now: Room.disconnect() writes it synchronously (and
  // ends a join still retrying); not awaited, the hook runs right after. The
  // hook's own disconnect is then a no-op in the core (one Leave per socket).
  void _sendLeaveSignal(Room room, String why) {
    if (_signalSent || room.isDisposed) return;
    _signalSent = true;
    _log('leaveSignalFirst', 'why=$why');
    try {
      unawaited(
        room.disconnect().then<void>(
          (_) {},
          onError: (Object e) {
            _log(
              'error',
              'leaveSignalFirst: disconnect threw ${e.runtimeType} (ignored)',
              at: GravixJoinLogLevel.verbose,
            );
          },
        ),
      );
    } catch (e) {
      _log('error', 'leaveSignalFirst: disconnect threw ${e.runtimeType} (ignored)', at: GravixJoinLogLevel.verbose);
    }
  }

  // Abandoned while connecting: the app's connect hook may not have called
  // Room.connect yet (its own work first), and Room.connect clears the leave
  // mark, so the leave alone does not stop it. The Room is marked (a later
  // connect returns at once), and a connect that joins anyway is left at once
  // (`leaveAfterLateConnect`), as soon as the Room reports connected or the
  // hook returned.
  void _guardLateConnect() {
    final room = _room;
    if (room == null || room.isDisposed) return;
    try {
      if (room.gravixAbandonConnect()) {
        _log('connectBlocked', 'abandoned before the connect started', at: GravixJoinLogLevel.verbose);
      }
    } catch (e) {
      _log('error', 'connect not blocked (${e.runtimeType})', at: GravixJoinLogLevel.verbose);
    }
    try {
      _cancelLateWatch = room.events.on<RoomConnectedEvent>((_) => _leaveLateConnect(room, 'room connected'));
    } catch (e) {
      _log('error', 'late connect not watched (${e.runtimeType})', at: GravixJoinLogLevel.verbose);
    }
  }

  void _unwatchLate() {
    final cancel = _cancelLateWatch;
    _cancelLateWatch = null;
    if (cancel == null) return;
    unawaited(
      cancel().catchError(
        (Object e) => _log('error', 'late unwatch threw ${e.runtimeType}', at: GravixJoinLogLevel.verbose),
      ),
    );
  }

  // The handle ended before its connect finished, and the Room joined anyway:
  // the signal leave now (Room.disconnect(); the app's leave hook already ran
  // at the abandon). Once.
  void _leaveLateConnect(Room room, String why) {
    if (_lateLeft || room.isDisposed) return;
    final ConnectionState state;
    try {
      state = room.connectionState;
    } catch (e) {
      _log('error', 'late connect: state unreadable (${e.runtimeType})', at: GravixJoinLogLevel.verbose);
      return;
    }
    if (state == ConnectionState.disconnected) return; // nothing joined
    _lateLeft = true;
    _unwatchLate();
    _log('leaveAfterLateConnect', 'why=$why state=${state.name}');
    try {
      unawaited(
        room.disconnect().then<void>(
          (_) {},
          onError: (Object e) => _log(
            'error',
            'leaveAfterLateConnect: disconnect threw ${e.runtimeType} (ignored)',
            at: GravixJoinLogLevel.verbose,
          ),
        ),
      );
    } catch (e) {
      _log(
        'error',
        'leaveAfterLateConnect: disconnect threw ${e.runtimeType} (ignored)',
        at: GravixJoinLogLevel.verbose,
      );
    }
  }

  void _watchDetachDuringLeave(Room room) {
    try {
      _leaveWatch = AppLifecycleListener(onDetach: () => _sendLeaveSignal(room, 'detached'));
    } catch (e) {
      _log('error', 'no detach watch during the leave (${e.runtimeType})', at: GravixJoinLogLevel.verbose);
    }
  }

  void _finish(GravixPrejoinEndReason reason) {
    if (_isEnded) return;
    _endReason = reason;
    _state = GravixPrejoinState.ended;
    _stopTimeout();
    _disposeLifecycle();
    _unwatchRoom();
    if (identical(_live[key], this)) _live.remove(key);
    if (!_connected.isCompleted) _connected.complete(false);
    if (!_ended.isCompleted) _ended.complete(reason);
  }

  void _disposeLifecycle() {
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  @override
  String toString() => 'GravixPrejoin(${_state.name})';
}
