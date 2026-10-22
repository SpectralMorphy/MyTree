import 'dart:collection';
import 'dart:convert';

import '../room_identity.dart';
import 'patronymic.dart';

export 'patronymic.dart';

enum TreeSex { unknown, male, female }

enum TreeNameMode { givenSurname, surnameGivenPatronymic }

enum TreeTextField { name, biography, fact, photoCaption }

const rootTreePersonId = 'root';
const maxTreeTextLength = 100000;
const maxTreeSurnameLength = 200;
const maxTreePatronymicLength = 200;
const maxTreePhotoBytes = 700 * 1024;
const treeFactColors = <String>[
  '#E6DCCB',
  '#D5DFC8',
  '#D1DED9',
  '#D7DCE8',
  '#E4D5DF',
  '#E8D4C4',
];
const treeFactPalette = treeFactColors;
const defaultTreeFactColor = '#E6DCCB';

class TreeFact {
  const TreeFact({
    required this.id,
    this.text = '',
    this.color = defaultTreeFactColor,
  });

  final String id;
  final String text;
  final String color;
}

class TreePhoto {
  const TreePhoto({required this.id, required this.dataUrl, this.caption = ''});

  final String id;
  final String dataUrl;
  final String caption;
}

/// Canonical base spelling. Rendered forms never become inherited values.
class TreeSurname {
  const TreeSurname({required this.text, this.decline = false});

  final String text;
  final bool decline;

  String formForSex(TreeSex sex) =>
      decline && sex == TreeSex.female ? '$textа' : text;

  String get plural => decline ? '$textы' : text;

  @override
  bool operator ==(Object other) =>
      other is TreeSurname && other.text == text && other.decline == decline;

  @override
  int get hashCode => Object.hash(text, decline);
}

/// One active undirected sibling claim. Its ID is the immutable creation event.
class TreeSiblingLink {
  const TreeSiblingLink({
    required this.id,
    required this.personId,
    required this.siblingId,
  });

  final String id;
  final String personId;
  final String siblingId;
}

class TreePerson {
  TreePerson({
    required this.id,
    this.name = '',
    this.biography = '',
    this.sex = TreeSex.unknown,
    this.birthDate,
    this.deathDate,
    this.alive,
    this.fatherId,
    this.motherId,
    Iterable<TreeFact> facts = const [],
    Iterable<TreePhoto> photos = const [],
    this.avatarPhotoId,
    this.familySurname,
    this.individualSurname,
    this.maidenSurname,
    TreeSurname? effectiveSurname,
    this.surnameInheritedFrom,
    TreePatronymicForms? fatherPatronymicForms,
  }) : effectiveSurname =
           effectiveSurname ?? individualSurname ?? familySurname,
       _fatherPatronymicForms = fatherPatronymicForms,
       facts = List.unmodifiable(facts),
       photos = List.unmodifiable(photos);

  final String id;
  final String name;
  final String biography;
  final TreeSex sex;
  final DateTime? birthDate;
  final DateTime? deathDate;

  /// Explicit death-date choice when [deathDate] is absent. `true` is living,
  /// `false` is unknown. Null keeps the legacy display.
  final bool? alive;
  final String? fatherId;
  final String? motherId;
  final List<TreeFact> facts;
  final List<TreePhoto> photos;
  final String? avatarPhotoId;

  /// Read-only historical family fallback, hidden after any personal edit.
  final TreeSurname? familySurname;

  /// This person's explicit configuration; null means father inheritance.
  final TreeSurname? individualSurname;
  final TreeSurname? maidenSurname;
  final TreeSurname? effectiveSurname;

  /// Immediate father, only when the effective value is inherited from him.
  final String? surnameInheritedFrom;

  /// Projection-only forms from the accepted father's current given-name text.
  /// There is no editable or persisted person patronymic register.
  final TreePatronymicForms? _fatherPatronymicForms;

  String get displayName => name.trim().isEmpty ? 'Без имени' : name;
  String get surname => effectiveSurname?.formForSex(sex) ?? '';
  String get patronymic => fatherId == null
      ? ''
      : switch (sex) {
          TreeSex.male => _fatherPatronymicForms?.male ?? '',
          TreeSex.female => _fatherPatronymicForms?.female ?? '',
          TreeSex.unknown => '',
        };

  String get fullName {
    final givenName = name.trim();
    return [
      givenName.isEmpty ? displayName : givenName,
      if (surname.isNotEmpty) surname,
    ].join(' ');
  }

  String nameForMode(TreeNameMode mode) {
    if (mode == TreeNameMode.givenSurname) return fullName;
    final givenName = name.trim();
    return [
      if (surname.isNotEmpty) surname,
      givenName.isEmpty ? displayName : givenName,
      if (patronymic.isNotEmpty) patronymic,
    ].join(' ');
  }

  String get fullNameWithPatronymic =>
      nameForMode(TreeNameMode.surnameGivenPatronymic);

  /// Year span. A death date wins. Otherwise explicit [alive] chooses `н.в.`
  /// or `?`. With no explicit choice, a missing death is `н.в.` only when a
  /// birth date exists; both missing stays `?–?`.
  String get lifeYears {
    if (deathDate != null) {
      return '${birthDate?.year ?? '?'}–${deathDate!.year}';
    }
    final living = alive ?? birthDate != null;
    if (!living && birthDate == null) return '?–?';
    return '${birthDate?.year ?? '?'}–${living ? 'н.в.' : '?'}';
  }
}

/// Display order: unknown birth dates count as oldest, then ascending birth date,
/// normalized given name (trimmed, lowercase, ё = е), and identity.
/// This never changes the document or history.
int compareTreePeopleByBirth(TreePerson a, TreePerson b) {
  final aBirth = a.birthDate;
  final bBirth = b.birthDate;
  if (aBirth == null && bBirth != null) return -1;
  if (aBirth != null && bBirth == null) return 1;
  if (aBirth != null && bBirth != null) {
    final birthOrder = aBirth.compareTo(bBirth);
    if (birthOrder != 0) return birthOrder;
  }
  final nameOrder = a.name
      .trim()
      .toLowerCase()
      .replaceAll('ё', 'е')
      .compareTo(b.name.trim().toLowerCase().replaceAll('ё', 'е'));
  return nameOrder != 0 ? nameOrder : a.id.compareTo(b.id);
}

/// The same role-sensitive block identity used by the layout. A missing parent
/// never groups half siblings or people with unknown parents into one family.
String treeSurnameFamilyKey(TreePerson person) =>
    _surnameFamilyKey(person.id, person.fatherId, person.motherId);

String _surnameFamilyKey(String id, String? father, String? mother) =>
    father != null && mother != null
    ? 'parents:${father.length}:$father:${mother.length}:$mother'
    : 'person:${id.length}:$id';

/// Render a block only when all its members agree on a canonical config.
String surnameForBlock(Iterable<TreePerson> people) {
  final members = people.toList();
  if (members.isEmpty ||
      members.every((person) => person.effectiveSurname == null)) {
    return '';
  }
  if (members.length == 1) return members.single.surname;
  final surname = members.first.effectiveSurname;
  if (surname == null ||
      members.any((person) => person.effectiveSurname != surname)) {
    return 'разные фамилии';
  }
  return surname.plural;
}

/// A validated, deeply immutable JSON operation. Stamps belong to the journal,
/// not to this payload. Unknown keys/types are rejected rather than ignored.
class TreeOperation {
  TreeOperation._(Map<String, Object?> json) : _json = _freezeMap(json);

  final Map<String, Object?> _json;
  late final String _encoded = jsonEncode(_json);

  String get type => _json['type']! as String;
  bool get isRoomScoped => type == 'setPatronymicOverride';

  /// Room operations have no person target or serialized personId.
  String get personId => isRoomScoped ? '' : _json['personId']! as String;
  String? get itemId => _json['itemId'] as String?;

  String get fieldKey => switch (type) {
    'createPerson' || 'createSibling' || 'deletePerson' => 'person',
    'unlinkSibling' => 'sibling:${_json['linkId']}',
    'setPatronymicOverride' => 'patronymic:${_json['name']}',
    'setValue' => _json['field']! as String,
    'setSurname' =>
      _json['scope'] == 'family'
          ? 'surname:family:${_json['familyKey']}'
          : 'surname:${_json['scope']}',
    'editText' => switch (_json['field']) {
      'fact' => 'fact:$itemId:text',
      'photoCaption' => 'photo:$itemId:caption',
      _ => _json['field']! as String,
    },
    'addFact' || 'removeFact' || 'moveFact' => 'fact:$itemId',
    'setFactColor' => 'fact:$itemId:color',
    'addPhoto' || 'removePhoto' || 'movePhoto' => 'photo:$itemId',
    'bindActor' || 'unbindActor' => 'binding:${_json['actorId']}',
    _ => throw StateError('Unknown tree operation'),
  };

