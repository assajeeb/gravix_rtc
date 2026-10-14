// Copyright (c) 2026 Gravity Compile. Apache 2.0.

/// How a room recovers from network and region failures (0.4.15).
///
/// Every field is a separate switch. Each one's OFF value is exactly the 0.4.14
/// behaviour; [GravixRecoveryOptions.legacy] turns all of them off at once. Pass
/// it as `RoomOptions(recovery: ...)` or `GravixRoomService(recovery: ...)`.
class GravixRecoveryOptions {
  const GravixRecoveryOptions({
    this.upstreamReconnectFixes = true,
    this.measuredRegionFailover = true,
    this.retrySameUrlFirst = true,
    this.sameUrlRetryDialTimeout = const Duration(milliseconds: 2500),
    this.publisherRestartRetryAfter = const Duration(milliseconds: 2500),
    this.subscriberSufficientWhenIdle = true,
    this.earlyStallDetection = true,
    this.stallNoPacketsFor = const Duration(seconds: 2),
    this.stallMinInterval = const Duration(seconds: 10),
    this.noVideoWatchdog = true,
    this.noVideoFor = const Duration(seconds: 4),
    this.noVideoWindow = const Duration(seconds: 15),
    this.noVideoMinInterval = const Duration(seconds: 60),
    this.keepParticipantsOnRejoin = true,
    this.republishStoppedTracksMuted = true,
    this.startBitrateBySetupTime = true,
    this.resumePrimaryDeadline = const Duration(seconds: 3),
    this.leaveAbortsResumeWait = true,
    this.networkWaitProbeInterval = const Duration(seconds: 2),
    this.failoverNeedsEvidence = true,
    this.rejoinAbsentGrace = const Duration(seconds: 5),
    this.boundedSignalConnect = true,
    this.signalDialCap = const Duration(seconds: 30),
    this.silentHostFailFast = true,
    this.signalUpgradeWindow = const Duration(seconds: 20),
    this.signalDialCeiling = const Duration(seconds: 45),
    this.fullReconnectMediaConnect = true,
    this.slowPathPeerConnectWait = const Duration(seconds: 30),
    this.slowSignalSetup = const Duration(seconds: 5),
    this.slowSignalRtt = const Duration(seconds: 1),
    this.hostCameraGuard = true,
    this.resumeSatisfiesPeerFailure = true,
    this.resumePeerRestartWait = const Duration(seconds: 3),
    this.lastGoodRegionList = true,
    this.restartAbortsOnSignalLoss = true,
    this.uplinkFeedbackStallFor = const Duration(seconds: 5),
    this.deferNegotiateDuringResume = true,
    this.rollbackStaleOfferOnRestart = true,
    this.resumeReasonNetworkWindow = const Duration(seconds: 30),
    this.freshPeerFailedGrace = const Duration(seconds: 3),
    this.iceTransportWatch = const Duration(seconds: 5),
    this.iceTransportWatchUdp = const Duration(seconds: 30),
    this.slowTcpRtt = const Duration(seconds: 1),
    this.slowTcpFor = const Duration(seconds: 10),
    this.resumeAfterNetworkSocketError = true,
    this.resumeBeforeFullOnNetworkFailure = true,
  });

  /// GRAVIX (2026-10-14): the 0.4.16 behaviour in one step: every recovery switch
  /// 0.4.18 added is off (resumeReasonNetworkWindow, freshPeerFailedGrace,
  /// iceTransportWatch, resumeAfterNetworkSocketError,
  /// resumeBeforeFullOnNetworkFailure); the 0.4.15-0.4.16 ones stay on. The
  /// rollback of 0.4.18's recovery: `RoomOptions(recovery:
  /// GravixRecoveryOptions.before0418)`. [legacy] turns everything off.
  static const before0418 = GravixRecoveryOptions(
    resumeReasonNetworkWindow: Duration.zero,
    freshPeerFailedGrace: Duration.zero,
    iceTransportWatch: Duration.zero,
    resumeAfterNetworkSocketError: false,
    resumeBeforeFullOnNetworkFailure: false,
  );

