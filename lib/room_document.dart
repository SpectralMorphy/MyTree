import 'dart:collection';
import 'dart:convert';

import 'room_identity.dart';
import 'tree/tree_document.dart';

const maxParticipantNameLength = 64;
const maxRoomNameLength = 120;
const _maxExactInteger = 9007199254740991; // Exact on both Dart VM and JS.
const maxAuthorBaseLength = 200000;

bool _sameIds(List<String>? left, List<String>? right) {
  if (identical(left, right)) return true;
  if (left == null || right == null || left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

bool _validAuthorProof(Map value) {
  final hasSequence = value.containsKey('authorSequence');
  final hasPrevious = value.containsKey('authorPrevious');
  final hasBase = value.containsKey('authorBase');
  if (!hasSequence) return !hasPrevious && !hasBase;
  final sequence = value['authorSequence'];
  if (!hasPrevious ||
      sequence is! int ||
      sequence < 1 ||
      sequence > _maxExactInteger) {
    return false;
  }
  if (sequence != 1) {
    return !hasBase && isValidRoomActor(value['authorPrevious']);
  }
  final base = value['authorBase'];
  if (value['authorPrevious'] != null ||
      !hasBase ||
      base is! List ||
      base.length > maxAuthorBaseLength) {
    return false;
  }
  String? previous;
  for (final id in base) {
    if (!isValidRoomActor(id) ||
        (previous != null && previous.compareTo(id as String) >= 0)) {
      return false;
    }
    previous = id as String;
  }
  return true;
}

// Includes C0/C1 controls and the Unicode line/paragraph separators. Check the
// input before trimming so a newline cannot silently become a valid name.
bool _isNameControl(int rune) =>
    rune <= 0x1f ||
    (rune >= 0x7f && rune <= 0x9f) ||
    rune == 0x2028 ||
    rune == 0x2029;

String? _normalizeName(String input, int maxLength, {bool allowEmpty = false}) {
  if (input.runes.any(_isNameControl)) return null;
  final name = input.trim();
  return (allowEmpty || name.isNotEmpty) && name.runes.length <= maxLength
      ? name
      : null;
}

/// Returns a canonical single-line alias, including an explicit empty alias.
/// Null means invalid input, not an anonymous participant.
String? normalizeParticipantName(String input) =>
    _normalizeName(input, maxParticipantNameLength, allowEmpty: true);

/// Returns a trimmed, single-line title, or null for empty/invalid input.
String? normalizeRoomName(String input) =>
    _normalizeName(input, maxRoomNameLength);

/// Wire/storage validation requires the name to already be canonical.
bool isValidParticipantName(Object? value) =>
    value is String && normalizeParticipantName(value) == value;

bool isValidRoomName(Object? value) =>
    value is String && normalizeRoomName(value) == value;

enum RoomEditKind {
  text,
  participantName,
  roomName,
  participantRole,
  tree,
  diskConnection,
}

/// Public room metadata only: never accept credentials or extra payload fields.
/// JSON whitespace/key order are preserved as part of the immutable edit text.
bool isValidDiskConnection(String text) {
  try {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) return false;
    final valid = switch (value['action']) {
      'connect' => value.length == 1,
      'disconnect' => value.length == 2 && isValidRoomActor(value['bindingId']),
      _ => false,
    };
    if (!valid) return false;
    // Decoders discard duplicate keys. Count keys in the already valid, flat
    // string-only object so discarded fields cannot hide inside journal text.
    final strings = RegExp(r'("(?:[^"\\]|\\.)*")(\s*:)?');
    return strings.allMatches(text).where((match) => match[2] != null).length ==
        value.length;
  } on FormatException {
    return false;
  }
}

bool _validTreeOperation(String value) {
  try {
    TreeOperation.fromJson(jsonDecode(value));
    return true;
  } catch (_) {
    return false;
  }
}

RoomRole? _roleFromText(String text) => switch (text) {
  'guest' => RoomRole.guest,
  'editor' => RoomRole.editor,
  _ => null,
};

class RoomEdit {
  const RoomEdit({
    required this.id,
    required this.author,
    required this.clock,
    required this.createdAt,
    required this.text,
    this.kind = RoomEditKind.text,
    this.targetActor,
  }) : authorSequence = null,
       authorPrevious = null,
       authorBase = null;

  RoomEdit._withAuthorProof(
    RoomEdit source, {
    required this.authorSequence,
    required this.authorPrevious,
    List<String>? authorBase,
  }) : id = source.id,
       author = source.author,
       clock = source.clock,
       createdAt = source.createdAt,
       text = source.text,
       kind = source.kind,
       targetActor = source.targetActor,
       authorBase = authorBase == null ? null : List.unmodifiable(authorBase);

  final String id;
  final String author;
  final int clock;
  final int createdAt;
  final String text;
  final RoomEditKind kind;

  /// Only role operations have a subject distinct from their issuing author.
  final String? targetActor;

  /// A journal prefix proof, independent of wall time and projection stamps.
  /// Null means an unchanged legacy entry or an unpersisted local draft.
  final int? authorSequence;
  final String? authorPrevious;

  /// The sorted, immutable legacy IDs sealed by this author's first proof.
  /// Absent on legacy entries and all subsequent proofs; empty is meaningful.
  final List<String>? authorBase;

  RoomEdit withAuthorProof({
    required int authorSequence,
    required String? authorPrevious,
    List<String>? authorBase,
  }) {
    final proof = {
      'authorSequence': authorSequence,
      'authorPrevious': authorPrevious,
      if (authorBase != null) 'authorBase': authorBase,
    };
    if (!_validAuthorProof(proof)) {
      throw const FormatException('Неверная последовательность автора');
    }
    return RoomEdit._withAuthorProof(
      this,
      authorSequence: authorSequence,
      authorPrevious: authorPrevious,
      authorBase: authorBase,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'author': author,
    'clock': clock,
    'createdAt': createdAt,
    'text': text,
    if (kind != RoomEditKind.text) 'kind': kind.name,
    if (targetActor != null) 'targetActor': targetActor,
    if (authorSequence != null) ...{
      'authorSequence': authorSequence,
      'authorPrevious': authorPrevious,
      if (authorBase != null) 'authorBase': authorBase,
    },
  };

  static RoomEdit? fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['author'] is! String ||
        (value['author'] as String).isEmpty ||
        value['clock'] is! int ||
        (value['clock'] as int) < 0 ||
        value['createdAt'] is! int ||
        value['text'] is! String ||
        !_validAuthorProof(value)) {
      return null;
    }
    final RoomEditKind kind;
    if (!value.containsKey('kind')) {
      kind = RoomEditKind.text;
    } else {
      switch (value['kind']) {
        case 'text':
          kind = RoomEditKind.text;
        case 'participantName':
          kind = RoomEditKind.participantName;
        case 'roomName':
          kind = RoomEditKind.roomName;
        case 'participantRole':
          kind = RoomEditKind.participantRole;
        case 'tree':
          kind = RoomEditKind.tree;
        case 'diskConnection':
          kind = RoomEditKind.diskConnection;
        default:
          return null;
      }
    }
    final text = value['text'] as String;
    final targetActor = value['targetActor'];
    if ((kind == RoomEditKind.participantName &&
            !isValidParticipantName(text)) ||
        (kind == RoomEditKind.roomName && !isValidRoomName(text)) ||
        (kind == RoomEditKind.tree && !_validTreeOperation(text)) ||
        (kind == RoomEditKind.diskConnection && !isValidDiskConnection(text)) ||
        (kind == RoomEditKind.participantRole
            ? _roleFromText(text) == null || !isValidRoomActor(targetActor)
            : value.containsKey('targetActor'))) {
      return null;
    }
    final edit = RoomEdit(
      id: value['id'] as String,
      author: value['author'] as String,
      clock: value['clock'] as int,
      createdAt: value['createdAt'] as int,
      text: text,
      kind: kind,
      targetActor: targetActor as String?,
    );
    return value.containsKey('authorSequence')
        ? edit.withAuthorProof(
            authorSequence: value['authorSequence'] as int,
            authorPrevious: value['authorPrevious'] as String?,
            authorBase: (value['authorBase'] as List?)?.cast<String>(),
          )
        : edit;
  }

  bool sameContentAs(RoomEdit other) =>
      sameCoreAs(other) &&
      authorSequence == other.authorSequence &&
      authorPrevious == other.authorPrevious &&
      _sameIds(authorBase, other.authorBase);

  /// Core payloads never change when storage assigns a draft's prefix proof.
  bool sameCoreAs(RoomEdit other) =>
      id == other.id &&
      author == other.author &&
      clock == other.clock &&
      createdAt == other.createdAt &&
      text == other.text &&
      kind == other.kind &&
      targetActor == other.targetActor;

  int compareTo(RoomEdit other) {
    final byClock = clock.compareTo(other.clock);
    return byClock != 0 ? byClock : id.compareTo(other.id);
  }
}

