import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../room_document.dart';
import '../room_identity.dart';
import '../room_session.dart';
import '../tree/tree_document.dart';

class JoinRoomDialog extends StatefulWidget {
  const JoinRoomDialog({super.key, this.initialRoomId});

  final String? initialRoomId;

  @override
  State<JoinRoomDialog> createState() => _JoinRoomDialogState();
}

class _JoinRoomDialogState extends State<JoinRoomDialog> {
  late final _controller = TextEditingController(
    text: widget.initialRoomId ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Присоединиться к комнате'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Для входа по ID нужен онлайн-участник. Приглашение с доступом к Диску позволяет войти без него.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.go,
          decoration: const InputDecoration(
            labelText: 'ID комнаты или ссылка',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Подключиться'),
      ),
    ],
  );
}

class ParticipantNameDialog extends StatefulWidget {
  const ParticipantNameDialog({
    super.key,
    this.initialName,
    this.onSave,
    this.boundPersonName,
    this.onUnbind,
  });

  final String? initialName;
  final Future<void> Function(String)? onSave;
  final String? boundPersonName;
  final Future<void> Function()? onUnbind;

  @override
  State<ParticipantNameDialog> createState() => _ParticipantNameDialogState();
}

class _ParticipantNameDialogState extends State<ParticipantNameDialog> {
  late final _controller = TextEditingController(text: widget.initialName);
  String? _error;
  bool _saving = false;
  bool _unbinding = false;

  Future<void> _unbind() async {
    final unbind = widget.onUnbind;
    if (_saving || unbind == null) return;
    setState(() {
      _saving = _unbinding = true;
      _error = null;
    });
    try {
      await unbind();
    } catch (error) {
      if (mounted) setState(() => _error = 'Не удалось отменить связь: $error');
    } finally {
      if (mounted) setState(() => _saving = _unbinding = false);
    }
  }

  Future<void> _submit() async {
    if (_saving) return;
    final name = normalizeParticipantName(_controller.text);
    if (name == null) {
      setState(() => _error = 'До 64 символов, без переноса строк.');
      return;
    }
    final save = widget.onSave;
    if (save == null) {
      Navigator.pop(context, name);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await save(name);
      if (mounted) Navigator.pop(context, name);
    } catch (error) {
      if (mounted) setState(() => _error = 'Не удалось сохранить имя: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(
        widget.onSave == null ? 'Как вас зовут?' : 'Изменить моё имя',
      ),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('participant-name'),
            controller: _controller,
            enabled: !_saving,
            autofocus: true,
            maxLength: maxParticipantNameLength,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Ваше имя',
              hintText: 'Аноним',
              border: const OutlineInputBorder(),
              errorText: _error,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.onUnbind != null) ...[
            const SizedBox(height: 8),
            Tooltip(
              message: widget.boundPersonName ?? 'Отменить «Это я»',
              excludeFromSemantics: true,
              child: TextButton.icon(
                key: const Key('participant-unbind'),
                onPressed: _saving ? null : _unbind,
                icon: const Icon(Icons.link_off),
                label: Text(_unbinding ? 'Отвязываем…' : 'Отменить «Это я»'),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(
            _saving
                ? 'Сохраняем…'
                : widget.onSave == null
                ? 'Продолжить'
                : 'Сохранить',
          ),
        ),
      ],
    ),
  );
}

class RoomSettingsDialog extends StatefulWidget {
  const RoomSettingsDialog({super.key, required this.session});

  final RoomSession session;

  @override
  State<RoomSettingsDialog> createState() => _RoomSettingsDialogState();
}

class _RoomSettingsDialogState extends State<RoomSettingsDialog> {
  late final _controller = TextEditingController(text: widget.session.roomName);
  final _diskTokenController = TextEditingController();
  bool _saving = false;
  bool _showDiskToken = false;
  bool _confirmingDisk = false;
  bool _diskPending = false;
  String? _error;
  String? _diskError;

