import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'cloud/disk_binding.dart';
import 'cloud/disk_credential_exchange.dart';
import 'cloud/room_disk_sync.dart';
import 'cloud/room_disk_retirements.dart';
import 'cloud/yandex_disk_client.dart';
import 'ice_configuration.dart';
import 'local/room_tabs.dart';
import 'network_status_stub.dart'
    if (dart.library.js_interop) 'network_status_web.dart';
import 'room_document.dart';
import 'room_history.dart';
import 'room_identity.dart';
import 'room_protocol.dart';
import 'signaling/fallback_signaling.dart';
import 'signaling/signaling.dart';
import 'storage/room_store.dart';
import 'tree/tree_document.dart';

@immutable
class RoomParticipant {
  const RoomParticipant({
    required this.actorId,
    required this.name,
    required this.isOnline,
    required this.isSelf,
    this.role = RoomRole.editor,
    this.personId,
    this.boundPersonFullName,
    this.avatarDataUrl,
  });

  final String actorId;
  final String name;
  final bool isOnline;
  final bool isSelf;
  final RoomRole role;
  final String? personId;

  /// The durable tree identity for tooltips, independent of the chosen alias.
  final String? boundPersonFullName;
  final String? avatarDataUrl;
}

/// A persisted room, with an elected (not permanent) signaling rendezvous host.
///
/// Only accepted/saved members may claim [hostAlias]. Invitations contain the
/// stable [roomId], never a device's transient signaling ID. Fresh members need
/// either a valid live welcome or a validated, durably saved Disk invitation.
/// Transfers are limited to 8 MiB of UTF-8 JSON; larger histories remain local
/// and report a synchronization error rather than silently truncating history.
class RoomSession extends ChangeNotifier {
  RoomSession({
    required this.roomId,
    required this.actorId,
    required this.store,
    required bool existingMember,
    String? participantName,
    List<RoomEdit>? initialHistory,
    this.invitationRole,
    this.invitationDiskAccess,
    this.preferExistingHost = false,
    this.newlyCreated = false,
    this.peerFactory = createSignalingPeer,
    this.roomTabs,
    this.now = DateTime.now,
    this.requireFamilyTree = false,
    this.iceConfiguration = const IceConfiguration.fromEnvironment(),
    YandexDiskClient? diskClient,
  }) : _joined = existingMember,
       _entryHistory = initialHistory == null
           ? null
           : List.unmodifiable(initialHistory),
       _entryParticipantName = participantName == null
           ? null
           : normalizeParticipantName(participantName) {
    if (participantName != null && _entryParticipantName == null) {
      throw ArgumentError.value(participantName, 'participantName');
    }
    if (invitationDiskAccess != null &&
        (invitationRole == null ||
            invitationDiskAccess!.isEditor !=
                (invitationRole == RoomRole.editor))) {
      throw const FormatException('Некорректный доступ в приглашении');
    }
    _history = RoomHistory(
      roomId: roomId,
      actorId: actorId,
      store: store,
      existingMember: existingMember,
      onChanged: _historyChanged,
      onLog: _record,
      onDurableEdits: _onDurableEdits,
      serializeRefresh: (refresh) {
        // Storage refreshes and incoming histories share the admission queue.
        _messages = _messages.then((_) => refresh());
      },
    );
    _diskClient = diskClient ?? YandexDiskClient();
    _diskSync = RoomDiskSync(
      roomId: roomId,
      client: _diskClient,
      closeClientOnDispose: false,
      readHistory: () => _history.durableHistory,
      mergeHistory: _mergeDiskHistory,
      onChanged: _diskChanged,
    );
    _diskReadSync = RoomDiskReadSync(
      roomId: roomId,
      client: _diskClient,
      readHistory: () => _history.durableHistory,
      mergeHistory: _mergePublicDiskHistory,
      onChanged: _changed,
    );
    _diskRetirements = RoomDiskRetirements(
      roomId: roomId,
      store: store,
      client: _diskClient,
      readHistory: () => _history.durableHistory,
      mergeHistory: _mergeDiskHistory,
      onChanged: _changed,
    );
    _diskCredentialExchange = DiskCredentialExchange(
      roomId: roomId,
      actorId: actorId,
      peerFactory: peerFactory,
      rtcConfiguration: iceConfiguration.validationError == null
          ? iceConfiguration.toRtcConfiguration()
          : const {},
      isEditor: (actor) =>
          _durableRoleDocument.participantRoles[actor] == RoomRole.editor,
      activeBindingId: () => diskBinding?.id,
      readCredentials: () => _diskCredentials,
      onCredentials: (bindingId, token) => _saveReceivedDiskCredentials(
        bindingId,
        token,
        propagateFailure: true,
      ),
    );
  }

  final String roomId;
  final String actorId;
  final RoomStore store;
  final String? _entryParticipantName;

  // The UI's saved-alias read, still validated by RoomHistory on entry. Watching
  // storage closes the snapshot/subscribe gap as for an ordinary history load.
  List<RoomEdit>? _entryHistory;

  /// Null preserves direct legacy callers. Named UI entry always supplies the
  /// invitation role, including for a saved member whose durable role wins.
  final RoomRole? invitationRole;

  /// Optional binding-scoped entry snapshot. Never a welcome or a peer ACK.
  final RoomDiskAccess? invitationDiskAccess;

  /// A first-attempt optimization, never proof of membership or a live host.
  final bool preferExistingHost;

  /// Only the creator of a freshly saved, random, not-yet-shared room can know
  /// it is solo without discovery. Restored membership is never this evidence.
  final bool newlyCreated;
  final SignalingPeerFactory peerFactory;
  final IceConfiguration iceConfiguration;
  final DateTime Function() now;
  final bool requireFamilyTree;

  /// Provided only when this store is genuinely shared by same-origin tabs.
  final RoomTabs? roomTabs;

  static const maxTransferBytes = maxRoomTransferBytes;
  static const _joinDeadline = Duration(seconds: 30);
  static const _registrationDeadline = Duration(seconds: 8);
  static const _handshakeDeadline = Duration(seconds: 12);
  static const _checkpointDeadline = Duration(seconds: 12);
  static const _assemblyDeadline = Duration(seconds: 25);
  static const _livenessDeadline = Duration(seconds: 20);

  late final RoomHistory _history;
  late final YandexDiskClient _diskClient;
  late final RoomDiskSync _diskSync;
  late final RoomDiskReadSync _diskReadSync;
  late final DiskCredentialExchange _diskCredentialExchange;
  Map<String, dynamic>? _diskCredentials;
  RoomDiskAccess? _diskPublicAccess;
  bool _diskEntryPending = true;
  bool _diskEntryReading = false;
  bool _initialSyncFromDisk = false;
  String? _diskEntryError;
  Future<void>? _diskCredentialsLoading;
  late final RoomDiskRetirements _diskRetirements;
  String? _diskCommandError;
  bool _diskCommandBusy = false;
  int _diskProjectionLength = -1;
  DiskBinding? _projectedDiskBinding;
  final _connections = <RoomChannel, _RoomConnection>{};
  final _peerSubscriptions = <StreamSubscription<dynamic>>[];
  final _tabSubscriptions = <StreamSubscription<dynamic>>[];
  StreamSubscription<bool>? _networkSubscription;
  StreamSubscription<bool>? _foregroundSubscription;
  bool _networkOnlineHint = networkOnlineHint;
  bool _tabsActive = false;
  bool _tabsStarting = false;
  bool _tabLeader = false;
  int _tabTerm = 0;
  RoomTabState? _tabState;
  RoomTabState? _verifiedTabState;
  RoomTabState? _publishedTabState;
  Timer? _tabPublishTimer;
  Timer? _tabVerifyTimer;
  int _tabInventoryLength = -1;
  Map<String, String> _tabInventory = const {};
  int _roleProjectionLength = -1;
  RoomDocument _durableRoles = RoomDocument();
  final _tree = TreeDocument();
  final _durableTree = TreeDocument();
  int _treeProjectionLength = -1;
  int _durableTreeLength = -1;
  final _projectedTreeIds = <String>{};
  final _projectedDurableTreeIds = <String>{};
  final _sizedEditIds = <String>{};
  int _historyBytes = 2;
  bool _entryProfileSaved = false;
  bool _admissionHistoryLoaded = false;
  final _log = <String>[];
  final _random = Random();
  Future<void> _messages = Future<void>.value();
  Future<void>? _startFuture;
  SignalingPeer? _peer;
  _RoomConnection? _hostConnection;
  Timer? _joinTimer;
  Timer? _registrationTimer;
  Timer? _retryTimer;
  Timer? _heartbeatTimer;
  Timer? _resumeTimer;
  DateTime? _backgroundedAt;
  DateTime? _lastHeartbeatAt;
  DateTime? _peerStartedAt;
  bool _discoveryComplete = false;
  Timer? _initialTimer;
  Timer? _soloTimer;
  int _entryAttempt = 0;
  bool _initialSyncComplete = false;
  bool _localCopyOpened = false;
  bool _settledHosting = false;
  String? _initialSyncError;
  Set<String>? _soloCheckpoint;
  bool _failedInitialConnection = false;
  bool _validatedRemoteSeen = false;
  int _generation = 0;
  int _retryAttempt = 0;
  int _remoteOnline = 1;
  Set<String>? _remoteActors;
  bool _joined;
  bool _disposed = false;
  bool _running = false;
  bool _networkStarted = false;
  bool _hosting = false;
  bool _registered = false;
  bool _signalingReady = false;
  bool _peerFailed = false;
  String _requestedId = '';
  String? _error;
  String? _networkIssue;

  String get hostAlias => 'mytree-room-$roomId';
  bool get joined => _joined;

  /// Loading/admission readiness, not authority to edit. Guests can still open
  /// the document, host channels and relay the entire journal.
  bool get editable => !_disposed && _joined && _history.loaded;
  bool get canEdit => editable && ownRole == RoomRole.editor;

  RoomDocument get _durableRoleDocument {
    // A failed optimistic promotion is visible to the journal retry machinery,
    // but must never grant commands to this participant or another local tab.
    if (_roleProjectionLength != _history.durableLength) {
      _durableRoles = RoomDocument()
        ..merge(
          _history.durableHistory.where(
            (edit) => edit.kind == RoomEditKind.participantRole,
          ),
        );
      _roleProjectionLength = _history.durableLength;
    }
    return _durableRoles;
  }

  RoomRole get ownRole =>
      _durableRoleDocument.participantRoles[actorId] ??
      (_joined ? RoomRole.editor : invitationRole ?? RoomRole.editor);

  bool get initialSyncComplete => _initialSyncComplete;
  String? get initialSyncError => _initialSyncError;
  bool get localCopyOpened => _localCopyOpened;
  String get initialSyncStatus {
    if (_initialSyncComplete) {
      return _initialSyncFromDisk
          ? 'История загружена с Диска · онлайн-сверка продолжается'
          : 'История комнаты проверена';
    }
    if (_diskEntryReading) return 'Проверяем историю на Диске…';
    if (_localCopyOpened) {
      return 'Локальная копия · синхронизация не подтверждена';
    }
    if (_initialSyncError != null) {
      return 'Не удалось проверить историю комнаты';
    }
    if (!_history.loaded) return 'Читаем сохранённую историю…';
    if (_isTabFollower) {
      return _verifiedTabState?.initialSyncStatus ??
          'Проверяем историю через соседнюю вкладку…';
    }
    if (!_registered) return 'Ищем онлайн-участников…';
    if (_connections.isEmpty) return 'Проверяем доступность комнаты…';
    return 'Сохраняем и сверяем полную историю…';
  }

  /// Explicit display bypass, not synchronization or admission. It leaves
  /// discovery/backfill running and never promotes unaccepted/failed loads.
  void openLocalCopy() {
    if (_disposed || !_joined || !_history.loaded || _initialSyncComplete) {
      return;
    }
    _localCopyOpened = true;
    _changed();
    if (_networkStarted && !_tabsActive && !_tabsStarting) {
      unawaited(_activateTabs(retainNetwork: true));
    }
  }

  String get text => _history.text;
  String get roomName => _history.roomName;
  String? get participantName =>
      _joined ? _history.participantNames[actorId] : null;
  List<RoomEdit> get changes => _history.changes;

  Iterable<StampedTreeOperation> _treeOperations(Iterable<RoomEdit> edits) =>
      edits
          .where((edit) => edit.kind == RoomEditKind.tree)
          .map(
            (edit) => StampedTreeOperation(
              id: edit.id,
              author: edit.author,
              clock: edit.clock,
              createdAt: DateTime.fromMillisecondsSinceEpoch(edit.createdAt),
              operation: TreeOperation.fromJson(jsonDecode(edit.text)),
            ),
          );

  TreeDocument get tree {
    if (_treeProjectionLength != _history.historyLength) {
      final additions = _history.changes
          .where(
            (edit) =>
                edit.kind == RoomEditKind.tree &&
                !_projectedTreeIds.contains(edit.id),
          )
          .toList();
      _tree.merge(_treeOperations(additions));
      _projectedTreeIds.addAll(additions.map((edit) => edit.id));
      _treeProjectionLength = _history.historyLength;
    }
    return _tree;
  }

  TreeDocument get durableTree {
    if (_durableTreeLength != _history.durableLength) {
      final additions = _history.durableHistory
          .where(
            (edit) =>
                edit.kind == RoomEditKind.tree &&
                !_projectedDurableTreeIds.contains(edit.id),
          )
          .toList();
      _durableTree.merge(_treeOperations(additions));
      _projectedDurableTreeIds.addAll(additions.map((edit) => edit.id));
      _durableTreeLength = _history.durableLength;
    }
    return _durableTree;
  }

  String? get boundPersonId => _boundEditorPersonId(actorId);
  String? get boundPersonFullName {
    final id = boundPersonId;
    return id == null ? null : durableTree.person(id)?.fullName;
  }

  DiskBinding? get diskBinding {
    if (_diskProjectionLength != _history.durableLength) {
      _projectedDiskBinding = DiskBinding.project(_history.durableHistory);
      _diskProjectionLength = _history.durableLength;
    }
    return _projectedDiskBinding;
  }

  bool get canConnectDisk =>
      canEdit && diskBinding == null && !_diskCommandBusy && !_diskEntryPending;

  bool get canDisconnectDisk {
    final binding = diskBinding;
    if (!canEdit || binding == null || _diskCommandBusy || _diskEntryPending) {
      return false;
    }
    if (binding.ownerActor == actorId) return true;
    final ownerPerson = _boundEditorPersonId(binding.ownerActor);
    return ownerPerson != null && ownerPerson == boundPersonId;
  }

  bool get diskInvitationsAvailable {
    final binding = diskBinding;
    if (_disposed || !_joined || binding == null) return false;
    if (ownRole == RoomRole.editor) return true;
    final access = _diskPublicAccess;
    return access != null &&
        !access.isEditor &&
        access.bindingId == binding.id &&
        access.publicUrl != null;
  }

