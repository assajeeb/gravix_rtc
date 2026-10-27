// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.
//
// Per-region media (owner 2026-10-21): doh1 is audio-only; a join that uses
// video goes to the nearest region allowing video. The pick itself runs on the
// shared fixture (region_shortlist_test.dart, `media` cases); this file covers
// the parsing, the join's media, the join url, the standby rule and the failover
// order.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/backend/gravix_token_provider.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_failover.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/connect/gravix_region_shortlist.dart';
import 'package:gravix_rtc/src/join/gravix_join_url.dart';

const _regionsUrl = 'https://gw.example.test/v1/regions';

Map<String, Object?> _r(String slug, [List<String>? media]) => {
  'region': slug,
  'url': 'wss://$slug.example.test',
  'media': ?media,
};

final _gulf = {
  'regions': [
    _r('doh1', ['audio']),
    _r('blr1'),
    _r('sgp1'),
  ],
  'shortlist': ['doh1', 'blr1', 'sgp1'],
};

String _jwt(Map<String, Object?> claims) {
  String b64(Object o) => base64Url.encode(utf8.encode(json.encode(o))).replaceAll('=', '');
  return '${b64({'alg': 'HS256', 'typ': 'JWT'})}.${b64(claims)}.c2ln';
}

Future<void> _measure(Map<String, Object?> body, Map<String, int?> rtt) => gravixMeasureRegions(
  regionsUrl: _regionsUrl,
  fetchDirectory: (_) async => GravixRegionDirectory.fromJson(json.decode(json.encode(body))),
  sampler: (r) async => rtt[r.region] == null ? null : Duration(milliseconds: rtt[r.region]!),
  store: GravixMemoryRegionListStore(),
  budget: const Duration(seconds: 5),
  networkType: () async => 'unknown',
);

GravixJoinCredentials _creds(String url, {List<GravixRegionUrl> entries = const [], String? home}) =>
    GravixJoinCredentials(token: 't', url: url, regionEntries: entries, homeRegion: home, fetchedAt: DateTime.now());

