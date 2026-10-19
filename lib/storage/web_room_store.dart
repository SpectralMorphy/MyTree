import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../room_document.dart';
import '../room_identity.dart';
import 'room_store.dart';
import 'storage_codec.dart';

RoomStore createPlatformRoomStore() => WebRoomStore();

@JS('navigator.locks')
external web.LockManager? get _clientIdLocks;

extension type _ClientIdLockMethods(JSObject _) implements JSObject {
  external JSAny? get request;
}

/// Synchronous localStorage writes, one immutable value per operation. History
/// is never rewritten on each edit. Quota/security/corruption errors propagate.
class WebRoomStore extends RoomStore {
  static const _prefix = 'mytree.room-store.v1.';

  @override
  bool get sharedAcrossTabs => true;

  // Resolve inside Future.sync so a blocked localStorage getter is also
  // reported through the store's Future API rather than during construction.
  web.Storage get _storage => web.window.localStorage;

  String _roomPrefix(String roomId) =>
      '${_prefix}room.${encodeStoreKey(roomId)}.';

  String? _readString(String key) {
    final encoded = _storage.getItem(key);
    return encoded == null ? null : decodeStoredString(encoded, key);
  }

  void _writeString(String key, String value) {
    if (_readString(key) != value) {
      _storage.setItem(key, jsonEncode(value));
    }
  }

  bool _hasMembership(String roomId) {
    final key = '${_roomPrefix(roomId)}membership';
    final saved = _readString(key);
    if (saved == null) {
      return false;
    }
    if (saved != roomId) {
      throw FormatException('Membership does not match its room in $key');
    }
    return true;
  }

  String _readOrCreateClientId() {
    const key = '${_prefix}client-id';
    final existing = _readString(key);
    if (existing != null) {
      if (!isValidRoomId(existing)) {
        throw const FormatException('Invalid stored browser client ID');
      }
      return existing;
    }
    final id = createRoomId();
    _writeString(key, id);
    return id;
  }

  @override
  Future<String> loadClientId() => Future.sync(() async {
    // Identity is settled before any per-room owner lock. Re-read, validate,
    // generate, and durably write under one origin-wide critical section, even
    // when different room tabs/stores cold-start simultaneously.
    final locks = _clientIdLocks;
    if (web.window.isSecureContext &&
        locks != null &&
        _ClientIdLockMethods(locks).request.typeofEquals('function')) {
      late String value;
      Object? failure;
      StackTrace? failureStack;
      await locks
          .request(
            '${_prefix}client-id',
            web.LockOptions(mode: 'exclusive'),
            ((web.Lock lock) {
              try {
                value = _readOrCreateClientId();
              } catch (error, stackTrace) {
                failure = error;
                failureStack = stackTrace;
              }
              return null;
            }).toJS,
          )
          .toDart;
      // Promise rejection would convert a Dart exception to JS NativeError.
      // Keep storage failures typed and retain their original Dart stack.
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      return value;
    }
    // Conventional independent-network fallback for browsers lacking secure
    // Web Locks. Still persist synchronously; never mask storage/quota failures
    // with an in-memory identity or claim cross-tab atomicity here.
    return _readOrCreateClientId();
  });

  @override
  Future<String?> loadLastRoom() => Future.sync(() {
    final roomId = _readString('${_prefix}last-room');
    if (roomId != null && !_hasMembership(roomId)) {
      throw FormatException('Last room $roomId has no saved membership');
    }
    return roomId;
  });

  @override
  Future<void> saveMembership(String roomId) => Future.sync(() {
    requireRoomId(roomId);
    if (!_hasMembership(roomId)) {
      _writeString('${_roomPrefix(roomId)}membership', roomId);
    }
    // Both calls run before the first await; last-room never precedes the
    // durable membership write, including when setItem throws on quota.
    _writeString('${_prefix}last-room', roomId);
  });

  @override
  Future<bool> hasMembership(String roomId) => Future.sync(() {
    requireRoomId(roomId);
    return _hasMembership(roomId);
  });

