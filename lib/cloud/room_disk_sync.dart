import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../room_document.dart';
import '../room_identity.dart';
import '../room_protocol.dart';
import 'disk_binding.dart';
import 'yandex_disk_client.dart';

final _diskBatchName = RegExp(r'^[0-9a-f]{64}\.json$');
const _maxDiskHistoryBatches = 2048;
const _diskHistoryDownloadConcurrency = 4;

List<RoomEdit> _decodeDiskBatch(
  Uint8List bytes, {
  required String name,
  required String roomId,
  required String bindingId,
}) {
  if (bytes.length > maxRoomTransferBytes ||
      '${sha256.convert(bytes)}.json' != name) {
    throw const FormatException('Облачный пакет повреждён');
  }
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map ||
      value['v'] != 1 ||
      value['roomId'] != roomId ||
      value['bindingId'] != bindingId) {
    throw const FormatException('Пакет другой комнаты или подключения');
  }
  return decodeRoomHistory(value['history']);
}

/// Reads an admission snapshot without preparing, merging, or writing anything.
///
/// Public access is rooted at the binding folder, not the application folder.
/// The returned canonical union includes [localHistory], which may supply author
/// predecessors or a later disconnect. Admission/role checks remain with callers.
/// [allowFinalDisconnect] is only for an established guest with this binding
/// already active in [localHistory], never for accepting a fresh invitation.
/// The client owns individual request cancellation; after this overall deadline,
/// a late response can never start another request or return a successful result.
Future<List<RoomEdit>> readDiskRoomHistory({
  required YandexDiskClient client,
  required String roomId,
  required RoomDiskAccess access,
  List<RoomEdit> localHistory = const [],
  bool Function()? isCurrent,
  Duration timeout = const Duration(seconds: 30),
  bool allowFinalDisconnect = false,
}) async {
  final clock = Stopwatch()..start();
  final deadline = DateTime.now().add(timeout);
  var stopped = false;

  bool requestIsCurrent() {
    if (stopped ||
        clock.elapsed >= timeout ||
        !DateTime.now().isBefore(deadline) ||
        !(isCurrent?.call() ?? true)) {
      stopped = true;
      return false;
    }
    return true;
  }

  void checkCurrent() {
    if (!requestIsCurrent()) {
      throw StateError('Чтение истории с Диска прервано');
    }
  }

  Future<List<RoomEdit>> readSnapshot() async {
    checkCurrent();
    // A binding ID is also a private path segment; the identity schema alone
    // permits characters that must never become cloud path components.
    if (!isValidRoomId(roomId) ||
        !isValidRoomActor(access.bindingId) ||
        access.bindingId == '.' ||
        access.bindingId == '..' ||
        RegExp(r'[/\\\x00-\x1f\x7f-\x9f]').hasMatch(access.bindingId)) {
      throw const FormatException('Неверное подключение Диска');
    }
    final local = List<RoomEdit>.of(localHistory);
    final directory = 'app:/mytree/$roomId/${access.bindingId}/batches';
    checkCurrent();
    final files = access.isEditor
        ? await client.listFiles(
            access.token!,
            directory,
            isCurrent: requestIsCurrent,
            deadline: deadline,
          )
        : await client.listPublicFiles(
            access.publicUrl!,
            path: '/batches',
            isCurrent: requestIsCurrent,
            deadline: deadline,
          );
    checkCurrent();
    final candidates = files.where((name) => name.endsWith('.json')).toList();
    if (candidates.isEmpty || candidates.length > _maxDiskHistoryBatches) {
      throw const FormatException('Неверное число облачных пакетов');
    }
    // Validate every name before constructing any download path.
    if (candidates.any((name) => !_diskBatchName.hasMatch(name))) {
      throw const FormatException('Неверное имя облачного пакета');
    }
    final names = candidates.toSet().toList()..sort();
    final batches = List<List<RoomEdit>?>.filled(names.length, null);
    var nextBatch = 0;
    var downloadedBytes = 0;
    Future<void> download() async {
      try {
        while (!stopped && nextBatch < names.length) {
          checkCurrent();
          final index = nextBatch++;
          final name = names[index];
          final bytes = access.isEditor
              ? await client.readFile(
                  access.token!,
                  '$directory/$name',
                  isCurrent: requestIsCurrent,
                  deadline: deadline,
                )
              : await client.readPublicFile(
                  access.publicUrl!,
                  '/batches/$name',
                  isCurrent: requestIsCurrent,
                  deadline: deadline,
                );
          checkCurrent();
          // Charge all completed downloads before decoding or scheduling more.
          // Only this fixed worker set can retain additional in-flight bodies.
          downloadedBytes += bytes.length;
          if (downloadedBytes > maxRoomTransferBytes) {
            throw const FormatException('Облачная история превышает 8 МиБ');
          }
          batches[index] = _decodeDiskBatch(
            bytes,
            name: name,
            roomId: roomId,
            bindingId: access.bindingId,
          );
        }
      } catch (_) {
        // Also invalidates the guard used by other workers' link/body requests.
        stopped = true;
        rethrow;
      }
    }

    // Eager failure still observes every worker, including late client errors.
    await Future.wait([
      for (
        var worker = 0;
        worker < _diskHistoryDownloadConcurrency && worker < names.length;
        worker++
      )
        download(),
    ], eagerError: true);
    checkCurrent();
    // Completion order must not change the validated union's input ordering.
    final remote = [for (final batch in batches) ...batch!];
    if (remote.isEmpty) {
      throw const FormatException('Облачная история пуста');
    }
    final combined = validateAuthorHistory([...local, ...remote]);
    var combinedBytes = 2; // JSON array brackets, plus records and separators.
    var first = true;
    for (final edit in combined) {
      checkCurrent();
      if (!first) combinedBytes++;
      first = false;
      combinedBytes += utf8.encode(jsonEncode(edit.toJson())).length;
      if (combinedBytes > maxRoomTransferBytes) {
        throw const FormatException('История комнаты превышает 8 МиБ');
      }
    }
    final binding = DiskBinding.project(combined);
    final finalDisconnect =
        allowFinalDisconnect &&
        !access.isEditor &&
        binding == null &&
        DiskBinding.project(local)?.id == access.bindingId &&
        _hasFinalDiskDisconnect(combined, access.bindingId);
    if (binding?.id != access.bindingId && !finalDisconnect) {
      throw const FormatException('Подключение Диска больше не активно');
    }
    checkCurrent();
    return List<RoomEdit>.unmodifiable(combined);
  }

  try {
    final history = await readSnapshot().timeout(
      timeout,
      onTimeout: () {
        stopped = true;
        throw StateError('Время чтения истории с Диска истекло');
      },
    );
    checkCurrent();
    return history;
  } catch (_) {
    // JSON/transport/platform failures may contain source text, tokens or URLs.
    // No external exception, including a client-supplied message, escapes here.
    throw StateError('Не удалось прочитать подтверждённую историю с Диска.');
  } finally {
    stopped = true;
    clock.stop();
  }
}

