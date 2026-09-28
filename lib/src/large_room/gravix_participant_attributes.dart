// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/foundation.dart';

import '../rtc_core/gravix_client.dart' show Participant;

/// The `gravix.*` participant attribute keys a large room uses.
///
/// These are set server-side on the participant; the SDK only reads them. An
/// attribute the server never sets simply reads as absent, which is why every
/// accessor here has a defined meaning for "missing".
abstract final class GravixAttributeKeys {
  /// What this participant is in the room: `host`, `cohost`, `viewer`,
  /// `mixer`, or anything else the deployment defines.
  static const role = 'gravix.role';

  /// `'true'` when this participant's media is a server-side mix of other
  /// participants rather than a real person's capture.
  static const mixed = 'gravix.mixed';

  /// The room this participant is being forwarded from, when they are joined
  /// in from another room rather than present in this one.
  static const linkedFrom = 'gravix.linked_from';

  /// Where this participant's stream is being broadcast, when it is.
  static const broadcastUrl = 'gravix.broadcast_url';
}

/// Roles the SDK recognises. Anything else is [GravixRole.other], with the raw
/// string still available on [GravixParticipantInfo.rawRole] — a deployment is
/// free to define its own and the SDK will not swallow it.
enum GravixRole { host, cohost, viewer, mixer, other, unknown }

/// A typed read of one participant's `gravix.*` attributes.
///
/// Purely a view over [Participant.attributes]: constructing one changes
/// nothing and subscribes to nothing. Rebuild it when
/// `ParticipantAttributesChanged` fires.
@immutable
class GravixParticipantInfo {
  const GravixParticipantInfo({
    required this.identity,
    this.rawRole,
    this.mixed = false,
    this.linkedFrom,
    this.broadcastUrl,
  });

  /// Reads the attributes off a live participant.
  factory GravixParticipantInfo.of(Participant participant) =>
      GravixParticipantInfo.fromAttributes(participant.identity, participant.attributes);

  factory GravixParticipantInfo.fromAttributes(String identity, Map<String, String> attributes) {
    String? nonEmpty(String key) {
      final value = attributes[key];
      return (value == null || value.isEmpty) ? null : value;
    }

    return GravixParticipantInfo(
      identity: identity,
      rawRole: nonEmpty(GravixAttributeKeys.role),
      // Tolerant of the shapes a server might send for a boolean.
      mixed: switch (attributes[GravixAttributeKeys.mixed]?.toLowerCase()) {
        'true' || '1' || 'yes' => true,
        _ => false,
      },
      linkedFrom: nonEmpty(GravixAttributeKeys.linkedFrom),
      broadcastUrl: nonEmpty(GravixAttributeKeys.broadcastUrl),
    );
  }

  final String identity;

  /// `gravix.role` verbatim, or null when unset.
  final String? rawRole;

  /// `gravix.mixed`.
  final bool mixed;

  /// `gravix.linked_from`.
  final String? linkedFrom;

  /// `gravix.broadcast_url`.
  final String? broadcastUrl;

  /// [rawRole] mapped onto [GravixRole]. Unset reads as [GravixRole.unknown];
  /// a role the SDK does not know reads as [GravixRole.other].
  GravixRole get role => switch (rawRole?.toLowerCase()) {
    null => GravixRole.unknown,
    'host' => GravixRole.host,
    'cohost' || 'co-host' => GravixRole.cohost,
    'viewer' || 'listener' => GravixRole.viewer,
    'mixer' => GravixRole.mixer,
    _ => GravixRole.other,
  };

  /// A server-side mixer rather than a person: either the role says so or the
  /// media is a mix.
  bool get isMixer => role == GravixRole.mixer || mixed;

  /// Forwarded in from another room.
  bool get isLinked => linkedFrom != null;

  /// Being broadcast somewhere.
  bool get isBroadcasting => broadcastUrl != null;

  /// Can publish, by role. [GravixRole.unknown] is treated as not a publisher:
  /// a room that does not set roles gets no behaviour from this getter, which
  /// is the point of the whole feature being opt-in.
  bool get canPublishByRole => role == GravixRole.host || role == GravixRole.cohost;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GravixParticipantInfo &&
          other.identity == identity &&
          other.rawRole == rawRole &&
          other.mixed == mixed &&
          other.linkedFrom == linkedFrom &&
          other.broadcastUrl == broadcastUrl;

  @override
  int get hashCode => Object.hash(identity, rawRole, mixed, linkedFrom, broadcastUrl);

  @override
  String toString() =>
      'GravixParticipantInfo($identity, role=${rawRole ?? "-"}, mixed=$mixed, '
      'linkedFrom=${linkedFrom ?? "-"}, broadcastUrl=${broadcastUrl ?? "-"})';
}