  String _credentialsKey(String roomId, [String? bindingId]) =>
      '${_roomPrefix(roomId)}disk-credentials'
      '${bindingId == null ? '' : '.binding.${encodeStoreKey(bindingId)}'}';

  Map<String, dynamic>? _readDiskCredentials(String key, {String? bindingId}) {
    final encoded = _storage.getItem(key);
    return encoded == null
        ? null
        : decodeDiskCredentials(encoded, bindingId: bindingId);
  }

  @override
  Future<Map<String, dynamic>?> loadDiskCredentials(
    String roomId, {
    String? bindingId,
  }) => Future.sync(() {
    requireDiskCredentialsRoomId(roomId);
    requireDiskCredentialsBindingId(bindingId);
    if (bindingId != null) {
      final archived = _readDiskCredentials(
        _credentialsKey(roomId, bindingId),
        bindingId: bindingId,
      );
      if (archived != null) return archived;
    }
    final latest = _readDiskCredentials(_credentialsKey(roomId));
    return bindingId == null || latest?['bindingId'] == bindingId
        ? latest
        : null;
  });

  @override
  Future<void> saveDiskCredentials(
    String roomId,
    Map<String, dynamic>? value, {
    String? bindingId,
  }) => Future.sync(() {
    requireDiskCredentialsRoomId(roomId);
    requireDiskCredentialsBindingId(bindingId);
    final snapshot = value == null
        ? null
        : snapshotDiskCredentials(value, bindingId: bindingId);
    final key = _credentialsKey(roomId);
    final storage = _storage;
    if (snapshot == null && bindingId == null) {
      final prefix = '$key.binding.';
      final archives = <String>[];
      for (var index = 0; index < storage.length; index++) {
        final candidate = storage.key(index);
        if (candidate == null) {
          throw const FormatException('A localStorage key disappeared');
        }
        if (candidate.startsWith(prefix)) archives.add(candidate);
      }
      for (final archive in archives) {
        storage.removeItem(archive);
      }
      storage.removeItem(key);
      return;
    }
    final latest = _readDiskCredentials(key);
    if (snapshot == null) {
      // Keep read/compare/remove in one synchronous browser task. A losing
      // staged binding must not clear a newer binding's latest value.
      storage.removeItem(_credentialsKey(roomId, bindingId));
      if (latest?['bindingId'] == bindingId) storage.removeItem(key);
      return;
    }
    final id = snapshot['bindingId'] as String;
    final archiveKey = _credentialsKey(roomId, id);
    final archived = _readDiskCredentials(archiveKey, bindingId: id);
    // Preserve a legacy latest-only value before overwriting it, but never
    // overwrite a newer archive with an older pointer after a failed save.
    if (latest != null && latest['bindingId'] != id) {
      final previousId = latest['bindingId'] as String;
      final previousKey = _credentialsKey(roomId, previousId);
      if (_readDiskCredentials(previousKey, bindingId: previousId) == null) {
        storage.setItem(previousKey, jsonEncode(latest));
      }
    }
    final encoded = jsonEncode(snapshot);
    if (archived == null || jsonEncode(archived) != encoded) {
      storage.setItem(archiveKey, encoded);
    }
    if (latest == null || jsonEncode(latest) != encoded) {
      // Archive first: a later pointer failure is visible to the caller, but
      // cannot destroy another staged connect's credentials. No journal writes.
      storage.setItem(key, encoded);
    }
  });

  HistoryRecord _readOperation(String key, String operationPrefix) {
    final encoded = _storage.getItem(key);
    if (encoded == null) {
      throw FormatException('Missing operation value in $key');
    }
    final record = HistoryRecord.decode(encoded, key);
    if (key != '$operationPrefix${encodeStoreKey(record.id)}') {
      throw FormatException('Operation id does not match its key in $key');
    }
    return record;
  }