  bool get _busy => _saving || _confirmingDisk || _diskPending;

  Future<void> _save() async {
    if (_busy || !widget.session.canEdit) return;
    final name = normalizeRoomName(_controller.text);
    if (name == null) {
      setState(
        () => _error = 'Укажите название: до 120 символов, без переноса строк.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.session.renameRoom(name);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Не удалось сохранить название: $error');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDisk({
    required String title,
    required String message,
    required String action,
  }) async {
    setState(() => _confirmingDisk = true);
    try {
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(title),
              scrollable: true,
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(action),
                ),
              ],
            ),
          ) ==
          true;
    } finally {
      if (mounted) setState(() => _confirmingDisk = false);
    }
  }

  Future<bool> _runDiskCommand(
    Future<void> Function() command,
    String failureMessage,
  ) async {
    setState(() {
      _diskPending = true;
      _diskError = null;
    });
    try {
      await command();
      return true;
    } catch (_) {
      // Disk exceptions may contain credentials; never render their raw text.
      if (mounted) setState(() => _diskError = failureMessage);
      return false;
    } finally {
      if (mounted) setState(() => _diskPending = false);
    }
  }

  Future<void> _connectDisk() async {
    final session = widget.session;
    if (_busy || !session.canEdit || !session.canConnectDisk) return;
    final token = _diskTokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _diskError = 'Укажите OAuth-токен.');
      return;
    }
    final confirmed = await _confirmDisk(
      title: 'Подключить Яндекс Диск?',
      message:
          'Доступ к папке приложения будет общим для редакторов комнаты, '
          'но не для гостей.',
      action: 'Подключить',
    );
    if (!mounted ||
        !confirmed ||
        _busy ||
        !session.canEdit ||
        !session.canConnectDisk ||
        session.diskBinding != null) {
      return;
    }
    final connected = await _runDiskCommand(
      () => session.connectDisk(token),
      'Не удалось подключить Яндекс Диск.',
    );
    if (mounted && connected) {
      _diskTokenController.clear();
      setState(() => _showDiskToken = false);
    }
  }

  Future<void> _disconnectDisk() async {
    final session = widget.session;
    final binding = session.diskBinding;
    if (_busy ||
        !session.canEdit ||
        !session.canDisconnectDisk ||
        binding == null) {
      return;
    }
    final confirmed = await _confirmDisk(
      title: 'Отвязать Яндекс Диск?',
      message: 'Файлы на Диске сохранятся.',
      action: 'Отвязать',
    );
    if (!mounted ||
        !confirmed ||
        _busy ||
        !session.canEdit ||
        !session.canDisconnectDisk ||
        session.diskBinding?.id != binding.id) {
      return;
    }
    await _runDiskCommand(
      session.disconnectDisk,
      'Не удалось отвязать Яндекс Диск.',
    );
  }

  Future<void> _syncDisk() async {
    final session = widget.session;
    if (_busy || !session.canEdit || session.diskBinding == null) return;
    await _runDiskCommand(
      session.syncDisk,
      'Не удалось синхронизировать с Диском.',
    );
  }

  Widget _buildDiskSection(BuildContext context) {
    final session = widget.session;
    final error = _diskError ?? session.diskSyncError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Яндекс Диск', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(session.diskSyncStatus, key: const Key('disk-status')),
        if (_diskPending || session.diskSyncBusy) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(key: Key('disk-progress')),
        ],
        if (session.canEdit &&
            session.diskBinding == null &&
            session.canConnectDisk) ...[
          const SizedBox(height: 12),
          if (!_showDiskToken)
            OutlinedButton.icon(
              key: const Key('disk-connect-expand'),
              onPressed: _busy
                  ? null
                  : () => setState(() => _showDiskToken = true),
              icon: const Icon(Icons.cloud_outlined),
              label: const Text('Подключить Яндекс Диск'),
            )
          else ...[
            TextField(
              key: const Key('disk-token'),
              controller: _diskTokenController,
              enabled: !_busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'OAuth-токен',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _connectDisk(),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('disk-connect'),
              onPressed: _busy ? null : _connectDisk,
              child: const Text('Подключить'),
            ),
          ],
        ],
        if (session.canEdit && session.diskBinding != null) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton.icon(
                key: const Key('disk-sync'),
                onPressed: _busy || session.diskSyncBusy ? null : _syncDisk,
                icon: const Icon(Icons.sync),
                label: const Text('Синхронизировать'),
              ),
              if (session.canDisconnectDisk)
                TextButton.icon(
                  key: const Key('disk-disconnect'),
                  onPressed: _busy ? null : _disconnectDisk,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Отвязать Яндекс Диск'),
                ),
            ],
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              key: const Key('disk-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _diskTokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) => PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Настройки комнаты'),
        scrollable: true,
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('room-name'),
                controller: _controller,
                enabled: !_busy,
                readOnly: !widget.session.canEdit,
                autofocus: widget.session.canEdit,
                maxLength: maxRoomNameLength,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Название комнаты',
                  border: const OutlineInputBorder(),
                  errorText: _error,
                  errorMaxLines: 3,
                  helperText: widget.session.canEdit
                      ? null
                      : 'Доступ только для просмотра',
                ),
                onSubmitted: widget.session.canEdit ? (_) => _save() : null,
              ),
              const Divider(height: 32),
              _buildDiskSection(context),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(widget.session.canEdit ? 'Отмена' : 'Закрыть'),
          ),
          if (widget.session.canEdit)
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_saving ? 'Сохраняем…' : 'Сохранить'),
            ),
        ],
      ),
    ),
  );
}

