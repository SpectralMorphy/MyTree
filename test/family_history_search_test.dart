import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';
import 'package:mytree_webrtc_demo/ui/tree_search.dart';

void main() {
  test('search uses the latest surname together with computed patronymics', () {
    final tree = TreeDocument();
    var clock = 0;
    void apply(TreeOperation operation) {
      final sequence = ++clock;
      tree.merge([
        StampedTreeOperation(
          id: 'history-search-$sequence',
          author: 'editor',
          clock: sequence,
          createdAt: DateTime.utc(2026),
          operation: operation,
        ),
      ]);
    }

    apply(tree.editText('root', TreeTextField.name, 'Анна')!);
    apply(tree.setValue('root', 'sex', TreeSex.female.name));
    apply(tree.setIndividualSurname('root', text: 'Смирнов', decline: true));
    apply(tree.createPerson('father', name: 'Пётр', sex: TreeSex.male));
    apply(tree.setValue('root', 'fatherId', 'father'));
    apply(tree.createPerson('partner', name: 'Иван', sex: TreeSex.male));
    apply(tree.setIndividualSurname('partner', text: 'Иванов', decline: true));
    apply(tree.createPerson('child', name: 'Алексей', sex: TreeSex.male));
    apply(tree.setValue('child', 'fatherId', 'partner'));
    apply(tree.setValue('child', 'motherId', 'root'));
    apply(tree.setValue('child', 'birthDate', '2000-01-01'));

    expect(
      tree.person('root')!.fullNameWithPatronymic,
      'Иванова Анна Петровна',
    );
    expect(
      searchTreePeople(tree.people, 'иванова анна петровна').map((p) => p.id),
      ['root'],
    );
    expect(tree.person('root')!.effectiveSurname!.text, 'Смирнов');

    apply(
      tree.addSurnameChange(
        'root',
        id: 'personal-change',
        surname: const TreeSurname(text: 'Соколов', decline: true),
        date: DateTime.utc(2020, 2, 3),
        reason: 'Личная причина',
      ),
    );
    expect(tree.person('root')!.fullName, 'Анна Соколова');
    expect(
      tree.person('root')!.fullNameWithPatronymic,
      'Соколова Анна Петровна',
    );
    expect(
      searchTreePeople(tree.people, 'соколова петровна').map((p) => p.id),
      ['root'],
    );

    apply(tree.removeSurnameChange('root', 'personal-change'));
    expect(tree.person('root')!.surname, 'Иванова');
    final marriageId = tree.marriagesOf('root').single.id;
    apply(tree.removeMarriage('root', marriageId));
    expect(tree.person('root')!.surname, 'Смирнова');
    expect(
      searchTreePeople(tree.people, 'смирнова петровна').map((p) => p.id),
      ['root'],
    );
    expect(tree.person('child')!.fatherId, 'partner');
    expect(tree.person('child')!.motherId, 'root');
    expect(tree.person('child')!.surname, 'Иванов');
  });

  test(
    'a father changing current surname does not change birth inheritance',
    () {
      final tree = TreeDocument();
      var clock = 0;
      void apply(TreeOperation operation) {
        final sequence = ++clock;
        tree.merge([
          StampedTreeOperation(
            id: 'birth-search-$sequence',
            author: 'editor',
            clock: sequence,
            createdAt: DateTime.utc(2026),
            operation: operation,
          ),
        ]);
      }

      apply(tree.editText('root', TreeTextField.name, 'Иван')!);
      apply(tree.setValue('root', 'sex', TreeSex.male.name));
      apply(tree.setIndividualSurname('root', text: 'Иванов', decline: true));
      apply(tree.createPerson('child', name: 'Мария', sex: TreeSex.female));
      apply(tree.setValue('child', 'fatherId', 'root'));
      apply(
        tree.addSurnameChange(
          'root',
          id: 'father-change',
          surname: const TreeSurname(text: 'Орлов', decline: true),
          date: DateTime.utc(2025),
          reason: 'Смена фамилии',
        ),
      );
      expect(tree.person('root')!.fullName, 'Иван Орлов');
      expect(
        tree.person('child')!.fullNameWithPatronymic,
        'Иванова Мария Ивановна',
      );
      expect(
        searchTreePeople(
          tree.people,
          'иванова мария ивановна',
        ).map((p) => p.id),
        ['child'],
      );
      expect(surnameForBlock([tree.person('root')!]), 'Иванов');
    },
  );

  test('a declension-only change hides an unchanged displayed surname', () {
    final tree = TreeDocument();
    var clock = 0;
    void apply(TreeOperation operation) {
      final sequence = ++clock;
      tree.merge([
        StampedTreeOperation(
          id: 'same-display-$sequence',
          author: 'editor',
          clock: sequence,
          createdAt: DateTime.utc(2026),
          operation: operation,
        ),
      ]);
    }

    apply(tree.setValue('root', 'sex', TreeSex.male.name));
    apply(tree.setIndividualSurname('root', text: 'Иванов', decline: false));
    apply(
      tree.addSurnameChange(
        'root',
        id: 'declension-only',
        surname: const TreeSurname(text: 'Иванов', decline: true),
        date: DateTime.utc(2020),
        reason: 'Уточнение склонения',
      ),
    );
    expect(
      tree.historyOf('root').single.surnameChange!.changesSurname,
      isFalse,
    );
    expect(tree.person('root')!.surname, 'Иванов');
    expect(tree.person('root')!.currentSurname!.decline, isTrue);
    expect(tree.person('root')!.effectiveSurname!.decline, isFalse);

    apply(tree.setValue('root', 'sex', TreeSex.female.name));
    expect(tree.historyOf('root').single.surnameChange!.changesSurname, isTrue);
    expect(tree.person('root')!.surname, 'Иванова');
  });
}
