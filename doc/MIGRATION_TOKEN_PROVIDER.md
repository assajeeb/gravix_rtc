# Moving from key+secret on the device to a token provider

**Status:** the deprecated key+secret client (`GravixCloudBackend`, deprecated
since 2026-09-19) is **not part of gravix_rtc**. The package gets its join
token from a `GravixTokenProvider`. This page is how to move an app that sent
the gateway secret from the device over to a provider.

## Why

A key+secret client sends `api_key` + `api_secret` from the phone to the token
gateway. To do that the secret has to be inside the app, and anything inside an
app can be read out of it, however it is encoded. Whoever holds the secret can mint a token for
**any room, as any identity, with publish rights**, and every one of those
sessions is billed to you.

The fix is structural, not cryptographic: **the secret lives on a server you
control; the app only ever receives a token.**

```
before:  app ──(api_key, api_secret, room, identity)──▶ gateway ──▶ token
after:   app ──(your session, room)──▶ YOUR backend ──(api_key, api_secret, …)──▶ gateway
         app ◀──────────── the gateway's response, unchanged ◀────────────────────┘
```

## The three ways to give the SDK a token

All three produce the same `GravixJoinCredentials` (token, url, `regionEntries`)
and are used the same way.

```dart
// (a) You already have a token.
final provider = GravixTokenProvider.literal(
  token: token,
  url: url,
  regionEntries: gravixRegionEntriesFrom(response), // optional
);

// (b) You fetch it yourself (Parse SDK, gRPC, anything). Return the gateway's
//     response map as you received it.
final provider = GravixTokenProvider.callback((request) async {
  final result = await ParseCloudFunction('gravixToken').execute(parameters: request.toJson());
  return Map<String, dynamic>.from(result.result as Map);
});

// (c) Your backend's URL. The SDK POSTs {room, identity, name, can_publish}
//     with YOUR session headers and expects the gateway's response back.
final provider = GravixTokenProvider.endpoint(
  Uri.parse('https://api.example.com/rtc/token'),
  headers: {'Authorization': 'Bearer $sessionToken'},
);
```

Then, instead of fetching a token on the device with the secret + `room.connect(...)`:

```dart
const request = GravixTokenRequest(room: roomId, identity: uid, name: displayName, canPublish: isHost);

final ok = await room.connectWithTokenProvider(
  tokenProvider: provider,
  request: request,
  regionProbe: true,            // optional, as before
);
if (!ok) print(room.lastTokenError); // null when the failure was the connect, not the token
```

`connectWithTokenProvider` passes the url, the token **and the `region_urls`
(region slug and `probe_url` included)** from the response into `connect`. There
is nothing to thread through by hand, so there is nothing to drop on the way.

**Build one provider and keep it** (per app, or per logged-in user). The cache
lives in the instance; a provider created for every join caches nothing.

## It must not cost the tap a round trip

A provider caches. `getCredentials(request)` for a request whose token is still
valid returns immediately, without touching the network. So fetch **before** the
user taps — when the room list opens, or when a row scrolls into view:

```dart
unawaited(provider.getCredentials(request)); // room list opened
…
await room.connectWithTokenProvider(tokenProvider: provider, request: request); // tap: 0 token round trips
```

`GravixRoomService.prewarm(...)` (see `doc/FAST_CONNECT_INTEGRATION.md`) does this
and more. On a cold provider the tap pays for exactly one token request — the
same one the old flow always paid. It never pays for two.

## Caching, expiry, timeout — the exact rules

| | |
|---|---|
| Cache key | `room`, `identity`, `name`, `canPublish`. A host token is never reused for a listener join, or the other way round. |
| Expiry | The JWT's `exp`, read without verifying the signature (the SFU is the judge of that). An opaque token uses `expires_in` from the response, else `unknownExpiryTtl` (5 min). |
| Reuse | Only while the token has `minRemainingValidity` (60 s) left, and its `nbf` has passed. A token with three seconds left is a join that fails at the last step. |
| Timeout | `timeout`, default **8 s**, on every variant including your callback. Before this neither SDK had a token timeout at all: a backend that accepted the connection and then stalled held the join forever. |
| Concurrency | Concurrent calls for the same request share one in-flight fetch. |
| Failure | Never cached. Throws `GravixTokenException` with `reason`: `timeout`, `http` (+ `statusCode`), `malformed`, `callback`, `expired`. The message never contains a token, a header or a response body. |
| Bound | `maxEntries` (16), least-recently-used eviction. |
| Refresh | `getCredentials(request, forceRefresh: true)`, or `invalidate([request])` — e.g. after the server changed the user's role. |

## The wire contract of variant (c)

Request — `POST`, `Content-Type: application/json`, plus your headers:

```json
{ "room": "abc", "identity": "42", "name": "Alice", "can_publish": false }
```

