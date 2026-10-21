// Copyright 2026 Gravity Compile
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// MUSIC-SDP (the device run 2026-10-15, a host app's room music via "Play in
// room", Android 13): every music track change
// republishes the microphone twice within ~250 ms (music stop -> DTX on, music
// start -> DTX off: unpublish + publish of a new LocalAudioTrack each). 7 times
// in one session libwebrtc logged
//   sdp_munging_detector: mid does not match last created description
//   Failed to set local offer sdp: The order of m-lines in subsequent offer
//   doesn't match order from previous offer/answer   (x2: munged + unmunged)
// and the NegotiationError sent the host to a full rejoin (viewers saw the host
// leave and come back). Pre-existing (0.4.17/0.4.18 builds show it too).
//
// Cause: Transport._createAndSendOffer was not serialised. A debounced
// negotiate() that fires while the previous offer is still being created (the
// createOffer round trip + sdp_transform munging + setLocalDescription take
// 60-200 ms on the phone), or one that fires while the answer's `renegotiate`
// replay is being created, also finds the connection stable, so two offers are
// created from the same state. libwebrtc gives a transceiver that has no mid
// yet a FRESH mid in every createOffer, so the two offers name the new m-line
// differently; the first setLocalDescription wins and the second is validated
// against it and refused.
//
// The fake below models exactly that part of libwebrtc: per-createOffer mids
// for unassociated transceivers, mids fixed by setLocalDescription, and the
// m-line order check against the pending (or current) local description.
@Timeout(Duration(seconds: 10))
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/transport.dart' show Transport;
import 'package:gravix_rtc/src/rtc_core/src/internal/types.dart' show RTCOfferOptions;
import 'package:gravix_rtc/src/rtc_core/src/options.dart';

import '../support/fake_rtc.dart';

const _mlineError =
    "Failed to set local offer sdp: The order of m-lines in subsequent offer doesn't match order from previous "
    'offer/answer.';

class _MidPc extends FakePeerConnection {
  _MidPc() : super(0);

  /// One entry per transceiver: its mid, or null until a local offer naming it
  /// was applied (libwebrtc: an unassociated transceiver).
  final mids = <String?>[];
  int _midGenerator = 0;

  /// The native createOffer round trip (the offer is built from the state at
  /// the START of the call, like libwebrtc's signaling-thread snapshot).
  Duration createDelay = const Duration(milliseconds: 30);

  final log = <String>[];
  int localOfferRefusals = 0;

  List<String>? _pendingMids;
  List<String>? _currentMids;
  rtc.RTCSessionDescription? _pendingOffer;
  rtc.RTCSessionDescription? _currentAnswer;
  final _assignedByPending = <int>[];

  void addSender() => mids.add(null);

  /// The native getSignalingState round trip (main-thread load on a phone made
  /// it 24-423 ms in the device run) and how often it was asked.
  Duration signalingStateDelay = Duration.zero;
  int signalingStateCalls = 0;
  int createOfferCalls = 0;

  @override
  Future<rtc.RTCSignalingState?> getSignalingState() async {
    signalingStateCalls++;
    if (signalingStateDelay > Duration.zero) await Future<void>.delayed(signalingStateDelay);
    return signalingState;
  }

  static List<String> midsOf(String? sdp) =>
      RegExp(r'a=mid:(\S+)').allMatches(sdp ?? '').map((m) => m.group(1)!).toList();

  /// [initial]: the first offer of a fresh connection. libwebrtc (no bundle
  /// policy: "balanced") gives it one transport per m-section and, once an
  /// answer accepted BUNDLE, re-offers carry one (device 2026-10-15: three
  /// transports at the first offer, one at the replay; which SDP line then
  /// differed is not in the device log). Modelled here with transport-level
  /// lines (ICE credentials per m-section, ports, candidates): the senders are
  /// the same.
  static String sdpFor(List<String> sectionMids, {bool initial = false}) {
    final b = StringBuffer('v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n');
    var i = 0;
    for (final mid in sectionMids) {
      b.write(
        'm=audio ${initial ? 9 : 51000} UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 ${initial ? '0.0.0.0' : '10.0.0.5'}\r\n'
        'a=ice-ufrag:${initial ? 'u$i' : 'u0'}\r\na=ice-pwd:${initial ? 'p$i' : 'p0'}\r\n'
        '${initial ? '' : 'a=candidate:1 1 udp 2122260223 10.0.0.5 51000 typ host\r\n'}'
        'a=mid:$mid\r\na=sendonly\r\na=msid:s t$mid\r\na=rtpmap:111 opus/48000/2\r\n',
      );
      i++;
    }
    return b.toString();
  }