  String get description => switch (type) {
    'createPerson' => 'Добавлен человек',
    'createSibling' => 'Добавлен брат или сестра',
    'unlinkSibling' => 'Удалена прямая связь братьев или сестёр',
    'deletePerson' => 'Удалён человек',
    'setPatronymicOverride' =>
      _json['male'] == null
          ? 'Сброшены отчества для имени «${_json['name']}»'
          : 'Изменены отчества для имени «${_json['name']}»',
    'setValue' => switch (_json['field']) {
      'sex' => 'Изменён пол',
      'birthDate' => 'Изменена дата рождения',
      'deathDate' => 'Изменена дата смерти',
      'alive' => switch (_json['value']) {
        true => 'Отмечен как живой',
        false => 'Дата смерти неизвестна',
        _ => 'Сброшена отметка о жизни',
      },
      'fatherId' => 'Изменён отец',
      'motherId' => 'Изменена мать',
      'avatarPhotoId' => 'Изменена главная фотография',
      _ => 'Изменены данные',
    },
    'setSurname' => switch (_json['scope']) {
      'family' => 'Изменена семейная фамилия',
      'individual' => 'Изменена личная фамилия',
      _ => 'Изменена девичья фамилия',
    },
    'editText' => switch (_json['field']) {
      'name' => 'Изменено имя',
      'biography' => 'Изменена биография',
      'photoCaption' => 'Изменена подпись фотографии',
      _ => 'Изменён факт',
    },
    'addFact' => 'Добавлен факт',
    'setFactColor' => 'Изменён цвет факта',
    'removeFact' => 'Удалён факт',
    'moveFact' => 'Изменён порядок фактов',
    'addPhoto' => 'Добавлена фотография',
    'removePhoto' => 'Удалена фотография',
    'movePhoto' => 'Изменён порядок фотографий',
    'bindActor' => 'Участник выбрал себя в дереве',
    'unbindActor' => 'Участник отменил выбор себя в дереве',
    _ => throw StateError('Unknown tree operation'),
  };

  Map<String, Object?> toJson() => _json;

