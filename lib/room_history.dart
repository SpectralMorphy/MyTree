import 'dart:async';

import 'room_document.dart';
import 'room_identity.dart';
import 'storage/room_store.dart';

/// The local journal and optimistic LWW model, independent of network/UI.
///
/// Optimistic drafts appear synchronously; atomic authored appends may await a
/// cross-tab lock. Only canonical, prefix-complete durable edits may leave this
/// object for synchronization. Watching storage never establishes membership.
class RoomHistory {
  RoomHistory({
    required this.roomId,
    required this.actorId,
    required this.store,
    required bool existingMember,
    void Function()? onChanged,
    void Function(String)? onLog,
    void Function(List<RoomEdit>)? onDurableEdits,
    void Function(Future<void> Function())? serializeRefresh,
  }) : _loaded = !existingMember,
       _watchEnabled = existingMember,
       _onChanged = onChanged,
       _onLog = onLog,
       _onDurableEdits = onDurableEdits,
       _serializeRefresh = serializeRefresh {
    if (!isValidRoomId(roomId)) {
      throw ArgumentError.value(
        roomId,
        'roomId',
        'Expected 32 lowercase hex digits',
      );
    }
    if (!isValidRoomActor(actorId)) {
      throw ArgumentError.value(
        actorId,
        'actorId',
        'Expected a nonempty identity',
      );
    }
  }

  final String roomId;
  final String actorId;
  final RoomStore store;
  final void Function()? _onChanged;
  final void Function(String)? _onLog;
  final void Function(List<RoomEdit>)? _onDurableEdits;

  // A session supplies its remote-message queue so storage refreshes cannot
  // race admission/acknowledgment. Standalone histories use their own queue.
  final void Function(Future<void> Function())? _serializeRefresh;
  Future<void> _refreshes = Future<void>.value();
  final _document = RoomDocument();
  final _known = <String, RoomEdit>{};
  final _durable = <String>{};
  List<RoomEdit> _durableSnapshot = const [];
  final _unsaved = <String, RoomEdit>{};
  final _drafts = <String, RoomEdit>{};
  final _writes = <String, Future<bool>>{};
  Timer? _refreshTimer;
  StreamSubscription<void>? _subscription;
  int _savingCount = 0;
  bool _loaded;
  bool _watchEnabled;
  bool _disposed = false;
  bool _flushFailed = false;
  String? _error;

  bool get loaded => _loaded;
  String get text => _document.text;
  String get roomName => _document.roomName;
  Map<String, String> get participantNames => _document.participantNames;
  Map<String, RoomRole> get participantRoles => _document.participantRoles;
  RoomRole roleFor(String actor) => _document.roleFor(actor);
  List<RoomEdit> get changes => List.unmodifiable(_document.history);
  int get historyLength => _document.historyLength;
  int get durableLength => _durable.length;
  bool get saving => _savingCount != 0;
  int get savingCount => _savingCount;
  String? get error => _error;
  List<RoomEdit> get durableHistory => _durableSnapshot;

  /// Includes pending/failed appends for immutable-ID checks, never outbound
  /// synchronization. The returned snapshot cannot alter the journal.
  List<RoomEdit> get knownEdits => List.unmodifiable(_known.values);

  Future<void> load({List<RoomEdit>? initialHistory}) async {
    if (_disposed) return;
    try {
      var edits = initialHistory;
      if (edits == null) {
        final history = await store.loadHistory(roomId);
        if (_disposed) return;
        edits = decodeRoomHistory(history);
      }
      _acceptStored(validateAuthorHistory(edits));
      _loaded = true;
      if (_unsaved.isEmpty && !_flushFailed) _error = null;
      _watchHistory();
      _changed();
    } catch (error) {
      if (_disposed) return;
      _error = 'Не удалось загрузить историю: $error';
      _onLog?.call(_error!);
      _changed();
    }
  }

  /// Called only after the coordinator has accepted a fresh member.
  void watchAcceptedHistory() {
    if (_disposed) return;
    _watchEnabled = true;
    _watchHistory();
  }

