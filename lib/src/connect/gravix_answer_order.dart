// Copyright Gravity Compile, Inc. Apache 2.0.

import 'dart:async';

/// The order in which the engine answers a subscriber offer.
///
/// Upstream order: createAnswer -> setLocalDescription -> send the answer. On a
/// phone, `setLocalDescription` for the first offer that carries AUDIO does not
/// return for ~350 ms (2201117TG, 2026-09-20: libwebrtc starts audio playout - the
/// Android AudioTrack - inside it), and the SFU does not forward a single packet
/// until it has the answer. So the answer sits finished in memory for a third of
/// a second while the user hears nothing. That wait does not scale with RTT.
///
/// [fastAnswer] sends the answer as soon as it exists and applies it locally
/// afterwards. The SDP sent is byte-for-byte the SDP that is then applied
/// (nothing edits a subscriber answer between the two calls), so the server sees
/// exactly the answer it would have seen ~350 ms later.
///
/// What changes, and the risk: the server may start sending RTP before the local
/// description is applied. The transport is already up (the subscriber PC is
/// BUNDLEd and DTLS-SRTP completed for offer #1), and the remote description -
/// already applied - is what creates the receiver and its SSRC mapping, so early
/// packets have somewhere to go; they wait in the jitter buffer until playout
/// starts. That is the expectation from how libwebrtc is built, NOT a guarantee:
/// the phone measurement (packetsDiscarded / packetsLost / concealedSamples at
/// first audio) is what decides whether this stays.
///
/// Failure: if `setLocalDescription` throws, the exception reaches the caller
/// exactly as it does today (the engine logs it as severe and carries on). The
/// one difference is that with [fastAnswer] the server has already been told the
/// negotiation succeeded. Today it would instead time the negotiation out after
/// 15 s. Neither path recovers by itself; both end in the engine's reconnect.
///
/// Lives outside `rtc_core/` so it can be unit-tested without a native peer
/// connection; the vendored offer handler calls it (`// GRAVIX`).
Future<void> gravixAnswerSubscriberOffer<T>({
  required bool fastAnswer,
  required Future<T> Function() createAnswer,
  required Future<void> Function(T answer) setLocalDescription,
  required void Function(T answer) sendAnswer,
  void Function(String step)? mark,
}) async {
  final answer = await createAnswer();
  mark?.call('createAnswerDone');
  if (fastAnswer) {
    sendAnswer(answer);
    mark?.call('answerSent');
    await setLocalDescription(answer);
    mark?.call('setLocalDescriptionDone');
    return;
  }
  await setLocalDescription(answer);
  mark?.call('setLocalDescriptionDone');
  sendAnswer(answer);
  mark?.call('answerSent');
}
