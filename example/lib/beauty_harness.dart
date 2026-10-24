// Beauty-effects device run (2026-10-24): the built-in GravixBeautyEffect through
// GravixRoomService on a real phone, scripted, timed, one JSON line per step in
// logcat under GRAVIX_BEAUTY.
//
// Roles (launch extra `role`):
//   beauty  publishes the camera through GravixBeautyEffect and runs the script
//           below (looks, reshape, flip, camera off/on, leave, rejoin);
//   plain   the same script on the SDK's normal camera (the baseline);
//   viewer  joins without a camera and logs the remote video it receives
//           (first track, size, fps, decoded/dropped frames) every 2 s.
//
// Built with `-t lib/beauty_main.dart`; started with `am start ...
// --es role beauty --es tokenUrl http://127.0.0.1:3001/token --es room <room>`.
// NEVER log a token or a license token from here.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

import 'harness.dart';

const kBeautyTag = 'GRAVIX_BEAUTY';

/// GravixBeautyEffect that times its own camera opening.
class _TimedBeauty extends GravixBeautyEffect {
  _TimedBeauty({super.licenseToken});
  int? lastOpenMs;

  @override
  Future<LocalVideoTrack> openCamera(CameraCaptureOptions options) async {
    final sw = Stopwatch()..start();
    final t = await super.openCamera(options);
    lastOpenMs = sw.elapsedMilliseconds;
    return t;
  }
}

class BeautyHarnessScreen extends StatefulWidget {
  const BeautyHarnessScreen({super.key, required this.config, required this.appStartedAt});
  final HarnessConfig config;
  final DateTime appStartedAt;

  @override
  State<BeautyHarnessScreen> createState() => _BeautyHarnessScreenState();
}

class _BeautyHarnessScreenState extends State<BeautyHarnessScreen> {
  late final String _role = widget.config.str('role').isEmpty ? 'beauty' : widget.config.str('role');
  late final _TimedBeauty? _fx = _role == 'beauty'
      ? _TimedBeauty(licenseToken: widget.config.str('licenseToken').isEmpty ? null : widget.config.str('licenseToken'))
      : null;
  late GravixRoomService _room;
  final _status = ValueNotifier<String>('starting');
  VideoTrack? _remote;
  Timer? _poll;
  int _seq = 0;
  bool _stopped = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _log(String step, [Map<String, Object?> data = const {}]) {
    final line = jsonEncode({'role': _role, 'seq': _seq++, 'step': step, 'tMs': DateTime.now().difference(widget.appStartedAt).inMilliseconds, ...data});
    nativeLog(kBeautyTag, line);
    _status.value = '$step ${data.isEmpty ? '' : data}';
  }

  GravixRoomService _newRoom() {
    final r = GravixRoomService(videoEffect: _fx);
    r.onRemoteVideoTrack = (uid, track) {
      _log('remote_track', {'uid': uid});
      setState(() => _remote = track);
    };
    r.onRemoteVideoTrackRemoved = (uid) {
      _log('remote_track_removed', {'uid': uid});
      setState(() => _remote = null);
    };
    return r;
  }

  Future<int> _timed(Future<void> Function() f) async {
    final sw = Stopwatch()..start();
    await f();
    return sw.elapsedMilliseconds;
  }

  Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  Future<bool> _join(int n) async {
    _room = _newRoom();
    final c = widget.config;
    final publisher = _role != 'viewer';
    final provider = GravixTokenProvider.endpoint(Uri.parse(c.str('tokenUrl')));
    final sw = Stopwatch()..start();
    final creds = await provider.getCredentials(GravixTokenRequest(
      room: c.str('room'),
      identity: '${c.str('identity').isEmpty ? _role : c.str('identity')}-$n',
      name: _role,
      canPublish: publisher,
    ));
    final tokenMs = sw.elapsedMilliseconds;
    final ok = await _room.connect(url: creds.url, token: creds.token, enableVideo: publisher);
    final connectMs = sw.elapsedMilliseconds - tokenMs;
    // The camera publish can complete after connect() returns: wait for the local track.
    var publishedMs = -1;
    if (publisher) {
      while (sw.elapsedMilliseconds < 15000 && _room.localVideoTrack == null) {
        await _wait(20);
      }
      if (_room.localVideoTrack != null) publishedMs = sw.elapsedMilliseconds;
    }
    // Time to the first frame the engine hands WebRTC (beauty), or the first
    // encoded frame of the SDK camera (plain): what the viewer waits for.
    var firstFrameMs = -1;
    if (publisher && ok) {
      while (sw.elapsedMilliseconds < 20000) {
        final cam = _fx?.camera;
        if (cam != null) {
          final st = await cam.stats();
          if (((st?['framesSent'] as num?) ?? 0) > 0) break;
        } else {
          final t = _room.localVideoTrack;
          final s = t == null ? null : await t.getSenderStats();
          if (s != null && s.isNotEmpty && ((s.first.framesSent ?? 0) > 0)) break;
        }
        await _wait(100);
      }
      if (sw.elapsedMilliseconds < 20000) firstFrameMs = sw.elapsedMilliseconds;
    }
    _log('join', {
      'n': n, 'ok': ok, 'firstFrameMs': firstFrameMs, 'tokenMs': tokenMs, 'connectMs': connectMs, 'cameraPublishedMs': publishedMs,
      'cameraOpenMs': _fx?.lastOpenMs, 'effectActive': _room.videoEffectActive.value,
    });
    setState(() {});
    return ok;
  }