  bool get canPublishDiskInvitation =>
      diskInvitationsAvailable &&
      canEdit &&
      _durableRoleDocument.participantRoles[actorId] == RoomRole.editor;

  bool get diskUnlinkPending => _diskRetirements.pending;
  bool get diskSyncAcknowledged => canEdit && _diskSync.acknowledged;
  bool get diskSyncBusy =>
      _diskCommandBusy ||
      _diskEntryReading ||
      _diskSync.busy ||
      _diskReadSync.busy ||
      _diskRetirements.busy;
  String? get diskSyncError =>
      _diskCommandError ??
      _diskEntryError ??
      _diskSync.error ??
      _diskReadSync.error ??
      _diskRetirements.error;
  String get diskSyncStatus => _diskEntryReading
      ? 'Чтение истории с Диска…'
      : diskBinding == null
      ? diskUnlinkPending
            ? 'Отвязка сохранена локально · отправляем на Диск'
            : 'Не подключён'
      : !canEdit
      ? _diskPublicAccess?.bindingId == diskBinding?.id
            ? _diskReadSync.status
            : 'Подключён'
      : _diskSync.status;

  Future<void> _loadDiskCredentials() {
    final loading = _diskCredentialsLoading;
    if (loading != null) return loading;
    late final Future<void> result;
    result = Future<void>.microtask(() async {
      try {
        Map<String, dynamic>? value;
        String? requestedBinding;
        do {
          requestedBinding = diskBinding?.id;
          value = ownRole == RoomRole.editor
              ? await store.loadDiskCredentials(
                  roomId,
                  bindingId: requestedBinding,
                )
              : null;
          if (_disposed) return;
        } while (requestedBinding != diskBinding?.id);
        _diskCredentials = ownRole == RoomRole.editor ? value : null;
        final publicValue = diskBinding == null
            ? null
            : await store.loadDiskPublicAccess(roomId);
        if (_disposed) return;
        _diskPublicAccess = publicValue == null
            ? null
            : RoomDiskAccess.fromJson(publicValue);
        _updateDiskSync();
        _shareDiskCredentials();
      } catch (_) {
        if (!_disposed) {
          _diskCommandError =
              'Не удалось прочитать доступ к Диску на устройстве';
        }
      } finally {
        if (identical(_diskCredentialsLoading, result)) {
          _diskCredentialsLoading = null;
        }
        _changed();
      }
    });
    _diskCredentialsLoading = result;
    return result;
  }

  void _updateDiskSync() {
    if (_disposed) return;
    final binding = diskBinding;
    final savedId = _diskCredentials?['bindingId'] as String?;
    final token = _diskCredentials?['token'] as String?;
    _diskSync.update(
      bindingId: binding?.id,
      token: savedId == binding?.id ? token : null,
      enabled: canEdit && !_diskEntryPending,
    );
    _diskReadSync.update(
      access: _diskPublicAccess?.bindingId == binding?.id
          ? _diskPublicAccess
          : null,
      enabled: editable && !canEdit && !_diskEntryPending,
    );
    unawaited(_diskRetirements.update(enabled: canEdit && !_diskEntryPending));
  }

  void _diskChanged() {
    if (_disposed) return;
    if (!_diskSync.busy) {
      if (_diskSync.error == null && _diskSync.acknowledged) {
        _diskEntryError = null;
      }
      // A peer may have received a token but failed its local durable save.
      // Periodic cloud rounds also retry directed delivery without logging it.
      for (final state in _connections.values) {
        state.sentDiskBinding = null;
      }
      _shareDiskCredentials();
    }
    _changed();
  }

  Future<void> _mergeDiskHistory(List<RoomEdit> edits) {
    final result = _messages.then((_) async {
      if (_disposed || !canEdit) return;
      final added = await _history.merge(edits);
      if (added == null) throw StateError('Облачные изменения не сохранены');
      await _history.flush();
      if (!_disposed && added.isNotEmpty) _onDurableEdits(added);
    });
    // A failed cloud read/save cannot poison the admission/network queue.
    _messages = result.catchError((Object _) {});
    return result;
  }

  Future<void> _mergePublicDiskHistory(List<RoomEdit> edits) {
    final access = _diskPublicAccess;
    final result = _messages.then((_) async {
      if (_disposed ||
          !editable ||
          canEdit ||
          _diskEntryPending ||
          access == null ||
          access != _diskPublicAccess ||
          diskBinding?.id != access.bindingId) {
        return;
      }
      _validateDiskEntryHistory(edits, access, allowFinalDisconnect: true);
      final added = await _history.merge(edits);
      if (added == null) throw StateError('Облачные изменения не сохранены');
      await _history.flush();
      if (!_disposed && added.isNotEmpty) _onDurableEdits(added);
    });
    _messages = result.catchError((Object _) {});
    return result;
  }

  /// Produces only binding-scoped access. Publication is an explicit command,
  /// never an entry side effect, and needs the caller's prior consent.
  Future<RoomDiskAccess?> prepareDiskInvitation(
    RoomRole role, {
    bool allowPublication = false,
  }) async {
    final binding = diskBinding;
    if (!diskInvitationsAvailable || binding == null) return null;
    if (_diskCommandBusy || _diskEntryPending) {
      throw StateError('Дождитесь завершения операции с Диском');
    }
    final bindingId = binding.id;
    if (bindingId == '.' ||
        bindingId == '..' ||
        RegExp(r'[/\\\x00-\x1f\x7f-\x9f]').hasMatch(bindingId)) {
      throw StateError('Некорректное подключение Диска');
    }
    bool current() => !_disposed && _joined && diskBinding?.id == bindingId;
    bool editor() =>
        current() &&
        canEdit &&
        _durableRoleDocument.participantRoles[actorId] == RoomRole.editor;
    void requireCurrent({bool requireEditor = false}) {
      if (!current() || (requireEditor && !editor())) {
        throw StateError('Подключение комнаты или права изменились');
      }
    }

    _diskCommandBusy = true;
    _diskCommandError = null;
    _changed();
    try {
      requireCurrent(requireEditor: role == RoomRole.editor);
      if (role == RoomRole.guest) {
        final saved = await store.loadDiskPublicAccess(roomId);
        requireCurrent();
        final access = saved == null ? null : RoomDiskAccess.fromJson(saved);
        if (access != null &&
            !access.isEditor &&
            access.bindingId == bindingId) {
          _validateDiskEntryHistory(_history.durableHistory, access);
          _diskPublicAccess = access;
          _updateDiskSync();
          return access;
        }
        if (!allowPublication) return null;
        requireCurrent(requireEditor: true);
      }
      final saved = await store.loadDiskCredentials(
        roomId,
        bindingId: bindingId,
      );
      requireCurrent(requireEditor: true);
      final access = saved == null ? null : RoomDiskAccess.fromJson(saved);
      if (access == null || !access.isEditor || access.bindingId != bindingId) {
        throw StateError('Нет сохранённого доступа к подключённому Диску');
      }
      _validateDiskEntryHistory(_history.durableHistory, access);
      final token = access.token!;
      _diskCredentials = saved;
      if (role == RoomRole.editor) return access;

      bool sameCredential() =>
          editor() &&
          _diskCredentials?['bindingId'] == bindingId &&
          _diskCredentials?['token'] == token;
      Future<void> verifyCredential() async {
        requireCurrent(requireEditor: true);
        final value = await store.loadDiskCredentials(
          roomId,
          bindingId: bindingId,
        );
        if (!sameCredential() ||
            value?['bindingId'] != bindingId ||
            value?['token'] != token) {
          throw StateError('Доступ к подключённому Диску изменился');
        }
      }

      await _history.flush();
      await verifyCredential();
      _updateDiskSync();
      await _diskSync.sync();
      await verifyCredential();
      // Concurrent local writes must not be advertised as already uploaded.
      if (!_diskSync.acknowledged) {
        throw StateError('Сначала подтвердите текущую копию на Диске');
      }
      final publicUrl = await _diskClient.publishDirectory(
        token,
        'app:/mytree/$roomId/$bindingId',
      );
      await verifyCredential();
      final publicAccess = RoomDiskAccess.guest(
        bindingId: bindingId,
        publicUrl: publicUrl,
      );
      await store.saveDiskPublicAccess(roomId, publicAccess.toJson());
      await verifyCredential();
      await store.flush();
      await verifyCredential();
      _diskPublicAccess = publicAccess;
      _updateDiskSync();
      return publicAccess;
    } catch (_) {
      if (!_disposed) {
        _diskCommandError = 'Не удалось подготовить доступ к Диску';
      }
      throw StateError('Не удалось подготовить доступ к Диску');
    } finally {
      _diskCommandBusy = false;
      _changed();
    }
  }

  Future<void> connectDisk(String value) async {
    if (!canConnectDisk) throw StateError('Диск уже подключён или нет прав');
    final token = value.trim();
    if (token.isEmpty ||
        token.length > 4096 ||
        token.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
      throw ArgumentError('Укажите корректный OAuth-токен');
    }
    _diskCommandBusy = true;
    _diskCommandError = null;
    _changed();
    final stagedId = _diskCredentials?['bindingId'] as String?;
    final pendingConnect =
        stagedId != null &&
        _history.knownEdits.any(
          (edit) =>
              edit.id == stagedId && edit.kind == RoomEditKind.diskConnection,
        ) &&
        !_history.durableHistory.any((edit) => edit.id == stagedId);
    final id = pendingConnect ? stagedId : createRoomId();
    try {
      if (pendingConnect) {
        await _history.flush();
        if (_disposed) return;
        _updateDiskSync();
        _shareDiskCredentials();
        if (diskBinding?.id != id) throw StateError('Подключение изменилось');
        return;
      }
      await _diskSync.prepare(id, token);
      if (_disposed || !canEdit || diskBinding != null) {
        throw StateError('Подключение комнаты изменилось');
      }
      // Stage the secret first: a failed metadata save remains an immutable,
      // retryable journal draft and must not lose the only copy of its token.
      final credentials = <String, dynamic>{
        'v': 1,
        'bindingId': id,
        'token': token,
      };
      await store.saveDiskCredentials(roomId, credentials);
      if (_disposed) return;
      _diskCredentials = credentials;
      final edit = await _history.appendDiskConnection(
        jsonEncode({'action': 'connect'}),
        id: id,
      );
      await _history.flush();
      if (_disposed) return;
      if (edit != null) _onDurableEdits([edit]);
      if (diskBinding?.id != id) {
        throw StateError('Другой редактор уже подключил Диск');
      }
      _updateDiskSync();
      _shareDiskCredentials();
    } catch (error) {
      _diskCommandError = error is YandexDiskException
          ? error.toString()
          : 'Не удалось подключить Яндекс Диск';
      throw StateError(_diskCommandError!);
    } finally {
      _diskCommandBusy = false;
      _changed();
    }
  }

  Future<void> disconnectDisk() async {
    if (!canDisconnectDisk) {
      throw StateError('Отвязать Диск может только владелец');
    }
    final binding = diskBinding!;
    _diskCommandBusy = true;
    _diskCommandError = null;
    _changed();
    try {
      final edit = await _history.appendDiskConnection(
        jsonEncode({'action': 'disconnect', 'bindingId': binding.id}),
      );
      await _history.flush();
      if (!_disposed && edit != null) _onDurableEdits([edit]);
      _updateDiskSync();
      await _diskRetirements.update(enabled: canEdit);
      // Cloud acknowledgment is independent. If offline, the persisted detach
      // and retained credential resume this final upload on the next launch.
    } catch (_) {
      _diskCommandError = 'Не удалось сохранить отвязку Диска';
      throw StateError(_diskCommandError!);
    } finally {
      _diskCommandBusy = false;
      _changed();
    }
  }

  void _shareDiskCredentials() {
    if (_disposed) return;
    _updateDiskCredentialExchange();
    if (_diskEntryPending || !canEdit || _diskCredentials == null) return;
    final binding = diskBinding;
    if (binding == null || _diskCredentials!['bindingId'] != binding.id) return;
    if (_durableRoleDocument.participantRoles[actorId] != RoomRole.editor) {
      return;
    }
    for (final state in _connections.values) {
      if (!state.ready ||
          !state.diskSync ||
          !_live(state) ||
          !state.connection.open ||
          state.actor == null ||
          (state.durableSync && !state.localAcknowledged) ||
          _durableRoleDocument.participantRoles[state.actor] !=
              RoomRole.editor ||
          state.sentDiskBinding == binding.id) {
        continue;
      }
      state.sentDiskBinding = binding.id;
      unawaited(
        _send(
          state,
          RoomMessage(
            roomId: roomId,
            type: RoomMessageType.diskCredentials,
            actor: actorId,
            history: const [],
            diskBindingId: binding.id,
            diskToken: _diskCredentials!['token'] as String,
          ),
        ),
      );
    }
  }

  Future<void> _receiveDiskCredentials(
    _RoomConnection state,
    RoomMessage message,
  ) async {
    if (!state.diskSync ||
        !canEdit ||
        _durableRoleDocument.participantRoles[actorId] != RoomRole.editor ||
        _durableRoleDocument.participantRoles[message.actor] !=
            RoomRole.editor) {
      throw const FormatException('Передача доступа к Диску не разрешена');
    }
    if (!_live(state)) return;
    await _saveReceivedDiskCredentials(
      message.diskBindingId!,
      message.diskToken!,
    );
  }

  Future<void> _saveReceivedDiskCredentials(
    String bindingId,
    String token, {
    bool propagateFailure = false,
  }) async {
    if (_disposed || !canEdit || diskBinding?.id != bindingId) return;
    if (_diskCredentials?['bindingId'] == bindingId &&
        _diskCredentials?['token'] == token) {
      return;
    }
    final credentials = <String, dynamic>{
      'v': 1,
      'bindingId': bindingId,
      'token': token,
    };
    try {
      await store.saveDiskCredentials(roomId, credentials);
      if (_disposed || !canEdit || diskBinding?.id != bindingId) return;
      _diskCredentials = credentials;
      _diskCommandError = null;
      _updateDiskSync();
      _shareDiskCredentials();
      _changed();
    } catch (_) {
      if (!_disposed) {
        _diskCommandError = 'Не удалось сохранить доступ к Диску на устройстве';
        _changed();
      }
      if (propagateFailure) throw StateError('Доступ к Диску не сохранён');
    }
  }

  void _updateDiskCredentialExchange() {
    final host = _hostConnection;
    _diskCredentialExchange.update(
      enabled:
          !_disposed &&
          !_diskEntryPending &&
          canEdit &&
          !_isTabFollower &&
          diskBinding != null &&
          _durableRoleDocument.participantRoles[actorId] == RoomRole.editor &&
          host != null &&
          host.ready &&
          _live(host) &&
          _durableRoleDocument.participantRoles[host.actor] == RoomRole.guest,
      editorActors: _durableRoleDocument.participantRoles.entries
          .where((entry) => entry.value == RoomRole.editor)
          .map((entry) => entry.key),
    );
  }

