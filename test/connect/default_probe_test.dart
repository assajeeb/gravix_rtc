import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_region_prober.dart';

/// The default HEAD probe against a real local HTTP server.
///
/// `sdkHttpHead` does not throw on a non-2xx, so until 2026-09-19 a region whose
/// edge answered 503 (draining) or 404 (misrouted) WON the race on the strength
/// of answering at all. JS `probeRegions.ts` counts 2xx only and retries a
/// 405/501 once with GET; these tests pin the same rules here.
void main() {
  late HttpServer server;
  late Map<String, int> statusByMethod;
  late List<String> seen;

  setUp(() async {
    statusByMethod = {};
    seen = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      seen.add(req.method);
      req.response.statusCode = statusByMethod[req.method] ?? 200;
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  String url() => 'ws://127.0.0.1:${server.port}';

  test('a 2xx answer is a responder', () async {
    await GravixRegionProber.defaultProbe(url());
    expect(seen, ['HEAD']);
  });

  for (final status in [404, 500, 503]) {
    test('a $status answer is not a responder', () async {
      statusByMethod['HEAD'] = status;
      await expectLater(GravixRegionProber.defaultProbe(url()), throwsA(anything));
      expect(seen, ['HEAD'], reason: 'only 405/501 earn a GET retry');
    });
  }

  for (final status in [405, 501]) {
    test('an edge that refuses HEAD with $status is retried once with GET', () async {
      statusByMethod['HEAD'] = status;
      await GravixRegionProber.defaultProbe(url());
      expect(seen, ['HEAD', 'GET']);
    });
  }

  test('the GET retry is judged by the same 2xx rule', () async {
    statusByMethod['HEAD'] = 405;
    statusByMethod['GET'] = 503;
    await expectLater(GravixRegionProber.defaultProbe(url()), throwsA(anything));
    expect(seen, ['HEAD', 'GET']);
  });

  test('a 503 edge loses the race to a slower healthy one', () async {
    statusByMethod['HEAD'] = 503;
    final healthy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => healthy.close(force: true));
    healthy.listen((req) async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await req.response.close();
    });
    final outcome = await GravixRegionProber().race([url(), 'ws://127.0.0.1:${healthy.port}']);
    expect(outcome.winner, 'ws://127.0.0.1:${healthy.port}');
  });
}