  rtc.RTCSessionDescription answerTo(rtc.RTCSessionDescription offer) =>
      rtc.RTCSessionDescription(sdpFor(midsOf(offer.sdp)), 'answer');

  @override
  rtc.RTCSignalingState? get signalingState => _pendingOffer != null
      ? rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer
      : rtc.RTCSignalingState.RTCSignalingStateStable;

  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async {
    offers.add(Map.of(constraints ?? const {}));
    createOfferCalls++;
    final sectionMids = [for (final mid in mids) mid ?? '${_midGenerator++}'];
    log.add('createOffer:${sectionMids.join(',')}');
    final initial = _currentMids == null;
    await Future<void>.delayed(createDelay);
    return rtc.RTCSessionDescription(sdpFor(sectionMids, initial: initial), 'offer');
  }

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription description) async {
    if (description.type == 'rollback') {
      if (_pendingOffer == null) throw Exception('Failed to set local rollback: Called in wrong state: stable');
      for (final i in _assignedByPending) {
        mids[i] = null; // a rolled-back offer's new mids are released
      }
      _assignedByPending.clear();
      _pendingOffer = null;
      _pendingMids = null;
      log.add('local:rollback');
      return;
    }
    if (description.type != 'offer') throw UnsupportedError('only offers in this fake');
    final offered = midsOf(description.sdp);
    final previous = _pendingMids ?? _currentMids ?? const <String>[];
    var sameOrder = offered.length >= previous.length;
    for (var i = 0; sameOrder && i < previous.length; i++) {
      sameOrder = offered[i] == previous[i];
    }
    if (!sameOrder) {
      localOfferRefusals++;
      log.add('local:offer:REFUSED:${offered.join(',')}');
      throw Exception(_mlineError);
    }
    for (var i = 0; i < offered.length && i < mids.length; i++) {
      if (mids[i] == null) {
        mids[i] = offered[i];
        _assignedByPending.add(i);
      }
    }
    _pendingOffer = description;
    _pendingMids = offered;
    log.add('local:offer:${offered.join(',')}');
  }

  /// The native setRemoteDescription / getRemoteDescription round trips.
  Duration remoteSetDelay = Duration.zero;
  Duration remoteGetDelay = Duration.zero;
  int remoteGetCalls = 0;

  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription description) async {
    if (remoteSetDelay > Duration.zero) await Future<void>.delayed(remoteSetDelay);
    if (_pendingOffer == null) throw Exception('Failed to set remote answer sdp: Called in wrong state: stable');
    _currentMids = _pendingMids;
    _assignedByPending.clear();
    _currentAnswer = description;
    _pendingOffer = null;
    _pendingMids = null;
    log.add('remote:answer:${midsOf(description.sdp).join(',')}');
  }

  @override
  Future<rtc.RTCSessionDescription?> getRemoteDescription() async {
    remoteGetCalls++;
    final at = _currentAnswer; // read when asked, returned after the round trip
    if (remoteGetDelay > Duration.zero) await Future<void>.delayed(remoteGetDelay);
    return at;
  }

  @override
  Future<rtc.RTCSessionDescription?> getLocalDescription() async => _pendingOffer;
}

class _Setup {
  _Setup(this.transport, this.pc);
  final Transport transport;
  final _MidPc pc;
  final sent = <rtc.RTCSessionDescription>[];
  final errors = <Object>[];

  Future<void> answerLast() => transport.setRemoteDescription(pc.answerTo(sent.last));
}

