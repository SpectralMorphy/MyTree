import 'dart:convert';

import '../room_document.dart';

/// Public room binding identity, never an OAuth token or cloud snapshot.
class DiskBinding {
  const DiskBinding({required this.id, required this.ownerActor});

  final String id;
  final String ownerActor;

  /// First connect in (clock, id) order wins until an exact-ID disconnect.
  /// Replaying the full operation set, rather than arrival order, makes late
  /// connects/disconnects deterministic. Ignored claims remain in the journal.
  /// Command authorization belongs to callers, not this trusted-room projection.
  static DiskBinding? project(Iterable<RoomEdit> history) {
    final edits =
        history
            .where((edit) => edit.kind == RoomEditKind.diskConnection)
            .toList()
          ..sort((left, right) => left.compareTo(right));
    DiskBinding? active;
    final seen = <String>{};
    for (final edit in edits) {
      if (!seen.add(edit.id)) continue;
      if (!isValidDiskConnection(edit.text)) {
        throw const FormatException('Invalid Disk connection metadata');
      }
      final payload = jsonDecode(edit.text) as Map<String, dynamic>;
      switch (payload['action']) {
        case 'connect':
          active ??= DiskBinding(id: edit.id, ownerActor: edit.author);
        case 'disconnect':
          if (payload['bindingId'] == active?.id) active = null;
      }
    }
    return active;
  }
}