  static bool isValid(Object? value) {
    try {
      fromJson(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  static TreeOperation fromJson(Object? value) {
    final json = _object(value);
    final type = json['type'];
    if (type != 'setPatronymicOverride') _id(json['personId']);
    switch (type) {
      case 'setPatronymicOverride':
        _keys(json, const ['type', 'name', 'male', 'female']);
        _patronymicText(json['name']);
        final name = json['name']! as String;
        if (name.isEmpty || name != normalizePatronymicName(name)) {
          throw const FormatException('Expected a normalized father name');
        }
        final male = json['male'];
        final female = json['female'];
        if (male != null || female != null) {
          _patronymicText(male);
          _patronymicText(female);
        }
      case 'createPerson':
        _keys(json, const ['type', 'personId', 'name', 'sex']);
        _text(json['name']);
        _sex(json['sex']);
      case 'createSibling':
        _keys(json, const [
          'type',
          'personId',
          'siblingId',
          'name',
          'sex',
          'birthDate',
        ]);
        _id(json['siblingId']);
        if (json['personId'] == json['siblingId']) {
          throw const FormatException('A person cannot be their own sibling');
        }
        _text(json['name']);
        _sex(json['sex']);
        _validateValue('birthDate', json['birthDate']);
      case 'unlinkSibling':
        _keys(json, const ['type', 'personId', 'siblingId', 'linkId']);
        _id(json['siblingId']);
        _id(json['linkId'], maxLength: 128);
        if (json['personId'] == json['siblingId']) {
          throw const FormatException('A person cannot be their own sibling');
        }
      case 'deletePerson':
        _keys(json, const ['type', 'personId']);
      case 'setValue':
        _keys(json, const ['type', 'personId', 'field', 'value']);
        _validateValue(json['field'], json['value']);
      case 'setSurname':
        _keys(json, const [
          'type',
          'personId',
          'scope',
          'familyKey',
          'text',
          'decline',
        ]);
        if (!const ['family', 'individual', 'maiden'].contains(json['scope'])) {
          throw const FormatException('Unknown surname scope');
        }
        if (json['scope'] == 'family') {
          _validateSurnameFamilyKey(
            json['familyKey'],
            json['personId']! as String,
          );
        } else if (json['familyKey'] != null) {
          throw const FormatException('Only family surnames have a family key');
        }
        _surnameText(json['text']);
        if (json['decline'] is! bool ||
            (json['text'] == null && json['decline'] != false)) {
          throw const FormatException('Invalid surname declension');
        }
      case 'editText':
        _keys(json, const [
          'type',
          'personId',
          'field',
          'itemId',
          'inserts',
          'deletes',
        ]);
        if (!TreeTextField.values.any((field) => field.name == json['field'])) {
          throw const FormatException('Unknown text field');
        }
        if (json['field'] == 'fact' || json['field'] == 'photoCaption') {
          _id(json['itemId']);
        } else if (json['itemId'] != null) {
          throw const FormatException('Only item text has an itemId');
        }
        final inserts = json['inserts'];
        final deletes = json['deletes'];
        if (inserts is! List ||
            deletes is! List ||
            inserts.length > maxTreeTextLength ||
            deletes.length > maxTreeTextLength) {
          throw const FormatException('Invalid text edits');
        }
        final inserted = <String>{};
        var insertedLength = 0;
        for (final value in inserts) {
          final atom = _object(value);
          _keys(atom, const ['id', 'text', 'left', 'right']);
          final id = _id(atom['id']);
          final text = _text(atom['text']);
          if (text.runes.length != 1 || !inserted.add(id)) {
            throw const FormatException(
              'Expected distinct single Unicode atoms',
            );
          }
          insertedLength += text.length;
          _nullableId(atom['left']);
          _nullableId(atom['right']);
          if (atom['left'] == id ||
              atom['right'] == id ||
              (atom['left'] != null && atom['left'] == atom['right'])) {
            throw const FormatException('Invalid text anchors');
          }
        }
        final deleted = <String>{};
        for (final value in deletes) {
          final id = _id(value);
          if (!deleted.add(id) || inserted.contains(id)) {
            throw const FormatException('Invalid deleted atom IDs');
          }
        }
        if (insertedLength > maxTreeTextLength ||
            (inserts.isEmpty && deletes.isEmpty)) {
          throw const FormatException('Empty or oversized text edit');
        }
      case 'addFact':
        _keys(json, const [
          'type',
          'personId',
          'itemId',
          'text',
          'color',
          'afterId',
          'beforeId',
        ]);
        _id(json['itemId']);
        _text(json['text']);
        _color(json['color']);
        _validatePosition(json);
      case 'setFactColor':
        _keys(json, const ['type', 'personId', 'itemId', 'color']);
        _id(json['itemId']);
        _color(json['color']);
      case 'removeFact' || 'removePhoto':
        _keys(json, const ['type', 'personId', 'itemId']);
        _id(json['itemId']);
      case 'moveFact' || 'movePhoto':
        _keys(json, const [
          'type',
          'personId',
          'itemId',
          'afterId',
          'beforeId',
        ]);
        _id(json['itemId']);
        _validatePosition(json);
      case 'addPhoto':
        _keys(json, const [
          'type',
          'personId',
          'itemId',
          'dataUrl',
          'caption',
          'afterId',
          'beforeId',
        ]);
        _id(json['itemId']);
        _text(json['caption']);
        _validatePhoto(json['dataUrl']);
        _validatePosition(json);
      case 'bindActor':
        _keys(json, const ['type', 'personId', 'actorId']);
        if (!isValidRoomActor(json['actorId'])) {
          throw const FormatException('Invalid actor ID');
        }
      case 'unbindActor':
        _keys(json, const ['type', 'personId', 'actorId', 'bindingId']);
        if (!isValidRoomActor(json['actorId'])) {
          throw const FormatException('Invalid actor ID');
        }
        _id(json['bindingId'], maxLength: 128);
      default:
        throw const FormatException('Unknown tree operation');
    }
    return TreeOperation._(Map<String, Object?>.from(json));
  }
}

/// Total order is (clock, author, id). Wall time is for display only.
class StampedTreeOperation {
  StampedTreeOperation({
    required this.id,
    required this.author,
    required this.clock,
    required this.createdAt,
    required this.operation,
  }) {
    _id(id, maxLength: 128);
    if (!isValidRoomActor(author) || clock < 0 || clock > 9007199254740991) {
      throw const FormatException('Invalid tree operation stamp');
    }
  }

  final String id;
  final String author;
  final int clock;
  final DateTime createdAt;
  final TreeOperation operation;

  Map<String, Object?> toJson() => Map.unmodifiable({
    'id': id,
    'author': author,
    'clock': clock,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'operation': operation.toJson(),
  });

  static StampedTreeOperation fromJson(Object? value) {
    final json = _object(value);
    _keys(json, const ['id', 'author', 'clock', 'createdAt', 'operation']);
    final id = _id(json['id'], maxLength: 128);
    final author = json['author'];
    final clock = json['clock'];
    final createdAt = json['createdAt'];
    if (!isValidRoomActor(author) || clock is! int || createdAt is! String) {
      throw const FormatException('Invalid tree operation stamp');
    }
    final date = DateTime.tryParse(createdAt);
    if (date == null || !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(createdAt)) {
      throw const FormatException('Expected an absolute timestamp');
    }
    return StampedTreeOperation(
      id: id,
      author: author as String,
      clock: clock,
      createdAt: date.toUtc(),
      operation: TreeOperation.fromJson(json['operation']),
    );
  }
}

/// Visible rune IDs and their UTF-16 boundaries (including 0 and text.length).
/// Snapshots remain valid after subsequent merges, including deleted anchors.
class TreeTextSnapshot {
  TreeTextSnapshot._(
    this.personId,
    this.field,
    this.itemId,
    this.text,
    List<String> atomIds,
    List<int> boundaries,
  ) : atomIds = List.unmodifiable(atomIds),
      boundaries = List.unmodifiable(boundaries),
      _indices = {for (var i = 0; i < atomIds.length; i++) atomIds[i]: i};

  final String personId;
  final TreeTextField field;
  final String? itemId;
  final String text;
  final List<String> atomIds;
  final List<int> boundaries;
  final Map<String, int> _indices;

  List<String> get visibleAtomIds => atomIds;
  List<int> get utf16Boundaries => boundaries;

  /// Right affinity: stay before the next surviving original rune; an end
  /// cursor stays at the end. An offset inside a surrogate pair rounds down.
  int mapOffsetTo(TreeTextSnapshot other, int utf16Offset) {
    if (personId != other.personId ||
        field != other.field ||
        itemId != other.itemId) {
      throw ArgumentError('Cannot map cursors between different text fields');
    }
    final index = _boundaryAt(boundaries, utf16Offset.clamp(0, text.length));
    if (index == atomIds.length) return other.text.length;
    for (var i = index; i < atomIds.length; i++) {
      final mapped = other._indices[atomIds[i]];
      if (mapped != null) return other.boundaries[mapped];
    }
    for (var i = index - 1; i >= 0; i--) {
      final mapped = other._indices[atomIds[i]];
      if (mapped != null) return other.boundaries[mapped + 1];
    }
    return 0;
  }
}

/// An event-set CRDT projection with a virtual root: constructing a document
/// requires no writes. Commands only create operations; callers stamp and merge
/// them optimistically before creating the next local command.
class TreeDocument {
  TreeDocument() {
    _rebuild();
  }

  final Map<String, StampedTreeOperation> _events = {};
  Map<String, _PersonState> _states = {};
  Set<String> _deletedPersonIds = const {};
  Map<String, TreePerson> _people = const {};
  Map<String, TreePatronymicForms> _patronymicOverrides = const {};
  Map<String, String> _bindings = const {};
  Map<String, StampedTreeOperation> _bindingEvents = const {};
  Map<String, String> _siblingGroupIds = const {};
  List<TreeSiblingLink> _directSiblingLinks = const [];

  Map<String, String> get siblingGroupIds => _siblingGroupIds;
  List<TreeSiblingLink> get directSiblingLinks => _directSiblingLinks;
  Map<String, TreePerson> get people => _people;
  Map<String, TreePatronymicForms> get patronymicOverrides =>
      _patronymicOverrides;
  Map<String, String> get bindings => _bindings;
  TreePerson? person(String id) => _people[id];

  /// Returns whether the event set changed. Duplicate delivery is a no-op.
  /// Conflicting immutable IDs throw without partially applying the batch.
  bool merge(Iterable<StampedTreeOperation> operations) {
    final additions = <String, StampedTreeOperation>{};
    for (final event in operations) {
      final previous = additions[event.id] ?? _events[event.id];
      if (identical(previous, event)) continue;
      if (previous != null) {
        final same =
            previous.author == event.author &&
            previous.clock == event.clock &&
            previous.createdAt.isAtSameMomentAs(event.createdAt) &&
            (identical(previous.operation, event.operation) ||
                previous.operation._encoded == event.operation._encoded);
        if (!same) {
          throw StateError(
            'Conflicting immutable tree operation ID: ${event.id}',
          );
        }
        continue;
      }
      additions[event.id] = event;
    }
    if (additions.isEmpty) return false;
    _events.addAll(additions);
    _rebuild();
    return true;
  }

  TreeOperation createPerson(
    String id, {
    String name = '',
    TreeSex sex = TreeSex.unknown,
  }) {
    if (_states.containsKey(id) || _deletedPersonIds.contains(id)) {
      throw ArgumentError.value(id, 'id', 'Person IDs cannot be reused');
    }
    return TreeOperation.fromJson({
      'type': 'createPerson',
      'personId': id,
      'name': name,
      'sex': sex.name,
    });
  }

  /// Creates the person and sibling relationship as one immutable command.
  TreeOperation createSibling(
    String sourceId,
    String newId, {
    String name = '',
    TreeSex sex = TreeSex.unknown,
    DateTime? birthDate,
  }) {
    _requirePerson(sourceId);
    createPerson(newId, name: name, sex: sex);
    return TreeOperation.fromJson({
      'type': 'createSibling',
      'personId': newId,
      'siblingId': sourceId,
      'name': name,
      'sex': sex.name,
      'birthDate': birthDate == null ? null : _dateText(birthDate),
    });
  }

  /// Removes only the observed direct edge, never shared parent assignments.
  TreeOperation unlinkSibling(String personId, String siblingId) {
    _requirePerson(personId);
    _requirePerson(siblingId);
    final link = _directSiblingLinks
        .where(
          (link) =>
              (link.personId == personId && link.siblingId == siblingId) ||
              (link.personId == siblingId && link.siblingId == personId),
        )
        .firstOrNull;
    if (link == null) throw ArgumentError('No direct sibling link');
    return TreeOperation.fromJson({
      'type': 'unlinkSibling',
      'personId': personId,
      'siblingId': siblingId,
      'linkId': link.id,
    });
  }

  /// Permanently hides this identity, without removing any journal history.
  TreeOperation deletePerson(String personId) {
    _requirePerson(personId);
    return TreeOperation.fromJson({
      'type': 'deletePerson',
      'personId': personId,
    });
  }

  TreeOperation setValue(String personId, String field, Object? value) {
    _requirePerson(personId);
    if (value is TreeSex) value = value.name;
    if (value is DateTime && (field == 'birthDate' || field == 'deathDate')) {
      value = _dateText(value);
    }
    final operation = TreeOperation.fromJson({
      'type': 'setValue',
      'personId': personId,
      'field': field,
      'value': value,
    });
    if ((field == 'fatherId' || field == 'motherId') && value != null) {
      _requirePerson(value as String);
      final members = _directComponentOf(personId);
      if (members.any((id) => wouldCreateCycle(id, value as String))) {
        throw ArgumentError('A sibling group cannot contain its own ancestor');
      }
    }
    if (field == 'avatarPhotoId' &&
        value != null &&
        !person(personId)!.photos.any((photo) => photo.id == value)) {
      throw ArgumentError.value(value, 'value', 'Unknown visible photo');
    }
    return operation;
  }

  /// Atomic room-scoped forms; both null resets to built-in/algorithmic forms.
  /// This command is valid even when every person, including root, is deleted.
  TreeOperation setPatronymicOverride(
    String name, {
    required String? male,
    required String? female,
  }) => TreeOperation.fromJson({
    'type': 'setPatronymicOverride',
    'name': normalizePatronymicName(name),
    'male': male?.trim(),
    'female': female?.trim(),
  });

  String surnameFamilyKey(String personId) {
    _requirePerson(personId);
    return treeSurnameFamilyKey(_people[personId]!);
  }

  /// Compatibility alias. New commands never write a shared family register.
  @Deprecated('Use setIndividualSurname; surnames are edited per person.')
  TreeOperation setFamilySurname(
    String personId, {
    required String? text,
    bool decline = false,
  }) => setIndividualSurname(personId, text: text, decline: decline);

  TreeOperation setIndividualSurname(
    String personId, {
    required String? text,
    bool decline = false,
  }) => _setSurname(personId, 'individual', text, decline);

  TreeOperation setMaidenSurname(
    String personId, {
    required String? text,
    bool decline = false,
  }) => _setSurname(personId, 'maiden', text, decline);

  TreeOperation _setSurname(
    String personId,
    String scope,
    String? text,
    bool decline,
  ) {
    _requirePerson(personId);
    final trimmed = text?.trim();
    final normalized = trimmed == null || trimmed.isEmpty ? null : trimmed;
    return TreeOperation.fromJson({
      'type': 'setSurname',
      'personId': personId,
      'scope': scope,
      'familyKey': null,
      'text': normalized,
      'decline': normalized != null && decline,
    });
  }

  TreeTextSnapshot textSnapshot(
    String personId,
    TreeTextField field, {
    String? itemId,
  }) {
    final state = _requirePerson(personId);
    return _textState(state, field, itemId).snapshot(personId, field, itemId);
  }

  /// Bounded Myers diff on Unicode runes. A large wholesale replacement falls
  /// back to its changed span; unchanged prefix/suffix IDs are always retained.
  /// A supplied base may be stale, so remote insertions are never deleted merely
  /// because they were absent from the editing widget's old value.
  TreeOperation? editText(
    String personId,
    TreeTextField field,
    String newValue, {
    String? itemId,
    TreeTextSnapshot? base,
  }) {
    _text(newValue);
    final current = textSnapshot(personId, field, itemId: itemId);
    base ??= current;
    if (base.personId != personId ||
        base.field != field ||
        base.itemId != itemId) {
      throw ArgumentError('The base snapshot belongs to another text field');
    }
    if (base.text == newValue) return null;
    final edits = _diff(base.text.runes.toList(), newValue.runes.toList());
    final nonce = createRoomId();
    final inserts = <Map<String, Object?>>[];
    final deletes = <String>[];
    var oldIndex = 0;
    String? left;
    for (final edit in edits) {
      switch (edit.kind) {
        case _EditKind.keep:
          left = base.atomIds[oldIndex++];
        case _EditKind.delete:
          deletes.add(base.atomIds[oldIndex++]);
        case _EditKind.insert:
          final id =
              '$nonce:${inserts.length.toRadixString(16).padLeft(6, '0')}';
          inserts.add({
            'id': id,
            'text': String.fromCharCode(edit.rune),
            'left': left,
            'right': oldIndex < base.atomIds.length
                ? base.atomIds[oldIndex]
                : null,
          });
          left = id;
      }
    }
    return TreeOperation.fromJson({
      'type': 'editText',
      'personId': personId,
      'field': field.name,
      'itemId': itemId,
      'inserts': inserts,
      'deletes': deletes,
    });
  }

  TreeOperation addFact(
    String personId,
    String id, {
    String text = '',
    String color = defaultTreeFactColor,
  }) {
    final state = _requirePerson(personId);
    if (state.facts.containsKey(id)) {
      throw ArgumentError('Fact IDs cannot be reused');
    }
    final facts = person(personId)!.facts;
    return TreeOperation.fromJson({
      'type': 'addFact',
      'personId': personId,
      'itemId': id,
      'text': text,
      'color': color,
      'afterId': facts.isEmpty ? null : facts.last.id,
      'beforeId': null,
    });
  }

  TreeOperation setFactColor(String personId, String itemId, String color) {
    _requireFact(personId, itemId);
    return TreeOperation.fromJson({
      'type': 'setFactColor',
      'personId': personId,
      'itemId': itemId,
      'color': color,
    });
  }

  TreeOperation removeFact(String personId, String itemId) {
    _requireFact(personId, itemId, includeRemoved: true);
    return TreeOperation.fromJson({
      'type': 'removeFact',
      'personId': personId,
      'itemId': itemId,
    });
  }

  /// A single anchor means immediately after/before it in the current list.
  /// With neither anchor the item moves to the front. Both anchors are encoded.
  TreeOperation moveFact(
    String personId,
    String itemId, {
    String? afterId,
    String? beforeId,
  }) {
    _requireFact(personId, itemId);
    final anchors = _moveAnchors(
      person(personId)!.facts.map((item) => item.id).toList(),
      itemId,
      afterId,
      beforeId,
    );
    return TreeOperation.fromJson({
      'type': 'moveFact',
      'personId': personId,
      'itemId': itemId,
      ...anchors,
    });
  }

  TreeOperation addPhoto(
    String personId,
    String id, {
    required String dataUrl,
    String caption = '',
  }) {
    final state = _requirePerson(personId);
    if (state.photos.containsKey(id)) {
      throw ArgumentError('Photo IDs cannot be reused');
    }
    final photos = person(personId)!.photos;
    return TreeOperation.fromJson({
      'type': 'addPhoto',
      'personId': personId,
      'itemId': id,
      'dataUrl': dataUrl,
      'caption': caption,
      'afterId': photos.isEmpty ? null : photos.last.id,
      'beforeId': null,
    });
  }

  TreeOperation removePhoto(String personId, String itemId) {
    _requirePhoto(personId, itemId, includeRemoved: true);
    return TreeOperation.fromJson({
      'type': 'removePhoto',
      'personId': personId,
      'itemId': itemId,
    });
  }

  TreeOperation movePhoto(
    String personId,
    String itemId, {
    String? afterId,
    String? beforeId,
  }) {
    _requirePhoto(personId, itemId);
    final anchors = _moveAnchors(
      person(personId)!.photos.map((item) => item.id).toList(),
      itemId,
      afterId,
      beforeId,
    );
    return TreeOperation.fromJson({
      'type': 'movePhoto',
      'personId': personId,
      'itemId': itemId,
      ...anchors,
    });
  }

  TreeOperation bindActor(String actorId, String personId) {
    _requirePerson(personId);
    return TreeOperation.fromJson({
      'type': 'bindActor',
      'personId': personId,
      'actorId': actorId,
    });
  }

  /// Releases exactly the active immutable claim, even if its person is deleted.
  /// Releasing an older claim cannot clear a subsequent rebind to the same person.
  TreeOperation unbindActor(String actorId) {
    final binding = _bindingEvents[actorId];
    if (binding == null) {
      throw ArgumentError.value(actorId, 'actorId', 'Actor is not bound');
    }
    return TreeOperation.fromJson({
      'type': 'unbindActor',
      'personId': binding.operation.personId,
      'actorId': actorId,
      'bindingId': binding.id,
    });
  }

  bool wouldCreateCycle(String childId, String parentId) => _reaches(
    parentId,
    childId,
    (id) => [
      if (_people[id]?.fatherId case final String father) father,
      if (_people[id]?.motherId case final String mother) mother,
    ],
  );

  Set<String> _directComponentOf(String personId) {
    final group = _siblingGroupIds[personId];
    if (group == null || !group.startsWith('siblings:')) return {personId};
    return {
      for (final entry in _siblingGroupIds.entries)
        if (entry.value == group) entry.key,
    };
  }

  List<TreePerson> childrenOf(String id) => List.unmodifiable(
    _sortedPeople().where(
      (person) => person.fatherId == id || person.motherId == id,
    ),
  );

  List<TreePerson> siblingsOf(String id, {bool includeHalf = true}) {
    final target = person(id);
    if (target == null) return const [];
    final parents = {
      if (target.fatherId != null) target.fatherId,
      if (target.motherId != null) target.motherId,
    };
    return List.unmodifiable(
      _sortedPeople().where((candidate) {
        if (candidate.id == id) return false;
        if (_siblingGroupIds[id] == _siblingGroupIds[candidate.id]) return true;
        if (!includeHalf) {
          return target.fatherId != null &&
              target.motherId != null &&
              target.fatherId == candidate.fatherId &&
              target.motherId == candidate.motherId;
        }
        return (candidate.fatherId != null &&
                parents.contains(candidate.fatherId)) ||
            (candidate.motherId != null &&
                parents.contains(candidate.motherId));
      }),
    );
  }

  List<TreePerson> _sortedPeople() =>
      _people.values.toList()..sort(compareTreePeopleByBirth);

  _PersonState _requirePerson(String id) {
    if (!_people.containsKey(id)) {
      throw ArgumentError.value(id, 'personId', 'Unknown visible person');
    }
    return _states[id]!;
  }

  _FactState _requireFact(
    String personId,
    String itemId, {
    bool includeRemoved = false,
  }) {
    final fact = _requirePerson(personId).facts[itemId];
    if (fact == null || (!includeRemoved && fact.removed)) {
      throw ArgumentError('Unknown visible fact');
    }
    return fact;
  }

  _PhotoState _requirePhoto(
    String personId,
    String itemId, {
    bool includeRemoved = false,
  }) {
    final photo = _requirePerson(personId).photos[itemId];
    if (photo == null || (!includeRemoved && photo.removed)) {
      throw ArgumentError('Unknown visible photo');
    }
    return photo;
  }

  _TextState _textState(
    _PersonState state,
    TreeTextField field,
    String? itemId,
  ) {
    if (field == TreeTextField.fact || field == TreeTextField.photoCaption) {
      if (itemId == null) throw ArgumentError('Item text requires itemId');
      return field == TreeTextField.fact
          ? _requireFact(state.id, itemId).text
          : _requirePhoto(state.id, itemId).caption;
    }
    if (itemId != null) throw ArgumentError('Only item text has itemId');
    return field == TreeTextField.name ? state.name : state.biography;
  }

  void _rebuild() {
    final events = _events.values.toList()..sort(_compareStamp);
    // Remove-wins identities: deletion can arrive before creation and cannot be
    // undone by any later edit/create. Keep all events and actor claims intact.
    final deletedPersonIds = {
      for (final event in events)
        if (event.operation.type == 'deletePerson') event.operation.personId,
    };
    final states = <String, _PersonState>{
      rootTreePersonId: _PersonState(rootTreePersonId),
    };
    // Gather identities first: edits and removals may arrive before their adds.
    final creations = <String, StampedTreeOperation>{};
    for (final event in events) {
      final op = event.operation;
      if ((op.type != 'createPerson' && op.type != 'createSibling') ||
          states.containsKey(op.personId)) {
        continue;
      }
      final state = _PersonState(op.personId);
      state.name.seed(op._json['name']! as String, event, 'name');
      state.values['sex'] = _Register(op._json['sex'], event);
      if (op.type == 'createSibling') {
        state.values['birthDate'] = _Register(op._json['birthDate'], event);
      }
      states[op.personId] = state;
      creations[op.personId] = event;
    }
    for (final event in events) {
      final op = event.operation;
      final state = states[op.personId];
      if (state == null) continue;
      if (op.type == 'addFact') {
        state.facts.putIfAbsent(op.itemId!, () => _FactState(op, event));
      } else if (op.type == 'addPhoto') {
        state.photos.putIfAbsent(op.itemId!, () => _PhotoState(op, event));
      }
    }
    final bindingEvents = <String, StampedTreeOperation>{};
    final familySurnames = <String, _Register>{};
    final patronymicOverrides = <String, TreePatronymicForms>{};
    for (final event in events) {
      final op = event.operation;
      final json = op._json;
      if (op.type == 'setPatronymicOverride') {
        // Sorted replay is LWW for the whole pair, including resets. Keep the
        // reset event in history so delayed older overrides cannot reappear.
        // This room register must be processed before looking up any person.
        final name = json['name']! as String;
        if (json['male'] == null) {
          patronymicOverrides.remove(name);
        } else {
          patronymicOverrides[name] = TreePatronymicForms(
            male: json['male']! as String,
            female: json['female']! as String,
          );
        }
        continue;
      }
      if (op.type == 'bindActor') {
        // Preserve legacy earliest-claim replay until that exact claim is
        // explicitly released. A later bind alone never changes an active one.
        bindingEvents.putIfAbsent(json['actorId']! as String, () => event);
        continue;
      }
      if (op.type == 'unbindActor') {
        final actor = json['actorId']! as String;
        final binding = bindingEvents[actor];
        if (event.author == actor &&
            binding?.id == json['bindingId'] &&
            binding?.operation.personId == op.personId) {
          bindingEvents.remove(actor);
        }
        continue;
      }
      if (op.type == 'setSurname' && json['scope'] == 'family') {
        // Preserve historical shared registers at their frozen targets, even
        // when their editing representative is missing or deleted. They are
        // read-only fallback for people without a personal surname register.
        familySurnames[json['familyKey']! as String] = _Register(
          _surnameValue(json),
          event,
        );
        continue;
      }
      final state = states[op.personId];
      if (state == null) continue;
      switch (op.type) {
        case 'setValue':
          final field = json['field']! as String;
          final previous = state.values[field];
          if (previous == null || _compareStamp(previous.stamp, event) < 0) {
            state.values[field] = _Register(json['value'], event);
          }
        case 'setSurname':
          state.values['${json['scope']}Surname'] = _Register(
            _surnameValue(json),
            event,
          );
        case 'editText':
          final text = switch (json['field']) {
            'name' => state.name,
            'biography' => state.biography,
            'fact' => state.facts[op.itemId]?.text,
            'photoCaption' => state.photos[op.itemId]?.caption,
            _ => null,
          };
          text?.apply(op, event);
        case 'setFactColor':
          final fact = state.facts[op.itemId];
          if (fact != null && _compareStamp(fact.color.stamp, event) < 0) {
            fact.color = _Register(json['color'], event);
          }
        case 'removeFact':
          state.facts[op.itemId]?.removed = true;
        case 'removePhoto':
          state.photos[op.itemId]?.removed = true;
        case 'moveFact':
          state.facts[op.itemId]?.positions.add(_Position(op, event));
        case 'movePhoto':
          state.photos[op.itemId]?.positions.add(_Position(op, event));
      }
    }
    // Histories without the new operations keep the original register replay.
    final hasExplicitSiblings = events.any(
      (event) =>
          event.operation.type == 'createSibling' ||
          event.operation.type == 'unlinkSibling',
    );
    final relations = hasExplicitSiblings
        ? _SiblingRelations(states, events, creations)
        : null;
    final accepted =
        relations?.accepted ?? _projectParents(states, deletedPersonIds);
    final directComponents = relations?.components ?? const <String, String>{};
    final people = <String, TreePerson>{};
    final ids =
        states.keys.where((id) => !deletedPersonIds.contains(id)).toList()
          ..sort();
    final explicitFamilies = <String, TreeSurname?>{
      for (final id in ids)
        id: states[id]!.values.containsKey('individualSurname')
            ? null
            : familySurnames[_surnameFamilyKey(
                        id,
                        accepted[id]?['fatherId'],
                        accepted[id]?['motherId'],
                      )]
                      ?.value
                  as TreeSurname?,
    };
    final effectiveSurnames = <String, TreeSurname?>{};
    final inheritedFrom = <String, String>{};
    // Resolve the accepted acyclic father graph parent-first with memoization.
    // Long ancestry and pedigree collapse never recurse or expand into paths.
    for (final id in ids) {
      var current = id;
      final lineage = <String>[];
      while (!effectiveSurnames.containsKey(current)) {
        lineage.add(current);
        final own =
            states[current]!.values['individualSurname']?.value
                as TreeSurname? ??
            explicitFamilies[current];
        if (own != null) {
          effectiveSurnames[current] = own;
          break;
        }
        final father = accepted[current]?['fatherId'];
        if (father == null) {
          effectiveSurnames[current] = null;
          break;
        }
        current = father;
      }
      for (final child in lineage.reversed) {
        if (effectiveSurnames.containsKey(child)) continue;
        final father = accepted[child]!['fatherId']!;
        final surname = effectiveSurnames[father];
        effectiveSurnames[child] = surname;
        if (surname != null) inheritedFrom[child] = father;
      }
    }
    // Names are independent of person iteration order: a father can sort after
    // his child. Derive forms only after deletion and accepted-edge projection.
    final names = {
      for (final id in ids)
        id: states[id]!.name.snapshot(id, TreeTextField.name, null).text,
    };
    for (final id in ids) {
      if (deletedPersonIds.contains(id)) continue;
      final state = states[id]!;
      final father = accepted[id]?['fatherId'];
      final fatherPatronymicForms = father == null
          ? null
          : generatePatronymicForms(
              names[father]!,
              overrides: patronymicOverrides,
            );
      final facts = _orderItems(state.facts.values)
          .where((fact) => !fact.removed)
          .map(
            (fact) => TreeFact(
              id: fact.id,
              text: fact.text.snapshot(id, TreeTextField.fact, fact.id).text,
              color: fact.color.value! as String,
            ),
          );
      final photos = _orderItems(state.photos.values)
          .where((photo) => !photo.removed)
          .map(
            (photo) => TreePhoto(
              id: photo.id,
              dataUrl: photo.dataUrl,
              caption: photo.caption
                  .snapshot(id, TreeTextField.photoCaption, photo.id)
                  .text,
            ),
          )
          .toList();
      final avatar = state.values['avatarPhotoId']?.value as String?;
      people[id] = TreePerson(
        id: id,
        name: names[id]!,
        biography: state.biography
            .snapshot(id, TreeTextField.biography, null)
            .text,
        sex: TreeSex.values.byName(
          state.values['sex']?.value as String? ?? 'unknown',
        ),
        birthDate: _dateValue(state.values['birthDate']?.value),
        deathDate: _dateValue(state.values['deathDate']?.value),
        alive: state.values['alive']?.value as bool?,
        fatherId: father,
        fatherPatronymicForms: fatherPatronymicForms,
        motherId: accepted[id]?['motherId'],
        familySurname: explicitFamilies[id],
        individualSurname:
            state.values['individualSurname']?.value as TreeSurname?,
        maidenSurname: state.values['maidenSurname']?.value as TreeSurname?,
        effectiveSurname: effectiveSurnames[id],
        surnameInheritedFrom: inheritedFrom[id],
        facts: facts,
        photos: photos,
        avatarPhotoId: photos.any((photo) => photo.id == avatar)
            ? avatar
            : null,
      );
    }
    _states = states;
    _deletedPersonIds = deletedPersonIds;
    _people = Map.unmodifiable(people);
    _patronymicOverrides = Map.unmodifiable(patronymicOverrides);
    _directSiblingLinks = List.unmodifiable(
      relations?.links.values ?? const <TreeSiblingLink>[],
    );
    _siblingGroupIds = Map.unmodifiable({
      for (final person in people.values)
        person.id: directComponents.containsKey(person.id)
            ? 'siblings:${directComponents[person.id]!.length}:${directComponents[person.id]}'
            : treeSurnameFamilyKey(person),
    });
    _bindingEvents = Map.unmodifiable(bindingEvents);
    _bindings = Map.unmodifiable({
      for (final entry in bindingEvents.entries)
        entry.key: entry.value.operation.personId,
    });
  }
}

class _PersonState {
  _PersonState(this.id);
  final String id;
  final name = _TextState();
  final biography = _TextState();
  final Map<String, _Register> values = {};
  final Map<String, _FactState> facts = {};
  final Map<String, _PhotoState> photos = {};
}

class _Register {
  _Register(this.value, this.stamp);
  final Object? value;
  final StampedTreeOperation stamp;
}

/// Replays only relationship transitions. Propagated registers are materialized
/// per person so splitting an explicit component never discards assigned parents.
class _SiblingRelations {
  _SiblingRelations(
    this.states,
    List<StampedTreeOperation> events,
    Map<String, StampedTreeOperation> creations,
  ) {
    for (final state in states.values) {
      state.values.remove('fatherId');
      state.values.remove('motherId');
    }
    for (final event in events) {
      final op = event.operation;
      final json = op._json;
      if (op.type == 'deletePerson') {
        deleted.add(op.personId);
        links.removeWhere(
          (_, link) =>
              link.personId == op.personId || link.siblingId == op.personId,
        );
      } else if (op.type == 'createSibling' &&
          creations[op.personId] == event) {
        final source = json['siblingId']! as String;
        if (!states.containsKey(source) ||
            deleted.contains(source) ||
            deleted.contains(op.personId)) {
          continue;
        }
        // Copy the accepted canonical pair, not a cycle-rejected raw reference.
        _resolve();
        for (final field in const ['fatherId', 'motherId']) {
          states[op.personId]!.values[field] = _Register(
            accepted[source]?[field],
            event,
          );
        }
        if (accepted[source]?['fatherId'] == null ||
            accepted[source]?['motherId'] == null) {
          final link = TreeSiblingLink(
            id: event.id,
            personId: op.personId,
            siblingId: source,
          );
          if (!(removed[event.id] ?? const []).any(
            (pair) => _samePair(link, pair.$1, pair.$2),
          )) {
            links[event.id] = link;
            _unify(_members(op.personId));
          }
        }
      } else if (op.type == 'unlinkSibling') {
        final sibling = json['siblingId']! as String;
        final id = json['linkId']! as String;
        (removed[id] ??= []).add((op.personId, sibling));
        final link = links[id];
        if (link != null && _samePair(link, op.personId, sibling)) {
          links.remove(id);
        }
      } else if (op.type == 'setValue' &&
          (json['field'] == 'fatherId' || json['field'] == 'motherId')) {
        if (!states.containsKey(op.personId) || deleted.contains(op.personId)) {
          continue;
        }
        final register = _Register(json['value'], event);
        for (final id in _members(op.personId)) {
          states[id]!.values[json['field']! as String] = register;
        }
      } else {
        continue;
      }
      if (links.isEmpty) continue;
      _resolve();
      // Retired claims never reactivate on a later clear/deletion. Completion is
      // evaluated at this event, using accepted live parents, not future tombstones.
      final complete = <String>{};
      for (final entry in components.entries) {
        if (accepted[entry.key]?['fatherId'] != null &&
            accepted[entry.key]?['motherId'] != null) {
          complete.add(entry.value);
        }
      }
      if (complete.isNotEmpty) {
        links.removeWhere(
          (_, link) => complete.contains(components[link.personId]),
        );
        _resolve();
      }
    }
    _resolve();
  }

  final Map<String, _PersonState> states;
  final deleted = <String>{};
  final links = <String, TreeSiblingLink>{};
  final removed = <String, List<(String, String)>>{};
  Map<String, String> components = {};
  Map<String, Map<String, String>> accepted = {};

  static bool _samePair(TreeSiblingLink link, String a, String b) =>
      (link.personId == a && link.siblingId == b) ||
      (link.personId == b && link.siblingId == a);

  Set<String> _members(String id) {
    final adjacency = <String, Set<String>>{};
    for (final link in links.values) {
      (adjacency[link.personId] ??= {}).add(link.siblingId);
      (adjacency[link.siblingId] ??= {}).add(link.personId);
    }
    final members = <String>{id};
    final pending = [id];
    while (pending.isNotEmpty) {
      for (final neighbor
          in adjacency[pending.removeLast()] ?? const <String>{}) {
        if (members.add(neighbor)) pending.add(neighbor);
      }
    }
    return members;
  }

  void _unify(Set<String> members) {
    for (final field in const ['fatherId', 'motherId']) {
      _Register? newest;
      for (final id in members) {
        final register = states[id]!.values[field];
        if (register != null &&
            (newest == null ||
                _compareStamp(newest.stamp, register.stamp) < 0)) {
          newest = register;
        }
      }
      if (newest != null) {
        for (final id in members) {
          states[id]!.values[field] = newest;
        }
      }
    }
  }

  void _resolve() {
    components = {};
    for (final link in links.values) {
      if (components.containsKey(link.personId)) continue;
      final members = _members(link.personId).toList()..sort();
      for (final id in members) {
        components[id] = members.first;
      }
    }
    accepted = _projectParents(states, deleted, components);
  }
}

/// Candidates of an active explicit group are accepted/rejected atomically on
/// its quotient graph. With no direct group this is the historical projection.
Map<String, Map<String, String>> _projectParents(
  Map<String, _PersonState> states,
  Set<String> deleted, [
  Map<String, String> components = const {},
]) {
  final members = <String, List<String>>{};
  for (final id in states.keys) {
    if (!deleted.contains(id)) (members[components[id] ?? id] ??= []).add(id);
  }
  final edges = <_ParentEdge>[];
  for (final entry in members.entries) {
    for (final field in const ['fatherId', 'motherId']) {
      _Register? newest;
      for (final id in entry.value) {
        final register = states[id]!.values[field];
        if (register != null &&
            (newest == null ||
                _compareStamp(newest.stamp, register.stamp) < 0)) {
          newest = register;
        }
      }
      if (newest?.value case final String parent) {
        if (states.containsKey(parent) && !deleted.contains(parent)) {
          edges.add(_ParentEdge(entry.key, parent, field, newest!.stamp));
        }
      }
    }
  }
  edges.sort((a, b) {
    final stamp = _compareStamp(b.stamp, a.stamp);
    if (stamp != 0) return stamp;
    final child = a.child.compareTo(b.child);
    return child != 0 ? child : a.field.compareTo(b.field);
  });
  final parents = <String, List<String>>{};
  final accepted = <String, Map<String, String>>{};
  for (final edge in edges) {
    final parentGroup = components[edge.parent] ?? edge.parent;
    if (_reaches(parentGroup, edge.child, (id) => parents[id] ?? const [])) {
      continue;
    }
    (parents[edge.child] ??= []).add(parentGroup);
    for (final id in members[edge.child]!) {
      (accepted[id] ??= {})[edge.field] = edge.parent;
    }
  }
  return accepted;
}

class _ParentEdge {
  _ParentEdge(this.child, this.parent, this.field, this.stamp);
  final String child;
  final String parent;
  final String field;
  final StampedTreeOperation stamp;
}

class _Position {
  _Position(TreeOperation operation, this.stamp)
    : after = operation._json['afterId'] as String?,
      before = operation._json['beforeId'] as String?,
      isMove = operation.type == 'moveFact' || operation.type == 'movePhoto';
  final String? after;
  final String? before;
  final bool isMove;
  final StampedTreeOperation stamp;
}

abstract class _ListItem {
  _ListItem(TreeOperation operation, this.creation)
    : id = operation.itemId!,
      positions = [_Position(operation, creation)];
  final String id;
  final StampedTreeOperation creation;
  final List<_Position> positions;
  bool removed = false;
}

class _FactState extends _ListItem {
  _FactState(TreeOperation operation, StampedTreeOperation stamp)
    : color = _Register(operation._json['color'], stamp),
      super(operation, stamp) {
    text.seed(operation._json['text']! as String, stamp, 'fact');
  }
  final text = _TextState();
  _Register color;
}

class _PhotoState extends _ListItem {
  _PhotoState(TreeOperation operation, StampedTreeOperation stamp)
    : dataUrl = operation._json['dataUrl']! as String,
      super(operation, stamp) {
    caption.seed(operation._json['caption']! as String, stamp, 'caption');
  }
  final String dataUrl;
  final caption = _TextState();
}

/// Replay item-local placements in total order. A move changes only its item,
/// never a whole-list register; concurrent adds/edits cannot be overwritten.
/// Retaining old placements preserves every other item's relative order on
/// sequential moves, which a graph of only the latest anchors cannot guarantee.
/// Removed items remain as ordering anchors until the final visible projection.
List<T> _orderItems<T extends _ListItem>(Iterable<T> items) {
  final byId = {for (final item in items) item.id: item};
  final placements =
      [
        for (final item in byId.values)
          for (final position in item.positions) (item.id, position),
      ]..sort((a, b) {
        final stamp = _compareStamp(a.$2.stamp, b.$2.stamp);
        return stamp != 0 ? stamp : a.$1.compareTo(b.$1);
      });
  final ordered = <String>[];
  for (final (id, position) in placements) {
    ordered.remove(id);
    final after = position.after == null
        ? -1
        : ordered.indexOf(position.after!);
    final before = position.before == null
        ? -1
        : ordered.indexOf(position.before!);
    final index = after >= 0
        ? after + 1
        : before >= 0
        ? before
        : position.isMove
        ? 0
        : ordered.length;
    ordered.insert(index, id);
  }
  return [for (final id in ordered) byId[id]!];
}

Map<String, Object?> _moveAnchors(
  List<String> ids,
  String itemId,
  String? after,
  String? before,
) {
  ids.remove(itemId);
  if (after == itemId ||
      before == itemId ||
      (after != null && !ids.contains(after)) ||
      (before != null && !ids.contains(before))) {
    throw ArgumentError('Invalid list anchors');
  }
  if (after == null && before == null) {
    before = ids.isEmpty ? null : ids.first;
  } else if (after == null) {
    final index = ids.indexOf(before!);
    after = index == 0 ? null : ids[index - 1];
  } else if (before == null) {
    final index = ids.indexOf(after);
    before = index + 1 == ids.length ? null : ids[index + 1];
  } else if (ids.indexOf(after) >= ids.indexOf(before)) {
    throw ArgumentError('List anchors are reversed');
  }
  return {'afterId': after, 'beforeId': before};
}

class _Atom {
  _Atom(this.id, this.text, this.left, this.right, this.stamp);
  final String id;
  final String text;
  final String? left;
  final String? right;
  final StampedTreeOperation stamp;
}

/// RGA left-anchor forest. Right anchors impose sibling precedence, including
/// when an older visible successor is below a tombstoned ancestor. Concurrent
/// sibling runs use reverse stamp order and are traversed as intact subtrees.
class _TextState {
  final Map<String, _Atom> atoms = {};
  final Set<String> deleted = {};
  TreeTextSnapshot? _snapshot;

  void seed(String text, StampedTreeOperation stamp, String field) {
    String? left;
    var index = 0;
    for (final rune in text.runes) {
      final id = 'seed:${stamp.id}:$field:${index++}';
      atoms[id] = _Atom(id, String.fromCharCode(rune), left, null, stamp);
      left = id;
    }
  }

  void apply(TreeOperation operation, StampedTreeOperation stamp) {
    for (final raw in operation._json['inserts']! as List) {
      final json = raw as Map;
      final id = json['id']! as String;
      final atom = _Atom(
        id,
        json['text']! as String,
        json['left'] as String?,
        json['right'] as String?,
        stamp,
      );
      final previous = atoms[id];
      if (previous == null || _compareStamp(stamp, previous.stamp) < 0) {
        atoms[id] = atom;
      }
    }
    deleted.addAll((operation._json['deletes']! as List).cast<String>());
  }

  TreeTextSnapshot snapshot(
    String personId,
    TreeTextField field,
    String? itemId,
  ) {
    if (_snapshot case final TreeTextSnapshot snapshot) return snapshot;
    final children = <String?, List<_Atom>>{};
    for (final atom in atoms.values) {
      if (atom.right != null && !atoms.containsKey(atom.right)) continue;
      children.putIfAbsent(atom.left, () => []).add(atom);
    }
    // Iterative DFS avoids stack overflows on long names/biographies. Raw
    // subtree intervals let us find the successor's direct sibling in O(log n).
    final starts = <String, int>{};
    final ends = <String, int>{};
    final stack = <(_Atom, bool)>[
      for (final atom in (children[null] ?? const <_Atom>[]).reversed)
        (atom, false),
    ];
    var counter = 0;
    while (stack.isNotEmpty) {
      final (atom, exiting) = stack.removeLast();
      if (exiting) {
        ends[atom.id] = counter;
        continue;
      }
      starts[atom.id] = counter++;
      stack.add((atom, true));
      for (final child in (children[atom.id] ?? const <_Atom>[]).reversed) {
        stack.add((child, false));
      }
    }
    for (final entry in children.entries) {
      final siblings = entry.value;
      if (siblings.length < 2) continue;
      final reachable = siblings
          .where((atom) => starts.containsKey(atom.id))
          .toList();
      if (reachable.length < 2) continue;
      final graph = <String, Set<String>>{};
      for (final atom in reachable) {
        final right = starts[atom.right];
        if (right == null) continue;
        var low = 0;
        var high = reachable.length;
        while (low < high) {
          final middle = (low + high) ~/ 2;
          if (starts[reachable[middle].id]! <= right) {
            low = middle + 1;
          } else {
            high = middle;
          }
        }
        if (low == 0) continue;
        final branch = reachable[low - 1].id;
        if (branch != atom.id && right < ends[branch]!) {
          graph.putIfAbsent(atom.id, () => {}).add(branch);
        }
      }
      final byId = {for (final atom in reachable) atom.id: atom};
      final ordered = _topological(byId.keys, graph, (a, b) {
        final stamp = _compareStamp(byId[b]!.stamp, byId[a]!.stamp);
        return stamp != 0 ? stamp : a.compareTo(b);
      });
      children[entry.key] = [for (final id in ordered) byId[id]!];
    }
    final text = StringBuffer();
    final ids = <String>[];
    final boundaries = <int>[0];
    final visibleStack = [...(children[null] ?? const <_Atom>[]).reversed];
    while (visibleStack.isNotEmpty) {
      final atom = visibleStack.removeLast();
      if (!deleted.contains(atom.id)) {
        text.write(atom.text);
        ids.add(atom.id);
        boundaries.add(boundaries.last + atom.text.length);
      }
      visibleStack.addAll((children[atom.id] ?? const <_Atom>[]).reversed);
    }
    return _snapshot = TreeTextSnapshot._(
      personId,
      field,
      itemId,
      text.toString(),
      ids,
      boundaries,
    );
  }
}

int _compareStamp(StampedTreeOperation a, StampedTreeOperation b) {
  final clock = a.clock.compareTo(b.clock);
  if (clock != 0) return clock;
  final author = a.author.compareTo(b.author);
  return author != 0 ? author : a.id.compareTo(b.id);
}

bool _reaches(
  String start,
  String target,
  Iterable<String> Function(String) neighbors,
) {
  final pending = [start];
  final seen = <String>{};
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (id == target) return true;
    if (seen.add(id)) pending.addAll(neighbors(id));
  }
  return false;
}

List<String> _topological(
  Iterable<String> ids,
  Map<String, Set<String>> graph,
  int Function(String, String) compare,
) {
  final remaining = SplayTreeSet<String>(compare)..addAll(ids);
  final degrees = {for (final id in remaining) id: 0};
  for (final outgoing in graph.values) {
    for (final to in outgoing) {
      degrees[to] = degrees[to]! + 1;
    }
  }
  final ready = SplayTreeSet<String>(compare)
    ..addAll(remaining.where((id) => degrees[id] == 0));
  final result = <String>[];
  while (remaining.isNotEmpty) {
    // Malformed cross-referencing atoms cannot hang or make replay dependent.
    final id = ready.isEmpty ? remaining.first : ready.first;
    ready.remove(id);
    if (!remaining.remove(id)) continue;
    result.add(id);
    for (final next in graph[id] ?? const <String>{}) {
      degrees[next] = degrees[next]! - 1;
      if (degrees[next] == 0 && remaining.contains(next)) ready.add(next);
    }
  }
  return result;
}

enum _EditKind { keep, delete, insert }

class _Edit {
  const _Edit(this.kind, this.rune);
  final _EditKind kind;
  final int rune;
}

List<_Edit> _diff(List<int> old, List<int> value) {
  var prefix = 0;
  while (prefix < old.length &&
      prefix < value.length &&
      old[prefix] == value[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < old.length - prefix &&
      suffix < value.length - prefix &&
      old[old.length - suffix - 1] == value[value.length - suffix - 1]) {
    suffix++;
  }
  final a = old.sublist(prefix, old.length - suffix);
  final b = value.sublist(prefix, value.length - suffix);
  final middle =
      _myers(a, b) ??
      [
        for (final rune in a) _Edit(_EditKind.delete, rune),
        for (final rune in b) _Edit(_EditKind.insert, rune),
      ];
  return [
    for (var i = 0; i < prefix; i++) _Edit(_EditKind.keep, old[i]),
    ...middle,
    for (var i = old.length - suffix; i < old.length; i++)
      _Edit(_EditKind.keep, old[i]),
  ];
}

List<_Edit>? _myers(List<int> a, List<int> b) {
  if (a.isEmpty) return [for (final rune in b) _Edit(_EditKind.insert, rune)];
  if (b.isEmpty) return [for (final rune in a) _Edit(_EditKind.delete, rune)];
  final trace = <Map<int, int>>[];
  final v = <int, int>{1: 0};
  var work = 0;
  for (var d = 0; d <= a.length + b.length && d <= 512; d++) {
    trace.add(Map.of(v));
    for (var k = -d; k <= d; k += 2) {
      if (++work > 1000000) return null;
      var x = k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0))
          ? v[k + 1] ?? 0
          : (v[k - 1] ?? 0) + 1;
      var y = x - k;
      while (x < a.length && y < b.length && a[x] == b[y]) {
        x++;
        y++;
        if (++work > 1000000) return null;
      }
      v[k] = x;
      if (x < a.length || y < b.length) continue;
      final edits = <_Edit>[];
      x = a.length;
      y = b.length;
      for (var depth = d; depth >= 0; depth--) {
        final previous = trace[depth];
        final diagonal = x - y;
        final previousDiagonal =
            diagonal == -depth ||
                (diagonal != depth &&
                    (previous[diagonal - 1] ?? 0) <
                        (previous[diagonal + 1] ?? 0))
            ? diagonal + 1
            : diagonal - 1;
        final previousX = previous[previousDiagonal] ?? 0;
        final previousY = previousX - previousDiagonal;
        while (x > previousX && y > previousY) {
          edits.add(_Edit(_EditKind.keep, a[--x]));
          y--;
        }
        if (depth == 0) break;
        if (x == previousX) {
          edits.add(_Edit(_EditKind.insert, b[--y]));
        } else {
          edits.add(_Edit(_EditKind.delete, a[--x]));
        }
      }
      return edits.reversed.toList();
    }
  }
  return null;
}

int _boundaryAt(List<int> boundaries, int offset) {
  var low = 0;
  var high = boundaries.length;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    if (boundaries[middle] <= offset) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low - 1;
}

Map _object(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Expected a JSON object');
  }
  return value;
}

