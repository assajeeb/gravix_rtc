// 0.8.4: randomized interleavings of on/off/unpublish/leave across full
// reconnects, through LocalParticipant and GravixRoomService. Checks the real track and capture
// state and what the fake server received.
import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/room/gravix_room_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/participant/local.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/mic_uplink_pause.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/music_voice_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_camera.dart';
import '../support/fake_rtc.dart';

class Caps {
  final open = <String, String>{}; // id -> kind
  int n = 0;
  int opened = 0;
}

void mocks(Caps caps, Random rng, {int maxDelay = 25}) {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
    switch (call.method) {
      case 'getUserMedia':
        final c = (call.arguments as Map)['constraints'] as Map?;
        final isVideo = c?['video'] != null && c?['video'] != false;
        final id = '${isVideo ? 'v' : 'a'}-${++caps.n}';
        caps.opened++;
        caps.open[id] = isVideo ? 'video' : 'audio';
        if (const bool.fromEnvironment('CAPLOG')) print('CAP open $id');
        final d = rng.nextInt(maxDelay + 1);
        if (d > 0) await Future<void>.delayed(Duration(milliseconds: d));
        return <String, dynamic>{
          'streamId': 'st-$id',
          'audioTracks': isVideo ? <dynamic>[] : <dynamic>[<String, dynamic>{'id': id, 'label': 'mic', 'kind': 'audio', 'enabled': true}],
          'videoTracks': isVideo ? <dynamic>[<String, dynamic>{'id': id, 'label': 'camera', 'kind': 'video', 'enabled': true}] : <dynamic>[],
        };
      case 'trackDispose':
        caps.open.remove((call.arguments as Map)['trackId']);
        if (const bool.fromEnvironment('CAPLOG')) print('CAP close ${(call.arguments as Map)['trackId']} ${StackTrace.current.toString().split('\n').where((l) => l.contains('local.dart') || l.contains('room.dart') || l.contains('room_service')).take(4).join(' <- ')}');
        return null;
      case 'getSources':
        return <String, dynamic>{'sources': <dynamic>[]};
      case 'getRtpReceiverCapabilities':
        return <String, dynamic>{'codecs': <dynamic>[], 'headerExtensions': <dynamic>[], 'fecMechanisms': <dynamic>[]};
    }
    return null;
  });
}

void fullReconnect(Room r) {
  r.engine.fullReconnectOnNext = true;
  unawaited(r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed));
}

enum Op { micOn, micOff, camOn, camOff, unpubMic, unpubCam }

/// The server's view of a sid on the socket: its AddTrack, then its mute signals.
bool? wireMuted(FakeWs ws, String sid, String? cid) {
  bool? st;
  for (final q in ws.sent) {
    if (q.hasAddTrack() && q.addTrack.cid == cid) st = q.addTrack.muted;
    if (q.hasMute() && q.mute.sid == sid) st = q.mute.muted;
  }
  return st;
}

Future<List<String>> check(LocalParticipant lp, TrackSource src, String? want, FakeWs ws, Caps caps, {required bool stopsOnMute, String ui = '', bool voiceOnly = false}) async {
  final out = <String>[];
  final pubs = lp.trackPublications.values.where((p) => p.source == src).toList();
  final name = src.name;
  if (pubs.length > 1) out.add('$name: ${pubs.length} publications');
  for (final p in pubs) {
    final t = p.track;
    if (t == null) continue;
    final wire = wireMuted(ws, p.sid, t.getCid());
    if (want == 'on') {
      if (t.muted) out.add('$name: last call on, track muted (silent while on)');
      if (!t.isActive) out.add('$name: last call on, capture not active');
      if (!t.mediaStreamTrack.enabled) out.add('$name: last call on, mediaStreamTrack disabled');
      if (t.sender?.track == null) out.add('$name: last call on, sender has no track');
      if (wire == true) out.add('$name: last call on, server has it muted');
      final enc = t.sender?.parameters.encodings;
      if (src == TrackSource.microphone && enc != null && enc.isNotEmpty && enc.first.maxBitrate == MicUplinkPause.mutedMaxBitrate) {
        out.add('$name: last call on, sender capped at the muted bitrate');
      }
    } else if (want == 'off') {
      if (!t.muted) out.add('$name: last call off, track LIVE (not muted)');
      if (t.isActive && t.mediaStreamTrack.enabled && !GravixEngineMicMute.engaged) out.add('$name: last call off, capture enabled');
      if (wire == false && !(voiceOnly && src == TrackSource.microphone)) out.add('$name: last call off, server has it live');
      if (wire == true && voiceOnly && src == TrackSource.microphone) out.add('$name: voice-only mute, server has it muted (music cut)');
    } else if (want == 'unpub') {
      out.add('$name: last call unpublish, publication still there (muted=${t.muted})');
    }
  }
  if (want == 'on' && pubs.isEmpty) out.add('$name: last call on, no publication');
  final kind = src == TrackSource.microphone ? 'audio' : 'video';
  final openN = caps.open.values.where((k) => k == kind).length;
  if (want == 'on' && openN > 1) out.add('$name: $openN captures open');
  if (want == 'off' && stopsOnMute && openN > 0 && !(src == TrackSource.microphone && GravixEngineMicMute.engaged)) out.add('$name: last call off, $openN captures open');
  if (want == 'off' && !stopsOnMute && openN > 1) out.add('$name: $openN captures open');
  if (want == 'unpub' && openN > 0) out.add('$name: unpublished, $openN captures open');
  return out;
}

