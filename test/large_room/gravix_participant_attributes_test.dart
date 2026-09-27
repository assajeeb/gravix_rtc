import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  GravixParticipantInfo info(Map<String, String> attributes, {String identity = '42'}) =>
      GravixParticipantInfo.fromAttributes(identity, attributes);

  group('gravix.role', () {
    test('maps the roles the SDK knows', () {
      expect(info({'gravix.role': 'host'}).role, GravixRole.host);
      expect(info({'gravix.role': 'cohost'}).role, GravixRole.cohost);
      expect(info({'gravix.role': 'co-host'}).role, GravixRole.cohost);
      expect(info({'gravix.role': 'viewer'}).role, GravixRole.viewer);
      expect(info({'gravix.role': 'listener'}).role, GravixRole.viewer);
      expect(info({'gravix.role': 'mixer'}).role, GravixRole.mixer);
    });

    test('is case-insensitive', () {
      expect(info({'gravix.role': 'HOST'}).role, GravixRole.host);
    });

    test('an unknown role is `other` and keeps its raw value', () {
      final i = info({'gravix.role': 'moderator'});
      expect(i.role, GravixRole.other);
      expect(i.rawRole, 'moderator');
    });

    test('absent and empty both read as unknown', () {
      expect(info({}).role, GravixRole.unknown);
      expect(info({'gravix.role': ''}).role, GravixRole.unknown);
      expect(info({}).rawRole, isNull);
    });

    test('canPublishByRole is false for a room that sets no roles', () {
      expect(info({}).canPublishByRole, isFalse);
      expect(info({'gravix.role': 'host'}).canPublishByRole, isTrue);
      expect(info({'gravix.role': 'cohost'}).canPublishByRole, isTrue);
      expect(info({'gravix.role': 'viewer'}).canPublishByRole, isFalse);
    });
  });

  group('gravix.mixed', () {
    test('accepts the shapes a server might send for true', () {
      expect(info({'gravix.mixed': 'true'}).mixed, isTrue);
      expect(info({'gravix.mixed': 'TRUE'}).mixed, isTrue);
      expect(info({'gravix.mixed': '1'}).mixed, isTrue);
      expect(info({'gravix.mixed': 'yes'}).mixed, isTrue);
    });

    test('anything else is false', () {
      expect(info({}).mixed, isFalse);
      expect(info({'gravix.mixed': 'false'}).mixed, isFalse);
      expect(info({'gravix.mixed': '0'}).mixed, isFalse);
      expect(info({'gravix.mixed': ''}).mixed, isFalse);
      expect(info({'gravix.mixed': 'maybe'}).mixed, isFalse);
    });

    test('isMixer is true from either the role or the flag', () {
      expect(info({'gravix.role': 'mixer'}).isMixer, isTrue);
      expect(info({'gravix.mixed': 'true'}).isMixer, isTrue);
      expect(info({'gravix.role': 'host', 'gravix.mixed': 'true'}).isMixer, isTrue);
      expect(info({'gravix.role': 'host'}).isMixer, isFalse);
    });
  });

  group('gravix.linked_from and gravix.broadcast_url', () {
    test('are read verbatim', () {
      final i = info({'gravix.linked_from': 'room-7', 'gravix.broadcast_url': 'https://cdn.example/live.m3u8'});
      expect(i.linkedFrom, 'room-7');
      expect(i.broadcastUrl, 'https://cdn.example/live.m3u8');
      expect(i.isLinked, isTrue);
      expect(i.isBroadcasting, isTrue);
    });

    test('absent and empty both read as null, not as a present empty value', () {
      expect(info({}).linkedFrom, isNull);
      expect(info({'gravix.linked_from': ''}).linkedFrom, isNull);
      expect(info({'gravix.linked_from': ''}).isLinked, isFalse);
      expect(info({'gravix.broadcast_url': ''}).isBroadcasting, isFalse);
    });
  });

  test('a participant with no gravix attributes is completely inert', () {
    final i = info({'cameraFacing': 'front'});

    expect(i.role, GravixRole.unknown);
    expect(i.mixed, isFalse);
    expect(i.isMixer, isFalse);
    expect(i.isLinked, isFalse);
    expect(i.isBroadcasting, isFalse);
    expect(i.canPublishByRole, isFalse);
  });

  test('value equality, so a rebuild on attributes-changed can be diffed', () {
    expect(info({'gravix.role': 'host'}), info({'gravix.role': 'host'}));
    expect(info({'gravix.role': 'host'}).hashCode, info({'gravix.role': 'host'}).hashCode);
    expect(info({'gravix.role': 'host'}), isNot(info({'gravix.role': 'viewer'})));
    expect(info({'gravix.role': 'host'}, identity: '1'), isNot(info({'gravix.role': 'host'}, identity: '2')));
  });
}
