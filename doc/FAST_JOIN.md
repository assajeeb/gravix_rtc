# Fast join with `GravixJoin` (0.4.19)

Joining a room fast takes more than `room.connect`: the token has to be fetched before the
tap, the signalling server's connection opened before the tap, the connect started at the tap
(not after the route), handed to the room screen without a second connect, abandoned when the
user leaves before the room opens, and a switch from one room to another has to stop the old
session at once and start the new one the moment it closed. Up to 0.4.18 every app wrote this
by hand around `Room`. `GravixJoin` is that code in the package. Everything in it is opt-in:
`Room.connect`, `GravixRoomService` and the token provider behave as before unless you use it.

## The calls

```dart
// once per app (or per signed-in user)
final join = GravixJoin(
  tokenProvider: GravixTokenProvider.callback(
    (r) => myBackend.joinToken(room: r.room, canPublish: r.canPublish), // your server mints it
    reuse: GravixTokenReuse.fastJoin,
  ),
);
gravixStartRegionMeasurement(regionsUrl: ...); // as before: joins dial the fastest region

final request = GravixTokenRequest(room: roomId, identity: uid, canPublish: isHost);

// a room list: every room on screen, and the one under the finger
join.warm(request, role: GravixStandbyRole.visible, rank: index);
join.warm(request);                                   // onPointerDown: touched

// the tap: the connect starts now, beside your own work and the navigation
join.prepare(request, createRoom: () => Room(roomOptions: myRoomOptions));

// the room screen: the same connect (no second session)
final room = await join.attach(request);              // null: failed or abandoned
// read room.remoteParticipants and room.connectionState now, then listen
// (events before attach are not replayed)

// a gate after the tap refused the room (password, payment, ban)
await join.abandon(request);

// from one room to another (an in-room list, a banner)
join.switchTo(next, beforeConnect: () async { await closeOldScreen(); return true; });

// the real exit; another account signed in
await join.leave();
join.forgetAll();
```

| Call | What it does |
|---|---|
| `warm(request, role:, rank:, activity:)` | The token into the provider's cache and a standby pre-connect (TCP + TLS) to the server the join will dial. No connect. Never throws. `activity: false` for a periodic refresh (e.g. your own room's token every 40 s): it does not count as user activity, so it neither wakes an idle pool nor keeps it rotating. |
| `prepare(request, abandonInBackground:, attachTimeout:)` | Starts the join now and returns its `GravixPrejoin`. The same handle while that session (room + identity + publish right) is live. Another session is left first; the new connect starts after that leave returned. `abandonInBackground` and `attachTimeout` override the constructor's for this one handle (`attachTimeout: null` = never; omitted = the constructor's). |
| `attach(request, hooks:, createRoom:, connect:, leave:, abandonInBackground:, attachTimeout:)` | The connected `Room` of the session the tap started, or a cold join when there was none. The hooks, `abandonInBackground` and `attachTimeout` (as for `prepare`; also on `attachResult` / `attachOrThrow`) are used only for that cold join; a live handle keeps its own. The screen claims the session at this call. |
| `attachOrThrow(request, hooks:, onHandle:, throwIf:)` | `attach` for a screen with try / catch: null when the session ended without an error; throws the token callback's own exception (unwrapped from `GravixTokenException`) or the connect's error. Safe to start before a permission dialog. See "An app's join layer". |
| `attachResult(request, hooks:)` | `attach` that never throws: `GravixAttach` (`room`, `handle`, `error`, `connectedBeforeAttach`, `isLive`). |
| `switchTo(request, beforeConnect:)` | The new room's token and server warmed now, the old session stopped now, your `beforeConnect` beside it, the new connect the moment both are done. `false` cancels. |
| `adopt(request, room, leave:)` | A Room you connected yourself (your own reconnect) becomes the current session, already attached. See below. |
| `abandon` / `leave` / `forgetAll` | End a join nobody will use / the real exit / drop every cached token and standby. |
| `onEvent` | `GravixJoinEvent`s on the tap's clock: `prejoinStart`, `tokenReady` (`cached`/`fetched`), `urlChosen`, `connectStart`, `connected`, `attached`, `shown`, `abandoned`, `left`, `switchStart`, `switchOldLeft`, `switchConnected`, `adopted`. |