void _keys(Map json, List<String> keys) {
  if (json.length != keys.length || keys.any((key) => !json.containsKey(key))) {
    throw const FormatException('Unexpected or missing operation keys');
  }
}

String _id(Object? value, {int maxLength = 256}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > maxLength ||
      RegExp(r'[\x00-\x1f]').hasMatch(value) ||
      !_wellFormedUnicode(value)) {
    throw const FormatException('Invalid ID');
  }
  return value;
}

void _nullableId(Object? value) {
  if (value != null) _id(value);
}

TreeSurname? _surnameValue(Map<String, Object?> json) => json['text'] == null
    ? null
    : TreeSurname(
        text: json['text']! as String,
        decline: json['decline']! as bool,
      );

void _surnameText(Object? value) {
  if (value == null) return;
  if (value is! String ||
      value.isEmpty ||
      value != value.trim() ||
      value.runes.length > maxTreeSurnameLength ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value) ||
      !_wellFormedUnicode(value)) {
    throw const FormatException('Invalid or oversized surname');
  }
}

void _patronymicText(Object? value) {
  if (value is! String ||
      value != value.trim() ||
      value.runes.length > maxTreePatronymicLength ||
      RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value) ||
      !_wellFormedUnicode(value)) {
    throw const FormatException('Invalid or oversized patronymic text');
  }
}