  /// Everything off: the 0.4.14 behaviour.
  static const legacy = GravixRecoveryOptions(
    upstreamReconnectFixes: false,
    measuredRegionFailover: false,
    retrySameUrlFirst: false,
    publisherRestartRetryAfter: null,
    subscriberSufficientWhenIdle: false,
    earlyStallDetection: false,
    noVideoWatchdog: false,
    keepParticipantsOnRejoin: false,
    republishStoppedTracksMuted: false,
    startBitrateBySetupTime: false,
    resumePrimaryDeadline: null,
    leaveAbortsResumeWait: false,
    networkWaitProbeInterval: null,
    failoverNeedsEvidence: false,
    rejoinAbsentGrace: Duration.zero,
    boundedSignalConnect: false,
    signalDialCap: null,
    silentHostFailFast: false,
    signalUpgradeWindow: null,
    fullReconnectMediaConnect: false,
    slowPathPeerConnectWait: null,
    hostCameraGuard: false,
    resumeSatisfiesPeerFailure: false,
    resumePeerRestartWait: Duration.zero,
    lastGoodRegionList: false,
    restartAbortsOnSignalLoss: false,
    uplinkFeedbackStallFor: Duration.zero,
    deferNegotiateDuringResume: false,
    rollbackStaleOfferOnRestart: false,
    resumeReasonNetworkWindow: Duration.zero,
    freshPeerFailedGrace: Duration.zero,
    iceTransportWatch: Duration.zero,
    resumeAfterNetworkSocketError: false,
    resumeBeforeFullOnNetworkFailure: false,
  );

  /// Reconnect fixes ported from the upstream client SDK 2.13.0: a server
  /// Leave{RESUME} (node migration) resumes instead of a full rejoin; a reconnect
  /// request arriving while an attempt runs is not dropped, and one that needs a
  /// full reconnect is not downgraded by a later request; a resume whose signal
  /// socket drops right after the ReconnectResponse is retried.
  final bool upstreamReconnectFixes;

  /// Region failover (a failed first connect to a cloud url, or a failed full
  /// reconnect) dials the regions in MEASURED order when the app's start-up
  /// measurement (`gravixStartRegionMeasurement`) is fresh: fastest `ok` first,
  /// regions slower than max(2 x best, best + 100 ms) of the best remaining
  /// candidate only when nothing near is left, unmeasured / failed ones after the
  /// measured ones. Off (or no fresh measurement): the server's
  /// `/settings/regions` order, as before -- which could move a session to a
  /// distant region while a nearer one was up.
  final bool measuredRegionFailover;

  /// A full reconnect retries the url it was on once, with a short signal dial
  /// ([sameUrlRetryDialTimeout]), before any other region. A short path drop
  /// should not move the session to another region for the rest of its life.
  final bool retrySameUrlFirst;

  /// The signal dial timeout of that same-url retry (not the JoinResponse or
  /// peer-connection waits). Default 2.5 s.
  final Duration sameUrlRetryDialTimeout;

  /// Resume (dual peer connection, publisher primary): when the publisher
  /// connection is still not connected this long after the resume's
  /// ReconnectResponse while the subscriber connection IS connected, send ONE
  /// fresh publisher ICE-restart offer (only when the publisher's signaling state
  /// is stable, so offers are never stacked). Null = off: the resume only waits
  /// `Timeouts.peerConnection`, which a restart whose credentials the server's
  /// ICE agent rejects sits out in full.
  final Duration? publisherRestartRetryAfter;

  /// Resume: a participant whose published tracks are all muted (or who
  /// publishes nothing) is resumed as soon as the subscriber connection is
  /// connected; the publisher connection keeps recovering in the background,
  /// and a publisher that does not recover within `Timeouts.peerConnection`
  /// still triggers a reconnect. Data sent meanwhile waits for the publisher
  /// (its data channels live there), as it did before.
  final bool subscriberSufficientWhenIdle;

  /// A subscribed camera video (enabled, unmuted, not paused by the server, its
  /// publisher still publishing) that received no packet for [stallNoPacketsFor]
  /// starts a resume at once instead of waiting for ICE to report disconnected
  /// (~7 s). Reads the receiver stats the track already polls every 2 s (no new
  /// poll). At most once per [stallMinInterval].
  final bool earlyStallDetection;
  final Duration stallNoPacketsFor;
  final Duration stallMinInterval;

  /// After a resume, a subscribed camera video (same guards as
  /// [earlyStallDetection]) that decodes no new frame for [noVideoFor] within
  /// [noVideoWindow] of the resume triggers a full rejoin. At most once per
  /// [noVideoMinInterval]. The client-side safety net for a resumed session whose
  /// server-side video stopped.
  final bool noVideoWatchdog;
  final Duration noVideoFor;
  final Duration noVideoWindow;
  final Duration noVideoMinInterval;

