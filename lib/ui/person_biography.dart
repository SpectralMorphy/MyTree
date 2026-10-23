import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../room_session.dart';
import '../tree/tree_document.dart';
import 'biography_section.dart';
import 'person_dates.dart';
import 'person_family_history.dart';

const _leaf = Color(0xFF53765B);
const _bark = Color(0xFF896C52);
const _maleColor = Color(0xFF875826);
const _femaleColor = Color(0xFF28644B);
const _neutralColor = Color(0xFF686C65);

typedef PickTreePerson =
    Future<String?> Function(
      String initialPersonId,
      bool Function(TreePerson) canPick,
    );

/// The same biography is used by the mobile route and the desktop side panel.
/// Editing writes to the session immediately; closing is never a save action.
class PersonBiography extends StatefulWidget {
  const PersonBiography({
    super.key,
    required this.session,
    required this.personId,
    required this.onSelect,
    required this.onClose,
    this.fullScreen = false,
    this.onPickFromTree,
    this.nameMode,
  });

  final RoomSession session;
  final String personId;
  final ValueChanged<String> onSelect;
  final VoidCallback onClose;
  final bool fullScreen;
  final PickTreePerson? onPickFromTree;
  final ValueNotifier<TreeNameMode>? nameMode;

  @override
  State<PersonBiography> createState() => _PersonBiographyState();
}

class _PersonBiographyState extends State<PersonBiography> {
  final _localNameMode = ValueNotifier(TreeNameMode.givenSurname);
  ValueNotifier<TreeNameMode> get _nameMode =>
      widget.nameMode ?? _localNameMode;

