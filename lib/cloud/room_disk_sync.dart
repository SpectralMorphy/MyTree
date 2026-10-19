import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../room_document.dart';
import '../room_protocol.dart';
import 'yandex_disk_client.dart';

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
  String? error;
  bool get busy => _running != null;

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
      if (!RegExp(r'^[0-9a-f]{64}\.json$').hasMatch(name)) {
        throw const FormatException('Неверное имя облачного пакета');
      }
      var edits = _batches[name];
      if (edits == null) {
        final bytes = await client.readFile(token, '$directory/$name');
        if (!_current(generation)) return;
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
        edits = decodeRoomHistory(value['history']);
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
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _batches.clear();
    if (closeClientOnDispose) client.close();
  }
}
