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
import '../tree/tree_document.dart';
import 'patronymic_dictionary_dialog.dart';
import 'room_dialogs.dart';
import 'tree_brand.dart';
import 'tree_editor.dart';

const _buildVersion = String.fromEnvironment(
  'MYTREE_BUILD_VERSION',
  defaultValue: 'dev',
);

class _RoomVersionMenuEntry extends PopupMenuEntry<String> {
  const _RoomVersionMenuEntry();

  @override
  double get height => kMinInteractiveDimension;

  @override
  bool represents(String? value) => false;

  @override
  State<_RoomVersionMenuEntry> createState() => _RoomVersionMenuEntryState();
}

class _RoomVersionMenuEntryState extends State<_RoomVersionMenuEntry> {
  @override
  Widget build(BuildContext context) => SizedBox(
    height: widget.height,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          enabled: true,
          child: SelectableText(
            'Версия: $_buildVersion',
            key: const Key('room-build-version'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    ),
  );
}

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
  final _nameMode = ValueNotifier(TreeNameMode.givenSurname);
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
  OverlayEntry? _resumeOverlay;
  bool _resumeOverlayScheduled = false;
  bool _roomSurfaceOpened = false;
  bool _wasPaused = false;

  bool get _roomActionsEnabled =>
      !_leaving && _session?.verifyingAfterResume != true;

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
    if (state == AppLifecycleState.inactive) return;
    if (state == AppLifecycleState.paused) _wasPaused = true;
    if (state == AppLifecycleState.resumed && _wasPaused) {
      _wasPaused = false;
      _session?.setSuspended();
    }
    _session?.setForeground(state == AppLifecycleState.resumed);
  }

  Future<void> _restore() async {
    try {
      _actorId = await _store.loadClientId();
      _lastRoom = await _store.loadLastRoom();
      if (!mounted) return;
      final invite = roomInvitationFromUri(_applicationUri);
      if (invite != null) {
        await _openRoom(
          invite.roomId,
          invitationRole: invite.role,
          invitationDiskAccess: invite.diskAccess,
        );
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
    RoomDiskAccess? invitationDiskAccess,
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
      invitationDiskAccess: newlyCreated
          ? null
          : invitationDiskAccess ?? invitation!.diskAccess,
      newlyCreated: newlyCreated,
      roomTabs: tabsFactory?.call(roomId, _actorId),
      preferExistingHost: existing && _recentlyOnlineRooms.containsKey(roomId),
      peerFactory: widget.peerFactory,
      requireFamilyTree: widget.roomEditorBuilder == null,
      iceConfiguration: widget.iceConfiguration,
    );
    _session = session;
    _roomSurfaceOpened = false;
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
    if (session.joined &&
        (session.initialSyncComplete || session.localCopyOpened)) {
      _roomSurfaceOpened = true;
    }
    if (session.joined) {
      if (session.hasValidatedOnlinePeer ||
          (session.initialSyncComplete && session.onlineCount > 1)) {
        _recentlyOnlineRooms[session.roomId] = DateTime.now();
        rememberRecentRoomHost(session.roomId);
      }
      _lastRoom = session.roomId;
    }
    setState(() {});
    _scheduleResumeOverlay();
  }

  void _scheduleResumeOverlay() {
    if (_resumeOverlayScheduled) return;
    _resumeOverlayScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resumeOverlayScheduled = false;
      if (!mounted) return;
      final session = _session;
      if (session == null || !session.verifyingAfterResume) {
        _removeResumeOverlay();
      } else if (_resumeOverlay == null &&
          ModalRoute.of(context)?.isCurrent == false) {
        // A phone biography or an open dialog lives above this page's body.
        // Cover those routes too, without discarding their already-saved drafts.
        FocusManager.instance.primaryFocus?.unfocus();
        final overlay = _resumeOverlay = OverlayEntry(
          builder: (context) => Positioned.fill(
            child: BlockSemantics(
              child: Material(
                key: const Key('resume-loading-overlay'),
                color: Theme.of(context).colorScheme.surface,
                child: ListenableBuilder(
                  listenable: session,
                  builder: (_, _) => Stack(
                    fit: StackFit.expand,
                    children: [
                      const ModalBarrier(dismissible: false),
                      SafeArea(child: _buildJoining(session)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        Overlay.of(context, rootOverlay: true).insert(overlay);
      }
    });
  }

  void _removeResumeOverlay() {
    _resumeOverlay?.remove();
    _resumeOverlay?.dispose();
    _resumeOverlay = null;
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
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        Navigator.of(
          context,
        ).popUntil((candidate) => identical(candidate, route));
      }
      ++_generation;
      session.removeListener(_sessionChanged);
      session.dispose();
      _session = null;
      _roomSurfaceOpened = false;
      _removeResumeOverlay();
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
    if (session == null || !session.joined || !_roomActionsEnabled) return;
    final invite = await showDialog<bool>(
      context: context,
      builder: (_) =>
          RoomParticipantsDialog(session: session, nameMode: _nameMode.value),
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
    if (session == null || !_roomActionsEnabled) return;
    if (value == 'menu') {
      unawaited(_exitToMenu());
    } else if (value == 'settings') {
      showDialog<void>(
        context: context,
        builder: (_) => RoomSettingsDialog(session: session),
      );
    } else if (value == 'patronymics') {
      showDialog<void>(
        context: context,
        builder: (_) => PatronymicDictionaryDialog(session: session),
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
            boundPersonName: session.durableTree
                .person(session.boundPersonId ?? '')
                ?.nameForMode(_nameMode.value),
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
        !_roomActionsEnabled ||
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
        prepareDiskAccess: session.diskInvitationsAvailable
            ? session.prepareDiskInvitation
            : null,
        canPublishDiskAccess: session.canPublishDiskInvitation,
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
    _removeResumeOverlay();
    ++_generation;
    _session?.removeListener(_sessionChanged);
    _session?.dispose();
    _nameMode.dispose();
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
                enabled: _roomActionsEnabled,
                child: PopupMenuButton<String>(
                  key: const Key('room-menu'),
                  tooltip: 'Меню комнаты',
                  enabled: _roomActionsEnabled,
                  onSelected: _roomMenu,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'settings',
                      child: Text('Настройки комнаты'),
                    ),
                    PopupMenuItem(
                      value: 'patronymics',
                      child: Text('Словарь отчеств'),
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
                    PopupMenuDivider(),
                    _RoomVersionMenuEntry(),
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
            RoomDiskStatusButton(
              session: session!,
              enabled: _roomActionsEnabled,
              onConnect: () => _roomMenu('settings'),
            ),
          if (inRoom)
            RoomParticipantsButton(
              otherOnlineCount: session!.otherOnlineCount,
              networkAvailable: session.networkAvailable,
              onPressed: _roomActionsEnabled
                  ? () => unawaited(_participants())
                  : null,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: _loading && session == null
            ? const RoomLoadingView(status: 'Читаем данные на устройстве…')
            : session == null
            ? _buildMenu()
            : _buildSessionSurface(session),
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
    requiresOnlineMember:
        !session.joined && session.invitationDiskAccess == null,
    onRetry: () => unawaited(session.retry()),
    onOpenLocal: session.joined && session.editable
        ? session.openLocalCopy
        : null,
    onExit: _leaving ? null : () => unawaited(_exitToMenu()),
  );

  Widget _buildSessionSurface(RoomSession session) {
    final ready =
        session.joined &&
        (session.initialSyncComplete || session.localCopyOpened);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_roomSurfaceOpened)
          Offstage(
            offstage: !ready,
            child: TickerMode(enabled: ready, child: _buildRoom(session)),
          ),
        if (!ready) _buildJoining(session),
      ],
    );
  }

  Widget _buildRoom(RoomSession session) {
    final customEditor = widget.roomEditorBuilder?.call(session);
    final blocked =
        _leaving || (!session.initialSyncComplete && !session.localCopyOpened);
    // The tree toolbar is full-bleed under the AppBar. The historical text
    // editor keeps its inset so its floating label stays clear of the header.
    Widget editor = AbsorbPointer(
      absorbing: blocked,
      child: ExcludeFocus(
        excluding: blocked,
        child:
            customEditor ?? TreeEditor(session: session, nameMode: _nameMode),
      ),
    );
    if (customEditor != null) {
      editor = Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: editor,
      );
    }
    return Column(
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
                    onPressed: session.saving
                        ? null
                        : () => _retrySave(session),
                    child: const Text('Повторить сохранение'),
                  ),
                ],
              ],
            ),
          ),
        Expanded(child: editor),
      ],
    );
  }
}
