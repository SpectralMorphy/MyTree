import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/tree/patronymic.dart';

void main() {
  group('algorithmic patronymics', () {
    const cases = {
      'Иван': TreePatronymicForms(male: 'Иванович', female: 'Ивановна'),
      'Олег': TreePatronymicForms(male: 'Олегович', female: 'Олеговна'),
      'Роман': TreePatronymicForms(male: 'Романович', female: 'Романовна'),
      'Александр': TreePatronymicForms(
        male: 'Александрович',
        female: 'Александровна',
      ),
      'Андрей': TreePatronymicForms(male: 'Андреевич', female: 'Андреевна'),
      'Сергей': TreePatronymicForms(male: 'Сергеевич', female: 'Сергеевна'),
      'Николай': TreePatronymicForms(male: 'Николаевич', female: 'Николаевна'),
      'Игорь': TreePatronymicForms(male: 'Игоревич', female: 'Игоревна'),
      'Леонтий': TreePatronymicForms(male: 'Леонтьевич', female: 'Леонтьевна'),
      'Семён': TreePatronymicForms(male: 'Семёнович', female: 'Семёновна'),
      'Фёдор': TreePatronymicForms(male: 'Фёдорович', female: 'Фёдоровна'),
      'Акакий': TreePatronymicForms(male: 'Акакиевич', female: 'Акакиевна'),
      'Евтихий': TreePatronymicForms(male: 'Евтихиевич', female: 'Евтихиевна'),
      'Сергий': TreePatronymicForms(male: 'Сергиевич', female: 'Сергиевна'),
      'Франц': TreePatronymicForms(male: 'Францевич', female: 'Францевна'),
      'Жорж': TreePatronymicForms(male: 'Жоржевич', female: 'Жоржевна'),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(generatePatronymicForms(entry.key), entry.value);
        expect(
          generatePatronymicForms('  ${entry.key.toUpperCase()}  '),
          entry.value,
        );
      });
    }

    test('compound names derive each part', () {
      expect(
        generatePatronymicForms('Жан-Поль'),
        const TreePatronymicForms(
          male: 'Жанович-Полевич',
          female: 'Жановна-Полевна',
        ),
      );
    });

    test('empty component overrides do not leave compound separators', () {
      const blank = TreePatronymicForms(male: '', female: '');
      expect(
        generatePatronymicForms('Иван-Пётр', overrides: {'иван': blank}),
        const TreePatronymicForms(male: 'Петрович', female: 'Петровна'),
      );
      expect(
        generatePatronymicForms('Иван-Пётр', overrides: {'петр': blank}),
        const TreePatronymicForms(male: 'Иванович', female: 'Ивановна'),
      );
      expect(
        generatePatronymicForms(
          'Иван-Пётр',
          overrides: {'иван': blank, 'петр': blank},
        ),
        blank,
      );
    });

    test('does not parse legacy full names or invent unsupported forms', () {
      for (final name in [
        '',
        '  ',
        'John',
        'Иван Иванович',
        '?',
        'О',
        'Марио',
      ]) {
        expect(generatePatronymicForms(name), isNull, reason: name);
      }
    });
  });

  group('dictionary precedence', () {
    test('base exceptions', () {
      const expected = {
        'Пётр': TreePatronymicForms(male: 'Петрович', female: 'Петровна'),
        'Павел': TreePatronymicForms(male: 'Павлович', female: 'Павловна'),
        'Лев': TreePatronymicForms(male: 'Львович', female: 'Львовна'),
        'Яков': TreePatronymicForms(male: 'Яковлевич', female: 'Яковлевна'),
        'Илья': TreePatronymicForms(male: 'Ильич', female: 'Ильинична'),
        'Никита': TreePatronymicForms(male: 'Никитич', female: 'Никитична'),
        'Кузьма': TreePatronymicForms(male: 'Кузьмич', female: 'Кузьминична'),
        'Лука': TreePatronymicForms(male: 'Лукич', female: 'Лукинична'),
        'Фома': TreePatronymicForms(male: 'Фомич', female: 'Фоминична'),
        'Савва': TreePatronymicForms(male: 'Саввич', female: 'Саввична'),
        'Дмитрий': TreePatronymicForms(
          male: 'Дмитриевич',
          female: 'Дмитриевна',
        ),
        'Георгий': TreePatronymicForms(
          male: 'Георгиевич',
          female: 'Георгиевна',
        ),
        'Виталий': TreePatronymicForms(
          male: 'Виталиевич',
          female: 'Виталиевна',
        ),
        'Данила': TreePatronymicForms(male: 'Данилович', female: 'Даниловна'),
      };
      for (final entry in expected.entries) {
        expect(generatePatronymicForms(entry.key), entry.value);
      }
      expect(
        generatePatronymicForms(' ПЕТР '),
        generatePatronymicForms('Пётр'),
      );
    });

    test('room override replaces a base entry or an algorithmic result', () {
      const custom = TreePatronymicForms(
        male: 'Виталович',
        female: 'Виталовна',
      );
      expect(
        generatePatronymicForms('Виталий', overrides: {'виталий': custom}),
        custom,
      );
      expect(
        generatePatronymicForms('Иван', overrides: {'иван': custom}),
        custom,
      );
      expect(
        generatePatronymicForms('Виталий'),
        basePatronymicDictionary['виталий'],
      );
    });

    test('room can explicitly support non-Cyrillic or multiword names', () {
      const custom = TreePatronymicForms(male: 'Джонович', female: 'Джоновна');
      for (final name in ['John', 'Иван Иванович']) {
        expect(
          generatePatronymicForms(
            name,
            overrides: {normalizePatronymicName(name): custom},
          ),
          custom,
        );
      }
    });

    test('lookup normalization does not mutate the dictionary', () {
      const custom = TreePatronymicForms(male: 'Левович', female: 'Левовна');
      final entries = {'лев': custom};
      expect(generatePatronymicForms('  ЛЕВ  ', overrides: entries), custom);
      expect(entries, {'лев': custom});
      expect(
        generatePatronymicForms('Лев'),
        const TreePatronymicForms(male: 'Львович', female: 'Львовна'),
      );
    });
  });
}