These are the gateway's `/v1/token` field names **minus** `api_key` and
`api_secret`. The SDK never sends a credential it was not handed as a header.

Response — the gateway's `/v1/token` response, **returned unchanged**:

```json
{
  "token": "<jwt>",
  "url": "wss://…",
  "region_urls": [
    { "region": "sgp1", "url": "wss://…", "probe_url": "https://…/v1/region-probe", "home": true },
    { "region": "blr1", "url": "wss://…", "probe_url": "https://…/v1/region-probe", "home": false }
  ]
}
```

Do not rebuild this object field by field on your server. `region_urls` and each
entry's `probe_url` are what let the client join the nearest region; a backend
that returns only `{token, url}` silently pins every user to one region.

Also accepted: a Parse Cloud Function envelope `{"result": { …the above… }}`
(unwrapped for you), and the upstream token-source shape
`{"participant_token", "server_url"}` (no regions).

## Server side: a Parse Server cloud function

The secret is read from the server's environment. It is not in the app, not in
the repository, and not in the response.

```js
// cloud/main.js — runs on YOUR Parse Server.
// Environment (set on the server, never committed):
//   GRAVIX_GATEWAY_URL   e.g. https://<GATEWAY_HOST>
//   GRAVIX_API_KEY
//   GRAVIX_API_SECRET
Parse.Cloud.define('gravixToken', async (request) => {
  // 1. Only a logged-in user gets a token.
  const user = request.user;
  if (!user) {
    throw new Parse.Error(Parse.Error.INVALID_SESSION_TOKEN, 'login required');
  }

  const room = String(request.params.room || '');
  if (!room) {
    throw new Parse.Error(Parse.Error.VALIDATION_ERROR, 'room is required');
  }

  // 2. Identity and name come from the SESSION, never from the request body.
  //    A client that could choose its own identity could join as anyone.
  const identity = String(user.get('uid') ?? user.id);
  const name = String(user.get('name') ?? user.get('username') ?? identity);

  // 3. The client ASKS for publish rights; the server DECIDES. Replace this with
  //    your own rule (room owner, co-host list, seat table, …).
  const wantsPublish = request.params.can_publish === true;
  const canPublish = wantsPublish && (await userMayPublish(user, room));

  // 4. Call the gateway with the secret, under a timeout: a stalled gateway must
  //    become an error the app can show, not a spinner that never ends.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5000);
  let response;
  try {
    response = await fetch(`${process.env.GRAVIX_GATEWAY_URL}/v1/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      signal: controller.signal,
      body: JSON.stringify({
        api_key: process.env.GRAVIX_API_KEY,
        api_secret: process.env.GRAVIX_API_SECRET,
        room,
        identity,
        name,
        can_publish: canPublish,
      }),
    });
  } catch (e) {
    throw new Parse.Error(Parse.Error.CONNECTION_FAILED, 'token gateway unreachable');
  } finally {
    clearTimeout(timer);
  }
  if (!response.ok) {
    // Do not forward the gateway's body: it can describe your account.
    throw new Parse.Error(Parse.Error.SCRIPT_FAILED, `token gateway answered ${response.status}`);
  }

  // 5. Return the gateway's response UNCHANGED - token, url and region_urls
  //    (with probe_url). Do not log it: it contains a live token.
  return await response.json();
});

async function userMayPublish(user, room) {
  const q = new Parse.Query('Room');
  q.equalTo('roomId', room);
  const r = await q.first({ useMasterKey: true });
  return !!r && (r.get('hostId') === user.id || (r.get('cohostIds') || []).includes(user.id));
}
```

Client, variant (c), straight at the function:

```dart
final provider = GravixTokenProvider.endpoint(
  Uri.parse('https://parse.example.com/parse/functions/gravixToken'),
  headers: {
    'X-Parse-Application-Id': parseAppId,
    'X-Parse-Session-Token': currentUser.sessionToken!,
  },
);
```

Parse wraps the return value as `{"result": …}`; the SDK unwraps it. The function
ignores the `identity` and `name` the SDK posts and uses the session's — that is
the point. (They are still part of the cache key on the client, so keep passing
the real ones.) A session token that rotates means a new provider, or variant
(b) with the Parse SDK doing the call.

The same five steps apply to any backend (Node, Go, Laravel, a Firebase
callable): authenticate the caller, derive identity server-side, decide publish
rights server-side, call the gateway under a timeout with the secret from the
environment, return the response unchanged.

## After you migrate

**Rotate the secret.** Every build that ever shipped it is still out there, and
a secret that was in an APK is a secret that has leaked. Migrating without
rotating changes nothing for an attacker who already has it.

## What else to know

- `GravixRoomService.connect(url:, token:, …)` — the raw path is untouched.
- Promoting a listener to publisher has no provider equivalent on purpose: promoting a participant
  is a server-side decision and should be a call to **your** backend, which
  then calls the gateway's upgrade endpoint.
