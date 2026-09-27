// Join-latency harness for a real phone.
//
// Why a harness and not a stopwatch. The question is "how long from the tap
// to audio, and where does that time go" — answered per step by the SDK's join
// timeline. For the answer to be worth anything the tap has to come through the
// real touch path (`adb shell input tap`, not a method call), the run has to be
// repeatable N times without a human typing a token on a phone keyboard, and
// the result has to leave the phone as one machine-readable line. This screen
// is that: configured by launch-intent extras or --dart-define, one big JOIN
// target with known coordinates, auto-leave after first audio, and one line of
// JSON per join in logcat under the fixed tag GRAVIX_JOIN_TIMELINE.
//
// It points at NOTHING by default. Every url is empty until a run supplies one.
//
// NEVER log a token, an api secret or a header value from here. The config dump
// below prints which fields are SET, not what they hold.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const _channel = MethodChannel('gravix.example/harness');

/// logcat tag of the one-line-per-join result.
const kTimelineTag = kGravixJoinTimelineLogTag;

/// logcat tag of harness state (`ready`, `tap`, `left`, `done`, `error`), so a
/// script knows when to inject the next tap.
const kHarnessTag = 'GRAVIX_HARNESS';

/// Both tags go through the SDK's own logger (`gravixLogLine`): the same fixed-tag
/// native `Log.i`, the same PART i/n chunking, the same code path a production
/// app uses when it sets `logJoinTimelines` - so what the driver script has been
/// validated against is what the owner's app emits.
Future<void> nativeLog(String tag, String line) => gravixLogLine(tag, line);

/// Everything a run can set. Launch-intent extras win over --dart-define, which
/// wins over the defaults; all three use the same key names.
class HarnessConfig {
  HarnessConfig(this._values);

  /// The complete key list. `String.fromEnvironment` needs a constant name, so
  /// the --dart-define layer is spelled out once, here.
  static const _defines = <String, String>{
    'harness': String.fromEnvironment('harness'),
    'wsUrl': String.fromEnvironment('wsUrl'),
    'token': String.fromEnvironment('token'),
    'tokenUrl': String.fromEnvironment('tokenUrl'),
    'tokenHeader': String.fromEnvironment('tokenHeader'),
    'room': String.fromEnvironment('room'),
    'identity': String.fromEnvironment('identity'),
    'name': String.fromEnvironment('name'),
    'joins': String.fromEnvironment('joins'),
    'cold': String.fromEnvironment('cold'),
    'label': String.fromEnvironment('label'),
    'network': String.fromEnvironment('network'),
    'timeoutSec': String.fromEnvironment('timeoutSec'),
    'holdMs': String.fromEnvironment('holdMs'),
    'autoTap': String.fromEnvironment('autoTap'),
    'pollMs': String.fromEnvironment('pollMs'),
    'prewarmMic': String.fromEnvironment('prewarmMic'),
    'regionProbe': String.fromEnvironment('regionProbe'),
    'publishMic': String.fromEnvironment('publishMic'),
    'tokenCache': String.fromEnvironment('tokenCache'),
    // Candidate toggles. One fenced slot per fast-connect candidate, here and in
    // the three places below, so the commit that adds a candidate (the SDK option
    // plus its toggle) can be reverted on its own without touching a neighbour:
    // the owner's rule is that whatever does not move the phone number goes.
    // <slot:prewarm>
    'prewarm': String.fromEnvironment('prewarm'),
    // </slot:prewarm>
    // <slot:parallelAudio>
    'parallelAudio': String.fromEnvironment('parallelAudio'),
    // </slot:parallelAudio>
    // <slot:parallelTokenProbe>
    'parallelTokenProbe': String.fromEnvironment('parallelTokenProbe'),
    // </slot:parallelTokenProbe>
    // <slot:staggerMs>
    'staggerMs': String.fromEnvironment('staggerMs'),
    // </slot:staggerMs>
    // <slot:fastAnswer>
    'fastAnswer': String.fromEnvironment('fastAnswer'),
    // </slot:fastAnswer>
    // <slot:earlyCallAudio>
    'earlyCallAudio': String.fromEnvironment('earlyCallAudio'),
    // </slot:earlyCallAudio>
    // <slot:singlePc>
    // </slot:singlePc>
  };