  // A short journal lock, deliberately distinct from identity and the long-lived
  // networking owner lock. All room reads and writers use the same lock name.
  Future<T> _withJournalLock<T>(
    String roomId,
    T Function(bool locked) action, {
    bool required = false,
  }) => Future.sync(() async {
    requireRoomId(roomId);
    final locks = _clientIdLocks;
    if (web.window.isSecureContext &&
        locks != null &&
        _ClientIdLockMethods(locks).request.typeofEquals('function')) {
      late T result;
      Object? failure;
      StackTrace? failureStack;
      await locks
          .request(
            '${_prefix}journal.${encodeStoreKey(roomId)}',
            web.LockOptions(mode: 'exclusive'),
            ((web.Lock lock) {
              try {
                result = action(true);
              } catch (error, stackTrace) {
                failure = error;
                failureStack = stackTrace;
              }
              return null;
            }).toJS,
          )
          .toDart;
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      return result;
    }
    if (required) {
      throw UnsupportedError('Atomic room authoring requires secure Web Locks');
    }
    return action(false);
  });

  Map<String, HistoryRecord> _readHistory(String roomId) {
    final prefix = '${_roomPrefix(roomId)}operation.';
    final history = <String, HistoryRecord>{};
    final storage = _storage;
    final length = storage.length;
    for (var index = 0; index < length; index++) {
      final key = storage.key(index);
      if (key == null) {
        throw const FormatException('A localStorage key disappeared');
      }
      if (key.startsWith(prefix)) {
        addHistoryRecord(history, _readOperation(key, prefix));
      }
    }
    return history;
  }

  void _appendRecords(String roomId, Iterable<HistoryRecord> records) {
    final prefix = '${_roomPrefix(roomId)}operation.';
    for (final record in records) {
      _storage.setItem('$prefix${encodeStoreKey(record.id)}', record.encoded);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> loadHistory(String roomId) =>
      _withJournalLock(roomId, (_) {
        // localStorage key order is not chronological. Prefix histories are
        // returned predecessor-first, preserving the original record JSON.
        return orderStoredHistory(
          _readHistory(roomId).values,
        ).map((record) => record.toJson()).toList();
      });

  @override
  Stream<void> watchHistory(String roomId) {
    requireRoomId(roomId);
    final prefix = '${_roomPrefix(roomId)}operation.';
    final credentialsKey = _credentialsKey(roomId);
    late StreamController<void> controller;
    JSFunction? listener;
    controller = StreamController<void>(
      onListen: () {
        try {
          final storage = _storage;
          final handler = ((web.Event event) {
            final change = event as web.StorageEvent;
            if (change.storageArea == storage &&
                ((change.key?.startsWith(prefix) ?? false) ||
                    change.key == credentialsKey ||
                    (change.key?.startsWith('$credentialsKey.binding.') ??
                        false))) {
              controller.add(null);
            }
          }).toJS;
          web.window.addEventListener('storage', handler);
          listener = handler;
        } catch (error, stackTrace) {
          controller.addError(error, stackTrace);
          unawaited(controller.close());
        }
      },
      onCancel: () {
        final handler = listener;
        if (handler != null) {
          web.window.removeEventListener('storage', handler);
          listener = null;
        }
      },
    );
    return controller.stream;
  }

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
    return _withJournalLock(roomId, (locked) {
      final history = _readHistory(roomId);
      final additions = newValidatedHistoryRecords(history, records);
      if (!locked &&
          [
            ...history.values,
            ...records,
          ].any((record) => record.toJson().containsKey('authorSequence'))) {
        throw UnsupportedError('Author-prefix writes require secure Web Locks');
      }
      // The entire combined history was checked before the first setItem. Its
      // predecessor-first ordering keeps a quota failure's durable prefix valid.
      _appendRecords(roomId, additions);
    });
  }

  @override
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
    return _withJournalLock(roomId, (_) {
      final history = _readHistory(roomId);
      final additions = prepareAuthoredHistory(history, edits);
      for (final record in additions) {
        _appendRecords(roomId, [record]);
        history[record.id] = record;
      }
      return orderStoredHistory(
        history.values,
      ).map((record) => record.toJson()).toList();
    }, required: true);
  }
}
