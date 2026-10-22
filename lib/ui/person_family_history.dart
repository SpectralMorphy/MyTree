import 'dart:convert';

import 'package:flutter/material.dart';

import '../room_identity.dart';
import '../room_session.dart';
import '../tree/tree_document.dart';

/// The biography supplies navigation; history forms do not depend on the canvas.
class PersonFamilyHistory extends StatefulWidget {
  const PersonFamilyHistory({
    super.key,
    required this.session,
    required this.personId,
    required this.nameMode,
    required this.onSelect,
    required this.editing,
    this.onPickFromTree,
  });

  final RoomSession session;
  final String personId;
  final ValueNotifier<TreeNameMode> nameMode;
  final ValueChanged<String> onSelect;
  final bool editing;
  final Future<String?> Function(String, bool Function(TreePerson))?
  onPickFromTree;

  @override
  State<PersonFamilyHistory> createState() => _PersonFamilyHistoryState();
}

class _PersonFamilyHistoryState extends State<PersonFamilyHistory> {
  bool _busy = false;
  bool _retryPending = false;
  String? _error;

  void _open({bool marriage = true, TreeFamilyHistoryEntry? entry}) {
    if (_busy || _retryPending || !widget.session.canEdit) return;
    showDialog<void>(
      context: context,
      builder: (_) => _FamilyHistoryDialog(
        session: widget.session,
        personId: widget.personId,
        nameMode: widget.nameMode,
        onPickFromTree: widget.onPickFromTree,
        marriage: entry == null ? marriage : entry.marriage != null,
        entry: entry,
      ),
    );
  }

  Future<void> _remove(TreeFamilyHistoryEntry entry) async {
    if (_busy || _retryPending || !widget.session.canEdit) return;
    final session = widget.session;
    final personId = widget.personId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          entry.marriage == null ? 'Удалить смену фамилии?' : 'Удалить брак?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('confirm-delete-family-history'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        widget.session != session ||
        widget.personId != personId ||
        !session.canEdit) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final before = session.changes.map((edit) => edit.id).toSet();
    TreeOperation? operation;
    try {
      operation = entry.marriage != null
          ? session.tree.removeMarriage(widget.personId, entry.marriage!.id)
          : session.tree.removeSurnameChange(
              widget.personId,
              entry.surnameChange!.id,
            );
      await session.applyTreeOperation(operation);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _retryPending =
              operation != null && _hasSubmitted(session, before, [operation]);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retry() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.session.flush();
      if (mounted) {
        setState(() {
          _error = null;
          _retryPending = false;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, widget.nameMode]),
    builder: (context, _) {
      final tree = widget.session.tree;
      final person = tree.person(widget.personId);
      if (person == null) return const SizedBox.shrink();
      final entries = tree.historyOf(person.id);
      final editing = widget.editing && widget.session.canEdit;
      return Column(
        key: const Key('person-family-history'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Фамилии и браки',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (editing) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  key: const Key('add-marriage'),
                  onPressed: _busy || _retryPending ? null : () => _open(),
                  icon: const Icon(Icons.favorite_border),
                  label: const Text('Брак'),
                ),
                OutlinedButton.icon(
                  key: const Key('add-surname-change'),
                  onPressed: _busy || _retryPending
                      ? null
                      : () => _open(marriage: false),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Смена фамилии'),
                ),
              ],
            ),
          ],
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Записей пока нет',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final entry in entries)
            Padding(
              key: ValueKey('family-history-entry-${_entryIdentity(entry)}'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (entry.surnameChange case final change?
                      when change.changesSurname)
                    Row(
                      key: ValueKey(
                        'family-history-surname-${_entryIdentity(entry)}',
                      ),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (change.date != null) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(_dateLabel(change.date!)),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: Text(
                            change.surname.formForSex(person.sex),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ],
                    ),
                  if (entry.marriage case final marriage?)
                    _marriageCaption(marriage, person)
                  else
                    Text(entry.surnameChange!.reason),
                  if (editing)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          key: ValueKey(
                            'edit-family-history-${_entryIdentity(entry)}',
                          ),
                          tooltip: 'Изменить запись',
                          onPressed: _busy || _retryPending
                              ? null
                              : () => _open(entry: entry),
                          icon: const Icon(Icons.edit_outlined, size: 20),
                        ),
                        IconButton(
                          key: ValueKey(
                            'delete-family-history-${_entryIdentity(entry)}',
                          ),
                          tooltip: 'Удалить запись',
                          onPressed: _busy || _retryPending
                              ? null
                              : () => _remove(entry),
                          icon: const Icon(Icons.delete_outline, size: 20),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          if (_error != null)
            _HistoryError(error: _error!, onRetry: _busy ? null : _retry),
        ],
      );
    },
  );

  Widget _marriageCaption(TreeMarriage marriage, TreePerson person) {
    final partner = widget.session.tree.person(
      marriage.otherPersonId(person.id) ?? '',
    );
    final range = _marriageRange(marriage, person, partner);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('Брак с '),
        if (partner == null)
          const Text('Удалённый человек')
        else
          Semantics(
            button: true,
            child: InkWell(
              key: ValueKey('marriage-partner-${marriage.id}'),
              onTap: () => widget.onSelect(partner.id),
              child: Text(
                partner.nameForMode(widget.nameMode.value),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
        if (range.isNotEmpty) Text(' ($range)'),
      ],
    );
  }
}

