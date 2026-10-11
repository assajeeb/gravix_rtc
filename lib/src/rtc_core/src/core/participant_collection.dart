// Copyright 2024 LiveKit, Inc.
// Modifications Copyright 2024-2026 Gravity Compile
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

import 'dart:collection';

import '../participant/participant.dart';

/// Small helper to keep participant lookups by identity and sid in sync.
class ParticipantCollection<T extends Participant> extends IterableBase<T> {
  final Map<String, T> _byIdentity = {};
  final Map<String, T> _bySid = {};

  // Read-only views of the collections
  UnmodifiableMapView<String, T> get byIdentity => UnmodifiableMapView(_byIdentity);
  UnmodifiableMapView<String, T> get bySid => UnmodifiableMapView(_bySid);

  // Update methods
  void set(T participant) {
    _byIdentity[participant.identity] = participant;
    _bySid[participant.sid] = participant;
  }

  /// GRAVIX (0.4.15): [participant] is kept across a full rejoin and may have a
  /// new sid: drop its old sid key, then index it again.
  void rekey(T participant, String oldSid) {
    if (identical(_bySid[oldSid], participant)) _bySid.remove(oldSid);
    set(participant);
  }

  // Contains methods
  bool containsIdentity(String identity) => _byIdentity.containsKey(identity);
  bool containsSid(String sid) => _bySid.containsKey(sid);

  void clear() {
    _byIdentity.clear();
    _bySid.clear();
  }

  T? removeByIdentity(String identity) {
    final participant = _byIdentity.remove(identity);
    if (participant == null) return null;
    return _bySid.remove(participant.sid);
  }

  @override
  Iterator<T> get iterator => _byIdentity.values.iterator;
}