class Rig {
  Rig(this.seed) : rng = Random(seed);
  final int seed;
  final Random rng;
  final caps = Caps();
  final server = FakeSignalServer()
    ..joinResponse = ((_) => fakeJoinResponse())
    ..answerOffers = true
    ..answerMetadata = true;
  final pcs = FakeCamPcFactory();
  var holding = false;
  final answered = <String>{};
  void answerHeld() {
    final ws = server.sockets.last;
    for (final q in ws.sent.where((q) => q.hasAddTrack()).toList()) {
      if (answered.add('${ws.hashCode}:${q.addTrack.cid}')) {
        ws.deliver(
          lk_rtc.SignalResponse(
            trackPublished: lk_rtc.TrackPublishedResponse(
              cid: q.addTrack.cid,
              track: lk_models.TrackInfo(sid: 'TR_${ws.hashCode}_${q.addTrack.cid.hashCode}', type: q.addTrack.type, source: q.addTrack.source, name: q.addTrack.name, muted: q.addTrack.muted),
            ),
          ),
        );
      }
    }
  }
}

List<Object> script(Rig g, {required int n, required bool unpub, required bool leave}) {
  final ops = <Object>[];
  var rec = 0;
  for (var i = 0; i < n; i++) {
    final x = g.rng.nextInt(100);
    if (x < 32) {
      ops.add(g.rng.nextBool() ? (g.rng.nextBool() ? Op.micOn : Op.micOff) : (g.rng.nextBool() ? Op.camOn : Op.camOff));
    } else if (x < 40 && unpub) {
      ops.add(g.rng.nextBool() ? Op.unpubMic : Op.unpubCam);
    } else if (x < 55 && rec < 2) {
      ops.add('reconnect');
      rec++;
    } else if (x < 65) {
      ops.add('hold');
    } else if (x < 75) {
      ops.add('release');
    } else if (x < 95) {
      ops.add(g.rng.nextInt(16));
    } else {
      ops.add(g.rng.nextInt(80));
    }
  }
  if (leave) ops.insert(ops.length - g.rng.nextInt(3), 'leave');
  return ops;
}