  void _watchHistory() {
    if (_disposed || !_watchEnabled || !_loaded || _subscription != null) {
      return;
    }
    try {
      _subscription = store
          .watchHistory(roomId)
          .listen(
            (_) => _scheduleRefresh(),
            onError: (Object error) {
              if (_disposed) return;
              _error = 'Не удалось отслеживать историю: $error';
              _onLog?.call(_error!);
              _changed();
            },
          );
      // Close the read/subscribe gap, including edits persisted before a fresh
      // member completed its welcome. No event is evidence of membership.
      _scheduleRefresh();
    } catch (error) {
      if (_disposed) return;
      _error = 'Не удалось отслеживать историю: $error';
      _onLog?.call(_error!);
      _changed();
    }
  }

  void _scheduleRefresh() {
    if (_disposed || !_watchEnabled || !_loaded) return;
    // Coalesce a burst without postponing forever under continuous events.
    _refreshTimer ??= Timer(const Duration(milliseconds: 35), () {
      _refreshTimer = null;
      if (_disposed || !_watchEnabled) return;
      final serialize = _serializeRefresh;
      if (serialize != null) {
        serialize(_refreshStoredHistory);
      } else {
        _refreshes = _refreshes.then((_) => _refreshStoredHistory());
      }
    });
  }

  /// The session serializes this with remote admission and local tab proofs.
  /// It reads durable storage only; a tab beacon never supplies journal edits.
  Future<void> refresh() => _refreshStoredHistory();

  Future<void> _refreshStoredHistory() async {
    if (_disposed || !_watchEnabled || !_loaded) return;
    try {
      final history = await store.loadHistory(roomId);
      if (_disposed || !_watchEnabled) return;
      final edits = validateAuthorHistory(decodeRoomHistory(history));
      // Already durable: never append these again or replace a snapshot.
      final additions = _acceptStored(edits);
      if (_unsaved.isEmpty && !_flushFailed) _error = null;
      if (additions.isNotEmpty) _onDurableEdits?.call(additions);
      _changed();
    } catch (error) {
      if (_disposed) return;
      _error = 'Не удалось обновить сохранённую историю: $error';
      _onLog?.call(_error!);
      _changed();
    }
  }

  void _checkImmutable(List<RoomEdit> edits) {
    final batch = <String, RoomEdit>{};
    for (final edit in edits) {
      final duplicate = batch[edit.id];
      final known = _known[edit.id];
      final finalizesDraft =
          _drafts.containsKey(edit.id) &&
          known != null &&
          known.sameCoreAs(edit) &&
          edit.authorSequence != null;
      if ((duplicate != null && !duplicate.sameContentAs(edit)) ||
          (known != null && !known.sameContentAs(edit) && !finalizesDraft)) {
        throw const FormatException(
          'Попытка заменить уже сохранённое изменение',
        );
      }
      batch[edit.id] = edit;
    }
  }

  List<RoomEdit> _acceptStored(List<RoomEdit> edits) {
    _checkImmutable(edits);
    final complete = validateAuthorHistory([...durableHistory, ...edits]);
    final additions = <RoomEdit>[];
    for (final edit in complete) {
      if (_drafts.containsKey(edit.id)) {
        if (edit.authorSequence == null) {
          throw const FormatException(
            'Локальная запись не получила номер автора',
          );
        }
      }
    }
    for (final edit in complete) {
      if (!_durable.contains(edit.id)) additions.add(edit);
      if (_drafts.remove(edit.id) != null) {
        _document.finalizeAuthored(edit);
      } else {
        _document.merge([edit]);
      }
      _known[edit.id] = edit;
      _durable.add(edit.id);
      _unsaved.remove(edit.id);
    }
    _durableSnapshot = List.unmodifiable(complete);
    return additions;
  }

  /// Appends a fully decoded remote history; null means saving failed. The
  /// returned additions were not durable before this merge, for host relaying.
  /// Checks every immutable ID before starting even the first append.
  Future<List<RoomEdit>?> merge(List<RoomEdit> edits) {
    if (edits.isEmpty) return Future.value(<RoomEdit>[]);
    final before = Set<String>.of(_durable);
    return _persist(edits).then(
      (ok) => ok
          ? durableHistory.where((edit) => !before.contains(edit.id)).toList()
          : null,
    );
  }