// Called only on a schema/prefix-validated union whose final projection is null.
// An unrelated/stale disconnect is not evidence this binding was ever active.
bool _hasFinalDiskDisconnect(List<RoomEdit> history, String bindingId) {
  final operations =
      history.where((edit) => edit.kind == RoomEditKind.diskConnection).toList()
        ..sort((left, right) => left.compareTo(right));
  final connect = operations.indexWhere(
    (edit) =>
        edit.id == bindingId &&
        (jsonDecode(edit.text) as Map)['action'] == 'connect',
  );
  if (connect < 0) return false;
  for (var index = connect + 1; index < operations.length; index++) {
    final payload = jsonDecode(operations[index].text) as Map;
    if (payload['action'] == 'disconnect' &&
        payload['bindingId'] == bindingId) {
      return DiskBinding.project(operations.take(index))?.id == bindingId;
    }
  }
  return false;
}

/// Polls a guest's published binding without ever preparing or uploading files.
/// Established guests can import its terminal disconnect, then stop polling.
/// A successful read says nothing about cloud persistence of local guest edits.
class RoomDiskReadSync {
  RoomDiskReadSync({
    required this.roomId,
    required this.client,
    required this.readHistory,
    required this.mergeHistory,
    required this.onChanged,
    this.pollInterval = const Duration(seconds: 30),
  });