Future<List<String>> runDirect(int seed, {bool engine = false, bool leaveVariant = false}) async {
  final g = Rig(seed);
  installRecoveryChannelMocks();
  mocks(g.caps, g.rng);
  autoConnectPcs(g.pcs);
  g.server.holdAddTrack = (_) => g.holding;
  final opts = RoomOptions(reconnectPolicy: FastPolicy());
  final r = Room(
    engine: Engine(connectOptions: ConnectOptions(timeouts: fastTimeouts()), roomOptions: opts, signalClient: SignalClient(g.server.connect), peerConnectionCreate: g.pcs.create),
    roomOptions: opts,
  );
  final problems = <String>[];
  final calls = <Future<void>>[];
  final trace = <String>[];
  try {
    await r.connect('wss://x.example', 'tok', connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0));
    final lp = r.localParticipant!;
    final want = <TrackSource, String?>{};
    // starting state
    if (g.rng.nextInt(3) > 0) {
      await lp.setMicrophoneEnabled(true);
      want[TrackSource.microphone] = 'on';
    }
    if (g.rng.nextInt(3) > 0) {
      await lp.setCameraEnabled(true);
      want[TrackSource.camera] = 'on';
    }
    final ops = script(g, n: 14, unpub: true, leave: leaveVariant);
    var left = false;
    for (final o in ops) {
      trace.add('$o');
      if (const bool.fromEnvironment('CAPLOG') && o is! int) print('OP $o');
      if (o is int) {
        if (o > 0) await settle(o);
      } else if (o == 'reconnect') {
        if (!left) fullReconnect(r);
      } else if (o == 'hold') {
        g.holding = true;
      } else if (o == 'release') {
        g.holding = false;
        g.answerHeld();
      } else if (o == 'leave') {
        left = true;
        calls.add(r.disconnect());
      } else if (o is Op) {
        if (left) continue;
        Future<void> call(Future<Object?> Function() f, TrackSource s, String w) {
          want[s] = w;
          return f().then<void>((_) {}, onError: (Object e) {
            trace.add('threw:$s:${e.runtimeType}');
            if (want[s] == w) want[s] = 'threw';
          });
        }
        switch (o) {
          case Op.micOn:
            calls.add(call(() => lp.setMicrophoneEnabled(true), TrackSource.microphone, 'on'));
          case Op.micOff:
            calls.add(call(() => lp.setMicrophoneEnabled(false), TrackSource.microphone, 'off'));
          case Op.camOn:
            calls.add(call(() => lp.setCameraEnabled(true), TrackSource.camera, 'on'));
          case Op.camOff:
            calls.add(call(() => lp.setCameraEnabled(false), TrackSource.camera, 'off'));
          case Op.unpubMic:
            final p = lp.getTrackPublicationBySource(TrackSource.microphone);
            if (p != null) calls.add(call(() => lp.removePublishedTrack(p.sid).then((_) => null), TrackSource.microphone, 'unpub'));
          case Op.unpubCam:
            final p = lp.getTrackPublicationBySource(TrackSource.camera);
            if (p != null) calls.add(call(() => lp.removePublishedTrack(p.sid).then((_) => null), TrackSource.camera, 'unpub'));
        }
      }
    }
    g.holding = false;
    // the reconnect ends: answer all until quiet
    final end = DateTime.now().add(const Duration(seconds: 7));
    var hung = false;
    var done = false;
    unawaited(Future.wait(calls).whenComplete(() => done = true));
    while (!done) {
      if (DateTime.now().isAfter(end)) {
        hung = true;
        break;
      }
      if (g.server.sockets.isNotEmpty) g.answerHeld();
      await settle(5);
    }
    if (hung) problems.add('a call did not end within 7 s of the reconnect');
    await eventually(() => !r.engine.gravixFullReconnectInProgress, timeout: const Duration(seconds: 3));
    for (var i = 0; i < 6; i++) {
      g.answerHeld();
      await settle(10);
    }
    trace.add('SNAP pubs=${lp.trackPublications.values.map((p) => '${p.source.name}:${p.sid}:muted=${(p.track)?.muted}:cid=${(p.track)?.getCid()}').toList()} open=${g.caps.open.keys.toList()} want=$want micW=${lp.gravixMicWanted} camW=${lp.gravixCameraWanted}');
    if (left) {
      await settle(const int.fromEnvironment('LATE', defaultValue: 300));
      if (g.caps.open.isNotEmpty) problems.add('left: captures still open ${g.caps.open}');
      if (lp.trackPublications.isNotEmpty) problems.add('left: ${lp.trackPublications.length} publications');
      if (lp.gravixCameraWanted) problems.add('left: gravixCameraWanted true');
      if (lp.gravixMicWanted) problems.add('left: gravixMicWanted true');
    } else {
      await settle(const int.fromEnvironment('LATE2', defaultValue: 0));
      final ws = g.server.sockets.last;
      for (final s in [TrackSource.microphone, TrackSource.camera]) {
        final w = want[s];
        if (w == 'threw') {
          for (final p in lp.trackPublications.values.where((p) => p.source == s)) {
            if ((p.track)?.muted == false) problems.add('${s.name}: last call failed, track live');
          }
          continue;
        }
        problems.addAll(await check(lp, s, w, ws, g.caps, stopsOnMute: true));
      }
    }
  } catch (e) {
    problems.add('threw $e');
  } finally {
    try {
      await r.dispose().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
  return [for (final p in problems) '$p | seed=$seed trace=${trace.join(',')}'];
}

Future<List<String>> runService(int seed, {required bool engine, bool leaveVariant = false, bool voiceOnly = false}) async {
  final g = Rig(seed);
  installRecoveryChannelMocks();
  mocks(g.caps, g.rng);
  autoConnectPcs(g.pcs);
  GravixEngineMicMute.debugReset(supported: () => engine, setNative: (_) async => true);
  GravixMusicVoiceMute.predicate = voiceOnly ? (_) => true : null;
  g.server.holdAddTrack = (_) => g.holding;
  final s = GravixRoomService(
    reconnectPolicy: FastPolicy(),
    createRoom: (options) => Room(
      engine: Engine(connectOptions: ConnectOptions(timeouts: fastTimeouts()), roomOptions: options, signalClient: SignalClient(g.server.connect), peerConnectionCreate: g.pcs.create),
      roomOptions: options,
    ),
    connectRoom: (room, u, token) => room.connect(u, token, connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0)),
  );
  final problems = <String>[];
  final calls = <Future<void>>[];
  final trace = <String>[];
  try {
    expect(await s.connect(url: 'wss://x.example', token: 'tok', publishMic: false), isTrue);
    final r = s.room!;
    final lp = s.localParticipant!;
    final want = <TrackSource, String?>{};
    if (g.rng.nextInt(3) > 0) {
      await s.setMicEnabled(true);
      want[TrackSource.microphone] = 'on';
    }
    if (g.rng.nextInt(3) > 0) {
      await s.setCameraEnabled(true);
      want[TrackSource.camera] = 'on';
    }
    final ops = script(g, n: 14, unpub: false, leave: leaveVariant);
    var left = false;
    for (final o in ops) {
      trace.add('$o');
      if (const bool.fromEnvironment('CAPLOG') && o is! int) print('OP $o');
      if (o is int) {
        if (o > 0) await settle(o);
      } else if (o == 'reconnect') {
        if (!left) fullReconnect(r);
      } else if (o == 'hold') {
        g.holding = true;
      } else if (o == 'release') {
        g.holding = false;
        g.answerHeld();
      } else if (o == 'leave') {
        left = true;
        calls.add(s.disconnect());
      } else if (o is Op) {
        if (left) continue;
        switch (o) {
          case Op.micOn:
            want[TrackSource.microphone] = 'on';
            calls.add(s.setMicEnabled(true));
          case Op.micOff:
            want[TrackSource.microphone] = 'off';
            calls.add(s.setMicEnabled(false));
          case Op.camOn:
            want[TrackSource.camera] = 'on';
            calls.add(s.setCameraEnabled(true));
          case Op.camOff:
            want[TrackSource.camera] = 'off';
            calls.add(s.setCameraEnabled(false));
          default:
        }
      }
    }
    g.holding = false;
    final end = DateTime.now().add(const Duration(seconds: 7));
    var hung = false;
    var done = false;
    unawaited(Future.wait(calls).whenComplete(() => done = true));
    while (!done) {
      if (DateTime.now().isAfter(end)) {
        hung = true;
        break;
      }
      g.answerHeld();
      await settle(5);
    }
    if (hung) problems.add('a call did not end within 7 s of the reconnect');
    await eventually(() => !r.engine.gravixFullReconnectInProgress, timeout: const Duration(seconds: 3));
    for (var i = 0; i < 6; i++) {
      g.answerHeld();
      await settle(10);
    }
    trace.add('SNAP pubs=${lp.trackPublications.values.map((p) => '${p.source.name}:${p.sid}:muted=${(p.track)?.muted}').toList()} open=${g.caps.open.keys.toList()} want=$want ui=${s.isMicMuted.value}/${s.isCameraEnabled.value} micW=${lp.gravixMicWanted} camW=${lp.gravixCameraWanted}');
    if (left) {
      await settle(const int.fromEnvironment('LATE', defaultValue: 300));
      if (g.caps.open.isNotEmpty) problems.add('left: captures still open ${g.caps.open}');
    } else {
      final ws = g.server.sockets.last;
      for (final src in [TrackSource.microphone, TrackSource.camera]) {
        problems.addAll(await check(lp, src, want[src], ws, g.caps, stopsOnMute: false, voiceOnly: voiceOnly));
      }
      final mw = want[TrackSource.microphone];
      if (mw == 'on' && s.isMicMuted.value) problems.add('mic: last call on, UI says muted');
      if (mw == 'off' && !s.isMicMuted.value) problems.add('mic: last call off, UI says on');
      final cw = want[TrackSource.camera];
      if (cw == 'on' && !s.isCameraEnabled.value) problems.add('camera: last call on, UI says off');
      if (cw == 'off' && s.isCameraEnabled.value) problems.add('camera: last call off, UI says on');
      // control is not lost: a further toggle works
      if (problems.isEmpty) {
        await s.setMicEnabled(false).timeout(const Duration(seconds: 2));
        final p = lp.getTrackPublicationBySource(TrackSource.microphone);
        if (p != null && (p.track)?.muted == false) problems.add('mic: follow-up off did not mute');
        await s.setMicEnabled(true).timeout(const Duration(seconds: 2));
        final p2 = lp.getTrackPublicationBySource(TrackSource.microphone);
        if (p2 == null || (p2.track)?.muted != false) problems.add('mic: follow-up on did not unmute');
      }
    }
  } catch (e) {
    problems.add('threw $e');
  } finally {
    try {
      await s.dispose().timeout(const Duration(seconds: 4));
    } catch (_) {}
    GravixEngineMicMute.debugReset();
    GravixMusicVoiceMute.predicate = null;
  }
  return [for (final p in problems) '$p | seed=$seed trace=${trace.join(',')}'];
}

