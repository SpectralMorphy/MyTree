import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../room_document.dart';
import '../room_identity.dart';
import 'room_store.dart';
import 'storage_codec.dart';

RoomStore createPlatformRoomStore() => FileRoomStore();

/// Native append-only JSONL storage. Use one instance per storage directory.
/// Reads and writes share a recoverable queue; completed appends are flushed
/// before their futures complete. Pending writes cannot survive an OS kill.
class FileRoomStore extends RoomStore {
  FileRoomStore() : _directory = null;

  FileRoomStore.withDirectory(Directory directory) : _directory = directory;

  Directory? _directory;
  Future<void> _queue = Future<void>.value();
  final _histories = <String, Map<String, HistoryRecord>>{};

  Future<Directory> _getDirectory() async {
    final existing = _directory;
    if (existing != null) {
      await existing.create(recursive: true);
      return existing;
    }
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/mytree-room-store-v1');
    await directory.create(recursive: true);
    _directory = directory;
    return directory;
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    // A failing operation still reaches its caller, but cannot poison the
    // queue or prevent subsequent reads/retries from running.
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<File> _file(String name) async {
    final directory = await _getDirectory();
    return File('${directory.path}/$name');
  }

  Future<bool> _exists(File file) async {
    final type = await FileSystemEntity.type(file.path);
    if (type == FileSystemEntityType.notFound) {
      return false;
    }
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('Expected a storage file', file.path);
    }
    return true;
  }

  Future<String?> _readString(File file) async {
    if (!await _exists(file)) {
      return null;
    }
    return decodeStoredString(await file.readAsString(), file.path);
  }

