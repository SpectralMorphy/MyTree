import 'dart:async';
import 'dart:convert';

import '../room_document.dart';
import '../room_identity.dart';
import 'storage_codec.dart';

/// Local, plain-JSON room persistence; no encryption, cloud storage, or CRDT.
///
/// A missing client ID, last room, membership, or history is normal on first
/// use. Existing malformed data and persistence failures throw, never fall
/// back to an empty history or an ephemeral store.
abstract class RoomStore {
  final _historyQueues = <String, Future<void>>{};
  final _historyZoneKey = Object();

  /// Only stores sharing durable data between same-origin browser tabs may
  /// delegate networking to a local tab. Native and custom stores opt out.
  bool get sharedAcrossTabs => false;

  Future<String> loadClientId();
  Future<String?> loadLastRoom();

  /// Persist membership first, then make this the last room. Exiting the UI
  /// does not remove membership or clear the last room.
  Future<void> saveMembership(String roomId);
  Future<bool> hasMembership(String roomId);

  Future<List<Map<String, dynamic>>> loadHistory(String roomId);

  /// Local-only plain-JSON credentials: exactly {v: 1, bindingId, token}.
  /// Never part of history, exports, or tab/network message payloads. An old
  /// binding's credentials may be retained while its final writes are flushed.
  /// Binding-scoped reads use the archive, falling back to a matching legacy
  /// latest value. Unscoped reads retain the latest-value compatibility API.
  /// Missing data returns null; malformed data and unsupported stores throw.
  Future<Map<String, dynamic>?> loadDiskCredentials(
    String roomId, {
    String? bindingId,
  }) => Future.sync(() {
    requireDiskCredentialsRoomId(roomId);
    requireDiskCredentialsBindingId(bindingId);
    throw UnsupportedError('This store cannot persist Disk credentials');
  });

  /// Snapshot before asynchronous work. Save by payload binding ID before
  /// updating the latest value, preserving other concurrently staged bindings.
  /// If supplied, bindingId must match a nonnull payload. Null with bindingId
  /// removes only that binding and a matching latest value; unscoped null clears
  /// all credentials for the room, never history or membership.
  /// Custom stores must opt in to persistence, never silently keep an ephemeral
  /// token. Implementations must not include credentials in diagnostic errors.
  Future<void> saveDiskCredentials(
    String roomId,
    Map<String, dynamic>? value, {
    String? bindingId,
  }) => Future.sync(() {
    requireDiskCredentialsRoomId(roomId);
    requireDiskCredentialsBindingId(bindingId);
    if (value != null) snapshotDiskCredentials(value, bindingId: bindingId);
    throw UnsupportedError('This store cannot persist Disk credentials');
  });

  /// Local-only anonymous read access: exactly {v: 1, bindingId, publicUrl}.
  /// Separate from editor credentials and history, bound to its room's storage
  /// key. Only the current pointer is retained; no binding archive or token.
  /// Missing data returns null; malformed data and unsupported stores throw.
  Future<Map<String, dynamic>?> loadDiskPublicAccess(String roomId) =>
      Future.sync(() {
        requireDiskPublicAccessRoomId(roomId);
        throw UnsupportedError('This store cannot persist Disk public access');
      });

  /// Snapshot before asynchronous work. Null removes only the public pointer,
  /// never credentials, history, or membership. Errors must not echo URLs.
  /// Custom stores must opt in to persistence, never use an ephemeral fallback.
  Future<void> saveDiskPublicAccess(
    String roomId,
    Map<String, dynamic>? value,
  ) => Future.sync(() {
    requireDiskPublicAccessRoomId(roomId);
    if (value != null) snapshotDiskPublicAccess(value);
    throw UnsupportedError('This store cannot persist Disk public access');
  });

  /// Signals history (and optionally credential/public-access) changes from
  /// other browser tabs. Subscribe before loading, then reload on each signal.
  /// No payload is exposed. Native/memory stores do not broadcast.
  Stream<void> watchHistory(String roomId) => const Stream<void>.empty();

