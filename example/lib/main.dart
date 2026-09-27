import 'dart:async';

import 'package:flutter/material.dart';

import 'package:gravix_rtc/gravix_rtc.dart';

import 'harness.dart';

Future<void> main() async {
  final appStartedAt = DateTime.now();
  WidgetsFlutterBinding.ensureInitialized();
  // Launch-intent extras / --dart-define decide whether this start is a scripted
  // measurement run (docs: example/README.md, "Join-latency harness").
  final harness = await HarnessConfig.load();
  runApp(MeetingApp(harness: harness, appStartedAt: appStartedAt));
}

/// Minimal Gravix Cloud meeting app for testing between two devices.
///
/// Join a room by a **custom room id** you share with the other device; the
/// app gets a join token from your backend's token endpoint (or uses a pasted
/// token) and
/// renders the local preview + remote participants as a tiled video grid.
class MeetingApp extends StatelessWidget {
  const MeetingApp({super.key, this.harness, this.appStartedAt});

  /// Non-null and enabled = start straight into the join-latency harness.
  final HarnessConfig? harness;
  final DateTime? appStartedAt;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gravix Cloud Meeting',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: (harness?.enabled ?? false)
          ? HarnessScreen(
              config: harness!,
              appStartedAt: appStartedAt ?? DateTime.now(),
            )
          : _MeetingHome(harness: harness, appStartedAt: appStartedAt),
    );
  }
}

class _MeetingHome extends StatefulWidget {
  const _MeetingHome({this.harness, this.appStartedAt});
  final HarnessConfig? harness;
  final DateTime? appStartedAt;

  @override
  State<_MeetingHome> createState() => _MeetingHomeState();
}

class _MeetingHomeState extends State<_MeetingHome> {
  final _room = GravixRoomService();

  final _urlCtrl = TextEditingController(text: 'wss://rtc.example.com');
  final _roomCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _tokenUrlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();

  bool _connecting = false;
  String? _error;
  String _meetingTitle = '';

  // ══ 0.2.0 OPT-IN FEATURES ══════════════════════════════════════════════════
  // Every one of these is off by default in the SDK. The lobby toggles exist so
  // the features can be exercised on a device; an app that wants none of them
  // writes exactly the code this example had before.

  /// Race the token response's region_urls and connect to the first responder.
  bool _regionProbe = false;

  /// v2 audio routing. Read once at connect time, so it is set before joining.
  /// See the internal on-device audio-routing checklist — this is how you run the A/B rows.
  bool _audioRoutingV2 = false;

  /// Hide mixer and linked participants from the grid.
  bool _filterPlumbing = false;

  /// Drop remote video on sustained poor quality.
  bool _audioOnlyFallback = false;

  final _fallback = GravixAudioOnlyFallback();

  /// uid -> latest video track, populated by onRemoteVideoTrack.
  final Map<String, VideoTrack> _remoteVideos = <String, VideoTrack>{};

  @override
  void initState() {
    super.initState();
    _room.onRemoteVideoTrack = (uid, track) {
      if (mounted) setState(() => _remoteVideos[uid] = track);
    };
    _room.onRemoteVideoTrackRemoved = (uid) {
      if (mounted) setState(() => _remoteVideos.remove(uid));
    };
    _room.onUserOffline = (uid) {
      if (mounted) setState(() => _remoteVideos.remove(uid));
    };
    _room.onDisconnected = () {
      if (mounted) setState(() => _remoteVideos.clear());
    };
  }