  final String roomId;
  final YandexDiskClient client;
  final List<RoomEdit> Function() readHistory;
  final Future<void> Function(List<RoomEdit>) mergeHistory;
  final void Function() onChanged;
  final Duration pollInterval;
  RoomDiskAccess? _access;
  bool _enabled = false;
  bool _disposed = false;
  bool _hasRead = false;
  bool _finalDisconnected = false;
  int _generation = 0;
  Timer? _timer;
  Future<void>? _running;
  String? error;

  bool get busy => _running != null;

  String get status {
    if (_access == null) return 'Нет гостевого доступа к Диску';
    if (_finalDisconnected) return 'Подключение Диска отключено';
    if (!_enabled) return 'Чтение Диска приостановлено';
    if (busy) return 'Чтение истории с Диска…';
    if (error != null) return 'Диск недоступен · история сохранена локально';
    if (_hasRead) return 'История прочитана с Диска';
    return 'Ожидаем историю с Диска';
  }

  void update({RoomDiskAccess? access, required bool enabled}) {
    if (_disposed) return;
    final publicAccess = access != null && !access.isEditor ? access : null;
    final changed = publicAccess != _access;
    if (changed) {
      _hasRead = false;
      _finalDisconnected = false;
      error = null;
    }
    final nextEnabled = enabled && !_finalDisconnected;
    if (changed || nextEnabled != _enabled) _generation++;
    _access = publicAccess;
    _enabled = nextEnabled;
    if (!nextEnabled || publicAccess == null) {
      _timer?.cancel();
      _timer = null;
    } else if (changed || _timer == null) {
      schedule();
    }
  }

  bool _current(int generation) =>
      !_disposed && _enabled && _access != null && generation == _generation;

  void schedule() {
    if (_disposed || !_enabled || _access == null) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), () {
      _timer = null;
      unawaited(sync().catchError((Object _) {}));
    });
  }

  Future<void> sync() {
    if (_disposed || !_enabled || _access == null) {
      return Future.error(StateError('Нет гостевого доступа к Диску'));
    }
    final running = _running;
    if (running != null) return running;
    final generation = _generation;
    final access = _access!;
    _timer?.cancel();
    _timer = null;
    late final Future<void> result;
    result = _read(access, generation)
        .then((_) {
          if (_current(generation)) error = null;
        })
        .catchError((Object _) {
          const message =
              'Не удалось прочитать историю с Диска. Повторим позже.';
          if (_current(generation)) error = message;
          throw StateError(message);
        })
        .whenComplete(() {
          if (identical(_running, result)) _running = null;
          if (_disposed) return;
          onChanged();
          if (_enabled && _access != null) {
            _timer?.cancel();
            _timer = Timer(
              _current(generation) ? pollInterval : Duration.zero,
              () {
                _timer = null;
                unawaited(sync().catchError((Object _) {}));
              },
            );
          }
        });
    _running = result;
    onChanged();
    return result;
  }

  Future<void> _read(RoomDiskAccess access, int generation) async {
    if (!_current(generation)) return;
    final history = await readDiskRoomHistory(
      client: client,
      roomId: roomId,
      access: access,
      localHistory: readHistory(),
      isCurrent: () => _current(generation),
      allowFinalDisconnect: true,
    );
    if (!_current(generation)) return;
    await mergeHistory(history);
    if (!_current(generation)) return;
    _hasRead = true;
    if (DiskBinding.project(history) == null) {
      _finalDisconnected = true;
      error = null;
      update(access: access, enabled: false);
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _timer = null;
    // The session shares this client with other Disk operations.
  }
}