/// Validates batch syntax and immutable IDs, not author-prefix closure.
/// Chunks and inventory subsets may legitimately omit a proof's dependencies.
List<RoomEdit> decodeRoomHistory(Object? value) {
  if (value is! List) throw const FormatException('Неверная история');
  final edits = <RoomEdit>[];
  final ids = <String, RoomEdit>{};
  for (final raw in value) {
    final edit = RoomEdit.fromJson(raw);
    if (edit == null ||
        !isValidRoomActor(edit.id) ||
        !isValidRoomActor(edit.author) ||
        edit.clock > _maxExactInteger ||
        edit.createdAt < 0 ||
        edit.createdAt > _maxExactInteger) {
      throw const FormatException('Неверная запись истории');
    }
    final duplicate = ids[edit.id];
    if (duplicate != null && !duplicate.sameContentAs(edit)) {
      throw const FormatException('ID изменения не является неизменяемым');
    }
    ids[edit.id] = edit;
    edits.add(edit);
  }
  return edits;
}

bool _validHistoryEdit(RoomEdit edit) {
  if (!isValidRoomActor(edit.id) ||
      !isValidRoomActor(edit.author) ||
      edit.clock < 0 ||
      edit.clock > _maxExactInteger ||
      edit.createdAt < 0 ||
      edit.createdAt > _maxExactInteger) {
    return false;
  }
  if (edit.kind == RoomEditKind.participantRole) {
    return _roleFromText(edit.text) != null &&
        isValidRoomActor(edit.targetActor);
  }
  if (edit.targetActor != null) return false;
  return switch (edit.kind) {
    RoomEditKind.text => true,
    RoomEditKind.participantName => isValidParticipantName(edit.text),
    RoomEditKind.roomName => isValidRoomName(edit.text),
    RoomEditKind.tree => _validTreeOperation(edit.text),
    RoomEditKind.diskConnection => isValidDiskConnection(edit.text),
    RoomEditKind.participantRole => false,
  };
}

