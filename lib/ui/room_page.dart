import 'dart:async';

import 'package:flutter/material.dart';

import '../ice_configuration.dart';
import '../local/room_tabs.dart';
import '../local/room_tabs_stub.dart'
    if (dart.library.js_interop) '../local/room_tabs_web.dart';
import '../room_document.dart';
import '../room_identity.dart';
import '../room_session.dart';
import '../signaling/fallback_signaling.dart';
import '../signaling/signaling.dart';
import '../storage/create_room_store.dart';
import '../storage/room_store.dart';
import 'room_dialogs.dart';
import 'tree_brand.dart';
import 'tree_editor.dart';

class RoomPage extends StatefulWidget {
  const RoomPage({
    super.key,
    this.store,
    this.applicationUri,
    this.peerFactory = createSignalingPeer,
    this.roomTabsFactory,
    this.roomEditorBuilder,
    this.iceConfiguration = const IceConfiguration.fromEnvironment(),
  });

  final RoomStore? store;
  final Uri? applicationUri;
  final SignalingPeerFactory peerFactory;
  final RoomTabsFactory? roomTabsFactory;
  final Widget Function(RoomSession)? roomEditorBuilder;
  final IceConfiguration iceConfiguration;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> with WidgetsBindingObserver {
  final _recentlyOnlineRooms = <String, DateTime>{};
  late final RoomStore _store;
  late final Uri _applicationUri;
  String _actorId = '';
  String? _lastRoom;
  String? _menuError;
  bool _loading = true;
  bool _leaving = false;
  bool _joinDialogOpen = false;
  int _generation = 0;
  RoomSession? _session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store = widget.store ?? createRoomStore();
    _applicationUri = widget.applicationUri ?? Uri.base;
    unawaited(_restore());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _session?.setForeground(state == AppLifecycleState.resumed);
  }