void _validateSurnameFamilyKey(Object? value, String personId) {
  if (value is! String || value.length > 540) {
    throw const FormatException('Invalid surname family key');
  }
  if (value == _surnameFamilyKey(personId, null, null)) return;
  if (!value.startsWith('parents:')) {
    throw const FormatException('Invalid surname family identity');
  }
  // IDs may contain colons and astral Unicode; lengths use UTF-16, just as the
  // layout key does. Reject noncanonical lengths, truncation and extra suffixes.
  (String, int) component(int start) {
    final separator = value.indexOf(':', start);
    if (separator < 0) throw const FormatException('Invalid family key length');
    final encodedLength = value.substring(start, separator);
    final length = int.tryParse(encodedLength);
    if (length == null ||
        length < 1 ||
        length > 256 ||
        encodedLength != length.toString()) {
      throw const FormatException('Invalid family key length');
    }
    final end = separator + 1 + length;
    if (end > value.length) {
      throw const FormatException('Truncated family key');
    }
    return (_id(value.substring(separator + 1, end)), end);
  }

  final (_, fatherEnd) = component('parents:'.length);
  if (fatherEnd >= value.length || value[fatherEnd] != ':') {
    throw const FormatException('Missing mother family key');
  }
  final (_, motherEnd) = component(fatherEnd + 1);
  if (motherEnd != value.length) {
    throw const FormatException('Unexpected family key suffix');
  }
}