  /// Append detached JSON snapshots. IDs must be nonempty strings and are
  /// immutable: identical retries are ignored, conflicting retries throw.
  /// A failed batch may have partially persisted; retrying it is safe.
  /// Sequenced room edits must include their complete author predecessor closure
  /// together with the existing history, validated before any batch write.
  Future<void> appendHistory(
    String roomId,
    List<Map<String, dynamic>> operations,
  );

  /// Atomically allocate author proofs against persisted history, then append
  /// unproven drafts in their supplied order. Draft IDs and core fields are
  /// stable across retries; an already persisted same-core ID reuses its exact
  /// stored record. Returns the full canonical persisted history, including
  /// edits discovered from other writers. A failed call may persist a prefix.
  ///
  /// Unlike a synchronous in-memory append, authoring begins asynchronously.
  /// Custom stores can inherit this in-process lock and their virtual I/O stays
  /// observable (including injected failures). Shared durable stores override
  /// it with their own atomic journal transaction.
  Future<List<Map<String, dynamic>>> appendAuthoredHistory(
    String roomId,
    List<Map<String, dynamic>> drafts,
  ) {
    late List<RoomEdit> edits;
    try {
      requireRoomId(roomId);
      edits = decodeAuthoredDrafts(drafts);
    } catch (error, stackTrace) {
      return Future.error(error, stackTrace);
    }
    return _withHistoryLock(roomId, () async {
      final history = <String, HistoryRecord>{};
      for (final raw in await loadHistory(roomId)) {
        addHistoryRecord(history, HistoryRecord(raw));
      }
      final additions = prepareAuthoredHistory(history, edits);
      for (final record in additions) {
        await appendHistory(roomId, [record.toJson()]);
      }
      final persisted = (await loadHistory(roomId)).map(HistoryRecord.new);
      return orderStoredHistory(
        persisted,
      ).map((record) => record.toJson()).toList();
    });
  }

  // Reentrant only inside this store's active room transaction, allowing the
  // default authored implementation to call virtual Memory/custom-store I/O.
  // A token inherited by a detached future is invalid after the lock releases.
  Future<T> _withHistoryLock<T>(String roomId, FutureOr<T> Function() action) {
    final current = Zone.current[_historyZoneKey] as _HistoryLockToken?;
    if (current != null && current.active && current.roomId == roomId) {
      return Future<T>.sync(action);
    }
    final result = (_historyQueues[roomId] ?? Future<void>.value()).then((_) {
      final token = _HistoryLockToken(roomId);
      return runZoned(
        () => Future<T>.sync(action).whenComplete(() => token.active = false),
        zoneValues: {_historyZoneKey: token},
      );
    });
    final released = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _historyQueues[roomId] = released;
    unawaited(
      released.then((_) {
        if (identical(_historyQueues[roomId], released)) {
          _historyQueues.remove(roomId);
        }
      }),
    );
    return result;
  }

  /// Wait for queued native writes. Callers must also handle each write's
  /// returned future; flush does not replay errors from already failed writes.
  /// An immediate OS kill before a native write completes can lose that edit.
  Future<void> flush() => Future<void>.value();
}

class _HistoryLockToken {
  _HistoryLockToken(this.roomId);

  final String roomId;
  bool active = true;
}

/// Preserve the generic JSON history contract for older callers and fixtures.
/// Once author proofs occur, the whole snapshot must be valid room edits with
/// complete, nonforking author prefixes. Never rewrite the stored JSON records.
List<HistoryRecord> orderStoredHistory(Iterable<HistoryRecord> history) {
  final records = history.toList();
  final json = records.map((record) => record.toJson()).toList();
  if (!json.any((raw) => raw.containsKey('authorSequence'))) return records;
  final ordered = validateAuthorHistory(decodeRoomHistory(json));
  final byId = {for (final record in records) record.id: record};
  return ordered.map((edit) => byId[edit.id]!).toList();
}

/// Validate immutable IDs and the full resulting prefix before the first write,
/// returning only new records in predecessor-first order.
List<HistoryRecord> newValidatedHistoryRecords(
  Map<String, HistoryRecord> existing,
  List<HistoryRecord> operations,
) {
  final additions = newHistoryRecords(existing, operations);
  final ids = additions.map((record) => record.id).toSet();
  return orderStoredHistory([
    ...existing.values,
    ...additions,
  ]).where((record) => ids.contains(record.id)).toList();
}