  Future<void> _join() async {
    final url = _urlCtrl.text.trim();
    final roomId = _roomCtrl.text.trim();
    final name = _nameCtrl.text.trim();
    if (roomId.isEmpty || name.isEmpty) {
      setState(() => _error = 'Enter a room id and your display name.');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
      _remoteVideos.clear();
    });
    try {
      // v2 routing is latched by connect(), so the flag has to be set first.
      GravixAudioRouting.v2 = _audioRoutingV2;

      // No secret on the device: either a token you pasted, or a token from
      // YOUR backend's endpoint (it holds the gateway secret and answers with
      // the gateway's /v1/token response). See doc/MIGRATION_TOKEN_PROVIDER.md.
      final token = _tokenCtrl.text.trim();
      final tokenUrl = _tokenUrlCtrl.text.trim();
      final GravixTokenProvider provider;
      if (token.isNotEmpty) {
        provider = GravixTokenProvider.literal(token: token, url: url);
      } else if (tokenUrl.isNotEmpty) {
        provider = GravixTokenProvider.endpoint(Uri.parse(tokenUrl));
      } else {
        throw StateError(
          'Paste a join token, or enter your token endpoint url.',
        );
      }

      final ok = await _room.connectWithTokenProvider(
        tokenProvider: provider,
        // The token service keys participants by this identity string; use
        // the display name so the other device sees who joined.
        request: GravixTokenRequest(
          room: roomId,
          identity: name,
          name: name,
          canPublish: true,
        ),
        publishMic: true,
        enableVideo: true,
        regionProbe: _regionProbe,
      );
      if (!ok) {
        throw StateError(
          'Connect failed — check the server url/token in the logs.',
        );
      }
      _meetingTitle = roomId;

      final room = _room.room;
      if (_audioOnlyFallback && room != null) _fallback.attach(room);

      debugPrint('join report: ${_room.lastConnectionReport}');
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _leave() async {
    await _fallback.detach();
    await _room.disconnect();
    if (mounted) setState(() => _remoteVideos.clear());
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _roomCtrl.dispose();
    _nameCtrl.dispose();
    _tokenUrlCtrl.dispose();
    _tokenCtrl.dispose();
    _fallback.dispose();
    unawaited(_room.dispose()); // async teardown; nothing to await here
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _room.isConnected,
      builder: (context, connected, _) {
        if (connected) {
          return _CallView(
            room: _room,
            title: _meetingTitle,
            remoteVideos: _remoteVideos,
            onLeave: _leave,
            roomView: _filterPlumbing
                ? const GravixRoomView()
                : GravixRoomView.showAll,
            fallback: _audioOnlyFallback ? _fallback : null,
          );
        }
        return _Lobby(
          urlCtrl: _urlCtrl,
          roomCtrl: _roomCtrl,
          nameCtrl: _nameCtrl,
          tokenUrlCtrl: _tokenUrlCtrl,
          tokenCtrl: _tokenCtrl,
          connecting: _connecting,
          error: _error,
          onJoin: _join,
          onOpenHarness: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => HarnessScreen(
                config: widget.harness ?? HarnessConfig(<String, String>{}),
                appStartedAt: widget.appStartedAt ?? DateTime.now(),
              ),
            ),
          ),
          regionProbe: _regionProbe,
          audioRoutingV2: _audioRoutingV2,
          filterPlumbing: _filterPlumbing,
          audioOnlyFallback: _audioOnlyFallback,
          onToggle: (name, value) => setState(() {
            switch (name) {
              case 'regionProbe':
                _regionProbe = value;
              case 'audioRoutingV2':
                _audioRoutingV2 = value;
              case 'filterPlumbing':
                _filterPlumbing = value;
              case 'audioOnlyFallback':
                _audioOnlyFallback = value;
            }
          }),
        );
      },
    );
  }
}

class _Lobby extends StatelessWidget {
  const _Lobby({
    required this.urlCtrl,
    required this.roomCtrl,
    required this.nameCtrl,
    required this.tokenUrlCtrl,
    required this.tokenCtrl,
    required this.connecting,
    required this.error,
    required this.onJoin,
    required this.onOpenHarness,
    required this.regionProbe,
    required this.audioRoutingV2,
    required this.filterPlumbing,
    required this.audioOnlyFallback,
    required this.onToggle,
  });