  /// A full rejoin keeps the RemoteParticipant objects of identities still in the
  /// room: no ParticipantDisconnected / ParticipantConnected for them, their
  /// tracks are resubscribed on the same objects; only identities that really
  /// left get ParticipantDisconnected, new ones ParticipantConnected.
  final bool keepParticipantsOnRejoin;

  /// A full rejoin republishes a track whose capture was stopped by a mute
  /// (stopAudioCaptureOnMute) as a muted publication without a capture; the
  /// unmute restarts the capture. Off: the stopped track is handed to
  /// addTransceiver, which fails ("track is null"). A track that still fails to
  /// republish is reported, never thrown.
  final bool republishStoppedTracksMuted;

  /// Ported from the upstream client SDK 2.13.1: the video start bitrate hint is
  /// one connection-level value written once per publisher connection, capped at
  /// 1 Mbps for a camera and scaled down to 300 kbps by the connection's setup
  /// time (1.5 s -> 3.5 s); screen share uncapped; no hint below a 300 kbps
  /// target. Off: the 0.4.14 per-track hint (90 % of the first encoding).
  final bool startBitrateBySetupTime;

  /// A resume whose PRIMARY connection is still not connected this long after the
  /// ReconnectResponse (signal up) becomes a full rejoin at once, instead of
  /// after `Timeouts.peerConnection` (10 s): a resume whose ICE never completes
  /// would otherwise keep the session without media for the whole wait. With a
  /// fresh publisher restart pending ([publisherRestartRetryAfter]) it counts
  /// from that restart's due time. Null = off (the 10 s wait).
  final Duration? resumePrimaryDeadline;

  /// A Leave (or the socket closing) while a resume waits for its primary
  /// connection ends the wait at once and acts as the Leave says (RESUME: resume
  /// again; RECONNECT: full rejoin; DISCONNECT: disconnect). Off: the Leave was
  /// dropped and the resume sat out its 10 s wait.
  final bool leaveAbortsResumeWait;

  /// While a reconnect waits for connectivity (the connectivity reading said
  /// "none"), re-check it this often and probe the server url (one HTTP HEAD, any
  /// answer = reachable): a per-app network block lifted, or a stale reading,
  /// fires no connectivity event, and the attempt used to wait up to 10 x
  /// `Timeouts.connection` (100 s). Null = off (wait for the event).
  final Duration? networkWaitProbeInterval;

  /// A full reconnect that failed at the session's url moves to another region
  /// only with evidence that the region failed: no connectivity change and no
  /// offline reading since the attempt began, the session url does not answer a
  /// probe (HTTP HEAD) and the other region does. Otherwise the same url is
  /// retried (reconnect back-off, the network wait). A refusal (4xx) still moves
  /// on as before. Off: any failure after the same-url retry moved the session --
  /// the device's own Wi-Fi going off could move it to another region for good.
  final bool failoverNeedsEvidence;

  /// With [keepParticipantsOnRejoin]: a kept participant the new JoinResponse
  /// does not list gets this long to reappear in a participant update before it
  /// is reported gone. On a node where the room was just created, a participant
  /// relayed from another region arrives a moment after the JoinResponse and was
  /// reported left, then joined, milliseconds apart. Duration.zero: reported gone
  /// at once.
  final Duration rejoinAbsentGrace;

  /// When the route to the server is black-holed while the local network stays
  /// up, a TCP connect hangs until the operating system gives up (from about 30 s
  /// to over two minutes on Android), and the reconnect's validate and
  /// region-list requests had no timeout at all: recovery lagged the network by
  /// tens of seconds.
  ///
  /// On: each network step of a signal connect -- the WebSocket dial (TCP, TLS
  /// and the upgrade), the validate request, the region list request of a
  /// failover, the reachability probes of the network wait and the failover
  /// evidence -- gives up at its timeout (the dial timeout of the attempt:
  /// `Timeouts.connection`, or [sameUrlRetryDialTimeout] for that retry; a probe
  /// its own) and closes its socket, so the next step starts at once and nothing
  /// keeps connecting in the background. A dial that times out still fails with a
  /// TimeoutException, as before. Off: the 0.4.14 behaviour (no timeout on the
  /// validate and region list requests; a timed-out dial or probe left to the
  /// OS).
  final bool boundedSignalConnect;