// Marriage and independent surname records have separate domain ID namespaces.
String _entryIdentity(TreeFamilyHistoryEntry entry) =>
    '${entry.marriage != null ? 'marriage' : 'surnameChange'}-${entry.id}';

String _marriageRange(
  TreeMarriage marriage,
  TreePerson person,
  TreePerson? partner,
) {
  final death = marriage.lifelongEndDate(person.deathDate, partner?.deathDate);
  if (!marriage.hasExplicitDates && death == null) return '';
  final start = marriage.startDate == null
      ? '?'
      : _dateLabel(marriage.startDate!);
  final endDate = marriage.endMode == TreeMarriageEndMode.lifelong
      ? death
      : marriage.endDate;
  final alive = person.alive == true && partner?.alive == true;
  final end = endDate != null
      ? _dateLabel(endDate)
      : marriage.endMode == TreeMarriageEndMode.lifelong
      ? alive
            ? 'н.в.'
            : 'пожизненно'
      : '?';
  return '$start — $end';
}

bool _hasSubmitted(
  RoomSession session,
  Set<String> before,
  Iterable<TreeOperation> operations,
) {
  final texts = operations
      .map((operation) => jsonEncode(operation.toJson()))
      .toSet();
  return session.changes.any(
    (edit) =>
        !before.contains(edit.id) &&
        edit.author == session.actorId &&
        texts.contains(edit.text),
  );
}

class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.error, required this.onRetry});
  final String error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          error,
          key: const Key('family-history-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        TextButton(
          onPressed: onRetry,
          child: const Text('Повторить сохранение'),
        ),
      ],
    ),
  );
}

/// Tracks the frozen wanted payloads separately from their immutable journal
/// cores: an append can reject one command before creating its core while another
/// command from the same form is already optimistic. Retry must not lose either.
class _HistorySubmission {
  _HistorySubmission(RoomSession session, Iterable<TreeOperation> operations)
    : beforeIds = session.changes.map((edit) => edit.id).toSet(),
      wanted = List.unmodifiable(
        operations.map(
          (operation) =>
              (operation: operation, payload: jsonEncode(operation.toJson())),
        ),
      );

  final Set<String> beforeIds;
  final List<({TreeOperation operation, String payload})> wanted;
  final _appended = <String>{};

  bool get hasAppended => _appended.isNotEmpty;
  bool get complete => wanted.every((item) => _appended.contains(item.payload));

  void observe(RoomSession session) {
    for (final edit in session.changes) {
      if (!beforeIds.contains(edit.id) &&
          edit.author == session.actorId &&
          wanted.any((item) => item.payload == edit.text)) {
        _appended.add(edit.text);
      }
    }
  }

