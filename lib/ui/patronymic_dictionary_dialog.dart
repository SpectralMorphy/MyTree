import 'dart:convert';

import 'package:flutter/material.dart';

import '../room_document.dart';
import '../room_session.dart';
import '../tree/tree_document.dart';

class PatronymicDictionaryDialog extends StatelessWidget {
  const PatronymicDictionaryDialog({super.key, required this.session});

  final RoomSession session;

  Future<void> _edit(BuildContext context, {String? name}) => showDialog<void>(
    context: context,
    builder: (_) => _PatronymicEntryDialog(session: session, name: name),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final overrides = session.tree.patronymicOverrides;
      final entries = {
        ...basePatronymicDictionary,
        ...overrides,
      }.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
      return AlertDialog(
        title: const Text('Словарь отчеств'),
        content: SizedBox(
          width: 480,
          height: MediaQuery.sizeOf(context).height * .55,
          child: ListView.separated(
            key: const Key('patronymic-dictionary-list'),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = entries[index];
              final custom = overrides.containsKey(entry.key);
              return ListTile(
                key: ValueKey('patronymic-entry-${entry.key}'),
                contentPadding: EdgeInsets.zero,
                title: Text(_displayName(entry.key)),
                subtitle: Text(
                  '${entry.value.male.isEmpty ? '—' : entry.value.male} / '
                  '${entry.value.female.isEmpty ? '—' : entry.value.female}',
                ),
                trailing: custom
                    ? const Icon(Icons.bookmark_outline, size: 20)
                    : null,
                onTap: session.canEdit
                    ? () => _edit(context, name: entry.key)
                    : null,
              );
            },
          ),
        ),
        actions: [
          if (session.canEdit)
            TextButton.icon(
              key: const Key('add-patronymic-entry'),
              onPressed: () => _edit(context),
              icon: const Icon(Icons.add),
              label: const Text('Добавить'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      );
    },
  );
}

String _displayName(String name) =>
    name.isEmpty ? name : '${name[0].toUpperCase()}${name.substring(1)}';

class _PatronymicEntryDialog extends StatefulWidget {
  const _PatronymicEntryDialog({required this.session, this.name});

  final RoomSession session;
  final String? name;

  @override
  State<_PatronymicEntryDialog> createState() => _PatronymicEntryDialogState();
}

class _PatronymicEntryDialogState extends State<_PatronymicEntryDialog> {
  late final _name = TextEditingController(
    text: _displayName(widget.name ?? ''),
  );
  final _male = TextEditingController();
  final _female = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _retry = false;
  String _suggestedName = '';

  @override
  void initState() {
    super.initState();
    final name = widget.name;
    if (name != null) {
      final forms = generatePatronymicForms(
        name,
        overrides: widget.session.tree.patronymicOverrides,
      );
      _male.text = forms?.male ?? '';
      _female.text = forms?.female ?? '';
    }
  }

  void _suggestForms(String name) {
    final key = normalizePatronymicName(name);
    if (key == _suggestedName) return;
    _suggestedName = key;
    final forms = generatePatronymicForms(
      name,
      overrides: widget.session.tree.patronymicOverrides,
    );
    _male.text = forms?.male ?? '';
    _female.text = forms?.female ?? '';
  }

  Future<void> _save({bool reset = false}) async {
    final session = widget.session;
    if (_busy || !session.canEdit) return;
    final name = widget.name ?? normalizePatronymicName(_name.text);
    final male = reset ? null : _male.text.trim();
    final female = reset ? null : _female.text.trim();
    var flushOnly = _retry;
    String? submittedText;
    if (!flushOnly) {
      try {
        // Validate once, before persistence; a retry never rebuilds the draft.
        submittedText = jsonEncode(
          session.tree
              .setPatronymicOverride(name, male: male, female: female)
              .toJson(),
        );
      } catch (_) {
        setState(() => _error = 'До 200 символов в поле, без переноса строк.');
        return;
      }
      final current = session.tree.patronymicOverrides[name];
      // Equal optimistic values can still have an outstanding failed save,
      // including when this entry form was closed and reopened.
      flushOnly =
          (reset && current == null) ||
          (!reset &&
              current == TreePatronymicForms(male: male!, female: female!));
    }
    final existingIds = session.changes.map((edit) => edit.id).toSet();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (flushOnly) {
        await session.flush();
      } else {
        await session.setPatronymicOverride(name, male: male, female: female);
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      // A failed optimistic edit must be flushed under its original core,
      // not submitted again as a replacement dictionary operation.
      _retry =
          flushOnly ||
          session.changes.any(
            (edit) =>
                !existingIds.contains(edit.id) &&
                edit.author == session.actorId &&
                edit.kind == RoomEditKind.tree &&
                edit.text == submittedText,
          );
      setState(() => _error = 'Не удалось сохранить: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _male.dispose();
    _female.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final enabled = widget.session.canEdit && !_busy && !_retry;
      final custom =
          widget.name != null &&
          widget.session.tree.patronymicOverrides.containsKey(widget.name);
      return PopScope(
        canPop: !_busy,
        child: AlertDialog(
          title: Text(widget.name == null ? 'Добавить отчества' : 'Отчества'),
          scrollable: true,
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('patronymic-father-name'),
                  controller: _name,
                  enabled: enabled && widget.name == null,
                  autofocus: widget.name == null,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: 'Имя отца'),
                  onChanged: _suggestForms,
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('patronymic-male-form'),
                  controller: _male,
                  enabled: enabled,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: 'Мужское отчество',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('patronymic-female-form'),
                  controller: _female,
                  enabled: enabled,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: 'Женское отчество',
                  ),
                  onSubmitted: enabled ? (_) => _save() : null,
                ),
                if (custom)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('reset-patronymic-entry'),
                      onPressed: enabled ? () => _save(reset: true) : null,
                      child: const Text('Сбросить запись комнаты'),
                    ),
                  ),
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
          actions: [
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const Key('save-patronymic-entry'),
              onPressed: !_busy && widget.session.canEdit
                  ? () => _save()
                  : null,
              child: Text(
                _busy
                    ? 'Сохраняем…'
                    : _retry
                    ? 'Повторить сохранение'
                    : 'Сохранить',
              ),
            ),
          ],
        ),
      );
    },
  );
}