  /// On a very bad path (round trips of 1-2 s, 25-35 % loss) TCP and TLS come up
  /// but the WebSocket upgrade's answer can take longer than
  /// `Timeouts.connection`: every join failed on a path that works, slowly.
  ///
  /// With [boundedSignalConnect], a FRESH join's dial (the first join, a full
  /// reconnect, a region failover; not a resume, not the short same-url retry)
  /// may take up to this long. A connection not up after `Timeouts.connection`
  /// gets another one in parallel, again every `Timeouts.connection`; the first
  /// one up carries the upgrade and the others are closed before anything is
  /// written on them, so the server sees one join. A connection that is up and
  /// waiting for the upgrade's answer is not raced: it gets the rest of this
  /// time. On a black-holed path a connection started after the path is back
  /// carries the join within one `Timeouts.connection`. A resume keeps
  /// `Timeouts.connection`: past the server's disconnect grace (~15 s) it can
  /// only be refused, and two timed-out resumes lead to the full reconnect. Null
  /// (or not above `Timeouts.connection`): the dial gives up at
  /// `Timeouts.connection`, as with [boundedSignalConnect] alone. With
  /// app-installed HttpOverrides the dial keeps WebSocket.connect's shared
  /// client: one connection, not raced, but it still gets the cap. The cost: a
  /// region that does not answer at all (not refusing) holds a fresh join or a
  /// full reconnect for the cap before the validate request and the failover run;
  /// a refused connection still fails at once. Default 30 s.
  final Duration? signalDialCap;

  /// When a region drops every packet (no TCP connection at all), raced dials and
  /// the validate request each waited out their full timeouts before the failover
  /// ran, so moving to another region took over a minute.
  ///
  /// With [boundedSignalConnect]: a signal dial that failed with no connection up
  /// (TCP, and TLS for wss) marks its host silent (for 60 s, until a dial to it
  /// connects, or until a reconnect attempt ends without leaving the url). The
  /// next fresh dial to a silent host must get a connection within
  /// `Timeouts.connection`, without a parallel race; one that does come up still
  /// gets the rest of [signalDialCap] for the upgrade's answer (a slow path has
  /// its connection up and waits on the upgrade). And a fresh dial that failed
  /// with no connection up does not ask that host /rtc/validate (it would time
  /// out the same way; its only use, telling a 401/403 apart, needs a
  /// connection). A reconnect attempt that then stays on the url (no other
  /// region, or no evidence the region failed) forgets the silent host, so the
  /// next attempt races again: a path where even TCP is slower than
  /// `Timeouts.connection` loses one attempt, not its recovery. Off: every fresh
  /// dial races up to the cap and is validated.
  final bool silentHostFailFast;

  /// On a very bad path a raced dial's connection can come up late (TCP + TLS
  /// after 15-25 s) with the WebSocket upgrade's answer still on its way when
  /// [signalDialCap] closes the dial.
  ///
  /// With [signalDialCap]: once a connection of a raced dial is up (TCP, and TLS
  /// for wss) the host is alive, and the upgrade gets this long counted from that
  /// moment, but never past [signalDialCeiling] from the dial's start, and never
  /// less than the cap would have given. Before a connection is up the cap still
  /// ends the dial (and [silentHostFailFast] still fails a silent host at
  /// `Timeouts.connection`). A resume and the short same-url retry keep their own
  /// timeouts. Null: the cap ends the dial.
  final Duration? signalUpgradeWindow;

  /// The absolute end of a raced dial whose connection came up (see
  /// [signalUpgradeWindow]), counted from the dial's start. Default 45 s.
  final Duration signalDialCeiling;

  /// A full reconnect waited `Timeouts.connection` (10 s) for its primary peer
  /// connection, a fresh join `Timeouts.mediaConnect` (20 s); on a slow path ICE
  /// plus the DTLS handshake can take longer than 10 s. On: a full reconnect
  /// waits `Timeouts.mediaConnect` too. Off: `Timeouts.connection`.
  final bool fullReconnectMediaConnect;

  /// On a slow path ICE can still be checking when the wait for the primary peer
  /// connection runs out. When the signal path was measurably slow -- the signal
  /// connect (dial + upgrade) took at least [slowSignalSetup], or the signal ping
  /// round trip is at least [slowSignalRtt] when the wait runs out -- the wait
  /// for the primary peer connection (fresh join or full reconnect) goes on up to
  /// this long in all. On a normal path the waits are unchanged. Null: no
  /// extension.
  final Duration? slowPathPeerConnectWait;

  /// See [slowPathPeerConnectWait]. Default 5 s.
  final Duration slowSignalSetup;

  /// See [slowPathPeerConnectWait]. Default 1 s.
  final Duration slowSignalRtt;