/// Snapshot and strictly decode drafts before they enter an asynchronous queue.
/// Only one author may allocate within an authored transaction.
List<RoomEdit> decodeAuthoredDrafts(List<Map<String, dynamic>> drafts) {
  final edits = decodeRoomHistory(
    drafts.map(HistoryRecord.new).map((record) => record.toJson()).toList(),
  );
  String? author;
  for (final edit in edits) {
    if (edit.authorSequence != null) {
      throw const FormatException(
        'Authored drafts must not contain author proofs',
      );
    }
    author ??= edit.author;
    if (edit.author != author) {
      throw const FormatException('Authored drafts must have one author');
    }
  }
  return edits;
}

/// Allocate against one locked, complete snapshot. Existing IDs keep their exact
/// stored representation; conflicting core fields fail before anything writes.
List<HistoryRecord> prepareAuthoredHistory(
  Map<String, HistoryRecord> existing,
  List<RoomEdit> drafts,
) {
  final persisted = validateAuthorHistory(
    decodeRoomHistory(
      existing.values.map((record) => record.toJson()).toList(),
    ),
  );
  final working = {for (final edit in persisted) edit.id: edit};
  final additions = <HistoryRecord>[];
  for (final draft in drafts) {
    final edit = sequenceAuthoredEdit(draft, working.values);
    if (!working.containsKey(edit.id)) {
      additions.add(HistoryRecord(edit.toJson()));
      working[edit.id] = edit;
    }
  }
  // Author-base metadata is allocated only here, after the command boundary's
  // size guard. Bound the full new canonical journal below the current 8 MiB
  // transfer ceiling, leaving 32 KiB for its wire envelope, without coupling
  // generic legacy persistence to a networking import or retroactive size rule.
  const maxAuthoredHistoryBytes = 8 * 1024 * 1024 - 32 * 1024;
  if (additions.isNotEmpty &&
      utf8
              .encode(
                jsonEncode([
                  ...existing.values.map((record) => record.toJson()),
                  ...additions.map((record) => record.toJson()),
                ]),
              )
              .length >
          maxAuthoredHistoryBytes) {
    throw const FormatException('Authored history exceeds the transfer budget');
  }
  return additions;
}

/// Credentials belong to real application room identities, not generic legacy
/// history fixtures. Do not trim/repair malformed IDs into a different room.
void requireDiskCredentialsRoomId(String roomId) {
  if (!isValidRoomId(roomId)) {
    throw ArgumentError('Invalid room ID for Disk credentials');
  }
}

void requireDiskCredentialsBindingId(String? bindingId) {
  if (bindingId != null && !isValidRoomActor(bindingId)) {
    throw ArgumentError('Invalid binding ID for Disk credentials');
  }
}

/// Validate and detach the one supported local credential envelope. Keep this
/// codec at the storage boundary, independent of cloud/network/UI dependencies.
Map<String, dynamic> snapshotDiskCredentials(
  Object? value, {
  String? bindingId,
}) {
  if (value is! Map<String, dynamic> ||
      value.length != 3 ||
      value['v'] is! int ||
      value['v'] != 1 ||
      !isValidRoomActor(value['bindingId']) ||
      (bindingId != null && value['bindingId'] != bindingId)) {
    throw const FormatException('Invalid stored Disk credentials');
  }
  final token = value['token'];
  if (token is! String ||
      token.isEmpty ||
      token.length > 4096 ||
      token.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
    throw const FormatException('Invalid stored Disk credentials');
  }
  return {'v': 1, 'bindingId': value['bindingId'], 'token': token};
}

/// JSON parser errors can quote source text; never expose them for secrets.
Map<String, dynamic> decodeDiskCredentials(
  String encoded, {
  String? bindingId,
}) {
  try {
    final snapshot = snapshotDiskCredentials(
      jsonDecode(encoded),
      bindingId: bindingId,
    );
    // The supported object is flat. A decoder would otherwise silently accept
    // duplicate keys, potentially retaining secret bytes outside the snapshot.
    final strings = RegExp(r'("(?:[^"\\]|\\.)*")(\s*:)?');
    if (strings.allMatches(encoded).where((match) => match[2] != null).length !=
        snapshot.length) {
      throw const FormatException('Invalid stored Disk credentials');
    }
    return snapshot;
  } on FormatException {
    throw const FormatException('Invalid stored Disk credentials');
  }
}