void main() {
  final lines = <String>[];
  setUp(() {
    gravixClearRegionMeasurement();
    lines.clear();
    GravixRegionLog.sink = lines.add;
  });
  tearDown(() => GravixRegionLog.sink = null);

  group('parsing', () {
    test('/v1/regions media: absent = every medium, kept through the stored copy', () {
      final dir = GravixRegionDirectory.fromJson({
        'regions': [
          _r('doh1', ['audio']),
          _r('blr1'),
          {
            ..._r('x1'),
            'media': ['Audio', 'VIDEO', 7],
          },
          {..._r('x2'), 'media': 'audio'},
        ],
      });
      expect(dir.regions.map((r) => r.media).toList(), [
        ['audio'],
        null,
        ['audio', 'video'],
        null,
      ]);
      final again = GravixRegionDirectory.fromJson(json.decode(json.encode(dir.toJson())));
      expect(again.regions, dir.regions);
      expect(gravixMediaAllows(null, GravixRoomMedia.video), isTrue);
      expect(gravixMediaAllows(const ['audio'], GravixRoomMedia.video), isFalse);
      expect(gravixMediaAllows(const [], GravixRoomMedia.audio), isFalse);
    });

    test('a token response region_urls entry may carry media too', () {
      final e = gravixRegionEntriesFrom({
        'region_urls': [
          _r('doh1', ['audio']),
          _r('blr1'),
        ],
      });
      expect(e.first.media, ['audio']);
      expect(e.last.media, isNull);
    });

    test('the media is not part of the token request (wire body, cache key)', () {
      const a = GravixTokenRequest(room: 'r', identity: 'u', media: GravixRoomMedia.audio);
      const b = GravixTokenRequest(room: 'r', identity: 'u');
      expect(a.toJson(), b.toJson());
      expect(a.cacheKey, b.cacheKey);
      expect(a.toString(), contains('media: audio'));
    });
  });

  group('the join media', () {
    test('default video; audio when declared; promoted, never demoted', () {
      expect(gravixJoinMedia(), GravixRoomMedia.video);
      expect(gravixJoinMedia(declared: GravixRoomMedia.audio), GravixRoomMedia.audio);
      expect(gravixJoinMedia(declared: GravixRoomMedia.audio, enableVideo: true), GravixRoomMedia.video);
      final camera = _jwt({
        'video': {
          'room': 'r',
          'roomJoin': true,
          'canPublishSources': ['microphone', 'camera'],
        },
      });
      final micOnly = _jwt({
        'video': {
          'room': 'r',
          'roomJoin': true,
          'canPublishSources': ['microphone'],
        },
      });
      expect(gravixMediaHintFromToken(camera), GravixRoomMedia.video);
      expect(gravixMediaHintFromToken(micOnly), isNull, reason: 'a mic-only publisher may still watch video');
      expect(gravixMediaHintFromToken('not a jwt'), isNull);
      expect(gravixJoinMedia(declared: GravixRoomMedia.audio, token: camera), GravixRoomMedia.video);
      expect(gravixJoinMedia(declared: GravixRoomMedia.audio, token: micOnly), GravixRoomMedia.audio);
      expect(gravixJoinMedia(declared: GravixRoomMedia.video, token: micOnly), GravixRoomMedia.video);
      expect(lines, contains('[GravixRegion] media media=video cause=token-grant-camera (declared audio)'));
      expect(lines, contains('[GravixRegion] media media=video cause=default'));
    });
  });

  group('join url', () {
    test('a video join leaves the audio-only best region; an audio join takes it', () async {
      await _measure(_gulf, {'doh1': 20, 'blr1': 60, 'sgp1': 90});
      final c = _creds('wss://doh1.example.test');
      final video = gravixJoinUrl(c, media: GravixRoomMedia.video);
      expect(video.region, 'blr1');
      expect(video.rttMs, 60);
      final audio = gravixJoinUrl(c, media: GravixRoomMedia.audio);
      expect(audio.region, 'doh1');
      expect(lines, contains('[GravixRegion] pick media=video skip=doh1(audio-only) -> blr1 rtt=60 reason=measured'));
    });

    test(
      'nothing measured: a video join with an audio-only token url goes to the first allowed shortlist region',
      () async {
        await _measure(_gulf, {});
        final choice = gravixJoinUrl(_creds('wss://doh1.example.test'), media: GravixRoomMedia.video);
        expect(choice.url, 'wss://blr1.example.test');
        expect(
          gravixJoinUrl(_creds('wss://doh1.example.test'), media: GravixRoomMedia.audio).source,
          GravixJoinUrlSource.token,
        );
      },
    );

    // Field 2026-10-27: token url = doh1 (audio-only), no region list in the
    // token, and doh1 not in this caller's shortlist (never measured): the video
    // join stayed on doh1 and the camera was refused (media_not_allowed).
    final unmeasuredDoh1 = {
      'regions': [
        _r('doh1', ['audio']),
        _r('dac1'),
        _r('blr1'),
        _r('sgp1'),
      ],
      'shortlist': ['dac1', 'blr1', 'sgp1'],
    };

    test('an unmeasured audio-only token url: a video join takes the best measured region allowing video', () async {
      await _measure(unmeasuredDoh1, {'doh1': 12, 'dac1': 140, 'blr1': 70, 'sgp1': 95});
      final video = gravixJoinUrl(_creds('wss://doh1.example.test'), media: GravixRoomMedia.video);
      expect(video.region, 'blr1');
      expect(video.url, 'wss://blr1.example.test');
      expect(video.source, GravixJoinUrlSource.measured);
      expect(
        lines,
        contains(
          '[GravixRegion] candidates media=video pinned=doh1(audio-only) unmeasured -> directory+measured cause=media-not-allowed',
        ),
      );
      final audio = gravixJoinUrl(_creds('wss://doh1.example.test'), media: GravixRoomMedia.audio);
      expect(audio.url, 'wss://doh1.example.test', reason: 'doh1 allows audio: the token url stays');
      expect(audio.source, GravixJoinUrlSource.token);
    });

    test('an unmeasured audio-only token url, nothing measured: the first shortlist region allowing video', () async {
      await _measure(unmeasuredDoh1, {});
      final video = gravixJoinUrl(_creds('wss://doh1.example.test'), media: GravixRoomMedia.video);
      expect(video.url, 'wss://dac1.example.test');
      expect(video.source, GravixJoinUrlSource.measured);
    });

    test('no region allows the media: the token url stays, and the log says why', () async {
      await _measure(
        {
          'regions': [
            _r('doh1', ['audio']),
            _r('blr1', ['audio']),
          ],
          'shortlist': ['blr1'],
        },
        {'blr1': 70},
      );
      final video = gravixJoinUrl(_creds('wss://doh1.example.test'), media: GravixRoomMedia.video);
      expect(video.url, 'wss://doh1.example.test');
      expect(video.source, GravixJoinUrlSource.token);
      expect(
        lines,
        contains('[GravixRegion] candidates media=video pinned=doh1(audio-only) kept cause=no-region-allows-video'),
      );
    });

    // 2026-10-27: a token signed on the device (GravixTokenProvider.local) has
    // no region list either; the same rule must move its video join off doh1.
    test('a device-signed token on doh1: a video join still moves to a region allowing video', () async {
      await _measure(unmeasuredDoh1, {'doh1': 12, 'dac1': 140, 'blr1': 70, 'sgp1': 95});
      final provider = GravixTokenProvider.local(
        appId: 'APPlocal',
        appCertificate: 'x' * 32,
        url: 'wss://doh1.example.test',
      );
      final creds = await provider.getCredentials(
        const GravixTokenRequest(room: 'r1', identity: 'u1', canPublish: true),
      );
      expect(creds.regionEntries, isEmpty);
      final video = gravixJoinUrl(creds, media: GravixRoomMedia.video);
      expect(video.url, 'wss://blr1.example.test');
      expect(video.source, GravixJoinUrlSource.measured);
      final audio = gravixJoinUrl(creds, media: GravixRoomMedia.audio);
      expect(audio.url, 'wss://doh1.example.test');
    });

    test('a url outside the fleet is still never redirected', () async {
      await _measure(unmeasuredDoh1, {'blr1': 70});
      final video = gravixJoinUrl(_creds('wss://own.server.test'), media: GravixRoomMedia.video);
      expect(video.url, 'wss://own.server.test');
      expect(video.source, GravixJoinUrlSource.token);
      expect(gravixMeasuredCandidates('wss://own.server.test', media: GravixRoomMedia.video), isEmpty);
    });

    test('a standby open at an audio-only region does not take a video join', () async {
      await _measure(_gulf, {'doh1': 20, 'blr1': 60, 'sgp1': 90});
      final video = gravixJoinUrl(_creds('wss://doh1.example.test'), media: GravixRoomMedia.video);
      final kept = video.withStandby(standbyUrl: 'wss://doh1.example.test', pickedOpen: false, standbyOpen: true);
      expect(kept.url, video.url);
      expect(lines.last, startsWith('[GravixRegion] standbySkip media=video standby=doh1(audio-only)'));
      final other = video.withStandby(standbyUrl: 'wss://sgp1.example.test', pickedOpen: false, standbyOpen: true);
      expect(other.source, GravixJoinUrlSource.standby);
      final audio = gravixJoinUrl(_creds('wss://blr1.example.test'), media: GravixRoomMedia.audio);
      expect(
        audio.withStandby(standbyUrl: 'wss://doh1.example.test', pickedOpen: false, standbyOpen: true).url,
        'wss://doh1.example.test',
      );
    });

    test('a remembered url is checked by its region (gravixUrlAllowsMedia)', () async {
      await _measure(_gulf, {'doh1': 20});
      expect(gravixUrlAllowsMedia('wss://doh1.example.test/', GravixRoomMedia.video), isFalse);
      expect(gravixUrlAllowsMedia('wss://doh1.example.test', GravixRoomMedia.audio), isTrue);
      expect(gravixUrlAllowsMedia('wss://own.server.test', GravixRoomMedia.video), isTrue);
    });
  });

  group('hysteresis per medium', () {
    test('video joins do not flip between two close video regions across runs', () async {
      final store = GravixMemoryRegionListStore();
      Future<GravixRegionMeasurementResult> run(Map<String, int> rtt) => gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: (_) async => GravixRegionDirectory.fromJson(json.decode(json.encode(_gulf))),
        sampler: (r) async => rtt[r.region] == null ? null : Duration(milliseconds: rtt[r.region]!),
        store: store,
        budget: const Duration(seconds: 5),
        networkType: () async => 'unknown',
      );
      final first = await run({'doh1': 20, 'blr1': 60, 'sgp1': 70});
      expect(first.bestFor(GravixRoomMedia.video)?.region, 'blr1');
      final second = await run({'doh1': 20, 'blr1': 70, 'sgp1': 60});
      expect(second.bestFor(GravixRoomMedia.video)?.region, 'blr1');
      expect(second.mediaSelectReason[GravixRoomMedia.video]?.name, 'kept');
      expect(gravixJoinUrl(_creds('wss://doh1.example.test'), media: GravixRoomMedia.video).region, 'blr1');
      expect(lines, contains('[GravixRegion] select media=video -> blr1 rtt=70 reason=kept anchor=blr1'));
      expect(second.bestFor(GravixRoomMedia.audio)?.region, 'doh1');
    });
  });

  group('failover and refusals', () {
    test('regions not taking the media go last, never dropped', () async {
      await _measure(_gulf, {'doh1': 20, 'blr1': 60, 'sgp1': 90});
      final order = gravixOrderFailoverRegions(
        [
          for (final s in ['doh1', 'blr1', 'sgp1']) GravixRegionUrl(region: s, url: 'wss://$s.example.test'),
        ],
        regionOf: (r) => r.region,
        urlOf: (r) => r.url,
        media: GravixRoomMedia.video,
      );
      expect(order.map((r) => r.region), ['blr1', 'sgp1', 'doh1']);
      expect(lines.last, '[GravixRegion] failoverOrder media=video last=doh1 first=blr1,sgp1');
    });

    test('a media_not_allowed refusal: the region is avoided for that medium', () async {
      await _measure(_gulf, {'doh1': 20, 'blr1': 60, 'sgp1': 90});
      expect(gravixIsMediaNotAllowed('Signal request failed: NOT_ALLOWED - media_not_allowed: video'), isTrue);
      expect(gravixIsMediaNotAllowed(StateError('MEDIA_NOT_ALLOWED')), isTrue);
      expect(gravixIsMediaNotAllowed('not allowed'), isFalse);
      // the SFU's exact refusal of a video publish on a video-off node
      expect(gravixIsMediaNotAllowed('media_not_allowed'), isTrue);
      expect(gravixRefusedMedia('media_not_allowed'), GravixRoomMedia.video);
      expect(gravixRefusedMedia('media_not_allowed: audio'), GravixRoomMedia.audio);
      expect(gravixIsMediaNotAllowed(null), isFalse);
      gravixNoteMediaRefused('blr1', GravixRoomMedia.video);
      final c = _creds('wss://doh1.example.test');
      expect(gravixJoinUrl(c, media: GravixRoomMedia.video).region, 'sgp1');
      expect(gravixJoinUrl(c, media: GravixRoomMedia.audio).region, 'doh1');
      final later = DateTime.now().add(kGravixMediaRefusalLife + const Duration(seconds: 1));
      expect(
        gravixRegionAllowsMedia(
          const GravixRegionUrl(region: 'blr1', url: 'wss://blr1.example.test'),
          GravixRoomMedia.video,
          now: later,
        ),
        isTrue,
      );
    });
  });
}
