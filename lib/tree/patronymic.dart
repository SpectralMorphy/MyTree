/// Masculine and feminine forms derived from one father's given name.
class TreePatronymicForms {
  const TreePatronymicForms({required this.male, required this.female});

  final String male;
  final String female;

  @override
  bool operator ==(Object other) =>
      other is TreePatronymicForms &&
      other.male == male &&
      other.female == female;

  @override
  int get hashCode => Object.hash(male, female);
}

String normalizePatronymicName(String name) =>
    name.trim().toLowerCase().replaceAll('ё', 'е');

/// Built-in exceptions and common names with more than one accepted derivation.
/// Room entries take precedence; removing an entry restores this dictionary.
const Map<String, TreePatronymicForms> basePatronymicDictionary = {
  'петр': TreePatronymicForms(male: 'Петрович', female: 'Петровна'),
  'павел': TreePatronymicForms(male: 'Павлович', female: 'Павловна'),
  'лев': TreePatronymicForms(male: 'Львович', female: 'Львовна'),
  'яков': TreePatronymicForms(male: 'Яковлевич', female: 'Яковлевна'),
  'илья': TreePatronymicForms(male: 'Ильич', female: 'Ильинична'),
  'никита': TreePatronymicForms(male: 'Никитич', female: 'Никитична'),
  'лука': TreePatronymicForms(male: 'Лукич', female: 'Лукинична'),
  'кузьма': TreePatronymicForms(male: 'Кузьмич', female: 'Кузьминична'),
  'фома': TreePatronymicForms(male: 'Фомич', female: 'Фоминична'),
  'савва': TreePatronymicForms(male: 'Саввич', female: 'Саввична'),
  'сила': TreePatronymicForms(male: 'Силич', female: 'Силична'),
  'савелий': TreePatronymicForms(male: 'Савельевич', female: 'Савельевна'),
  'дмитрий': TreePatronymicForms(male: 'Дмитриевич', female: 'Дмитриевна'),
  'георгий': TreePatronymicForms(male: 'Георгиевич', female: 'Георгиевна'),
  'виталий': TreePatronymicForms(male: 'Виталиевич', female: 'Виталиевна'),
  'евгений': TreePatronymicForms(male: 'Евгеньевич', female: 'Евгеньевна'),
  'геннадий': TreePatronymicForms(male: 'Геннадьевич', female: 'Геннадьевна'),
  'валерий': TreePatronymicForms(male: 'Валерьевич', female: 'Валерьевна'),
  'анатолий': TreePatronymicForms(male: 'Анатольевич', female: 'Анатольевна'),
  'василий': TreePatronymicForms(male: 'Васильевич', female: 'Васильевна'),
  'аркадий': TreePatronymicForms(male: 'Аркадьевич', female: 'Аркадьевна'),
  'юрий': TreePatronymicForms(male: 'Юрьевич', female: 'Юрьевна'),
  'захарий': TreePatronymicForms(male: 'Захарьевич', female: 'Захарьевна'),
  'зиновий': TreePatronymicForms(male: 'Зиновьевич', female: 'Зиновьевна'),
  'прокофий': TreePatronymicForms(male: 'Прокофьевич', female: 'Прокофьевна'),
  'михаил': TreePatronymicForms(male: 'Михайлович', female: 'Михайловна'),
  'данила': TreePatronymicForms(male: 'Данилович', female: 'Даниловна'),
  'данило': TreePatronymicForms(male: 'Данилович', female: 'Даниловна'),
  'гаврила': TreePatronymicForms(male: 'Гаврилович', female: 'Гавриловна'),
  'гавриил': TreePatronymicForms(male: 'Гаврилович', female: 'Гавриловна'),
};

/// Returns null for empty or unsupported names rather than inventing a form.
/// Multiword/non-Cyrillic names can still be defined explicitly in the room.
TreePatronymicForms? generatePatronymicForms(
  String fatherName, {
  Map<String, TreePatronymicForms> overrides = const {},
}) {
  final key = normalizePatronymicName(fatherName);
  final override = overrides[key];
  if (override != null) return override;
  final exception = basePatronymicDictionary[key];
  if (exception != null) return exception;
  if (!RegExp(r'^[а-яё]+(?:-[а-яё]+)*$').hasMatch(key)) return null;

  if (key.contains('-')) {
    final parts = fatherName
        .trim()
        .split('-')
        .map((part) => generatePatronymicForms(part, overrides: overrides))
        .toList();
    if (parts.any((part) => part == null)) return null;
    return TreePatronymicForms(
      male: parts
          .map((part) => part!.male)
          .where((form) => form.isNotEmpty)
          .join('-'),
      female: parts
          .map((part) => part!.female)
          .where((form) => form.isNotEmpty)
          .join('-'),
    );
  }
  if (key.length < 2) return null;

  String stem;
  String maleSuffix;
  String femaleSuffix;
  if (key.endsWith('ий')) {
    stem = key.substring(0, key.length - 2);
    final velar = RegExp(r'[гкх]$').hasMatch(stem);
    maleSuffix = velar ? 'иевич' : 'ьевич';
    femaleSuffix = velar ? 'иевна' : 'ьевна';
  } else if (key.endsWith('й') || key.endsWith('ь')) {
    stem = key.substring(0, key.length - 1);
    maleSuffix = 'евич';
    femaleSuffix = 'евна';
  } else if (key.endsWith('а')) {
    stem = key.substring(0, key.length - 1);
    maleSuffix = 'ович';
    femaleSuffix = 'овна';
  } else if (key.endsWith('я')) {
    stem = key.substring(0, key.length - 1);
    maleSuffix = 'евич';
    femaleSuffix = 'евна';
  } else if (RegExp(r'[жчшщц]$').hasMatch(key)) {
    stem = key;
    maleSuffix = 'евич';
    femaleSuffix = 'евна';
  } else if (RegExp(r'[бвгдзклмнпрстфх]$').hasMatch(key)) {
    stem = key;
    maleSuffix = 'ович';
    femaleSuffix = 'овна';
  } else {
    return null;
  }
  if (stem.isEmpty) return null;
  // Preserve ё in generated forms, while dictionary lookup treats е/ё alike.
  final original = fatherName.trim().toLowerCase();
  stem = original.substring(0, stem.length);
  stem = '${stem[0].toUpperCase()}${stem.substring(1)}';
  return TreePatronymicForms(
    male: '$stem$maleSuffix',
    female: '$stem$femaleSuffix',
  );
}