/// A compact cloud action, independent of room presence and local saving.
class RoomDiskStatusButton extends StatefulWidget {
  const RoomDiskStatusButton({
    super.key,
    required this.session,
    this.enabled = true,
    this.onConnect,
  });

  final RoomSession session;
  final bool enabled;
  final VoidCallback? onConnect;

  @override
  State<RoomDiskStatusButton> createState() => _RoomDiskStatusButtonState();
}

class _RoomDiskStatusButtonState extends State<RoomDiskStatusButton> {
  bool _pending = false;
  String? _error;

  @override
  void didUpdateWidget(RoomDiskStatusButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      _pending = false;
      _error = null;
    }
  }

  Future<void> _sync() async {
    final session = widget.session;
    if (!widget.enabled ||
        _pending ||
        session.diskSyncBusy ||
        !session.canEdit) {
      return;
    }
    if (session.diskBinding == null && !session.diskUnlinkPending) {
      widget.onConnect?.call();
      return;
    }
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      await session.syncDisk();
    } catch (_) {
      if (mounted && identical(widget.session, session)) {
        // Only the session's sanitized error may be shown, never a raw failure.
        _error = 'Не удалось синхронизировать с Диском. Повторите позже.';
      }
    } finally {
      if (mounted && identical(widget.session, session)) {
        setState(() => _pending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final session = widget.session;
      final error =
          session.diskSyncError ??
          (session.diskSyncAcknowledged ? null : _error);
      if (!session.canEdit) return const SizedBox.shrink();
      final disconnected =
          session.diskBinding == null && !session.diskUnlinkPending;
      final colors = Theme.of(context).colorScheme;
      final busy = _pending || session.diskSyncBusy;
      final confirmed =
          session.diskBinding != null &&
          session.diskSyncAcknowledged &&
          !session.diskUnlinkPending;
      final symbol = busy
          ? Icons.sync
          : error != null
          ? Icons.close
          : confirmed
          ? Icons.check
          : Icons.sync;
      final symbolColor = busy
          ? colors.onSurfaceVariant
          : error != null
          ? colors.error
          : confirmed
          ? colors.primary
          : colors.onSurfaceVariant;
      final status = _pending && !session.diskSyncBusy
          ? 'Синхронизация с Диском…'
          : session.diskSyncStatus;
      final label = [
        'Яндекс Диск: $status',
        if (session.diskUnlinkPending && session.diskBinding != null)
          'Отвязка прежнего Диска ещё не подтверждена.',
        if (error != null) error,
      ].join('\n');
      final onPressed =
          widget.enabled && !busy && (!disconnected || widget.onConnect != null)
          ? () => unawaited(_sync())
          : null;
      return Semantics(
        label: label,
        button: true,
        enabled: onPressed != null,
        onTap: onPressed,
        excludeSemantics: true,
        child: Tooltip(
          message: label,
          child: IconButton(
            key: const Key('disk-sync-button'),
            onPressed: onPressed,
            icon: SizedBox(
              width: 30,
              height: 30,
              child: Stack(
                children: [
                  Center(
                    child: Icon(
                      Icons.cloud_outlined,
                      key: const Key('disk-sync-cloud'),
                      color: colors.onSurfaceVariant,
                      size: 26,
                    ),
                  ),
                  if (!disconnected || busy || error != null)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: DecoratedBox(
                        key: const Key('disk-sync-badge'),
                        decoration: BoxDecoration(
                          color: colors.surface,
                          shape: BoxShape.circle,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(1),
                          child: Icon(
                            symbol,
                            key: const Key('disk-sync-symbol'),
                            color: symbolColor,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Connectivity is independent of presence: a solo room can still be online.
class RoomParticipantsButton extends StatelessWidget {
  const RoomParticipantsButton({
    super.key,
    required this.otherOnlineCount,
    required this.networkAvailable,
    required this.onPressed,
  });

  final int otherOnlineCount;
  final bool networkAvailable;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label =
        'Участники: $otherOnlineCount других онлайн'
        '${networkAvailable ? '' : '. Нет подключения к сети'}';
    return Semantics(
      label: label,
      button: true,
      enabled: onPressed != null,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: TextButton(
          key: const Key('participants-button'),
          onPressed: onPressed,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (networkAvailable) ...[
                Text('$otherOnlineCount', key: const Key('participants-count')),
                const SizedBox(width: 6),
              ],
              SizedBox(
                width: 28,
                height: 28,
                child: Stack(
                  children: [
                    Center(
                      child: Icon(
                        networkAvailable
                            ? Icons.person_outline
                            : Icons.cloud_off_outlined,
                        key: const Key('participants-icon'),
                      ),
                    ),
                    if (otherOnlineCount > 0)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          key: const Key('participants-online-dot'),
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF32D74B),
                            border: Border.all(color: colors.surface, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RoomParticipantsDialog extends StatefulWidget {
  const RoomParticipantsDialog({super.key, required this.session});

  final RoomSession session;

  @override
  State<RoomParticipantsDialog> createState() => _RoomParticipantsDialogState();
}

class _RoomParticipantsDialogState extends State<RoomParticipantsDialog> {
  bool _saving = false;
  String? _error;

  Future<void> _promoteParticipant(RoomParticipant person) async {
    if (_saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Сделать редактором?'),
        content: Text(
          '${person.name} сможет изменять дерево и приглашать редакторов.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сделать редактором'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.session.promoteParticipant(person.actorId);
    } catch (error) {
      if (mounted) setState(() => _error = 'Не удалось сохранить: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final session = widget.session;
      final participants = session.participants.toList()
        ..sort((a, b) {
          if (a.role != b.role) return a.role == RoomRole.editor ? -1 : 1;
          if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
          final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          return byName != 0 ? byName : a.actorId.compareTo(b.actorId);
        });
      return LayoutBuilder(
        builder: (context, constraints) => Dialog(
          key: const Key('participants-panel'),
          alignment: Alignment.topRight,
          insetPadding: const EdgeInsets.fromLTRB(16, 72, 16, 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 360,
              maxHeight: (constraints.maxHeight - 88).clamp(0, 560),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            'Участники',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Закрыть',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    key: const Key('participants-scroll'),
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          key: const Key('participants-list'),
                          alignment: WrapAlignment.center,
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final person in participants)
                              _ParticipantAvatar(
                                person: person,
                                onPressed:
                                    !_saving &&
                                        !person.isSelf &&
                                        session.canEdit &&
                                        person.role == RoomRole.guest
                                    ? () => _promoteParticipant(person)
                                    : null,
                                action:
                                    !person.isSelf &&
                                        session.canEdit &&
                                        person.role == RoomRole.guest
                                    ? 'Сделать редактором'
                                    : null,
                              ),
                          ],
                        ),
                        if (_saving) const LinearProgressIndicator(),
                        if (_error != null)
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: OutlinedButton.icon(
                    onPressed:
                        session.joined &&
                            (session.initialSyncComplete ||
                                session.localCopyOpened)
                        ? () => Navigator.pop(context, true)
                        : null,
                    icon: const Icon(Icons.person_add_outlined),
                    label: const Text('Пригласить участников'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ParticipantAvatar extends StatelessWidget {
  const _ParticipantAvatar({required this.person, this.onPressed, this.action});

  final RoomParticipant person;
  final VoidCallback? onPressed;
  final String? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const tileWidth = 96.0;
    const tilePadding = 8.0;
    final nameLayout = TextPainter(
      text: TextSpan(
        text: person.name,
        style: DefaultTextStyle.of(context).style,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: tileWidth - tilePadding * 2);
    final truncated = nameLayout.didExceedMaxLines;
    nameLayout.dispose();
    final fullName = person.boundPersonFullName;
    final tooltip = [
      if (truncated) person.name,
      if (fullName != null &&
          fullName.isNotEmpty &&
          (!truncated || fullName != person.name))
        fullName,
    ].join('\n');
    final tile = Semantics(
      key: ValueKey('participant-${person.actorId}'),
      label:
          '${person.name}, ${person.isSelf ? 'вы, ' : ''}${person.isOnline ? 'онлайн' : 'офлайн'}, ${person.role == RoomRole.editor ? 'редактор' : 'гость'}',
      hint: action,
      button: action != null,
      enabled: action == null ? null : onPressed != null,
      onTap: onPressed,
      excludeSemantics: true,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          key: ValueKey('participant-tile-${person.actorId}'),
          padding: const EdgeInsets.all(tilePadding),
          width: tileWidth,
          decoration: BoxDecoration(
            color: person.isOnline ? colors.primaryContainer : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              SizedBox(
                width: 54,
                height: 54,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      key: person.isSelf
                          ? const Key('self-participant-glow')
                          : null,
                      width: 54,
                      height: 54,
                      alignment: Alignment.center,
                      decoration: person.isSelf
                          ? BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: colors.primary,
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: colors.primary.withValues(alpha: 0.4),
                                  blurRadius: 12,
                                  spreadRadius: 2,
                                ),
                              ],
                            )
                          : null,
                      child: CircleAvatar(
                        radius: 22,
                        backgroundColor: person.isOnline
                            ? colors.primary
                            : colors.surfaceContainerHighest,
                        foregroundColor: person.isOnline
                            ? colors.onPrimary
                            : colors.onSurfaceVariant,
                        backgroundImage: person.avatarDataUrl == null
                            ? null
                            : MemoryImage(
                                base64Decode(
                                  person.avatarDataUrl!.split(',').last,
                                ),
                              ),
                        child: person.avatarDataUrl == null
                            ? const Icon(Icons.person_outline)
                            : null,
                      ),
                    ),
                    if (person.isOnline)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          key: ValueKey(
                            'participant-online-dot-${person.actorId}',
                          ),
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF32D74B),
                            border: Border.all(color: colors.surface, width: 2),
                          ),
                        ),
                      ),
                    if (person.role == RoomRole.guest)
                      Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          key: ValueKey('guest-badge-${person.actorId}'),
                          width: 20,
                          height: 20,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF875826),
                          ),
                          child: const Icon(
                            Icons.visibility_outlined,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                person.name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
    return tooltip.isEmpty
        ? tile
        : Tooltip(
            key: ValueKey('participant-tooltip-${person.actorId}'),
            message: tooltip,
            child: tile,
          );
  }
}

class RoomChangesDialog extends StatelessWidget {
  const RoomChangesDialog({super.key, required this.session});

  final RoomSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final groups = <List<RoomEdit>>[];
      String? previousField;
      for (final edit in session.changes) {
        final operation = edit.kind == RoomEditKind.tree
            ? TreeOperation.fromJson(jsonDecode(edit.text))
            : null;
        final field = operation == null
            ? null
            : '${operation.personId}:${operation.fieldKey}';
        if (field != null &&
            previousField == field &&
            groups.isNotEmpty &&
            groups.last.last.author == edit.author) {
          groups.last.add(edit);
        } else {
          groups.add([edit]);
        }
        previousField = field;
      }
      final changes = groups.reversed.toList();
      final names = {
        for (final person in session.participants) person.actorId: person.name,
      };
      final localizations = MaterialLocalizations.of(context);
      return AlertDialog(
        title: const Text('Журнал изменений'),
        content: SizedBox(
          width: 420,
          height: MediaQuery.sizeOf(context).height * 0.55,
          child: changes.isEmpty
              ? const Center(child: Text('Изменений пока нет'))
              : ListView.separated(
                  key: const Key('room-changes'),
                  itemCount: changes.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, index) {
                    final edit = changes[index].last;
                    final operation = edit.kind == RoomEditKind.tree
                        ? TreeOperation.fromJson(jsonDecode(edit.text))
                        : null;
                    final time = DateTime.fromMillisecondsSinceEpoch(
                      edit.createdAt,
                      isUtc: true,
                    ).toLocal();
                    final title = switch (edit.kind) {
                      RoomEditKind.text => 'Изменён текст',
                      RoomEditKind.participantName => 'Имя участника',
                      RoomEditKind.roomName => 'Название комнаты',
                      RoomEditKind.participantRole => 'Роль участника',
                      RoomEditKind.diskConnection => 'Яндекс Диск',
                      RoomEditKind.tree => operation!.description,
                    };
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(title),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${names[edit.author] ?? edit.author} · '
                            '${localizations.formatShortDate(time)} '
                            '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(time))}',
                          ),
                          const SizedBox(height: 4),
                          Text(
                            operation != null
                                ? session.tree
                                          .person(operation.personId)
                                          ?.displayName ??
                                      'Участник дерева'
                                : edit.kind == RoomEditKind.diskConnection
                                ? jsonDecode(edit.text)['action'] == 'connect'
                                      ? 'Яндекс Диск подключён'
                                      : 'Яндекс Диск отвязан'
                                : edit.kind == RoomEditKind.participantRole
                                ? '${names[edit.targetActor] ?? edit.targetActor}: ${edit.text == 'editor' ? 'Редактор' : 'Гость'}'
                                : edit.kind == RoomEditKind.participantName &&
                                      edit.text.isEmpty
                                ? 'Имя не указано'
                                : edit.text,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      );
    },
  );
}

typedef PrepareRoomDiskAccess =
    Future<RoomDiskAccess?> Function(
      RoomRole role, {
      required bool allowPublication,
    });

class InviteParticipantsDialog extends StatefulWidget {
  const InviteParticipantsDialog({
    super.key,
    required this.roomId,
    required this.applicationUri,
    required this.onMessage,
    this.canInviteEditors = false,
    this.prepareDiskAccess,
    this.canPublishDiskAccess = false,
  });

  final String roomId;
  final Uri applicationUri;
  final ValueChanged<String> onMessage;
  final bool canInviteEditors;
  final PrepareRoomDiskAccess? prepareDiskAccess;
  final bool canPublishDiskAccess;

  @override
  State<InviteParticipantsDialog> createState() =>
      _InviteParticipantsDialogState();
}

class _InviteParticipantsDialogState extends State<InviteParticipantsDialog> {
  RoomRole _role = RoomRole.guest;
  bool _preparing = false;
  bool _editorSharingAccepted = false;
  bool _publicSharingAccepted = false;
  String? _error;

  Future<bool> _confirmAccess({required bool public}) async {
    if ((public && _publicSharingAccepted) ||
        (!public && _editorSharingAccepted)) {
      return true;
    }
    final accepted =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: Text(
              public
                  ? 'Разрешить гостям доступ к Диску?'
                  : 'Передать доступ редактору?',
            ),
            content: Text(
              public
                  ? 'По ссылке будет доступна история этого дерева, включая удалённые записи. Другие деревья не публикуются.'
                  : 'Приглашение будет содержать ключ папки приложения на Диске. Передавайте его только доверенным редакторам.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(public ? 'Разрешить' : 'Передать'),
              ),
            ],
          ),
        ) ==
        true;
    if (accepted) {
      if (public) {
        _publicSharingAccepted = true;
      } else {
        _editorSharingAccepted = true;
      }
    }
    return accepted;
  }

  Future<RoomInvitation?> _prepareInvitation() async {
    if (_preparing) return null;
    final role = _role;
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      RoomDiskAccess? access;
      final prepare = widget.prepareDiskAccess;
      if (prepare != null) {
        if (role == RoomRole.editor && !await _confirmAccess(public: false)) {
          return null;
        }
        if (!mounted) return null;
        access = await prepare(role, allowPublication: false);
        if (!mounted) return null;
        if (access == null &&
            role == RoomRole.guest &&
            widget.canPublishDiskAccess) {
          if (!await _confirmAccess(public: true) || !mounted) return null;
          access = await prepare(role, allowPublication: true);
          if (!mounted) return null;
        }
        if (access == null) {
          throw StateError('Доступ к Диску недоступен');
        }
      }
      if (role != _role ||
          (role == RoomRole.editor && !widget.canInviteEditors)) {
        return null;
      }
      if (access != null && access.isEditor != (role == RoomRole.editor)) {
        throw const FormatException(
          'Роль приглашения не соответствует доступу к Диску',
        );
      }
      return RoomInvitation(widget.roomId, role: role, diskAccess: access);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось подготовить приглашение через Диск. Проверьте доступ и повторите.',
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _copyInvitation({required bool code}) async {
    final invitation = await _prepareInvitation();
    if (!mounted || invitation == null) return;
    final value = code
        ? (invitation.diskAccess == null
              ? widget.roomId
              : jsonEncode({
                  'v': 1,
                  'peerId': widget.roomId,
                  'role': invitation.role.name,
                  'disk': invitation.diskAccess!.toJson(),
                }))
        : createRoomLink(
            widget.applicationUri,
            widget.roomId,
            role: invitation.role,
            diskAccess: invitation.diskAccess,
          );
    if (value == null) return;
    await _copy(
      value,
      code
          ? invitation.diskAccess == null
                ? 'ID комнаты скопирован. Вход по ID — как гость.'
                : 'Код приглашения скопирован'
          : 'Ссылка на комнату скопирована',
    );
  }

  Future<void> _copy(String value, String message) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      widget.onMessage(message);
    } catch (_) {
      widget.onMessage(
        widget.prepareDiskAccess == null
            ? 'Не удалось скопировать. Выделите и скопируйте значение вручную.'
            : 'Не удалось скопировать. Повторите или используйте QR.',
      );
    }
  }

  Future<void> _showQr(BuildContext context) async {
    final invitation = await _prepareInvitation();
    if (!mounted || invitation == null || !context.mounted) return;
    QrCode? qr;
    try {
      final candidate = QrCode.fromData(
        data: createRoomQrData(
          widget.applicationUri,
          widget.roomId,
          role: invitation.role,
          diskAccess: invitation.diskAccess,
        ),
        errorCorrectLevel: QrErrorCorrectLevel.L,
      );
      // Capacity errors can be deferred until the image is constructed.
      QrImage(candidate);
      qr = candidate;
    } catch (_) {
      // Do not expose the payload in a library exception or error widget.
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(
          invitation.role == RoomRole.editor ? 'QR · Редактор' : 'QR · Гость',
        ),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 264,
                height: 264,
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: qr == null
                    ? const Text(
                        'Приглашение слишком длинное для QR. Скопируйте URL.',
                      )
                    : QrImageView.withQr(
                        qr: qr,
                        size: 240,
                        errorStateBuilder: (_, _) => const Text(
                          'Приглашение слишком длинное для QR. Скопируйте URL.',
                        ),
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Colors.black,
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Colors.black,
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              Text(
                createRoomLink(
                          widget.applicationUri,
                          widget.roomId,
                          role: _role,
                        ) !=
                        null
                    ? 'Откройте ссылку обычной камерой телефона.'
                    : 'Отсканируйте ID комнаты на другом устройстве.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final link = createRoomLink(
      widget.applicationUri,
      widget.roomId,
      role: _role,
    );
    return PopScope(
      canPop: !_preparing,
      child: AlertDialog(
        title: const Text('Пригласить участников'),
        scrollable: true,
        content: SizedBox(
          width: 360,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.prepareDiskAccess == null
                    ? 'При первом входе кто-то из комнаты должен быть онлайн.'
                    : 'Приглашение с доступом к Диску позволяет войти без онлайн-участников.',
              ),
              const SizedBox(height: 16),
              SegmentedButton<RoomRole>(
                key: const Key('invitation-role'),
                segments: [
                  const ButtonSegment(
                    value: RoomRole.guest,
                    label: Text('Гость'),
                    icon: Icon(Icons.visibility_outlined),
                  ),
                  ButtonSegment(
                    value: RoomRole.editor,
                    label: const Text('Редактор'),
                    icon: const Icon(Icons.edit_outlined),
                    enabled: widget.canInviteEditors,
                  ),
                ],
                selected: {_role},
                onSelectionChanged: _preparing
                    ? null
                    : (roles) => setState(() {
                        _role = roles.single;
                        _error = null;
                      }),
              ),
              const SizedBox(height: 8),
              Text(
                _role == RoomRole.guest
                    ? 'Только просмотр. Редактор сможет повысить участника позже.'
                    : 'Редактирование дерева и приглашение новых редакторов.',
              ),
              if (!widget.canInviteEditors)
                const Text('Гость может приглашать только гостей.'),
              const SizedBox(height: 16),
              SelectableText(
                widget.roomId,
                key: const Key('room-id'),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              OutlinedButton.icon(
                onPressed: _preparing
                    ? null
                    : () => unawaited(_copyInvitation(code: true)),
                icon: const Icon(Icons.copy),
                label: Text(
                  widget.prepareDiskAccess == null
                      ? 'Скопировать ID'
                      : 'Скопировать код',
                ),
              ),
              Text(
                widget.prepareDiskAccess == null
                    ? 'Вход по одному ID — как гость. Для редактора отправьте URL или QR.'
                    : 'Один ID не содержит доступа к Диску.',
              ),
              if (link != null) ...[
                const SizedBox(height: 12),
                if (widget.prepareDiskAccess == null)
                  SelectableText(link, key: const Key('room-link'))
                else
                  const Text('Доступ к Диску включается в код, URL и QR.'),
                OutlinedButton.icon(
                  onPressed: _preparing
                      ? null
                      : () => unawaited(_copyInvitation(code: false)),
                  icon: const Icon(Icons.link),
                  label: const Text('Скопировать URL'),
                ),
              ],
              OutlinedButton.icon(
                onPressed: _preparing
                    ? null
                    : () => unawaited(_showQr(context)),
                icon: const Icon(Icons.qr_code),
                label: const Text('Показать QR'),
              ),
              if (_preparing) const LinearProgressIndicator(),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _preparing ? null : () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }
}