/// Nonpersistent implementation for tests, with the same snapshot/ID rules.
class MemoryRoomStore extends RoomStore {
  String? _clientId;
  String? _lastRoom;
  final _memberships = <String>{};
  final _histories = <String, Map<String, HistoryRecord>>{};
  final _diskCredentials = <String, Map<String, dynamic>>{};
  final _diskCredentialsByBinding =
      <String, Map<String, Map<String, dynamic>>>{};
  final _diskPublicAccess = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>?> loadDiskPublicAccess(String roomId) =>
      Future.sync(() {
        requireDiskPublicAccessRoomId(roomId);
        final value = _diskPublicAccess[roomId];
        return value == null ? null : snapshotDiskPublicAccess(value);
      });

  @override
  Future<void> saveDiskPublicAccess(
    String roomId,
    Map<String, dynamic>? value,
  ) => Future.sync(() {
    requireDiskPublicAccessRoomId(roomId);
    if (value == null) {
      _diskPublicAccess.remove(roomId);
    } else {
      _diskPublicAccess[roomId] = snapshotDiskPublicAccess(value);
    }
  });

  @override
  Future<Map<String, dynamic>?> loadDiskCredentials(
    String roomId, {
    String? bindingId,
  }) => Future.sync(() {
    requireDiskCredentialsRoomId(roomId);
    requireDiskCredentialsBindingId(bindingId);
    final latest = _diskCredentials[roomId];
    final value = bindingId == null
        ? latest
        : _diskCredentialsByBinding[roomId]?[bindingId] ??
              (latest?['bindingId'] == bindingId ? latest : null);
    return value == null
        ? null
        : snapshotDiskCredentials(value, bindingId: bindingId);
  });

  @override
  Future<void> saveDiskCredentials(
    String roomId,
    Map<String, dynamic>? value, {
    String? bindingId,
  }) => Future.sync(() {
    requireDiskCredentialsRoomId(roomId);
    requireDiskCredentialsBindingId(bindingId);
    if (value != null) {
      final snapshot = snapshotDiskCredentials(value, bindingId: bindingId);
      (_diskCredentialsByBinding[roomId] ??= {})[snapshot['bindingId']
              as String] =
          snapshot;
      _diskCredentials[roomId] = snapshot;
    } else if (bindingId == null) {
      _diskCredentialsByBinding.remove(roomId);
      _diskCredentials.remove(roomId);
    } else {
      _diskCredentialsByBinding[roomId]?.remove(bindingId);
      if (_diskCredentials[roomId]?['bindingId'] == bindingId) {
        _diskCredentials.remove(roomId);
      }
    }
  });

  @override
  Future<String> loadClientId() =>
      Future.sync(() => _clientId ??= createRoomId());

  @override
  Future<String?> loadLastRoom() => Future.value(_lastRoom);

  @override
  Future<void> saveMembership(String roomId) => Future.sync(() {
    requireRoomId(roomId);
    _memberships.add(roomId);
    _lastRoom = roomId;
  });

  @override
  Future<bool> hasMembership(String roomId) => Future.sync(() {
    requireRoomId(roomId);
    return _memberships.contains(roomId);
  });

  @override
  Future<List<Map<String, dynamic>>> loadHistory(String roomId) =>
      _withHistoryLock(roomId, () {
        requireRoomId(roomId);
        return orderStoredHistory(
          _histories[roomId]?.values ?? [],
        ).map((record) => record.toJson()).toList();
      });

  @override
  Future<void> appendHistory(
    String roomId,
    List<Map<String, dynamic>> operations,
  ) {
    late List<HistoryRecord> records;
    try {
      requireRoomId(roomId);
      records = operations.map(HistoryRecord.new).toList();
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    return _withHistoryLock(roomId, () {
      final history = _histories[roomId] ?? <String, HistoryRecord>{};
      final additions = newValidatedHistoryRecords(history, records);
      for (final record in additions) {
        history[record.id] = record;
      }
      _histories[roomId] = history;
    });
  }
}
