import 'dart:async';
import 'dart:convert';

import '../room_document.dart';
import '../storage/room_store.dart';
import 'room_disk_sync.dart';
import 'yandex_disk_client.dart';

/// Final detach deliveries survive replacement bindings and revoked tokens.
/// Each old binding retains its own credential and frozen pre-detach prefix;
/// it must never receive edits authored for a subsequently connected Disk.
class RoomDiskRetirements {
  RoomDiskRetirements({
    required this.roomId,
    required this.store,
    required this.client,
    required this.readHistory,
    required this.mergeHistory,
    required this.onChanged,
  });

  final String roomId;
  final RoomStore store;
  final YandexDiskClient client;
  final List<RoomEdit> Function() readHistory;
  final Future<void> Function(List<RoomEdit>) mergeHistory;
  final void Function() onChanged;
  final _replicas = <String, RoomDiskSync>{};
  final _clearing = <String>{};
  final _finished = <String>{};
  Future<void>? _loading;
  bool _dirty = false;
  bool _enabled = false;
  bool _disposed = false;
  String? _readError;
  String? _clearError;

  bool get pending => _replicas.isNotEmpty;
  bool get busy => _replicas.values.any((replica) => replica.busy);
  String? get error {
    if (_readError != null || _clearError != null) {
      return _readError ?? _clearError;
    }
    for (final replica in _replicas.values) {
      if (replica.error != null) {
        return 'Отвязка прежнего Диска ещё не подтверждена. ${replica.error}';
      }
    }
    return null;
  }

  Future<void> update({required bool enabled}) {
    _enabled = enabled;
    if (_disposed) return Future.value();
    final loading = _loading;
    if (loading != null) {
      _dirty = true;
      return loading;
    }
    late final Future<void> result;
    result = Future<void>.microtask(() async {
      try {
        do {
          _dirty = false;
          final history = readHistory();
          final detaches = <String, RoomEdit>{};
          for (final edit in history) {
            if (edit.kind != RoomEditKind.diskConnection) continue;
            final value = jsonDecode(edit.text) as Map;
            if (value['action'] == 'disconnect') {
              final id = value['bindingId'] as String;
              final previous = detaches[id];
              if (previous == null || edit.compareTo(previous) < 0) {
                detaches[id] = edit;
              }
            }
          }
          for (final entry in detaches.entries) {
            if (_disposed) return;
            final id = entry.key;
            if (_finished.contains(id)) continue;
            var replica = _replicas[id];
            if (replica == null) {
              final credentials = await store.loadDiskCredentials(
                roomId,
                bindingId: id,
              );
              if (_disposed) return;
              if (credentials == null) continue;
              final cutoff = _cutoffHistory(history, entry.value);
              replica = RoomDiskSync(
                roomId: roomId,
                client: client,
                closeClientOnDispose: false,
                readHistory: () => cutoff,
                mergeHistory: mergeHistory,
                onChanged: () => _replicaChanged(id),
              );
              _replicas[id] = replica;
              replica.update(
                bindingId: id,
                token: credentials['token'] as String,
                enabled: _enabled,
              );
            } else {
              // Preserve its token and cutoff; pause/resume does not change them.
              replica.setEnabled(_enabled);
            }
          }
          _readError = null;
        } while (_dirty && !_disposed);
      } catch (_) {
        if (!_disposed) {
          _readError = 'Не удалось прочитать очередь отвязки Диска';
        }
      } finally {
        if (identical(_loading, result)) _loading = null;
        if (!_disposed) onChanged();
      }
    });
    _loading = result;
    return result;
  }

  List<RoomEdit> _cutoffHistory(List<RoomEdit> history, RoomEdit detach) {
    final included = <String, RoomEdit>{};
    // Proofs are allocated when a draft finally persists, not when its clock
    // was chosen. A retried old-clock draft may depend on a newer binding's
    // edits: exclude it rather than expand a retirement into that later data.
    for (final edit in validateAuthorHistory(history)) {
      if (edit.compareTo(detach) > 0 ||
          (edit.authorPrevious != null &&
              !included.containsKey(edit.authorPrevious)) ||
          (edit.authorBase?.any((id) => !included.containsKey(id)) ?? false)) {
        continue;
      }
      included[edit.id] = edit;
    }
    if (!included.containsKey(detach.id)) {
      throw const FormatException('Отвязка зависит от более поздней истории');
    }
    return List.unmodifiable(included.values);
  }

  void _replicaChanged(String id) {
    if (_disposed) return;
    final replica = _replicas[id];
    if (replica != null &&
        !replica.busy &&
        replica.acknowledged &&
        _clearing.add(id)) {
      unawaited(
        Future<void>.microtask(() async {
          try {
            await store.saveDiskCredentials(roomId, null, bindingId: id);
            if (_disposed) return;
            _finished.add(id);
            _replicas.remove(id)?.dispose();
            _clearError = null;
          } catch (_) {
            if (!_disposed) {
              _clearError = 'Не удалось удалить прежний доступ к Диску';
            }
          } finally {
            _clearing.remove(id);
            if (!_disposed) onChanged();
          }
        }),
      );
    }
    onChanged();
  }

  Future<void> sync() async {
    await update(enabled: _enabled);
    if (!_enabled) return;
    await Future.wait(
      _replicas.values.toList().map((replica) => replica.sync()),
    );
  }

  void dispose() {
    _disposed = true;
    for (final replica in _replicas.values) {
      replica.dispose();
    }
    _replicas.clear();
  }
}