  Future<void> appendMissing(RoomSession session) async {
    final missing = wanted
        .where((item) => !_appended.contains(item.payload))
        .toList();
    try {
      // Future.sync also captures a synchronous guard failure so it cannot skip
      // starting the remaining wanted commands before the first await.
      await Future.wait([
        for (final item in missing)
          Future<void>.sync(() => session.applyTreeOperation(item.operation)),
      ]);
    } finally {
      observe(session);
    }
    if (!complete) throw StateError('Не все изменения добавлены в историю.');
  }
}

class _FamilyHistoryDialog extends StatefulWidget {
  const _FamilyHistoryDialog({
    required this.session,
    required this.personId,
    required this.nameMode,
    required this.marriage,
    required this.onPickFromTree,
    this.entry,
  });

  final RoomSession session;
  final String personId;
  final ValueNotifier<TreeNameMode> nameMode;
  final bool marriage;
  final TreeFamilyHistoryEntry? entry;
  final Future<String?> Function(String, bool Function(TreePerson))?
  onPickFromTree;

  @override
  State<_FamilyHistoryDialog> createState() => _FamilyHistoryDialogState();
}

class _FamilyHistoryDialogState extends State<_FamilyHistoryDialog> {
  final _name = TextEditingController();
  final _surname = TextEditingController();
  final _reason = TextEditingController();
  final _partnerSurname = TextEditingController();
  late final String _id;
  late bool _changeSurname;
  bool _decline = true;
  bool _partnerDecline = true;
  bool _newPerson = true;
  TreeSex _sex = TreeSex.unknown;
  DateTime? _birthDate;
  DateTime? _date;
  DateTime? _end;
  TreeMarriageEndMode _endMode = TreeMarriageEndMode.unknown;
  String? _partnerId;
  bool _busy = false;
  bool _picking = false;
  _HistorySubmission? _submission;
  bool get _submitted => _submission?.hasAppended ?? false;
  String? _error;

  bool get _editing => widget.entry != null;
  bool get _enabled =>
      !_busy && !_picking && !_submitted && widget.session.canEdit;

  @override
  void initState() {
    super.initState();
    final person = widget.session.tree.person(widget.personId);
    final marriage = widget.entry?.marriage;
    final change = widget.entry?.surnameChange;
    _id = widget.entry?.id ?? 'history-${createRoomId()}';
    _changeSurname =
        marriage?.surnameChoices[widget.personId]?.changeSurname ??
        person?.sex == TreeSex.female;
    if (marriage != null) {
      _partnerId = marriage.otherPersonId(widget.personId);
      _newPerson = false;
      _date = marriage.startDate;
      _end = marriage.endDate;
      _endMode = marriage.endMode;
    } else if (change != null) {
      _date = change.date;
      _surname.text = change.surname.text;
      _decline = change.surname.decline;
      _reason.text = change.reason;
    }
  }

  bool _canPick(TreePerson person) =>
      widget.session.canEdit &&
      person.id != widget.personId &&
      widget.session.tree.person(person.id) != null &&
      widget.session.tree.person(widget.personId) != null;