Construct `GravixJoin` after `WidgetsFlutterBinding.ensureInitialized()` (e.g. in `main` before
`runApp`): it binds the standby pool to the app's lifecycle, which needs the binding. Built
earlier, call `GravixStandbyPool.instance.bindLifecycle()` yourself once the binding exists.

## What is safe by default

- **The app leaves before the room opens.** A prejoin is abandoned (its room left) when the app
  is hidden, paused or detached before `attach()`, or was started in the background.
  `GravixJoin(abandonInBackground: false)` for a join you make in the background on purpose
  (a call answered from a notification); `prepare(request, abandonInBackground: false)` for one
  handle, e.g. a host's own Go Live join started at the tap whose room screen is pushed only after
  your Go Live flow: a Home press in that window keeps it, and the screen may attach to it even
  while the app is still in the background (`attachTimeout` still applies, counting only the time
  the app is in front: see below). A handle allowed to survive the background still ends when
  the app is *detached* (its view destroyed, e.g. a Back that finished the activity) before a
  screen of it was shown: its screen can no longer come.
- **The room screen was built but never shown.** The screen claims the session the moment it
  *calls* `attach()` (call it in `initState`: the screen is up while the connect runs), not when
  `attach()` returns. From that call the handle watches until a frame was shown with the app
  resumed (a frame drawn while `inactive` does not count; the next one after the resume does);
  going to the background before that leaves the room (`ended` completes with
  `GravixPrejoinEndReason.neverShown`: close the screen; a pending `attach()` returns null). Once a
  frame was shown, Home / minimize never leaves, also while the connect is still running (the
  `shown` event can then come before `attached`).
  `attach(leaveIfNeverShown: false)` turns the watch off. `handle.markShown()` says a screen of
  the session is shown when you know better than the frame watch (e.g. drawn under an overlay):
  from then on the background never leaves, before or after `attach()`. A screen disposed before
  its first frame ends the handle (`leave()` / `abandon()`); its watch goes with it.
- **Nobody attaches.** The handle leaves after `attachTimeout` (20 s; `null` = never; per handle:
  `prepare(request, attachTimeout:)`). A screen that called `attach()` stops the timeout, however
  long the connect takes. The clock counts only the time the app is in front: it pauses while the
  app is hidden or paused (`[GravixJoin] attachTimeoutPaused`) and goes on with what was left
  when the app is resumed (`attachTimeoutResumed`); a handle started in the background starts
  paused. `inactive` (a shade, a dialog) does not pause it. So a host's Go Live join whose flow
  waits while the app is away is not timed out by the time spent away.
- **The leave reaches the server even when the app is going away.** When a handle is abandoned
  while connecting or connected (no screen yet: Back or Home after the tap, a gate, the attach
  timeout, a newer session), or for the background (`background` / `neverShown`), the signal
  leave goes FIRST: `room.disconnect()` is called (not awaited; it writes the Leave at once) and
  only then your leave hook runs (`[GravixJoin] leaveSignalFirst`). Your hook's own
  `disconnect()` is then harmless (one Leave per connection). The real exit of an attached room
  (`leave()`, a room switch from it) keeps your hook first, so it can stop your tracks and audio
  session before the disconnect; if the app is detached while that hook runs, the signal leave
  goes at once. Before, the engine could detach ~20 ms after a Back, before your hook reached its
  disconnect, and the others saw a ghost participant until the server timed it out (~30 s).
- **An abandoned join never ends joined.** A handle abandoned while its connect runs, also before
  your connect hook has called `room.connect()` (your own work first), is never left joined: the
  Room is marked so that a later `connect()` on it returns at once without connecting, and a
  connect that joins anyway (a Room you connected before) is left at once with the signal leave
  as soon as it reports connected or your hook returns (`[GravixJoin] leaveAfterLateConnect`).
  Your leave hook is not run a second time.