/// The microphone published and answered: stable, one m-line (mid 0).
Future<_Setup> _publishedMic() async {
  final pc = _MidPc();
  final transport = await Transport.create(
    (Map<String, dynamic> c, [Map<String, dynamic>? k]) async => pc,
    connectOptions: const ConnectOptions(),
  );
  final s = _Setup(transport, pc);
  transport.onOffer = s.sent.add;
  transport.onNegotiationError = s.errors.add;
  pc.addSender();
  await transport.createAndSendOffer();
  await s.answerLast();
  expect(pc.mids, ['0']);
  expect(pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
  return s;
}

Future<void> _ms(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// The running test's virtual clock (see [_vtest]).
FakeAsync? _clock;

/// Runs [body] on a virtual clock: every delay here (the fake native round
/// trips, the 20 ms negotiate debounce, the waits between steps) is a timer that
/// fires in order at its virtual time, so a loaded machine cannot reorder them
/// (2026-10-21: real-time waits flaked 3/10 under CPU load). Time advances 1 ms
/// at a time until [body] completes (or 60 virtual s pass: a hang fails).
void _vtest(String description, Future<void> Function() body) {
  test(description, () {
    fakeAsync((async) {
      _clock = async;
      var done = false;
      Object? error;
      StackTrace? stack;
      body().then(
        (_) => done = true,
        onError: (Object e, StackTrace s) {
          error = e;
          stack = s;
          done = true;
        },
      );
      while (!done && async.elapsed < const Duration(seconds: 60)) {
        async.elapse(const Duration(milliseconds: 1));
      }
      _clock = null;
      if (error != null) Error.throwWithStackTrace(error!, stack!);
      if (!done) fail('did not finish in 60 virtual seconds');
    });
  });
}

/// A Stopwatch on the virtual clock.
class _VirtualStopwatch {
  _VirtualStopwatch() : _start = _clock!.elapsed;
  final Duration _start;
  int get elapsedMilliseconds => (_clock!.elapsed - _start).inMilliseconds;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  group('MUSIC-SDP: overlapping offers on a music track change', () {
    _vtest('a debounced negotiate firing while the previous offer is still being created waits for it', () async {
      final s = await _publishedMic();
      addTearDown(s.transport.dispose);

      // music stop -> mic republished (new transceiver, no mid yet) -> negotiate
      s.pc.addSender();
      s.transport.negotiate(null);
      await _ms(25); // the 20 ms debounce fired: offer 1 is in its createOffer
      // music start -> the second republish's negotiate fires before offer 1 is applied
      s.pc.addSender();
      s.transport.negotiate(null);
      await _ms(120);

      expect(s.pc.localOfferRefusals, 0, reason: s.pc.log.join('\n'));
      expect(s.errors, isEmpty, reason: 'a NegotiationError here is the full rejoin seen on the phone');
      expect(
        s.sent,
        hasLength(2),
        reason: 'the mic offer + one offer in flight; the second change waits for its answer',
      );
      expect(s.pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer);

      // the answer replays the deferred offer: it carries the later sender too
      await s.answerLast();
      await _ms(60);
      expect(s.sent, hasLength(3), reason: s.pc.log.join('\n'));
      await s.answerLast();
      expect(s.pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
      expect(s.pc.mids.every((m) => m != null), isTrue, reason: 'every transceiver negotiated: ${s.pc.mids}');
      expect(s.pc.localOfferRefusals, 0);
      expect(s.errors, isEmpty);
    });

    _vtest('the answer\'s renegotiate replay and a debounced negotiate do not both create an offer', () async {
      final s = await _publishedMic();
      addTearDown(s.transport.dispose);

      // republish 1: offer A goes out (mid 1)
      s.pc.addSender();
      await s.transport.createAndSendOffer();
      expect(s.sent, hasLength(2));
      // republish 2 while A is unanswered: deferred (renegotiate)
      s.pc.addSender();
      s.transport.negotiate(null);
      await _ms(30);
      expect(s.sent, hasLength(2));
      expect(s.transport.renegotiate, isTrue);

      // a third change's debounce is pending when the answer to A lands: the
      // replay's createOffer is in flight when the debounce fires (20 ms)
      s.transport.negotiate(null);
      await s.answerLast();
      await _ms(120);

      expect(s.pc.localOfferRefusals, 0, reason: s.pc.log.join('\n'));
      expect(s.errors, isEmpty, reason: 'a NegotiationError here is the full rejoin seen on the phone');
      expect(s.sent, hasLength(3), reason: 'one replay offer, not two');
      await s.answerLast();
      await _ms(60);
      // the debounced call was asked for before the replay's snapshot but ran
      // after it, so it may ask once more: at most one extra offer, identical
      // m-lines, applied cleanly
      if (s.pc.signalingState == rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        expect(s.sent, hasLength(4), reason: s.pc.log.join('\n'));
        expect(_MidPc.midsOf(s.sent[3].sdp), _MidPc.midsOf(s.sent[2].sdp));
        await s.answerLast();
        await _ms(60);
      }
      expect(s.sent.length, lessThanOrEqualTo(4), reason: s.pc.log.join('\n'));
      expect(s.pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
      expect(s.pc.mids.every((m) => m != null), isTrue, reason: 'every transceiver negotiated: ${s.pc.mids}');
      expect(s.pc.localOfferRefusals, 0);
      expect(s.errors, isEmpty);
    });

    _vtest('an offer made after the answer satisfies the deferred replay: no empty extra offer', () async {
      final s = await _publishedMic();
      addTearDown(s.transport.dispose);

      s.pc.addSender();
      await s.transport.createAndSendOffer(); // offer A pending
      s.pc.addSender();
      await s.transport.createAndSendOffer(); // deferred: renegotiate
      expect(s.transport.renegotiate, isTrue);
      expect(s.sent, hasLength(2));

      // the next change's offer lands on the chain right after the answer step
      // and before the replay: it carries every change and clears the replay
      final answer = s.answerLast();
      final next = s.transport.createAndSendOffer();
      await Future.wait([answer, next]);
      await _ms(60);
      expect(s.sent, hasLength(3), reason: s.pc.log.join('\n'));
      await s.answerLast();
      await _ms(60);
      expect(s.sent, hasLength(3), reason: 'no empty extra round trip: ${s.pc.log.join('\n')}');
      expect(s.pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
      expect(s.pc.mids.every((m) => m != null), isTrue);
      expect(s.pc.localOfferRefusals, 0);
    });

    _vtest('a burst of 16 republishes (mute toggles + track changes) never refuses an offer', () async {
      final s = await _publishedMic();
      addTearDown(s.transport.dispose);

      for (var i = 0; i < 16; i++) {
        s.pc.addSender();
        s.transport.negotiate(null);
        // answer whatever is pending at irregular moments, like the SFU does
        await _ms(i.isEven ? 25 : 45);
        if (s.pc.signalingState == rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          unawaited(s.answerLast());
        }
      }
      for (var i = 0; i < 6; i++) {
        await _ms(60);
        if (s.pc.signalingState == rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer) await s.answerLast();
      }

      expect(s.pc.localOfferRefusals, 0, reason: s.pc.log.join('\n'));
      expect(s.errors, isEmpty);
      expect(s.pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
      expect(s.pc.mids, hasLength(17));
      expect(s.pc.mids.every((m) => m != null), isTrue, reason: '${s.pc.mids}');
    });

    _vtest('an ICE restart asked for while an offer is being created waits for it, then restarts', () async {
      final s = await _publishedMic();
      addTearDown(s.transport.dispose);
      s.transport.gravixRollbackStaleOffer = true;

      s.pc.addSender();
      final first = s.transport.createAndSendOffer();
      await _ms(5); // offer in its createOffer
      final restart = s.transport.createAndSendOffer(const RTCOfferOptions(iceRestart: true));
      await Future.wait([first, restart]);

      expect(s.pc.localOfferRefusals, 0, reason: s.pc.log.join('\n'));
      expect(s.pc.iceRestartOffers, 1);
      expect(s.sent, hasLength(3), reason: 'the publish offer, then the restart offer');
      await s.answerLast();
      expect(s.pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
    });

    _vtest('a step ahead that never finishes holds the next one only for gravixOfferChainWait', () async {
      final s = await _publishedMic();
      addTearDown(s.transport.dispose);
      s.transport.gravixOfferChainWait = const Duration(milliseconds: 50);

      s.pc.addSender();
      s.pc.createDelay = const Duration(days: 1); // a native createOffer that never returns
      unawaited(s.transport.createAndSendOffer());
      await _ms(5);
      s.pc.createDelay = const Duration(milliseconds: 5);
      final sw = _VirtualStopwatch();
      await s.transport.createAndSendOffer(const RTCOfferOptions(iceRestart: true));

      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(45));
      expect(s.pc.iceRestartOffers, 1);
      expect(s.sent, hasLength(2), reason: 'the mic offer, then the restart offer');
      expect(s.pc.localOfferRefusals, 0, reason: s.pc.log.join('\n'));
    });
  });

  // HOST-CAMERA (device run 2026-10-15, cold host joins): the app publishes the
  // camera while the first (mic) offer is out. Its negotiate() queued on the
  // offer chain in front of the answer, only to read have-local-offer and
  // defer, but first a native getSignalingState round trip under main-thread
  // load: the answer was held 24-423 ms in 4 of 10 runs (mic and camera live
  // slipped by the same), and an identical replay offer followed.
  group('HOST-CAMERA: the first answer is never held behind a deferred sender change', () {
    _vtest(
      'a sender change while the offer is pending defers with no native call; the answer is applied at once',
      () async {
        final s = await _publishedMic();
        addTearDown(s.transport.dispose);
        s.pc.signalingStateDelay = const Duration(milliseconds: 300); // a loaded main thread

        s.pc.addSender(); // the mic of the join
        await s.transport.createAndSendOffer(); // offer out: pending
        final nativeBefore = s.pc.signalingStateCalls;
        final createsBefore = s.pc.createOfferCalls;

        s.pc.addSender(); // the camera, published while the offer is out
        s.transport.negotiate(null);
        await _ms(25); // the debounce fired
        expect(s.pc.signalingStateCalls, nativeBefore, reason: 'no native round trip while the offer is pending');
        expect(s.pc.createOfferCalls, createsBefore);
        expect(s.transport.renegotiate, isTrue);

        final sw = _VirtualStopwatch();
        final answered = s.transport.setRemoteDescription(s.pc.answerTo(s.sent.last));
        // the answer step runs before anything the deferred change could do
        await _ms(5);
        expect(s.pc.log.where((l) => l.startsWith('remote:answer')), hasLength(2), reason: s.pc.log.join('\n'));
        expect(sw.elapsedMilliseconds, lessThan(200), reason: 'not held behind a 300 ms native call');
        await answered;
        await _ms(60);
        // the camera goes out in the replay, after the answer
        expect(s.sent, hasLength(3), reason: s.pc.log.join('\n'));
        final answerAt = s.pc.log.lastIndexWhere((l) => l.startsWith('remote:answer'));
        final replayAt = s.pc.log.lastIndexWhere((l) => l.startsWith('createOffer'));
        expect(replayAt, greaterThan(answerAt));
        await s.answerLast();
        expect(s.pc.mids.every((m) => m != null), isTrue);
        expect(s.pc.localOfferRefusals, 0);
        expect(s.errors, isEmpty);
      },
    );

    _vtest('an ICE restart while the offer is pending still takes the chain', () async {
      final s = await _publishedMic();
      addTearDown(s.transport.dispose);
      s.transport.gravixRollbackStaleOffer = true;
      s.pc.addSender();
      await s.transport.createAndSendOffer(); // pending
      await s.transport.createAndSendOffer(const RTCOfferOptions(iceRestart: true));
      expect(s.pc.iceRestartOffers, 1);
      expect(s.sent, hasLength(3));
      expect(s.pc.localOfferRefusals, 0, reason: s.pc.log.join('\n'));
    });

    _vtest('a replay whose sender set did not change since the last offer is skipped', () async {
      final s = await _publishedMic();
      addTearDown(s.transport.dispose);

      s.pc.addSender(); // the mic and camera transceivers both in the first offer
      s.pc.addSender();
      await s.transport.createAndSendOffer();
      // the camera's own negotiate arrives while that offer is out: deferred
      s.transport.negotiate(null);
      await _ms(25);
      expect(s.transport.renegotiate, isTrue);
      await s.answerLast();
      await _ms(60);
      expect(s.sent, hasLength(2), reason: 'no identical replay offer: ${s.pc.log.join('\n')}');
      expect(s.pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
      expect(s.transport.renegotiate, isFalse);

      // a later change is negotiated as usual
      s.pc.addSender();
      s.transport.negotiate(null);
      await _ms(60);
      expect(s.sent, hasLength(3));
      await s.answerLast();
      expect(s.pc.mids.every((m) => m != null), isTrue);
    });

    test('the sender set ignores what gathering adds to a later offer, not a sender change', () {
      const first =
          'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtcp:9 IN IP4 0.0.0.0\r\n'
          'a=mid:0\r\na=sendonly\r\na=msid:s a1\r\na=rtpmap:111 opus/48000/2\r\n';
      const gathered =
          'v=0\r\no=- 1 3 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
          'm=audio 53211 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 10.0.0.5\r\na=rtcp:9 IN IP4 0.0.0.0\r\n'
          'a=candidate:1 1 udp 2122260223 10.0.0.5 53211 typ host\r\na=end-of-candidates\r\n'
          'a=mid:0\r\na=sendonly\r\na=msid:s a1\r\na=rtpmap:111 opus/48000/2\r\n';
      expect(Transport.gravixSenderSet(gathered), Transport.gravixSenderSet(first));
      expect(
        Transport.gravixSenderSet(first.replaceFirst('a=sendonly', 'a=inactive')),
        isNot(Transport.gravixSenderSet(first)),
      );
      expect(
        Transport.gravixSenderSet(first.replaceFirst('msid:s a1', 'msid:s a2')),
        isNot(Transport.gravixSenderSet(first)),
      );
      expect(
        Transport.gravixSenderSet(first.replaceFirst('m=audio 9', 'm=audio 0')),
        isNot(Transport.gravixSenderSet(first)),
      );
    });

    _vtest('a replay is sent when a sender changed since the last offer', () async {
      final s = await _publishedMic();
      addTearDown(s.transport.dispose);

      s.pc.addSender();
      await s.transport.createAndSendOffer(); // pending
      s.pc.addSender(); // a new sender while pending
      s.transport.negotiate(null);
      await _ms(25);
      await s.answerLast();
      await _ms(60);
      expect(s.sent, hasLength(3), reason: s.pc.log.join('\n'));
      expect(_MidPc.midsOf(s.sent[2].sdp), hasLength(3));
      await s.answerLast();
      expect(s.pc.mids.every((m) => m != null), isTrue);
      expect(s.pc.localOfferRefusals, 0);
    });

    _vtest('a burst of 16 republishes with a slow native state read: 0 refusals, every sender negotiated', () async {
      final s = await _publishedMic();
      addTearDown(s.transport.dispose);
      s.pc.signalingStateDelay = const Duration(milliseconds: 15);

      for (var i = 0; i < 16; i++) {
        s.pc.addSender();
        s.transport.negotiate(null);
        await _ms(i.isEven ? 25 : 45);
        if (s.pc.signalingState == rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          unawaited(s.answerLast());
        }
      }
      for (var i = 0; i < 8; i++) {
        await _ms(80);
        if (s.pc.signalingState == rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer) await s.answerLast();
      }

      expect(s.pc.localOfferRefusals, 0, reason: s.pc.log.join('\n'));
      expect(s.errors, isEmpty);
      expect(s.pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
      expect(s.pc.mids, hasLength(17));
      expect(s.pc.mids.every((m) => m != null), isTrue, reason: '${s.pc.mids}');
    });
  });

  // HOST-VIDEO-COLD (device run B-g 2026-10-15, host video cold, 3/3 joins):
  // the camera's sender was added before the first publisher offer was
  // created, so that offer already carried mic + camera; the camera's own
  // negotiate() fired while the offer was being created, deferred, and an
  // identical replay followed the answer. The skip compared the FIRST offer of
  // a fresh connection with a post-answer re-offer, whose transport lines
  // differ (one transport per m-section before BUNDLE was accepted, one after;
  // candidates), so it never fired; the publisher's ICE only started after the
  // replay's setLocalDescription.
  group('HOST-VIDEO-COLD: a change already in the pending offer is never replayed', () {
    Future<_Setup> fresh() async {
      final pc = _MidPc();
      final transport = await Transport.create(
        (Map<String, dynamic> c, [Map<String, dynamic>? k]) async => pc,
        connectOptions: const ConnectOptions(),
      );
      final s = _Setup(transport, pc);
      transport.onOffer = s.sent.add;
      transport.onNegotiationError = s.errors.add;
      return s;
    }

    _vtest('the first offer already carried the camera: its late negotiate causes no replay offer', () async {
      final s = await fresh();
      addTearDown(s.transport.dispose);
      s.pc.addSender(); // the join's microphone
      s.pc.addSender(); // the camera, added before the first offer is created
      await s.transport.createAndSendOffer(); // the first offer: audio + video
      s.transport.negotiate(null); // the camera's negotiate, while that offer is out
      await _ms(30);
      await s.answerLast();
      await _ms(80);
      expect(s.sent, hasLength(1), reason: 'no identical replay: ${s.pc.log.join('\n')}');
      expect(s.pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
      expect(s.pc.mids.every((m) => m != null), isTrue);
    });

    _vtest('a negotiate asked for before the pending offer was created: no replay and no createOffer at all', () async {
      final s = await fresh();
      addTearDown(s.transport.dispose);
      s.pc.addSender();
      s.transport.negotiate(null); // debounced: fires while the offer below is being created
      await s.transport.createAndSendOffer();
      await _ms(40);
      await s.answerLast();
      await _ms(60);
      expect(s.pc.createOfferCalls, 1, reason: s.pc.log.join('\n'));
      expect(s.sent, hasLength(1));
    });

    _vtest('non-restart offers read no native signaling state', () async {
      final s = await fresh();
      addTearDown(s.transport.dispose);
      s.pc.addSender();
      await s.transport.createAndSendOffer();
      s.pc.addSender();
      s.transport.negotiate(null);
      await _ms(30);
      await s.answerLast();
      await _ms(60);
      await s.answerLast();
      expect(s.pc.signalingStateCalls, 0);
      expect(s.sent, hasLength(2));
    });

    _vtest('a real change made after the offer was created goes out right after the answer', () async {
      final s = await fresh();
      addTearDown(s.transport.dispose);
      s.pc.signalingStateDelay = const Duration(milliseconds: 200); // a loaded main thread
      s.pc.addSender();
      await s.transport.createAndSendOffer();
      s.pc.addSender(); // the camera, after the first offer
      s.transport.negotiate(null);
      await _ms(30);
      final sw = _VirtualStopwatch();
      await s.answerLast();
      expect(await _eventually(() => s.sent.length == 2), isTrue, reason: s.pc.log.join('\n'));
      expect(sw.elapsedMilliseconds, lessThan(150), reason: 'one createOffer (30 ms), no native state read');
      expect(_MidPc.midsOf(s.sent[1].sdp), hasLength(2));
      await s.answerLast();
      expect(s.pc.mids.every((m) => m != null), isTrue);
    });

    test('the sender set ignores transport lines (initial vs re-offer), not a sender change', () {
      final initial = _MidPc.sdpFor(['0', '1'], initial: true);
      final reoffer = _MidPc.sdpFor(['0', '1']);
      expect(Transport.gravixSenderSet(reoffer), Transport.gravixSenderSet(initial));
      expect(Transport.gravixSenderSet(_MidPc.sdpFor(['0', '1', '2'])), isNot(Transport.gravixSenderSet(initial)));
      expect(
        Transport.gravixSenderSet(reoffer.replaceFirst('a=sendonly', 'a=inactive')),
        isNot(Transport.gravixSenderSet(initial)),
      );
      expect(
        Transport.gravixSenderSet(reoffer.replaceFirst('msid:s t1', 'msid:s t9')),
        isNot(Transport.gravixSenderSet(initial)),
      );
      expect(
        Transport.gravixSenderSet(reoffer.replaceFirst('a=rtpmap:111 opus/48000/2', 'a=rtpmap:111 red/48000/2')),
        Transport.gravixSenderSet(initial),
        reason: 'codec lists are not senders (preferences are set on a new transceiver only)',
      );
    });

    _vtest('a remote candidate that arrives while the answer is being applied is not stuck', () async {
      final s = await fresh();
      addTearDown(s.transport.dispose);
      s.pc.addSender();
      await s.transport.createAndSendOffer();
      s.pc.remoteSetDelay = const Duration(milliseconds: 40);
      s.pc.remoteGetDelay = const Duration(milliseconds: 60);
      final answered = s.answerLast();
      await _ms(10);
      final cand = rtc.RTCIceCandidate('candidate:7 1 udp 1 10.0.0.9 6000 typ host', '0', 0);
      await Future.wait([answered, s.transport.addIceCandidate(cand)]);
      await _ms(80);
      expect(s.pc.addedCandidates, contains(cand), reason: 'added to the native side, not left pending');
    });

    _vtest('a remote candidate after the answer is added with no native description read', () async {
      final s = await fresh();
      addTearDown(s.transport.dispose);
      s.pc.addSender();
      await s.transport.createAndSendOffer();
      await s.answerLast();
      final before = s.pc.remoteGetCalls;
      await s.transport.addIceCandidate(rtc.RTCIceCandidate('candidate:8 1 udp 1 10.0.0.9 6001 typ host', '0', 0));
      expect(s.pc.remoteGetCalls, before);
      expect(s.pc.addedCandidates, hasLength(1));
    });
  });
}

Future<bool> _eventually(bool Function() cond, {Duration timeout = const Duration(seconds: 2)}) async {
  final end = _clock!.elapsed + timeout;
  while (_clock!.elapsed < end) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  return cond();
}