  Future<void> _publisherScript() async {
    for (var n = 1; n <= 2 && !_stopped; n++) {
      if (!await _join(n)) return;
      await _wait(4000);
      await _faceAndStats('after_join');
      if (_fx != null) {
        for (final look in const ['glow', 'natural', 'rosy']) {
          final ms = await _timed(() => _room.setVideoEffectParams({'look': look}));
          _log('look', {'look': look, 'ms': ms});
          await _wait(3000);
        }
        final ms = await _timed(() => _room.setVideoEffectParams({'reshape': {'faceSlim': 0.4, 'bigEyes': 0.3}}));
        _log('reshape', {'ms': ms});
        await _wait(3000);
        // A caption look (text in the stream): must read correctly on the viewer.
        final gfx = (await rootBundle.load('assets/looks/caption.gfx')).buffer.asUint8List();
        final cms = await _timed(() => _room.setVideoEffectParams({'lookBytes': gfx}));
        _log('look', {'look': 'caption', 'ms': cms});
        await _wait(6000);
        await _room.setVideoEffectParams({'look': 'natural'});
      }
      // `flip=0`: skip (a phone whose back camera is broken, e.g. the test Infinix).
      for (var i = 0; i < (widget.config.str('flip') == '0' ? 0 : 2); i++) {
        final ms = await _timed(_room.switchCamera);
        _log('flip', {'to': _room.cameraPosition.name, 'ms': ms});
        await _wait(4000);
        await _faceAndStats('after_flip_${_room.cameraPosition.name}');
      }
      var ms = await _timed(() => _room.setCameraEnabled(false));
      _log('camera_off', {'ms': ms, 'effectActive': _room.videoEffectActive.value});
      await _wait(3000);
      ms = await _timed(() => _room.setCameraEnabled(true));
      _log('camera_on', {'ms': ms, 'cameraOpenMs': _fx?.lastOpenMs, 'effectActive': _room.videoEffectActive.value});
      await _wait(5000);
      await _faceAndStats('after_camera_on');
      ms = await _timed(_room.disconnect);
      _log('leave', {'n': n, 'ms': ms, 'cameraClosed': _fx == null ? null : _fx.camera == null});
      await _room.dispose();
      setState(() {});
      await _wait(3000);
    }
    _log('done');
  }

  Future<void> _faceAndStats(String at) async {
    final cam = _fx?.camera;
    if (cam == null) {
      _log('stats', {'at': at, 'camera': _role == 'plain' ? 'sdk' : null});
      return;
    }
    final face = await cam.faceInView(windowSeconds: 3);
    final stats = await cam.stats();
    _log('stats', {'at': at, 'faceInView': face, 'engine': stats});
  }

  Future<void> _viewerScript() async {
    if (!await _join(1)) return;
    var firstFrameLogged = false;
    final joinedAt = DateTime.now();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      final t = _remote;
      if (t is! RemoteVideoTrack) return;
      final s = await t.getReceiverStats();
      if (s == null) return;
      if (!firstFrameLogged && (s.framesDecoded ?? 0) > 0) {
        firstFrameLogged = true;
        _log('remote_first_frame', {'sinceJoinMs': DateTime.now().difference(joinedAt).inMilliseconds});
      }
      _log('remote_stats', {
        'w': s.frameWidth, 'h': s.frameHeight, 'fps': s.framesPerSecond,
        'decoded': s.framesDecoded, 'dropped': s.framesDropped,
      });
    });
    final holdSec = int.tryParse(widget.config.str('holdSec')) ?? 150;
    await _wait(holdSec * 1000);
    _poll?.cancel();
    await _room.disconnect();
    _log('done');
  }

  Future<void> _run() async {
    _log('config', {'room': widget.config.str('room'), 'licenseToken': widget.config.str('licenseToken').isEmpty ? 'unset' : '(set)'});
    if (_fx != null && widget.config.str('preload') == '1') {
      final sw = Stopwatch()..start();
      final ok = await _fx.preload();
      _log('preload', {'ok': ok, 'ms': sw.elapsedMilliseconds});
    }
    try {
      if (_role == 'viewer') {
        await _viewerScript();
      } else {
        await _publisherScript();
      }
    } catch (e) {
      _log('error', {'error': '$e'});
    }
  }

  @override
  void dispose() {
    _stopped = true;
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = _fx?.camera;
    Widget local = const SizedBox.shrink();
    if (cam != null) {
      local = GravixPreview(cam);
    } else if (_role == 'plain') {
      final t = _room.localVideoTrack;
      if (t != null) local = VideoTrackRenderer(t, fit: VideoViewFit.cover);
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          Expanded(child: _role == 'viewer'
              ? (_remote == null ? const Center(child: Text('waiting for video', style: TextStyle(color: Colors.white))) : VideoTrackRenderer(_remote!, fit: VideoViewFit.contain))
              : local),
          ValueListenableBuilder<String>(
            valueListenable: _status,
            builder: (_, s, _) => Padding(
              padding: const EdgeInsets.all(8),
              child: Text('[$_role] $s', style: const TextStyle(color: Colors.white, fontSize: 12), maxLines: 3),
            ),
          ),
        ]),
      ),
    );
  }
}
