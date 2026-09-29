// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Field 2026-09-30: the tester app restarted mid-call six times without a leave;
// the others saw a ghost participant for 10-20 s each (the SFU's ping timeout).
// A signal client / engine / room disposed while connected now writes the leave
// before closing the socket, once.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

class _FakeWs extends GravixRtcWebSocket {
  _FakeWs(this.onDispose0) {
    onDispose(() async {
      closed = true;
      onDispose0?.call();
    });
  }
  final void Function()? onDispose0;
  final sent = <lk_rtc.SignalRequest>[];
  bool closed = false;

  @override
  void send(List<int> data) {
    if (closed) return;
    sent.add(lk_rtc.SignalRequest.fromBuffer(data));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeWs ws;

  setUp(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in const ['dev.fluttercommunity.plus/device_info', 'dev.fluttercommunity.plus/package_info']) {
      m.setMockMethodCallHandler(MethodChannel(ch), (call) async => <String, dynamic>{});
    }
  });

  Future<SignalClient> connected() async {
    final sc = SignalClient((uri, {options, headers, networkOptions, preconnected}) async {
      ws = _FakeWs(options?.onDispose);
      return ws;
    });
    await sc.connect(
      'wss://sfu.example',
      'tok',
      connectOptions: const ConnectOptions(),
      roomOptions: const RoomOptions(),
    );
    expect(sc.connectionState, ConnectionState.connected);
    return sc;
  }

  int leaves() => ws.sent.where((r) => r.hasLeave()).length;

  test('signal client disposed while connected: one leave, before the socket closes', () async {
    final sc = await connected();
    await sc.dispose();
    expect(leaves(), 1);
    expect(ws.closed, isTrue);
  });

  test('a leave already sent is not sent again on dispose', () async {
    final sc = await connected();
    await sc.sendLeave();
    await sc.dispose();
    expect(leaves(), 1);
  });

  test('engine disposed while connected: leave, and the engine is closed (no reconnect on the server close)', () async {
    final sc = await connected();
    final engine = Engine(connectOptions: const ConnectOptions(), roomOptions: const RoomOptions(), signalClient: sc);
    engine.gravixLeaveBestEffort();
    expect(leaves(), 1);
    expect(engine.isClosed, isTrue);
    // the later disconnect()/dispose() does not send a second one
    await engine.dispose();
    expect(leaves(), 1);
  });

  test('not connected: nothing is sent', () async {
    final sc = await connected();
    await sc.cleanUp();
    final engine = Engine(connectOptions: const ConnectOptions(), roomOptions: const RoomOptions(), signalClient: sc);
    engine.gravixLeaveBestEffort();
    await engine.dispose();
    expect(leaves(), 0);
  });
}