- **A dead Room is an ended session.** A connected or attached handle whose Room was
  disconnected after the connect (the server ended it, a kick, your own disconnect: the Room's
  `RoomDisconnectedEvent`, or `disconnected` with its engine closed) or disposed by you (e.g. your
  own reconnect failed and you tore the Room down) is not handed out again: `pendingFor` /
  `pending` / `current` return null, `prepare` / `attach` start a fresh join, `handle.attach()`
  returns null, and the handle ends with `GravixPrejoinEndReason.roomGone`. A resume or full
  reconnect under way is not a dead Room. The same live session still returns the same handle (a
  double tap, the screen's own `attach`).
- **A dead Room is never left again.** When a dead handle is superseded (the next `prepare` /
  `switchTo`), abandoned or left, your leave hook does NOT run: your own disconnect handling owns
  that cleanup, and a viewer rejoin after a drop does not stop and restart your audio session. The
  SDK disposes a dead Room only when it built it itself with the default `createRoom` and the
  default `leave`. A live handle superseded runs your leave hook once, as before.
- **A failed join drops out.** A handle that failed (token or connect: `GravixPrejoinEndReason.failed`)
  is no longer returned by `pendingFor` / `pending`, so its `error` is reachable only through the
  handle you kept: keep the one `prepare` returned (`final h = join.prepare(r); ... h.error`), or
  use `join.prepare(r).attach()` instead of `join.attach(r)` when the screen shows the failure.
- **Abandon while joining** ends the join at once (`Room.disconnect` ends its retries).
- **One session at a time** inside one `GravixJoin`, and one handle per session key
  (`GravixPrejoin.sessionKey(request)`: room + identity + `canPublish`).
- Events before `attach()` are not replayed: read `room.remoteParticipants` and
  `room.connectionState` after `attach()`, then listen.

## Keeping your own connect

An app that builds its Room and runs its own steps around the connect (audio session, listeners,
the microphone in the first offer) keeps them:

```dart
join.prepare(
  request,
  createRoom: () => myService.createRoom(),                       // listeners bound
  connect: (room, target) => myService.connectRoom(room, target.url, target.token),
  leave: (room) => myService.teardown(room),
);
```

### Your own reconnect (role change)

A role change (viewer to guest or host) is usually a new connect with a new token whose
`canPublish` differs, made by your own service outside `GravixJoin`. The session key changes, so
tell `GravixJoin` about the new Room, or its current session stays the old one (the next
`prepare` would run the old leave hook, and `leave()` would not leave the new room):

```dart
final room = await myService.reconnectWithToken(newToken); // your own teardown + connect
join.adopt(GravixTokenRequest(room: roomId, identity: uid, canPublish: true), room,
    leave: (room) => myService.teardown(room));
```

The adopted handle is attached already (`pending` / `attach` / `GravixPrejoin.pendingFor` return
it; no lifecycle guard, no never-shown watch, no attach timeout). The next `prepare` / `switchTo`
and `leave()` leave it. The previous session ends with `GravixPrejoinEndReason.replaced`
without its leave hook (you tore it down already; a screen does not close on `replaced`); one
still joining is abandoned normally. `GravixPrejoin.adopt(key:, room:, leave:, replaces:)` is the
same for the low-level handle.

The low-level handle is `GravixPrejoin.start(key:, target:, createRoom:, connect:, leave:)`
(no token provider, no pool); `GravixPrejoin.pendingFor(key)` finds it from the room screen.

## An app's join layer

Most apps put one small class between their screens and `GravixJoin`: one `GravixJoin` for the
app, the backend's token call, and the app's own connect handed to every join. With the hooks
bundle and the attach forms below, that class is only your own parts. A complete example (a room
list, the tap, the room screen with a permission dialog, a switch, a role change, the trace):

```dart
/// What one join of your app is: the token request + the flags your own connect reads.
class MyJoin {
  const MyJoin({required this.room, required this.uid, required this.host});
  final String room, uid;
  final bool host;
  // the ONE place the request is built: a warm-up and the tap must ask for the same token
  GravixTokenRequest get request => GravixTokenRequest(room: room, identity: uid, canPublish: host);
}

abstract final class AppJoin {
  static final GravixJoin join = GravixJoin(          // built after ensureInitialized()
    tokenProvider: GravixTokenProvider.callback(
      (r) => myBackend.joinToken(room: r.room, canPublish: r.canPublish), // may throw RoomRefused
      reuse: GravixTokenReuse.fastJoin,
    ),
    onEvent: _trace,
  );

  // your connect, per join: the same steps for the tap and a cold join from the screen
  static GravixJoinHooks hooks(MyJoin j) => GravixJoinHooks(
    createRoom: () => myRtc.createRoom(video: j.host),               // listeners bound
    connect: (room, target) => myRtc.connect(room, target.url, target.token, mic: j.host),
    leave: (room) => myRtc.teardown(room),
  );

  static void warm(MyJoin j, {int? rank}) => join.warm(
    j.request,
    role: rank == null ? GravixStandbyRole.touched : GravixStandbyRole.visible,
    rank: rank ?? 0,
  );
  static GravixPrejoin prepare(MyJoin j) => join.prepare(j.request, hooks: hooks(j));
  static GravixPrejoin switchTo(MyJoin j, Future<bool> Function() closeOld) =>
      join.switchTo(j.request, hooks: hooks(j), beforeConnect: closeOld);

  // the room screen: throws RoomRefused (your own exception, not GravixTokenException)
  static Future<Room?> attach(MyJoin j, {void Function(GravixPrejoin h)? onHandle}) => join.attachOrThrow(
    j.request,
    hooks: hooks(j),
    leaveIfNeverShown: !j.host,
    onHandle: onHandle,
    throwIf: (e) => e is! MyConnectFailed,   // your connect reported that one itself: null
  );

  // a role change: your own reconnect with the publish token
  static void adoptRoleChange(MyJoin publisher, Room room) =>
      join.adopt(publisher.request, room, hooks: hooks(publisher));

  static void _trace(GravixJoinEvent e) {
    final s = e.session;                       // room / identity / publish right
    if (e.kind == GravixJoinEventKind.urlChosen && s != null && s.canPublish) {
      myBackend.reportHostRegion(room: s.room, region: e.detail?.split(' ').first);
    }
    myTrace.mark(e.kind.name, e.sinceTap);
  }
}

// the room screen (initState -> initRtc)
Future<void> initRtc() async {
  final attaching = AppJoin.attach(widget.join, onHandle: (h) {
    h.ended.then((why) { if (why.leftBeforeShown && mounted) closeScreen(); });
  });
  final mic = await Permission.microphone.request(); // a token failure meanwhile is not "unhandled"
  final Room? room;
  try {
    room = await attaching;
  } on RoomRefused catch (e) {
    return showRefused(e);                         // your own message
  }
  if (!GravixJoin.isLive(room)) return;            // failed, ended, or the server ended it already
  bindListeners(room!);
  replayPresent(room.remoteParticipants);         // events before attach are not replayed
}
```

A screen that prefers a result to try / catch uses `attachResult`:

```dart
final r = await AppJoin.join.attachResult(j.request, hooks: AppJoin.hooks(j));
if (r.room == null) {
  if (r.error is RoomRefused) showRefused(r.error);
  return;
}
if (r.connectedBeforeAttach) replayPresent(r.room!.remoteParticipants);
```

| API | |
|---|---|
| `GravixJoinHooks(createRoom:, connect:, leave:)` | Your connect as one value, for `prepare` / `attach` / `attachResult` / `attachOrThrow` / `switchTo` / `adopt` (`hooks:`). A null field: the constructor's; an explicit argument wins. |
| `attachOrThrow` | Null when the session ended without an error; throws the unwrapped cause; `throwIf` picks which errors throw; `onHandle` gets the handle at the call. Its future is observed inside: a failure before your `await` is not an unhandled error (a future nobody awaits drops it; the handle's `error` and the log keep it). |
| `attachResult` / `GravixAttach` | Never throws; `error` is unwrapped; `connectedBeforeAttach`: the connect's participant events went out before you listened. |
| `GravixJoin.unwrapError(e)` | The cause inside a `GravixTokenException` (your token callback's exception), else `e`. |
| `GravixJoin.isLive(room)` | Not null and not `disconnected`. |
| `join.hasToken(request)` / `join.dropToken(request)` | A warm-up landed / forget a cached token (e.g. before a viewer's rejoin). |
| `GravixJoinEvent.session` / `GravixPrejoin.parseSessionKey(key)` | Room / identity / publish right of a session key. |
| `GravixPrejoinEndReason.leftBeforeShown` | `background` / `neverShown`: the user left before the room was shown; close the screen normally. |

## Rooms this SDK cannot join (old servers)

Some live rooms are hosted by old app builds on an old server this SDK does not join. Their join
is refused, not failed: the token callback refuses the room (your own "old app version"
exception), or the token answer's url names a retired Gravix server (`RetiredServerException`,
built in). `GravixJoin` treats a refusal differently from a failure:

```dart
final join = GravixJoin(
  tokenProvider: GravixTokenProvider.callback(myTokenCall, reuse: GravixTokenReuse.fastJoin),
  // your own exception types (given the error unwrapped from GravixTokenException)
  isRefusal: (e) => e is MyOldAppRoomException,
  refusalMemo: const Duration(seconds: 60), // the default
);

// ... or throw the SDK's type from the token callback (no isRefusal needed):
//   if (answer.hostAppOutdated) throw const GravixRoomRefused('host_app_outdated');

if (join.isRefused(card.request)) showOldAppBadge(card); // no I/O
```

- **What is a refusal**: a `RetiredServerException`, a `GravixRoomRefused` thrown by the token
  callback (or your connect hook), or what `isRefusal` says of your own exception (it gets the
  error unwrapped from the provider's `GravixTokenException`; a predicate that throws counts as
  "not a refusal"). `join.isRefusalError(e)` / `GravixRoomRefused.classify(e, isRefusal)` answer it
  for any error.
- **`warm`**: one `[GravixJoin] warmRefused key=... reason=<type>` line (not `warmFail`; the type
  only, never the message) and a `GravixJoinEventKind.refused` event; the room is remembered for
  `refusalMemo`. Warms of that room inside the memo do nothing: no token call, no standby, at most
  one `warmSkip ... reason=refused` line (verbose). After the memo the next warm asks again (the
  host may have updated).
- **`prepare` / `attach` / `attachResult` / `attachOrThrow`**: the token callback is still asked
  (you may want to show your old-app message), the join ends at once (`GravixPrejoinEndReason.failed`,
  `handle.refused` true), the line and event are `refused` (not `connectFail` / `connectFailed`, no
  `tokenFail`), `attachOrThrow` throws your own error and `GravixAttach.error` is it; the memo is
  renewed.
- **Ends the memo**: a token for the room (a warm or a join), `forgetAll()`, or `refusalMemo`
  elapsing. `Duration.zero`: refusals are classified and logged but never remembered. The memo is
  per room (any identity / publish right), at most 256 rooms.
- **Never a failure**: `GravixRejoinPolicy(isRefusal:, onRefused:)`: a `rejoin` that throws a
  refusal is not counted (`attempts` / `total` unchanged), not retried and does not call
  `onGaveUp` (a Retry cannot join it); `onRefused` gets your error, `roomRefused` is true until
  `liveBack`. A `rejoin` that only returns false cannot be told apart from a failure: throw the
  refusal to get this.

## The pieces, usable on their own

| API | |
|---|---|
| `GravixTokenReuse.fastJoin` | a cached token is presented only while younger than half its lifetime and 5 min, with >= 90 s left. Without `reuse:` the provider keeps its rule (>= `minRemainingValidity`, 60 s). |
| `gravixJoinUrl(credentials)` | the url a join dials: the measured region; a viewer's room home region when it is within max(25 ms, 30 %) of the fastest; a url outside the measured fleet is never redirected. `.withStandby(...)`: an open standby in another of the token's regions wins (never over the home region). |
| `GravixStandbyPool` (`instance`) | one standby per server for the servers the user is likeliest to join (touched > own region > visible by position, at most 3), rotated every 40 s while active, closed after 3 min idle and in the background, re-opened on resume (`bindLifecycle`); `explain(url, token)` for a join trace. |
| `GravixRejoinPolicy` | a viewer joins again when the live is back, and after a session that ended by itself while the live is on (1/2/4/8 s; never after a kick, another device, a deleted room or a refused join; 3 per incident, 12 per live; an optional entry check; a refused room is not counted: `isRefusal` / `onRefused`). The app supplies `liveOn` and the `rejoin`. |
| `GravixRoomRefused` | a room this SDK cannot join: throw it from the token callback; `classify` / `isBuiltIn` / `unwrap`. See "Rooms this SDK cannot join (old servers)". |
| `gravixConnectWhileAlive` | a connect that leaves the session again when the screen closed meanwhile. |

## Not in the package

Your backend's token call, your room rules (password, payment, bans, seats), routes, the
switch's visual cover and the server-side exit of the old room stay in the app.