  /// When the host app leaves the screen (background or lock) the operating
  /// system pauses the camera, the server scores the silent camera poor, and
  /// GravixRoomService's automatic data saver unpublished the camera to republish
  /// it single-layer. That republish can never work (unpublishing disposes the
  /// track), so the host's video was gone for good while `isCameraEnabled` said
  /// on.
  ///
  /// On: the data saver changes the camera's bitrate caps IN PLACE
  /// (setParameters, no unpublish; a change that fails is undone and reported as
  /// a `GravixDataSaverEvent`); it ignores quality samples while the app is not
  /// in the foreground or the camera sent no frame since the previous sample (and
  /// for 10 s after); and a camera publication missing while the camera is on is
  /// published again on a fresh capture (at most 3 tries, 10 s apart, then the
  /// camera is reported off). Off: the 0.4.14 data saver (unpublish + republish,
  /// every sample counted, no restore), except that a failed republish is still
  /// rolled back. GravixRoomService only.
  final bool hostCameraGuard;

  /// When the network comes back after a short drop, libwebrtc can report the OLD
  /// ICE session of both peer connections Failed while the resume is starting.
  /// With [upstreamReconnectFixes] each report queued a full-reconnect request;
  /// the resume's ICE restart brought both connections back and the resume
  /// succeeded, then the queued request ran anyway: a full rejoin, so the other
  /// participants saw this one leave and join again.
  ///
  /// On: a full-reconnect request that ONLY peer connections reporting Failed
  /// made, while a resume ran, is satisfied by that resume when a peer connection
  /// came back after the last such report and, when the resume ends, the primary
  /// connection and the other one (unless never used) are connected. It is
  /// dropped instead of starting a rejoin. Still a rejoin: a connection still
  /// down when the resume ends, a failure of the restarted session, a
  /// Leave{RECONNECT}, a negotiation failure. Off: every request made during a
  /// successful resume starts a full rejoin when it ends.
  final bool resumeSatisfiesPeerFailure;

  /// With [resumeSatisfiesPeerFailure]. After a longer drop the resume can
  /// succeed with one connection still restarting (iOS reports it Disconnected
  /// while its ICE restart runs); requiring both connections up at that instant
  /// started a needless full rejoin.
  ///
  /// A connection still restarting when the resume succeeds (Connecting or
  /// Disconnected, not Failed) gets this long to come back: connected -> no
  /// rejoin; it fails -> its own reconnect (a full rejoin) at once; still not
  /// back -> the full rejoin then. The request is held aside meanwhile, so a
  /// reconnect started for any other reason is not turned into a full one by it.
  /// With the subscriber enough for an idle publisher
  /// ([subscriberSufficientWhenIdle]) the publisher watch decides instead (a
  /// rejoin at `Timeouts.peerConnection` if the publisher is not back). Worst
  /// case: a rejoin that is needed starts this much later. Duration.zero: no wait
  /// (the rejoin at once).
  final Duration resumePeerRestartWait;

  /// The failover's next region comes from the server's `/settings/regions`,
  /// fetched at connect from the url the app passed. It was kept for 5 s only; a
  /// later failover fetched it again from the same host -- the failed one -- and
  /// the error ended the attempt before the failover ran, so a session could end
  /// while another region was up.
  ///
  /// On: a region list fetch that fails (network error, timeout, a 5xx) falls
  /// back to the last list the provider had (the connect-time fetch or a list the
  /// server sent), however old: a region set changes on a server deploy, a
  /// session can run for hours, and a list thrown away by a TTL is exactly the
  /// list a dead region needs. The log names its age. When the list's host is the
  /// url that just failed (not by a refusal), it is not asked at all: it would
  /// only wait out the fetch's timeout. A 401/403 still ends the attempt (the
  /// token, not the region). [failoverNeedsEvidence] still decides whether the
  /// session may leave its url, and [measuredRegionFailover] still orders the
  /// regions. No list at all (the connect-time fetch failed too): unchanged. Off:
  /// the 0.4.14 behaviour (a failed fetch ends the attempt).
  final bool lastGoodRegionList;

  /// On a flapping network (Wi-Fi going off and on every few seconds) a full
  /// reconnect that lost its own signal socket kept waiting anyway -- 10 s for
  /// the primary connection, or for the publisher once ICE had brought the
  /// subscriber back by itself -- although no offer, answer or candidate could
  /// pass: recovery took either about 1 s or 11-13 s, depending on timing.
  ///
  /// On: a full reconnect fails as soon as its own signal socket closes (while it
  /// waits for the JoinResponse, the primary connection or the publisher), and
  /// the reconnect goes on at once (the same-url retry, then the attempt's
  /// network wait). An attempt that failed that way while the device's network
  /// changed does not count against the reconnect policy's attempts (otherwise
  /// one failure per flap climbs the back-off to 7 s and, after 10 flaps, ends
  /// the session); with the network steady it counts as before. Off: the 0.4.14
  /// behaviour (the waits run out their timeouts).
  final bool restartAbortsOnSignalLoss;

