// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

/// The room-music method channel (gravix_rtc 0.4.10+).
///
/// gravix_rtc <= 0.4.9 used `gravity.music_mixer`, the name the apps' own audio
/// kits use: the SDK's plugin, registered after the kit, took every kit call
/// (field 2026-10-05). The SDK never registers that name again.
const String kGravixMusicChannel = 'com.gravitycompile.gravix_rtc/music';

/// Fans the native -> Dart events of one music channel out to every Dart-side
/// user (GravixMusicController and GravixRoomMusic share the channel; a
/// MethodChannel takes one handler only).
@internal
class GravixMusicEventHub {
  GravixMusicEventHub._(this.channel);

  final MethodChannel channel;
  final _subs = <Future<void> Function(MethodCall call)>[];

  static final _hubs = <String, GravixMusicEventHub>{};

  static GravixMusicEventHub of(MethodChannel channel) {
    final hub = _hubs[channel.name];
    if (hub != null && identical(hub.channel, channel)) return hub;
    // a different MethodChannel object with the same name (tests): rebind
    final fresh = GravixMusicEventHub._(channel);
    if (hub != null) fresh._subs.addAll(hub._subs);
    _hubs[channel.name] = fresh;
    if (fresh._subs.isNotEmpty) channel.setMethodCallHandler(fresh._dispatch);
    return fresh;
  }

  void add(Future<void> Function(MethodCall call) handler) {
    _subs.add(handler);
    if (_subs.length == 1) channel.setMethodCallHandler(_dispatch);
  }

  void remove(Future<void> Function(MethodCall call) handler) {
    _subs.remove(handler);
    if (_subs.isEmpty) channel.setMethodCallHandler(null);
  }

  Future<dynamic> _dispatch(MethodCall call) async {
    for (final s in List.of(_subs)) {
      try {
        await s(call);
      } catch (_) {}
    }
    return null;
  }

  @visibleForTesting
  static void debugReset() {
    for (final h in _hubs.values) {
      h._subs.clear();
      h.channel.setMethodCallHandler(null);
    }
    _hubs.clear();
  }
}