/// Validates per-author prefixes and returns a deterministic topological order.
/// A first proof seals exactly the known legacy entries of its own author.
/// Other authors' histories remain independent and may still be all-legacy.
///
/// Partial validation is for subsets only: missing dependencies are allowed,
/// but observable forks, conflicting IDs and baseline violations never are.
List<RoomEdit> validateAuthorHistory(
  Iterable<RoomEdit> history, {
  bool requireComplete = true,
}) {
  final ids = <String, RoomEdit>{};
  final authors = <String, List<RoomEdit>>{};
  for (final edit in history) {
    if (!_validHistoryEdit(edit)) {
      throw const FormatException('Неверная запись истории');
    }
    final duplicate = ids[edit.id];
    if (duplicate != null) {
      if (!duplicate.sameContentAs(edit)) {
        throw const FormatException('ID изменения не является неизменяемым');
      }
      continue;
    }
    ids[edit.id] = edit;
    (authors[edit.author] ??= []).add(edit);
  }
  for (final edits in authors.values) {
    final legacy = <String>{};
    final sequences = <int, RoomEdit>{};
    final successors = <String, RoomEdit>{};
    for (final edit in edits) {
      final sequence = edit.authorSequence;
      if (sequence == null) {
        legacy.add(edit.id);
        continue;
      }
      if (sequences.containsKey(sequence)) {
        throw const FormatException('Разветвление последовательности автора');
      }
      sequences[sequence] = edit;
      final previous = edit.authorPrevious;
      if (previous != null && successors.containsKey(previous)) {
        throw const FormatException('Разветвление последовательности автора');
      }
      if (previous != null) successors[previous] = edit;
    }
    if (sequences.isEmpty) continue;
    final first = sequences[1];
    if (first == null) {
      if (requireComplete) {
        throw const FormatException('Отсутствует начало истории автора');
      }
    } else {
      final base = first.authorBase!.toSet();
      if (!legacy.every(base.contains) ||
          (requireComplete && base.length != legacy.length)) {
        throw const FormatException('Изменилась исходная история автора');
      }
      for (final id in base) {
        final baseline = ids[id];
        if (baseline == null) {
          if (requireComplete) {
            throw const FormatException('Неполная исходная история автора');
          }
        } else if (baseline.author != first.author ||
            baseline.authorSequence != null) {
          throw const FormatException('Неверная исходная история автора');
        }
      }
    }
    for (final edit in sequences.values) {
      if (edit.authorSequence == 1) continue;
      final previous = ids[edit.authorPrevious];
      if (previous == null) {
        if (requireComplete) {
          throw const FormatException(
            'Отсутствует предыдущее изменение автора',
          );
        }
      } else if (previous.author != edit.author ||
          previous.authorSequence != edit.authorSequence! - 1) {
        throw const FormatException('Неверное предыдущее изменение автора');
      }
    }
  }
  return _orderAvailableAuthorHistory(ids.values);
}