  /// Values that must never reach a log line.
  static const _secret = {'token', 'tokenHeader'};

  final Map<String, String> _values;

  static Future<HarnessConfig> load() async {
    final values = <String, String>{
      for (final e in _defines.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    try {
      final extras = await _channel.invokeMapMethod<String, String>(
        'getLaunchExtras',
      );
      if (extras != null) values.addAll(extras);
    } on MissingPluginException {
      // No native side (iOS, tests): --dart-define only.
    }
    return HarnessConfig(values);
  }

  String str(String key) => _values[key]?.trim() ?? '';
  bool flag(String key, {bool orElse = false}) {
    final v = str(key).toLowerCase();
    if (v.isEmpty) return orElse;
    return v == 'true' || v == '1';
  }

  int integer(String key, int orElse) => int.tryParse(str(key)) ?? orElse;
  void set(String key, String value) => _values[key] = value;

  bool get enabled => flag('harness');

  /// For the log: `key=value` for plain settings, `key=(set)` for secrets.
  Map<String, Object> describe() => <String, Object>{
    for (final e in _values.entries)
      if (e.value.isNotEmpty)
        e.key: _secret.contains(e.key) ? '(set)' : e.value,
  };
}

class HarnessScreen extends StatefulWidget {
  const HarnessScreen({
    super.key,
    required this.config,
    required this.appStartedAt,
  });
  final HarnessConfig config;
  final DateTime appStartedAt;

  @override
  State<HarnessScreen> createState() => _HarnessScreenState();
}

class _HarnessScreenState extends State<HarnessScreen> {
  // Lazy: the prober's stagger comes from the run's configuration.
  late final _room = GravixRoomService(
    regionProber: GravixRegionProber(
      stagger: Duration(milliseconds: widget.config.integer('staggerMs', 0)),
    ),
  );
  final _buttonKey = GlobalKey();
  GravixTokenProvider? _provider;
  String _providerSignature = '';

  int _run = 0;
  bool _busy = false;
  String _status = 'starting';
  DateTime? _tapDownAt;
  Completer<GravixJoinTimeline?>? _pending;
  final _lines = <String>[];

  static const _fields = <(String, String, bool)>[
    ('wsUrl', 'ws url (paste-token mode)', false),
    ('token', 'pasted token', true),
    ('tokenUrl', 'token-provider url (your backend)', false),
    ('tokenHeader', 'token-provider header  "Name: value"', true),
    ('room', 'room', false),
    ('identity', 'identity', false),
    ('joins', 'joins (N)', false),
    ('label', 'label', false),
  ];
  static const _switches = <String>[
    'cold',
    'regionProbe',
    'publishMic',
    'tokenCache',
    // <slot:prewarm>
    'prewarm',
    // </slot:prewarm>
    // <slot:parallelAudio>
    'parallelAudio',
    // </slot:parallelAudio>
    // <slot:parallelTokenProbe>
    'parallelTokenProbe',
    // </slot:parallelTokenProbe>
    // <slot:staggerMs>
    // </slot:staggerMs>
    // <slot:fastAnswer>
    'fastAnswer',
    // </slot:fastAnswer>
    // <slot:earlyCallAudio>
    'earlyCallAudio',
    // </slot:earlyCallAudio>
    // <slot:singlePc>
    // </slot:singlePc>
    'autoTap',
  ];
  late final Map<String, TextEditingController> _ctrl = {
    for (final f in _fields)
      f.$1: TextEditingController(text: widget.config.str(f.$1)),
  };

  HarnessConfig get _c => widget.config;
  int get _joins => _c.integer('joins', 1);

  @override
  void initState() {
    super.initState();
    _room.onJoinTimeline = (report) {
      final pending = _pending;
      if (pending != null && !pending.isCompleted) pending.complete(report);
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _announceReady());
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    unawaited(_room.dispose());
    super.dispose();
  }

  void _say(String status) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _lines.insert(
        0,
        '${DateTime.now().toIso8601String().substring(11, 23)}  $status',
      );
      if (_lines.length > 40) _lines.removeLast();
    });
  }

  Future<void> _event(String event, [Map<String, Object?> more = const {}]) =>
      nativeLog(
        kHarnessTag,
        jsonEncode(<String, Object?>{
          'event': event,
          'run': _run,
          'of': _joins,
          ...more,
        }),
      );

  /// Where to tap, in PHYSICAL pixels — what `adb shell input tap` takes.
  Map<String, int>? _buttonCentre() {
    final box = _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final centre = box.localToGlobal(box.size.center(Offset.zero));
    return {'x': (centre.dx * dpr).round(), 'y': (centre.dy * dpr).round()};
  }

  Future<void> _announceReady() async {
    if (_run >= _joins) {
      _say('done: $_run/$_joins joins');
      await _event('done');
      return;
    }
    if (_c.flag('prewarm')) await _prewarm();
    _say('ready for join ${_run + 1}/$_joins — tap JOIN');
    // `ready` is a promise to the script that a tap will be accepted NOW. The
    // JOIN button is re-enabled by the rebuild that _say just scheduled, so wait
    // for that frame to be on screen first: a tap injected against the previous
    // frame lands on a disabled button and the run stalls waiting for a join
    // that never started.
    await WidgetsBinding.instance.endOfFrame;
    await _event('ready', {'tap': _buttonCentre(), 'config': _c.describe()});
    if (_c.flag('autoTap')) {
      // No touch path: tapAt is then the moment the harness decided to join.
      // The report says so (context.tapSource), because that is not a tap.
      _tapDownAt = DateTime.now();
      unawaited(_runOne(tapSource: 'auto'));
    }
  }

  /// prewarm=true: what an app would do when its room list opens, done here
  /// BEFORE `ready` is announced — so by the time the script taps, the token,
  /// the region decision and the DNS/TLS warm-up are already paid for, and the
  /// timeline shows what is left.
  Future<void> _prewarm() async {
    try {
      for (final f in _fields) {
        _c.set(f.$1, _ctrl[f.$1]!.text);
      }
      final report = await _room.prewarm(
        tokenProvider: _providerFor(),
        request: _request(),
        regionProbe: _c.flag('regionProbe'),
        // prewarmMic: open-and-close the mic during the prewarm even for a LISTENER
        // join. Not for the permission - on Android that capture is what makes
        // flutter_webrtc activate its audio switch (communication mode, focus,
        // route) BEFORE the join instead of on the platform thread in the middle of
        // it. Costs what it says: the phone enters call audio mode at prewarm time.
        requestMicPermission: _c.flag('publishMic') || _c.flag('prewarmMic'),
      );
      await _event('prewarm', report.toJson());
    } catch (e) {
      await _event('error', {'message': 'prewarm: $e'});
    }
  }

  /// What the first [holdMs] of audio were like, as the receiver counted it: a
  /// fix that gets audio out sooner by having it start with a burst of
  /// concealment, discarded packets or time-compression has not fixed anything.
  Future<void> _logAudioStats() async {
    final counters = await _room.inboundAudioCounters();
    if (counters != null) await _event('audioStats', counters);
  }

  GravixTokenRequest _request() {
    final identity = _c.str('identity').isEmpty
        ? 'harness-${widget.appStartedAt.millisecondsSinceEpoch}'
        : _c.str('identity');
    return GravixTokenRequest(
      room: _c.str('room'),
      identity: identity,
      name: _c.str('name').isEmpty ? identity : _c.str('name'),
      canPublish: _c.flag('publishMic'),
    );
  }

  /// One provider for the whole session, rebuilt only when what it points at
  /// changed — the cache lives in the instance.
  GravixTokenProvider _providerFor() {
    final signature = [
      for (final k in const ['wsUrl', 'token', 'tokenUrl', 'tokenHeader'])
        _c.str(k),
    ].join('\u0000');
    final existing = _provider;
    if (existing != null && signature == _providerSignature) return existing;
    _providerSignature = signature;

    final GravixTokenProvider built;
    if (_c.str('token').isNotEmpty) {
      if (_c.str('wsUrl').isEmpty) {
        throw StateError('a pasted token needs wsUrl');
      }
      built = GravixTokenProvider.literal(
        token: _c.str('token'),
        url: _c.str('wsUrl'),
      );
    } else if (_c.str('tokenUrl').isNotEmpty) {
      final header = _c.str('tokenHeader');
      final colon = header.indexOf(':');
      built = GravixTokenProvider.endpoint(
        Uri.parse(_c.str('tokenUrl')),
        headers: colon > 0
            ? {
                header.substring(0, colon).trim(): header
                    .substring(colon + 1)
                    .trim(),
              }
            : const {},
      );
    } else {
      throw StateError('set token+wsUrl, or tokenUrl');
    }
    return _provider = built;
  }

  Future<void> _runOne({required String tapSource}) async {
    if (_busy || _run >= _joins) return;
    _busy = true;
    _run++;
    final tapAt = _tapDownAt ?? DateTime.now();
    _tapDownAt = null;
    for (final f in _fields) {
      _c.set(f.$1, _ctrl[f.$1]!.text);
    }
    _say('join $_run/$_joins …');
    unawaited(_event('tap', {'tapSource': tapSource}));

    GravixJoinTimeline? report;
    String? error;
    try {
      final provider = _providerFor();
      final request = _request();
      // Default: every join pays for its token, like the apps in the field do
      // today. tokenCache=true keeps it, to measure the provider's cache; a
      // prewarmed run keeps it by definition.
      if (!_c.flag('tokenCache') && !_c.flag('prewarm')) {
        provider.invalidate(request);
      }

      final pending = _pending = Completer<GravixJoinTimeline?>();
      final ok = await _room.connectWithTokenProvider(
        tokenProvider: provider,
        request: request,
        publishMic: _c.flag('publishMic'),
        regionProbe: _c.flag('regionProbe'),
        // <slot:prewarm>
        // </slot:prewarm>
        // <slot:parallelAudio>
        parallelAudioSession: _c.flag('parallelAudio'),
        // </slot:parallelAudio>
        // <slot:parallelTokenProbe>
        parallelTokenAndProbe: _c.flag('parallelTokenProbe'),
        // </slot:parallelTokenProbe>
        // <slot:staggerMs>
        // </slot:staggerMs>
        // <slot:fastAnswer>
        fastAnswer: _c.flag('fastAnswer'),
        // </slot:fastAnswer>
        // <slot:earlyCallAudio>
        earlyCallAudio: _c.flag('earlyCallAudio'),
        // </slot:earlyCallAudio>
        // <slot:singlePc>
        // </slot:singlePc>
        joinTimeline: GravixJoinTimelineInput(
          tapAt: tapAt,
          // pollMs: the first-audio stats poll. Raising it is how to check that the
          // timeline's own getStats() calls are not what it is measuring.
          firstAudioPoll: Duration(milliseconds: _c.integer('pollMs', 50)),
          context: <String, Object?>{
            'run': _run,
            'of': _joins,
            'cold': _c.flag('cold'),
            'label': _c.str('label'),
            'network': _c.str('network'),
            'tapSource': tapSource,
            'tokenMode': _c.str('token').isNotEmpty
                ? 'paste'
                : (_c.str('tokenUrl').isNotEmpty
                      ? 'provider-url'
                      : 'deprecated-backend'),
            'tokenCache': _c.flag('tokenCache'),
            // <slot:prewarm>
            'prewarm': _c.flag('prewarm'),
            'prewarmMic': _c.flag('prewarmMic'),
            // </slot:prewarm>
            // <slot:parallelAudio>
            'parallelAudio': _c.flag('parallelAudio'),
            // </slot:parallelAudio>
            // <slot:parallelTokenProbe>
            'parallelTokenProbe': _c.flag('parallelTokenProbe'),
            // </slot:parallelTokenProbe>
            // <slot:staggerMs>
            'staggerMs': _c.integer('staggerMs', 0),
            // </slot:staggerMs>
            // <slot:fastAnswer>
            'fastAnswer': _c.flag('fastAnswer'),
            // </slot:fastAnswer>
            // <slot:earlyCallAudio>
            'earlyCallAudio': _c.flag('earlyCallAudio'),
            // </slot:earlyCallAudio>
            // <slot:singlePc>
            // </slot:singlePc>
            'msAppStartToTap': tapAt
                .difference(widget.appStartedAt)
                .inMilliseconds,
          },
        ),
      );
      if (!ok) error = _room.lastTokenError?.toString() ?? 'connect failed';
      // First audio, or the harness timeout — whichever is first. On timeout the
      // disconnect below makes the SDK emit the (incomplete) timeline.
      report = await pending.future.timeout(
        Duration(seconds: _c.integer('timeoutSec', 20)),
        onTimeout: () => null,
      );
      if (report != null && report.complete) {
        await Future<void>.delayed(
          Duration(milliseconds: _c.integer('holdMs', 500)),
        );
        await _logAudioStats();
      }
    } catch (e) {
      error = e.toString();
    }

    final pending = _pending;
    await _room.disconnect();
    report ??= (pending != null && pending.isCompleted)
        ? await pending.future
        : _room.joinTimeline.value;
    _pending = null;

    if (report != null) {
      await nativeLog(kTimelineTag, report.toJsonLine());
      _say(
        'join $_run: ${report.complete ? '${report.ms['tapToFirstAudioPlayoutProxy']} ms tap→audio(proxy)' : 'no audio (${report.endReason.name})'}'
        '${report.fallbackDetected ? '  FALLBACK ${report.pair?.transport}' : ''}',
      );
    }
    if (error != null) {
      _say('join $_run error: $error');
      await _event('error', {'message': error});
    }
    await _event('left');
    _busy = false;
    await _announceReady();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Gravix · join harness')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Text(_status, style: theme.textTheme.titleMedium),
                  ExpansionTile(
                    title: const Text('Configuration'),
                    subtitle: const Text(
                      'or: am start extras / --dart-define (same key names)',
                    ),
                    children: [
                      for (final f in _fields)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TextField(
                            controller: _ctrl[f.$1],
                            obscureText: f.$3,
                            decoration: InputDecoration(
                              labelText: f.$2,
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      for (final flag in _switches)
                        SwitchListTile(
                          dense: true,
                          title: Text(flag),
                          value: _c.flag(flag),
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _c.set(flag, '$v')),
                        ),
                    ],
                  ),
                  for (final line in _lines)
                    Text(line, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            // Pinned to the bottom with a fixed height: its centre does not move
            // when the list above scrolls, so the coordinates logged at `ready`
            // stay valid for the whole session.
            Padding(
              padding: const EdgeInsets.all(12),
              child: Listener(
                // Pointer DOWN is the tap time. onTap fires on pointer-up, after
                // the gesture arena resolves — that delay is real and belongs
                // to the measurement, which is why the join starts in onTap but
                // the clock starts here.
                onPointerDown: (_) {
                  if (!_busy) _tapDownAt = DateTime.now();
                },
                child: SizedBox(
                  key: _buttonKey,
                  width: double.infinity,
                  height: 220,
                  child: FilledButton(
                    onPressed: _busy || _run >= _joins
                        ? null
                        : () => unawaited(_runOne(tapSource: 'touch')),
                    child: Text(
                      _busy ? 'JOINING…' : 'JOIN',
                      style: const TextStyle(fontSize: 48),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
