// Copyright 2024 Gravity Compile
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:flutter/foundation.dart';

import '../rtc_core/gravix_client.dart' show Participant, RemoteParticipant, Room;
import 'gravix_participant_attributes.dart';

/// A filter over the participant list for UI that should not show the
/// plumbing.
///
/// In a large room the participant list contains entries that are not people
/// in the room: a server-side mixer publishing a combined stream, and
/// participants forwarded in from a linked room. Both are real participants
/// and both must stay subscribed — dropping them would drop the audio — but
/// showing them in a seat grid or a viewer count is wrong.
///
/// This is a **view**, not a policy: it filters lists you hand it and changes
/// nothing about subscriptions, publishing, or the transport. Nothing in the
/// SDK applies it for you — build one and use it where you render.
///
/// ```dart
/// const view = GravixRoomView();
/// final people = view.participants(room);
/// final count  = view.visibleCount(room);
/// ```
@immutable
class GravixRoomView {
  const GravixRoomView({
    this.hideMixers = true,
    this.hideLinked = true,
    this.hideRoles = const <GravixRole>{},
    this.hideIdentities = const <String>{},
  });

  /// Show everything — the identity filter, useful as a baseline or to turn
  /// the view off from a setting without branching at every call site.
  static const GravixRoomView showAll = GravixRoomView(hideMixers: false, hideLinked: false);

  /// Hide participants whose media is a server-side mix (`gravix.role=mixer`
  /// or `gravix.mixed=true`).
  final bool hideMixers;

  /// Hide participants forwarded in from another room (`gravix.linked_from`).
  final bool hideLinked;

  /// Additional roles to hide.
  final Set<GravixRole> hideRoles;

  /// Specific identities to hide, whatever their attributes say.
  final Set<String> hideIdentities;

  /// Whether a participant with these attributes should appear in UI lists.
  bool isVisible(GravixParticipantInfo info) {
    if (hideIdentities.contains(info.identity)) return false;
    if (hideMixers && info.isMixer) return false;
    if (hideLinked && info.isLinked) return false;
    if (hideRoles.contains(info.role)) return false;
    return true;
  }

  /// [isVisible] for a live participant.
  bool showsParticipant(Participant participant) => isVisible(GravixParticipantInfo.of(participant));

  /// Filters any list, given a way to read attributes off its elements — for
  /// UI models that carry their own attribute map rather than a [Participant].
  List<T> filter<T>(Iterable<T> items, GravixParticipantInfo Function(T item) info) =>
      items.where((item) => isVisible(info(item))).toList(growable: false);

  /// The room's remote participants, minus the plumbing.
  List<RemoteParticipant> participants(Room room) =>
      room.remoteParticipants.values.where(showsParticipant).toList(growable: false);

  /// Identities of [participants], for code keyed by uid.
  Set<String> visibleIdentities(Room room) => participants(room).map((p) => p.identity).toSet();

  /// Filters a set of identities you already hold, using the room to look each
  /// one up. An identity no longer in the room is kept: this filter's job is to
  /// hide plumbing, not to garbage-collect stale uids, and silently dropping
  /// unknown ids here would hide real bugs in the caller's own bookkeeping.
  Set<String> filterIdentities(Iterable<String> identities, Room room) {
    final hidden = room.remoteParticipants.values.where((p) => !showsParticipant(p)).map((p) => p.identity).toSet();
    return identities.where((id) => !hidden.contains(id)).toSet();
  }

  /// How many participants the UI should claim are present. Excludes the local
  /// participant, matching [participants].
  int visibleCount(Room room) => participants(room).length;

  /// The mixers and linked participants this view hides — for a diagnostics
  /// panel, or to render them somewhere other than the main list.
  List<RemoteParticipant> hidden(Room room) =>
      room.remoteParticipants.values.where((p) => !showsParticipant(p)).toList(growable: false);

  GravixRoomView copyWith({
    bool? hideMixers,
    bool? hideLinked,
    Set<GravixRole>? hideRoles,
    Set<String>? hideIdentities,
  }) => GravixRoomView(
    hideMixers: hideMixers ?? this.hideMixers,
    hideLinked: hideLinked ?? this.hideLinked,
    hideRoles: hideRoles ?? this.hideRoles,
    hideIdentities: hideIdentities ?? this.hideIdentities,
  );
}