/// A second durable replica. It never authors edits, changes room admission, or
/// replaces a shared cloud file: batches are immutable and content-addressed.
class RoomDiskSync {
  RoomDiskSync({
    required this.roomId,
    required this.client,
    required this.readHistory,
    required this.mergeHistory,
    required this.onChanged,
    this.pollInterval = const Duration(seconds: 30),
    this.closeClientOnDispose = true,
  });

  final String roomId;
  final YandexDiskClient client;
  final List<RoomEdit> Function() readHistory;
  final Future<void> Function(List<RoomEdit>) mergeHistory;
  final void Function() onChanged;
  final Duration pollInterval;
  final bool closeClientOnDispose;
  String? _bindingId;
  String? _token;
  bool _enabled = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _timer;
  Future<void>? _running;
  final _batches = <String, List<RoomEdit>>{};
  String? _acknowledgedDigest;
  int _completedRounds = 0;
  String? error;
  bool get busy => _running != null;

  /// Progress only, not admission evidence or a replacement for a validated read.
  int get completedRounds => _completedRounds;

  bool get acknowledged =>
      _acknowledgedDigest != null &&
      _acknowledgedDigest == roomHistoryDigest(readHistory());

  String get status {
    if (_bindingId == null) return 'Не подключён';
    if (_token == null) return 'Ожидаем доступ от редактора';
    if (busy) return 'Синхронизация с Диском…';
    if (error != null) return 'Диск недоступен · изменения сохранены локально';
    if (acknowledged) return 'Копия на Диске подтверждена';
    return 'Есть изменения для отправки на Диск';
  }

  String _directory(String bindingId) => 'app:/mytree/$roomId/$bindingId';

  Future<void> prepare(String bindingId, String token) async {
    for (final path in [
      'app:/mytree',
      'app:/mytree/$roomId',
      _directory(bindingId),
      '${_directory(bindingId)}/batches',
    ]) {
      await client.createDirectory(token, path);
    }
  }

  void update({
    required String? bindingId,
    required String? token,
    required bool enabled,
  }) {
    if (_disposed) return;
    final changed = bindingId != _bindingId || token != _token;
    if (changed || enabled != _enabled) _generation++;
    if (changed) {
      _batches.clear();
      _acknowledgedDigest = null;
      error = null;
    }
    _bindingId = bindingId;
    _token = token;
    _enabled = enabled;
    if (!_enabled || bindingId == null || token == null) {
      _timer?.cancel();
      _timer = null;
    } else if (changed || _timer == null) {
      schedule();
    }
  }

  void setEnabled(bool enabled) =>
      update(bindingId: _bindingId, token: _token, enabled: enabled);

