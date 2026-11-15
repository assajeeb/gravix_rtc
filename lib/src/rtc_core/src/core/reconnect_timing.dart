// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.
//
// GRAVIX (0.10.2, 2026-11-15, Edu reconnect rig): reconnect timing after long network cuts.
// After a 30-90 s cut the SDKs reached the SFU up to ~23 s after the network was back: each dial
// waited out its timeout while TCP backed off, then 7 s + jitter, so no dial was in flight when
// the network returned (the SFU answers in ~40 ms once reached). The rules, as in the JS SDK
// (src/core/room/gravix/reconnectTiming.ts):
// - a reconnect dial must get a connection up within GravixRecoveryOptions.reconnectDialTimeout;
//   every 4th dial in a row with none gets a long one, so a slow but live path still connects;
// - after a dial with no connection the wait is capped (reconnectRetryDelayCap); after a failure
//   the server answered, the old back-off stays (no extra load on a restarting server);
// - the default policy gives up on time (reconnectGiveUpAfter), not after 10 attempts.
import 'dart:math' as math;

import 'reconnect_policy.dart';

/// Every this-many-th reconnect dial in a row with no connection is a long one.
const int kGravixLongDialEvery = 4;

/// The shortest long dial: long enough for the SYN TCP sends at 7 s.
const Duration kGravixLongDialMin = Duration(seconds: 8);

/// How long the next reconnect dial may wait for a connection to come up. [cap] is
/// `reconnectDialTimeout` (zero: off, null is returned), [noConnectionInARow] the dials in a row
/// before this one that got no connection, [dialTimeout] the dial's own timeout (never exceeded).
Duration? gravixReconnectConnectWithin(Duration cap, Duration dialTimeout, int noConnectionInARow) {
  if (cap <= Duration.zero) return null;
  final long = noConnectionInARow % kGravixLongDialEvery == kGravixLongDialEvery - 1;
  var d = cap;
  if (long) {
    d = cap * 2;
    if (d < kGravixLongDialMin) d = kGravixLongDialMin;
  }
  return d < dialTimeout ? d : dialTimeout;
}

/// [gravixReconnectConnectWithin] for a full reconnect's dial: on the long slot (every 4th dial in
/// a row with no connection) no bound at all, so that dial keeps the 0.10.1 bounds -- raced
/// connections up to `signalDialCap` with the upgrade window -- for a path whose connections take
/// 10-25 s to come up (device recheck 2026-10-11, "Very Bad Network"). Its raced connections send
/// fresh SYNs every `Timeouts.connection`, so a cut that ends during it is still seen within ~4 s.
Duration? gravixFullReconnectConnectWithin(Duration cap, Duration dialTimeout, int noConnectionInARow) {
  if (noConnectionInARow % kGravixLongDialEvery == kGravixLongDialEvery - 1) return null;
  return gravixReconnectConnectWithin(cap, dialTimeout, noConnectionInARow);
}

/// The wait in ms before the next reconnect attempt, or null to give up. An app's own policy (or
/// a [DefaultReconnectPolicy] with the app's own table) decides alone; the SDK's default policy
/// gets the time budget [giveUpAfter] and, after a dial with no connection, the cap [retryDelayCap]
/// (from half of it to all of it: the jitter stays).
int? gravixReconnectDelay(
  ReconnectPolicy policy,
  ReconnectContext context, {
  required bool lastDialTimedOut,
  required Duration retryDelayCap,
  required Duration giveUpAfter,
  math.Random? random,
}) {
  final ctx = ReconnectContext(
    retryCount: context.retryCount,
    elapsedMs: context.elapsedMs,
    retryReason: context.retryReason,
    serverUrl: context.serverUrl,
    gravixLastDialTimedOut: lastDialTimedOut,
  );
  var delay = policy.nextRetryDelayInMs(ctx);
  if (!(policy is DefaultReconnectPolicy && policy.gravixDefaultTable)) return delay;
  if (giveUpAfter > Duration.zero) {
    if (ctx.elapsedMs >= giveUpAfter.inMilliseconds) return null;
    if (delay == null && policy.maxAttempts > 0) {
      // past the table: keep its last step (with its jitter) until the budget is spent
      delay = policy.nextRetryDelayInMs(
        ReconnectContext(
          retryCount: policy.maxAttempts - 1,
          elapsedMs: ctx.elapsedMs,
          retryReason: ctx.retryReason,
          serverUrl: ctx.serverUrl,
          gravixLastDialTimedOut: lastDialTimedOut,
        ),
      );
    }
  }
  final cap = retryDelayCap.inMilliseconds;
  if (delay != null && lastDialTimedOut && cap > 0 && delay > cap) {
    final r = (random ?? math.Random()).nextDouble();
    delay = (cap / 2 + r * (cap / 2)).round();
  }
  return delay;
}