  /// When UDP to the server dies mid-call, libwebrtc can move the publisher
  /// connection to ICE-TCP by itself, without an ICE restart, while the server
  /// keeps sending its RTCP into the dead UDP pair: the media still arrives, but
  /// no receiver report, PLI or bandwidth feedback comes back, so no keyframe is
  /// sent and viewers see black video until the server's ICE times out (15 s or
  /// more). Newer servers follow the client's nomination themselves; this also
  /// covers older ones.
  ///
  /// While connected, a published, unmuted track that keeps sending (at least 20
  /// packets) with NO new receiver report from the server (`remote-inbound-rtp`
  /// unchanged) on any published stream for this long -> a resume at once (its
  /// ICE restart makes the server select again). At most once per 20 s. The
  /// server reports about every second and the tracks poll every 2 s, so a live
  /// uplink never waits this long. Duration.zero: off (no such check).
  final Duration uplinkFeedbackStallFor;

  /// A renegotiation started while a resume is dialling (a track published or
  /// unpublished then -- e.g. by the data saver as the app returns from a phone
  /// call) was applied locally and dropped, because offers are never queued while
  /// the socket is reconnecting. The resume's ICE restart then found an
  /// unanswered offer, re-applied the answer to the PREVIOUS offer and failed
  /// ("Incompatible send direction"), twice, then fell back to a full reconnect.
  /// On: an offer the socket cannot carry is not made; it goes out after the
  /// resume's restart answer (that offer already carries the current senders).
  /// Off: the 0.4.14 behaviour.
  final bool deferNegotiateDuringResume;

  /// The other half of [deferNegotiateDuringResume]: an offer that LEFT just
  /// before the socket died is never answered either. On: the ICE restart rolls
  /// that offer back (an SDP rollback) instead of re-applying an answer to a
  /// different offer; a native side that refuses the rollback gets the old
  /// behaviour. Off: the 0.4.14 behaviour.
  final bool rollbackStaleOfferOnRestart;

  /// GRAVIX (2026-10-14): a resume after the phone's own network changed (Wi-Fi
  /// off or back, a handover between Wi-Fi and mobile, offline) within this
  /// window before the reconnect began (or during it) tells the server
  /// `RR_SIGNAL_DISCONNECTED` instead of `RR_PUBLISHER_FAILED` /
  /// `RR_SUBSCRIBER_FAILED`. The SFU takes a peer connection failure on a
  /// connection younger than 90 s for "UDP blocked" and prefers ICE/TCP for that
  /// participant (5 minutes, renewed by every join); after a network change the
  /// failure was the network's, and the TCP sessions that followed ran at
  /// seconds of round trip. A peer connection failing on a steady network still
  /// says RR_*_FAILED. Duration.zero: off (always RR_*_FAILED, the previous
  /// behaviour).
  final Duration resumeReasonNetworkWindow;

  /// GRAVIX (2026-10-14): a peer connection that never connected and reports
  /// FAILED gets this long to connect before it asks for a reconnect. Over
  /// ICE/TCP a new connection's first checks can fail at once (checking ->
  /// failed -> connected within ~0.1-1.7 s on a device); each such FAILED asked
  /// for another full rejoin (8 in 2 minutes). Its own join or rejoin still
  /// times out as before; a connection that WAS connected and fails reconnects
  /// at once. Duration.zero: off (at once, the previous behaviour).
  final Duration freshPeerFailedGrace;

  /// GRAVIX (2026-10-14): how often the selected candidate pair of each
  /// connected peer connection is read (one getStats per connection) for
  /// `Room.selectedTransport` (udp / tcp / relay), RoomIceTransportChangedEvent
  /// and RoomSlowTcpTransportEvent. The first reading comes 3 s after a
  /// connection connected (the interval when shorter): nothing is read on the
  /// join path. Duration.zero: off (nothing is read; the getters stay null).
  final Duration iceTransportWatch;

  /// GRAVIX (2026-10-14): while every connection runs over UDP (or a relay) the
  /// selected pairs are read this often instead of every [iceTransportWatch]
  /// (which stays the rate on ICE/TCP, for RoomSlowTcpTransportEvent). Nothing is
  /// read while the app is in the background.
  final Duration iceTransportWatchUdp;