  Future<void> _restore() async {
    try {
      _actorId = await _store.loadClientId();
      _lastRoom = await _store.loadLastRoom();
      if (!mounted) return;
      final invite = roomInvitationFromUri(_applicationUri);
      if (invite != null) {
        await _openRoom(invite.roomId, invitationRole: invite.role);
      } else if (roomIdFromUri(_applicationUri) != null) {
        _menuError =
            'В приглашении указана неизвестная роль. Попросите новую ссылку.';
      } else if (_lastRoom != null) {
        await _openRoom(_lastRoom!);
      }
    } catch (error) {
      if (mounted) _menuError = 'Не удалось прочитать локальные данные: $error';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createRoom() async {
    if (_loading || _joinDialogOpen || _session != null) return;
    if (_actorId.isEmpty) {
      _showMessage('Локальное хранилище недоступно. Комната не создана.');
      return;
    }
    setState(() => _loading = true);
    try {
      await _openRoom(createRoomId(), newlyCreated: true);
    } catch (error) {
      if (mounted) setState(() => _menuError = 'Комната не сохранена: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openRoom(
    String rawId, {
    bool newlyCreated = false,
    RoomRole? invitationRole,
  }) async {
    final invitation = parseRoomInvitation(rawId);
    final roomId = invitation?.roomId;
    if (roomId == null || !isValidRoomId(roomId)) {
      if (mounted) {
        setState(
          () => _menuError =
              'Укажите корректный ID комнаты или ссылку-приглашение.',
        );
      }
      return;
    }
    final generation = ++_generation;
    final existing = await _store.hasMembership(roomId);
    if (!mounted || generation != _generation) return;
    String? participantName;
    List<RoomEdit>? initialHistory;
    if (existing) {
      initialHistory = decodeRoomHistory(await _store.loadHistory(roomId));
      final document = RoomDocument()..merge(initialHistory);
      if (!mounted || generation != _generation) return;
      participantName = document.participantNames[_actorId];
    }
    if (participantName == null) {
      // A prompt can outlive this snapshot; reload after accepting the name.
      initialHistory = null;
      participantName = await showDialog<String>(
        context: context,
        builder: (_) => const ParticipantNameDialog(),
      );
      if (!mounted || generation != _generation || participantName == null) {
        return;
      }
    }
    // Creating a room must remain harmless when the name prompt is cancelled.
    if (newlyCreated) {
      await _store.saveMembership(roomId);
      if (!mounted || generation != _generation) return;
    }
    await _session?.flush();
    if (!mounted || generation != _generation) return;
    _session?.removeListener(_sessionChanged);
    _session?.dispose();
    final now = DateTime.now();
    _recentlyOnlineRooms.removeWhere(
      (_, seen) => now.difference(seen) > const Duration(seconds: 60),
    );
    final recentHost = recentRoomHostSeen(roomId);
    if (recentHost != null) _recentlyOnlineRooms[roomId] = recentHost;
    final tabsFactory =
        widget.roomTabsFactory ??
        (_store.sharedAcrossTabs ? createRoomTabs : null);
    final session = RoomSession(
      roomId: roomId,
      actorId: _actorId,
      store: _store,
      existingMember: existing || newlyCreated,
      participantName: participantName,
      initialHistory: initialHistory,
      invitationRole: newlyCreated
          ? RoomRole.editor
          : invitationRole ?? invitation!.role,
      newlyCreated: newlyCreated,
      roomTabs: tabsFactory?.call(roomId, _actorId),
      preferExistingHost: existing && _recentlyOnlineRooms.containsKey(roomId),
      peerFactory: widget.peerFactory,
      requireFamilyTree: widget.roomEditorBuilder == null,
      iceConfiguration: widget.iceConfiguration,
    );
    _session = session;
    _menuError = null;
    session.addListener(_sessionChanged);
    setState(() {});
    try {
      await session.start();
      if (!mounted || generation != _generation) return;
      _sessionChanged();
      if (existing) {
        try {
          await _store.saveMembership(roomId);
          if (mounted && generation == _generation) _lastRoom = roomId;
        } catch (error) {
          if (mounted && generation == _generation) {
            _showMessage(
              'Комната открыта, но не удалось запомнить её для следующего запуска: $error',
            );
          }
        }
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      session.removeListener(_sessionChanged);
      session.dispose();
      _session = null;
      setState(() => _menuError = 'Не удалось открыть комнату: $error');
    }
  }

  void _sessionChanged() {
    if (!mounted) return;
    final session = _session;
    if (session == null) return;
    if (session.joined) {
      if (session.hasValidatedOnlinePeer ||
          (session.initialSyncComplete && session.onlineCount > 1)) {
        _recentlyOnlineRooms[session.roomId] = DateTime.now();
        rememberRecentRoomHost(session.roomId);
      }
      _lastRoom = session.roomId;
    }
    setState(() {});
  }

  Future<void> _joinRoom() async {
    if (_loading || _joinDialogOpen || _session != null) return;
    _joinDialogOpen = true;
    String? value;
    try {
      value = await showDialog<String>(
        context: context,
        builder: (_) => JoinRoomDialog(initialRoomId: _lastRoom),
      );
    } finally {
      _joinDialogOpen = false;
    }
    if (!mounted || value == null) return;
    if (_actorId.isEmpty) {
      _showMessage('Локальное хранилище недоступно.');
      return;
    }
    setState(() => _loading = true);
    try {
      await _openRoom(value);
    } catch (error) {
      if (mounted) {
        setState(() => _menuError = 'Не удалось подключиться: $error');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _exitToMenu() async {
    final session = _session;
    if (_leaving || session == null) return;
    setState(() => _leaving = true);
    try {
      await session.flush();
      if (!mounted) return;
      if (session.onlineCount > 1) {
        _recentlyOnlineRooms[session.roomId] = DateTime.now();
      } else {
        _recentlyOnlineRooms.remove(session.roomId);
        forgetRecentRoomHost(session.roomId);
      }
      ++_generation;
      session.removeListener(_sessionChanged);
      session.dispose();
      _session = null;
      setState(() => _menuError = null);
    } catch (error) {
      _showMessage('Не удалось завершить локальное сохранение: $error');
    } finally {
      if (mounted) setState(() => _leaving = false);
    }
  }

  Future<void> _retrySave(RoomSession session) async {
    try {
      if (!session.editable) {
        await session.retry();
      } else {
        await session.flush();
      }
    } catch (error) {
      _showMessage('Данные ещё не сохранены: $error');
    }
  }

  Future<void> _participants() async {
    final session = _session;
    if (session == null || !session.joined || _leaving) return;
    final invite = await showDialog<bool>(
      context: context,
      builder: (_) => RoomParticipantsDialog(session: session),
    );
    if (mounted &&
        identical(_session, session) &&
        !_leaving &&
        invite == true) {
      _invite();
    }
  }

  void _roomMenu(String value) {
    final session = _session;
    if (session == null || _leaving) return;
    if (value == 'menu') {
      unawaited(_exitToMenu());
    } else if (value == 'settings') {
      showDialog<void>(
        context: context,
        builder: (_) => RoomSettingsDialog(session: session),
      );
    } else if (value == 'history') {
      showDialog<void>(
        context: context,
        builder: (_) => RoomChangesDialog(session: session),
      );
    } else if (value == 'name') {
      showDialog<String>(
        context: context,
        builder: (_) => ListenableBuilder(
          listenable: session,
          builder: (_, _) => ParticipantNameDialog(
            initialName: session.participantName,
            onSave: session.setParticipantName,
            boundPersonName: session.boundPersonFullName,
            onUnbind: session.canUnbindFromPerson
                ? session.unbindFromPerson
                : null,
          ),
        ),
      );
    }
  }

  void _invite() {
    final session = _session;
    if (session == null ||
        !session.joined ||
        (!session.initialSyncComplete && !session.localCopyOpened)) {
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => InviteParticipantsDialog(
        roomId: session.roomId,
        applicationUri: _applicationUri,
        canInviteEditors: session.canEdit,
        onMessage: _showMessage,
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_generation;
    _session?.removeListener(_sessionChanged);
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final inRoom = session?.joined == true;
    return Scaffold(
      appBar: AppBar(
        excludeHeaderSemantics: inRoom,
        title: inRoom
            ? Semantics(
                button: true,
                enabled: !_leaving,
                child: PopupMenuButton<String>(
                  key: const Key('room-menu'),
                  tooltip: 'Меню комнаты',
                  enabled: !_leaving,
                  onSelected: _roomMenu,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'settings',
                      child: Text('Настройки комнаты'),
                    ),
                    PopupMenuItem(
                      value: 'history',
                      child: Text('Журнал изменений'),
                    ),
                    PopupMenuItem(
                      value: 'name',
                      child: Text('Изменить моё имя'),
                    ),
                    PopupMenuItem(value: 'menu', child: Text('Выход в меню')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            session!.roomName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.expand_more, size: 20),
                      ],
                    ),
                  ),
                ),
              )
            : const Text('MyTree'),
        actions: [
          if (inRoom)
            RoomDiskStatusButton(session: session!, enabled: !_leaving),
          if (inRoom)
            RoomParticipantsButton(
              otherOnlineCount: session!.otherOnlineCount,
              networkAvailable: session.networkAvailable,
              onPressed: _leaving ? null : () => unawaited(_participants()),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: _loading && session == null
            ? const RoomLoadingView(status: 'Читаем данные на устройстве…')
            : session == null
            ? _buildMenu()
            : session.joined &&
                  (session.initialSyncComplete || session.localCopyOpened)
            ? _buildRoom(session)
            : _buildJoining(session),
      ),
    );
  }

  Widget _buildMenu() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: TreeMark(size: 96)),
            const SizedBox(height: 20),
            Text(
              'MyTree',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _createRoom,
              icon: const Icon(Icons.add),
              label: const Text('Создать комнату'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _joinRoom,
              icon: const Icon(Icons.login),
              label: const Text('Присоединиться'),
            ),
            if (_menuError != null) ...[
              const SizedBox(height: 20),
              Text(
                _menuError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _buildJoining(RoomSession session) => RoomLoadingView(
    status: session.initialSyncStatus,
    error: session.storageError ?? session.error ?? session.initialSyncError,
    requiresOnlineMember: !session.joined,
    onRetry: () => unawaited(session.retry()),
    onOpenLocal: session.joined && session.editable
        ? session.openLocalCopy
        : null,
    onExit: _leaving ? null : () => unawaited(_exitToMenu()),
  );

  Widget _buildRoom(RoomSession session) => Column(
    children: [
      if (session.storageError != null ||
          (session.localCopyOpened && !session.initialSyncComplete))
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (session.localCopyOpened && !session.initialSyncComplete)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'Локальная копия · синхронизация не подтверждена',
                    key: const Key('sync-status'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (session.storageError != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'Не сохранено: ${session.storageError}',
                    key: const Key('save-status'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: session.saving ? null : () => _retrySave(session),
                  child: const Text('Повторить сохранение'),
                ),
              ],
            ],
          ),
        ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: AbsorbPointer(
            absorbing: _leaving,
            child: ExcludeFocus(
              excluding: _leaving,
              child:
                  widget.roomEditorBuilder?.call(session) ??
                  TreeEditor(session: session),
            ),
          ),
        ),
      ),
    ],
  );
}