/// Complete durable histories must pass prefix validation before use.
List<RoomEdit> orderAuthorHistory(Iterable<RoomEdit> history) =>
    validateAuthorHistory(history);

/// Assigns proof using the journal observed inside an atomic storage append.
/// Retrying the same core ID returns the exact stored, canonical entry.
RoomEdit sequenceAuthoredEdit(RoomEdit draft, Iterable<RoomEdit> persisted) {
  final history = validateAuthorHistory(persisted);
  if (!_validHistoryEdit(draft)) {
    throw const FormatException('Неверная запись истории');
  }
  RoomEdit? head;
  final base = <String>[];
  for (final edit in history) {
    if (edit.id == draft.id) {
      if (!edit.sameCoreAs(draft)) {
        throw const FormatException('ID изменения не является неизменяемым');
      }
      return edit;
    }
    if (edit.author != draft.author) continue;
    if (edit.authorSequence == null) {
      base.add(edit.id);
    } else if (head == null || edit.authorSequence! > head.authorSequence!) {
      head = edit;
    }
  }
  if (draft.authorSequence != null) {
    throw const FormatException(
      'Изменение уже имеет последовательность автора',
    );
  }
  if (head != null && head.authorSequence == _maxExactInteger) {
    throw const FormatException('Исчерпана последовательность автора');
  }
  return draft.withAuthorProof(
    authorSequence: head == null ? 1 : head.authorSequence! + 1,
    authorPrevious: head?.id,
    authorBase: head == null ? (base..sort()) : null,
  );
}

/// Stable Kahn order: preserve available author dependencies, choosing the old
/// clock/ID key among ready entries. Missing optimistic dependencies are ignored.
List<RoomEdit> _orderAvailableAuthorHistory(Iterable<RoomEdit> history) {
  final ids = {for (final edit in history) edit.id: edit};
  final remaining = {for (final id in ids.keys) id: 0};
  final successors = <String, List<RoomEdit>>{};
  for (final edit in ids.values) {
    final dependencies = edit.authorSequence == null
        ? const <String>[]
        : edit.authorSequence == 1
        ? edit.authorBase!
        : [edit.authorPrevious!];
    for (final id in dependencies) {
      if (!ids.containsKey(id)) continue;
      remaining[edit.id] = remaining[edit.id]! + 1;
      (successors[id] ??= []).add(edit);
    }
  }
  final ready = SplayTreeSet<RoomEdit>((a, b) => a.compareTo(b));
  for (final edit in ids.values) {
    if (remaining[edit.id] == 0) ready.add(edit);
  }
  final ordered = <RoomEdit>[];
  while (ready.isNotEmpty) {
    final edit = ready.first;
    ready.remove(edit);
    ordered.add(edit);
    for (final next in successors[edit.id] ?? const <RoomEdit>[]) {
      final count = remaining[next.id]! - 1;
      remaining[next.id] = count;
      if (count == 0) ready.add(next);
    }
  }
  if (ordered.length != ids.length) {
    throw const FormatException('Цикл в истории автора');
  }
  return ordered;
}

/// Immutable edit IDs deduplicate retries. Projection stamps retain their LWW
/// clock/ID order; author proofs order the journal, not conflict resolution.
class RoomDocument {
  final _edits = <String, RoomEdit>{};
  final _participantNames = <String, RoomEdit>{};
  final _participantRoles = <String, RoomRole>{};
  RoomEdit? _latest;
  RoomEdit? _roomName;
  int _clock = 0;

  /// Metadata never replaces the displayed text or its winning edit.
  RoomEdit? get latest => _latest;
  String get text => _latest?.text ?? '';
  String get roomName => _roomName?.text ?? 'Комната';
  Map<String, String> get participantNames => Map.unmodifiable({
    for (final entry in _participantNames.entries) entry.key: entry.value.text,
  });

