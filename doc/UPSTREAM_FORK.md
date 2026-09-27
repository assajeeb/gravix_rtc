# Upstream fork: what `lib/src/rtc_core/` is, and what a rebase costs

**Report only. Nothing was changed for this document.**

## 1. Which upstream version this is forked from

**`livekit_client` 2.11.0.**

Evidence, three independent ways:

- `lib/src/rtc_core/src/gravix.dart:26` — `static const version = '2.11.0';`
  (the upstream `LiveKitClient.version` constant, carried across verbatim).
- File-for-file identity with the upstream v2.11.0 tree: 151 Dart files under
  `lib/src/rtc_core/` and 151 Dart files under upstream `lib/` at tag
  `v2.11.0`, matching 1:1 once the renames are applied
  (`livekit_client.dart` → `gravix_client.dart`, `src/livekit.dart` →
  `src/gravix.dart`, `src/proto/livekit_*.dart` → `src/proto/gravixcloud_*.dart`).
  No file is present on one side and absent on the other.
- A reference checkout of upstream `client-sdk-flutter` at
  `v2.11.0-3-gf62d479` — v2.11.0 plus three commits. The vendored tree matches
  the **tag**, not that HEAD, so the three post-tag upstream commits
  (`f62d479` Flutter 3.38 / Dart 3.10 minimums for native assets, `2328913`
  subscriber data-channel state events, `2f09e20` `discardFrameWhenCryptorNotReady`)
  are **not** in this fork.

For reference the JS sibling is vendored the same way, from `client-sdk-js`
v2.21.0.

## 2. `git log --stat` of upstream files touched

Exactly **one** commit in this repository has ever touched
`lib/src/rtc_core/`:

```
$ git log --oneline --all -- lib/src/rtc_core
84f4bb7 Vendor+purge RTC core; add room service, music mixer, beauty interface, backend

$ git log --stat 84f4bb7 -1 -- lib/src/rtc_core | tail -1
 151 files changed, 47824 insertions(+)

$ git show --stat 84f4bb7 | tail -1      # the whole commit, incl. non-upstream files
 183 files changed, 52834 insertions(+), 272 deletions(-)
```

All 47,824 lines are insertions: the vendor drop created the tree, and nothing
has edited it since. Every Gravix feature — the v2 audio routing stack, the
probe-race connect, the room service, the music mixer, the beauty interface,
the token backend — lives **outside** `lib/src/rtc_core/`, in `lib/src/audio/`,
`lib/src/connect/`, `lib/src/room/`, `lib/src/large_room/`, `lib/src/music/`,
`lib/src/beauty/` and `lib/src/backend/`.

The per-directory shape of the vendored tree:

| Files | Directory |
| --- | --- |
| 13 | `src/support` |
| 12 | `src/types` |
| 12 | `src/token_source` |
| 11 | `src/audio` |
| 10 | `src/track` |
| 9 | `src/proto` |
| 9 | `src/connection_check/checks` |
| 7 | `src/core` |
| 5 | `src/agent`, 5 `src/agent/chat` |
| 4 | `src/track/web`, 4 `src/publication`, 4 `src/e2ee` |
| … | 51 more across 15 smaller directories |

## 3. How far the vendored tree has actually diverged

`git log` says "one commit, all insertions", which is true but not the whole
answer — the divergence that matters is between the vendored tree and upstream
v2.11.0, and that was introduced *inside* the vendor commit.

Measured by normalising away branding (`LiveKit`→`Gravix`, package and proto
renames) and then comparing comment-stripped, whitespace-stripped token
streams:

| | Files |
| --- | --- |
| Identical to upstream v2.11.0 once branding and formatting are normalised | **95 / 151** |
| Substantively different | **56 / 151** |

And of those 56, the volume is concentrated in generated code:

| Changed chars | File | What it is |
| --- | --- | --- |
| 89,543 | `src/proto/gravixcloud_rtc.pbjson.dart` | regenerated protobuf — `package livekit;` → `gravixcloud` |
| 33,631 | `src/proto/gravixcloud_models.pbjson.dart` | same |
| 1,563 | `src/token_source/token_source.g.dart` | regenerated `json_serializable` |
| 1,075 | `src/proto/gravixcloud_metrics.pbjson.dart` | regenerated protobuf |
| 654 / 647 / 628 | `jwt.g.dart`, `agent_attributes.g.dart`, `room_configuration.g.dart` | regenerated `json_serializable` |
| 325 / 300 / 30 | `*_rtc.pb.dart`, `*_models.pb.dart`, `*_metrics.pb.dart` | regenerated protobuf |
| 150 | `src/core/engine.dart` | branding only (see below) |
| 98 | `src/token_source/jwt.dart` | branding only |
| 57 | `src/core/room.dart` | branding only |
| ≤ 48 | 44 further files | branding only |

