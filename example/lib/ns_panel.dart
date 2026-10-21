// Noise suppression in the example: a mode toggle with the live engine,
// reason, route and frame time (p95), and a timed script for device runs
// (`--es ns auto --es nsScript "15:off,30:standard,45:studio,60:music,..."`).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const kNsHarnessTag = 'GravixNSHarness';

/// `ns` extra -> options (absent / empty = null = today's behaviour).
GravixNoiseSuppressionOptions? nsOptionsFromExtra(String mode, {String? packUrl}) {
  final m = gravixNsModeFromName(mode.trim());
  if (m == null) return null;
  return GravixNoiseSuppressionOptions(mode: m, studioPackUrl: packUrl == null || packUrl.isEmpty ? null : packUrl);
}

class NoiseSuppressionPanel extends StatefulWidget {
  const NoiseSuppressionPanel({super.key});

  @override
  State<NoiseSuppressionPanel> createState() => _NoiseSuppressionPanelState();
}

class _NoiseSuppressionPanelState extends State<NoiseSuppressionPanel> {
  final _ns = GravixNoiseSuppression.instance;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _ns.refreshStats());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GravixNsState>(
      valueListenable: _ns.state,
      builder: (context, s, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Noise suppression'),
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<GravixNoiseSuppressionMode>(
                  segments: [
                    for (final m in GravixNoiseSuppressionMode.values) ButtonSegment(value: m, label: Text(m.name)),
                  ],
                  selected: {s.mode},
                  onSelectionChanged: (v) => unawaited(_ns.setMode(v.first)),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'engine ${gravixNsEngineName(s.engine)} · ${s.reason} · ${gravixNsRouteName(s.route)} '
                '${s.rate ?? '?'} Hz · p95 ${s.p95Us ?? '-'} us${s.musicBypass ? ' · music bypass' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Runs `<sec>:<action>` steps after a join: off | standard | studio | auto
/// (setMode), music / nomusic (room music from [musicPath]), earpiece / speaker,
/// stats. Every step and its resulting state is logged under [kNsHarnessTag].
Future<void> runNsScript(String script, GravixRoomService room, {String? musicPath}) async {
  final steps = <(int, String)>[];
  for (final part in script.split(',')) {
    final kv = part.trim().split(':');
    if (kv.length != 2) continue;
    final t = int.tryParse(kv[0].trim());
    if (t != null) steps.add((t, kv[1].trim()));
  }
  steps.sort((a, b) => a.$1.compareTo(b.$1));
  final ns = GravixNoiseSuppression.instance;
  final start = DateTime.now();
  Future<void> log(String line) => gravixLogLine(kNsHarnessTag, line);
  await log('script start steps=${steps.length} state=${ns.state.value}');
  for (final (t, action) in steps) {
    final wait = Duration(seconds: t) - DateTime.now().difference(start);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    final before = ns.state.value;
    try {
      final mode = gravixNsModeFromName(action);
      if (mode != null) {
        await ns.setMode(mode);
      } else {
        switch (action) {
          case 'music':
            if (musicPath == null || musicPath.isEmpty) throw StateError('no nsMusic path');
            await room.roomMusic.start(GravixMusicSource.file(musicPath), loop: true);
          case 'nomusic':
            await room.roomMusic.stop();
          case 'earpiece':
            await GravixAudioDevice.setEnableSpeakerphone(false);
          case 'speaker':
            await GravixAudioDevice.setEnableSpeakerphone(true);
          case 'stats':
            break;
          default:
            throw ArgumentError('unknown step $action');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final after = await ns.refreshStats();
      await log('step t=$t action=$action ok before=$before after=$after');
    } catch (e) {
      await log('step t=$t action=$action FAILED $e');
    }
  }
  await log('script end state=${ns.state.value}');
}