  /// GRAVIX (2026-10-14): a TCP session whose selected pair's round trip stays
  /// above [slowTcpRtt] for [slowTcpFor] is reported once
  /// (RoomSlowTcpTransportEvent), again after it recovered.
  final Duration slowTcpRtt;

  /// See [slowTcpRtt].
  final Duration slowTcpFor;

  /// GRAVIX (2026-10-14): a resume whose dial fails with a socket error while the
  /// phone's network changed (within [resumeReasonNetworkWindow], 30 s when that
  /// is off) or reads offline keeps the next attempt a RESUME: it waits for the
  /// network and resumes, while the server still holds the session. Device run
  /// (Wi-Fi off 5 s): the dial made as the interface went away failed, the next
  /// attempt was a full rejoin started the instant the Wi-Fi came back. Resumes
  /// that keep failing still become a full reconnect after two in a row. On a
  /// steady network a socket error is a full reconnect as before. False: always
  /// a full reconnect after a socket error (the previous behaviour).
  final bool resumeAfterNetworkSocketError;

  /// GRAVIX (2026-10-14): a connected peer connection that reports FAILED while
  /// the phone's network changed (same window) gets one resume -- its ICE
  /// restart -- before the full reconnect; the full reconnect follows when that
  /// resume does not bring it back. On a steady network a FAILED is a full
  /// reconnect at once, as before. False: always a full reconnect (the previous
  /// behaviour).
  final bool resumeBeforeFullOnNetworkFailure;