  bool _editing = false;
  bool _binding = false;
  bool _deleting = false;
  bool _deletionPending = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_sessionChanged);
    _nameMode.addListener(_nameModeChanged);
  }

  @override
  void didUpdateWidget(PersonBiography oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nameMode != widget.nameMode) {
      (oldWidget.nameMode ?? _localNameMode).removeListener(_nameModeChanged);
      _nameMode.addListener(_nameModeChanged);
    }
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_sessionChanged);
      widget.session.addListener(_sessionChanged);
    }
    if (oldWidget.personId != widget.personId ||
        oldWidget.session != widget.session) {
      _editing = false;
      _deletionPending = false;
    }
  }

  void _nameModeChanged() => setState(() {});

  void _sessionChanged() {
    if (!mounted) return;
    setState(() {
      if (!widget.session.canEdit) _editing = false;
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    _nameMode.removeListener(_nameModeChanged);
    _localNameMode.dispose();
    super.dispose();
  }

  void _report(Object error) {
    if (mounted) setState(() => _failure = error.toString());
  }

  Future<bool> _act(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (error) {
      _report(error);
      return false;
    }
  }

  Future<void> _retry() async {
    final session = widget.session;
    final personId = widget.personId;
    final retryDeletion = _deletionPending;
    final success = await _act(session.flush);
    if (success &&
        mounted &&
        widget.session == session &&
        widget.personId == personId &&
        session.storageError == null) {
      setState(() {
        _failure = null;
        _deletionPending = false;
      });
      if (retryDeletion && session.durableTree.person(personId) == null) {
        widget.onClose();
      }
    }
  }

  Future<void> _bind() async {
    final person = widget.session.durableTree.person(widget.personId);
    if (person == null ||
        !widget.session.canEdit ||
        !widget.session.canBindToPerson ||
        _binding) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: _nameMode,
        builder: (context, _) => AlertDialog(
          title: const Text('Это вы?'),
          content: Text(
            'Связать ваш профиль с «${person.nameForMode(_nameMode.value)}»?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const Key('confirm-person-binding'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Да, это я'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _binding = true);
    await _act(() => widget.session.bindToPerson(person.id));
    if (mounted) setState(() => _binding = false);
  }

  Future<void> _date(
    TreePerson person, {
    required bool birth,
    DateTime? chosenDate,
  }) async {
    final current = birth ? person.birthDate : person.deathDate;
    final picked = chosenDate ?? await pickPersonDate(context, current);
    if (picked == null || !mounted) return;
    await _act(() async {
      final session = widget.session;
      await session.applyTreeOperation(
        session.tree.setValue(
          person.id,
          birth ? 'birthDate' : 'deathDate',
          _dateValue(picked),
        ),
      );
      // A chosen death date replaces either explicit mark. Leaving `alive`
      // set would make clearing the date fall back to "living".
      if (!birth && session.tree.person(person.id)?.alive != null) {
        await session.applyTreeOperation(
          session.tree.setValue(person.id, 'alive', null),
        );
      }
    });
  }

  Future<void> _markAlive(TreePerson person, {required bool alive}) async {
    await _act(() async {
      final session = widget.session;
      final current = session.tree.person(person.id);
      if (current == null || !session.canEdit) return;
      if (current.deathDate != null) {
        await session.applyTreeOperation(
          session.tree.setValue(person.id, 'deathDate', null),
        );
      }
      if (session.tree.person(person.id)?.alive != alive) {
        await session.applyTreeOperation(
          session.tree.setValue(person.id, 'alive', alive),
        );
      }
    });
  }

  Future<void> _chooseDeathDate(TreePerson person) async {
    final value = await showPersonEndDateDialog(
      context,
      value: (
        mode: person.deathDate != null
            ? PersonEndDateMode.date
            : _shownAlive(person) == true
            ? PersonEndDateMode.ongoing
            : PersonEndDateMode.unknown,
        date: person.deathDate,
      ),
    );
    if (value == null || !mounted || !widget.session.canEdit) return;
    if (value.mode == PersonEndDateMode.date) {
      if (value.date != null) {
        await _date(person, birth: false, chosenDate: value.date);
      }
    } else {
      await _markAlive(person, alive: value.mode == PersonEndDateMode.ongoing);
    }
  }

  void _album() {
    showDialog<void>(
      context: context,
      builder: (context) => _PhotoAlbum(
        session: widget.session,
        personId: widget.personId,
        editing: _editing,
      ),
    );
  }

  void _addRelative() {
    showDialog<void>(
      context: context,
      builder: (context) => _AddRelativeDialog(
        session: widget.session,
        nameMode: _nameMode,
        personId: widget.personId,
        onPickFromTree: widget.onPickFromTree,
      ),
    );
  }

  Future<void> _deletePerson() async {
    final session = widget.session;
    final personId = widget.personId;
    final person = session.tree.person(personId);
    if (!session.canEdit || person == null || _deleting) return;
    setState(() => _deleting = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Удалить человека?'),
          content: Text(
            'Удалить «${person.displayName}» и все его связи из дерева? '
            'Другие люди останутся в дереве. Это действие нельзя отменить.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const Key('confirm-delete-person'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить'),
            ),
          ],
        ),
      );
      if (confirmed != true ||
          !mounted ||
          widget.session != session ||
          widget.personId != personId) {
        return;
      }
      setState(() => _deletionPending = true);
      final success = await _act(
        () => session.applyTreeOperation(session.tree.deletePerson(personId)),
      );
      if (success &&
          mounted &&
          widget.session == session &&
          widget.personId == personId) {
        _deletionPending = false;
        widget.onClose();
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _unlinkParentLinks({
    required String childId,
    required String parentId,
    Iterable<String> fields = const ['fatherId', 'motherId'],
  }) async {
    await _act(() async {
      final session = widget.session;
      final pending = <Future<void>>[];
      for (final field in fields) {
        final tree = session.tree;
        final child = tree.person(childId);
        if (child == null) break;
        final currentParentId = field == 'fatherId'
            ? child.fatherId
            : child.motherId;
        if (currentParentId != parentId) continue;
        pending.add(
          session.applyTreeOperation(tree.setValue(childId, field, null)),
        );
      }
      await Future.wait(pending);
    });
  }

  Future<void> _unlinkSibling(TreeSiblingLink link) async {
    final session = widget.session;
    if (!session.canEdit ||
        (widget.personId != link.personId &&
            widget.personId != link.siblingId) ||
        !session.tree.directSiblingLinks.any(
          (current) => current.id == link.id,
        )) {
      return;
    }
    await _act(
      () => session.applyTreeOperation(
        session.tree.unlinkSibling(link.personId, link.siblingId),
      ),
    );
  }

  Future<void> _moveFact(TreePerson person, int from, int to) async {
    if (from == to) return;
    final ids = person.facts.map((fact) => fact.id).toList();
    final item = ids.removeAt(from);
    ids.insert(to, item);
    await _act(
      () => widget.session.applyTreeOperation(
        widget.session.tree.moveFact(
          person.id,
          item,
          afterId: to > 0 ? ids[to - 1] : null,
          beforeId: to + 1 < ids.length ? ids[to + 1] : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final person = session.tree.person(widget.personId);
    final editing = _editing && session.canEdit;
    final colors = Theme.of(context).colorScheme;
    final body = Material(
      color: colors.surface,
      child: SafeArea(
        top: widget.fullScreen,
        bottom: widget.fullScreen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Биография',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (session.canEdit && person != null)
                    TextButton.icon(
                      key: const Key('biography-edit-toggle'),
                      onPressed: () => setState(() => _editing = !editing),
                      icon: Icon(
                        editing
                            ? Icons.visibility_outlined
                            : Icons.edit_outlined,
                      ),
                      label: Text(editing ? 'Просмотр' : 'Изменить'),
                    ),
                  IconButton(
                    key: const Key('biography-close'),
                    tooltip: 'Закрыть биографию',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (session.saving)
              const LinearProgressIndicator(
                key: Key('biography-saving'),
                minHeight: 2,
                semanticsLabel: 'Сохраняем на устройстве',
              ),
            if (session.storageError != null || _failure != null)
              _SaveError(
                message: session.storageError ?? _failure!,
                onRetry: session.storageError == null ? null : _retry,
                onAcknowledge: () => setState(() => _failure = null),
              ),
            Expanded(
              child: person == null
                  ? const Center(child: Text('Человек не найден в дереве'))
                  : ListView(
                      key: PageStorageKey('biography-${person.id}'),
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                      children: [
                        _identity(person, editing),
                        if (session.canEdit &&
                            session.canBindToPerson &&
                            session.durableTree.person(person.id) != null) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            key: const Key('this-is-me'),
                            onPressed: _binding ? null : _bind,
                            icon: const Icon(Icons.person_pin_outlined),
                            label: Text(
                              _binding ? 'Сохраняем привязку…' : 'Это я',
                            ),
                          ),
                        ] else if (session.canEdit &&
                            session.boundPersonId == person.id)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text(
                              'Ваш профиль',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        const SizedBox(height: 24),
                        _relatives(person, editing: editing),
                        const SizedBox(height: 24),
                        PersonFamilyHistory(
                          key: ValueKey('family-history-${person.id}'),
                          session: session,
                          personId: person.id,
                          nameMode: _nameMode,
                          onSelect: widget.onSelect,
                          onPickFromTree: widget.onPickFromTree,
                          editing: editing,
                        ),
                        const SizedBox(height: 24),
                        BiographySectionHeader(
                          title: 'Факты и воспоминания',
                          trailing: !editing
                              ? null
                              : IconButton(
                                  key: const Key('add-fact'),
                                  tooltip: 'Добавить факт',
                                  onPressed: () => _act(
                                    () => session.applyTreeOperation(
                                      session.tree.addFact(
                                        person.id,
                                        _newId('fact'),
                                      ),
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.add_circle_outline,
                                    color: _leaf,
                                  ),
                                ),
                        ),
                        const SizedBox(height: 8),
                        if (person.facts.isEmpty)
                          Text(
                            editing
                                ? 'Добавьте первый факт кнопкой «+»'
                                : 'Фактов пока нет',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          )
                        else if (editing)
                          ReorderableListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            buildDefaultDragHandles: false,
                            itemCount: person.facts.length,
                            onReorderItem: (from, to) =>
                                _moveFact(person, from, to),
                            itemBuilder: (context, index) => _fact(
                              person,
                              person.facts[index],
                              editing,
                              index,
                            ),
                          )
                        else
                          for (var i = 0; i < person.facts.length; i++)
                            _fact(person, person.facts[i], false, i),
                        const SizedBox(height: 24),
                        _heading('О человеке'),
                        const SizedBox(height: 8),
                        _TreeText(
                          key: ValueKey('biography-text-${person.id}'),
                          session: session,
                          personId: person.id,
                          field: TreeTextField.biography,
                          editing: editing,
                          fieldKey: const Key('person-biography-field'),
                          label: 'Биография',
                          emptyText: 'Биография пока не добавлена',
                          minLines: 5,
                          onError: _report,
                        ),
                        if (editing) ...[
                          const SizedBox(height: 20),
                          OutlinedButton.icon(
                            key: const Key('delete-person'),
                            onPressed: _deleting ? null : _deletePerson,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: colors.error,
                            ),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Удалить человека'),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
    return widget.fullScreen ? Scaffold(body: body) : body;
  }

  Widget _heading(String text) => BiographySectionHeader(title: text);

  Widget _identity(TreePerson person, bool editing) {
    final avatar = person.photos
        .where((photo) => photo.id == person.avatarPhotoId)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Tooltip(
            message: 'Открыть фотоальбом',
            child: InkWell(
              key: const Key('person-avatar'),
              onTap: _album,
              customBorder: const CircleBorder(),
              child: Semantics(
                button: true,
                label: 'Фотоальбом: ${person.displayName}',
                child: Container(
                  width: 108,
                  height: 108,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: _sexColor(person.sex), width: 2),
                  ),
                  child: ClipOval(
                    child: avatar == null
                        ? ColoredBox(
                            color: _sexColor(person.sex).withValues(alpha: .12),
                            child: Icon(
                              _sexIcon(person.sex),
                              size: 52,
                              color: _sexColor(person.sex),
                            ),
                          )
                        : _PhotoImage(dataUrl: avatar.dataUrl),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (editing) ...[
          _TreeText(
            key: ValueKey('name-text-${person.id}'),
            session: widget.session,
            personId: person.id,
            field: TreeTextField.name,
            editing: true,
            fieldKey: const Key('person-name-field'),
            label: 'Имя',
            emptyText: 'Без имени',
            maxLines: 2,
            style: Theme.of(context).textTheme.headlineSmall,
            onError: _report,
          ),
          const SizedBox(height: 12),
          _SurnameEditor(
            key: ValueKey('surname-editor-${person.id}'),
            session: widget.session,
            person: person,
            nameMode: _nameMode.value,
            onError: _report,
          ),
        ] else ...[
          SelectableText(
            person.nameForMode(_nameMode.value),
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 12),
        if (editing) ...[
          DropdownButtonFormField<TreeSex>(
            key: ValueKey('person-sex-${person.id}-${person.sex.name}'),
            initialValue: person.sex,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Пол',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final sex in TreeSex.values)
                DropdownMenuItem(
                  value: sex,
                  child: Row(
                    children: [
                      Icon(_sexIcon(sex), color: _sexColor(sex), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _sexLabel(sex),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            onChanged: (sex) {
              if (sex == null) return;
              _act(
                () => widget.session.applyTreeOperation(
                  widget.session.tree.setValue(person.id, 'sex', sex.name),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _birthDate(person),
          _deathDate(person),
        ] else ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _sexIcon(person.sex),
                color: _sexColor(person.sex),
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(_sexLabel(person.sex)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _lifeDates(person),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _birthDate(TreePerson person) {
    final date = person.birthDate;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('person-birth-date'),
            onPressed: () => _date(person, birth: true),
            icon: const Icon(Icons.calendar_today_outlined, size: 18),
            label: Text(
              'Дата рождения: ${date == null ? 'не указана' : _dateLabel(date)}',
            ),
          ),
        ),
        if (date != null)
          IconButton(
            tooltip: 'Убрать дату рождения',
            onPressed: () => _act(
              () => widget.session.applyTreeOperation(
                widget.session.tree.setValue(person.id, 'birthDate', null),
              ),
            ),
            icon: const Icon(Icons.clear, size: 18),
          ),
      ],
    );
  }

  /// A date takes precedence; legacy birth-only records still read as living.
  bool? _shownAlive(TreePerson person) {
    if (person.deathDate != null) return null;
    return person.alive ?? person.birthDate != null;
  }

  Widget _deathDate(TreePerson person) {
    final date = person.deathDate;
    final label = date != null
        ? _dateLabel(date)
        : _shownAlive(person) == true
        ? 'Жив'
        : 'Не известно';
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('person-death-date'),
            onPressed: () => _chooseDeathDate(person),
            icon: const Icon(Icons.calendar_today_outlined, size: 18),
            label: Text('Дата смерти: $label'),
          ),
        ),
      ],
    );
  }

  Widget _relatives(TreePerson person, {required bool editing}) {
    final tree = widget.session.tree;
    final siblings = tree.siblingsOf(person.id, includeHalf: false);
    final directSiblings = <String, TreeSiblingLink>{
      for (final link in tree.directSiblingLinks)
        if (link.personId == person.id)
          link.siblingId: link
        else if (link.siblingId == person.id)
          link.personId: link,
    };
    final fullIds = siblings.map((person) => person.id).toSet();
    final half = tree
        .siblingsOf(person.id)
        .where((person) => !fullIds.contains(person.id))
        .toList();
    return Column(
      key: const Key('person-relatives'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Родные'),
        const SizedBox(height: 8),
        if (editing) ...[
          OutlinedButton.icon(
            key: const Key('add-relative'),
            onPressed: _addRelative,
            icon: const Icon(Icons.person_add_alt_outlined),
            label: const Text('Добавить родственника'),
          ),
          const SizedBox(height: 12),
        ],
        _relativeGroup(
          'Отец',
          [
            if (person.fatherId != null &&
                tree.person(person.fatherId!) != null)
              tree.person(person.fatherId!)!,
          ],
          onRemove: !editing
              ? null
              : (relative) => _unlinkParentLinks(
                  childId: person.id,
                  parentId: relative.id,
                  fields: const ['fatherId'],
                ),
        ),
        _relativeGroup(
          'Мать',
          [
            if (person.motherId != null &&
                tree.person(person.motherId!) != null)
              tree.person(person.motherId!)!,
          ],
          onRemove: !editing
              ? null
              : (relative) => _unlinkParentLinks(
                  childId: person.id,
                  parentId: relative.id,
                  fields: const ['motherId'],
                ),
        ),
        _relativeGroup(
          'Братья и сёстры',
          siblings,
          onRemove: editing
              ? (relative) => _unlinkSibling(directSiblings[relative.id]!)
              : null,
          canRemove: (relative) => directSiblings.containsKey(relative.id),
          deleteTooltip: 'Убрать прямую братскую связь',
        ),
        if (half.isNotEmpty)
          _relativeGroup('Неполнородные братья и сёстры', half),
        _relativeGroup(
          'Дети',
          tree.childrenOf(person.id),
          onRemove: !editing
              ? null
              : (relative) => _unlinkParentLinks(
                  childId: relative.id,
                  parentId: person.id,
                ),
        ),
      ],
    );
  }

  Widget _relativeGroup(
    String label,
    Iterable<TreePerson> people, {
    ValueChanged<TreePerson>? onRemove,
    bool Function(TreePerson)? canRemove,
    String deleteTooltip = 'удалить связь',
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        if (people.isEmpty)
          Text(
            'Не указаны',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final relative in people)
                if (onRemove == null || canRemove?.call(relative) == false)
                  ActionChip(
                    key: ValueKey('relative-$label-${relative.id}'),
                    avatar: Icon(
                      _sexIcon(relative.sex),
                      size: 18,
                      color: _sexColor(relative.sex),
                    ),
                    label: Text(relative.nameForMode(_nameMode.value)),
                    onPressed: () => widget.onSelect(relative.id),
                  )
                else
                  InputChip(
                    key: ValueKey('relative-$label-${relative.id}'),
                    avatar: Icon(
                      _sexIcon(relative.sex),
                      size: 18,
                      color: _sexColor(relative.sex),
                    ),
                    label: Text(relative.nameForMode(_nameMode.value)),
                    onPressed: () => widget.onSelect(relative.id),
                    deleteIcon: const Icon(Icons.close, size: 18),
                    deleteButtonTooltipMessage: deleteTooltip,
                    onDeleted: () => onRemove(relative),
                  ),
            ],
          ),
      ],
    ),
  );

  Widget _fact(TreePerson person, TreeFact fact, bool editing, int index) {
    final colors = Theme.of(context).colorScheme;
    final palette = _factColors(fact.color, colors.brightness);
    return Container(
      key: ValueKey('fact-${fact.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.fill,
        border: Border(left: BorderSide(color: palette.accent, width: 4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (editing)
            Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: const Tooltip(
                    message: 'Перетащить факт',
                    child: Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.drag_indicator, color: _leaf),
                    ),
                  ),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  key: ValueKey('fact-color-${fact.id}'),
                  tooltip: 'Цвет факта',
                  icon: Icon(Icons.palette_outlined, color: palette.accent),
                  onSelected: (color) => _act(
                    () => widget.session.applyTreeOperation(
                      widget.session.tree.setFactColor(
                        person.id,
                        fact.id,
                        color,
                      ),
                    ),
                  ),
                  itemBuilder: (context) => [
                    for (var i = 0; i < treeFactColors.length; i++)
                      PopupMenuItem(
                        value: treeFactColors[i],
                        child: Row(
                          children: [
                            Icon(
                              Icons.circle,
                              color: _factColors(
                                treeFactColors[i],
                                colors.brightness,
                              ).accent,
                            ),
                            const SizedBox(width: 12),
                            Text('Цвет ${i + 1}'),
                            if (treeFactColors[i] == fact.color) ...[
                              const SizedBox(width: 12),
                              const Icon(Icons.check, size: 18),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
                IconButton(
                  tooltip: 'Удалить факт',
                  onPressed: () => _act(
                    () => widget.session.applyTreeOperation(
                      widget.session.tree.removeFact(person.id, fact.id),
                    ),
                  ),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          _TreeText(
            key: ValueKey('fact-text-${person.id}-${fact.id}'),
            session: widget.session,
            personId: person.id,
            field: TreeTextField.fact,
            itemId: fact.id,
            fieldKey: ValueKey('fact-field-${fact.id}'),
            editing: editing,
            label: 'Факт',
            emptyText: 'Пустой факт',
            minLines: 2,
            style: TextStyle(color: colors.onSurface),
            onError: _report,
          ),
        ],
      ),
    );
  }
}

/// Surname settings are short atomic values, separate from collaborative name
/// and biography text. Empty inherited fields stay empty until explicitly edited.
class _SurnameEditor extends StatefulWidget {
  const _SurnameEditor({
    super.key,
    required this.session,
    required this.person,
    required this.nameMode,
    required this.onError,
  });

  final RoomSession session;
  final TreePerson person;
  final TreeNameMode nameMode;
  final ValueChanged<Object> onError;

  @override
  State<_SurnameEditor> createState() => _SurnameEditorState();
}

class _SurnameEditorState extends State<_SurnameEditor> {
  final _surname = TextEditingController();
  TreeSurname? _explicitSnapshot;
  TreeSurname? _defaultSnapshot;
  bool _decline = true;

  TreePerson? get _father =>
      widget.session.tree.person(widget.person.fatherId ?? '');

  @override
  void initState() {
    super.initState();
    _refresh(initial: true);
  }

  @override
  void didUpdateWidget(_SurnameEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refresh();
  }

  void _refresh({bool initial = false}) {
    final person = widget.person;
    // The domain exposes a legacy value only until the personal register has
    // first been written, including an explicit clear. Opening never migrates it.
    final explicit = person.individualSurname ?? person.familySurname;
    final fallback = _father?.effectiveSurname;
    if (initial || explicit != _explicitSnapshot) {
      _replaceText(_surname, explicit?.text ?? '');
      _decline = (explicit ?? fallback)?.decline ?? true;
    } else if (explicit == null && fallback != _defaultSnapshot) {
      _decline = fallback?.decline ?? true;
    }
    _explicitSnapshot = explicit;
    _defaultSnapshot = fallback;
  }

  // Map a selection across the single replacement in a short LWW field. Do not
  // assign unchanged controller values: this preserves local selection and IME.
  void _replaceText(TextEditingController controller, String next) {
    final value = controller.value;
    final previous = value.text;
    if (previous == next) return;
    var prefix = 0;
    while (prefix < previous.length &&
        prefix < next.length &&
        previous.codeUnitAt(prefix) == next.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < previous.length - prefix &&
        suffix < next.length - prefix &&
        previous.codeUnitAt(previous.length - suffix - 1) ==
            next.codeUnitAt(next.length - suffix - 1)) {
      suffix++;
    }
    int map(int offset) {
      if (offset <= prefix) return offset.clamp(0, next.length);
      if (offset >= previous.length - suffix) {
        return (offset + next.length - previous.length).clamp(0, next.length);
      }
      return next.length - suffix;
    }

    final selection = value.selection;
    final composing = value.composing;
    var mappedComposing = TextRange.empty;
    if (composing.isValid &&
        !composing.isCollapsed &&
        composing.isNormalized &&
        composing.end <= previous.length) {
      final start = map(composing.start);
      final end = map(composing.end);
      if (start < end) mappedComposing = TextRange(start: start, end: end);
    }
    controller.value = TextEditingValue(
      text: next,
      selection: selection.isValid
          ? TextSelection(
              baseOffset: map(selection.baseOffset),
              extentOffset: map(selection.extentOffset),
              affinity: selection.affinity,
              isDirectional: selection.isDirectional,
            )
          : TextSelection.collapsed(offset: next.length),
      composing: mappedComposing,
    );
  }

  Future<void> _save() async {
    if (!widget.session.canEdit) return;
    try {
      await widget.session.applyTreeOperation(
        widget.session.tree.setIndividualSurname(
          widget.person.id,
          text: _surname.text.trim(),
          decline: _decline,
        ),
      );
    } catch (error) {
      widget.onError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final father = _father;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('person-surname-field'),
          controller: _surname,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Фамилия при рождении',
            hintText: father?.effectiveSurname?.text,
            helperText: _explicitSnapshot != null
                ? 'Указана для этого человека'
                : father?.effectiveSurname != null
                ? 'Наследуется от отца: ${father!.nameForMode(widget.nameMode)}'
                : 'Не указана',
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
            suffixIcon: _surname.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Убрать фамилию',
                    onPressed: () {
                      _surname.clear();
                      unawaited(_save());
                    },
                    icon: const Icon(Icons.clear),
                  ),
          ),
          onChanged: (_) => unawaited(_save()),
        ),
        CheckboxListTile(
          key: const Key('surname-decline'),
          value: _decline,
          onChanged: (checked) {
            setState(() => _decline = checked ?? false);
            if (_surname.text.trim().isNotEmpty) unawaited(_save());
          },
          title: const Text('склонять фамилию'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
      ],
    );
  }

  @override
  void dispose() {
    _surname.dispose();
    super.dispose();
  }
}

/// Each controller keeps the atom snapshot corresponding to its visible text.
/// Remote edits transform the selection instead of resetting it to the end.
class _TreeText extends StatefulWidget {
  const _TreeText({
    super.key,
    required this.session,
    required this.personId,
    required this.field,
    required this.editing,
    required this.fieldKey,
    required this.label,
    required this.emptyText,
    required this.onError,
    this.itemId,
    this.minLines = 1,
    this.maxLines,
    this.style,
  });

  final RoomSession session;
  final String personId;
  final TreeTextField field;
  final String? itemId;
  final bool editing;
  final Key fieldKey;
  final String label;
  final String emptyText;
  final ValueChanged<Object> onError;
  final int minLines;
  final int? maxLines;
  final TextStyle? style;

  @override
  State<_TreeText> createState() => _TreeTextState();
}

class _TreeTextState extends State<_TreeText> {
  late TreeTextSnapshot _snapshot;
  late final TextEditingController _controller;

  TreeTextSnapshot _read() => widget.session.tree.textSnapshot(
    widget.personId,
    widget.field,
    itemId: widget.itemId,
  );

  @override
  void initState() {
    super.initState();
    _snapshot = _read();
    _controller = TextEditingController(text: _snapshot.text);
    widget.session.addListener(_refresh);
  }

  @override
  void didUpdateWidget(_TreeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_refresh);
      widget.session.addListener(_refresh);
    }
    _refresh();
  }

  void _refresh() {
    // Listeners run before the parent rebuild disposes a removed item. Do not
    // request a snapshot for its now-tombstoned fact or photograph.
    final person = widget.session.tree.person(widget.personId);
    if (person == null ||
        (widget.field == TreeTextField.fact &&
            !person.facts.any((fact) => fact.id == widget.itemId)) ||
        (widget.field == TreeTextField.photoCaption &&
            !person.photos.any((photo) => photo.id == widget.itemId))) {
      return;
    }
    final next = _read();
    final value = _controller.value;
    if (value.text != next.text) {
      final selection = value.selection;
      final mapped = selection.isValid
          ? TextSelection(
              baseOffset: _snapshot.mapOffsetTo(next, selection.baseOffset),
              extentOffset: _snapshot.mapOffsetTo(next, selection.extentOffset),
              affinity: selection.affinity,
              isDirectional: selection.isDirectional,
            )
          : TextSelection.collapsed(offset: next.text.length);
      final composing = value.composing;
      var mappedComposing = TextRange.empty;
      if (composing.isValid &&
          !composing.isCollapsed &&
          composing.isNormalized &&
          composing.end <= value.text.length) {
        final start = _snapshot
            .mapOffsetTo(next, composing.start)
            .clamp(0, next.text.length);
        final end = _snapshot
            .mapOffsetTo(next, composing.end)
            .clamp(0, next.text.length);
        if (start < end) mappedComposing = TextRange(start: start, end: end);
      }
      _controller.value = TextEditingValue(
        text: next.text,
        selection: mapped,
        composing: mappedComposing,
      );
    }
    _snapshot = next;
  }

  Future<void> _write(String value) async {
    final base = _snapshot;
    try {
      // The session applies the optimistic operation synchronously, before the
      // persistence await. The next keystroke therefore sees its own atom IDs.
      final pending = widget.session.editTreeText(
        widget.personId,
        widget.field,
        value,
        itemId: widget.itemId,
        base: base,
      );
      _snapshot = _read();
      await pending;
    } catch (error) {
      widget.onError(error);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_refresh);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.editing) {
      final text = _snapshot.text;
      return SelectableText(
        text.isEmpty ? widget.emptyText : text,
        style:
            widget.style ??
            (text.isEmpty
                ? TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )
                : null),
      );
    }
    return TextField(
      key: widget.fieldKey,
      controller: _controller,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      textCapitalization: TextCapitalization.sentences,
      style: widget.style,
      decoration: InputDecoration(
        labelText: widget.label,
        border: const OutlineInputBorder(),
        alignLabelWithHint: true,
      ),
      onChanged: (value) => unawaited(_write(value)),
    );
  }
}

class _SaveError extends StatelessWidget {
  const _SaveError({
    required this.message,
    required this.onAcknowledge,
    this.onRetry,
  });
  final String message;
  final VoidCallback? onRetry;
  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Не удалось сохранить изменения. $message',
              key: const Key('biography-save-error'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onRetry ?? onAcknowledge,
                child: Text(
                  onRetry == null ? 'Понятно' : 'Повторить сохранение',
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

enum _RelativeKind { father, mother, sibling, child }

class _AddRelativeDialog extends StatefulWidget {
  const _AddRelativeDialog({
    required this.session,
    required this.personId,
    required this.onPickFromTree,
    required this.nameMode,
  });
  final RoomSession session;
  final String personId;
  final PickTreePerson? onPickFromTree;
  final ValueNotifier<TreeNameMode> nameMode;

  @override
  State<_AddRelativeDialog> createState() => _AddRelativeDialogState();
}

class _AddRelativeDialogState extends State<_AddRelativeDialog> {
  final _name = TextEditingController();
  _RelativeKind _kind = _RelativeKind.father;
  bool _newPerson = true;
  String? _existingId;
  String? _createdId;
  TreeSex _sex = TreeSex.male;
  DateTime? _birthDate;
  bool _busy = false;
  bool _pickingFromTree = false;
  String? _error;
  ({String childId, String field, String parentId})? _submittedLink;
  bool _submittedSibling = false;

  @override
  void initState() {
    super.initState();
    final tree = widget.session.tree;
    _kind =
        const [
          _RelativeKind.father,
          _RelativeKind.mother,
          _RelativeKind.child,
        ].firstWhere(
          (kind) => _kindAvailable(tree, kind),
          orElse: () => _RelativeKind.child,
        );
    _sex = _fixedSex ?? TreeSex.unknown;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _isSibling => _kind == _RelativeKind.sibling;

  bool get _createsNewPerson => _isSibling || _newPerson;

  TreeSex? get _fixedSex => switch (_kind) {
    _RelativeKind.father => TreeSex.male,
    _RelativeKind.mother => TreeSex.female,
    _RelativeKind.sibling || _RelativeKind.child => null,
  };

  bool _matchesRole(TreePerson person) =>
      _fixedSex == null ||
      person.sex == TreeSex.unknown ||
      person.sex == _fixedSex;

  bool _kindAvailable(TreeDocument tree, _RelativeKind kind) {
    final person = tree.person(widget.personId);
    if (person == null) return false;
    return switch (kind) {
      _RelativeKind.father => person.fatherId == null,
      _RelativeKind.mother => person.motherId == null,
      _RelativeKind.sibling || _RelativeKind.child => true,
    };
  }

  bool _targetIsMother(TreePerson focus) =>
      _kind == _RelativeKind.mother ||
      (_kind == _RelativeKind.child && focus.sex == TreeSex.female);

  bool _submittedLinkIsCurrent(TreeDocument tree) {
    final link = _submittedLink;
    if (link == null) return false;
    final child = tree.person(link.childId);
    return child != null &&
        tree.person(link.parentId) != null &&
        (link.field == 'motherId' ? child.motherId : child.fatherId) ==
            link.parentId;
  }

  String? _slotError(
    TreeDocument tree,
    String? relativeId, {
    bool allowSubmittedLink = false,
  }) {
    final focus = tree.person(widget.personId);
    if (focus == null) return 'Человек больше не доступен в дереве.';
    if (_isSibling) return null;
    final child = _kind == _RelativeKind.child
        ? tree.person(relativeId ?? '')
        : focus;
    if (child == null) return null; // A new child has no occupied parent slots.
    final mother = _targetIsMother(focus);
    if ((mother ? child.motherId : child.fatherId) == null) return null;
    final link = _submittedLink;
    if (allowSubmittedLink &&
        link != null &&
        link.childId == child.id &&
        link.field == (mother ? 'motherId' : 'fatherId') &&
        _submittedLinkIsCurrent(tree)) {
      return null;
    }
    return '${mother ? 'Мать уже указана' : 'Отец уже указан'}. '
        'Сначала удалите существующую связь.';
  }

  void _requireAvailableSlot(TreeDocument tree, String? relativeId) {
    if (!widget.session.canEdit) {
      throw StateError('В режиме гостя нельзя изменять дерево.');
    }
    final error = _slotError(tree, relativeId);
    if (error != null) {
      final created = tree.person(_createdId ?? '') != null;
      throw StateError(
        '$error${created ? ' Новый человек остался в дереве, но новая связь не добавлена.' : ''}',
      );
    }
  }

  bool _allowed(TreeDocument tree, String id) =>
      id != widget.personId &&
      (_kind == _RelativeKind.child
          ? !tree.wouldCreateCycle(id, widget.personId)
          : !tree.wouldCreateCycle(widget.personId, id));

  bool _canPick(TreePerson person) {
    final tree = widget.session.tree;
    final current = tree.person(person.id);
    return !_isSibling &&
        widget.session.canEdit &&
        current != null &&
        _slotError(tree, current.id) == null &&
        _matchesRole(current) &&
        _allowed(tree, current.id);
  }

  Future<void> _pickFromTree() async {
    final pick = widget.onPickFromTree;
    if (pick == null ||
        _isSibling ||
        _createdId != null ||
        _busy ||
        _pickingFromTree ||
        !widget.session.canEdit) {
      return;
    }
    final kind = _kind;
    final tree = widget.session.tree;
    if (!_kindAvailable(tree, _kind)) {
      setState(() => _error = _slotError(tree, null));
      return;
    }
    setState(() {
      _pickingFromTree = true;
      _error = null;
    });
    try {
      final initial = widget.session.tree.person(_existingId ?? '') != null
          ? _existingId!
          : widget.personId;
      final id = await pick(initial, _canPick);
      if (!mounted || id == null || _kind != kind || _isSibling) return;
      final person = widget.session.tree.person(id);
      if (person == null || !_canPick(person)) {
        setState(
          () => _error =
              _slotError(widget.session.tree, id) ??
              'Этот человек больше не подходит для выбранной связи. '
                  'Выберите другого человека.',
        );
        return;
      }
      setState(() => _existingId = id);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Не удалось выбрать человека: $error');
      }
    } finally {
      if (mounted) setState(() => _pickingFromTree = false);
    }
  }

  bool _submittedSiblingIsCurrent(TreeDocument tree) =>
      tree.person(widget.personId) != null &&
      tree.person(_createdId ?? '') != null &&
      tree
          .siblingsOf(widget.personId, includeHalf: false)
          .any((person) => person.id == _createdId);

  Future<void> _saveSibling() async {
    final session = widget.session;
    if (_submittedSibling) {
      if (!_submittedSiblingIsCurrent(session.tree)) {
        throw StateError(
          'Связь изменилась. Закройте форму и проверьте дерево.',
        );
      }
      // Creation, DOB and relation are one optimistic event, even when copying
      // both parents leaves no explicit sibling edge. Never create it again.
      await session.flush();
    } else {
      final id = _createdId ??= _newId('person');
      final operation = session.tree.createSibling(
        widget.personId,
        id,
        name: _name.text.trim(),
        sex: _sex,
        birthDate: _birthDate,
      );
      _submittedSibling = true;
      await session.applyTreeOperation(operation);
    }
    if (!_submittedSiblingIsCurrent(session.tree)) {
      throw StateError('Связь изменилась. Закройте форму и проверьте дерево.');
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _submit() async {
    if (_busy || _pickingFromTree) return;
    if (!widget.session.canEdit) {
      setState(() => _error = 'В режиме гостя нельзя изменять дерево.');
      return;
    }
    if (_createsNewPerson && _name.text.trim().isEmpty) {
      setState(() => _error = 'Укажите имя нового человека.');
      return;
    }
    if (!_createsNewPerson && _existingId == null) {
      setState(() => _error = 'Выберите человека из дерева.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_isSibling) {
        await _saveSibling();
        return;
      }
      if (_submittedLink != null) {
        if (!_submittedLinkIsCurrent(widget.session.tree)) {
          throw StateError(
            'Связь изменилась. Закройте форму и проверьте дерево.',
          );
        }
        // Persistence can fail after the link is applied optimistically. Retry
        // that event instead of validating our own edge as a conflict or
        // creating another link operation that could overwrite a remote edit.
        await widget.session.flush();
        if (!_submittedLinkIsCurrent(widget.session.tree)) {
          throw StateError(
            'Связь изменилась. Закройте форму и проверьте дерево.',
          );
        }
        if (mounted) Navigator.pop(context);
        return;
      }
      var id = _newPerson ? _createdId : _existingId;
      // Validate before creation as well as after every persistence await: a
      // stale Add button must not create a disconnected person or replace a
      // parent that arrived remotely while this dialog was open.
      _requireAvailableSlot(widget.session.tree, id);
      if (_newPerson) {
        // Keep the ID even if persistence fails after the optimistic creation.
        // Retrying must not leave a second, disconnected person in the tree.
        id = _createdId ??= _newId('person');
        if (widget.session.tree.person(id) == null) {
          await widget.session.applyTreeOperation(
            widget.session.tree.createPerson(
              id,
              name: _name.text.trim(),
              sex: _fixedSex ?? _sex,
            ),
          );
        } else {
          await widget.session.flush();
        }
        _requireAvailableSlot(widget.session.tree, id);
        if (_birthDate != null &&
            widget.session.tree.person(id)?.birthDate != _birthDate) {
          await widget.session.applyTreeOperation(
            widget.session.tree.setValue(
              id,
              'birthDate',
              _dateValue(_birthDate!),
            ),
          );
        }
      }
      if (id == null) throw StateError('Человек не выбран.');
      final tree = widget.session.tree;
      _requireAvailableSlot(tree, id);
      if (tree.person(id) == null || tree.person(widget.personId) == null) {
        throw StateError('Человек больше не доступен в дереве.');
      }
      if (!_matchesRole(tree.person(id)!)) {
        throw StateError(
          'Пол выбранного человека не соответствует роли родителя. '
          'Выберите другого человека.',
        );
      }
      if (!_allowed(tree, id)) {
        throw StateError(
          'Эта связь создаст цикл родства. Выберите другого человека.',
        );
      }
      final childId = _kind == _RelativeKind.child ? id : widget.personId;
      final parentId = _kind == _RelativeKind.child ? widget.personId : id;
      final mother = _targetIsMother(tree.person(widget.personId)!);
      final field = mother ? 'motherId' : 'fatherId';
      _submittedLink = (childId: childId, field: field, parentId: parentId);
      await widget.session.applyTreeOperation(
        tree.setValue(childId, field, parentId),
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Не удалось добавить родственника: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, widget.nameMode]),
    builder: (context, _) {
      final tree = widget.session.tree;
      final hasCandidates = tree.people.values.any(_canPick);
      final selected = tree.person(_existingId ?? '');
      final kindAvailable = _kindAvailable(tree, _kind);
      // A successful optimistic link also rebuilds this dialog, including its
      // closing animation. Only that exact submitted edge is not a conflict;
      // genuine remote occupancy and explicit save errors remain visible.
      final slotError = _slotError(
        tree,
        _newPerson ? _createdId : _existingId,
        allowSubmittedLink: true,
      );
      final error = _error ?? slotError;
      return PopScope(
        canPop: !_busy,
        child: AlertDialog(
          title: const Text('Добавить родственника'),
          scrollable: true,
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<_RelativeKind>(
                  key: const Key('relative-kind'),
                  initialValue: _kind,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Кого добавить',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: _RelativeKind.father,
                      enabled: _kindAvailable(tree, _RelativeKind.father),
                      child: Text(
                        'Отца',
                        style: _kindAvailable(tree, _RelativeKind.father)
                            ? null
                            : TextStyle(color: Theme.of(context).disabledColor),
                      ),
                    ),
                    DropdownMenuItem(
                      value: _RelativeKind.mother,
                      enabled: _kindAvailable(tree, _RelativeKind.mother),
                      child: Text(
                        'Мать',
                        style: _kindAvailable(tree, _RelativeKind.mother)
                            ? null
                            : TextStyle(color: Theme.of(context).disabledColor),
                      ),
                    ),
                    const DropdownMenuItem(
                      value: _RelativeKind.sibling,
                      child: Text('Брат/сестра'),
                    ),
                    const DropdownMenuItem(
                      value: _RelativeKind.child,
                      child: Text('Ребёнка'),
                    ),
                  ],
                  onChanged:
                      _busy ||
                          _createdId != null ||
                          _submittedLink != null ||
                          !widget.session.canEdit
                      ? null
                      : (kind) {
                          if (kind == null ||
                              _busy ||
                              _createdId != null ||
                              _submittedLink != null ||
                              !widget.session.canEdit ||
                              !_kindAvailable(widget.session.tree, kind)) {
                            return;
                          }
                          setState(() {
                            _kind = kind;
                            _existingId = null;
                            // A sibling is always a new person. Keep that choice
                            // selected so the muted "from tree" chip is not shown
                            // as the current one.
                            if (kind == _RelativeKind.sibling) {
                              _newPerson = true;
                            }
                            _sex = _fixedSex ?? TreeSex.unknown;
                            _error = null;
                          });
                        },
                ),
                const SizedBox(height: 12),
                PersonSourceChoice(
                  newPerson: _newPerson,
                  allowExisting: !_isSibling,
                  onChanged:
                      _busy || _createdId != null || _submittedLink != null
                      ? null
                      : (value) => setState(() => _newPerson = value),
                ),
                const SizedBox(height: 12),
                if (!_createsNewPerson) ...[
                  OutlinedButton(
                    key: const Key('relative-pick-from-tree'),
                    onPressed:
                        _busy ||
                            _submittedLink != null ||
                            _pickingFromTree ||
                            !widget.session.canEdit ||
                            !kindAvailable ||
                            widget.onPickFromTree == null
                        ? null
                        : _pickFromTree,
                    child: const Text('Выбрать'),
                  ),
                  if (selected != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      [
                        selected.nameForMode(widget.nameMode.value),
                        if (selected.lifeYears.isNotEmpty) selected.lifeYears,
                      ].join('\n'),
                      key: const Key('relative-selected-person'),
                    ),
                  ],
                  if (!hasCandidates && kindAvailable) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Нет подходящих людей. Создайте нового человека. Связи, создающие цикл, недоступны.',
                    ),
                  ],
                ] else ...[
                  NewPersonFields(
                    keyPrefix: 'relative-new',
                    name: _name,
                    sex: _fixedSex ?? _sex,
                    birthDate: _birthDate,
                    enabled: !_busy && _createdId == null,
                    onSexChanged: _fixedSex != null
                        ? null
                        : (sex) => setState(() => _sex = sex),
                    onBirthDateChanged: (date) =>
                        setState(() => _birthDate = date),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error,
                    key: const Key('relative-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (widget.session.storageError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    widget.session.storageError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const Key('confirm-add-relative'),
              onPressed:
                  _busy ||
                      _pickingFromTree ||
                      !widget.session.canEdit ||
                      slotError != null
                  ? null
                  : _submit,
              child: Text(
                _busy
                    ? 'Сохраняем…'
                    : _submittedLink != null || _submittedSibling
                    ? 'Повторить сохранение'
                    : 'Добавить',
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _PhotoAlbum extends StatefulWidget {
  const _PhotoAlbum({
    required this.session,
    required this.personId,
    required this.editing,
  });
  final RoomSession session;
  final String personId;
  final bool editing;

  @override
  State<_PhotoAlbum> createState() => _PhotoAlbumState();
}

class _PhotoAlbumState extends State<_PhotoAlbum> {
  bool _busy = false;
  String? _failure;

  Future<bool> _act(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (error) {
      if (mounted) setState(() => _failure = error.toString());
      return false;
    }
  }

  Future<void> _retry() async {
    if (await _act(widget.session.flush) &&
        mounted &&
        widget.session.storageError == null) {
      setState(() => _failure = null);
    }
  }

  Future<void> _upload() async {
    if (_busy || !widget.session.canEdit) return;
    setState(() => _busy = true);
    await _act(() async {
      final files = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Фотографии',
            extensions: ['jpg', 'jpeg', 'png', 'webp'],
            mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
          ),
        ],
      );
      for (final file in files) {
        if (!mounted) return;
        if (await file.length() > 8 * 1024 * 1024) {
          throw FormatException(
            '«${file.name}» больше 8 МБ. Выберите файл меньшего размера.',
          );
        }
        final bytes = await file.readAsBytes();
        if (bytes.length > 8 * 1024 * 1024) {
          throw FormatException('«${file.name}» больше 8 МБ.');
        }
        final image = await _preparePhoto(bytes, file.name);
        if (!mounted) return;
        await widget.session.applyTreeOperation(
          widget.session.tree.addPhoto(
            widget.personId,
            _newId('photo'),
            dataUrl: 'data:image/png;base64,${base64Encode(image)}',
          ),
        );
      }
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _move(TreePerson person, int from, int to) async {
    if (from == to || to < 0 || to >= person.photos.length) return;
    final ids = person.photos.map((photo) => photo.id).toList();
    final id = ids.removeAt(from);
    ids.insert(to, id);
    await _act(
      () => widget.session.applyTreeOperation(
        widget.session.tree.movePhoto(
          person.id,
          id,
          afterId: to > 0 ? ids[to - 1] : null,
          beforeId: to + 1 < ids.length ? ids[to + 1] : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final person = widget.session.tree.person(widget.personId);
      final editing = widget.editing && widget.session.canEdit;
      return PopScope(
        canPop: !_busy,
        child: Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 640,
              maxHeight: math.min(780, MediaQuery.sizeOf(context).height - 32),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 4, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Фотоальбом',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Закрыть альбом',
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                if (_busy)
                  const LinearProgressIndicator(
                    semanticsLabel: 'Обрабатываем и сохраняем фото',
                  ),
                if (_failure != null || widget.session.storageError != null)
                  _SaveError(
                    message: widget.session.storageError ?? _failure!,
                    onRetry: widget.session.storageError == null
                        ? null
                        : _retry,
                    onAcknowledge: () => setState(() => _failure = null),
                  ),
                if (editing)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: OutlinedButton.icon(
                      key: const Key('album-upload'),
                      onPressed: _busy ? null : _upload,
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        color: _leaf,
                      ),
                      label: const Text('Загрузить фотографии'),
                    ),
                  ),
                Expanded(
                  child: person == null || person.photos.isEmpty
                      ? const Center(
                          child: Text('В альбоме пока нет фотографий'),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                          itemCount: person.photos.length,
                          itemBuilder: (context, index) => _photo(
                            person,
                            person.photos[index],
                            index,
                            editing,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _photo(TreePerson person, TreePhoto photo, int index, bool editing) {
    final avatar = person.avatarPhotoId == photo.id;
    return Container(
      key: ValueKey('album-photo-${photo.id}'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: avatar ? _leaf : Theme.of(context).colorScheme.outlineVariant,
          width: avatar ? 3 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 220,
              child: _PhotoImage(dataUrl: photo.dataUrl, fit: BoxFit.contain),
            ),
          ),
          if (avatar)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Аватар',
                textAlign: TextAlign.center,
                style: TextStyle(color: _leaf),
              ),
            ),
          const SizedBox(height: 8),
          _TreeText(
            key: ValueKey('photo-caption-${person.id}-${photo.id}'),
            session: widget.session,
            personId: person.id,
            field: TreeTextField.photoCaption,
            itemId: photo.id,
            fieldKey: ValueKey('photo-caption-field-${photo.id}'),
            label: 'Подпись к фотографии',
            emptyText: 'Без подписи',
            editing: editing && !_busy,
            onError: (error) {
              if (mounted) setState(() => _failure = error.toString());
            },
          ),
          if (editing)
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  key: ValueKey('choose-avatar-${photo.id}'),
                  onPressed: _busy || avatar
                      ? null
                      : () => _act(
                          () => widget.session.applyTreeOperation(
                            widget.session.tree.setValue(
                              person.id,
                              'avatarPhotoId',
                              photo.id,
                            ),
                          ),
                        ),
                  icon: Icon(
                    avatar
                        ? Icons.check_circle_outline
                        : Icons.account_circle_outlined,
                    color: _leaf,
                  ),
                  label: Text(avatar ? 'Выбран аватаром' : 'На аватар'),
                ),
                IconButton(
                  tooltip: 'Фото выше',
                  onPressed: _busy || index == 0
                      ? null
                      : () => _move(person, index, index - 1),
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: 'Фото ниже',
                  onPressed: _busy || index == person.photos.length - 1
                      ? null
                      : () => _move(person, index, index + 1),
                  icon: const Icon(Icons.arrow_downward),
                ),
                IconButton(
                  tooltip: 'Удалить фотографию',
                  onPressed: _busy
                      ? null
                      : () => _act(
                          () => widget.session.applyTreeOperation(
                            widget.session.tree.removePhoto(
                              person.id,
                              photo.id,
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _PhotoImage extends StatefulWidget {
  const _PhotoImage({required this.dataUrl, this.fit = BoxFit.cover});
  final String dataUrl;
  final BoxFit fit;

  @override
  State<_PhotoImage> createState() => _PhotoImageState();
}

class _PhotoImageState extends State<_PhotoImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(_PhotoImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataUrl != widget.dataUrl) _decode();
  }

  void _decode() {
    try {
      final comma = widget.dataUrl.indexOf(',');
      _bytes = comma < 0
          ? null
          : base64Decode(widget.dataUrl.substring(comma + 1));
    } on FormatException {
      _bytes = null;
    }
  }

  Widget _broken() => const Center(
    child: Tooltip(
      message: 'Фотография недоступна или повреждена',
      child: Icon(Icons.broken_image_outlined, color: _bark, size: 36),
    ),
  );

  @override
  Widget build(BuildContext context) => _bytes == null
      ? _broken()
      : Image.memory(
          _bytes!,
          fit: widget.fit,
          gaplessPlayback: true,
          errorBuilder: (context, error, stack) => _broken(),
        );
}

Future<Uint8List> _preparePhoto(Uint8List bytes, String name) async {
  const maxBytes = 700 * 1024;
  ui.Codec? codec;
  ui.Image? source;
  try {
    // ImageDescriptor dimensions are unsupported by Flutter's web renderer.
    // Codec frames and Canvas resizing work on both browser and native engines.
    codec = await ui.instantiateImageCodec(bytes);
    source = (await codec.getNextFrame()).image;
    var scale = math.min(1.0, 1024 / math.max(source.width, source.height));
    for (var attempt = 0; attempt < 8; attempt++) {
      final width = math.max(1, (source.width * scale).round());
      final height = math.max(1, (source.height * scale).round());
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        source,
        ui.Rect.fromLTWH(
          0,
          0,
          source.width.toDouble(),
          source.height.toDouble(),
        ),
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final picture = recorder.endRecording();
      ui.Image? image;
      try {
        image = await picture.toImage(width, height);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          throw const FormatException('Не удалось создать PNG.');
        }
        final result = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        if (result.length <= maxBytes) return result;
        scale *= math.min(.8, math.sqrt(maxBytes / result.length) * .92);
      } finally {
        image?.dispose();
        picture.dispose();
      }
    }
    throw const FormatException('Не удалось уменьшить фотографию до 700 КБ.');
  } catch (error) {
    throw FormatException(
      'Не удалось обработать «$name». Выберите корректный JPG, PNG или WebP. $error',
    );
  } finally {
    source?.dispose();
    codec?.dispose();
  }
}

final _random = math.Random.secure();
String _newId(String prefix) =>
    '$prefix-${base64UrlEncode(List<int>.generate(16, (_) => _random.nextInt(256))).replaceAll('=', '')}';

Color _sexColor(TreeSex sex) => switch (sex) {
  TreeSex.male => _maleColor,
  TreeSex.female => _femaleColor,
  TreeSex.unknown => _neutralColor,
};
IconData _sexIcon(TreeSex sex) => switch (sex) {
  TreeSex.male => Icons.male,
  TreeSex.female => Icons.female,
  TreeSex.unknown => Icons.person_outline,
};
String _sexLabel(TreeSex sex) => switch (sex) {
  TreeSex.male => 'Мужской',
  TreeSex.female => 'Женский',
  TreeSex.unknown => 'Пол не указан',
};
({Color fill, Color accent}) _factColors(String value, Brightness brightness) {
  final base = HSLColor.fromColor(
    Color(int.tryParse(value.replaceFirst('#', 'FF'), radix: 16) ?? 0xFFE6DCCB),
  );
  // Keep the saved palette's coordinated hues; give cards and their palette
  // markers real color instead of applying a second near-transparent wash.
  final vivid = base.withSaturation((base.saturation * 1.5).clamp(0, 1));
  final dark = brightness == Brightness.dark;
  return (
    fill: vivid.withLightness(dark ? .22 : .84).toColor(),
    accent: vivid.withLightness(dark ? .70 : .38).toColor(),
  );
}

String _dateValue(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
String _dateLabel(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year.toString().padLeft(4, '0')}';
String _lifeDates(TreePerson person) {
  final living = person.deathDate != null
      ? null
      : person.alive ?? person.birthDate != null;
  if (person.birthDate == null && person.deathDate == null && living != true) {
    return 'Даты жизни не указаны';
  }
  final birth = person.birthDate == null
      ? 'Дата рождения неизвестна'
      : _dateLabel(person.birthDate!);
  final death = person.deathDate != null
      ? _dateLabel(person.deathDate!)
      : living == true
      ? 'н.в'
      : 'не известно';
  return '$birth — $death';
}
