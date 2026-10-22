/// Pure immutable surname and family-history values. Persistence and event
/// replay belong to TreeDocument; dates inferred from children are ordering hints
/// only and never become marriage dates.
enum TreeSex { unknown, male, female }

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

enum TreeMarriageEndMode { unknown, lifelong, date }

/// Optional new identity created atomically by addMarriage.
class TreeNewMarriagePartner {
  const TreeNewMarriagePartner({
    this.name = '',
    this.sex = TreeSex.unknown,
    this.birthDate,
    this.birthSurname,
  });

  final String name;
  final TreeSex sex;
  final DateTime? birthDate;
  final TreeSurname? birthSurname;
}

/// Canonical undirected identity, including IDs containing colons or Unicode.
String treeMarriagePairKey(String a, String b) {
  final first = a.compareTo(b) <= 0 ? a : b;
  final second = first == a ? b : a;
  return '${first.length}:$first:${second.length}:$second';
}

/// An explicit choice belongs to one partner, never to the whole pair. An
/// explicit adopted surname is a snapshot, not a reference to a current surname.
class TreeMarriageSurnameChoice {
  const TreeMarriageSurnameChoice({
    required this.changeSurname,
    this.adoptedSurname,
    this.isExplicit = false,
  });

  final bool changeSurname;
  final TreeSurname? adoptedSurname;
  final bool isExplicit;
}

class TreeMarriage {
  TreeMarriage({
    required this.id,
    required this.personId,
    required this.partnerId,
    this.startDate,
    this.endDate,
    this.endMode = TreeMarriageEndMode.unknown,
    this.isImplied = false,
    DateTime? orderingDate,
    Map<String, TreeMarriageSurnameChoice> surnameChoices = const {},
  }) : orderingDate = startDate ?? orderingDate,
       surnameChoices = Map.unmodifiable(surnameChoices);

  final String id;
  final String personId;
  final String partnerId;
  final DateTime? startDate;
  final DateTime? endDate;
  final TreeMarriageEndMode endMode;
  final bool isImplied;

  /// May be the oldest common child's known DOB. Never display this as a start.
  final DateTime? orderingDate;
  final Map<String, TreeMarriageSurnameChoice> surnameChoices;

  String get pairKey => treeMarriagePairKey(personId, partnerId);

  String? otherPersonId(String id) => id == personId
      ? partnerId
      : id == partnerId
      ? personId
      : null;

  /// Only explicit dates constitute a range; a child's DOB is never exposed here.
  bool get hasExplicitDates => startDate != null || endDate != null;

  /// A lifelong union ends at the first known death, not at an inferred date.
  /// Null without a known death means the boundary is still unknown/current;
  /// callers can distinguish living/unknown people using their alive registers.
  DateTime? lifelongEndDate(DateTime? personDeath, DateTime? partnerDeath) {
    if (endMode != TreeMarriageEndMode.lifelong) return null;
    if (personDeath == null) return partnerDeath;
    if (partnerDeath == null) return personDeath;
    return personDeath.isBefore(partnerDeath) ? personDeath : partnerDeath;
  }
}

class TreeSurnameChange {
  const TreeSurnameChange({
    required this.id,
    required this.personId,
    required this.surname,
    this.date,
    this.reason = '',
    this.marriageId,
    this.partnerId,
    this.isImplied = false,
    this.changesSurname = true,
    DateTime? orderingDate,
  }) : orderingDate = date ?? orderingDate;

  final String id;
  final String personId;
  final TreeSurname surname;
  final DateTime? date;
  final String reason;
  final String? marriageId;
  final String? partnerId;
  final bool isImplied;

  /// Whether this record changes the preceding chronological surname. Generic
  /// records remain editable/reason-visible even when this is false.
  final bool changesSurname;

  /// Sorting only. In particular an implied marriage does not acquire a date.
  final DateTime? orderingDate;
}

/// One UI history row: a marriage (optionally with an actual surname change),
/// or an independent surname change. No duplicate surname row is manufactured
/// for a marriage, and unchanged surnames have no surnameChange value.
class TreeFamilyHistoryEntry {
  const TreeFamilyHistoryEntry({
    required this.id,
    this.marriage,
    this.surnameChange,
  }) : assert(marriage != null || surnameChange != null);

  final String id;
  final TreeMarriage? marriage;
  final TreeSurnameChange? surnameChange;

  DateTime? get orderingDate =>
      surnameChange?.orderingDate ?? marriage?.orderingDate;
}

/// Chronological surname order is independent of event delivery/stamps. Missing
/// dates sort before dated entries, then by canonical surname and stable ID.
int compareTreeSurnameChanges(TreeSurnameChange a, TreeSurnameChange b) {
  final aDate = a.orderingDate;
  final bDate = b.orderingDate;
  if (aDate == null && bDate != null) return -1;
  if (aDate != null && bDate == null) return 1;
  if (aDate != null && bDate != null) {
    final dates = aDate.compareTo(bDate);
    if (dates != 0) return dates;
  }
  final names = a.surname.text.compareTo(b.surname.text);
  if (names != 0) return names;
  final kind = (a.marriageId == null ? 1 : 0).compareTo(
    b.marriageId == null ? 1 : 0,
  );
  if (kind != 0) return kind;
  final ids = a.id.compareTo(b.id);
  return ids != 0 ? ids : a.personId.compareTo(b.personId);
}