  void schedule() {
    if (_disposed || !_enabled || _bindingId == null || _token == null) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), () {
      _timer = null;
      unawaited(sync().catchError((Object _) {}));
    });
  }

  Future<void> sync() {
    if (_disposed || !_enabled || _bindingId == null || _token == null) {
      return Future.error(StateError('Нет доступа к подключённому Диску'));
    }
    final running = _running;
    if (running != null) return running;
    final generation = _generation;
    final bindingId = _bindingId!;
    final token = _token!;
    _timer?.cancel();
    _timer = null;
    late final Future<void> result;
    result = _sync(bindingId, token, generation)
        .then((_) {
          if (_current(generation)) error = null;
        })
        .catchError((Object failure) {
          if (_current(generation)) {
            // HTTP/platform errors can include URLs or headers. Only the API's
            // deliberately sanitized errors may reach the UI.
            error = failure is YandexDiskException
                ? failure.toString()
                : 'Не удалось подтвердить копию на Диске. Повторим позже.';
          }
          throw StateError(error ?? 'Синхронизация Диска прервана');
        })
        .whenComplete(() {
          if (identical(_running, result)) _running = null;
          if (_disposed) return;
          onChanged();
          if (_enabled && _bindingId != null && _token != null) {
            _timer?.cancel();
            _timer = Timer(
              _current(generation) ? pollInterval : Duration.zero,
              () {
                _timer = null;
                unawaited(sync().catchError((Object _) {}));
              },
            );
          }
        });
    _running = result;
    onChanged();
    return result;
  }

  bool _current(int generation) =>
      !_disposed && _enabled && generation == _generation;

  Future<void> _sync(String bindingId, String token, int generation) async {
    final directory = '${_directory(bindingId)}/batches';
    final files = await client.listFiles(token, directory);
    if (!_current(generation)) return;
    final names = files.where((name) => name.endsWith('.json')).toSet();
    final remote = <String, RoomEdit>{};
    var totalBytes = 0;
    for (final name in names.toList()..sort()) {
      if (!_diskBatchName.hasMatch(name)) {
        throw const FormatException('Неверное имя облачного пакета');
      }
      var edits = _batches[name];
      if (edits == null) {
        final bytes = await client.readFile(token, '$directory/$name');
        if (!_current(generation)) return;
        edits = _decodeDiskBatch(
          bytes,
          name: name,
          roomId: roomId,
          bindingId: bindingId,
        );
        _batches[name] = edits;
      }
      for (final edit in edits) {
        final previous = remote[edit.id];
        if (previous != null && !previous.sameContentAs(edit)) {
          throw const FormatException('Облачная история изменена');
        }
        if (previous == null) {
          totalBytes += utf8.encode(jsonEncode(edit.toJson())).length + 1;
          if (totalBytes > maxRoomTransferBytes) {
            throw const FormatException('Облачная история превышает 8 МиБ');
          }
        }
        remote[edit.id] = edit;
      }
    }
    // A partially uploaded batch sequence may omit a predecessor that is still
    // local. Validate the union, not each file in isolation, so retries can heal
    // interrupted uploads without accepting a truncated author history.
    final complete = validateAuthorHistory([
      ...readHistory(),
      ...remote.values,
    ]);
    if (!_current(generation)) return;
    await mergeHistory(complete);
    if (!_current(generation)) return;
    final history = readHistory();
    final missing = missingRoomEdits(
      history,
      roomHistoryInventory(remote.values),
    );
    var batch = <RoomEdit>[];
    var batchBytes = 0;
    Future<void> upload() async {
      if (batch.isEmpty || !_current(generation)) return;
      final edits = batch;
      batch = [];
      batchBytes = 0;
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'v': 1,
            'roomId': roomId,
            'bindingId': bindingId,
            'history': edits.map((edit) => edit.toJson()).toList(),
          }),
        ),
      );
      final name = '${sha256.convert(bytes)}.json';
      await client.writeFile(token, '$directory/$name', bytes);
      if (!_current(generation)) return;
      _batches[name] = edits;
      for (final edit in edits) {
        remote[edit.id] = edit;
      }
    }

    for (final edit in missing) {
      if (!_current(generation)) return;
      final size = utf8.encode(jsonEncode(edit.toJson())).length;
      if (batch.isNotEmpty && batchBytes + size > 512 * 1024) await upload();
      batch.add(edit);
      batchBytes += size;
    }
    await upload();
    if (!_current(generation)) return;
    // Acknowledges only this frozen local set, not concurrent edits, not another
    // device's unseen tail, and never an unconfirmed HTTP 202 upload.
    _acknowledgedDigest = roomHistoryDigest(history);
    _completedRounds++;
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _batches.clear();
    if (closeClientOnDispose) client.close();
  }
}
