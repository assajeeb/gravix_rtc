import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  GravixParticipantInfo person(String id) => GravixParticipantInfo(identity: id, rawRole: 'host');
  GravixParticipantInfo viewer(String id) => GravixParticipantInfo(identity: id, rawRole: 'viewer');
  GravixParticipantInfo mixerByRole(String id) => GravixParticipantInfo(identity: id, rawRole: 'mixer');
  GravixParticipantInfo mixerByFlag(String id) => GravixParticipantInfo(identity: id, rawRole: 'host', mixed: true);
  GravixParticipantInfo linked(String id) => GravixParticipantInfo(identity: id, rawRole: 'host', linkedFrom: 'room-2');

  group('default view', () {
    const view = GravixRoomView();

    test('hides mixers, by role or by flag', () {
      expect(view.isVisible(mixerByRole('m1')), isFalse);
      expect(view.isVisible(mixerByFlag('m2')), isFalse);
    });

    test('hides linked participants', () {
      expect(view.isVisible(linked('l1')), isFalse);
    });

    test('shows real participants', () {
      expect(view.isVisible(person('p1')), isTrue);
      expect(view.isVisible(viewer('v1')), isTrue);
    });

    test('shows a participant with no gravix attributes at all', () {
      expect(view.isVisible(const GravixParticipantInfo(identity: 'plain')), isTrue);
    });
  });

  test('showAll hides nothing', () {
    const view = GravixRoomView.showAll;

    expect(view.isVisible(mixerByRole('m1')), isTrue);
    expect(view.isVisible(linked('l1')), isTrue);
  });

  group('configuration', () {
    test('mixers and linked can be hidden independently', () {
      const noMixers = GravixRoomView(hideMixers: true, hideLinked: false);
      expect(noMixers.isVisible(mixerByRole('m')), isFalse);
      expect(noMixers.isVisible(linked('l')), isTrue);

      const noLinked = GravixRoomView(hideMixers: false, hideLinked: true);
      expect(noLinked.isVisible(mixerByRole('m')), isTrue);
      expect(noLinked.isVisible(linked('l')), isFalse);
    });

    test('extra roles can be hidden', () {
      const view = GravixRoomView(hideRoles: {GravixRole.viewer});
      expect(view.isVisible(viewer('v')), isFalse);
      expect(view.isVisible(person('p')), isTrue);
    });

    test('specific identities can be hidden whatever their attributes say', () {
      const view = GravixRoomView(hideIdentities: {'bot-1'});
      expect(view.isVisible(person('bot-1')), isFalse);
      expect(view.isVisible(person('bot-2')), isTrue);
    });

    test('copyWith keeps the untouched fields', () {
      const base = GravixRoomView(hideRoles: {GravixRole.viewer});
      final changed = base.copyWith(hideLinked: false);
      expect(changed.hideLinked, isFalse);
      expect(changed.hideMixers, isTrue);
      expect(changed.hideRoles, {GravixRole.viewer});
    });
  });

  group('filter', () {
    const view = GravixRoomView();

    test('keeps order and drops only the plumbing', () {
      final items = [person('a'), mixerByRole('mix'), viewer('b'), linked('l'), person('c')];

      final visible = view.filter(items, (i) => i);

      expect(visible.map((i) => i.identity), ['a', 'b', 'c']);
    });

    test('an all-visible list is returned intact', () {
      final items = [person('a'), viewer('b')];
      expect(view.filter(items, (i) => i).map((i) => i.identity), ['a', 'b']);
    });

    test('an all-hidden list returns empty rather than throwing', () {
      expect(view.filter([mixerByRole('m'), linked('l')], (i) => i), isEmpty);
    });
  });
}