  Future<void> syncDisk() async {
    if (!canEdit) throw StateError('Синхронизация доступна редактору');
    _diskCommandError = null;
    await _loadDiskCredentials();
    _updateDiskSync();
    if (diskBinding != null) {
      await _diskSync.sync();
    } else {
      await _diskRetirements.sync();
    }
  }

  bool get canBindToPerson => canEdit && boundPersonId == null;
  bool get canUnbindFromPerson => canEdit && boundPersonId != null;

  Future<void> editTreeText(
    String personId,
    TreeTextField field,
    String value, {
    String? itemId,
    TreeTextSnapshot? base,
  }) {
    if (!canEdit) {
      return Future.error(StateError('Только редактор может изменять дерево'));
    }
    final operation = tree.editText(
      personId,
      field,
      value,
      itemId: itemId,
      base: base,
    );
    return operation == null ? Future.value() : applyTreeOperation(operation);
  }

  Future<void> applyTreeOperation(TreeOperation operation) {
    if (!canEdit) {
      return Future.error(StateError('Только редактор может изменять дерево'));
    }
    try {
      _validateTreeCommand(operation);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    return _appendTreeOperation(operation);
  }

  void _validateTreeCommand(TreeOperation operation) {
    final document = tree;
    final id = operation.personId;
    final item = operation.itemId;
    final data = operation.toJson();
    if (operation.type != 'createPerson' &&
        operation.type != 'createSibling' &&
        operation.type != 'unbindActor' &&
        document.person(id) == null) {
      throw ArgumentError('Человек не найден в дереве');
    }
    switch (operation.type) {
      case 'createPerson':
        document.createPerson(id);
      case 'createSibling':
        document.createSibling(
          data['siblingId']! as String,
          id,
          name: data['name']! as String,
          sex: TreeSex.values.byName(data['sex']! as String),
          birthDate: data['birthDate'] == null
              ? null
              : DateTime.parse(data['birthDate']! as String),
        );
      case 'unlinkSibling':
        final link = document.directSiblingLinks
            .where(
              (link) =>
                  link.id == data['linkId'] &&
                  ((link.personId == id &&
                          link.siblingId == data['siblingId']) ||
                      (link.siblingId == id &&
                          link.personId == data['siblingId'])),
            )
            .firstOrNull;
        if (link == null) throw ArgumentError('Прямая связь уже изменилась.');
      case 'deletePerson':
        document.deletePerson(id);
      case 'setValue':
        document.setValue(id, data['field']! as String, data['value']);
      case 'setSurname':
        if (data['scope'] == 'family') {
          throw ArgumentError(
            'Фамилия изменяется только у выбранного человека.',
          );
        }
      case 'editText':
        document.textSnapshot(
          id,
          TreeTextField.values.byName(data['field']! as String),
          itemId: item,
        );
      case 'addFact':
        document.addFact(
          id,
          item!,
          text: data['text']! as String,
          color: data['color']! as String,
        );
      case 'setFactColor':
        document.setFactColor(id, item!, data['color']! as String);
      case 'removeFact':
        document.removeFact(id, item!);
      case 'moveFact':
        document.moveFact(
          id,
          item!,
          afterId: data['afterId'] as String?,
          beforeId: data['beforeId'] as String?,
        );
      case 'addPhoto':
        document.addPhoto(
          id,
          item!,
          dataUrl: data['dataUrl']! as String,
          caption: data['caption']! as String,
        );
      case 'removePhoto':
        document.removePhoto(id, item!);
      case 'movePhoto':
        document.movePhoto(
          id,
          item!,
          afterId: data['afterId'] as String?,
          beforeId: data['beforeId'] as String?,
        );
      case 'bindActor':
        if (data['actorId'] != actorId ||
            document.bindings.containsKey(actorId)) {
          throw StateError(
            'Можно привязать только собственный свободный профиль',
          );
        }
      case 'unbindActor':
        if (data['actorId'] != actorId ||
            !document.bindings.containsKey(actorId)) {
          throw StateError('Можно отменить только собственную привязку');
        }
        final current = document.unbindActor(actorId).toJson();
        if (current['bindingId'] != data['bindingId'] ||
            current['personId'] != id) {
          throw StateError('Привязка изменилась. Откройте профиль заново.');
        }
    }
  }

  Future<void> _appendTreeOperation(TreeOperation operation) {
    final payload = jsonEncode(operation.toJson());
    // Never accept a locally stored photo/edit which cannot leave this device.
    for (final edit in _history.knownEdits) {
      if (_sizedEditIds.add(edit.id)) {
        _historyBytes += utf8.encode(jsonEncode(edit.toJson())).length + 1;
      }
    }
    final projectedBytes =
        _historyBytes +
        utf8
            .encode(
              jsonEncode({
                'text': payload,
                'kind': 'tree',
                'id': createRoomId(),
                'author': actorId,
              }),
            )
            .length +
        1;
    if (projectedBytes > maxTransferBytes - 32768) {
      return Future.error(
        StateError(
          'История превысит лимит обмена 8 МБ. Уменьшите размер фотографий.',
        ),
      );
    }
    final saved = _history.appendTreeOperation(payload);
    return saved.then((edit) async {
      if (edit == null) {
        throw StateError(_history.error ?? 'Изменение не сохранено');
      }
      await _history.flush();
      if (!_disposed) _onDurableEdits([edit]);
    });
  }

  Future<void> bindToPerson(String personId) {
    if (!canEdit) {
      return Future.error(
        StateError('Только редактор может привязать профиль к человеку'),
      );
    }
    if (!canBindToPerson || tree.person(personId) == null) {
      return Future.error(
        StateError('Привязка уже выполнена или узел недоступен'),
      );
    }
    // Use optimistic state too: double submission cannot choose another node
    // while an immutable binding is awaiting its durable write.
    if (tree.bindings.containsKey(actorId)) return flush();
    return applyTreeOperation(tree.bindActor(actorId, personId));
  }

  /// Appends a release of the durable own claim; never rewrites old history or
  /// releases other actors grouped under the same person. Deleted targets can
  /// still be released. A failed optimistic release remains retryable by flush.
  Future<void> unbindFromPerson() {
    if (!canEdit) {
      return Future.error(
        StateError('Только редактор может отменить привязку профиля'),
      );
    }
    if (!canUnbindFromPerson) {
      return Future.error(StateError('Профиль не привязан к человеку'));
    }
    if (!tree.bindings.containsKey(actorId)) return flush();
    return applyTreeOperation(durableTree.unbindActor(actorId));
  }

  /// Confirmed application connectivity, not an Internet/cloud availability
  /// test. A working RTC channel survives a public signaling outage.
  bool get networkAvailable {
    if (_disposed || !_networkOnlineHint) return false;
    if (_isTabFollower) {
      // A leader's negative connectivity update revokes stale online evidence
      // even while this tab cannot verify a newer durable inventory.
      if (_tabState?.networkAvailable == false) return false;
      return _verifiedTabState?.networkAvailable ?? false;
    }
    final peer = _peer;
    return hasValidatedOnlinePeer ||
        (_signalingReady &&
            !_peerFailed &&
            peer != null &&
            peer.open &&
            !peer.disconnected);
  }

  Set<String> get _onlineActors {
    if (!_joined || !networkAvailable) return const {};
    if (_isTabFollower) {
      final verified = _verifiedTabState?.onlineActors?.toSet() ?? {actorId};
      final current = _tabState?.onlineActors;
      // New identities require a verified durable checkpoint, but a negative
      // presence update must not leave a disconnected identity online while a
      // local disk error prevents verification of the leader's newer journal.
      return current == null
          ? verified
          : verified.intersection(current.toSet());
    }
    if (_hosting) {
      return {
        actorId,
        for (final state in _connections.values)
          if (state.ready &&
              state.connection.open &&
              _live(state) &&
              state.actor != null)
            state.actor!,
      };
    }
    final host = _hostConnection;
    if (host != null &&
        host.ready &&
        host.connection.open &&
        _live(host) &&
        host.actor != null) {
      return {...?_remoteActors, actorId, host.actor!};
    }
    return {actorId};
  }

  // Retain legacy guest claims in history, but only editors use person identity.
  String? _boundEditorPersonId(String actor) =>
      _durableRoleDocument.roleFor(actor) == RoomRole.editor
      ? durableTree.bindings[actor]
      : null;

  /// Other online identities: local tabs and this participant are not counted.
  String _participantIdentity(String actor) {
    final person = _boundEditorPersonId(actor);
    return person == null ? 'actor:$actor' : 'person:$person';
  }

  int get otherOnlineCount => _onlineActors
      .map(_participantIdentity)
      .where((identity) => identity != _participantIdentity(actorId))
      .toSet()
      .length;

  List<RoomParticipant> get participants {
    if (!_joined) return const [];
    final names = _history.participantNames;
    final roles = _durableRoleDocument;
    final online = _onlineActors;
    final actors = {
      ...names.keys,
      ...roles.participantRoles.keys,
      ...online,
      actorId,
    };
    final groups = <String, List<String>>{};
    for (final actor in {...actors, ...durableTree.bindings.keys}) {
      groups.putIfAbsent(_participantIdentity(actor), () => []).add(actor);
    }
    final result = <RoomParticipant>[];
    for (final group in groups.values) {
      group.sort();
      final self = group.contains(actorId);
      // A self row always represents this actor's alias, not another device's.
      // Otherwise select the first nonempty alias in stable actor-ID order.
      final actor = self
          ? actorId
          : group.firstWhere(
              (member) => names[member]?.trim().isNotEmpty == true,
              orElse: () => group.first,
            );
      final personId = _boundEditorPersonId(actor);
      final person = personId == null ? null : durableTree.person(personId);
      String? avatar;
      if (person != null) {
        for (final photo in person.photos) {
          if (photo.id == person.avatarPhotoId) avatar = photo.dataUrl;
        }
      }
      result.add(
        RoomParticipant(
          actorId: actor,
          name: names[actor]?.trim().isNotEmpty == true
              ? names[actor]!.trim()
              : person?.name.trim().isNotEmpty == true
              ? person!.name.trim()
              : 'Аноним',
          isOnline: group.any(online.contains),
          isSelf: self,
          role: group.any((member) => roles.roleFor(member) == RoomRole.editor)
              ? RoomRole.editor
              : RoomRole.guest,
          personId: personId,
          boundPersonFullName: person?.fullName,
          avatarDataUrl: avatar,
        ),
      );
    }
    result.sort((a, b) {
      if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
      final nameOrder = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return nameOrder != 0 ? nameOrder : a.actorId.compareTo(b.actorId);
    });
    return List.unmodifiable(result);
  }

  int get historyLength => _history.historyLength;
  bool get saving => _history.saving;
  int get savingCount => _history.savingCount;
  String? get error => _error;
  String? get storageError => _history.error;
  String get signalingService => _peer?.service ?? '';

  /// Current validated welcome on a live outbound channel, not saved membership
  /// or signaling discovery. Advisory reload hints must not grant admission.
  bool get connectedToRemoteHost {
    final host = _hostConnection;
    return !_hosting &&
        host != null &&
        host.ready &&
        host.actor != null &&
        host.connection.open &&
        _live(host);
  }

  /// A validated online identity other than this device, on either host/follower
  /// channels. This also covers a previous alias owner reloading as a follower.
  bool get hasValidatedOnlinePeer => _connections.values.any(
    (state) =>
        state.ready &&
        state.actor != null &&
        state.actor != actorId &&
        state.connection.open &&
        _live(state),
  );

  int get logLength => _log.length;
  List<String> get log => List.unmodifiable(_log);

  /// Counts validated identities, not transport channels or same-origin tabs.
  int get onlineCount {
    if (!_joined) return 0;
    if (_isTabFollower) {
      if (_verifiedTabState?.onlineActors != null) {
        return max(1, _onlineActors.length);
      }
      return _verifiedTabState?.onlineCount ?? 1;
    }
    if (_hosting) {
      return {
        actorId,
        for (final state in _connections.values)
          if (state.ready &&
              state.connection.open &&
              _live(state) &&
              state.actor != null)
            state.actor!,
      }.length;
    }
    return _hostConnection?.ready == true && _live(_hostConnection!)
        ? _remoteOnline
        : 1;
  }

  String get status {
    if (_localCopyOpened && !_initialSyncComplete) {
      return 'Локальная копия · первичная синхронизация не подтверждена';
    }
    if (!_joined) {
      return _error == null ? 'Вход в комнату…' : 'Не удалось войти в комнату';
    }
    if (!_history.loaded) return 'Не удалось прочитать сохранённую историю';
    if (onlineCount > 1) return 'Онлайн · участников: $onlineCount';
    if (_isTabFollower) {
      final leader = _verifiedTabState;
      return leader == null
          ? 'Локально · проверяем соседнюю вкладку…'
          : 'Локально · ${leader.status}';
    }
    if (_hosting && _signalingReady) return 'Комната готова';
    return saving
        ? 'Офлайн · сохраняем изменения…'
        : 'Офлайн · комната доступна на устройстве';
  }

  /// Loads accepted local history and starts signaling, not the join handshake.
  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() async {
    if (_disposed) return;
    _networkSubscription = watchNetworkOnlineHint().listen((online) {
      if (_disposed || _networkOnlineHint == online) return;
      _networkOnlineHint = online;
      _changed();
      if (online) resume();
    });
    _foregroundSubscription = watchApplicationForeground().listen(
      setForeground,
    );
    _beginInitialWait();
    final attempt = _entryAttempt;
    if (!_admissionHistoryLoaded && (_joined || invitationRole != null)) {
      if (!await _loadEntryHistory()) return;
    }
    if (!await _enterFromDisk(attempt)) return;
    if (_disposed || attempt != _entryAttempt) return;
    if (_joined && _needsEntryProfile && !await _ensureEntryProfile()) return;
    if (_joined) unawaited(_loadDiskCredentials());
    if (newlyCreated && _joined) _completeInitialSync();
    if (_joined && roomTabs != null) {
      await _activateTabs();
    } else {
      _startNetwork();
    }
  }

  Future<bool> _loadEntryHistory() async {
    if (_disposed) return false;
    if (!_admissionHistoryLoaded && (_joined || invitationRole != null)) {
      // An earlier valid welcome may have saved the profile but failed its
      // membership write. Read it before choosing an invitation role again.
      final initialHistory = _entryHistory;
      _entryHistory = null;
      await _history.load(initialHistory: initialHistory);
      if (_disposed) return false;
      if (!_history.loaded || _history.error != null) {
        _failInitialSync(_history.error ?? 'Не удалось прочитать историю');
        return false;
      }
      _admissionHistoryLoaded = true;
    }
    return _history.loaded;
  }

  void _validateDiskEntryHistory(
    List<RoomEdit> history,
    RoomDiskAccess access, {
    bool allowFinalDisconnect = false,
  }) {
    var binding = DiskBinding.project(history);
    if (binding == null && allowFinalDisconnect) {
      // Only an established matching public reader may import its terminal
      // snapshot. Prove that the exact disconnect actually closes this binding,
      // rather than accepting an ignored disconnect or another binding's end.
      final connections =
          history
              .where((edit) => edit.kind == RoomEditKind.diskConnection)
              .toList()
            ..sort((left, right) => left.compareTo(right));
      for (var index = 0; index < connections.length; index++) {
        final payload = jsonDecode(connections[index].text) as Map;
        if (payload['action'] != 'disconnect' ||
            payload['bindingId'] != access.bindingId) {
          continue;
        }
        final previous = DiskBinding.project(connections.take(index));
        if (previous?.id == access.bindingId) {
          binding = previous;
          break;
        }
      }
    }
    final roles = RoomDocument()..merge(history);
    if (binding?.id != access.bindingId ||
        roles.participantRoles[binding!.ownerActor] != RoomRole.editor) {
      throw const FormatException('Подключение Диска не подтверждено');
    }
  }

  /// Shares the journal/admission queue with RTC and storage refreshes, but runs
  /// before starting either network or the write-capable Disk replica.
  Future<bool> _enterFromDisk(int attempt) {
    bool current() =>
        !_disposed && attempt == _entryAttempt && _initialSyncError == null;
    final result = _messages.then((_) async {
      if (!current()) return false;
      RoomDiskAccess? access = invitationDiskAccess;
      try {
        final binding = diskBinding;
        final acceptedGuest = _joined && ownRole == RoomRole.guest;
        if (access == null && _joined && binding != null) {
          if (ownRole == RoomRole.editor) {
            final saved = await store.loadDiskCredentials(
              roomId,
              bindingId: binding.id,
            );
            if (!current()) return false;
            if (saved != null) {
              final stored = RoomDiskAccess.fromJson(saved);
              if (stored.isEditor && stored.bindingId == binding.id) {
                access = stored;
              }
            }
          }
          if (access == null) {
            final saved = await store.loadDiskPublicAccess(roomId);
            if (!current()) return false;
            if (saved != null) {
              final stored = RoomDiskAccess.fromJson(saved);
              if (!stored.isEditor && stored.bindingId == binding.id) {
                access = stored;
              }
            }
          }
        }
        if (access == null) return true;
        _diskEntryReading = true;
        _changed();
        final entryAccess = access;
        final allowFinalDisconnect =
            acceptedGuest &&
            !entryAccess.isEditor &&
            binding?.id == entryAccess.bindingId;
        void validateEntryHistory(List<RoomEdit> edits) =>
            _validateDiskEntryHistory(
              edits,
              entryAccess,
              allowFinalDisconnect: allowFinalDisconnect,
            );
        final history = await readDiskRoomHistory(
          client: _diskClient,
          roomId: roomId,
          access: entryAccess,
          localHistory: _history.durableHistory,
          isCurrent: current,
          timeout: _joinDeadline,
          allowFinalDisconnect: allowFinalDisconnect,
        );
        if (!current()) return false;
        validateEntryHistory(history);
        final added = await _history.merge(history);
        if (!current()) return false;
        if (added == null) throw StateError('История с Диска не сохранена');
        await _history.flush();
        if (!current()) return false;
        validateEntryHistory(_history.durableHistory);
        if (!await _ensureEntryProfile(stillAdmissible: current)) return false;
        if (!current()) return false;

        // Durable roles, including roles saved by an earlier failed admission,
        // always win over a newly opened invitation. Never retain its editor
        // token for an actor whose existing role is guest.
        final retainsToken =
            ownRole == RoomRole.editor &&
            _durableRoleDocument.participantRoles[actorId] == RoomRole.editor;
        if (retainsToken && entryAccess.isEditor) {
          await store.saveDiskCredentials(roomId, entryAccess.toJson());
          if (!current()) return false;
        } else if (!entryAccess.isEditor) {
          await store.saveDiskPublicAccess(roomId, entryAccess.toJson());
          if (!current()) return false;
        }
        if (ownRole == RoomRole.guest) _diskCredentials = null;
        await _history.flush();
        if (!current()) return false;
        validateEntryHistory(_history.durableHistory);
        if (!_joined) {
          if (!await _history.saveMembership(stillAdmissible: current)) {
            throw StateError('Участие не сохранено');
          }
          if (!current()) return false;
          _joined = true;
          _joinTimer?.cancel();
          _history.watchAcceptedHistory();
        }
        // Recheck the accepted durable copy (and clear a recovered membership
        // write error) without authoring anything after the membership commit.
        await _history.refresh();
        if (!current()) return false;
        if (_history.error != null) {
          throw StateError('Не удалось проверить сохранённую историю');
        }
        validateEntryHistory(_history.durableHistory);
        if (retainsToken && entryAccess.isEditor) {
          _diskCredentials = entryAccess.toJson();
        } else if (!entryAccess.isEditor) {
          _diskPublicAccess = entryAccess;
        }
        _diskEntryError = null;
        _completeInitialSync(fromDisk: true);
        return true;
      } catch (_) {
        if (_disposed || attempt != _entryAttempt) return false;
        // External failures can contain tokens, URLs, or raw JSON. Keep cloud
        // errors safe and independent from the ordinary online admission path.
        _diskEntryError =
            'Не удалось открыть подтверждённую историю с Диска. '
            'Можно повторить проверку или дождаться онлайн-участника.';
        _failInitialSync(
          _history.error ?? _initialSyncError ?? _diskEntryError!,
        );
        return true;
      } finally {
        if (!_disposed && attempt == _entryAttempt) {
          _diskEntryReading = false;
          _diskEntryPending = false;
          _updateDiskSync();
          _changed();
        }
      }
    });
    _messages = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  bool get _needsEntryProfile =>
      !_entryProfileSaved &&
      (_entryParticipantName != null ||
          (invitationRole != null && (!_joined || newlyCreated)));

  Future<bool> _ensureEntryProfile({bool Function()? stillAdmissible}) async {
    if (!_needsEntryProfile) return true;
    if (stillAdmissible != null && !stillAdmissible()) return false;
    try {
      // Profiles are authored operations too: only the journal's allocator can
      // finalize their shared-tab sequence and immutable predecessor proof.
      // Existing explicit roles still beat a newly opened invitation.
      final saved = <RoomEdit>[];
      final name = _entryParticipantName;
      if (name != null) {
        final edit = await _history.setParticipantName(name);
        if (edit != null) saved.add(edit);
      }
      if (invitationRole != null &&
          (!_joined || newlyCreated) &&
          !_history.participantRoles.containsKey(actorId)) {
        final edit = await _history.setParticipantRole(
          actorId,
          newlyCreated ? RoomRole.editor : invitationRole!,
        );
        if (edit != null) saved.add(edit);
      }
      await _history.flush();
      if (_disposed || (stillAdmissible != null && !stillAdmissible())) {
        return false;
      }
      _entryProfileSaved = true;
      if (_joined && saved.isNotEmpty) _onDurableEdits(saved);
      return true;
    } catch (error) {
      if (!_disposed) {
        _failInitialSync(
          _history.error ?? 'Не удалось сохранить профиль: $error',
        );
      }
      return false;
    }
  }

  bool get _isTabFollower => _tabsActive && !_networkOwner;
  bool get _networkOwner =>
      !_tabsActive ||
      (_tabsStarting && _running) ||
      (_tabLeader && roomTabs!.isLeader);

  Future<void> _activateTabs({bool retainNetwork = false}) async {
    final tabs = roomTabs;
    if (_disposed ||
        !_joined ||
        !_history.loaded ||
        tabs == null ||
        _tabsActive ||
        _tabsStarting) {
      return;
    }
    _tabsStarting = true;
    _tabsActive = true;
    _tabSubscriptions.add(
      tabs.onRoleChanged.listen((_) {
        if (!_disposed && !_tabsStarting) _applyTabRole();
      }, onError: _tabError),
    );
    _tabSubscriptions.add(
      tabs.onState.listen(_receiveTabState, onError: _tabError),
    );
    try {
      await tabs.start();
      if (_disposed) return;
      _tabsStarting = false;
      _applyTabRole(first: true, retainNetwork: retainNetwork);
    } catch (error) {
      _tabsStarting = false;
      _stopNetwork();
      _tabError(error);
    }
  }

  void _stopNetwork() {
    _running = false;
    _joinTimer?.cancel();
    _heartbeatTimer?.cancel();
    _lastHeartbeatAt = null;
    _retirePeer();
  }

  void _applyTabRole({bool first = false, bool retainNetwork = false}) {
    if (_disposed || !_tabsActive) return;
    _tabTerm++;
    _tabLeader = roomTabs!.isLeader;
    _tabState = null;
    _verifiedTabState = null;
    _publishedTabState = null;
    _tabPublishTimer?.cancel();
    _tabPublishTimer = null;
    _tabVerifyTimer?.cancel();
    _tabVerifyTimer = null;
    // A new local owner has no inherited remote proof. Ordinary snapshots in
    // the same term do not undo latched readiness; election/retry does.
    if (!first || (_running && !_tabLeader)) _beginInitialWait();
    if (_tabLeader) {
      if (!(first && retainNetwork && _running)) {
        _stopNetwork();
        _startNetwork();
      }
      _changed();
    } else {
      _stopNetwork();
      _requestTabState();
      _changed();
    }
  }

  void _tabError(Object error) {
    if (_disposed) return;
    _tabState = null;
    _verifiedTabState = null;
    _initialSyncComplete = false;
    _localCopyOpened = false;
    _failInitialSync('Не удалось проверить соседнюю вкладку: $error');
  }

  void _requestTabState() {
    try {
      roomTabs?.requestState();
    } catch (error) {
      _tabError(error);
    }
  }

  void _receiveTabState(RoomTabState state) {
    if (_disposed ||
        !_isTabFollower ||
        state.roomId != roomId ||
        state.actorId != actorId ||
        state.onlineCount < 1) {
      return;
    }
    _tabState = state;
    _changed();
    _scheduleTabVerification();
  }

  void _scheduleTabVerification() {
    if (_disposed || !_isTabFollower || _tabState == null) return;
    // Never recursively refresh/publish from RoomHistory.onChanged. Only a new
    // beacon or durable additions schedule this bounded, serialized read.
    _tabVerifyTimer ??= Timer(const Duration(milliseconds: 35), () {
      _tabVerifyTimer = null;
      final term = _tabTerm;
      _messages = _messages.then((_) async {
        if (_disposed || !_isTabFollower || term != _tabTerm) return;
        final state = _tabState;
        if (state == null) return;
        await _history.refresh();
        if (_disposed ||
            !_isTabFollower ||
            term != _tabTerm ||
            !identical(state, _tabState) ||
            _history.error != null) {
          return;
        }
        _verifyTabState(state);
      });
    });
  }

  Map<String, String> get _durableTabInventory {
    // Immutable append-only journal: only durable additions change this map.
    if (_tabInventoryLength != _history.durableLength) {
      _tabInventory = roomHistoryInventory(_history.durableHistory);
      _tabInventoryLength = _history.durableLength;
    }
    return _tabInventory;
  }

  void _verifyTabState(RoomTabState state) {
    if (_disposed ||
        !_isTabFollower ||
        !identical(state, _tabState) ||
        !_joined ||
        !_history.loaded ||
        _history.error != null) {
      return;
    }
    final durable = _durableTabInventory;
    if (!state.inventory.entries.every(
      (entry) => durable[entry.key] == entry.value,
    )) {
      return;
    }
    _verifiedTabState = state;
    if (state.initialSyncComplete) {
      _completeInitialSync();
    } else if (!_initialSyncComplete) {
      _initialSyncError = state.initialSyncError;
      if (state.localCopyOpened) _localCopyOpened = true;
    }
    _changed();
  }

  bool get _currentTabEntryReady {
    if (!_initialSyncComplete) return false;
    // A random freshly created, never-shared room has an explicit solo proof,
    // even if public signaling is offline. Any real/pending cohort overrides it.
    if (newlyCreated && !_validatedRemoteSeen && _connections.isEmpty) {
      return true;
    }
    if (_hosting) {
      return _settledHosting &&
          _hostBarrierReachable &&
          _cohortImported &&
          _initialCohort.every((state) => state.localAcknowledged);
    }
    final host = _hostConnection;
    return host != null &&
        _live(host) &&
        host.ready &&
        host.remoteImported &&
        host.localAcknowledged &&
        host.remoteRoomReady;
  }

  void _scheduleTabPublish() {
    if (_disposed || !_tabsActive || !_networkOwner || _tabsStarting) return;
    _tabPublishTimer ??= Timer(const Duration(milliseconds: 35), () {
      _tabPublishTimer = null;
      if (_disposed || !_tabsActive || !_networkOwner || _tabsStarting) return;
      final state = RoomTabState(
        roomId: roomId,
        actorId: actorId,
        onlineCount: onlineCount,
        onlineActors: _onlineActors.toList()..sort(),
        networkAvailable: networkAvailable,
        // Existing UI readiness is latched, but a newly opened sibling must
        // not bypass a currently pending host cohort with that older latch.
        initialSyncComplete: _currentTabEntryReady,
        localCopyOpened: localCopyOpened,
        status: status,
        initialSyncStatus: initialSyncStatus,
        initialSyncError: initialSyncError,
        inventory: _durableTabInventory,
      );
      final previous = _publishedTabState;
      if (previous != null &&
          previous.onlineCount == state.onlineCount &&
          previous.networkAvailable == state.networkAvailable &&
          listEquals(previous.onlineActors, state.onlineActors) &&
          previous.initialSyncComplete == state.initialSyncComplete &&
          previous.localCopyOpened == state.localCopyOpened &&
          previous.status == state.status &&
          previous.initialSyncStatus == state.initialSyncStatus &&
          previous.initialSyncError == state.initialSyncError &&
          mapEquals(previous.inventory, state.inventory)) {
        return;
      }
      _publishedTabState = state;
      try {
        roomTabs!.publish(state);
      } catch (error) {
        _tabError(error);
      }
    });
  }

  void _beginInitialWait() {
    _entryAttempt++;
    _initialTimer?.cancel();
    _initialSyncComplete = false;
    _initialSyncFromDisk = false;
    _localCopyOpened = false;
    _initialSyncError = null;
    _soloCheckpoint = null;
    _failedInitialConnection = false;
    final attempt = _entryAttempt;
    _initialTimer = Timer(_joinDeadline, () {
      if (_disposed || attempt != _entryAttempt || _initialSyncComplete) return;
      final detail =
          _networkIssue ?? 'Нет подтверждения сохранения от онлайн-участников.';
      _failInitialSync(
        'Не удалось проверить полную историю за 30 секунд. '
        '$detail${detail.endsWith('.') ? '' : '.'} '
        'Можно повторить проверку или открыть принятую локальную копию.',
      );
    });
    _changed();
  }

  void _failInitialSync(String reason) {
    if (_disposed || _initialSyncComplete) return;
    _initialSyncError = reason;
    _initialTimer?.cancel();
    _record(reason);
    _changed();
  }

  void _completeInitialSync({bool fromDisk = false}) {
    if (_disposed || !_joined || !_history.loaded) return;
    if (!fromDisk &&
        _diskEntryError != null &&
        !hasValidatedOnlinePeer &&
        !_isTabFollower) {
      return;
    }
    if (_initialSyncComplete) {
      // Cloud readiness is not an RTC acknowledgment. Only the unmodified
      // cohort/checkpoint paths may later replace its source with peer proof.
      if (!fromDisk && _initialSyncFromDisk && hasValidatedOnlinePeer) {
        _initialSyncFromDisk = false;
        _changed();
      }
      return;
    }
    _initialSyncFromDisk = fromDisk;
    _initialSyncComplete = true;
    _localCopyOpened = false;
    _initialSyncError = null;
    _initialTimer?.cancel();
    _record(
      fromDisk
          ? 'История загружена с Диска; онлайн-сверка продолжается'
          : 'Первичная проверка истории завершена',
    );
    _changed();
    // A first join cannot participate in local election before its actual
    // welcome, membership write and durable checkpoint exchange completed.
    // The winner keeps this already-verified network; the loser retires it.
    if (_networkStarted && !_tabsActive && !_tabsStarting) {
      unawaited(_activateTabs(retainNetwork: true));
    }
  }

  /// Visibility is a reason to check connectivity, never proof of an online peer.
  void setForeground(bool foreground) {
    if (_disposed) return;
    if (!foreground) {
      _backgroundedAt ??= now();
      return;
    }
    final hiddenAt = _backgroundedAt;
    _backgroundedAt = null;
    if (hiddenAt != null &&
        (now().difference(hiddenAt) >= const Duration(seconds: 3) ||
            !networkAvailable)) {
      resume();
    }
  }

  /// Wake up discovery after suspension without resetting durable entry state
  /// or retiring channels which still answer the ordinary presence heartbeat.
  void resume() {
    if (_disposed || !_joined || !_history.loaded || !_networkOnlineHint) {
      return;
    }
    _diskSync.schedule();
    _diskReadSync.schedule();
    _resumeTimer ??= Timer(
      const Duration(milliseconds: 200),
      _checkAfterResume,
    );
  }

  void _checkAfterResume() {
    _resumeTimer = null;
    if (_disposed || !_joined || !_networkOnlineHint) return;
    if (_isTabFollower) {
      _requestTabState();
      return;
    }
    if (!_running || !_networkOwner) return;
    final generation = _generation;
    final probes = <_RoomConnection, int>{};
    for (final state in _connections.values.toList()) {
      final connectivity = state.connection.connectivity;
      if (!_live(state) ||
          connectivity == ChannelConnectivity.failed ||
          connectivity == ChannelConnectivity.closed ||
          (state.opened && !state.connection.open)) {
        _dropConnection(state, 'Проверка связи после пробуждения');
      } else if (state.ready &&
          !_checkpointPending(state) &&
          !state.decoder.assembling) {
        // Admission and real history transfers retain their fixed protocol
        // deadlines. A wake probe must not evict them after only six seconds.
        probes[state] = state.receivedPackets;
        unawaited(
          _send(
            state,
            _message(
              RoomMessageType.presence,
              const [],
              online: onlineCount,
              hosting: _hosting && _signalingReady,
            ),
          ),
        );
      }
    }
    if (probes.isEmpty) {
      if (_connections.isEmpty) _resumePeer();
      return;
    }
    // The other device need not have resumed: allow its regular 5s heartbeat
    // before declaring a channel silent. Successful send alone is not an ACK.
    _resumeTimer = Timer(const Duration(seconds: 6), () {
      _resumeTimer = null;
      if (!_current(generation)) return;
      for (final entry in probes.entries) {
        if (_live(entry.key) &&
            !_checkpointPending(entry.key) &&
            !entry.key.decoder.assembling &&
            entry.key.receivedPackets == entry.value) {
          _dropConnection(entry.key, 'Участник не ответил после пробуждения');
        }
      }
      // A newly arriving peer may still be saving its welcome/hello. Its own
      // handshake/assembly deadline must finish before another election.
      if (_connections.isEmpty) _resumePeer();
    });
  }

  void _resumePeer() {
    if (_disposed || !_running || !_networkOwner || !_networkOnlineHint) return;
    final startedAt = _peerStartedAt;
    if (!_peerFailed &&
        !_registered &&
        _peer != null &&
        startedAt != null &&
        now().difference(startedAt) < _registrationDeadline) {
      return;
    }
    _retryAttempt = 0;
    _record('Восстанавливаем поиск участников после пробуждения');
    _beginPeer(tryAlias: _joined);
  }

  /// Also useful after an initial join deadline. Saved rooms reconnect by
  /// themselves; a failed fresh join remains unaccepted until retried.
  Future<void> retry() async {
    if (_disposed) return;
    _diskEntryPending = true;
    _updateDiskSync();
    if (_networkStarted) _stopNetwork();
    _beginInitialWait();
    final attempt = _entryAttempt;
    _error = null;
    _networkIssue = null;
    _retryAttempt = 0;
    if (!_admissionHistoryLoaded && (_joined || invitationRole != null)) {
      if (!await _loadEntryHistory()) return;
    }
    if (!await _enterFromDisk(attempt)) return;
    if (_disposed || attempt != _entryAttempt) return;
    if (_joined && _needsEntryProfile && !await _ensureEntryProfile()) return;
    if (_joined) unawaited(_loadDiskCredentials());
    if (_isTabFollower) {
      _tabState = null;
      _verifiedTabState = null;
      _requestTabState();
      return;
    }
    if (!_tabsActive && _joined && roomTabs != null) {
      await _activateTabs();
    } else {
      _startNetwork();
    }
  }

  void _startNetwork() {
    if (_disposed || !_networkOwner) return;
    final tryAlias = _joined && (_networkStarted || !preferExistingHost);
    _networkStarted = true;
    final configurationError = iceConfiguration.validationError;
    if (configurationError != null) {
      _error = configurationError;
      _failInitialSync(configurationError);
      _changed();
      return;
    }
    _running = true;
    _joinTimer?.cancel();
    if (!_joined) {
      _joinTimer = Timer(_joinDeadline, () {
        if (_disposed || _joined || !_running) return;
        final detail =
            _networkIssue ??
            'Нет онлайн-участника или WebRTC-канал недоступен.';
        _error =
            'Не удалось войти за 30 секунд. '
            '$detail${detail.endsWith('.') ? '' : '.'} '
            'Можно повторить вход.';
        _running = false;
        _heartbeatTimer?.cancel();
        _retirePeer();
        _record(_error!);
        _failInitialSync(_error!);
        _changed();
      });
    }
    _heartbeatTimer?.cancel();
    _lastHeartbeatAt = now();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed || !_running) return;
      final tick = now();
      final previous = _lastHeartbeatAt;
      _lastHeartbeatAt = tick;
      if (previous != null && tick.difference(previous) > _livenessDeadline) {
        resume();
      }
      for (final state in _connections.values.toList()) {
        if (!_live(state)) {
          _dropConnection(state, 'WebRTC-канал закрыт');
        } else if (state.ready) {
          unawaited(
            _send(
              state,
              _message(
                RoomMessageType.presence,
                const [],
                online: onlineCount,
                hosting: _hosting && _signalingReady,
              ),
            ),
          );
        }
      }
    });
    _beginPeer(tryAlias: tryAlias);
  }

  bool _current(int generation) =>
      !_disposed && _networkOwner && _running && generation == _generation;
  bool _live(_RoomConnection state) =>
      !_disposed &&
      _networkOwner &&
      identical(_connections[state.connection], state) &&
      state.generation == _generation &&
      !state.connection.disposed;

  void _beginPeer({required bool tryAlias}) {
    if (_disposed || !_running) return;
    _retirePeer();
    final generation = _generation;
    _peerStartedAt = now();
    _hosting = tryAlias;
    _requestedId = tryAlias ? hostAlias : createRoomId();
    _registered = false;
    _signalingReady = false;
    _peerFailed = false;
    _registrationTimer = Timer(_registrationDeadline, () {
      if (_current(generation) && !_registered) {
        _reconnect('Signaling не подтвердил регистрацию');
      }
    });
    _record(tryAlias ? 'Пробуем стать хостом комнаты' : 'Ищем онлайн-хоста');
    _changed();
    if (!_current(generation)) return;

    // Adapters own their transport lifecycle; only our current generation may
    // elect an alias holder or restore room readiness. Keep asynchronous startup
    // failures scoped to that generation as well.
    runZonedGuarded(
      () {
        final peer = peerFactory(
          _requestedId,
          iceConfiguration.toRtcConfiguration(),
        );
        if (!_current(generation)) {
          _disposeLater(peer: peer);
          return;
        }
        _peer = peer;
        if (peer is SignalingDiscovery) {
          final discovery = peer as SignalingDiscovery;
          _peerSubscriptions.add(
            discovery.onDiscoveryChanged.listen((_) {
              if (_current(generation) && !_peerFailed) {
                final lostCoverage =
                    _discoveryComplete && !discovery.discoveryComplete;
                _discoveryComplete = discovery.discoveryComplete;
                _updateEntryBarrier();
                if (lostCoverage && _hosting && _connections.isEmpty) {
                  _reconnect('Потеряна регистрация поиска участников');
                }
              }
            }),
          );
        }
        _peerSubscriptions.add(
          peer.onOpen.listen((id) {
            if (_current(generation) && !_peerFailed) {
              _peerOpened(generation, id);
            }
          }),
        );
        _peerSubscriptions.add(
          peer.onConnection.listen((connection) {
            if (!_current(generation) ||
                !_hosting ||
                !_signalingReady ||
                !_joined) {
              _disposeLater(connection: connection);
              return;
            }
            _attach(connection, incoming: true);
          }),
        );
        _peerSubscriptions.add(
          peer.onError.listen((error) {
            if (!_current(generation) || _peerFailed) return;
            if (_hosting && error.kind == SignalingFailureKind.idTaken) {
              _retirePeer();
              final nextGeneration = _generation;
              scheduleMicrotask(() {
                if (_current(nextGeneration)) _beginPeer(tryAlias: false);
              });
            } else {
              _reconnect('$error');
            }
          }),
        );
        _peerSubscriptions.add(
          peer.onDisconnected.listen((_) {
            if (_current(generation) && !_peerFailed) {
              _reconnect('Signaling недоступен');
            }
          }),
        );
        _peerSubscriptions.add(
          peer.onClose.listen((_) {
            if (_current(generation) && !_peerFailed) {
              _reconnect('Signaling закрыт');
            }
          }),
        );
        peer.start();
        // An already-ready factory may have opened before we started listening.
        if (peer.open && !peer.disconnected) {
          scheduleMicrotask(() {
            if (_current(generation) && !_peerFailed) {
              _peerOpened(generation, peer.id);
            }
          });
        }
      },
      (error, stack) {
        if (_current(generation) && !_peerFailed) _reconnect('$error');
      },
    );
  }

  void _peerOpened(int generation, String? id) {
    if (!_current(generation) || _registered || _peerFailed) return;
    if (id != _requestedId) {
      _reconnect('Signaling вернул неожиданный ID');
      return;
    }
    _registered = true;
    _signalingReady = true;
    final peer = _peer;
    _discoveryComplete =
        peer is SignalingDiscovery &&
        (peer as SignalingDiscovery).discoveryComplete;
    _registrationTimer?.cancel();
    _networkIssue = null;
    _updateEntryBarrier();
    _changed();
    if (_hosting) return;
    scheduleMicrotask(() {
      final peer = _peer;
      if (!_current(generation) ||
          !_signalingReady ||
          _peerFailed ||
          peer == null ||
          !peer.open ||
          peer.disconnected ||
          _hostConnection != null) {
        return;
      }
      try {
        final connection = peer.connect(hostAlias);
        if (!_current(generation) || _peerFailed) {
          _disposeLater(connection: connection);
        } else {
          _attach(connection, incoming: false);
        }
      } catch (error) {
        if (_current(generation)) _reconnect('$error');
      }
    });
  }

  void _reconnect(String reason) {
    if (_disposed || !_running || _retryTimer != null) return;
    _peerFailed = true;
    _signalingReady = false;
    _updateEntryBarrier();
    _registrationTimer?.cancel();
    _networkIssue = reason;
    _record(reason);
    // Existing channels still work during the backoff, but an alias holder
    // which lost signaling asks saved followers to participate in election.
    if (_hosting) {
      _broadcast(
        _message(
          RoomMessageType.presence,
          const [],
          online: onlineCount,
          hosting: false,
        ),
      );
    }
    final generation = _generation;
    final exponent = min(_retryAttempt++, 4);
    final delay = Duration(
      milliseconds: min(8000, 400 * (1 << exponent)) + _random.nextInt(700),
    );
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_current(generation)) _beginPeer(tryAlias: _joined);
    });
    _changed();
  }

  void _attach(RoomChannel connection, {required bool incoming}) {
    if (_connections.containsKey(connection)) return;
    final state = _RoomConnection(connection, _generation, incoming, roomId);
    _connections[connection] = state;
    _settledHosting = false;
    _soloTimer?.cancel();
    _soloTimer = null;
    if (!incoming) _hostConnection = state;
    state.deadline = Timer(_handshakeDeadline, () {
      if (_live(state) && !state.ready) {
        _dropConnection(state, 'Не получено подтверждение комнаты');
      }
    });
    state.subscriptions.add(
      connection.onOpen.listen((_) => _channelOpened(state)),
    );
    state.subscriptions.add(
      connection.onData.listen((data) {
        if (_live(state) && state.opened && connection.open) {
          _receive(state, data);
        }
      }),
    );
    state.subscriptions.add(
      connection.onClose.listen((_) {
        if (_live(state)) _dropConnection(state, 'WebRTC-канал закрыт');
      }),
    );
    state.subscriptions.add(
      connection.onError.listen((error) {
        if (_live(state)) _dropConnection(state, '$error');
      }),
    );
    state.subscriptions.add(
      connection.onConnectivity.listen(
        (connectivity) => _connectivityChanged(state, connectivity),
      ),
    );
    // Polling catches transport failures/disposal which emit no channel event.
    state.poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_live(state)) {
        if (!_disposed && identical(_connections[connection], state)) {
          _dropConnection(state, 'WebRTC-канал был закрыт');
        }
        return;
      }
      _connectivityChanged(state, connection.connectivity);
    });
    if (connection.open) scheduleMicrotask(() => _channelOpened(state));
    _changed();
  }

  void _connectivityChanged(
    _RoomConnection state,
    ChannelConnectivity connectivity,
  ) {
    if (!_live(state)) return;
    if (connectivity == ChannelConnectivity.failed ||
        connectivity == ChannelConnectivity.closed) {
      _dropConnection(state, 'WebRTC/ICE не удалось соединиться');
    } else if (connectivity == ChannelConnectivity.disconnected) {
      state.iceDeadline ??= Timer(const Duration(seconds: 5), () {
        if (_live(state)) {
          _dropConnection(state, 'WebRTC/ICE потерял связь');
        }
      });
    } else {
      state.iceDeadline?.cancel();
      state.iceDeadline = null;
    }
  }

  void _channelOpened(_RoomConnection state) {
    if (!_live(state) || state.opened || !state.connection.open) return;
    state.opened = true;
    if (!state.incoming) {
      final history = _history.durableHistory;
      state.handshakeHistory = history;
      state.offeredFastSync = _joined;
      unawaited(
        _send(
          state,
          _message(
            RoomMessageType.hello,
            // No payload may leave before the remote capability is known.
            const [],
            fastSync: state.offeredFastSync,
            durableSync: true,
            historyDigest: state.offeredFastSync
                ? roomHistoryDigest(history)
                : null,
          ),
        ),
      );
    }
  }

  List<RoomEdit> _latestDurable(List<RoomEdit> history) {
    for (final edit in history.reversed) {
      if (edit.kind == RoomEditKind.text) return [edit];
    }
    return const [];
  }

  bool get _requiresMetadata =>
      _entryParticipantName != null ||
      _history.changes.any((edit) => edit.kind != RoomEditKind.text);

  bool get _requiresTree =>
      requireFamilyTree ||
      _history.changes.any((edit) => edit.kind == RoomEditKind.tree);

  bool _containsSurnameOperations(Iterable<RoomEdit> history) => history.any(
    (edit) =>
        edit.kind == RoomEditKind.tree &&
        (jsonDecode(edit.text) as Map<String, dynamic>)['type'] == 'setSurname',
  );

  bool get _requiresSurnames =>
      requireFamilyTree || _containsSurnameOperations(_history.knownEdits);

  bool _containsExplicitSiblings(Iterable<RoomEdit> history) => history.any(
    (edit) =>
        edit.kind == RoomEditKind.tree &&
        const [
          'createSibling',
          'unlinkSibling',
        ].contains((jsonDecode(edit.text) as Map<String, dynamic>)['type']),
  );

  bool get _requiresExplicitSiblings =>
      requireFamilyTree || _containsExplicitSiblings(_history.knownEdits);

  bool _containsParticipantIdentity(Iterable<RoomEdit> history) => history.any(
    (edit) =>
        (edit.kind == RoomEditKind.participantName && edit.text.isEmpty) ||
        (edit.kind == RoomEditKind.tree &&
            (jsonDecode(edit.text) as Map<String, dynamic>)['type'] ==
                'unbindActor'),
  );

  bool get _requiresParticipantIdentity =>
      requireFamilyTree ||
      // Entry can write a blank alias before membership; negotiate first.
      _needsEntryProfile ||
      _containsParticipantIdentity(_history.knownEdits);

  bool _containsAuthorHistory(Iterable<RoomEdit> history) =>
      history.any((edit) => edit.authorSequence != null);

  bool get _requiresAuthorHistory =>
      requireFamilyTree ||
      // Admission persists a first profile through the authored allocator too.
      // Reject an incompatible welcome before importing it or saving membership.
      _needsEntryProfile ||
      _containsAuthorHistory(_history.knownEdits);

  bool get _requiresRoles =>
      invitationRole != null ||
      _history.changes.any((edit) => edit.kind == RoomEditKind.participantRole);

  RoomMessage _message(
    RoomMessageType type,
    List<RoomEdit> history, {
    int? online,
    bool? hosting,
    bool fastSync = false,
    String? historyDigest,
    bool durableSync = false,
    String? syncId,
    String? syncDigest,
    bool? roomReady,
    Map<String, String>? inventory,
  }) => RoomMessage(
    roomId: roomId,
    type: type,
    actor: actorId,
    history: history.isEmpty
        ? const []
        : completeRoomAuthorHistory(history, _history.durableHistory),
    online: online,
    hosting: hosting,
    fastSync: fastSync,
    historyDigest: historyDigest,
    durableSync: durableSync,
    roomMetadata:
        type == RoomMessageType.hello || type == RoomMessageType.welcome,
    roomRoles: type == RoomMessageType.hello || type == RoomMessageType.welcome,
    familyTree:
        type == RoomMessageType.hello || type == RoomMessageType.welcome,
    familySurnames:
        type == RoomMessageType.hello || type == RoomMessageType.welcome,
    personalSurnames:
        type == RoomMessageType.hello || type == RoomMessageType.welcome,
    explicitSiblings:
        type == RoomMessageType.hello || type == RoomMessageType.welcome,
    participantIdentity:
        type == RoomMessageType.hello || type == RoomMessageType.welcome,
    authorHistory:
        type == RoomMessageType.hello || type == RoomMessageType.welcome,
    diskSync: type == RoomMessageType.hello || type == RoomMessageType.welcome,
    onlineActors:
        _hosting &&
            networkAvailable &&
            (type == RoomMessageType.welcome ||
                type == RoomMessageType.presence)
        ? (_onlineActors.toList()..sort())
        : null,
    syncId: syncId,
    syncDigest: syncDigest,
    roomReady: roomReady,
    inventory: inventory,
  );

  /// Snapshot after admission: includes writes which completed while this
  /// channel was not ready. Later durable edits use the ordinary broadcast.
  Future<void> _sendInventory(_RoomConnection state) {
    if (state.inventorySent) return Future<void>.value();
    state.inventorySent = true;
    return _send(
      state,
      _message(
        RoomMessageType.inventory,
        const [],
        inventory: roomHistoryInventory(
          state.durableSync ? state.initialHistory! : _history.durableHistory,
        ),
      ),
    );
  }

  /// Freeze the entry contribution at admission, including already-started
  /// local appends. Subsequent typing uses broadcasts and cannot move this goal.
  Future<bool> _prepareCheckpoint(_RoomConnection state) async {
    // Drafts have immutable IDs/core clocks, but acquire their canonical proof
    // only during the atomic append. Freeze the logical cutoff, not draft JSON.
    final cutoff = _history.knownEdits;
    try {
      await _history.flush();
      if (!_live(state)) return false;
      state.initialHistory = completeRoomAuthorHistory(
        cutoff,
        _history.durableHistory,
      );
      state.localSyncId = createRoomId();
      state.localSyncDigest = roomHistoryDigest(state.initialHistory!);
      return true;
    } catch (error) {
      if (_live(state)) {
        _failInitialSync(
          _history.error ?? 'Не удалось сохранить начальную историю: $error',
        );
        _dropConnection(
          state,
          'Не удалось сохранить начальную историю',
          terminal: true,
        );
      }
      return false;
    }
  }

  Future<void> _sendCheckpoint(
    _RoomConnection state, {
    bool includeInventory = false,
  }) => _send(
    state,
    _message(
      RoomMessageType.checkpoint,
      const [],
      syncId: state.localSyncId,
      syncDigest: state.localSyncDigest,
      inventory: includeInventory
          ? roomHistoryInventory(state.initialHistory!)
          : null,
    ),
  );

  Map<String, String> _checkpointInventory(
    _RoomConnection state,
    RoomMessage message,
  ) {
    if (message.inventory != null) return message.inventory!;
    final inventory = state.remoteInventory;
    if (inventory != null &&
        roomInventoryDigest(inventory) == message.syncDigest) {
      return inventory;
    }
    // Equal roots need neither inventory nor bulk history. Retain the fixed
    // handshake snapshots even when ordinary later edits have already arrived.
    for (final history in [
      state.handshakeHistory,
      state.receivedHistory,
      state.initialHistory,
      _history.durableHistory,
    ]) {
      if (history != null && roomHistoryDigest(history) == message.syncDigest) {
        return roomHistoryInventory(history);
      }
    }
    throw const FormatException('Нет списка для контрольной точки истории');
  }

  bool _hasDurableCheckpoint(_RoomConnection state) {
    final expected = state.remoteCheckpoint;
    if (expected == null) return false;
    final durable = _durableTabInventory;
    return expected.entries.every((entry) => durable[entry.key] == entry.value);
  }

  bool _checkpointPending(_RoomConnection state) =>
      state.ready &&
      state.durableSync &&
      (!state.remoteImported || !state.localAcknowledged);

  void _cancelCheckpointDeadline(_RoomConnection state) {
    state.checkpointDeadline?.cancel();
    state.checkpointDeadline = null;
    state.checkpointAssemblyDeadline?.cancel();
    state.checkpointAssemblyDeadline = null;
  }

  void _updateCheckpointDeadline(_RoomConnection state) {
    if (!_checkpointPending(state)) {
      _cancelCheckpointDeadline(state);
      return;
    }
    if (state.decoder.assembling) return;
    // Presence/liveness and repeated checkpoint packets never renew this timer.
    // roomReady:false can mean another cohort member is pending, not this one.
    state.checkpointDeadline ??= Timer(_checkpointDeadline, () {
      if (_live(state) && _checkpointPending(state)) {
        _dropConnection(state, 'Не подтверждена контрольная точка истории');
      }
    });
  }

  void _allowCheckpointAssembly(_RoomConnection state) {
    if (!_checkpointPending(state)) return;
    state.checkpointDeadline?.cancel();
    state.checkpointDeadline = null;
    // Give a real large transfer its existing fixed 25-second allowance. Keep
    // this cap across subsequent transfers in the same incomplete round; even
    // accepted fragments cannot stretch checkpoint waiting indefinitely.
    state.checkpointAssemblyDeadline ??= Timer(_assemblyDeadline, () {
      if (_live(state) && _checkpointPending(state)) {
        _dropConnection(state, 'Не подтверждена контрольная точка истории');
      }
    });
  }

  /// ACK is evidence of a durable merge, never merely of send() finishing.
  void _ackCheckpoint(_RoomConnection state, {required bool roomReady}) {
    if (!_live(state) || !state.remoteImported) return;
    if (state.ackedRemoteId == state.remoteSyncId &&
        state.ackedRoomReady == roomReady) {
      return;
    }
    state.ackedRemoteId = state.remoteSyncId;
    state.ackedRoomReady = roomReady;
    unawaited(
      _send(
        state,
        _message(
          RoomMessageType.syncAck,
          const [],
          syncId: state.remoteSyncId,
          syncDigest: state.remoteSyncDigest,
          roomReady: roomReady,
        ),
      ),
    );
  }

  bool get _validatedHostRegistration {
    final peer = _peer;
    return _hosting &&
        _registered &&
        _signalingReady &&
        !_peerFailed &&
        peer != null &&
        peer.open &&
        !peer.disconnected &&
        peer.id == hostAlias;
  }

  bool get _hostBarrierReachable {
    if (!_validatedHostRegistration) return false;
    // A real durable peer exchange is already evidence of synchronization.
    // Complete multi-backend coverage is needed only to infer absence (solo).
    final peer = _peer!;
    return _connections.isNotEmpty ||
        peer is! SignalingDiscovery ||
        (peer as SignalingDiscovery).discoveryComplete;
  }

  Iterable<_RoomConnection> get _initialCohort {
    final admitted = _connections.values.where(
      (state) =>
          state.admissionStarted || state.ready || state.decoder.assembling,
    );
    // Blank signaling hedges are not known participants. Once a real cohort
    // exists, their transport handshake cannot hold it for 12 seconds. A real
    // bounded assembly is still a pending contribution, even before hello.
    // With no admitted peer, pending transports still prevent unsupported solo.
    return admitted.isNotEmpty ? admitted : _connections.values;
  }

  bool get _cohortImported =>
      (!_failedInitialConnection ||
          _connections.values.any((state) => state.ready)) &&
      _initialCohort.every(
        (state) =>
            _live(state) &&
            state.ready &&
            state.durableSync &&
            state.remoteImported &&
            !state.decoder.assembling,
      );

  /// This is a bounded initial cohort barrier, not a room census or consensus.
  /// New live handshakes reset the quiet interval. A host cannot tell a newcomer
  /// it is ready while another initial inventory is still being imported.
  void _updateEntryBarrier() {
    if (_disposed || !_networkOwner) return;
    _shareDiskCredentials();
    for (final state in _connections.values) {
      if (state.durableSync && _hasDurableCheckpoint(state)) {
        state.remoteImported = true;
      }
      _updateCheckpointDeadline(state);
    }
    if (!_hosting) {
      final state = _hostConnection;
      if (state != null && state.remoteImported) {
        _ackCheckpoint(state, roomReady: true);
        if (state.localAcknowledged && state.remoteRoomReady) {
          _completeInitialSync();
        }
      }
      _scheduleTabPublish();
      return;
    }
    if (_hostBarrierReachable && _soloCheckpoint == null) {
      // Proof metadata is finalized by storage, so freeze immutable IDs rather
      // than fingerprints of drafts which have not received their proof yet.
      _soloCheckpoint = _history.knownEdits.map((edit) => edit.id).toSet();
    }
    final durable = _durableTabInventory;
    final localSaved =
        _soloCheckpoint != null && _soloCheckpoint!.every(durable.containsKey);
    if (!_hostBarrierReachable || !_cohortImported || !localSaved) {
      _soloTimer?.cancel();
      _soloTimer = null;
      _settledHosting = false;
    } else if (!_settledHosting && _soloTimer == null) {
      final generation = _generation;
      _soloTimer = Timer(const Duration(seconds: 1), () {
        _soloTimer = null;
        if (!_current(generation) ||
            !_hostBarrierReachable ||
            !_cohortImported) {
          return;
        }
        _settledHosting = true;
        _updateEntryBarrier();
      });
    }
    for (final state in _connections.values.toList()) {
      if (!state.durableSync || !state.remoteImported) continue;
      if (_settledHosting && !state.finalCheckpointSent) {
        state.finalCheckpointSent = true;
        final history = _history.durableHistory;
        final digest = roomHistoryDigest(history);
        if (digest != state.localSyncDigest) {
          // Include the imports from the other initial connections before the
          // final host checkpoint. Its cutoff is fixed here, not on every edit.
          state.initialHistory = history;
          state.localSyncId = createRoomId();
          state.localSyncDigest = digest;
          state.localAcknowledged = false;
          // This fixed final cutoff supersedes the acknowledged admission round.
          // The new ACK gets its own bound; stale ACKs keep the new timer live.
          _cancelCheckpointDeadline(state);
          _updateCheckpointDeadline(state);
          final missing = missingRoomEdits(history, state.remoteCheckpoint!);
          if (missing.isNotEmpty) {
            unawaited(_send(state, _message(RoomMessageType.edits, missing)));
          }
          unawaited(_sendCheckpoint(state, includeInventory: true));
        }
      }
      _ackCheckpoint(state, roomReady: _settledHosting);
    }
    if (_settledHosting &&
        _initialCohort.every((state) => state.localAcknowledged)) {
      _completeInitialSync();
    }
    _scheduleTabPublish();
  }

  void _receive(_RoomConnection state, dynamic data) {
    try {
      final packet = state.decoder.decode(data, expectedActor: state.actor);
      if (packet.startedTransfer) {
        // A valid bounded transfer gets its own deadline, replacing the normal
        // handshake deadline. Fresh joins retain their overall 30-second cap.
        state.deadline?.cancel();
        state.assemblyDeadline = Timer(_assemblyDeadline, () {
          if (_live(state) && state.decoder.assembling) {
            _dropConnection(state, 'Передача истории не завершена');
          }
        });
        _allowCheckpointAssembly(state);
      }
      if (packet.acceptedFragment) _touch(state);
      if (packet.completedTransfer) {
        state.assemblyDeadline?.cancel();
        state.assemblyDeadline = null;
        _updateCheckpointDeadline(state);
      }
      final message = packet.message;
      if (message == null) return;
      _touch(state);
      // Serializes remote history merges, membership writes and replies, along
      // with externally persisted history refreshes enqueued by RoomHistory.
      _messages = _messages.then((_) async {
        if (!_live(state) || !state.opened || !state.connection.open) return;
        try {
          await _handleMessage(state, message);
        } catch (error) {
          if (_live(state)) {
            _dropConnection(
              state,
              'Некорректная синхронизация: $error',
              terminal: true,
            );
          }
        }
      });
    } catch (error) {
      _dropConnection(
        state,
        'Некорректное сообщение комнаты: $error',
        terminal: true,
      );
    }
  }

  Future<void> _handleMessage(
    _RoomConnection state,
    RoomMessage message,
  ) async {
    if (state.actor != null && state.actor != message.actor) {
      throw const FormatException('Участник изменил свою идентичность');
    }
    if (message.type == RoomMessageType.hello) {
      if (!state.incoming || !_hosting || !_joined) {
        throw const FormatException('Неожиданный hello');
      }
      // A validated hello awaiting durable admission is already a real initial
      // contribution, unlike a provider hedge that never sends a hello.
      state.admissionStarted = true;
      _settledHosting = false;
      _soloTimer?.cancel();
      _soloTimer = null;
      _changed();
    } else if (message.type == RoomMessageType.welcome) {
      if (state.incoming ||
          _hosting ||
          state.connection.peer != hostAlias ||
          message.hosting != true) {
        throw const FormatException('Welcome получен не от хоста комнаты');
      }
      if (message.fastSync && (!state.offeredFastSync || !_joined)) {
        throw const FormatException('Быстрая синхронизация не согласована');
      }
    } else if (!state.ready) {
      throw const FormatException('Сначала требуется подтверждение комнаты');
    }
    if (message.type == RoomMessageType.hello ||
        message.type == RoomMessageType.welcome) {
      if (!message.roomMetadata && _requiresMetadata) {
        const reason =
            'У другого участника старая версия приложения без имён и настроек '
            'комнаты. Обновите страницу на обоих устройствах.';
        _failInitialSync(reason);
        throw const FormatException(reason);
      }
      if (!message.roomRoles && _requiresRoles) {
        const reason =
            'У другого участника старая версия приложения без ролей комнаты. '
            'Обновите страницу на обоих устройствах.';
        _failInitialSync(reason);
        throw const FormatException(reason);
      }
      if (!message.familyTree && _requiresTree) {
        const reason =
            'Обновите страницу на обоих устройствах: '
            'другой клиент ещё не поддерживает семейное дерево.';
        _failInitialSync(reason);
        throw const FormatException(reason);
      }
      if (!message.familySurnames && _requiresSurnames) {
        const reason =
            'Обновите страницу на обоих устройствах: '
            'другой клиент ещё не поддерживает фамилии семейного дерева.';
        _failInitialSync(reason);
        throw const FormatException(reason);
      }
      if (!message.personalSurnames && _requiresSurnames) {
        const reason =
            'Обновите страницу на обоих устройствах: '
            'другой клиент ещё не поддерживает фамилии отдельных людей.';
        _failInitialSync(reason);
        throw const FormatException(reason);
      }
      if (!message.authorHistory && _requiresAuthorHistory) {
        const reason =
            'Обновите страницу на обоих устройствах: '
            'другой клиент ещё не поддерживает полную историю автора.';
        _failInitialSync(reason);
        throw const FormatException(reason);
      }
      if (!message.participantIdentity && _requiresParticipantIdentity) {
        const reason =
            'Обновите страницу на обоих устройствах: '
            'другой клиент ещё не поддерживает имена и отмену привязки участников.';
        _failInitialSync(reason);
        throw const FormatException(reason);
      }
      if (!message.explicitSiblings && _requiresExplicitSiblings) {
        const reason =
            'Обновите страницу на обоих устройствах: '
            'другой клиент ещё не поддерживает прямые связи братьев и сестёр.';
        _failInitialSync(reason);
        throw const FormatException(reason);
      }
      if (!message.diskSync &&
          _history.knownEdits.any(
            (edit) => edit.kind == RoomEditKind.diskConnection,
          )) {
        throw const FormatException('Обновите клиент для синхронизации Диска');
      }
      state.diskSync = message.diskSync;
      state.explicitSiblings = message.explicitSiblings;
      state.roomMetadata = message.roomMetadata;
      state.roomRoles = message.roomRoles;
      state.familyTree = message.familyTree;
      state.familySurnames = message.familySurnames;
      state.personalSurnames = message.personalSurnames;
      state.participantIdentity = message.participantIdentity;
      state.authorHistory = message.authorHistory;
    }
    if (!state.diskSync &&
        message.history.any(
          (edit) => edit.kind == RoomEditKind.diskConnection,
        )) {
      throw const FormatException('Подключение Диска не согласовано');
    }
    if (message.type == RoomMessageType.diskCredentials) {
      await _receiveDiskCredentials(state, message);
      return;
    }
    if (!state.authorHistory &&
        (_requiresAuthorHistory || _containsAuthorHistory(message.history))) {
      throw const FormatException(
        'Обновите страницу на обоих устройствах: история автора не согласована.',
      );
    }
    if (!state.familySurnames && _containsSurnameOperations(message.history)) {
      throw const FormatException(
        'Обновите страницу на обоих устройствах: фамилии не согласованы.',
      );
    }
    if (!state.personalSurnames &&
        (_requiresSurnames || _containsSurnameOperations(message.history))) {
      throw const FormatException(
        'Обновите страницу на обоих устройствах: фамилии отдельных людей '
        'не согласованы.',
      );
    }
    if (!state.participantIdentity &&
        (_requiresParticipantIdentity ||
            _containsParticipantIdentity(message.history))) {
      throw const FormatException(
        'Обновите страницу на обоих устройствах: имена и отмена привязки '
        'участников не согласованы.',
      );
    }
    if (!state.explicitSiblings &&
        (_requiresExplicitSiblings ||
            _containsExplicitSiblings(message.history))) {
      throw const FormatException(
        'Обновите страницу на обоих устройствах: прямые связи братьев и сестёр не согласованы.',
      );
    }
    if (!state.familyTree &&
        message.history.any((edit) => edit.kind == RoomEditKind.tree)) {
      throw const FormatException('Семейное дерево не согласовано');
    }
    if (!state.roomRoles &&
        message.history.any(
          (edit) => edit.kind == RoomEditKind.participantRole,
        )) {
      throw const FormatException('Роли комнаты не согласованы');
    }
    if (!state.roomMetadata &&
        message.history.any((edit) => edit.kind != RoomEditKind.text)) {
      throw const FormatException('Данные комнаты не согласованы');
    }
    if (!state.incoming && message.onlineActors != null) {
      final actors = message.onlineActors!;
      if (!actors.contains(actorId) || !actors.contains(message.actor)) {
        throw const FormatException('Неполный список онлайн-участников');
      }
    }
    if (message.type == RoomMessageType.checkpoint ||
        message.type == RoomMessageType.syncAck) {
      if (!state.durableSync) {
        throw const FormatException('Подтверждение сохранения не согласовано');
      }
      if (message.type == RoomMessageType.checkpoint) {
        final inventory = _checkpointInventory(state, message);
        missingRoomEdits(_history.knownEdits, inventory);
        state.remoteCheckpoint = inventory;
        state.remoteSyncId = message.syncId;
        state.remoteSyncDigest = message.syncDigest;
        state.remoteImported = false;
        _settledHosting = false;
      } else if (message.syncId == state.localSyncId &&
          message.syncDigest == state.localSyncDigest) {
        state.localAcknowledged = true;
        state.remoteRoomReady = message.roomReady!;
      }
      _updateEntryBarrier();
      _changed();
      return;
    }
    if (message.type == RoomMessageType.inventory) {
      if (!state.fastSync) {
        throw const FormatException('Список изменений не согласован');
      }
      final inventory = message.inventory!;
      state.remoteInventory = inventory;
      // Failed and pending writes remain immutable too. Validate the whole
      // shared set before responding, but never send these nondurable records.
      missingRoomEdits(_history.knownEdits, inventory);
      final missing = missingRoomEdits(_history.durableHistory, inventory);
      // One side may initially see equal roots while the other gains a durable
      // edit during hello/welcome. Always reciprocate the first inventory.
      unawaited(_sendInventory(state));
      if (missing.isNotEmpty) {
        unawaited(_send(state, _message(RoomMessageType.edits, missing)));
      }
      return;
    }
    final added = await _history.merge(message.history);
    if (added == null || !_live(state)) {
      if (_live(state)) {
        _failInitialSync(_history.error ?? 'Не удалось сохранить историю');
        _dropConnection(state, 'Не удалось сохранить историю', terminal: true);
      }
      return;
    }
    state.actor = message.actor;
    _validatedRemoteSeen = true;
    if (message.type == RoomMessageType.hello) {
      state.fastSync = message.fastSync;
      state.durableSync = message.durableSync;
      final history = _history.durableHistory;
      state.handshakeHistory = history;
      final digest = state.fastSync ? roomHistoryDigest(history) : null;
      state.ready = true;
      state.deadline?.cancel();
      _updateCheckpointDeadline(state);
      _touch(state);
      _retryAttempt = 0;
      // Enqueue welcome before exposing this member to later edit broadcasts.
      final welcome = _send(
        state,
        _message(
          RoomMessageType.welcome,
          state.fastSync
              ? (state.authorHistory || _requiresAuthorHistory
                    ? const []
                    : _latestDurable(history))
              : history,
          online: onlineCount,
          hosting: _signalingReady,
          fastSync: state.fastSync,
          durableSync: state.durableSync,
          historyDigest: digest,
        ),
      );
      _changed();
      await welcome;
      if (!_live(state)) return;
      if (state.durableSync) {
        if (!await _prepareCheckpoint(state)) return;
        if (state.fastSync && state.localSyncDigest != message.historyDigest) {
          unawaited(_sendInventory(state));
        }
        unawaited(
          _sendCheckpoint(
            state,
            includeInventory:
                !state.fastSync &&
                state.localSyncDigest != roomHistoryDigest(history),
          ),
        );
      } else {
        _failInitialSync(
          'Онлайн-участник использует старый клиент без подтверждения '
          'сохранения полной истории. Можно открыть локальную копию.',
        );
        if (state.fastSync && digest != message.historyDigest) {
          unawaited(_sendInventory(state));
        }
      }
      _updateEntryBarrier();
      if (added.isNotEmpty) _broadcast(_message(RoomMessageType.edits, added));
      _broadcastPresence();
    } else if (message.type == RoomMessageType.welcome) {
      bool stillAdmissible() => _live(state) && _running && _error == null;
      // This welcome has passed transport, identity and capability validation,
      // and its history is durable. Persist our profile before membership makes
      // the room usable; never publish it for an unaccepted first admission.
      if (!stillAdmissible() ||
          (_needsEntryProfile &&
              !await _ensureEntryProfile(stillAdmissible: stillAdmissible))) {
        return;
      }
      if (!_joined) {
        if (!await _history.saveMembership(stillAdmissible: stillAdmissible) ||
            !stillAdmissible()) {
          return;
        }
        _joined = true;
        _joinTimer?.cancel();
        _history.watchAcceptedHistory();
        unawaited(_loadDiskCredentials());
      }
      if (!_live(state)) return;
      state.fastSync = message.fastSync;
      state.durableSync = message.durableSync;
      state.receivedHistory = message.fastSync ? null : message.history;
      state.ready = true;
      state.deadline?.cancel();
      _updateCheckpointDeadline(state);
      _remoteOnline = message.online!;
      _remoteActors = message.onlineActors?.toSet();
      _networkIssue = null;
      _retryAttempt = 0;
      _touch(state);
      _record(
        state.fastSync
            ? 'Соединение с комнатой установлено; проверяем полную историю'
            : 'История комнаты синхронизирована',
      );
      _changed();
      // Includes already-started writes in the finite entry contribution, but
      // never acknowledges or advertises those records until they are durable.
      if (state.durableSync) {
        if (!await _prepareCheckpoint(state)) return;
        if (state.fastSync && state.localSyncDigest != message.historyDigest) {
          unawaited(_sendInventory(state));
        } else if (!state.fastSync) {
          final missing = missingRoomEdits(
            state.initialHistory!,
            roomHistoryInventory(message.history),
          );
          if (missing.isNotEmpty) {
            unawaited(_send(state, _message(RoomMessageType.edits, missing)));
          }
        }
        unawaited(
          _sendCheckpoint(
            state,
            includeInventory:
                !state.fastSync &&
                state.localSyncDigest != roomHistoryDigest(message.history),
          ),
        );
      } else {
        _failInitialSync(
          'Хост использует старый клиент без подтверждения сохранения '
          'полной истории. Можно открыть локальную копию.',
        );
        if (state.fastSync) {
          if (roomHistoryDigest(_history.durableHistory) !=
              message.historyDigest) {
            unawaited(_sendInventory(state));
          }
        } else {
          // Legacy hosts ignore our extension and still need the full upload.
          unawaited(
            _send(
              state,
              _message(RoomMessageType.edits, _history.durableHistory),
            ),
          );
        }
      }
      _updateEntryBarrier();
    } else if (message.type == RoomMessageType.edits) {
      _updateEntryBarrier();
      if (_hosting && added.isNotEmpty) {
        _broadcast(_message(RoomMessageType.edits, added));
      }
      _changed();
    } else if (message.type == RoomMessageType.presence && !state.incoming) {
      _remoteOnline = message.online!;
      _remoteActors = message.onlineActors?.toSet();
      if (message.hosting == false && _joined) {
        _reconnect('Хост потерял signaling; выбираем онлайн-участника');
      }
      _changed();
    }
  }

  /// Optimistic display, but never broadcast or acknowledge an unsaved edit.
  /// RoomHistory starts the append synchronously before returning its Future.
  Future<void> edit(String value) {
    if (_disposed || !_joined || !_history.loaded) {
      return Future<void>.value();
    }
    if (!canEdit) {
      return Future<void>.error(
        StateError('Только редактор может изменять комнату'),
      );
    }
    return _history.edit(value).then((edit) {
      if (edit != null && !_disposed) _onDurableEdits([edit]);
    });
  }

  Future<void> renameRoom(String value) async {
    final name = normalizeRoomName(value);
    if (name == null) throw ArgumentError.value(value, 'roomName');
    if (!canEdit) throw StateError('Только редактор может изменять комнату');
    final edit = await _history.renameRoom(name);
    await _history.flush();
    if (edit != null && !_disposed) _onDurableEdits([edit]);
  }

  /// Editing one's own profile is allowed for guests too; a failed append or
  /// flush is reported to the caller rather than presenting a successful save.
  Future<void> setParticipantName(String value) async {
    final name = normalizeParticipantName(value);
    if (name == null) throw ArgumentError.value(value, 'participantName');
    if (!editable) throw StateError('Комната ещё не открыта');
    final edit = await _history.setParticipantName(name);
    await _history.flush();
    if (edit != null && !_disposed) _onDurableEdits([edit]);
  }

  /// Promotions are append-only. Existing editors (including legacy members)
  /// need no operation, and an optimistic unsaved role is never effective.
  Future<void> promoteParticipant(String targetActor) async {
    if (!canEdit) {
      throw StateError('Только редактор может назначать редакторов');
    }
    if (!isValidRoomActor(targetActor) ||
        !participants.any(
          (participant) => participant.actorId == targetActor,
        )) {
      throw ArgumentError.value(
        targetActor,
        'targetActor',
        'Неизвестный участник',
      );
    }
    if (_durableRoleDocument.roleFor(targetActor) == RoomRole.editor) return;
    final edit = await _history.setParticipantRole(
      targetActor,
      RoomRole.editor,
    );
    await _history.flush();
    if (edit != null && !_disposed) _onDurableEdits([edit]);
  }

  /// Throws if a draft still cannot be saved; callers must not exit/dispose a
  /// room after a failed flush, or its unsaved optimistic text would be lost.
  Future<void> flush() => _history.flush();

  void _touch(_RoomConnection state) {
    state.receivedPackets++;
    state.liveness?.cancel();
    state.liveness = Timer(_livenessDeadline, () {
      if (_live(state)) _dropConnection(state, 'Участник перестал отвечать');
    });
  }

  void _broadcastPresence() {
    if (_hosting) {
      _broadcast(
        _message(
          RoomMessageType.presence,
          const [],
          online: onlineCount,
          hosting: _signalingReady,
        ),
      );
    }
  }

  void _broadcast(RoomMessage message) {
    for (final state in _connections.values.toList()) {
      if (state.ready && state.opened && _live(state)) {
        unawaited(_send(state, message));
      }
    }
  }

  Future<void> _send(_RoomConnection state, RoomMessage message) {
    if (!_live(state) || !state.opened || !state.connection.open) {
      return Future<void>.value();
    }
    final Iterable<Map<String, dynamic>> packets;
    try {
      if (!state.diskSync &&
          message.history.any(
            (edit) => edit.kind == RoomEditKind.diskConnection,
          )) {
        throw const FormatException('Обновите клиент для синхронизации Диска');
      }
      if (!state.authorHistory &&
          (_containsAuthorHistory(message.history) ||
              (message.type != RoomMessageType.hello &&
                  _requiresAuthorHistory))) {
        throw const FormatException(
          'Обновите страницу на обоих устройствах для полной истории автора.',
        );
      }
      if (!state.familySurnames &&
          _containsSurnameOperations(message.history)) {
        throw const FormatException(
          'Обновите страницу на обоих устройствах для синхронизации фамилий.',
        );
      }
      if (!state.personalSurnames &&
          (_containsSurnameOperations(message.history) ||
              (message.type != RoomMessageType.hello && _requiresSurnames))) {
        throw const FormatException(
          'Обновите страницу на обоих устройствах для синхронизации фамилий '
          'отдельных людей.',
        );
      }
      if (!state.participantIdentity &&
          (_containsParticipantIdentity(message.history) ||
              (message.type != RoomMessageType.hello &&
                  _requiresParticipantIdentity))) {
        throw const FormatException(
          'Обновите страницу на обоих устройствах для синхронизации имён '
          'и отмены привязки участников.',
        );
      }
      if (!state.explicitSiblings &&
          (_containsExplicitSiblings(message.history) ||
              (message.type != RoomMessageType.hello &&
                  _requiresExplicitSiblings))) {
        throw const FormatException(
          'Обновите страницу на обоих устройствах: прямые связи братьев и сестёр не согласованы.',
        );
      }
      if (!state.familyTree &&
          message.history.any((edit) => edit.kind == RoomEditKind.tree)) {
        throw const FormatException(
          'Обновите старый клиент для семейного дерева',
        );
      }
      if (!state.roomRoles &&
          message.history.any(
            (edit) => edit.kind == RoomEditKind.participantRole,
          )) {
        throw const FormatException(
          'Обновите старый клиент для синхронизации ролей комнаты',
        );
      }
      if (!state.roomMetadata &&
          message.history.any((edit) => edit.kind != RoomEditKind.text)) {
        throw const FormatException(
          'Обновите старый клиент для синхронизации данных комнаты',
        );
      }
      packets = encodeRoomMessage(message);
    } catch (error) {
      _dropConnection(state, '$error', terminal: true);
      return Future<void>.value();
    }
    state.sending = state.sending
        .then((_) async {
          if (!_live(state) || !state.connection.open) return;
          if (message.type == RoomMessageType.diskCredentials &&
              (!state.diskSync ||
                  !canEdit ||
                  diskBinding?.id != message.diskBindingId ||
                  _durableRoleDocument.participantRoles[state.actor] !=
                      RoomRole.editor)) {
            return;
          }
          for (final packet in packets) {
            if (!_live(state) || !state.connection.open) return;
            await state.connection
                .send(packet)
                .timeout(const Duration(seconds: 5));
          }
        })
        .catchError((Object error) {
          if (_live(state)) {
            _dropConnection(
              state,
              message.type == RoomMessageType.diskCredentials
                  ? 'Не удалось передать доступ к Диску'
                  : 'Не удалось отправить историю: $error',
            );
          }
        });
    return state.sending;
  }

  void _dropConnection(
    _RoomConnection state,
    String reason, {
    bool terminal = false,
  }) {
    if (!identical(_connections[state.connection], state)) return;
    final outbound = identical(_hostConnection, state);
    final incompleteParticipant =
        ((!state.incoming && state.opened) ||
            state.admissionStarted ||
            state.actor != null ||
            state.ready) &&
        (!state.remoteImported || !state.localAcknowledged);
    if (incompleteParticipant || terminal) {
      // A real hello (even rejected), or our opened outbound logical channel,
      // is evidence against solo. Keep it across automatic peer generations.
      // Blank incoming discovery hedges are not such evidence.
      _failedInitialConnection = true;
    }
    if (terminal) {
      // Transport loss is recoverable within the original entry deadline, but
      // integrity/encoding failures must remain explicit. Preserve a more
      // specific capability or storage error already reported by the caller.
      _failInitialSync(_initialSyncError ?? reason);
    }
    _connections.remove(state.connection);
    if (outbound) _hostConnection = null;
    _cancelConnection(state);
    _disposeLater(connection: state.connection);
    _networkIssue = reason;
    _record(reason);
    _updateEntryBarrier();
    _changed();
    if (outbound) {
      _reconnect(reason);
    } else {
      _broadcastPresence();
      final peer = _peer;
      if (_hosting && _connections.isEmpty) {
        if (!_initialSyncComplete &&
            incompleteParticipant &&
            !terminal &&
            _history.error == null) {
          // A listening alias alone cannot recover an unfinished incoming
          // exchange if the other device no longer dials. Reuse normal bounded
          // backoff/election without resetting the entry deadline or evidence.
          _reconnect(reason);
        } else if (state.ready &&
            peer is SignalingDiscovery &&
            !(peer as SignalingDiscovery).discoveryComplete) {
          _reconnect('Восстанавливаем регистрацию поиска участников');
        }
      }
    }
  }

  void _cancelConnection(_RoomConnection state) {
    state.deadline?.cancel();
    state.liveness?.cancel();
    state.poll?.cancel();
    state.iceDeadline?.cancel();
    state.assemblyDeadline?.cancel();
    _cancelCheckpointDeadline(state);
    state.decoder.reset();
    _cancelSubscriptions(state.subscriptions);
  }

  void _retirePeer() {
    _generation++;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _discoveryComplete = false;
    _peerStartedAt = null;
    _soloTimer?.cancel();
    _soloTimer = null;
    _soloCheckpoint = null;
    _settledHosting = false;
    _registrationTimer?.cancel();
    _retryTimer?.cancel();
    _retryTimer = null;
    _registered = false;
    _signalingReady = false;
    final peer = _peer;
    _peer = null;
    _cancelSubscriptions(_peerSubscriptions);
    for (final state in _connections.values) {
      _cancelConnection(state);
      _disposeLater(connection: state.connection);
    }
    _connections.clear();
    _hostConnection = null;
    _remoteActors = null;
    _hosting = false;
    _disposeLater(peer: peer);
  }

  void _cancelSubscriptions(List<StreamSubscription<dynamic>> subscriptions) {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    subscriptions.clear();
  }

  void _disposeLater({SignalingPeer? peer, RoomChannel? connection}) {
    // Synchronous emitters must finish delivering before their streams close.
    scheduleMicrotask(() {
      try {
        connection?.dispose();
        peer?.dispose();
      } catch (_) {
        // A transport resource may already have disposed itself after the event.
      }
    });
  }

  void _record(String message) {
    if (_disposed) return;
    if (_log.length == 60) _log.removeAt(0);
    _log.add(message);
  }

  void _onDurableEdits(List<RoomEdit> edits) {
    if (_disposed || !_joined) return;
    _updateDiskSync();
    _diskSync.schedule();
    if (diskBinding != null &&
        _diskCredentials?['bindingId'] != diskBinding!.id &&
        !_diskCommandBusy &&
        !_diskEntryPending &&
        (canEdit || _diskPublicAccess?.bindingId != diskBinding!.id)) {
      unawaited(_loadDiskCredentials());
    }
    if (_isTabFollower) {
      final state = _tabState;
      if (state != null) _verifyTabState(state);
    } else {
      // Shared-storage additions, including follower typing, leave only through
      // this tab's normal network owner. No local tab message carries drafts.
      _broadcast(_message(RoomMessageType.edits, edits));
    }
    _shareDiskCredentials();
    _scheduleTabPublish();
  }

  void _historyChanged() {
    _changed();
    // Local persistence may release a frozen checkpoint even without a new
    // network message. Do not run this reentrantly inside a journal mutation.
    scheduleMicrotask(() {
      if (_disposed) return;
      _updateDiskSync();
      if (diskBinding != null &&
          _diskCredentials?['bindingId'] != diskBinding!.id &&
          !_diskCommandBusy &&
          !_diskEntryPending &&
          (canEdit || _diskPublicAccess?.bindingId != diskBinding!.id)) {
        unawaited(_loadDiskCredentials());
      }
      _shareDiskCredentials();
      if (_isTabFollower) {
        final state = _tabState;
        if (state != null) _verifyTabState(state);
      } else if (_networkStarted) {
        _updateEntryBarrier();
      }
    });
  }

  void _changed() {
    if (_disposed) return;
    _updateDiskCredentialExchange();
    notifyListeners();
    _scheduleTabPublish();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _running = false;
    _joinTimer?.cancel();
    _initialTimer?.cancel();
    _soloTimer?.cancel();
    _heartbeatTimer?.cancel();
    _tabTerm++;
    _tabPublishTimer?.cancel();
    _tabVerifyTimer?.cancel();
    _cancelSubscriptions(_tabSubscriptions);
    unawaited(_networkSubscription?.cancel());
    unawaited(_foregroundSubscription?.cancel());
    _diskCredentialExchange.dispose();
    _diskRetirements.dispose();
    _diskReadSync.dispose();
    _diskSync.dispose();
    _diskClient.close();
    _history.dispose();
    _retirePeer();
    // _retirePeer defers disposal out of synchronous transport emitters. Queue
    // lock release afterwards, so takeover never overlaps this tab's network.
    final tabs = roomTabs;
    if (tabs != null) scheduleMicrotask(tabs.dispose);
    super.dispose();
  }
}