void report(String name, Map<String, List<String>> buckets, int runs) {
  // ignore: avoid_print
  print('=== $name: $runs runs, ${buckets.values.fold<int>(0, (a, b) => a + b.length)} problems');
  final keys = buckets.keys.toList()..sort((a, b) => buckets[b]!.length - buckets[a]!.length);
  for (final k in keys) {
    // ignore: avoid_print
    print('  [${buckets[k]!.length}] $k\n     e.g. ${buckets[k]!.first.split(' | ').last}');
  }
}

void note(Map<String, List<String>> b, List<String> ps) {
  for (final p in ps) {
    b.putIfAbsent(p.split(' | ').first.replaceAll(RegExp(r'[av]-\d+'), 'x'), () => []).add(p);
  }
}

Future<void> guarded(Map<String, List<String>> b, int seed, Future<List<String>> Function() f) async {
  final done = Completer<void>();
  runZonedGuarded(() async {
    try {
      note(b, await f());
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }, (e, st) => note(b, ['uncaught ${e.runtimeType}: ${'$e'.split('\n').first} | seed=$seed']));
  await done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // a small seeded set in the suite; SEEDS and BASE for a longer run
  const seeds = int.fromEnvironment('SEEDS', defaultValue: 8);
  const base = int.fromEnvironment('BASE', defaultValue: 0);
  const t = Timeout(Duration(minutes: 9));
  void clean(Map<String, List<String>> b, String name, int runs) {
    report(name, b, runs);
    expect(b.keys.toList(), isEmpty, reason: b.values.map((v) => v.first).join('\n'));
  }

  test('direct', () async {
    final b = <String, List<String>>{};
    for (var i = 0; i < seeds; i++) {
      await guarded(b, base + i, () => runDirect(base + i));
    }
    clean(b, 'direct', seeds);
  }, timeout: t);

  test('direct, leave', () async {
    final b = <String, List<String>>{};
    for (var i = 0; i < seeds; i++) {
      await guarded(b, base + 10000 + i, () => runDirect(base + 10000 + i, leaveVariant: true));
    }
    clean(b, 'direct leave', seeds);
  }, timeout: t);

  for (final engine in [false, true]) {
    test('service engine=$engine', () async {
      final b = <String, List<String>>{};
      for (var i = 0; i < seeds; i++) {
        await guarded(b, base + 20000 + i, () => runService(base + 20000 + i, engine: engine));
      }
      clean(b, 'service engine=$engine', seeds);
    }, timeout: t);
    test('service leave engine=$engine', () async {
      final b = <String, List<String>>{};
      for (var i = 0; i < seeds; i++) {
        await guarded(b, base + 30000 + i, () => runService(base + 30000 + i, engine: engine, leaveVariant: true));
      }
      clean(b, 'service leave engine=$engine', seeds);
    }, timeout: t);
  }
}