  Future<void> _pick() async {
    final pick = widget.onPickFromTree;
    if (!_enabled || _editing || pick == null) return;
    setState(() => _picking = true);
    try {
      final id = await pick(_partnerId ?? widget.personId, _canPick);
      if (!mounted || id == null) return;
      final person = widget.session.tree.person(id);
      if (person == null || !_canPick(person)) {
        throw StateError('Человек больше не доступен в дереве.');
      }
      setState(() {
        _partnerId = id;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _picking) return;
    final session = widget.session;
    final operations = <TreeOperation>[];
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_submitted) {
        final submission = _submission!;
        // Existing immutable cores are flushed, never authored again. A payload
        // that was rejected before append is still wanted and remains frozen.
        await session.flush();
        if (!submission.complete) {
          await submission.appendMissing(session);
          await session.flush();
        }
      } else {
        if (!session.canEdit) {
          throw StateError('В режиме гостя нельзя изменять дерево.');
        }
        if (session.tree.person(widget.personId) == null) {
          throw StateError('Человек больше не доступен в дереве.');
        }
        if (widget.marriage) {
          if (_endMode == TreeMarriageEndMode.date && _end == null) {
            throw StateError('Укажите дату окончания брака.');
          }
          final old = widget.entry?.marriage;
          if (old == null) {
            if (_newPerson && _name.text.trim().isEmpty) {
              throw StateError('Укажите имя нового человека.');
            }
            final partnerId = _partnerId ??= _newPerson
                ? 'person-${createRoomId()}'
                : null;
            if (partnerId == null) {
              throw StateError('Выберите человека из дерева.');
            }
            if (!_newPerson) {
              final partner = session.tree.person(partnerId);
              if (partner == null || !_canPick(partner)) {
                throw StateError('Человек больше не доступен в дереве.');
              }
            }
            final surname = _partnerSurname.text.trim();
            operations.add(
              session.tree.addMarriage(
                widget.personId,
                partnerId,
                id: _id,
                startDate: _date,
                endDate: _endMode == TreeMarriageEndMode.date ? _end : null,
                endMode: _endMode,
                changeSurname: _changeSurname,
                newPartner: !_newPerson
                    ? null
                    : TreeNewMarriagePartner(
                        name: _name.text.trim(),
                        sex: _sex,
                        birthDate: _birthDate,
                        birthSurname: surname.isEmpty
                            ? null
                            : TreeSurname(
                                text: surname,
                                decline: _partnerDecline,
                              ),
                      ),
              ),
            );
          } else {
            final end = _endMode == TreeMarriageEndMode.date ? _end : null;
            if (old.isImplied ||
                old.startDate != _date ||
                old.endDate != end ||
                old.endMode != _endMode) {
              operations.add(
                session.tree.updateMarriage(
                  widget.personId,
                  old.id,
                  startDate: _date,
                  endDate: end,
                  endMode: _endMode,
                ),
              );
            }
            final choice = old.surnameChoices[widget.personId];
            if (old.isImplied || choice?.changeSurname != _changeSurname) {
              operations.add(
                session.tree.setMarriageSurname(
                  widget.personId,
                  old.id,
                  changeSurname: _changeSurname,
                  adoptedSurname: _changeSurname
                      ? choice?.adoptedSurname
                      : null,
                ),
              );
            }
          }
        } else {
          final text = _surname.text.trim();
          if (text.isEmpty) throw StateError('Укажите фамилию.');
          final surname = TreeSurname(text: text, decline: _decline);
          final old = widget.entry?.surnameChange;
          if (old == null) {
            operations.add(
              session.tree.addSurnameChange(
                widget.personId,
                id: _id,
                surname: surname,
                date: _date,
                reason: _reason.text.trim(),
              ),
            );
          } else if (old.surname != surname ||
              old.date != _date ||
              old.reason != _reason.text.trim()) {
            operations.add(
              session.tree.updateSurnameChange(
                widget.personId,
                old.id,
                surname: surname,
                date: _date,
                reason: _reason.text.trim(),
              ),
            );
          }
        }
        // Build/validate all operations before appending either half of an edit.
        final submission = _submission = _HistorySubmission(
          session,
          operations,
        );
        await submission.appendMissing(session);
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _submission?.observe(session);
          // With no appended core there is nothing immutable to retry; allow
          // correction of a rejected/invalid draft before the next attempt.
          if (!_submitted) _submission = null;
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickDate({bool end = false}) async {
    if (!_enabled) return;
    final date = await pickFamilyHistoryDate(context, end ? _end : _date);
    if (date != null && mounted) {
      setState(() {
        if (end) {
          _end = date;
        } else {
          _date = date;
        }
      });
    }
  }

  Widget _dateField({bool end = false}) {
    final date = end ? _end : _date;
    final label = end
        ? 'Дата окончания'
        : widget.marriage
        ? 'Дата начала'
        : 'Дата смены фамилии';
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            key: Key(end ? 'history-end-date' : 'history-start-date'),
            onPressed: _enabled ? () => _pickDate(end: end) : null,
            icon: const Icon(Icons.calendar_today_outlined),
            label: Text(date == null ? label : '$label: ${_dateLabel(date)}'),
          ),
        ),
        if (date != null)
          IconButton(
            tooltip: 'Убрать дату',
            onPressed: !_enabled
                ? null
                : () => setState(() {
                    if (end) {
                      _end = null;
                    } else {
                      _date = null;
                    }
                  }),
            icon: const Icon(Icons.clear),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, widget.nameMode]),
    builder: (context, _) {
      final partner = widget.session.tree.person(_partnerId ?? '');
      return PopScope(
        canPop: !_busy && !_picking,
        child: AlertDialog(
          key: const Key('family-history-dialog'),
          title: Text(
            widget.marriage
                ? (_editing ? 'Изменить брак' : 'Брак')
                : (_editing ? 'Изменить смену фамилии' : 'Смена фамилии'),
          ),
          scrollable: true,
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.marriage) ...[
                  if (!_editing) ...[
                    PersonSourceChoice(
                      newPerson: _newPerson,
                      onChanged: !_enabled
                          ? null
                          : (value) => setState(() {
                              _newPerson = value;
                              _partnerId = null;
                            }),
                    ),
                    const SizedBox(height: 12),
                    if (_newPerson) ...[
                      NewPersonFields(
                        keyPrefix: 'marriage-new',
                        name: _name,
                        sex: _sex,
                        birthDate: _birthDate,
                        enabled: _enabled,
                        onSexChanged: (sex) => setState(() => _sex = sex),
                        onBirthDateChanged: (date) =>
                            setState(() => _birthDate = date),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('marriage-new-surname'),
                        controller: _partnerSurname,
                        enabled: _enabled,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Фамилия при рождении',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      CheckboxListTile(
                        value: _partnerDecline,
                        onChanged: !_enabled
                            ? null
                            : (value) => setState(
                                () => _partnerDecline = value ?? true,
                              ),
                        title: const Text('склонять фамилию'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                      ),
                    ] else
                      OutlinedButton(
                        key: const Key('marriage-pick-from-tree'),
                        onPressed: !_enabled || widget.onPickFromTree == null
                            ? null
                            : _pick,
                        child: const Text('Выбрать'),
                      ),
                  ],
                  if (_editing || (!_newPerson && partner != null))
                    Text(
                      partner?.nameForMode(widget.nameMode.value) ??
                          'Удалённый человек',
                      key: const Key('marriage-selected-person'),
                    ),
                  const SizedBox(height: 12),
                ] else ...[
                  TextField(
                    key: const Key('history-surname'),
                    controller: _surname,
                    enabled: _enabled,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Фамилия',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  CheckboxListTile(
                    key: const Key('history-surname-decline'),
                    value: _decline,
                    onChanged: !_enabled
                        ? null
                        : (value) => setState(() => _decline = value ?? true),
                    title: const Text('склонять фамилию'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  ),
                  const SizedBox(height: 8),
                ],
                _dateField(),
                if (widget.marriage) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<TreeMarriageEndMode>(
                    key: ValueKey('history-end-mode-${_endMode.name}'),
                    initialValue: _endMode,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Окончание брака',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final mode in TreeMarriageEndMode.values)
                        DropdownMenuItem(
                          value: mode,
                          child: Text(
                            switch (mode) {
                              TreeMarriageEndMode.unknown => 'Не известно',
                              TreeMarriageEndMode.lifelong => 'Пожизненно',
                              TreeMarriageEndMode.date => 'Дата',
                            },
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: !_enabled
                        ? null
                        : (mode) => setState(
                            () =>
                                _endMode = mode ?? TreeMarriageEndMode.unknown,
                          ),
                  ),
                  if (_endMode == TreeMarriageEndMode.date) ...[
                    const SizedBox(height: 8),
                    _dateField(end: true),
                  ],
                  CheckboxListTile(
                    key: const Key('marriage-change-surname'),
                    value: _changeSurname,
                    onChanged: !_enabled
                        ? null
                        : (value) =>
                              setState(() => _changeSurname = value ?? false),
                    title: const Text('Менять фамилию'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('history-reason'),
                    controller: _reason,
                    enabled: _enabled,
                    maxLines: 3,
                    minLines: 1,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                      labelText: 'Причина',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      key: const Key('family-history-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                if (widget.session.storageError != null &&
                    widget.session.storageError != _error)
                  Text(
                    widget.session.storageError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _busy || _picking
                  ? null
                  : () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const Key('save-family-history'),
              onPressed: _busy || _picking || !widget.session.canEdit
                  ? null
                  : _save,
              child: Text(
                _busy
                    ? 'Сохраняем…'
                    : _submitted
                    ? 'Повторить сохранение'
                    : _editing
                    ? 'Сохранить'
                    : 'Добавить',
              ),
            ),
          ],
        ),
      );
    },
  );

  @override
  void dispose() {
    _name.dispose();
    _surname.dispose();
    _reason.dispose();
    _partnerSurname.dispose();
    super.dispose();
  }
}

/// Shared presentation only; relative and marriage dialogs own their drafts and
/// command lifecycles independently.
class PersonSourceChoice extends StatelessWidget {
  const PersonSourceChoice({
    super.key,
    required this.newPerson,
    required this.onChanged,
    this.allowExisting = true,
  });

  final bool newPerson;
  final ValueChanged<bool>? onChanged;
  final bool allowExisting;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    children: [
      ChoiceChip(
        label: const Text('Новый человек'),
        selected: newPerson,
        onSelected: onChanged == null ? null : (_) => onChanged!(true),
      ),
      ChoiceChip(
        label: const Text('Из дерева'),
        selected: !newPerson,
        onSelected: onChanged == null || !allowExisting
            ? null
            : (_) => onChanged!(false),
      ),
    ],
  );
}

class NewPersonFields extends StatelessWidget {
  const NewPersonFields({
    super.key,
    required this.name,
    required this.sex,
    required this.birthDate,
    required this.onSexChanged,
    required this.onBirthDateChanged,
    required this.keyPrefix,
    this.enabled = true,
  });

  final TextEditingController name;
  final TreeSex sex;
  final DateTime? birthDate;
  final ValueChanged<TreeSex>? onSexChanged;
  final ValueChanged<DateTime>? onBirthDateChanged;
  final String keyPrefix;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      TextField(
        key: Key('$keyPrefix-name'),
        controller: name,
        enabled: enabled,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Имя нового человека',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<TreeSex>(
        key: ValueKey('$keyPrefix-sex-${sex.name}'),
        initialValue: sex,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Пол',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final value in TreeSex.values)
            DropdownMenuItem(
              value: value,
              child: Text(
                switch (value) {
                  TreeSex.male => 'Мужской',
                  TreeSex.female => 'Женский',
                  TreeSex.unknown => 'Пол не указан',
                },
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: !enabled || onSexChanged == null
            ? null
            : (value) => onSexChanged!(value ?? TreeSex.unknown),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: Key('$keyPrefix-birth-date'),
        onPressed: !enabled || onBirthDateChanged == null
            ? null
            : () async {
                final date = await pickFamilyHistoryDate(context, birthDate);
                if (date != null && context.mounted) onBirthDateChanged!(date);
              },
        icon: const Icon(Icons.calendar_today_outlined),
        label: Text(
          birthDate == null
              ? 'Дата рождения (необязательно)'
              : _dateLabel(birthDate!),
        ),
      ),
    ],
  );
}

Future<DateTime?> pickFamilyHistoryDate(
  BuildContext context,
  DateTime? current,
) => showDatePicker(
  context: context,
  initialDate: current ?? DateTime(1970),
  firstDate: DateTime(1),
  lastDate: DateTime(9999, 12, 31),
  helpText: 'Выберите дату',
);

String _dateLabel(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year.toString().padLeft(4, '0')}';