class _RoomConnection {
  _RoomConnection(
    this.connection,
    this.generation,
    this.incoming,
    String roomId,
  ) : decoder = RoomMessageDecoder(roomId: roomId);
  final RoomChannel connection;
  final int generation;
  final bool incoming;
  final RoomMessageDecoder decoder;
  final subscriptions = <StreamSubscription<dynamic>>[];
  Future<void> sending = Future<void>.value();
  bool opened = false;
  int receivedPackets = 0;
  bool admissionStarted = false;
  bool ready = false;
  bool offeredFastSync = false;
  bool fastSync = false;
  bool inventorySent = false;
  bool durableSync = false;
  bool roomMetadata = false;
  bool roomRoles = false;
  bool familyTree = false;
  bool familySurnames = false;
  bool personalSurnames = false;
  bool explicitSiblings = false;
  bool participantIdentity = false;
  bool authorHistory = false;
  bool diskSync = false;
  String? sentDiskBinding;
  bool remoteImported = false;
  bool localAcknowledged = false;
  bool remoteRoomReady = false;
  bool finalCheckpointSent = false;
  List<RoomEdit>? handshakeHistory;
  List<RoomEdit>? receivedHistory;
  List<RoomEdit>? initialHistory;
  Map<String, String>? remoteInventory;
  Map<String, String>? remoteCheckpoint;
  String? localSyncId;
  String? localSyncDigest;
  String? remoteSyncId;
  String? remoteSyncDigest;
  String? ackedRemoteId;
  bool? ackedRoomReady;
  String? actor;
  Timer? deadline;
  Timer? liveness;
  Timer? poll;
  Timer? iceDeadline;
  Timer? assemblyDeadline;
  Timer? checkpointDeadline;
  Timer? checkpointAssemblyDeadline;
}