  GravixRecoveryOptions copyWith({
    bool? upstreamReconnectFixes,
    bool? measuredRegionFailover,
    bool? retrySameUrlFirst,
    Duration? sameUrlRetryDialTimeout,
    Duration? publisherRestartRetryAfter,
    bool clearPublisherRestartRetryAfter = false,
    bool? subscriberSufficientWhenIdle,
    bool? earlyStallDetection,
    Duration? stallNoPacketsFor,
    Duration? stallMinInterval,
    bool? noVideoWatchdog,
    Duration? noVideoFor,
    Duration? noVideoWindow,
    Duration? noVideoMinInterval,
    bool? keepParticipantsOnRejoin,
    bool? republishStoppedTracksMuted,
    bool? startBitrateBySetupTime,
    Duration? resumePrimaryDeadline,
    bool clearResumePrimaryDeadline = false,
    bool? leaveAbortsResumeWait,
    Duration? networkWaitProbeInterval,
    bool clearNetworkWaitProbeInterval = false,
    bool? failoverNeedsEvidence,
    Duration? rejoinAbsentGrace,
    bool? boundedSignalConnect,
    Duration? signalDialCap,
    bool clearSignalDialCap = false,
    bool? silentHostFailFast,
    Duration? signalUpgradeWindow,
    bool clearSignalUpgradeWindow = false,
    Duration? signalDialCeiling,
    bool? fullReconnectMediaConnect,
    Duration? slowPathPeerConnectWait,
    bool clearSlowPathPeerConnectWait = false,
    Duration? slowSignalSetup,
    Duration? slowSignalRtt,
    bool? hostCameraGuard,
    bool? resumeSatisfiesPeerFailure,
    Duration? resumePeerRestartWait,
    bool? lastGoodRegionList,
    bool? restartAbortsOnSignalLoss,
    Duration? uplinkFeedbackStallFor,
    bool? deferNegotiateDuringResume,
    bool? rollbackStaleOfferOnRestart,
    Duration? resumeReasonNetworkWindow,
    Duration? freshPeerFailedGrace,
    Duration? iceTransportWatch,
    Duration? iceTransportWatchUdp,
    Duration? slowTcpRtt,
    Duration? slowTcpFor,
    bool? resumeAfterNetworkSocketError,
    bool? resumeBeforeFullOnNetworkFailure,
  }) => GravixRecoveryOptions(
    upstreamReconnectFixes: upstreamReconnectFixes ?? this.upstreamReconnectFixes,
    measuredRegionFailover: measuredRegionFailover ?? this.measuredRegionFailover,
    retrySameUrlFirst: retrySameUrlFirst ?? this.retrySameUrlFirst,
    sameUrlRetryDialTimeout: sameUrlRetryDialTimeout ?? this.sameUrlRetryDialTimeout,
    publisherRestartRetryAfter: clearPublisherRestartRetryAfter
        ? null
        : publisherRestartRetryAfter ?? this.publisherRestartRetryAfter,
    subscriberSufficientWhenIdle: subscriberSufficientWhenIdle ?? this.subscriberSufficientWhenIdle,
    earlyStallDetection: earlyStallDetection ?? this.earlyStallDetection,
    stallNoPacketsFor: stallNoPacketsFor ?? this.stallNoPacketsFor,
    stallMinInterval: stallMinInterval ?? this.stallMinInterval,
    noVideoWatchdog: noVideoWatchdog ?? this.noVideoWatchdog,
    noVideoFor: noVideoFor ?? this.noVideoFor,
    noVideoWindow: noVideoWindow ?? this.noVideoWindow,
    noVideoMinInterval: noVideoMinInterval ?? this.noVideoMinInterval,
    keepParticipantsOnRejoin: keepParticipantsOnRejoin ?? this.keepParticipantsOnRejoin,
    republishStoppedTracksMuted: republishStoppedTracksMuted ?? this.republishStoppedTracksMuted,
    startBitrateBySetupTime: startBitrateBySetupTime ?? this.startBitrateBySetupTime,
    resumePrimaryDeadline: clearResumePrimaryDeadline ? null : resumePrimaryDeadline ?? this.resumePrimaryDeadline,
    leaveAbortsResumeWait: leaveAbortsResumeWait ?? this.leaveAbortsResumeWait,
    networkWaitProbeInterval: clearNetworkWaitProbeInterval
        ? null
        : networkWaitProbeInterval ?? this.networkWaitProbeInterval,
    failoverNeedsEvidence: failoverNeedsEvidence ?? this.failoverNeedsEvidence,
    rejoinAbsentGrace: rejoinAbsentGrace ?? this.rejoinAbsentGrace,
    boundedSignalConnect: boundedSignalConnect ?? this.boundedSignalConnect,
    signalDialCap: clearSignalDialCap ? null : signalDialCap ?? this.signalDialCap,
    silentHostFailFast: silentHostFailFast ?? this.silentHostFailFast,
    signalUpgradeWindow: clearSignalUpgradeWindow ? null : signalUpgradeWindow ?? this.signalUpgradeWindow,
    signalDialCeiling: signalDialCeiling ?? this.signalDialCeiling,
    fullReconnectMediaConnect: fullReconnectMediaConnect ?? this.fullReconnectMediaConnect,
    slowPathPeerConnectWait: clearSlowPathPeerConnectWait
        ? null
        : slowPathPeerConnectWait ?? this.slowPathPeerConnectWait,
    slowSignalSetup: slowSignalSetup ?? this.slowSignalSetup,
    slowSignalRtt: slowSignalRtt ?? this.slowSignalRtt,
    hostCameraGuard: hostCameraGuard ?? this.hostCameraGuard,
    resumeSatisfiesPeerFailure: resumeSatisfiesPeerFailure ?? this.resumeSatisfiesPeerFailure,
    resumePeerRestartWait: resumePeerRestartWait ?? this.resumePeerRestartWait,
    lastGoodRegionList: lastGoodRegionList ?? this.lastGoodRegionList,
    restartAbortsOnSignalLoss: restartAbortsOnSignalLoss ?? this.restartAbortsOnSignalLoss,
    uplinkFeedbackStallFor: uplinkFeedbackStallFor ?? this.uplinkFeedbackStallFor,
    deferNegotiateDuringResume: deferNegotiateDuringResume ?? this.deferNegotiateDuringResume,
    rollbackStaleOfferOnRestart: rollbackStaleOfferOnRestart ?? this.rollbackStaleOfferOnRestart,
    resumeReasonNetworkWindow: resumeReasonNetworkWindow ?? this.resumeReasonNetworkWindow,
    freshPeerFailedGrace: freshPeerFailedGrace ?? this.freshPeerFailedGrace,
    iceTransportWatch: iceTransportWatch ?? this.iceTransportWatch,
    iceTransportWatchUdp: iceTransportWatchUdp ?? this.iceTransportWatchUdp,
    slowTcpRtt: slowTcpRtt ?? this.slowTcpRtt,
    slowTcpFor: slowTcpFor ?? this.slowTcpFor,
    resumeAfterNetworkSocketError: resumeAfterNetworkSocketError ?? this.resumeAfterNetworkSocketError,
    resumeBeforeFullOnNetworkFailure: resumeBeforeFullOnNetworkFailure ?? this.resumeBeforeFullOnNetworkFailure,
  );
}