String _text(Object? value) {
  if (value is! String ||
      value.length > maxTreeTextLength ||
      !_wellFormedUnicode(value)) {
    throw const FormatException('Invalid or oversized Unicode text');
  }
  return value;
}

bool _wellFormedUnicode(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= text.length) return false;
      final next = text.codeUnitAt(i);
      if (next < 0xdc00 || next > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

void _sex(Object? value) {
  if (!TreeSex.values.any((sex) => sex.name == value)) {
    throw const FormatException('Invalid sex');
  }
}

void _color(Object? value) {
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    throw const FormatException('Expected #RRGGBB fact color');
  }
}

void _validateValue(Object? field, Object? value) {
  switch (field) {
    case 'sex':
      _sex(value);
    case 'birthDate' || 'deathDate':
      if (value != null && _dateValue(value) == null) {
        throw const FormatException('Expected yyyy-MM-dd');
      }
    case 'alive':
      if (value != null && value is! bool) {
        throw const FormatException('Expected alive true, false, or null');
      }
    case 'fatherId' || 'motherId' || 'avatarPhotoId':
      _nullableId(value);
    default:
      throw const FormatException('Unknown atomic field');
  }
}

String _dateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

DateTime? _dateValue(Object? value) {
  if (value == null) return null;
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  if (year < 1) return null;
  final date = DateTime.utc(year, month, day);
  return date.year == year && date.month == month && date.day == day
      ? date
      : null;
}