  /// Optimistic display is immediate. The authored append starts before this
  /// returns; its canonical proof is returned only after the writer lock/save.
  Future<RoomEdit?> edit(String value) =>
      _editValue(value, RoomEditKind.text, text);

  Future<RoomEdit?> setParticipantName(String value) => _editValue(
    value,
    RoomEditKind.participantName,
    participantNames[actorId],
  );

  Future<RoomEdit?> renameRoom(String value) =>
      _editValue(value, RoomEditKind.roomName, roomName);

  /// Tree payloads use the same stable-core, atomic authored append path.
  Future<RoomEdit?> appendTreeOperation(String payload) =>
      _editValue(payload, RoomEditKind.tree, null);

  /// Cloud metadata uses the same durable authored journal, never credentials.
  Future<RoomEdit?> appendDiskConnection(String payload, {String? id}) =>
      _editValue(payload, RoomEditKind.diskConnection, null, id: id);

  /// Records initial roles and promotions, never downgrades an explicit editor.
  /// Like names, the local projection is optimistic; only the returned durable
  /// edit (or durableHistory after retry) may be used for synchronization.
  Future<RoomEdit?> setParticipantRole(String targetActor, RoomRole role) {
    final previous = participantRoles[targetActor];
    if (previous == RoomRole.editor) return Future<RoomEdit?>.value();
    return _editValue(
      role.name,
      RoomEditKind.participantRole,
      previous?.name,
      targetActor: targetActor,
    );
  }

  Future<RoomEdit?> _editValue(
    String value,
    RoomEditKind kind,
    String? previous, {
    String? targetActor,
    String? id,
  }) {
    if (_disposed) return Future<RoomEdit?>.value();
    if (!_loaded) {
      _error = 'Сначала нужно прочитать сохранённую историю';
      _changed();
      return Future<RoomEdit?>.value();
    }
    if (value == previous) return Future<RoomEdit?>.value();
    final edit = _document.createEdit(
      actorId,
      value,
      kind: kind,
      targetActor: targetActor,
      id: id,
    );
    _document.merge([edit]);
    _known[edit.id] = edit;
    _unsaved[edit.id] = edit;
    _drafts[edit.id] = edit;
    final saved = _persistDrafts(returningEditId: edit.id);
    _changed();
    return saved.then((ok) => ok ? _known[edit.id] : null);
  }

  Future<bool> _persistDrafts({String? returningEditId}) {
    if (_drafts.isEmpty) return Future.value(true);
    final drafts = _drafts.values.toList();
    _savingCount++;
    Future<List<Map<String, dynamic>>> append;
    try {
      // Invoke immediately, but allocating the author frontier and committing it
      // happens together inside the store's room-scoped writer lock.
      append = store.appendAuthoredHistory(
        roomId,
        drafts.map((edit) => edit.toJson()).toList(),
      );
    } catch (error, stack) {
      append = Future.error(error, stack);
    }
    late final Future<bool> result;
    result = append
        .then((history) {
          final stored = validateAuthorHistory(decodeRoomHistory(history));
          final ids = stored.map((edit) => edit.id).toSet();
          if (drafts.any((edit) => !ids.contains(edit.id))) {
            throw const FormatException(
              'Сохранённый префикс не содержит все изменения',
            );
          }
          final additions = _acceptStored(
            stored,
          ).where((edit) => edit.id != returningEditId).toList();
          if (!_disposed) {
            if (_unsaved.isEmpty && !_flushFailed) _error = null;
            // The caller publishes its returned edit. Only retry/catch-up
            // additions need this callback, avoiding a duplicate normal send.
            if (additions.isNotEmpty) _onDurableEdits?.call(additions);
            _changed();
          }
          return true;
        })
        .catchError((Object error, StackTrace stack) {
          if (!_disposed) {
            _error = 'Изменения ещё не сохранены: $error';
            _onLog?.call(_error!);
            _changed();
          }
          return false;
        })
        .whenComplete(() {
          for (final edit in drafts) {
            if (identical(_writes[edit.id], result)) _writes.remove(edit.id);
          }
          _savingCount--;
          _changed();
        });
    for (final edit in drafts) {
      _writes[edit.id] = result;
    }
    _changed();
    return result;
  }