Spot-checking the hand-written files that differ — `engine.dart`, `room.dart`,
`exceptions.dart`, `region_url_provider.dart` — **every remaining difference is
branding or formatting**: the copyright header (`LiveKit, Inc.` → `Gravity
Compile`), identifier renames the blanket substitution does not cover
(`LiveKitException` → `GravixRtcException`, `LiveKitWebSocket` →
`GravixRtcWebSocket`), the cloud host check (`.livekit.cloud` /
`.livekit.run` → the Gravix Cloud domains), and `dart format`
reflow under this repo's formatter settings.

**There is no logic divergence from upstream 2.11.0 in the vendored core.** No
behaviour was patched in place; the audio-routing fixes sit in a layer above
it, talking to the core through its public `AudioManager` API.

## 4. Rebase risk

The risk is **high in mechanical cost and near-zero in semantic cost** — an
unusual and, for a rebase, a fortunate combination.

**Why it is mechanically expensive.** Three repo-wide rewrites were applied on
top of the vendor drop, and each one touches essentially every file:

1. **The rename.** `LiveKit`/`livekit` → `Gravix`/`gravix` across identifiers,
   imports, strings and comments, plus file renames. Every upstream hunk that
   mentions the old names conflicts.
2. **The reformat.** The tree was re-formatted with this repo's settings
   (trailing-comma reflow, different line length). This alone rewrites most
   multi-line call sites in files that are otherwise untouched, so even an
   upstream change to a single argument arrives as a conflict against
   reformatted context.
3. **The proto regeneration.** `package livekit;` → `gravixcloud`, so all nine
   `src/proto/*.dart` files are wholly different text from upstream's. Any
   upstream protocol bump (2.11.0 shipped protocol v1.50.4) has to be
   *regenerated* here, not merged. These are the largest files in the tree and
   a textual merge of them is meaningless.

A plain `git rebase` or `git merge` against upstream would therefore conflict
in roughly every file it touches, and most conflicts would be noise.

**Why it is semantically cheap.** Because the answer to "what did we change in
the core?" is *nothing*. A resync does not have to preserve local logic,
because there is none to preserve. That makes the tractable strategy a
**re-vendor rather than a rebase**:

1. Check out the new upstream tag.
2. Re-run the rename and the proto regeneration as a scripted, reviewable
   transformation — the same script that produced `84f4bb7`, which is worth
   committing to this repo if it is not already somewhere.
3. Re-run `dart format` with this repo's settings.
4. Replace `lib/src/rtc_core/` wholesale.
5. Diff the *Gravix* layers (`lib/src/audio/`, `lib/src/connect/`,
   `lib/src/room/`, …) against the new core's API surface. This is the only
   part that needs human judgement, and it is small: the surfaces actually
   consumed are `AudioManager`, `Room`, `LocalParticipant`, `Hardware`, the
   event types, and `sdkHttpHead` / `toHttpUrl`.
6. Run `flutter test` and `tool/check_analyze.sh`.

**Concrete risks for the next resync, in order:**

- **The three post-2.11.0 commits change the minimum toolchain.** `f62d479`
  raises the floor to Flutter 3.38 / Dart 3.10 for native assets. This package
  already declares those floors, so it is likely free — but a native-assets
  build hook is the kind of change that does not survive a file-copy vendor
  and needs checking against `android/` and `ios/`.
- **Protocol regeneration is a separate, scriptable step** and is the one place
  where a careless resync produces a tree that compiles and is wrong on the
  wire.
- **`AudioManager.setSpeakerOutputPreferred` is the single upstream API the v2
  routing stack depends on for control** (plus `setAudioSessionManagementMode`,
  `setAudioSessionOptions`, `deactivateAudioSession`). If a future upstream
  reshapes those — LiveKit has been actively reworking the audio session
  surface — the whole of `lib/src/audio/` is affected. `GravixAudioPlatform` is
  the one file that would need editing, which is the seam doing its job, but it
  is the file to look at first after any resync.
- **The two baselined analyze warnings live in vendored code**
  (`src/token_source/caching.dart`). A resync may move, fix or duplicate them;
  `tool/analyze_baseline.txt` will need updating and is deliberately
  line-number-free so only a real change forces that.
- **The baseline for "have we diverged?" should be kept.** The cheapest way to
  keep this document honest is to re-run the token-stream comparison in §3
  after each resync; if the "identical once normalised" count ever drops
  sharply, someone has started patching the core in place and the re-vendor
  strategy quietly stops working.