  /// Explicit roles only. Unrecorded legacy participants remain editors.
  Map<String, RoomRole> get participantRoles =>
      Map.unmodifiable(_participantRoles);
  RoomRole roleFor(String actor) => _participantRoles[actor] ?? RoomRole.editor;

  int get historyLength => _edits.length;
  // Optimistic drafts may not have a proof yet. Durable boundaries validate
  // closure separately; the view still honors every available dependency.
  List<RoomEdit> get history => _orderAvailableAuthorHistory(_edits.values);

  List<Map<String, dynamic>> toJson() =>
      history.map((edit) => edit.toJson()).toList();

  RoomEdit createEdit(
    String author,
    String text, {
    DateTime? now,
    RoomEditKind kind = RoomEditKind.text,
    String? targetActor,
    String? id,
  }) {
    if (id != null && !isValidRoomActor(id)) {
      throw const FormatException('Неверный ID изменения');
    }
    if (kind == RoomEditKind.participantRole
        ? !isValidRoomActor(targetActor)
        : targetActor != null) {
      throw const FormatException('Неверный адресат роли');
    }
    final value = switch (kind) {
      RoomEditKind.text => text,
      RoomEditKind.participantName => normalizeParticipantName(text),
      RoomEditKind.roomName => normalizeRoomName(text),
      RoomEditKind.participantRole => _roleFromText(text)?.name,
      RoomEditKind.tree => _validTreeOperation(text) ? text : null,
      RoomEditKind.diskConnection => isValidDiskConnection(text) ? text : null,
    };
    if (value == null) {
      throw FormatException(switch (kind) {
        RoomEditKind.participantRole => 'Неверная роль',
        RoomEditKind.diskConnection => 'Неверные данные подключения Диска',
        _ => 'Неверное имя',
      });
    }
    final time = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    return RoomEdit(
      id: id ?? createRoomId(),
      author: author,
      clock: time > _clock ? time : _clock + 1,
      createdAt: time,
      text: value,
      kind: kind,
      targetActor: targetActor,
    );
  }

  /// Only the owner of a provisional local draft may invoke this after its
  /// atomic append. No core field or winning projection stamp is reapplied.
  /// RoomHistory tracks ownership; ordinary merge never replaces an ID.
  RoomEdit finalizeAuthored(RoomEdit finalized) {
    final previous = _edits[finalized.id];
    if (previous == null ||
        finalized.authorSequence == null ||
        !previous.sameCoreAs(finalized)) {
      throw const FormatException('Нельзя завершить это изменение автора');
    }
    if (previous.sameContentAs(finalized)) return previous;
    if (previous.authorSequence != null) {
      throw const FormatException('Последовательность автора уже неизменяема');
    }
    _edits[finalized.id] = finalized;
    if (_latest?.id == finalized.id) _latest = finalized;
    if (_roomName?.id == finalized.id) _roomName = finalized;
    if (_participantNames[finalized.author]?.id == finalized.id) {
      _participantNames[finalized.author] = finalized;
    }
    return finalized;
  }

  List<RoomEdit> merge(Iterable<RoomEdit> edits) {
    final added = <RoomEdit>[];
    for (final edit in edits) {
      if (_edits.containsKey(edit.id)) {
        continue;
      }
      _edits[edit.id] = edit;
      added.add(edit);
      if (edit.clock > _clock) {
        _clock = edit.clock;
      }
      switch (edit.kind) {
        case RoomEditKind.text:
          if (_latest == null || edit.compareTo(_latest!) > 0) {
            _latest = edit;
          }
        case RoomEditKind.participantName:
          final previous = _participantNames[edit.author];
          if (previous == null || edit.compareTo(previous) > 0) {
            _participantNames[edit.author] = edit;
          }
        case RoomEditKind.roomName:
          if (_roomName == null || edit.compareTo(_roomName!) > 0) {
            _roomName = edit;
          }
        case RoomEditKind.participantRole:
          final target = edit.targetActor!;
          // Promotion is monotonic: an initial guest record arriving late (or
          // carrying a higher clock) must never undo an explicit editor role.
          if (_participantRoles[target] != RoomRole.editor) {
            _participantRoles[target] = _roleFromText(edit.text)!;
          }
        case RoomEditKind.tree:
        case RoomEditKind.diskConnection:
          // Domain projections replay these operations separately.
          break;
      }
    }
    return added;
  }
}