  // Metadata is tiny. Flush a temporary file then atomically rename it, so
  // interrupted writes do not turn a stable client ID into partial JSON.
  Future<void> _writeString(File file, String value) async {
    if (await _readString(file) == value) {
      return;
    }
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file.path);
  }

  Future<bool> _hasMembership(String roomId) async {
    final file = await _file('member-${encodeStoreKey(roomId)}.json');
    final saved = await _readString(file);
    if (saved == null) {
      return false;
    }
    if (saved != roomId) {
      throw FormatException(
        'Membership does not match its room in ${file.path}',
      );
    }
    return true;
  }

  @override
  Future<String> loadClientId() => _enqueue(() async {
    final file = await _file('client-id.json');
    final existing = await _readString(file);
    if (existing != null) {
      return existing;
    }
    final id = createRoomId();
    await _writeString(file, id);
    return id;
  });

  @override
  Future<String?> loadLastRoom() => _enqueue(() async {
    final roomId = await _readString(await _file('last-room.json'));
    if (roomId != null && !await _hasMembership(roomId)) {
      throw FormatException('Last room $roomId has no saved membership');
    }
    return roomId;
  });

  @override
  Future<void> saveMembership(String roomId) => _enqueue(() async {
    requireRoomId(roomId);
    if (!await _hasMembership(roomId)) {
      await _writeString(
        await _file('member-${encodeStoreKey(roomId)}.json'),
        roomId,
      );
    }
    // Membership has completed durably before last-room can reference it.
    await _writeString(await _file('last-room.json'), roomId);
  });

  @override
  Future<bool> hasMembership(String roomId) => _enqueue(() async {
    requireRoomId(roomId);
    return _hasMembership(roomId);
  });

  String _credentialsPrefix(String roomId) =>
      'disk-credentials-${encodeStoreKey(roomId)}';

  Future<File> _credentialsFile(String roomId, [String? bindingId]) => _file(
    bindingId == null
        ? '${_credentialsPrefix(roomId)}.json'
        // Actor IDs may contain 128 Unicode characters. Hash only the archive
        // filename to stay below native filename limits; verify its payload ID.
        : '${_credentialsPrefix(roomId)}.binding.${sha256.convert(utf8.encode(bindingId))}.json',
  );

  Future<Map<String, dynamic>?> _readDiskCredentials(
    File file, {
    String? bindingId,
  }) async {
    if (!await _exists(file)) return null;
    try {
      return decodeDiskCredentials(
        utf8.decode(await file.readAsBytes()),
        bindingId: bindingId,
      );
    } on FormatException {
      // UTF-8 and JSON errors can contain source text, including a token.
      throw const FormatException('Invalid stored Disk credentials');
    }
  }

  Future<void> _writeDiskCredentials(
    File file,
    Map<String, dynamic> snapshot,
  ) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(snapshot), flush: true);
    await temporary.rename(file.path);
  }

  Future<void> _deleteDiskCredentials(File file) async {
    final temporary = File('${file.path}.tmp');
    if (await _exists(temporary)) await temporary.delete();
    if (await _exists(file)) await file.delete();
  }

  @override
  Future<Map<String, dynamic>?> loadDiskCredentials(
    String roomId, {
    String? bindingId,
  }) => _enqueue(() async {
    requireDiskCredentialsRoomId(roomId);
    requireDiskCredentialsBindingId(bindingId);
    if (bindingId != null) {
      final archived = await _readDiskCredentials(
        await _credentialsFile(roomId, bindingId),
        bindingId: bindingId,
      );
      if (archived != null) return archived;
    }
    final latest = await _readDiskCredentials(await _credentialsFile(roomId));
    return bindingId == null || latest?['bindingId'] == bindingId
        ? latest
        : null;
  });

  @override
  Future<void> saveDiskCredentials(
    String roomId,
    Map<String, dynamic>? value, {
    String? bindingId,
  }) {
    late Map<String, dynamic>? snapshot;
    try {
      requireDiskCredentialsRoomId(roomId);
      requireDiskCredentialsBindingId(bindingId);
      snapshot = value == null
          ? null
          : snapshotDiskCredentials(value, bindingId: bindingId);
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    return _enqueue(() async {
      final file = await _credentialsFile(roomId);
      if (snapshot == null && bindingId == null) {
        // Remove only this room's credential namespace, including interrupted
        // temporary files. History, membership, and other rooms are untouched.
        final directory = await _getDirectory();
        final prefix = '${_credentialsPrefix(roomId)}.binding.';
        await for (final entity in directory.list(followLinks: false)) {
          final name = entity.uri.pathSegments.last;
          if (name.startsWith(prefix)) {
            final archive = File(entity.path);
            if (await _exists(archive)) await archive.delete();
          }
        }
        await _deleteDiskCredentials(file);
        return;
      }
      final latest = await _readDiskCredentials(file);
      if (snapshot == null) {
        await _deleteDiskCredentials(await _credentialsFile(roomId, bindingId));
        if (latest?['bindingId'] == bindingId) {
          await _deleteDiskCredentials(file);
        }
        return;
      }
      final id = snapshot['bindingId'] as String;
      final archive = await _credentialsFile(roomId, id);
      final archived = await _readDiskCredentials(archive, bindingId: id);
      // Preserve pre-archive legacy pointers before replacing the latest value.
      if (latest != null && latest['bindingId'] != id) {
        final previousId = latest['bindingId'] as String;
        final previous = await _credentialsFile(roomId, previousId);
        if (await _readDiskCredentials(previous, bindingId: previousId) ==
            null) {
          await _writeDiskCredentials(previous, latest);
        }
      }
      if (archived == null || jsonEncode(archived) != jsonEncode(snapshot)) {
        await _writeDiskCredentials(archive, snapshot!);
      }
      if (latest == null || jsonEncode(latest) != jsonEncode(snapshot)) {
        await _writeDiskCredentials(file, snapshot!);
      }
    });
  }

  Future<File> _publicAccessFile(String roomId) =>
      _file('disk-public-access-${encodeStoreKey(roomId)}.json');

  Future<Map<String, dynamic>?> _readDiskPublicAccess(File file) async {
    if (!await _exists(file)) return null;
    try {
      return decodeDiskPublicAccess(utf8.decode(await file.readAsBytes()));
    } on FormatException {
      // Both UTF-8 and JSON diagnostics can expose the source URL.
      throw const FormatException('Invalid stored Disk public access');
    }
  }

  @override
  Future<Map<String, dynamic>?> loadDiskPublicAccess(String roomId) =>
      _enqueue(() async {
        requireDiskPublicAccessRoomId(roomId);
        return _readDiskPublicAccess(await _publicAccessFile(roomId));
      });

  @override
  Future<void> saveDiskPublicAccess(
    String roomId,
    Map<String, dynamic>? value,
  ) {
    late Map<String, dynamic>? snapshot;
    try {
      requireDiskPublicAccessRoomId(roomId);
      snapshot = value == null ? null : snapshotDiskPublicAccess(value);
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    return _enqueue(() async {
      final file = await _publicAccessFile(roomId);
      final temporary = File('${file.path}.tmp');
      if (snapshot == null) {
        // Explicit removal also clears interrupted writes or malformed data.
        if (await _exists(temporary)) await temporary.delete();
        if (await _exists(file)) await file.delete();
        return;
      }
      final previous = await _readDiskPublicAccess(file);
      final encoded = jsonEncode(snapshot);
      if (previous != null && jsonEncode(previous) == encoded) return;
      // One current pointer only. Flush and rename without touching the journal
      // or credential sidecars, retaining the old value if a write fails.
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
    });
  }

  Future<Map<String, HistoryRecord>> _readHistory(String roomId) async {
    final cached = _histories[roomId];
    if (cached != null) {
      return cached;
    }
    final file = await _file('history-${encodeStoreKey(roomId)}.jsonl');
    final history = <String, HistoryRecord>{};
    if (await _exists(file)) {
      final bytes = await file.readAsBytes();
      var start = 0;
      for (var index = 0; index < bytes.length; index++) {
        if (bytes[index] == 10) {
          final source = '${file.path} at byte $start';
          final record = HistoryRecord.decode(
            utf8.decode(bytes.sublist(start, index)),
            source,
          );
          addHistoryRecord(history, record);
          start = index + 1;
        }
      }
      if (start < bytes.length) {
        // A fully written JSON record without its newline is recoverable too.
        // Only invalid JSON/UTF-8 at EOF is truncated; schema errors and
        // conflicting IDs remain intact and keep reporting corruption.
        final source = '${file.path} at byte $start';
        late String tail;
        try {
          tail = utf8.decode(bytes.sublist(start));
          decodeStoredJson(tail, source);
        } on FormatException {
          final handle = await file.open(mode: FileMode.append);
          try {
            await handle.truncate(start);
            await handle.flush();
          } finally {
            await handle.close();
          }
          // Surface recovery instead of silently dropping an interrupted edit.
          // A retry can now read/append the complete records safely.
          throw FormatException(
            'Truncated an incomplete history tail in $source; '
            '${bytes.length - start} bytes removed. Retry to load intact edits.',
          );
        }
        addHistoryRecord(history, HistoryRecord.decode(tail, source));
        await _appendText(file, '\n');
      }
    }
    orderStoredHistory(history.values);
    _histories[roomId] = history;
    return history;
  }

  Future<void> _appendText(File file, String text) async {
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.writeString(text);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  @override
  Future<List<Map<String, dynamic>>> loadHistory(String roomId) =>
      _enqueue(() async {
        requireRoomId(roomId);
        final history = await _readHistory(roomId);
        return orderStoredHistory(
          history.values,
        ).map((record) => record.toJson()).toList();
      });

  @override
  Future<void> appendHistory(
    String roomId,
    List<Map<String, dynamic>> operations,
  ) {
    // Snapshot before joining the asynchronous queue, not after the caller
    // has had an opportunity to mutate the maps it supplied.
    late List<HistoryRecord> records;
    try {
      requireRoomId(roomId);
      records = operations.map(HistoryRecord.new).toList();
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    return _enqueue(() async {
      try {
        final history = await _readHistory(roomId);
        final additions = newValidatedHistoryRecords(history, records);
        if (additions.isEmpty) {
          return;
        }
        final file = await _file('history-${encodeStoreKey(roomId)}.jsonl');
        await _appendText(
          file,
          additions.map((record) => '${record.encoded}\n').join(),
        );
        for (final record in additions) {
          history[record.id] = record;
        }
      } catch (_) {
        // A failed append may have reached disk partially. Reload on retry to
        // deduplicate complete lines and repair/report an incomplete tail.
        _histories.remove(roomId);
        rethrow;
      }
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
    // Allocation and persistence occupy one queue item: no nested enqueue and
    // no proof reservation while another queued writer can advance the journal.
    return _enqueue(() async {
      try {
        _histories.remove(roomId);
        final history = await _readHistory(roomId);
        final additions = prepareAuthoredHistory(history, edits);
        if (additions.isNotEmpty) {
          final file = await _file('history-${encodeStoreKey(roomId)}.jsonl');
          for (final record in additions) {
            await _appendText(file, '${record.encoded}\n');
            history[record.id] = record;
          }
        }
        return orderStoredHistory(
          history.values,
        ).map((record) => record.toJson()).toList();
      } catch (_) {
        // Complete prefix records may already be durable. Retry re-reads them
        // and reuses their canonical proof; incomplete EOF recovery stays visible.
        _histories.remove(roomId);
        rethrow;
      }
    });
  }

  @override
  Future<void> flush() => _queue;
}