  final TextEditingController urlCtrl;
  final TextEditingController roomCtrl;
  final TextEditingController nameCtrl;
  final TextEditingController tokenUrlCtrl;
  final TextEditingController tokenCtrl;
  final bool connecting;
  final String? error;
  final Future<void> Function() onJoin;
  final VoidCallback onOpenHarness;
  final bool regionProbe;
  final bool audioRoutingV2;
  final bool filterPlumbing;
  final bool audioOnlyFallback;
  final void Function(String name, bool value) onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Gravix Cloud · Meeting')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Join a meeting', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(
                    'Pick any room id — share it with the other device to '
                    'meet. Use a distinct display name per device.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: roomCtrl,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Room id',
                      hintText: 'e.g. team-sync-42',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameCtrl,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                      hintText: 'e.g. Alice',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: urlCtrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'RTC server url',
                      border: OutlineInputBorder(),
                      helperText:
                          'May be overridden by the token response url.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: tokenCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Token (optional)',
                      hintText:
                          'Paste a join token, or use your token endpoint below',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const Divider(height: 28),
                  TextField(
                    controller: tokenUrlCtrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Token endpoint (your backend)',
                      hintText: 'https://api.example.com/rtc/token',
                      border: OutlineInputBorder(),
                      helperText:
                          'Only needed when no token is pasted. Never a gateway secret.',
                    ),
                  ),
                  const Divider(height: 28),
                  Text(
                    'Opt-in features (all off by default)',
                    style: theme.textTheme.bodySmall,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: regionProbe,
                    onChanged: connecting
                        ? null
                        : (v) => onToggle('regionProbe', v),
                    title: const Text('Probe-race connect'),
                    subtitle: const Text(
                      'Race the token response\'s region_urls; first responder '
                      'wins, pinned url on timeout. No effect without regions.',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: audioRoutingV2,
                    onChanged: connecting
                        ? null
                        : (v) => onToggle('audioRoutingV2', v),
                    title: const Text('Audio routing v2'),
                    subtitle: const Text(
                      'App-owned session, re-assert ladder, hot-plug handling. '
                      'Unvalidated — use this to run the device checklist A/B.',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: filterPlumbing,
                    onChanged: connecting
                        ? null
                        : (v) => onToggle('filterPlumbing', v),
                    title: const Text('Hide mixers and linked participants'),
                    subtitle: const Text(
                      'UI filter only — those participants stay subscribed.',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: audioOnlyFallback,
                    onChanged: connecting
                        ? null
                        : (v) => onToggle('audioOnlyFallback', v),
                    title: const Text('Audio-only fallback'),
                    subtitle: const Text(
                      'Drop remote video after 10s of poor quality; restore '
                      'after 45s of excellent.',
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton.icon(
                    onPressed: connecting ? null : onJoin,
                    icon: connecting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.videocam),
                    label: Text(connecting ? 'Joining…' : 'Join meeting'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: connecting ? null : onOpenHarness,
                    child: const Text('Join-latency harness…'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CallView extends StatelessWidget {
  const _CallView({
    required this.room,
    required this.title,
    required this.remoteVideos,
    required this.onLeave,
    required this.roomView,
    this.fallback,
  });

  final GravixRoomService room;
  final String title;
  final Map<String, VideoTrack> remoteVideos;
  final Future<void> Function() onLeave;
  final GravixRoomView roomView;
  final GravixAudioOnlyFallback? fallback;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: _RemoteGrid(
                room: room,
                remoteVideos: remoteVideos,
                roomView: roomView,
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: ValueListenableBuilder<bool>(
                valueListenable: room.isConnected,
                builder: (context, connected, _) => Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: connected ? Colors.green : Colors.grey,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    connected ? '● $title' : 'disconnected',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(top: 8, right: 8, child: _LocalPreview(room: room)),
            Positioned(
              top: 44,
              left: 8,
              right: 8,
              child: _Diagnostics(room: room, fallback: fallback),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _Controls(room: room, onLeave: onLeave),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows what the opt-in features actually did on this join.
class _Diagnostics extends StatelessWidget {
  const _Diagnostics({required this.room, this.fallback});

  final GravixRoomService room;
  final GravixAudioOnlyFallback? fallback;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GravixConnectionReport?>(
      valueListenable: room.connectionReport,
      builder: (context, report, _) {
        final lines = <String>[];
        if (report != null) {
          lines.add(
            report.usedProbedRegion
                ? 'region ${report.winningRegionUrl} won in '
                      '${report.regionSelection?.inMilliseconds}ms'
                : 'pinned url (${report.fallbackReason.name})',
          );
          final firstAudio = report.joinToFirstAudio;
          lines.add(
            firstAudio == null
                ? 'join→first audio: waiting'
                : 'join→first audio: ${firstAudio.inMilliseconds}ms',
          );
        }
        if (GravixAudioRouting.v2) {
          lines.add(
            'routing v2 · speaker=${GravixAudioRouting.speakerOn} · '
            'sessionRebuilds=${GravixAudioRouting.sessionGuard.rebuildCount}',
          );
        }
        if (lines.isEmpty) return const SizedBox.shrink();

        final fallbackPolicy = fallback;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _chip(lines.join('  ·  ')),
            if (fallbackPolicy != null)
              ValueListenableBuilder<bool>(
                valueListenable: fallbackPolicy.active,
                builder: (context, active, _) => active
                    ? Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: _chip('video paused — weak connection'),
                      )
                    : const SizedBox.shrink(),
              ),
          ],
        );
      },
    );
  }

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white70, fontSize: 11),
    ),
  );
}

class _RemoteGrid extends StatelessWidget {
  const _RemoteGrid({
    required this.room,
    required this.remoteVideos,
    required this.roomView,
  });

  final GravixRoomService room;
  final Map<String, VideoTrack> remoteVideos;
  final GravixRoomView roomView;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: room.activeSpeakers,
      builder: (context, speaking, _) {
        // The filter runs over the identities we would otherwise render. The
        // hidden participants stay subscribed — this only decides what the
        // grid shows.
        final liveRoom = room.room;
        final visible = liveRoom == null
            ? remoteVideos.keys.toSet()
            : roomView.filterIdentities(remoteVideos.keys, liveRoom);
        final videos = remoteVideos.entries
            .where((e) => visible.contains(e.key))
            .toList();
        if (videos.isEmpty) {
          return const Center(
            child: Text(
              'Waiting for others…',
              style: TextStyle(color: Colors.white70, fontSize: 18),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: videos.length == 1 ? 1 : 2,
            childAspectRatio: 4 / 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: videos.length,
          itemBuilder: (context, i) {
            final entry = videos[i];
            return _RemoteTile(
              uid: entry.key,
              track: entry.value,
              isSpeaking: speaking.contains(entry.key),
            );
          },
        );
      },
    );
  }
}

class _RemoteTile extends StatelessWidget {
  const _RemoteTile({
    required this.uid,
    required this.track,
    required this.isSpeaking,
  });

  final String uid;
  final VideoTrack track;
  final bool isSpeaking;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSpeaking ? Colors.greenAccent : Colors.white24,
          width: isSpeaking ? 3 : 1,
        ),
        boxShadow: isSpeaking
            ? [
                BoxShadow(
                  color: Colors.greenAccent.withValues(alpha: 0.35),
                  blurRadius: 16,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            VideoTrackRenderer(track, fit: VideoViewFit.cover),
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '#$uid',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalPreview extends StatelessWidget {
  const _LocalPreview({required this.room});

  final GravixRoomService room;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: room.isCameraEnabled,
      builder: (context, enabled, _) {
        final track = room.localVideoTrack;
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 96,
            height: 128,
            color: Colors.black.withValues(alpha: 0.55),
            alignment: Alignment.center,
            child: (enabled && track != null)
                ? VideoTrackRenderer(track, fit: VideoViewFit.cover)
                : const Icon(Icons.person, color: Colors.white54, size: 40),
          ),
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.room, required this.onLeave});

  final GravixRoomService room;
  final Future<void> Function() onLeave;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.75),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: room.isMicMuted,
            builder: (context, muted, _) => _CircleButton(
              icon: muted ? Icons.mic_off : Icons.mic,
              color: muted ? Colors.redAccent : null,
              tooltip: muted ? 'Unmute mic' : 'Mute mic',
              onPressed: () => room.muteLocalAudio(muted),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: room.isCameraEnabled,
            builder: (context, enabled, _) => _CircleButton(
              icon: enabled ? Icons.videocam : Icons.videocam_off,
              color: enabled ? null : Colors.redAccent,
              tooltip: enabled ? 'Turn camera off' : 'Turn camera on',
              onPressed: () => room.setCameraEnabled(!enabled),
            ),
          ),
          _CircleButton(
            icon: Icons.cameraswitch,
            tooltip: 'Switch camera',
            onPressed: () => room.switchCamera(),
          ),
          _CircleButton(
            icon: Icons.volume_off,
            tooltip: 'Mute everyone',
            onPressed: () => room.muteAllRemoteAudio(true),
          ),
          _CircleButton(
            icon: Icons.call_end,
            color: Colors.redAccent,
            tooltip: 'Leave',
            onPressed: onLeave,
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onPressed,
    this.color,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon),
      color: color ?? Colors.white,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(backgroundColor: Colors.white10),
    );
  }
}