  Future<bool> _persist(List<RoomEdit> edits) {
    _checkImmutable(edits);
    final ordered = validateAuthorHistory([...durableHistory, ...edits]);
    final requested = edits.map((edit) => edit.id).toSet();
    edits = ordered.where((edit) => requested.contains(edit.id)).toList();
    final newEdits = <String, RoomEdit>{};
    final pending = <Future<bool>>{};
    for (final edit in edits) {
      if (_durable.contains(edit.id)) continue;
      final write = _writes[edit.id];
      if (write != null) {
        pending.add(write);
      } else {
        newEdits[edit.id] = edit;
      }
    }
    if (newEdits.isNotEmpty) pending.add(_write(newEdits.values.toList()));
    if (pending.isEmpty) return Future<bool>.value(true);
    return Future.wait(pending).then((results) => results.every((ok) => ok));
  }

  Future<bool> _write(List<RoomEdit> edits) {
    for (final edit in edits) {
      if (!_drafts.containsKey(edit.id)) {
        _known[edit.id] = edit;
        _unsaved[edit.id] = edit;
      }
    }
    _savingCount++;
    Future<void> append;
    try {
      // Start the remote append now; the store serializes complete-prefix
      // validation and writing with other tabs' authored and incoming batches.
      append = store.appendHistory(
        roomId,
        edits.map((edit) => edit.toJson()).toList(),
      );
    } catch (error, stack) {
      append = Future<void>.error(error, stack);
    }
    late final Future<bool> result;
    result = append
        .then(
          (_) {
            if (!_disposed) {
              _acceptStored(edits);
              if (_unsaved.isEmpty && !_flushFailed) _error = null;
              _changed();
            }
            return true;
          },
          onError: (Object error, StackTrace stack) {
            if (!_disposed) {
              _error = 'Изменения ещё не сохранены: $error';
              _onLog?.call(_error!);
              _changed();
            }
            return false;
          },
        )
        .whenComplete(() {
          for (final edit in edits) {
            if (identical(_writes[edit.id], result)) _writes.remove(edit.id);
          }
          _savingCount--;
          _changed();
        });
    for (final edit in edits) {
      _writes[edit.id] = result;
    }
    _changed();
    return result;
  }

  /// Admission remains the coordinator's decision. The guard is rechecked
  /// after notifying listeners and before invoking the membership write.
  Future<bool> saveMembership({
    required bool Function() stillAdmissible,
  }) async {
    _savingCount++;
    _changed();
    try {
      if (!stillAdmissible()) return false;
      await store.saveMembership(roomId);
      return true;
    } catch (error) {
      if (!_disposed) {
        _error = 'Не удалось сохранить участие: $error';
        _changed();
      }
      return false;
    } finally {
      _savingCount--;
      _changed();
    }
  }

  /// Retries immutable appends rather than replacing a snapshot. Throws if a
  /// draft remains unsaved: callers must not exit/dispose after a failed flush.
  Future<void> flush() async {
    try {
      do {
        if (!_disposed && _drafts.isNotEmpty) {
          final ok = await _persistDrafts();
          if (!ok) {
            throw StateError(_error ?? 'Не удалось сохранить изменения');
          }
        }
        if (!_disposed && _unsaved.isNotEmpty) {
          final remote = _unsaved.values
              .where((edit) => !_drafts.containsKey(edit.id))
              .toList();
          if (remote.isNotEmpty) {
            final ok = await _persist(remote);
            if (!ok) {
              throw StateError(_error ?? 'Не удалось сохранить изменения');
            }
            if (!_disposed) _onDurableEdits?.call(durableHistory);
          }
        }
        await store.flush();
        // Include an edit made while an earlier append/flush was pending.
      } while (!_disposed && _unsaved.isNotEmpty);
      final recoveredFlush = _flushFailed;
      _flushFailed = false;
      if (!_disposed &&
          _loaded &&
          (_watchEnabled || recoveredFlush) &&
          _error != null) {
        _error = null;
        _changed();
      }
    } catch (error) {
      if (!_disposed) {
        _flushFailed = true;
        _error ??= 'Не удалось завершить сохранение: $error';
        _changed();
      }
      rethrow;
    }
  }

  void _changed() {
    if (!_disposed) _onChanged?.call();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _refreshTimer?.cancel();
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }
}