void _validatePosition(Map json) {
  _nullableId(json['afterId']);
  _nullableId(json['beforeId']);
  if (json['afterId'] == json['itemId'] ||
      json['beforeId'] == json['itemId'] ||
      (json['afterId'] != null && json['afterId'] == json['beforeId'])) {
    throw const FormatException('Invalid list anchors');
  }
}

bool isValidTreePhotoDataUrl(Object? value) {
  try {
    _validatePhoto(value);
    return true;
  } on FormatException {
    return false;
  }
}

void _validatePhoto(Object? value) {
  if (value is! String ||
      value.length > ((maxTreePhotoBytes + 2) ~/ 3) * 4 + 32) {
    throw const FormatException('Photo exceeds 700 KiB');
  }
  final match = RegExp(
    r'^data:image/(jpeg|png|webp);base64,([A-Za-z0-9+/]*={0,2})$',
  ).firstMatch(value);
  if (match == null) {
    throw const FormatException('Expected a JPEG, PNG or WebP base64 data URI');
  }
  final encoded = match[2]!;
  final bytes = base64Decode(encoded);
  if (bytes.isEmpty ||
      bytes.length > maxTreePhotoBytes ||
      base64Encode(bytes) != encoded) {
    throw const FormatException('Invalid or oversized photo base64');
  }
  final validMagic = switch (match[1]) {
    'jpeg' =>
      bytes.length >= 4 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff,
    'png' =>
      bytes.length >= 8 &&
          _bytesMatch(bytes, 0, const [137, 80, 78, 71, 13, 10, 26, 10]),
    'webp' =>
      bytes.length >= 12 &&
          _bytesMatch(bytes, 0, const [82, 73, 70, 70]) &&
          _bytesMatch(bytes, 8, const [87, 69, 66, 80]),
    _ => false,
  };
  if (!validMagic) {
    throw const FormatException('Image bytes do not match the declared MIME');
  }
}

bool _bytesMatch(List<int> bytes, int offset, List<int> signature) {
  for (var i = 0; i < signature.length; i++) {
    if (bytes[offset + i] != signature[i]) return false;
  }
  return true;
}

Map<String, Object?> _freezeMap(Map<String, Object?> map) {
  final keys = map.keys.toList()..sort();
  return Map.unmodifiable({for (final key in keys) key: _freeze(map[key])});
}

Object? _freeze(Object? value) {
  if (value is Map) return _freezeMap(Map<String, Object?>.from(value));
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}
