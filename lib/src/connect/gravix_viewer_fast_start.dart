// Copyright Gravity Compile, Inc. Apache 2.0.

/// Faster first remote frame for a subscriber (a viewer joining a live): the
/// subscriber peer connection's handshake and the first track settings. Each
/// switch is its own rollback; read at every join / subscription.
///
/// Measured on the phone that motivated it (2201117TG, Android 13, Wi-Fi, ~60 ms
/// RTT to the SFU, a web publisher in the room, 2026-10-04; native libwebrtc log):
///
///  - The SFU offers the subscriber connection with `a=setup:actpass` and, being
///    a full-ICE CONTROLLING agent, nominates the pair on its own check loop (a
///    200 ms tick after a 50 ms srflx acceptance wait). The phone's libwebrtc
///    answers `a=setup:active`, so it is the DTLS CLIENT and sends its
///    ClientHello the moment ICE is writable on ITS side -- ~270 ms before the
///    SFU's DTLS endpoint exists. Those hellos are lost; libwebrtc retransmits
///    after 116 ms, then 232, then 464 (backoff from the ICE RTT), and the one
///    that lands is whichever comes after the SFU is ready: DTLS took 384 ms for
///    two ~60 ms round trips, and a retransmit that just missed costs +464 ms
///    (tap -> PC connected 1.1-1.2 s in 2 of 8 warm joins).
///  - [passiveSubscriberDtls] answers `a=setup:passive` instead: the phone is the
///    DTLS SERVER (listening from ICE-writable on) and the SFU, as client, sends
///    its ClientHello the moment ITS ICE is connected. No hello is sent into the
///    void, so there is no retransmission schedule to land on.
abstract final class GravixViewerFastStart {
  /// Subscriber answers carry `a=setup:passive` (the phone is the DTLS server
  /// of the subscriber connection). Every subscriber answer of a connection is
  /// edited the same way, so a renegotiation never asks libwebrtc to change a
  /// negotiated DTLS role. The publisher connection (the phone offers) is not
  /// touched. Default on; `false` = the libwebrtc default (`a=setup:active`).
  /// Not gated by server: a stock upstream server's join response cannot be told
  /// from a Gravix one (both report edition Standard and the same version), and
  /// stock upstream server 1.4.5 / 1.6.2 / 1.7.2 / 1.8.4 / 1.13.7 all accepted a
  /// passive answer and sent media (pion offerer: a passive answer makes it the
  /// DTLS client; tested 2026-10-05).
  static bool passiveSubscriberDtls = true;

  /// With adaptive stream on, a remote video track that has no renderer YET
  /// (the subscription arrives a frame before the app builds its view) is not
  /// reported as `disabled` at once: the periodic visibility check reports it
  /// after its usual debounce if no view appears. Up to 0.4.8 the SDK sent
  /// `disabled: true` the instant the track was subscribed and `enabled` again
  /// one frame later, when the view built -- two signalling messages, and if the
  /// view built after the SFU bound the track, a paused stream that then had to
  /// wait for a new keyframe. Default OFF since 0.4.9 (`false` = the 0.4.8
  /// behaviour, exactly): the 2026-10-04 traces showed both messages landing
  /// before the SFU bound the track, so no measurable first-frame gain, and the
  /// project ships an unproven default off. Kept as an opt-in (one-flag
  /// rollback either way).
  static bool noDisableBeforeFirstView = false;

  /// While the subscriber connection connects, libwebrtc's ping interval for a
  /// writable-but-not-yet-stable pair (`stableWritableConnectionPingIntervalMs`,
  /// default min(2500, 900) ms) is this many ms; it goes back to the default once
  /// the connection is connected. Why: the SFU (pion, full ICE, controlling)
  /// nominates a pair the moment a check from the phone arrives on a pair it has
  /// already validated, and otherwise only on its 200 ms check tick; the phone's
  /// three fast checks are spent before the SFU has the answer, and its next one
  /// is ~900 ms away -- measured: the SFU's DTLS hello came 270-320 ms after the
  /// phone's ICE was writable (100 ms here: 135-207 ms; DTLS writable ->
  /// complete 383/407 -> 202/295 ms, n=2 each).
  ///
  /// Default OFF (`null`) since 0.4.9; an app opts in with e.g. `100`. Why off:
  ///  - the pub.dev flutter_webrtc (1.6.0 and 1.6.2+hotfix.3, checked
  ///    2026-10-05) maps NEITHER key on Android or iOS, so with a stock plugin
  ///    the switch does nothing at all;
  ///  - a plugin fork that maps `stableWritableConnectionPingIntervalMs` but not
  ///    `iceCheckIntervalStrongConnectivityMs` gets a configuration libwebrtc
  ///    REFUSES, and flutter_webrtc's Android `peerConnectionInit` does not
  ///    surface that: it returns an id for a null native peer connection, so
  ///    nothing throws and the join just hangs (seen 2026-10-04). Whether the
  ///    keys are honoured cannot be read back either -- the Dart
  ///    `getConfiguration()` returns the map it was given, not the native
  ///    state -- so the SDK cannot detect a half-mapped fork at run time.
  /// Opt in only with a flutter_webrtc that maps BOTH keys (the SDK always
  /// sends both, [gravixWithSubscriberConnectPing]).
  static int? subscriberConnectPingIntervalMs;
}

/// [config] (a peer connection configuration map) with the connect-time ping
/// interval of [GravixViewerFastStart.subscriberConnectPingIntervalMs]. The
/// strong-connectivity check interval (default 480 ms) is lowered with it:
/// libwebrtc REFUSES a configuration whose stable-writable interval is shorter
/// ("Invalid ICE configuration", createPeerConnection fails and the join hangs;
/// seen on the phone 2026-10-04 with the first key alone).
Map<String, dynamic> gravixWithSubscriberConnectPing(Map<String, dynamic> config, int intervalMs) => {
  ...config,
  'stableWritableConnectionPingIntervalMs': intervalMs,
  'iceCheckIntervalStrongConnectivityMs': intervalMs,
};

/// [sdp] with every `a=setup:active` line replaced by `a=setup:passive`, line
/// endings kept. Lines with any other role (`passive`, `actpass`) are left
/// alone: an answer libwebrtc already made passive stays so.
String gravixPassiveDtlsAnswer(String sdp) =>
    sdp.replaceAllMapped(RegExp(r'^a=setup:active(?=\r?$)', multiLine: true), (_) => 'a=setup:passive');

/// Whether a newly subscribed remote video track skips its immediate
/// visibility report ([GravixViewerFastStart.noDisableBeforeFirstView]): only
/// when the switch is on and no view of the track exists yet. With a view
/// already registered (an app that reuses a renderer) the report is sent at
/// once, as before.
bool gravixSkipFirstVisibilityReport({required bool enabled, required int viewCount}) => enabled && viewCount == 0;
