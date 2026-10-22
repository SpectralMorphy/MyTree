import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';
import 'package:mytree_webrtc_demo/tree/tree_layout.dart';

void main() {
  group('TreeLayout', () {
    test('a lone root is centered and output collections are immutable', () {
      final layout = TreeLayout.build(
        TreeDocument(),
        selectedId: rootTreePersonId,
        mode: TreeTrunkMode.both,
      );

      expect(layout.levels, hasLength(1));
      expect(layout.positions.keys, [rootTreePersonId]);
      expect(layout.positions[rootTreePersonId]!.level, 0);
      expect(layout.positions[rootTreePersonId]!.crossCenter, 0);
      expect(layout.levels.single.minCross, -48);
      expect(layout.levels.single.maxCross, 48);
      expect(layout.levels.single.crossExtent, 96);
      expect(layout.trunkIds, {rootTreePersonId});
      expect(layout.links, isEmpty);
      expect(() => layout.levels.clear(), throwsUnsupportedError);
      expect(() => layout.positions.clear(), throwsUnsupportedError);
      expect(() => layout.trunkIds.clear(), throwsUnsupportedError);
      expect(() => layout.links.clear(), throwsUnsupportedError);
      expect(
        () => layout.levels.single.blocks.single.people.clear(),
        throwsUnsupportedError,
      );
    });

    test('groups only identical complete parents and sorts births stably', () {
      final family = _Family()
        ..add('father')
        ..add('mother')
        ..add('other-mother')
        ..add('unknown-b')
        ..add('unknown-a')
        ..add('young')
        ..add('old-b')
        ..add('old-a')
        ..add('half')
        ..add('one-parent-a')
        ..add('one-parent-b')
        ..add('swapped');
      for (final id in ['unknown-b', 'unknown-a', 'young', 'old-b', 'old-a']) {
        family.parents(id, father: 'father', mother: 'mother');
      }
      family
        ..birth('young', '2005-01-01')
        ..birth('old-b', '2000-01-01')
        ..birth('old-a', '2000-01-01')
        ..parents('half', father: 'father', mother: 'other-mother')
        ..parents('one-parent-a', father: 'father')
        ..parents('one-parent-b', father: 'father')
        ..parents('swapped', father: 'mother', mother: 'father');
      final layout = family.layout('young');
      final block = _blockFor(layout, 'young');

      expect(block.people.map((p) => p.id), [
        'unknown-a',
        'unknown-b',
        'old-a',
        'old-b',
        'young',
      ]);
      expect(block.fatherId, 'father');
      expect(block.motherId, 'mother');
      expect(block.extent, 5 * 96 + 4 * 24);
      expect(layout.positions['young']!.crossCenter, 0);
      for (final id in ['half', 'one-parent-a', 'one-parent-b', 'swapped']) {
        expect(_blockFor(layout, id).id, isNot(block.id));
      }
      expect(
        _blockFor(layout, 'one-parent-a').id,
        isNot(_blockFor(layout, 'one-parent-b').id),
      );
      expect(
        _blockFor(layout, 'father').id,
        isNot(_blockFor(layout, 'mother').id),
      );
      _expectNoOverlap(layout);
    });

    test(
      'undated and equal-date siblings use trimmed given names then strict IDs',
      () {
        for (final date in [null, '1980-06-15']) {
          _Family make(bool reverse) {
            final family = _Family()
              ..add('father')
              ..add('mother')
              ..add('partner');
            final siblings = [
              ('a-id', '  Вера  '),
              ('z-id', '  Анна'),
              ('b-id', 'Борис  '),
              ('same-z', 'Борис'),
              ('same-a', 'Борис'),
            ];
            for (final (id, name) in reverse ? siblings.reversed : siblings) {
              family
                ..add(id, name: name)
                ..parents(id, father: 'father', mother: 'mother');
              if (date != null) family.birth(id, date);
            }
            return family
              ..add('shared-child')
              ..parents('shared-child', mother: 'z-id', father: 'partner');
          }

          final family = make(false);
          final people = family.document.people;
          final events = family.events.toList();
          const canonical = ['z-id', 'b-id', 'same-a', 'same-z', 'a-id'];
          final initial = family.layout('z-id');
          var previous = family.layout('shared-child');
          for (final mode in TreeTrunkMode.values) {
            for (final selected in [
              'partner',
              'same-z',
              'z-id',
              'father',
              rootTreePersonId,
              'shared-child',
              'a-id',
              'z-id',
            ]) {
              final layout = family.layout(selected, mode, previous);
              expect(
                _blockFor(layout, 'z-id').people.map((p) => p.id),
                mode == TreeTrunkMode.both && selected == 'shared-child'
                    ? ['b-id', 'same-a', 'same-z', 'a-id', 'z-id']
                    : canonical,
                reason: '$date / $mode / $selected',
              );
              if (mode == TreeTrunkMode.both && selected == 'shared-child') {
                _expectParentCardsAdjacent(layout, 'z-id', 'partner');
              }
              final reverse = make(true).layout(selected, mode);
              expect(_snapshot(layout), _snapshot(reverse));
              expect(
                _snapshot(layout),
                _snapshot(family.layout(selected, mode)),
              );
              expect(
                _blockFor(layout, 'z-id').id,
                _blockFor(initial, 'z-id').id,
              );
              _expectSameRanks(initial, layout);
              expect(
                layout.links.map((e) => (e.parentId, e.childId, e.blockId)),
                initial.links.map((e) => (e.parentId, e.childId, e.blockId)),
              );
              _expectDescendingLinks(layout);
              _expectNoOverlap(layout);
              previous = layout;
            }
          }
          expect(identical(family.document.people, people), isTrue);
          expect(family.events, events);
        }
      },
    );

    test(
      'unknown births are older than every dated birth, then dates ascend',
      () {
        _Family make(bool reverse) {
          final family = _Family()
            ..add('father')
            ..add('mother');
          final siblings = [
            ('unknown-z', ' Яна ', null),
            ('unknown-a', ' Юрий ', null),
            ('dated-z', 'Алексей', '1800-01-01'),
            ('dated-a', 'Борис', '2000-01-01'),
            ('dated-tie-z', '  Анна  ', '2000-01-01'),
            ('dated-tie-a', 'Вера', '2000-01-01'),
          ];
          for (final (id, name, date)
              in reverse ? siblings.reversed : siblings) {
            family
              ..add(id, name: name)
              ..parents(id, father: 'father', mother: 'mother');
            if (date != null) family.birth(id, date);
          }
          return family;
        }

        final family = make(false);
        final canonical = family.layout('unknown-a');
        var previous = canonical;
        for (final mode in TreeTrunkMode.values) {
          for (final selected in family.document.people.keys) {
            final layout = family.layout(selected, mode, previous);
            expect(_blockFor(layout, 'unknown-a').people.map((p) => p.id), [
              'unknown-a',
              'unknown-z',
              'dated-z',
              'dated-tie-z',
              'dated-a',
              'dated-tie-a',
            ]);
            _expectTranslatedRow(
              canonical,
              layout,
              canonical.positions['unknown-a']!.level,
            );
            expect(
              _snapshot(layout),
              _snapshot(make(true).layout(selected, mode)),
            );
            _expectSameRanks(canonical, layout);
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
            previous = layout;
          }
        }
      },
    );

    test(
      'current name and date edits recompute canonical order without history',
      () {
        final family = _Family()
          ..add('father')
          ..add('mother')
          ..add('a', name: 'Яна')
          ..add('z', name: 'Анна')
          ..parents('a', father: 'father', mother: 'mother')
          ..parents('z', father: 'father', mother: 'mother');
        final initial = family.layout('a');
        expect(_blockFor(initial, 'a').people.map((p) => p.id), ['z', 'a']);
        family._apply(
          family.document.editText('a', TreeTextField.name, '  Ада  ')!,
        );
        final renamed = family.layout('z', TreeTrunkMode.both, initial);
        expect(_blockFor(renamed, 'a').people.map((p) => p.id), ['a', 'z']);
        expect(_snapshot(renamed), _snapshot(family.layout('z')));
        family.birth('a', '1800-01-01');
        for (final mode in TreeTrunkMode.values) {
          final dated = family.layout('a', mode, renamed);
          expect(_blockFor(dated, 'a').people.map((p) => p.id), ['z', 'a']);
          expect(_snapshot(dated), _snapshot(family.layout('a', mode)));
          _expectSameRanks(initial, dated);
          _expectDescendingLinks(dated);
          _expectNoOverlap(dated);
        }
      },
    );

    test('adding Lydia’s father keeps Gennady and Lydia on one generation', () {
      final family = _Family()
        ..add('gennady')
        ..add('lydia')
        ..add('natalia')
        ..add('veronika')
        ..parents('natalia', father: 'gennady', mother: 'lydia')
        ..parents('veronika', father: 'gennady', mother: 'lydia');
      final before = {
        for (final mode in TreeTrunkMode.values)
          mode: family.layout('natalia', mode),
      };
      family
        ..add('test')
        ..parents('lydia', father: 'test');
      for (final mode in TreeTrunkMode.values) {
        var previous = family.layout('natalia', mode, before[mode]);
        expect(previous.positions['test']!.level, 0);
        expect(previous.positions['gennady']!.level, 1);
        expect(previous.positions['lydia']!.level, 1);
        expect(previous.positions['natalia']!.level, 2);
        expect(previous.positions['veronika']!.level, 2);
        expect(
          _blockFor(previous, 'natalia').id,
          _blockFor(previous, 'veronika').id,
        );
        for (final id in ['lydia', 'gennady', 'test', 'veronika', 'natalia']) {
          final current = family.layout(id, mode, previous);
          _expectSameRanks(previous, current);
          _expectDescendingLinks(current);
          _expectNoOverlap(current);
          previous = current;
        }
      }
      final established = family.layout('natalia');
      // Neither a new child of the same couple nor an unrelated family changes
      // the couple constraint's priority or the existing generation numbers.
      family
        ..add('00-new-sibling')
        ..parents('00-new-sibling', father: 'gennady', mother: 'lydia')
        ..add('unrelated-parent')
        ..add('unrelated-child')
        ..parents('unrelated-child', father: 'unrelated-parent');
      final expanded = family.layout(
        'natalia',
        TreeTrunkMode.both,
        established,
      );
      _expectSameRanks(established, expanded);
      _expectDescendingLinks(expanded);
      _expectNoOverlap(expanded);
      family
        ..add('great-grandfather')
        ..parents('test', father: 'great-grandfather');
      final extended = family.layout('lydia', TreeTrunkMode.both, expanded);
      expect(extended.positions['test']!.level, 1);
      expect(extended.positions['gennady']!.level, 2);
      expect(extended.positions['lydia']!.level, 2);
      expect(extended.positions['natalia']!.level, 3);
      expect(extended.positions['veronika']!.level, 3);
      _expectDescendingLinks(extended);
      _expectNoOverlap(extended);
    });

    test(
      'new undated Oleg parents follow his generation, not unrelated roots',
      () {
        final family = _lydiaFamily(knownOtherParent: true)
          ..sex('oleg', TreeSex.male)
          ..add('prikol')
          ..parents('prikol', father: 'gennady', mother: 'lydia')
          ..add('great-grandparent')
          ..parents('test', father: 'great-grandparent')
          ..add('oldest')
          ..parents('great-grandparent', father: 'oldest');
        // A deeper disconnected tree must not supply a global bottom anchor.
        family.add('unrelated-0');
        for (var i = 1; i <= 8; i++) {
          family
            ..add('unrelated-$i')
            ..parents('unrelated-$i', father: 'unrelated-${i - 1}');
        }
        final established = family.layout('oleg');
        expect(established.positions['oleg']!.level, 4);
        var previous = established;
        final addedParents = <String>[];

        void verify() {
          for (final mode in TreeTrunkMode.values) {
            for (final selected in [
              'oleg',
              'olga',
              'natalia',
              'prikol',
              ...addedParents,
              'oleg',
            ]) {
              final current = family.layout(selected, mode, previous);
              _expectSameRanks(established, current);
              final olegRank = current.positions['oleg']!.level;
              for (final id in ['gennady', 'lydia', ...addedParents]) {
                expect(current.positions[id]!.level, olegRank - 1, reason: id);
              }
              for (final id in ['natalia', 'veronika', 'prikol']) {
                expect(current.positions[id]!.level, olegRank);
                expect(
                  _blockFor(current, id).id,
                  _blockFor(current, 'natalia').id,
                );
              }
              expect(current.positions['olga']!.level, olegRank + 1);
              if (addedParents.length == 2 && mode == TreeTrunkMode.both) {
                _expectParentCardsAdjacent(
                  current,
                  'oleg-mother',
                  'oleg-father',
                );
              }
              expect(
                _snapshot(current),
                _snapshot(family.layout(selected, mode)),
              );
              _expectDescendingLinks(current);
              _expectNoOverlap(current);
              previous = current;
            }
          }
        }

        // Match the relative dialog's real command sequence: first create the
        // disconnected person, then set the child's father/mother reference.
        for (final role in ['father', 'mother']) {
          final id = 'oleg-$role';
          family.add(id);
          final unconnected = family.layout('oleg');
          _expectSameRanks(previous, unconnected);
          expect(unconnected.positions[id]!.level, 0);
          final person = family.document.people[id]!;
          expect(person.sex, TreeSex.unknown);
          expect(person.birthDate, isNull);
          expect(person.deathDate, isNull);
          family.parents(
            'oleg',
            father: role == 'father' ? id : null,
            mother: role == 'mother' ? id : null,
          );
          addedParents.add(id);
          verify();
        }
        // A second free ancestor chain must inherit the same local anchoring.
        family
          ..add('oleg-grandfather')
          ..parents('oleg-father', father: 'oleg-grandfather')
          ..add('oleg-grandmother')
          ..parents('oleg-father', mother: 'oleg-grandmother');
        verify();
        for (final id in ['oleg-grandfather', 'oleg-grandmother']) {
          expect(
            previous.positions[id]!.level,
            previous.positions['oleg-father']!.level - 1,
          );
        }
      },
    );

    test(
      'Shrek follows compact Oleg parents instead of pulling them to the top',
      () {
        for (final bothShrekParents in [false, true]) {
          final family = _lydiaFamily(knownOtherParent: true)
            ..add('oldest')
            ..add('great-grandparent')
            ..parents('great-grandparent', father: 'oldest')
            ..parents('test', father: 'great-grandparent');
          final beforeParents = family.layout('oleg');
          for (final role in ['father', 'mother']) {
            final id = 'oleg-$role';
            family.add(id);
            _expectSameRanks(beforeParents, family.layout(id));
            family.parents(
              'oleg',
              father: role == 'father' ? id : null,
              mother: role == 'mother' ? id : null,
            );
          }
          final beforeShrek = family.layout('oleg');
          expect(beforeShrek.positions['oleg']!.level, 4);
          expect(beforeShrek.positions['oleg-father']!.level, 3);
          expect(beforeShrek.positions['oleg-mother']!.level, 3);
          // Match the relative dialog: create a disconnected child first, then
          // assign its selected parent, then (optionally) its second parent.
          family.add('shrek');
          _expectSameRanks(beforeShrek, family.layout('shrek'));
          expect(family.layout('shrek').positions['shrek']!.level, 0);
          family.parents('shrek', father: 'oleg-father');
          if (bothShrekParents) family.parents('shrek', mother: 'oleg-mother');
          for (final mode in TreeTrunkMode.values) {
            for (final selected in family.document.people.keys) {
              final current = family.layout(selected, mode, beforeShrek);
              _expectSameRanks(beforeShrek, current);
              expect(
                current.positions['shrek']!.level,
                4,
                reason: 'both parents: $bothShrekParents / $mode / $selected',
              );
              expect(
                _snapshot(current),
                _snapshot(family.layout(selected, mode)),
              );
              _expectDescendingLinks(current);
              _expectNoOverlap(current);
            }
          }
        }
      },
    );

    test(
      'collateral additions, ancestry edits, unlink/delete and reload compact locally',
      () {
        for (final parentsFirst in [false, true]) {
          final family = _lydiaFamily(knownOtherParent: true)
            ..add('oldest')
            ..add('great-grandparent')
            ..parents('great-grandparent', father: 'oldest')
            ..parents('test', father: 'great-grandparent')
            ..add('oleg-father')
            ..add('oleg-mother');
          family.add('unrelated-0');
          for (var i = 1; i <= 9; i++) {
            family
              ..add('unrelated-$i')
              ..parents('unrelated-$i', father: 'unrelated-${i - 1}');
          }
          void connectParents() => family.parents(
            'oleg',
            father: 'oleg-father',
            mother: 'oleg-mother',
          );
          if (parentsFirst) connectParents();
          final children = <String>[];
          for (final (id, father, mother) in [
            ('shrek', 'oleg-father', null),
            ('mother-child', null, 'oleg-mother'),
            ('full-child', 'oleg-father', 'oleg-mother'),
            ('another-child', 'oleg-father', null),
          ]) {
            family.add(id);
            expect(family.layout(id).positions[id]!.level, 0);
            family.parents(id, father: father, mother: mother);
            children.add(id);
            if (!parentsFirst) continue;
            final current = family.layout(id);
            expect(current.positions['oleg-father']!.level, 3);
            expect(current.positions['oleg-mother']!.level, 3);
            for (final child in children) {
              expect(current.positions[child]!.level, 4);
            }
          }
          if (!parentsFirst) connectParents();
          family
            ..add('shrek-child')
            ..parents('shrek-child', father: 'shrek');
          final established = family.layout('oleg');
          for (final child in children) {
            expect(established.positions[child]!.level, 4);
          }
          expect(established.positions['shrek-child']!.level, 5);
          expect(established.positions['unrelated-9']!.level, 9);
          void verify() {
            final reloaded = family.reload();
            for (final mode in TreeTrunkMode.values) {
              for (final selected in family.document.people.keys) {
                final current = family.layout(selected, mode, established);
                final cold = TreeLayout.build(
                  reloaded,
                  selectedId: selected,
                  mode: mode,
                );
                expect(_snapshot(current), _snapshot(cold));
                for (final id in current.positions.keys) {
                  if (established.positions.containsKey(id)) {
                    expect(
                      current.positions[id]!.level,
                      established.positions[id]!.level,
                    );
                  }
                }
                _expectDescendingLinks(current);
                _expectNoOverlap(current);
              }
            }
          }

          verify();
          // Making Shrek a complete sibling cannot change the equality cohort.
          family.parents('shrek', mother: 'oleg-mother');
          verify();
          family._apply(family.document.setValue('shrek', 'motherId', null));
          verify();
          // A new free ancestor with a shallow collateral leaf follows the same
          // local optimum; it is not another root/leaf anchoring exception.
          family
            ..add('oleg-grandfather')
            ..parents('oleg-father', father: 'oleg-grandfather')
            ..add('grandfather-child')
            ..parents('grandfather-child', father: 'oleg-grandfather');
          expect(family.layout('oleg').positions['oleg-grandfather']!.level, 2);
          expect(
            family.layout('oleg').positions['grandfather-child']!.level,
            3,
          );
          verify();
          family._apply(family.document.deletePerson('another-child'));
          verify();
          family._apply(
            family.document.setValue('mother-child', 'motherId', null),
          );
          final unlinked = family.layout('oleg');
          for (final mode in TreeTrunkMode.values) {
            for (final selected in family.document.people.keys) {
              final current = family.layout(selected, mode, established);
              _expectSameRanks(unlinked, current);
              _expectDescendingLinks(current);
              _expectNoOverlap(current);
            }
          }
          expect(unlinked.positions['mother-child']!.level, 0);
          expect(unlinked.positions['oleg-father']!.level, 3);
          expect(unlinked.positions['oleg-mother']!.level, 3);
          expect(
            _snapshot(unlinked),
            _snapshot(
              TreeLayout.build(
                family.reload(),
                selectedId: 'oleg',
                mode: TreeTrunkMode.both,
              ),
            ),
          );
        }
      },
    );

    test(
      'all feasible one-band generation edges stay short with collateral branches',
      () {
        _Family make(int seed, bool reverse) {
          final random = math.Random(seed);
          final dates = math.Random(seed + 1000);
          final family = _Family();
          final ids = [
            for (var rank = 0; rank <= 5; rank++)
              for (var member = 0; member < 3; member++) 'g$rank-$member',
          ];
          for (final id in reverse ? ids.reversed : ids) {
            family.add(id);
            if (reverse) family.birth(id, '${1900 + dates.nextInt(100)}-01-01');
          }
          for (var rank = 1; rank <= 5; rank++) {
            for (var member = 0; member < 3; member++) {
              // Guaranteed spanning paths plus a second compatible co-parent.
              family.parents(
                'g$rank-$member',
                father: 'g${rank - 1}-$member',
                mother: random.nextBool()
                    ? 'g${rank - 1}-${(member + 1) % 3}'
                    : null,
              );
              final leaf = 'leaf-$rank-$member';
              family
                ..add(leaf)
                ..parents(leaf, father: 'g${rank - 1}-$member');
            }
          }
          return family;
        }

        for (var seed = 0; seed < 6; seed++) {
          // Birth edits must not alter generation compaction. Keep random edge
          // choices independent from the date/insertion perturbation below.
          final family = make(seed, false);
          final baseline = family.layout('g5-0');
          final reloaded = family.reload();
          final reordered = make(seed, true);
          _expectSameRanks(baseline, reordered.layout('g5-0'));
          for (final mode in TreeTrunkMode.values) {
            for (final selected in ['g0-0', 'g3-1', 'g5-0', 'leaf-5-2']) {
              final layout = family.layout(selected, mode);
              for (final link in layout.links) {
                expect(
                  layout.positions[link.childId]!.level -
                      layout.positions[link.parentId]!.level,
                  1,
                  reason: 'seed $seed: ${link.parentId}->${link.childId}',
                );
              }
              _expectSameRanks(baseline, layout);
              _expectSameRanks(
                layout,
                TreeLayout.build(reloaded, selectedId: selected, mode: mode),
              );
              _expectDescendingLinks(layout);
              _expectNoOverlap(layout);
            }
          }
        }
      },
    );

    test('compact cohort slack matches an exhaustive tiny-DAG oracle', () {
      final random = math.Random(74651);
      for (var sample = 0; sample < 16; sample++) {
        final family = _Family();
        final ids = [for (var i = 0; i < 6; i++) 'p$i'];
        for (final id in ids) {
          family.add(id);
        }
        for (var child = 1; child < ids.length; child++) {
          final father = random.nextInt(child);
          final mother = child > 1 && random.nextBool()
              ? random.nextInt(child)
              : null;
          family.parents(
            ids[child],
            father: ids[father],
            mother: mother == null || mother == father ? null : ids[mother],
          );
        }
        final layout = family.layout(ids.last);
        // The compactor receives the established equality quotient. Reconstruct
        // its sibling/accepted-couple equalities, then independently enumerate
        // bounded feasible integer layers rather than reusing closure logic.
        final group = {for (final id in ids) id: id};
        String root(String id) {
          while (group[id] != id) {
            id = group[id]!;
          }
          return id;
        }

        void unite(String a, String b) {
          group[root(b)] = root(a);
        }

        for (final row in layout.levels) {
          for (final block in row.blocks) {
            for (final person in block.people.skip(1)) {
              unite(block.people.first.id, person.id);
            }
          }
        }
        for (final person in family.document.people.values) {
          final a = person.fatherId;
          final b = person.motherId;
          if (a != null &&
              b != null &&
              layout.positions[a]!.level == layout.positions[b]!.level) {
            unite(a, b);
          }
        }
        final vertices = ids.map(root).toSet().toList();
        final edges = <(String, String)>{
          for (final link in layout.links)
            (root(link.parentId), root(link.childId)),
        };
        final actual = edges.fold<int>(
          0,
          (sum, edge) =>
              sum +
              layout.positions[edge.$2]!.level -
              layout.positions[edge.$1]!.level -
              1,
        );
        var optimum = 1000000;
        final assignment = <String, int>{};
        void enumerate(int index) {
          if (index == vertices.length) {
            if (edges.any(
              (edge) => assignment[edge.$2]! <= assignment[edge.$1]!,
            )) {
              return;
            }
            final cost = edges.fold<int>(
              0,
              (sum, edge) =>
                  sum + assignment[edge.$2]! - assignment[edge.$1]! - 1,
            );
            optimum = math.min(optimum, cost);
            return;
          }
          for (var rank = 0; rank < vertices.length; rank++) {
            assignment[vertices[index]] = rank;
            enumerate(index + 1);
          }
        }

        enumerate(0);
        expect(actual, optimum, reason: 'sample $sample / $edges');
        _expectDescendingLinks(layout);
      }
    });

    test('iterative cohort compaction handles a long branched pedigree', () {
      const depth = 160;
      final family = _Family()..add('branch-parent');
      for (var i = 0; i <= depth; i++) {
        family.add('chain-$i');
        if (i > 0) family.parents('chain-$i', father: 'chain-${i - 1}');
      }
      family
        ..add('join')
        ..parents('join', father: 'chain-$depth', mother: 'branch-parent')
        ..add('free-grandparent')
        ..parents('branch-parent', father: 'free-grandparent');
      for (var i = 0; i < 12; i++) {
        family
          ..add('collateral-$i')
          ..parents('collateral-$i', father: 'free-grandparent');
      }
      final layout = family.layout('join');
      expect(layout.positions['branch-parent']!.level, depth);
      expect(layout.positions['free-grandparent']!.level, depth - 1);
      for (var i = 0; i < 12; i++) {
        expect(layout.positions['collateral-$i']!.level, depth);
      }
      for (final link in layout.links) {
        expect(
          layout.positions[link.childId]!.level -
              layout.positions[link.parentId]!.level,
          1,
        );
      }
      _expectDescendingLinks(layout);
      _expectNoOverlap(layout);
    });

    test('unequal ancestry depths align co-parents at the deeper rank', () {
      final family = _Family()
        ..add('old')
        ..add('grandparent')
        ..add('parent')
        ..add('partner')
        ..add('child')
        ..parents('parent', father: 'grandparent')
        ..parents('partner', father: 'parent')
        ..parents('child', father: 'old', mother: 'partner');
      final layout = family.layout('child');

      expect(layout.positions['old']!.level, 2);
      expect(layout.positions['partner']!.level, 2);
      expect(layout.positions['child']!.level, 3);
      _expectDescendingLinks(layout);
      _expectNoOverlap(layout);
    });

    test(
      'partner ancestry moves full siblings and their descendants together',
      () {
        final family = _Family()
          ..add('father')
          ..add('mother')
          ..add('a')
          ..add('b')
          ..parents('a', father: 'father', mother: 'mother')
          ..parents('b', father: 'father', mother: 'mother')
          ..add('grandparent')
          ..add('parent')
          ..add('partner')
          ..parents('parent', father: 'grandparent')
          ..parents('partner', father: 'parent')
          ..add('a-child')
          ..add('b-child')
          ..parents('a-child', father: 'a', mother: 'partner')
          ..parents('b-child', father: 'b');
        final layout = family.layout('a-child');

        for (final id in ['a', 'b', 'partner']) {
          expect(layout.positions[id]!.level, 2);
        }
        expect(_blockFor(layout, 'a').id, _blockFor(layout, 'b').id);
        expect(layout.positions['a-child']!.level, 3);
        expect(layout.positions['b-child']!.level, 3);
        _expectDescendingLinks(layout);
        _expectNoOverlap(layout);
      },
    );

    test(
      'intergeneration unions use max parent rank and retain long links',
      () {
        final family = _Family()
          ..add('old')
          ..add('grandparent')
          ..add('parent')
          ..add('partner')
          ..add('child')
          ..parents('grandparent', father: 'old')
          ..parents('parent', father: 'grandparent')
          ..parents('partner', father: 'parent')
          ..parents('child', father: 'old', mother: 'partner');
        final layout = family.layout('child');

        expect(layout.positions['old']!.level, 0);
        expect(layout.positions['partner']!.level, 3);
        expect(layout.positions['child']!.level, 4);
        expect(
          layout.links.map((e) => '${e.parentId}->${e.childId}'),
          containsAll(['old->child', 'partner->child']),
        );
        for (final link in layout.links) {
          expect(link.blockId, layout.positions[link.childId]!.blockId);
          expect(
            layout.positions[link.parentId]!.level,
            lessThan(layout.positions[link.childId]!.level),
          );
        }
        _expectNoOverlap(layout);
      },
    );

    test('an uncle and niece union respects their full-sibling ancestry', () {
      final family = _Family()
        ..add('grandfather')
        ..add('grandmother')
        ..add('parent')
        ..add('uncle')
        ..add('child')
        ..parents('parent', father: 'grandfather', mother: 'grandmother')
        ..parents('uncle', father: 'grandfather', mother: 'grandmother')
        ..parents(rootTreePersonId, father: 'parent')
        ..parents('child', father: 'uncle', mother: rootTreePersonId);
      final layout = family.layout('child');

      // Neither co-parent is the other's ancestor in the original DAG. Their
      // equality would still flatten parent -> niece through the sibling block.
      expect(layout.positions['uncle']!.level, 1);
      expect(layout.positions['parent']!.level, 1);
      expect(layout.positions[rootTreePersonId]!.level, 2);
      expect(layout.positions['child']!.level, 3);
      expect(_blockFor(layout, 'uncle').id, _blockFor(layout, 'parent').id);
      _expectDescendingLinks(layout);
      _expectNoOverlap(layout);
    });

    test('a spouse chain never flattens a real parent edge', () {
      final family = _Family()
        ..add('a')
        ..add('b')
        ..add('c')
        ..add('first-child')
        ..add('second-child')
        ..parents('b', father: 'a')
        ..parents('first-child', father: 'a', mother: 'c')
        ..parents('second-child', father: 'b', mother: 'c');
      final layout = family.layout('second-child');

      expect(layout.positions['a']!.level, 0);
      expect(layout.positions['c']!.level, 0);
      expect(layout.positions['b']!.level, 1);
      expect(layout.positions['first-child']!.level, 1);
      expect(layout.positions['second-child']!.level, 2);
      _expectDescendingLinks(layout);
      _expectNoOverlap(layout);
    });

    test(
      'mutually conflicting unions use parent IDs, not child or focus order',
      () {
        _Family make(bool reverse) {
          final ids = ['a', 'b', 'c', 'd', 'union-a', 'union-z'];
          final family = _Family();
          for (final id in reverse ? ids.reversed : ids) {
            family.add(id);
          }
          family
            ..parents('b', father: 'a')
            ..parents('d', father: 'c')
            // Each couple is individually mergeable in the original DAG. Merging
            // both creates {a,d} -> {b,c} -> {a,d}; the first parent pair wins.
            ..parents('union-z', father: 'a', mother: 'd')
            ..parents('union-a', father: 'b', mother: 'c');
          if (reverse) {
            family
              ..birth('a', '2000-01-01')
              ..birth('c', '1900-01-01');
          }
          return family;
        }

        final family = make(false);
        final initial = family.layout('union-a');
        expect(initial.positions['c']!.level, 0);
        expect(initial.positions['a']!.level, 1);
        expect(initial.positions['d']!.level, 1);
        expect(initial.positions['b']!.level, 2);
        expect(initial.positions['union-z']!.level, 2);
        expect(initial.positions['union-a']!.level, 3);
        for (final mode in TreeTrunkMode.values) {
          var previous = initial;
          for (final id in family.document.people.keys) {
            final cold = make(true).layout(id, mode);
            _expectSameRanks(initial, cold);
            final current = family.layout(id, mode, previous);
            _expectSameRanks(initial, current);
            _expectDescendingLinks(current);
            _expectNoOverlap(current);
            previous = current;
          }
        }
        family
          ..add('00-new-child')
          ..parents('00-new-child', father: 'b', mother: 'c');
        final expanded = family.layout(
          '00-new-child',
          TreeTrunkMode.both,
          initial,
        );
        _expectSameRanks(initial, expanded);
        _expectDescendingLinks(expanded);
      },
    );

    test('long pedigree collapse retains genuine cross-generation unions', () {
      const depth = 32;
      final family = _Family()
        ..add('ancestor-father')
        ..add('ancestor-mother');
      var father = 'ancestor-father';
      var mother = 'ancestor-mother';
      for (var i = 0; i < depth; i++) {
        final nextFather = 'father-$i';
        final nextMother = 'mother-$i';
        family
          ..add(nextFather)
          ..add(nextMother)
          ..parents(nextFather, father: father, mother: mother)
          ..parents(nextMother, father: father, mother: mother);
        father = nextFather;
        mother = nextMother;
      }
      family
        ..add('child')
        ..parents('child', father: 'father-0', mother: mother);
      final initial = family.layout('child');
      expect(initial.positions['father-0']!.level, 1);
      expect(initial.positions[mother]!.level, depth);
      expect(initial.positions['child']!.level, depth + 1);
      expect(initial.positions, hasLength(2 * depth + 4));
      for (var i = 0; i < depth; i++) {
        expect(initial.positions['father-$i']!.level, i + 1);
        expect(initial.positions['mother-$i']!.level, i + 1);
      }
      for (final mode in TreeTrunkMode.values) {
        final current = family.layout('mother-0', mode, initial);
        _expectSameRanks(initial, current);
        _expectDescendingLinks(current);
        _expectNoOverlap(current);
      }
    });

    test('both trunk puts maternal left and paternal right on every rank', () {
      final family = _Family()
        ..add('maternal-grandfather')
        ..add('maternal-grandmother')
        ..add('paternal-grandfather')
        ..add('paternal-grandmother')
        ..add('mother')
        ..add('father')
        ..parents(
          'mother',
          father: 'maternal-grandfather',
          mother: 'maternal-grandmother',
        )
        ..parents(
          'father',
          father: 'paternal-grandfather',
          mother: 'paternal-grandmother',
        )
        ..parents(rootTreePersonId, father: 'father', mother: 'mother');
      final layout = family.layout(rootTreePersonId);

      for (final id in [
        'mother',
        'maternal-grandfather',
        'maternal-grandmother',
      ]) {
        expect(layout.positions[id]!.crossCenter, lessThan(0));
        expect(layout.positions[id]!.branch, TreeBranch.maternal);
      }
      for (final id in [
        'father',
        'paternal-grandfather',
        'paternal-grandmother',
      ]) {
        expect(layout.positions[id]!.crossCenter, greaterThan(0));
        expect(layout.positions[id]!.branch, TreeBranch.paternal);
      }
      expect(layout.positions[rootTreePersonId]!.crossCenter, 0);
      expect(layout.trunkIds, family.document.people.keys.toSet());
      _expectNoOverlap(layout);
    });

    test(
      'common-descendant roles keep Valentina right in every mode and focus',
      () {
        for (final dates in [
          'unknown',
          'equal',
          'paternal-first',
          'maternal-first',
        ]) {
          for (final reverseInsertion in [false, true]) {
            final family = _branchSideFamily(dates, reverseInsertion);
            final people = family.document.people;
            final initial = family.layout('nikita');
            for (final mode in TreeTrunkMode.values) {
              for (final selected in people.keys) {
                final layout = family.layout(selected, mode, initial);
                final reason = '$dates / $reverseInsertion / $mode / $selected';
                _expectBefore(layout, 'lydia', 'gennady', reason);
                _expectBefore(layout, 'gennady', 'valentina', reason);
                _expectBefore(layout, 'veronika', 'roman', reason);
                _expectBefore(layout, 'natalia', 'oleg', reason);
                _expectBefore(layout, 'natalia', 'nekto', reason);
                expect(
                  _blockFor(layout, 'natalia').id,
                  _blockFor(layout, 'veronika').id,
                );
                if (mode == TreeTrunkMode.both) {
                  final person = people[selected]!;
                  if (person.motherId != null && person.fatherId != null) {
                    _expectParentCardsAdjacent(
                      layout,
                      person.motherId!,
                      person.fatherId!,
                    );
                  }
                }
                _expectSameRanks(initial, layout);
                expect(
                  layout.links.map((e) => (e.parentId, e.childId, e.blockId)),
                  initial.links.map((e) => (e.parentId, e.childId, e.blockId)),
                );
                expect(
                  _snapshot(layout),
                  _snapshot(family.layout(selected, mode)),
                );
                _expectDescendingLinks(layout);
                _expectNoOverlap(layout);
              }
            }
            expect(identical(family.document.people, people), isTrue);
            for (final mode in TreeTrunkMode.values) {
              final reversed = _branchSideFamily(dates, !reverseInsertion);
              expect(
                _snapshot(family.layout('nikita', mode)),
                _snapshot(reversed.layout('nikita', mode)),
              );
            }
          }
        }
      },
    );

    test(
      'selected co-parent proximity moves whole sibling blocks, never members',
      () {
        for (final dates in [
          'unknown',
          'equal',
          'natalia-first',
          'veronika-first',
        ]) {
          _Family make(bool reverse) {
            final family = _cousinFamily(
              reverseInsertion: reverse,
              anastasiaFather: true,
            );
            if (dates != 'unknown') {
              family
                ..birth(
                  'natalia',
                  dates == 'veronika-first' ? '1970-01-01' : '1960-01-01',
                )
                ..birth(
                  'veronika',
                  dates == 'natalia-first' ? '1970-01-01' : '1960-01-01',
                );
            }
            return family;
          }

          for (final reverse in [false, true]) {
            final family = make(reverse);
            final people = family.document.people;
            final events = family.events.toList();
            final chronology = dates == 'veronika-first'
                ? ['veronika', 'natalia']
                : ['natalia', 'veronika'];
            final context = family.layout('lydia');
            var previous = family.layout(rootTreePersonId);
            var movedBlocks = false;
            for (final selected in [
              'natalia',
              'nekto',
              'roman',
              'veronika',
              'natalia',
            ]) {
              final layout = family.layout(
                selected,
                TreeTrunkMode.both,
                previous,
              );
              final block = _blockFor(layout, 'natalia');
              expect(
                block.people.map((p) => p.id),
                chronology,
                reason: '$dates / $reverse / $selected',
              );
              expect(block.id, _blockFor(context, 'natalia').id);
              expect(block.extent, _blockFor(context, 'natalia').extent);
              _expectConsecutive(
                layout,
                selected == 'roman' || selected == 'veronika'
                    ? ['veronika', 'roman']
                    : selected == 'nekto'
                    ? ['natalia', 'nekto']
                    : ['natalia', 'oleg', 'nekto'],
              );
              movedBlocks |=
                  _rowPeople(layout, 'natalia').join(',') !=
                  _rowPeople(context, 'natalia').join(',');
              expect(_snapshot(layout), _snapshot(family.layout(selected)));
              expect(
                _snapshot(layout),
                _snapshot(make(!reverse).layout(selected)),
              );
              _expectSameRanks(context, layout);
              expect(
                layout.links.map((e) => (e.parentId, e.childId, e.blockId)),
                context.links.map((e) => (e.parentId, e.childId, e.blockId)),
              );
              _expectDescendingLinks(layout);
              _expectNoOverlap(layout);
              previous = layout;
            }
            expect(movedBlocks, isTrue);
            expect(identical(family.document.people, people), isTrue);
            expect(family.events, events);
          }
        }
      },
    );

    test(
      'common-descendant roles never reorder members of a full-sibling block',
      () {
        for (final date in [null, '1960-01-01', 'chronological']) {
          _Family make(bool reverse) {
            final family = _Family();
            final ids = [
              'grandfather',
              'grandmother',
              'a-older',
              'm-middle',
              'z-younger',
              'maternal-path',
              'paternal-path',
              'join',
            ];
            for (final id in reverse ? ids.reversed : ids) {
              family.add(id);
            }
            for (final (i, id) in [
              'a-older',
              'm-middle',
              'z-younger',
            ].indexed) {
              family.parents(id, father: 'grandfather', mother: 'grandmother');
              if (date != null) {
                family.birth(
                  id,
                  date == 'chronological' ? '${1960 + i * 5}-01-01' : date,
                );
              }
            }
            return family
              ..parents('maternal-path', father: 'z-younger')
              ..parents('paternal-path', mother: 'a-older')
              ..parents(
                'join',
                mother: 'maternal-path',
                father: 'paternal-path',
              );
          }

          final family = make(false);
          var previous = family.layout('join');
          for (final mode in TreeTrunkMode.values) {
            for (final selected in family.document.people.keys) {
              final layout = family.layout(selected, mode, previous);
              expect(_blockFor(layout, 'a-older').people.map((p) => p.id), [
                'a-older',
                'm-middle',
                'z-younger',
              ]);
              _expectBefore(layout, 'maternal-path', 'paternal-path');
              expect(
                _snapshot(layout),
                _snapshot(make(true).layout(selected, mode)),
              );
              expect(
                _snapshot(layout),
                _snapshot(family.layout(selected, mode)),
              );
              _expectSameRanks(previous, layout);
              _expectDescendingLinks(layout);
              _expectNoOverlap(layout);
              previous = layout;
            }
          }
        }
      },
    );

    test(
      'single modes keep sibling co-parents in canonical birth and ID order',
      () {
        for (final date in [null, '1980-01-01', 'father-first']) {
          final family = _Family()
            ..add('grandfather')
            ..add('grandmother');
          for (final (i, id) in ['a-father', 'm-sibling', 'z-mother'].indexed) {
            family
              ..add(id)
              ..parents(id, father: 'grandfather', mother: 'grandmother');
            if (date != null) {
              family.birth(
                id,
                date == 'father-first' ? '${1980 + i * 5}-01-01' : date,
              );
            }
          }
          family.parents(
            rootTreePersonId,
            mother: 'z-mother',
            father: 'a-father',
          );
          var previous = family.layout(rootTreePersonId);
          for (final mode in [TreeTrunkMode.father, TreeTrunkMode.mother]) {
            for (final selected in family.document.people.keys) {
              final layout = family.layout(selected, mode, previous);
              expect(_blockFor(layout, 'a-father').people.map((p) => p.id), [
                'a-father',
                'm-sibling',
                'z-mother',
              ]);
              expect(
                _snapshot(layout),
                _snapshot(family.layout(selected, mode)),
              );
              _expectSameRanks(previous, layout);
              _expectDescendingLinks(layout);
              _expectNoOverlap(layout);
              previous = layout;
            }
          }
        }
      },
    );

    test(
      'both mode exposes actual parent seams at multiple ancestral levels only',
      () {
        for (final date in [null, '1950-01-01', 'father-first']) {
          _Family make(bool reverse) {
            final family = _Family();
            final ids = [
              'oldest-father',
              'oldest-mother',
              for (final prefix in ['grand', 'parent']) ...[
                '$prefix-a-father',
                '$prefix-m-sibling',
                '$prefix-z-mother',
              ],
              'child',
              'descendant',
              'partner',
              'shared-child',
            ];
            for (final id in reverse ? ids.reversed : ids) {
              family.add(id);
            }
            for (final (depth, prefix) in ['grand', 'parent'].indexed) {
              for (final (i, suffix) in [
                'a-father',
                'm-sibling',
                'z-mother',
              ].indexed) {
                final id = '$prefix-$suffix';
                family.parents(
                  id,
                  father: depth == 0 ? 'oldest-father' : 'grand-a-father',
                  mother: depth == 0 ? 'oldest-mother' : 'grand-z-mother',
                );
                if (date != null) {
                  family.birth(
                    id,
                    date == 'father-first'
                        ? '${1930 + depth * 25 + i * 5}-01-01'
                        : date,
                  );
                }
              }
            }
            return family
              ..parents(
                'child',
                father: 'parent-a-father',
                mother: 'parent-z-mother',
              )
              ..parents('descendant', father: 'child')
              ..parents(
                'shared-child',
                father: 'descendant',
                mother: 'partner',
              );
          }

          final family = make(false);
          final people = family.document.people;
          final events = family.events.toList();
          var previous = family.layout(
            'parent-m-sibling',
            TreeTrunkMode.father,
          );
          for (final mode in TreeTrunkMode.values) {
            for (final selected in [
              'descendant',
              'partner',
              'shared-child',
              'child',
              'descendant',
            ]) {
              final layout = family.layout(selected, mode, previous);
              for (final prefix in ['grand', 'parent']) {
                final seam =
                    mode == TreeTrunkMode.both && selected != 'partner';
                expect(
                  _blockFor(layout, '$prefix-a-father').people.map((p) => p.id),
                  seam
                      ? [
                          '$prefix-z-mother',
                          '$prefix-a-father',
                          '$prefix-m-sibling',
                        ]
                      : [
                          '$prefix-a-father',
                          '$prefix-m-sibling',
                          '$prefix-z-mother',
                        ],
                  reason: '$date / $mode / $selected / $prefix',
                );
                if (seam) {
                  _expectParentCardsAdjacent(
                    layout,
                    '$prefix-z-mother',
                    '$prefix-a-father',
                  );
                }
                expect(
                  _blockFor(layout, '$prefix-a-father').id,
                  _blockFor(previous, '$prefix-a-father').id,
                );
              }
              expect(
                _snapshot(layout),
                _snapshot(make(true).layout(selected, mode)),
              );
              expect(
                _snapshot(layout),
                _snapshot(family.layout(selected, mode)),
              );
              _expectSameRanks(previous, layout);
              expect(
                layout.links.map((e) => (e.parentId, e.childId, e.blockId)),
                previous.links.map((e) => (e.parentId, e.childId, e.blockId)),
              );
              _expectDescendingLinks(layout);
              _expectNoOverlap(layout);
              previous = layout;
            }
          }
          expect(identical(family.document.people, people), isTrue);
          expect(family.events, events);
        }
      },
    );

    test(
      'both mode exposes ancestral block boundaries without moving co-parent members',
      () {
        final family = _Family();
        for (final id in [
          'oldest-father',
          'oldest-mother',
          'grandmother',
          'grandaunt',
          'grandfather',
          'mother',
          'aunt',
          'father',
          'partner-father',
          'partner-mother',
          'partner',
          'partner-sister',
          'shared-child',
        ]) {
          family.add(id);
        }
        for (final id in ['grandmother', 'grandaunt']) {
          family.parents(id, father: 'oldest-father', mother: 'oldest-mother');
        }
        for (final id in ['mother', 'aunt']) {
          family.parents(id, father: 'grandfather', mother: 'grandmother');
        }
        for (final id in ['partner', 'partner-sister']) {
          family.parents(
            id,
            father: 'partner-father',
            mother: 'partner-mother',
          );
        }
        family
          ..birth('grandmother', '1920-01-01')
          ..birth('grandaunt', '1925-01-01')
          ..birth('mother', '1950-01-01')
          ..birth('aunt', '1955-01-01')
          ..birth('partner', '1980-01-01')
          ..birth('partner-sister', '1985-01-01')
          ..parents(rootTreePersonId, father: 'father', mother: 'mother')
          ..parents(
            'shared-child',
            father: rootTreePersonId,
            mother: 'partner',
          );
        final people = family.document.people;
        var previous = family.layout(rootTreePersonId);
        for (final mode in TreeTrunkMode.values) {
          for (final selected in [
            rootTreePersonId,
            'partner',
            'shared-child',
            rootTreePersonId,
          ]) {
            final layout = family.layout(selected, mode, previous);
            final ancestrySeam =
                mode == TreeTrunkMode.both && selected != 'partner';
            expect(
              _blockFor(layout, 'mother').people.map((p) => p.id),
              ancestrySeam ? ['aunt', 'mother'] : ['mother', 'aunt'],
            );
            expect(
              _blockFor(layout, 'grandmother').people.map((p) => p.id),
              ancestrySeam
                  ? ['grandaunt', 'grandmother']
                  : ['grandmother', 'grandaunt'],
            );
            expect(
              _blockFor(layout, 'partner').people.map((p) => p.id),
              mode == TreeTrunkMode.both && selected == 'shared-child'
                  ? ['partner-sister', 'partner']
                  : ['partner', 'partner-sister'],
            );
            if (ancestrySeam) {
              _expectParentCardsAdjacent(layout, 'mother', 'father');
              _expectParentCardsAdjacent(layout, 'grandmother', 'grandfather');
            }
            if (mode == TreeTrunkMode.both && selected == 'shared-child') {
              _expectParentCardsAdjacent(layout, 'partner', rootTreePersonId);
            } else if (mode == TreeTrunkMode.both) {
              _expectConsecutive(layout, ['partner', rootTreePersonId]);
            }
            expect(_snapshot(layout), _snapshot(family.layout(selected, mode)));
            _expectSameRanks(previous, layout);
            expect(
              layout.links.map((e) => (e.parentId, e.childId, e.blockId)),
              previous.links.map((e) => (e.parentId, e.childId, e.blockId)),
            );
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
            previous = layout;
          }
        }
        expect(identical(family.document.people, people), isTrue);
      },
    );

    test(
      'both ancestor corridors exclude maternal, paternal and neutral context on every rank',
      () {
        for (final reverse in [false, true]) {
          final family = _ancestorCorridorFamily(reverse);
          final initial = family.layout('nikita');
          final people = family.document.people;
          final events = family.events.toList();
          var previous = initial;
          for (final selected in [
            'nikita',
            'olga',
            'nikita',
            'roman',
            'nikita',
          ]) {
            final layout = family.layout(
              selected,
              TreeTrunkMode.both,
              previous,
            );
            _expectAncestorCorridors(layout);
            if (selected == 'nikita') {
              for (final (context, ancestor) in [
                ('oleg-mother', 'lydia'),
                ('oleg-father', 'lydia'),
                ('oleg-great', 'maternal-great'),
              ]) {
                expect(layout.positions[context]!.branch, TreeBranch.maternal);
                _expectBefore(layout, context, ancestor);
              }
              for (final (ancestor, context) in [
                ('valentina', 'paternal-context'),
                ('paternal-great', 'paternal-context-great'),
              ]) {
                expect(layout.positions[context]!.branch, TreeBranch.paternal);
                _expectBefore(layout, ancestor, context);
              }
              expect(layout.positions['neutral']!.branch, TreeBranch.neutral);
              _expectParentCardsAdjacent(layout, 'lydia', 'gennady');
              _expectParentCardsAdjacent(layout, 'veronika', 'roman');
              expect(_blockFor(layout, 'veronika').people.map((p) => p.id), [
                'prikol',
                'natalia',
                'veronika',
              ]);
              expect(_snapshot(layout), _snapshot(initial));
            }
            expect(
              _snapshot(layout),
              _snapshot(_ancestorCorridorFamily(!reverse).layout(selected)),
            );
            expect(_snapshot(layout), _snapshot(family.layout(selected)));
            _expectSameRanks(initial, layout);
            expect(
              layout.links.map((e) => (e.parentId, e.childId, e.blockId)),
              initial.links.map((e) => (e.parentId, e.childId, e.blockId)),
            );
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
            previous = layout;
          }
          expect(identical(family.document.people, people), isTrue);
          expect(family.events, events);
        }
      },
    );

    test(
      'shared pedigree ancestor blocks stay whole inside the both corridor',
      () {
        final family = _ancestorCorridorFamily(false)
          ..add('shared', name: 'b shared')
          ..add('shared-sibling', name: 'a shared sibling')
          ..add('shared-father')
          ..add('shared-mother')
          ..parents('shared', father: 'shared-father', mother: 'shared-mother')
          ..parents(
            'shared-sibling',
            father: 'shared-father',
            mother: 'shared-mother',
          )
          ..parents('lydia', father: 'shared')
          ..parents('valentina', father: 'shared');
        final initial = family.layout('nikita');
        expect(initial.positions['shared']!.branch, TreeBranch.both);
        expect(_blockFor(initial, 'shared').people.map((p) => p.id), [
          'shared-sibling',
          'shared',
        ]);
        _expectAncestorCorridors(initial);
        var previous = initial;
        for (final mode in TreeTrunkMode.values) {
          for (final selected in ['lydia', 'nikita', 'roman', 'nikita']) {
            final layout = family.layout(selected, mode, previous);
            if (mode == TreeTrunkMode.both) _expectAncestorCorridors(layout);
            expect(_blockFor(layout, 'shared').people.map((p) => p.id), [
              'shared-sibling',
              'shared',
            ]);
            expect(_snapshot(layout), _snapshot(family.layout(selected, mode)));
            _expectSameRanks(initial, layout);
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
            previous = layout;
          }
        }
      },
    );

    test(
      'neutral corridor intruders use nearer edges with a stable left tie and exterior context unchanged',
      () {
        _Family make(bool reverse) {
          final family = _Family();
          final people = [
            ('outside-left', 'a outside'),
            ('left', 'b ancestor'),
            ('near-left', 'c context'),
            ('tie', 'd context'),
            ('near-right', 'e context'),
            ('right', 'f ancestor'),
            ('outside-right', 'g outside'),
            ('mother', 'mother'),
            ('father', 'father'),
            ('selected', 'selected'),
          ];
          for (final (id, name) in reverse ? people.reversed : people) {
            family.add(id, name: name);
          }
          family._apply(
            family.document.editText(
              rootTreePersonId,
              TreeTextField.name,
              'z root',
            )!,
          );
          return family
            ..parents('mother', father: 'left')
            ..parents('father', father: 'right')
            ..parents('selected', mother: 'mother', father: 'father');
        }

        final family = make(false);
        final singles = [
          'outside-left',
          'left',
          'near-left',
          'tie',
          'near-right',
          'right',
          'outside-right',
          rootTreePersonId,
        ];
        final both = [
          'outside-left',
          'near-left',
          'tie',
          'left',
          'right',
          'near-right',
          'outside-right',
          rootTreePersonId,
        ];
        var previous = family.layout('selected');
        for (final mode in TreeTrunkMode.values) {
          for (final selected in ['selected', 'mother', 'selected']) {
            final layout = family.layout(selected, mode, previous);
            expect(
              _rowPeople(layout, 'left'),
              mode == TreeTrunkMode.both && selected == 'selected'
                  ? both
                  : singles,
            );
            for (final id in ['near-left', 'tie', 'near-right']) {
              expect(layout.positions[id]!.branch, TreeBranch.neutral);
            }
            if (mode == TreeTrunkMode.both) _expectAncestorCorridors(layout);
            expect(
              _snapshot(layout),
              _snapshot(make(true).layout(selected, mode)),
            );
            expect(_snapshot(layout), _snapshot(family.layout(selected, mode)));
            _expectSameRanks(previous, layout);
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
            previous = layout;
          }
        }
      },
    );

    test(
      'both descendant corridors keep Natalia children together outside nephew context',
      () {
        for (final reverse in [false, true]) {
          final family = _descendantCorridorFamily(reverse);
          final initial = family.layout('natalia');
          final people = family.document.people;
          final events = family.events.toList();
          var previous = family.layout('nikita');
          for (final mode in TreeTrunkMode.values) {
            for (final selected in [
              'natalia',
              'veronika',
              'natalia',
              'nikita',
              'natalia',
            ]) {
              final layout = family.layout(selected, mode, previous);
              if (mode == TreeTrunkMode.both) {
                _expectDescendantCorridors(layout, family.document);
                _expectAncestorCorridors(layout);
              }
              if (selected == 'natalia') {
                expect(
                  _rowPeople(layout, rootTreePersonId),
                  mode == TreeTrunkMode.both
                      ? ['nikita', 'anastasia', rootTreePersonId]
                      : ['anastasia', rootTreePersonId, 'nikita'],
                );
                expect(
                  layout.positions['nikita']!.emphasis,
                  TreeEmphasis.cousin,
                );
                expect(layout.positions['nikita']!.branch, TreeBranch.both);
              }
              expect(
                _snapshot(layout),
                _snapshot(family.layout(selected, mode)),
              );
              expect(
                _snapshot(layout),
                _snapshot(
                  _descendantCorridorFamily(!reverse).layout(selected, mode),
                ),
              );
              _expectSameRanks(initial, layout);
              expect(
                layout.links.map((e) => (e.parentId, e.childId, e.blockId)),
                initial.links.map((e) => (e.parentId, e.childId, e.blockId)),
              );
              _expectDescendingLinks(layout);
              _expectNoOverlap(layout);
              previous = layout;
            }
          }
          expect(identical(family.document.people, people), isTrue);
          expect(family.events, events);
        }
      },
    );

    test(
      'a right-side full sister keeps her nephew outside the descendant corridor on the right',
      () {
        final family = _descendantCorridorFamily(false, sisterOnRight: true);
        final initial = family.layout('natalia');
        expect(_blockFor(initial, 'natalia').people.map((p) => p.id), [
          'natalia',
          'veronika',
        ]);
        expect(_rowPeople(initial, rootTreePersonId), [
          'anastasia',
          rootTreePersonId,
          'nikita',
        ]);
        expect(initial.positions['nikita']!.branch, TreeBranch.both);
        _expectDescendantCorridors(initial, family.document);
        for (final selected in ['veronika', 'nikita', 'natalia']) {
          final prior = family.layout(selected);
          final roundTrip = family.layout('natalia', TreeTrunkMode.both, prior);
          expect(_snapshot(roundTrip), _snapshot(initial));
          _expectSameRanks(initial, prior);
          _expectDescendingLinks(prior);
          _expectNoOverlap(prior);
        }
        expect(
          _snapshot(initial),
          _snapshot(
            _descendantCorridorFamily(
              true,
              sisterOnRight: true,
            ).layout('natalia'),
          ),
        );
      },
    );

    test(
      'deeper descendant corridors preserve full siblings and shared descendants',
      () {
        final family = _descendantCorridorFamily(false);
        for (final (id, name) in [
          ('olga-partner', 'Olga partner'),
          ('anastasia-partner', 'Anastasia partner'),
          ('nikita-partner', 'Nikita partner'),
          ('a-grandchild', 'a grandchild'),
          ('b-grandchild-sibling', 'b grandchild'),
          ('m-collateral', 'm collateral'),
          ('z-grandchild', 'z grandchild'),
          ('shared-descendant', 'shared descendant'),
          ('shared-collateral', 'shared collateral'),
        ]) {
          family.add(id, name: name);
        }
        family
          ..parents(
            'a-grandchild',
            mother: 'anastasia',
            father: 'anastasia-partner',
          )
          ..parents(
            'b-grandchild-sibling',
            mother: 'anastasia',
            father: 'anastasia-partner',
          )
          ..parents('m-collateral', mother: 'nikita-partner', father: 'nikita')
          ..parents(
            'z-grandchild',
            mother: rootTreePersonId,
            father: 'olga-partner',
          )
          ..parents(
            'shared-descendant',
            mother: 'a-grandchild',
            father: 'm-collateral',
          )
          ..parents('shared-collateral', father: 'm-collateral');
        final initial = family.layout('natalia');
        _expectDescendantCorridors(initial, family.document);
        expect(_blockFor(initial, 'a-grandchild').people.map((p) => p.id), [
          'a-grandchild',
          'b-grandchild-sibling',
        ]);
        _expectConsecutive(initial, ['a-grandchild', 'z-grandchild']);
        expect(
          initial.positions['shared-descendant']!.emphasis,
          TreeEmphasis.normal,
        );
        var previous = initial;
        for (final mode in TreeTrunkMode.values) {
          for (final selected in [
            'natalia',
            'nikita',
            'anastasia',
            'natalia',
          ]) {
            final layout = family.layout(selected, mode, previous);
            if (mode == TreeTrunkMode.both) {
              _expectDescendantCorridors(layout, family.document);
              _expectAncestorCorridors(layout);
            }
            expect(_blockFor(layout, 'a-grandchild').people.map((p) => p.id), [
              'a-grandchild',
              'b-grandchild-sibling',
            ]);
            expect(_snapshot(layout), _snapshot(family.layout(selected, mode)));
            _expectSameRanks(initial, layout);
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
            previous = layout;
          }
        }
      },
    );

    test(
      'every common-parent child cohort survives focus modes dates names and parent-role swaps',
      () {
        for (final swapped in [false, true]) {
          for (final reverse in [false, true]) {
            for (final variant in ['undated', 'equal', 'adverse', 'names']) {
              _Family make(bool reverseInsertion) {
                final family = _descendantCorridorFamily(reverseInsertion);
                if (variant == 'undated') {
                  family._apply(
                    family.document.setValue('natalia', 'birthDate', null),
                  );
                } else if (variant == 'equal') {
                  for (final id in [
                    'natalia',
                    'veronika',
                    'nekto',
                    'oleg',
                    'roman',
                  ]) {
                    family.birth(id, '1970-01-01');
                  }
                }
                if (variant == 'names') {
                  for (final (id, name) in [
                    ('natalia', 'Я общий родитель'),
                    ('nekto', 'А второй родитель'),
                    (rootTreePersonId, 'А ребёнок'),
                    ('nikita', 'М кузен'),
                    ('anastasia', 'Я ребёнок'),
                  ]) {
                    family._apply(
                      family.document.editText(id, TreeTextField.name, name)!,
                    );
                  }
                }
                if (swapped) {
                  for (final id in [rootTreePersonId, 'anastasia', 'nikita']) {
                    final person = family.document.people[id]!;
                    family.parents(
                      id,
                      father: person.motherId!,
                      mother: person.fatherId!,
                    );
                  }
                }
                family
                  ..sex('natalia', swapped ? TreeSex.male : TreeSex.female)
                  ..sex('nekto', swapped ? TreeSex.female : TreeSex.male);
                return family;
              }

              final family = make(reverse);
              final initial = family.layout('nikita');
              final people = family.document.people;
              final events = family.events.toList();
              var previous = initial;
              for (final mode in TreeTrunkMode.values) {
                for (final selected in [
                  'nikita',
                  'natalia',
                  'veronika',
                  'roman',
                  rootTreePersonId,
                  'anastasia',
                  'nikita',
                ]) {
                  final layout = family.layout(selected, mode, previous);
                  _expectConsecutive(layout, ['anastasia', rootTreePersonId]);
                  expect(
                    layout.positions['anastasia']!.blockId,
                    isNot(layout.positions[rootTreePersonId]!.blockId),
                  );
                  expect(
                    _snapshot(layout),
                    _snapshot(make(!reverse).layout(selected, mode)),
                  );
                  expect(
                    _snapshot(layout),
                    _snapshot(family.layout(selected, mode)),
                  );
                  _expectSameRanks(initial, layout);
                  expect(
                    layout.links.map((e) => (e.parentId, e.childId, e.blockId)),
                    initial.links.map(
                      (e) => (e.parentId, e.childId, e.blockId),
                    ),
                  );
                  _expectDescendingLinks(layout);
                  _expectNoOverlap(layout);
                  previous = layout;
                }
              }
              expect(identical(family.document.people, people), isTrue);
              expect(family.events, events);
            }
          }
        }
      },
    );

    test(
      'compatible overlapping parent stars match a tiny permutation oracle',
      () {
        final graphs = <List<(String, String?)>>[
          [('a', 'b'), ('b', 'c')],
          [
            ('c', null),
            ('a', null),
            ('a', 'b'),
            ('b', 'c'),
            ('b', null),
            ('c', null),
          ],
          [('a', 'b'), ('b', 'a'), ('b', 'c'), ('c', null)],
          [('a', 'a'), ('a', 'b'), ('b', null)],
          [('a', 'b'), ('b', 'c'), ('c', 'd')],
          [('a', 'b'), ('b', 'c'), ('b', 'd'), ('c', 'e')],
          [('a', 'b'), ('a', 'c'), ('a', 'd'), ('d', 'e')],
          [('a', 'b'), ('b', 'c'), ('c', 'a')],
          [
            ('a', 'b'),
            ('a', 'c'),
            ('a', 'd'),
            ('b', 'e'),
            ('c', 'f'),
            ('d', 'g'),
          ],
        ];
        for (final (sample, graph) in graphs.indexed) {
          final groups = <String, Set<String>>{};
          for (final (i, pair) in graph.indexed) {
            (groups[pair.$1] ??= {}).add('child-$i');
            if (pair.$2 case final parent?) {
              (groups[parent] ??= {}).add('child-$i');
            }
          }
          bool contiguous(List<String> order) => groups.values.every((group) {
            final slots = [
              for (var i = 0; i < order.length; i++)
                if (group.contains(order[i])) i,
            ];
            return slots.length < 2 ||
                slots.last - slots.first + 1 == slots.length;
          });
          var feasible = false;
          void enumerate(List<String> order, List<String> remaining) {
            if (feasible) return;
            if (remaining.isEmpty) {
              feasible = contiguous(order);
              return;
            }
            for (final id in remaining) {
              enumerate([...order, id], remaining.toList()..remove(id));
            }
          }

          final children = [for (var i = 0; i < graph.length; i++) 'child-$i'];
          enumerate([], children);
          final forward = <TreeTrunkMode, List<Object?>>{};
          for (final reverse in [false, true]) {
            final family = _Family();
            final parents = groups.keys.toList()..sort();
            for (final id in reverse ? parents.reversed : parents) {
              family.add(id);
            }
            final indexed = graph.indexed.toList();
            for (final (i, pair) in reverse ? indexed.reversed : indexed) {
              final id = 'child-$i';
              family
                ..add(id, name: '${graph.length - i} name')
                ..parents(id, father: pair.$1, mother: pair.$2);
            }
            for (final mode in TreeTrunkMode.values) {
              // Parentless focus gives no actual-ancestor seams or corridor locks.
              final layout = family.layout(rootTreePersonId, mode);
              if (reverse) {
                expect(_snapshot(layout), forward[mode]);
              } else {
                forward[mode] = _snapshot(layout);
              }
              final row = _rowPeople(layout, 'child-0');
              final actualGroups = <String, Set<String>>{};
              for (final id in children) {
                final person = family.document.people[id]!;
                for (final parent in {
                  person.fatherId,
                  person.motherId,
                }.nonNulls) {
                  (actualGroups[parent] ??= {}).add(id);
                }
              }
              if (feasible) {
                for (final group in actualGroups.values.where(
                  (group) => group.length > 1,
                )) {
                  _expectConsecutive(layout, group.toList());
                }
              }
              expect(row.toSet(), children.toSet(), reason: 'sample $sample');
              expect(
                _snapshot(layout),
                _snapshot(family.layout(rootTreePersonId, mode, layout)),
              );
              _expectDescendingLinks(layout);
              _expectNoOverlap(layout);
            }
          }
        }
      },
    );

    test(
      'a feasible parent component stays complete beside an impossible parent cycle',
      () {
        final family = _Family();
        for (final id in ['a', 'b', 'c', 'x', 'y', 'z']) {
          family.add(id);
        }
        for (final (id, father, mother) in [
          ('1-c-only', 'c', null),
          ('2-xy', 'x', 'y'),
          ('3-a-only', 'a', null),
          ('4-ab', 'a', 'b'),
          ('5-yz', 'y', 'z'),
          ('6-bc', 'b', 'c'),
          ('7-b-only', 'b', null),
          ('8-zx', 'z', 'x'),
          ('9-c-only', 'c', null),
        ]) {
          family
            ..add(id)
            ..parents(id, father: father, mother: mother);
        }
        for (final mode in TreeTrunkMode.values) {
          final layout = family.layout(rootTreePersonId, mode);
          for (final parent in ['a', 'b', 'c']) {
            final children = family.document.people.values
                .where(
                  (person) =>
                      person.fatherId == parent || person.motherId == parent,
                )
                .map((person) => person.id)
                .toList();
            _expectConsecutive(layout, children);
          }
          expect(
            _snapshot(layout),
            _snapshot(family.layout(rootTreePersonId, mode, layout)),
          );
          _expectDescendingLinks(layout);
          _expectNoOverlap(layout);
        }
      },
    );

    test(
      'neutral exterior context cannot use a sole ancestor to veto a common-parent cohort',
      () {
        final family = _Family()
          ..add('shared-parent')
          ..birth('shared-parent', '1970-01-01')
          ..add('before-father')
          ..add('after-father')
          ..add('before', name: 'a before')
          ..add('ancestor', name: 'b ancestor')
          ..add('after', name: 'c after')
          ..add('selected')
          ..parents('before', father: 'before-father', mother: 'shared-parent')
          ..parents('after', father: 'after-father', mother: 'shared-parent')
          ..parents('selected', father: 'ancestor');
        // Give the sole ancestor the same rank as the shared-parent children.
        family.parents('ancestor', father: rootTreePersonId);
        final initial = family.layout('selected');
        expect(initial.positions['before']!.branch, TreeBranch.neutral);
        expect(initial.positions['after']!.branch, TreeBranch.neutral);
        for (final mode in TreeTrunkMode.values) {
          for (final selected in [
            'selected',
            'ancestor',
            rootTreePersonId,
            'selected',
          ]) {
            final layout = family.layout(selected, mode, initial);
            _expectConsecutive(layout, ['before', 'after']);
            expect(_snapshot(layout), _snapshot(family.layout(selected, mode)));
            _expectSameRanks(initial, layout);
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
          }
        }
      },
    );

    test(
      'explicit rootless sibling components are indivisible ranked blocks without ancestry links',
      () {
        final family = _Family()
          ..add('a', name: 'Яна')
          ..add('unrelated', name: 'Ада');
        family
          .._apply(family.document.createSibling('a', 'b', name: ' Борис '))
          .._apply(family.document.createSibling('b', 'c', name: 'Анна'))
          ..birth('a', '1900-01-01')
          ..birth('c', '1900-01-01');
        final people = family.document.people;
        final events = family.events.toList();
        final group = family.document.siblingGroupIds['a']!;
        expect(group, startsWith('siblings:'));
        var previous = family.layout('a');
        for (final mode in TreeTrunkMode.values) {
          for (final selected in ['a', 'b', 'c', 'unrelated', 'a']) {
            final layout = family.layout(selected, mode, previous);
            final block = _blockFor(layout, 'a');
            expect(block.id, group);
            expect(block.people.map((person) => person.id), ['b', 'c', 'a']);
            expect(block.fatherId, isNull);
            expect(block.motherId, isNull);
            expect(block.extent, 3 * 96 + 2 * 24);
            for (final id in ['a', 'b', 'c']) {
              expect(layout.positions[id]!.level, 0);
              expect(_blockFor(layout, id).id, group);
              if (selected != 'unrelated') {
                expect(layout.positions[id]!.emphasis, TreeEmphasis.normal);
              }
            }
            expect(_blockFor(layout, 'unrelated').id, isNot(group));
            expect(layout.links, isEmpty);
            expect(_snapshot(layout), _snapshot(family.layout(selected, mode)));
            expect(
              _snapshot(layout),
              _snapshot(
                TreeLayout.build(
                  family.reload(),
                  selectedId: selected,
                  mode: mode,
                ),
              ),
            );
            _expectNoOverlap(layout);
            previous = layout;
          }
        }
        expect(identical(family.document.people, people), isTrue);
        expect(family.events, events);
      },
    );

    test(
      'one-parent explicit siblings copy complete parents then use computed block IDs',
      () {
        final family = _Family()
          ..add('father')
          ..add('mother')
          ..add('a')
          ..parents('a', father: 'father');
        family
          .._apply(family.document.createSibling('a', 'b', name: 'b'))
          .._apply(family.document.createSibling('b', 'c', name: 'c'));
        final incomplete = family.layout('b');
        final directId = _blockFor(incomplete, 'a').id;
        expect(_blockFor(incomplete, 'a').people.map((p) => p.id), [
          'a',
          'b',
          'c',
        ]);
        expect(incomplete.links.map((link) => (link.parentId, link.childId)), [
          ('father', 'a'),
          ('father', 'b'),
          ('father', 'c'),
        ]);
        family.parents('c', mother: 'mother');
        expect(family.document.directSiblingLinks, isEmpty);
        final complete = family.layout('b', TreeTrunkMode.both, incomplete);
        expect(_blockFor(complete, 'a').id, isNot(directId));
        expect(
          _blockFor(complete, 'a').id,
          treeSurnameFamilyKey(family.document.people['a']!),
        );
        for (final selected in ['a', 'b', 'c']) {
          for (final mode in TreeTrunkMode.values) {
            final layout = family.layout(selected, mode, incomplete);
            expect(_blockFor(layout, 'a').people.map((p) => p.id), [
              'a',
              'b',
              'c',
            ]);
            expect(_blockFor(layout, 'a').fatherId, 'father');
            expect(_blockFor(layout, 'a').motherId, 'mother');
            expect(layout.links, hasLength(6));
            expect(layout.positions['a']!.level, 1);
            _expectSameRanks(complete, layout);
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
          }
        }
      },
    );

    test(
      'unlinking direct siblings retains a known parent but splits half-sibling blocks',
      () {
        final family = _Family()
          ..add('father')
          ..add('a')
          ..parents('a', father: 'father');
        family
          .._apply(family.document.createSibling('a', 'b', name: 'b'))
          .._apply(family.document.createSibling('b', 'c', name: 'c'));
        final before = family.layout('a');
        family._apply(family.document.unlinkSibling('a', 'b'));
        final links = family.document.directSiblingLinks;
        expect(links, hasLength(1));
        for (final mode in TreeTrunkMode.values) {
          final layout = family.layout('a', mode, before);
          expect(_blockFor(layout, 'a').people.map((p) => p.id), ['a']);
          expect(_blockFor(layout, 'b').people.map((p) => p.id), ['b', 'c']);
          expect(_blockFor(layout, 'a').id, isNot(_blockFor(layout, 'b').id));
          for (final id in ['a', 'b', 'c']) {
            expect(family.document.people[id]!.fatherId, 'father');
            expect(layout.positions[id]!.level, 1);
            expect(layout.positions[id]!.emphasis, TreeEmphasis.normal);
          }
          expect(layout.links, hasLength(3));
          _expectDescendingLinks(layout);
          _expectNoOverlap(layout);
        }
      },
    );

    test(
      'explicit parentless siblings supply cousin context without spouse or ancestry shortcuts',
      () {
        final family = _Family()
          ..add('a')
          ..add('spouse')
          ..add('own-child')
          ..add('nephew')
          ..add('other-nephew');
        family
          .._apply(family.document.createSibling('a', 'b', name: 'b'))
          .._apply(family.document.createSibling('b', 'c', name: 'c'))
          ..parents('own-child', father: 'a')
          ..parents('nephew', father: 'b', mother: 'spouse')
          ..parents('other-nephew', mother: 'c');
        for (final mode in TreeTrunkMode.values) {
          final sibling = family.layout('a', mode);
          for (final id in ['b', 'c']) {
            expect(sibling.positions[id]!.emphasis, TreeEmphasis.normal);
            expect(sibling.positions[id]!.trunk, isFalse);
          }
          for (final id in ['nephew', 'other-nephew']) {
            expect(sibling.positions[id]!.emphasis, TreeEmphasis.cousin);
          }
          expect(sibling.positions['spouse']!.emphasis, TreeEmphasis.distant);
          final child = family.layout('own-child', mode);
          for (final id in ['b', 'c', 'nephew', 'other-nephew']) {
            expect(child.positions[id]!.emphasis, TreeEmphasis.cousin);
          }
          expect(child.trunkIds, {
            'own-child',
            if (mode != TreeTrunkMode.mother) 'a',
          });
          expect(
            child.links.map((link) => (link.parentId, link.childId)).toSet(),
            {
              ('a', 'own-child'),
              ('b', 'nephew'),
              ('spouse', 'nephew'),
              ('c', 'other-nephew'),
            },
          );
          _expectDescendingLinks(child);
          _expectNoOverlap(child);
        }
      },
    );

    test(
      'rootless explicit sibling side keeps a nephew outside the descendant cohort',
      () {
        final family = _Family()
          ..add('a', name: 'a')
          ..birth('a', '1970-01-01')
          ..add('father-left')
          ..add('father-right')
          ..add('nephew-father')
          ..add('child-left', name: 'a child')
          ..add('nephew', name: 'm nephew')
          ..add('child-right', name: 'z child');
        family
          .._apply(
            family.document.createSibling(
              'a',
              'b',
              name: 'b',
              birthDate: DateTime.utc(1980),
            ),
          )
          ..parents('child-left', mother: 'a', father: 'father-left')
          ..parents('child-right', mother: 'a', father: 'father-right')
          ..parents('nephew', mother: 'b', father: 'nephew-father');
        final layout = family.layout('a');
        expect(_blockFor(layout, 'a').people.map((p) => p.id), ['a', 'b']);
        expect(layout.positions['nephew']!.branch, TreeBranch.neutral);
        expect(_rowPeople(layout, 'nephew'), [
          'child-left',
          'child-right',
          'nephew',
        ]);
        _expectDescendantCorridors(layout, family.document);
        expect(layout.trunkIds, {'a'});
        expect(layout.links, hasLength(6));
        _expectDescendingLinks(layout);
        _expectNoOverlap(layout);
      },
    );

    test(
      'malformed parent updates inside a direct sibling group do not leak rank cycles',
      () {
        final family = _Family()..add('a');
        family._apply(family.document.createSibling('a', 'b', name: 'b'));
        family._apply(
          TreeOperation.fromJson({
            'type': 'setValue',
            'personId': 'a',
            'field': 'fatherId',
            'value': 'b',
          }),
        );
        final before = family.document.people;
        for (final mode in TreeTrunkMode.values) {
          final layout = family.layout('a', mode);
          expect(layout.positions['a']!.level, layout.positions['b']!.level);
          expect(_blockFor(layout, 'a').people.map((p) => p.id), ['a', 'b']);
          expect(layout.links, isEmpty);
          _expectNoOverlap(layout);
        }
        expect(identical(family.document.people, before), isTrue);
      },
    );

    test('selected partners outrank sibling partners in every trunk mode', () {
      for (final reverse in [false, true]) {
        final family =
            _cousinFamily(reverseInsertion: reverse, anastasiaFather: true)
              ..birth('natalia', '1970-01-01')
              ..birth('veronika', '1980-01-01');
        final people = family.document.people;
        final events = family.events.toList();
        final initial = family.layout('natalia');
        var previous = initial;
        for (final mode in TreeTrunkMode.values) {
          for (final selected in ['natalia', 'veronika', 'roman', 'natalia']) {
            final layout = family.layout(selected, mode, previous);
            if (selected == 'natalia') {
              _expectConsecutive(layout, ['natalia', 'oleg', 'nekto']);
              final row = _rowPeople(layout, 'natalia');
              final focused = [
                'natalia',
                'veronika',
                'oleg',
                'nekto',
              ].map(row.indexOf).toList()..sort();
              expect(
                row.indexOf('roman'),
                isNot(inInclusiveRange(focused.first, focused.last)),
              );
            } else {
              _expectConsecutive(layout, ['veronika', 'roman']);
            }
            expect(_blockFor(layout, 'natalia').people.map((p) => p.id), [
              'natalia',
              'veronika',
            ]);
            expect(_snapshot(layout), _snapshot(family.layout(selected, mode)));
            _expectSameRanks(initial, layout);
            expect(
              layout.links.map((e) => (e.parentId, e.childId, e.blockId)),
              initial.links.map((e) => (e.parentId, e.childId, e.blockId)),
            );
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
            previous = layout;
          }
        }
        expect(identical(family.document.people, people), isTrue);
        expect(family.events, events);
      }
    });

    test(
      'sibling-only partner refinement includes full half and explicit siblings',
      () {
        for (final kind in ['full', 'half', 'explicit']) {
          final family = _cousinFamily(anastasiaFather: true)
            ..add('roman-father')
            ..add('roman-mother')
            ..parents('roman', father: 'roman-father');
          if (kind == 'explicit') {
            family._apply(
              family.document.createSibling(
                'roman',
                'selected-no-partner',
                name: 'a selected',
              ),
            );
          } else {
            family
              ..parents('roman', mother: 'roman-mother')
              ..add('selected-no-partner', name: 'a selected')
              ..parents(
                'selected-no-partner',
                father: 'roman-father',
                mother: kind == 'full' ? 'roman-mother' : null,
              );
          }
          final initial = family.layout('selected-no-partner');
          final people = family.document.people;
          final events = family.events.toList();
          for (final mode in TreeTrunkMode.values) {
            final layout = family.layout('selected-no-partner', mode, initial);
            _expectConsecutive(layout, ['roman', 'veronika']);
            _expectBefore(layout, 'veronika', 'roman');
            expect(_blockFor(layout, 'natalia').people.map((p) => p.id), [
              'natalia',
              'veronika',
            ]);
            expect(
              _blockFor(layout, 'roman').people.map((p) => p.id),
              kind == 'half' ? ['roman'] : ['selected-no-partner', 'roman'],
            );
            expect(
              layout.positions['veronika']!.emphasis,
              TreeEmphasis.distant,
            );
            expect(
              _snapshot(layout),
              _snapshot(family.layout('selected-no-partner', mode)),
            );
            _expectSameRanks(initial, layout);
            expect(
              layout.links.map((e) => (e.parentId, e.childId, e.blockId)),
              initial.links.map((e) => (e.parentId, e.childId, e.blockId)),
            );
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
          }
          expect(identical(family.document.people, people), isTrue);
          expect(family.events, events);
        }
      },
    );

    test(
      'partner priority keeps both sibling blocks and structural child cohorts whole',
      () {
        for (final dates in ['unknown', 'equal', 'reversed']) {
          _Family make(bool reverse) {
            final family =
                _cousinFamily(reverseInsertion: reverse, anastasiaFather: true)
                  ..add('roman-father')
                  ..add('roman-mother')
                  ..add('yana', name: 'yana')
                  ..add('context-parent')
                  ..add('unrelated', name: 'm context')
                  ..parents(
                    'roman',
                    father: 'roman-father',
                    mother: 'roman-mother',
                  )
                  ..parents(
                    'yana',
                    father: 'roman-father',
                    mother: 'roman-mother',
                  )
                  ..parents('unrelated', father: 'context-parent');
            if (dates != 'unknown') {
              family
                ..birth(
                  'natalia',
                  dates == 'reversed' ? '1980-01-01' : '1970-01-01',
                )
                ..birth('veronika', '1970-01-01')
                ..birth(
                  'roman',
                  dates == 'reversed' ? '1980-01-01' : '1970-01-01',
                )
                ..birth('yana', '1970-01-01');
            }
            return family;
          }

          final family = make(false);
          final initial = family.layout('natalia');
          final people = family.document.people;
          final events = family.events.toList();
          var previous = initial;
          for (final mode in TreeTrunkMode.values) {
            for (final selected in [
              'natalia',
              'veronika',
              'roman',
              'natalia',
            ]) {
              final layout = family.layout(selected, mode, previous);
              _expectConsecutive(
                layout,
                selected == 'natalia'
                    ? ['natalia', 'oleg', 'nekto']
                    : ['veronika', 'roman'],
              );
              _expectConsecutive(layout, ['anastasia', rootTreePersonId]);
              expect(
                _blockFor(layout, 'natalia').people.map((p) => p.id),
                dates == 'reversed'
                    ? ['veronika', 'natalia']
                    : ['natalia', 'veronika'],
              );
              expect(
                _blockFor(layout, 'roman').people.map((p) => p.id),
                dates == 'reversed' ? ['yana', 'roman'] : ['roman', 'yana'],
              );
              for (final pair in [
                ('natalia', 'oleg'),
                ('natalia', 'nekto'),
                ('veronika', 'roman'),
              ]) {
                _expectBefore(layout, pair.$1, pair.$2);
              }
              expect(
                layout.positions['yana']!.emphasis,
                selected == 'roman'
                    ? TreeEmphasis.normal
                    : TreeEmphasis.distant,
              );
              expect(
                _snapshot(layout),
                _snapshot(make(true).layout(selected, mode)),
              );
              expect(
                _snapshot(layout),
                _snapshot(family.layout(selected, mode)),
              );
              _expectSameRanks(initial, layout);
              expect(
                layout.links.map((e) => (e.parentId, e.childId, e.blockId)),
                initial.links.map((e) => (e.parentId, e.childId, e.blockId)),
              );
              _expectDescendingLinks(layout);
              _expectNoOverlap(layout);
              previous = layout;
            }
          }
          expect(identical(family.document.people, people), isTrue);
          expect(family.events, events);
        }
      },
    );

    test('an ancestor above siblings does not reverse their birth order', () {
      final family = _Family()
        ..add('grandfather')
        ..add('grandmother')
        ..add('old')
        ..add('young')
        ..add('old-half')
        ..add('young-half')
        ..parents('old', father: 'grandfather', mother: 'grandmother')
        ..parents('young', father: 'grandfather', mother: 'grandmother')
        ..parents('old-half', father: 'grandfather')
        ..parents('young-half', father: 'grandfather')
        ..birth('old-half', '1940-01-01')
        ..birth('old', '1950-01-01')
        ..birth('young', '1960-01-01')
        ..birth('young-half', '1970-01-01');
      for (final mode in TreeTrunkMode.values) {
        final canonical = family.layout(rootTreePersonId, mode);
        for (final selected in family.document.people.keys) {
          final layout = family.layout(selected, mode);
          expect(_blockFor(layout, 'old').people.map((p) => p.id), [
            'old',
            'young',
          ]);
          _expectBefore(layout, 'old-half', 'young-half');
          expect(_rowPeople(layout, 'old'), _rowPeople(canonical, 'old'));
          if (mode != TreeTrunkMode.mother) {
            _expectBefore(layout, 'old-half', 'old');
            _expectBefore(layout, 'young', 'young-half');
            _expectConsecutive(layout, ['old-half', 'old', 'young-half']);
          }
        }
      }
    });

    test('nearest descendant rank wins over a deeper opposite branch', () {
      final family = _Family();
      for (final id in [
        'a',
        'b',
        'early',
        'a-path',
        'b-path',
        'a-late',
        'b-late',
        'late',
        'bottom',
      ]) {
        family.add(id);
      }
      family
        ..parents('a-path', father: 'a')
        ..parents('b-path', mother: 'b')
        ..parents('early', mother: 'a-path', father: 'b-path')
        ..parents('a-late', father: 'a-path')
        ..parents('b-late', mother: 'b-path')
        ..parents('late', mother: 'b-late', father: 'a-late')
        ..parents('bottom', father: 'late')
        ..birth('a', '1980-01-01')
        ..birth('b', '1920-01-01');
      for (final mode in TreeTrunkMode.values) {
        for (final selected in family.document.people.keys) {
          final layout = family.layout(selected, mode);
          _expectBefore(layout, 'a', 'b');
          _expectDescendingLinks(layout);
          _expectNoOverlap(layout);
        }
      }
    });

    test('multi-level role masks traverse real long edges without using sex', () {
      final family = _Family();
      for (final id in [
        'left',
        'right',
        'l1',
        'l2',
        'r1',
        'r2',
        'join',
        'older',
        'grandparent',
        'parent',
        'long-partner',
        'long-child',
        'other-root',
        'other-terminal',
        for (var i = 1; i <= 4; i++) 'other-$i',
        'long-join',
      ]) {
        family.add(id);
      }
      family.parents('other-terminal', mother: 'other-root');
      for (var i = 1; i <= 4; i++) {
        family.parents(
          'other-$i',
          father: i == 1 ? 'other-root' : 'other-${i - 1}',
        );
      }
      family
        ..parents('l1', father: 'left')
        ..parents('l2', father: 'l1')
        ..parents('r1', mother: 'right')
        ..parents('r2', mother: 'r1')
        ..parents('join', mother: 'l2', father: 'r2')
        // An incompatible intergeneration union leaves older -> long-child long.
        ..parents('grandparent', father: 'older')
        ..parents('parent', father: 'grandparent')
        ..parents('long-partner', father: 'parent')
        ..parents('long-child', mother: 'long-partner', father: 'older')
        ..parents('long-join', mother: 'other-4', father: 'long-child')
        ..sex('left', TreeSex.male)
        ..sex('right', TreeSex.female)
        ..birth('right', '1900-01-01')
        ..birth('left', '1980-01-01');
      for (final mode in TreeTrunkMode.values) {
        for (final selected in family.document.people.keys) {
          final layout = family.layout(selected, mode);
          _expectBefore(layout, 'left', 'right');
          _expectBefore(layout, 'l1', 'r1');
          _expectBefore(layout, 'l2', 'r2');
          _expectBefore(layout, 'other-root', 'older');
          expect(
            layout.positions['long-child']!.level -
                layout.positions['older']!.level,
            greaterThan(1),
          );
          _expectDescendingLinks(layout);
          _expectNoOverlap(layout);
        }
      }
    });

    test(
      'both-mask ancestry stays unassigned and opposed descendants cancel',
      () {
        final opposed = _Family();
        for (final id in ['a', 'b', 'a-child', 'b-child', 'first', 'second']) {
          opposed.add(id);
        }
        opposed
          ..parents('a-child', father: 'a')
          ..parents('b-child', father: 'b')
          ..parents('first', mother: 'a-child', father: 'b-child')
          ..parents('second', mother: 'b-child', father: 'a-child')
          ..birth('a', '1980-01-01')
          ..birth('b', '1920-01-01');
        for (final mode in TreeTrunkMode.values) {
          for (final selected in opposed.document.people.keys) {
            final layout = opposed.layout(selected, mode);
            _expectBefore(layout, 'b', 'a');
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
          }
        }
        // At join, a has mask 3 and b is paternal. That lower ambiguous mask
        // must not invent a new side or reverse their earlier exclusive roles.
        final ambiguous = _Family();
        for (final id in [
          'a',
          'b',
          'a-sibling',
          'a-grandfather',
          'a-grandmother',
          'a-path',
          'b-path',
          'mother',
          'father',
          'join',
        ]) {
          ambiguous.add(id);
        }
        ambiguous
          ..parents('a', father: 'a-grandfather', mother: 'a-grandmother')
          ..parents(
            'a-sibling',
            father: 'a-grandfather',
            mother: 'a-grandmother',
          )
          ..parents('b-path', father: 'b')
          ..parents('a-path', father: 'a')
          ..parents('mother', mother: 'a-path')
          ..parents('father', mother: 'b-path', father: 'a-path')
          ..parents('join', mother: 'mother', father: 'father')
          ..birth('a', '1980-01-01')
          ..birth('a-sibling', '1985-01-01')
          ..birth('b', '1920-01-01');
        for (final mode in TreeTrunkMode.values) {
          final layout = ambiguous.layout('join', mode);
          _expectBefore(layout, 'b', 'a');
          expect(layout.positions['a']!.branch, TreeBranch.both);
          _expectDescendingLinks(layout);
          _expectNoOverlap(layout);
        }

        // Two independent shared ancestors both have mask 3 at every join.
        final collapsed = _Family()
          ..add('a')
          ..add('b')
          ..add('mother')
          ..add('father')
          ..add('child')
          ..parents('mother', father: 'a', mother: 'b')
          ..parents('father', father: 'a', mother: 'b')
          ..parents('child', mother: 'mother', father: 'father');
        // a/b have actual co-parent roles, so use same-side one-parent ancestry
        // to test an ambiguous pair with no direct role preference between them.
        collapsed
          ..add('x')
          ..add('y')
          ..add('x-path')
          ..add('y-path')
          ..add('joined')
          ..add('joined-mother')
          ..add('joined-father')
          ..add('collapsed-child')
          ..parents('x-path', father: 'x')
          ..parents('y-path', father: 'y')
          ..parents('joined', mother: 'x-path', father: 'y-path')
          ..parents('joined-mother', mother: 'joined')
          ..parents('joined-father', mother: 'joined')
          ..parents(
            'collapsed-child',
            mother: 'joined-mother',
            father: 'joined-father',
          )
          ..birth('x', '1980-01-01')
          ..birth('y', '1920-01-01');
        // At joined the roles are unambiguous, therefore a lower collapse must
        // not erase the earlier x-before-y inequality.
        for (final mode in TreeTrunkMode.values) {
          _expectBefore(collapsed.layout('collapsed-child', mode), 'x', 'y');
        }
      },
    );

    test(
      'contradictory role cycles are deterministic without splitting blocks',
      () {
        _Family make(bool reverse) {
          final family = _Family();
          final ids = [
            'a',
            'b',
            'c',
            'ab',
            'bc',
            'ca',
            'unrelated',
            'unrelated-child',
            'grandfather',
            'grandmother',
            'a-sibling',
          ];
          for (final id in reverse ? ids.reversed : ids) {
            family.add(id);
          }
          return family
            ..parents('a', father: 'grandfather', mother: 'grandmother')
            ..parents('a-sibling', father: 'grandfather', mother: 'grandmother')
            ..birth('a-sibling', '1950-01-01')
            ..birth('a', '1960-01-01')
            ..parents('ab', mother: 'a', father: 'b')
            ..parents('bc', mother: 'b', father: 'c')
            ..parents('ca', mother: 'c', father: 'a')
            ..parents('unrelated-child', mother: 'unrelated');
        }

        for (final mode in TreeTrunkMode.values) {
          for (final selected in make(false).document.people.keys) {
            final layout = make(false).layout(selected, mode);
            expect(
              _snapshot(layout),
              _snapshot(make(true).layout(selected, mode)),
            );
            if (mode == TreeTrunkMode.both && selected == 'bc') {
              // a is shared/both-path context between the actual ancestors c/b.
              // Its equal-distance outside edge is left; the old context-role
              // c-before-a inequality yields, but ancestor c-before-b survives.
              expect(layout.positions['a']!.branch, TreeBranch.both);
              _expectBefore(layout, 'a', 'c');
              _expectBefore(layout, 'c', 'b');
              _expectAncestorCorridors(layout);
            } else {
              _expectBefore(layout, 'c', 'a');
            }
            _expectBefore(layout, 'a', 'b');
            expect(
              _blockFor(layout, 'a').people.map((p) => p.id),
              unorderedEquals(['a-sibling', 'a']),
            );
            expect(
              _blockFor(layout, 'a').id,
              _blockFor(layout, 'a-sibling').id,
            );
            if (mode != TreeTrunkMode.both) {
              expect(_blockFor(layout, 'a').people.map((p) => p.id), [
                'a-sibling',
                'a',
              ]);
            }
            expect(layout.positions, hasLength(12));
            expect(layout.links, hasLength(11));
            _expectDescendingLinks(layout);
            _expectNoOverlap(layout);
          }
        }
      },
    );

    test(
      'both-mode parent seam relocates when the old father-slot swap conflicts',
      () {
        final family = _Family();
        for (final id in [
          'mother',
          'father',
          'other-mother',
          'other-father',
          'selected',
          'other-child',
        ]) {
          family.add(id);
        }
        family
          ..parents('selected', mother: 'mother', father: 'father')
          ..parents(
            'other-child',
            mother: 'other-mother',
            father: 'other-father',
          )
          ..birth('mother', '1900-01-01')
          ..birth('other-mother', '1920-01-01')
          ..birth('other-father', '1930-01-01')
          ..birth('father', '1940-01-01');
        final initial = family.layout(rootTreePersonId);
        for (final selected in ['selected', 'other-child']) {
          final layout = family.layout(selected);
          final person = family.document.people[selected]!;
          _expectParentCardsAdjacent(
            layout,
            person.motherId!,
            person.fatherId!,
          );
          _expectBefore(layout, 'mother', 'father');
          _expectBefore(layout, 'other-mother', 'other-father');
          _expectSameRanks(initial, layout);
          _expectNoOverlap(layout);
        }
      },
    );

    test('single trunk follows all ancestry of the selected parent branch', () {
      final family = _Family()
        ..add('maternal-grandfather')
        ..add('maternal-grandmother')
        ..add('paternal-grandfather')
        ..add('paternal-grandmother')
        ..add('mother')
        ..add('father')
        ..parents(
          'mother',
          father: 'maternal-grandfather',
          mother: 'maternal-grandmother',
        )
        ..parents(
          'father',
          father: 'paternal-grandfather',
          mother: 'paternal-grandmother',
        )
        ..parents(rootTreePersonId, father: 'father', mother: 'mother');
      final paternal = family.layout(rootTreePersonId, TreeTrunkMode.father);
      final maternal = family.layout(rootTreePersonId, TreeTrunkMode.mother);

      expect(paternal.trunkIds, {
        rootTreePersonId,
        'father',
        'paternal-grandfather',
        'paternal-grandmother',
      });
      expect(maternal.trunkIds, {
        rootTreePersonId,
        'mother',
        'maternal-grandfather',
        'maternal-grandmother',
      });
      expect(paternal.positions['father']!.crossCenter, 0);
      expect(maternal.positions['mother']!.crossCenter, 0);
      expect(paternal.positions['mother']!.emphasis, TreeEmphasis.normal);
      for (final id in family.document.people.keys) {
        expect(paternal.positions[id]!.level, maternal.positions[id]!.level);
      }
      expect(paternal.links, hasLength(maternal.links.length));
    });

    test('cousin marriage keeps shared ancestors single and central', () {
      final family = _Family()
        ..add('grandfather')
        ..add('grandmother')
        ..add('aunt')
        ..add('uncle')
        ..add('mother')
        ..add('father')
        ..parents('aunt', father: 'grandfather', mother: 'grandmother')
        ..parents('uncle', father: 'grandfather', mother: 'grandmother')
        ..parents('mother', mother: 'aunt')
        ..parents('father', father: 'uncle')
        ..parents(rootTreePersonId, father: 'father', mother: 'mother');
      final layout = family.layout(rootTreePersonId);

      expect(layout.positions, hasLength(family.document.people.length));
      expect(layout.positions['grandfather']!.branch, TreeBranch.both);
      expect(layout.positions['grandmother']!.branch, TreeBranch.both);
      expect(layout.positions['grandfather']!.crossCenter, 0);
      expect(_blockFor(layout, 'aunt').id, _blockFor(layout, 'uncle').id);
      expect(
        layout.levels
            .expand((g) => g.blocks)
            .expand((b) => b.people)
            .map((p) => p.id),
        unorderedEquals(family.document.people.keys),
      );
      _expectNoOverlap(layout);
    });

    test('ancestor full siblings stay together ahead of distant context', () {
      final family = _Family()
        ..add('grandfather')
        ..add('grandmother')
        ..add('father')
        ..add('aunt')
        ..add('distant-parent')
        ..add('distant')
        ..parents('father', father: 'grandfather', mother: 'grandmother')
        ..parents('aunt', father: 'grandfather', mother: 'grandmother')
        ..parents('distant', father: 'distant-parent')
        ..parents(rootTreePersonId, father: 'father')
        ..birth('aunt', '1960-01-01')
        ..birth('father', '1965-01-01');
      final layout = family.layout(rootTreePersonId, TreeTrunkMode.father);
      final block = _blockFor(layout, 'father');

      expect(block.people.map((p) => p.id), ['aunt', 'father']);
      expect(block.trunk, isTrue);
      expect(layout.positions['father']!.trunk, isTrue);
      expect(layout.positions['aunt']!.trunk, isFalse);
      expect(layout.positions['father']!.crossCenter, 0);
      expect(
        layout.positions['aunt']!.crossCenter.abs(),
        lessThan(layout.positions['distant']!.crossCenter.abs()),
      );
      _expectNoOverlap(layout);
    });

    test('emphasis distinguishes siblings and cousins from distant people', () {
      final family = _Family()
        ..add('grandfather')
        ..add('father')
        ..add('aunt')
        ..add('sibling')
        ..add('half-sibling')
        ..add('cousin')
        ..add('cousin-child')
        ..add('child')
        ..add('unrelated')
        ..parents('father', father: 'grandfather')
        ..parents('aunt', father: 'grandfather')
        ..parents(rootTreePersonId, father: 'father')
        ..parents('sibling', father: 'father')
        ..parents('half-sibling', father: 'father')
        ..parents('cousin', mother: 'aunt')
        ..parents('cousin-child', father: 'cousin')
        ..parents('child', mother: rootTreePersonId);
      final layout = family.layout(rootTreePersonId);

      for (final id in [
        rootTreePersonId,
        'grandfather',
        'father',
        'sibling',
        'half-sibling',
        'child',
      ]) {
        expect(layout.positions[id]!.emphasis, TreeEmphasis.normal);
      }
      for (final id in ['aunt', 'cousin']) {
        expect(layout.positions[id]!.emphasis, TreeEmphasis.cousin);
      }
      for (final id in ['cousin-child', 'unrelated']) {
        expect(layout.positions[id]!.emphasis, TreeEmphasis.distant);
      }
    });

    test(
      'parents’ partners use cousin emphasis without extending ancestry',
      () {
        final family = _cousinFamily(anastasiaFather: true)
          ..add('stepmother')
          ..add('paternal-half')
          ..add('stepparent-parent')
          ..add('stepparent-sibling')
          ..parents('paternal-half', father: 'oleg', mother: 'stepmother')
          ..parents('nekto', father: 'stepparent-parent')
          ..parents('stepparent-sibling', father: 'stepparent-parent');
        final people = family.document.people;
        final events = family.events.toList();
        for (final mode in TreeTrunkMode.values) {
          final layout = family.layout(rootTreePersonId, mode);
          for (final id in ['nekto', 'stepmother']) {
            expect(layout.positions[id]!.emphasis, TreeEmphasis.cousin);
            expect(_blockFor(layout, id).emphasis, TreeEmphasis.cousin);
            expect(layout.trunkIds, isNot(contains(id)));
          }
          for (final id in ['natalia', 'oleg', 'anastasia', 'paternal-half']) {
            expect(layout.positions[id]!.emphasis, TreeEmphasis.normal);
          }
          for (final id in [
            'stepparent-parent',
            'stepparent-sibling',
            'roman',
          ]) {
            expect(layout.positions[id]!.emphasis, TreeEmphasis.distant);
          }
          _expectDescendingLinks(layout);
          _expectNoOverlap(layout);
        }
        expect(identical(family.document.people, people), isTrue);
        expect(family.events, events);
      },
    );

    test('parents and stepparents keep unrelated sibling blocks outside', () {
      _Family make(bool reverse) {
        final family = _cousinFamily(
          anastasiaFather: true,
          reverseInsertion: reverse,
        );
        for (final (id, name) in [
          ('natalia', 'Наталья'),
          ('veronika', 'Вероника'),
          ('oleg', 'Олег'),
          ('nekto', 'Сергей'),
          ('roman', 'Роман'),
        ]) {
          family._apply(
            family.document.editText(id, TreeTextField.name, name)!,
          );
        }
        family
          ..add('unrelated-father')
          ..add('unrelated-mother');
        final intruders = ['Елена', 'Наталья другая', 'Степан'];
        for (final id in reverse ? intruders.reversed : intruders) {
          family
            ..add(id)
            ..parents(
              id,
              father: 'unrelated-father',
              mother: 'unrelated-mother',
            );
        }
        family.parents(
          'roman',
          father: 'unrelated-father',
          mother: 'unrelated-mother',
        );
        return family;
      }

      final family = make(false);
      final reverse = make(true);
      final people = family.document.people;
      final events = family.events.toList();
      final baseline = family.layout(rootTreePersonId);
      for (final mode in TreeTrunkMode.values) {
        for (final selected in [
          rootTreePersonId,
          'anastasia',
          rootTreePersonId,
        ]) {
          final layout = family.layout(selected, mode, baseline);
          _expectConsecutive(layout, ['natalia', 'oleg', 'nekto']);
          expect(_blockFor(layout, 'roman').people.map((person) => person.id), [
            'Елена',
            'Наталья другая',
            'roman',
            'Степан',
          ]);
          expect(layout.positions.keys, unorderedEquals(people.keys));
          expect(_snapshot(layout), _snapshot(reverse.layout(selected, mode)));
          expect(
            _snapshot(layout),
            _snapshot(
              TreeLayout.build(
                family.reload(),
                selectedId: selected,
                mode: mode,
              ),
            ),
          );
          _expectSameRanks(baseline, layout);
          _expectDescendingLinks(layout);
          _expectNoOverlap(layout);
          if (mode == TreeTrunkMode.both) {
            _expectAncestorCorridors(layout);
            _expectParentCardsAdjacent(
              layout,
              'natalia',
              selected == rootTreePersonId ? 'oleg' : 'nekto',
            );
          }
        }
      }
      expect(identical(family.document.people, people), isTrue);
      expect(family.events, events);
    });

    test('full and half siblings of every ancestor use cousin colors', () {
      final family = _Family();
      final relatives = <String>[];
      final ancestors = <String>[];
      final halfRelatives = <String>[];
      for (final branch in ['paternal', 'maternal']) {
        for (var depth = 0; depth < 4; depth++) {
          final ancestor = '$branch-$depth';
          family.add(ancestor);
          ancestors.add(ancestor);
        }
        for (var depth = 0; depth < 3; depth++) {
          final ancestor = '$branch-$depth';
          final father = '$branch-${depth + 1}';
          final mother = '$branch-parent-$depth';
          family
            ..add(mother)
            ..parents(ancestor, father: father, mother: mother);
          ancestors.add(mother);
          for (final kind in ['full', 'paternal-half', 'maternal-half']) {
            final relative = '$branch-$depth-$kind';
            family
              ..add(relative)
              ..parents(
                relative,
                father: kind == 'maternal-half' ? null : father,
                mother: kind == 'paternal-half' ? null : mother,
              );
            relatives.add(relative);
            if (kind != 'full') halfRelatives.add(relative);
          }
        }
      }
      family
        ..parents(rootTreePersonId, father: 'paternal-0', mother: 'maternal-0')
        ..add('first-cousin')
        ..parents('first-cousin', father: 'paternal-0-full')
        ..add('higher-collateral-child')
        ..parents('higher-collateral-child', father: 'maternal-1-full')
        ..add('unrelated')
        ..add('unrelated-child')
        ..parents('unrelated-child', father: 'unrelated');
      final people = family.document.people;
      for (final mode in TreeTrunkMode.values) {
        final layout = family.layout(rootTreePersonId, mode);
        for (final id in [...relatives, 'first-cousin']) {
          expect(
            layout.positions[id]!.emphasis,
            TreeEmphasis.cousin,
            reason: '${mode.name}: $id',
          );
          expect(layout.positions[id]!.trunk, isFalse);
        }
        for (final id in halfRelatives) {
          expect(_blockFor(layout, id).emphasis, TreeEmphasis.cousin);
        }
        for (final id in [rootTreePersonId, ...ancestors]) {
          expect(
            layout.positions[id]!.emphasis,
            TreeEmphasis.normal,
            reason: '${mode.name}: $id',
          );
        }
        for (final id in [
          'higher-collateral-child',
          'unrelated',
          'unrelated-child',
        ]) {
          expect(layout.positions[id]!.emphasis, TreeEmphasis.distant);
        }
        var previous = layout;
        for (final selected in ['paternal-1', 'maternal-2', rootTreePersonId]) {
          final next = family.layout(selected, mode, previous);
          _expectSameRanks(layout, next);
          _expectDescendingLinks(next);
          _expectNoOverlap(next);
          previous = next;
        }
      }
      expect(identical(family.document.people, people), isTrue);
    });

    test('direct ancestry wins over ancestral sibling context', () {
      final family = _Family()
        ..add('shared-father')
        ..add('father')
        ..add('mother')
        ..add('aunt')
        ..parents('father', father: 'shared-father')
        ..parents('mother', father: 'shared-father')
        ..parents('aunt', father: 'shared-father')
        ..parents(rootTreePersonId, father: 'father', mother: 'mother');
      for (final mode in TreeTrunkMode.values) {
        final layout = family.layout(rootTreePersonId, mode);
        for (final id in ['father', 'mother', 'shared-father']) {
          expect(layout.positions[id]!.emphasis, TreeEmphasis.normal);
        }
        expect(layout.positions['aunt']!.emphasis, TreeEmphasis.cousin);
        expect(_blockFor(layout, 'aunt').emphasis, TreeEmphasis.cousin);
        _expectDescendingLinks(layout);
        _expectNoOverlap(layout);
      }
    });

    test('full and half siblings’ children use cousin emphasis', () {
      final family = _Family()
        ..add('father')
        ..add('mother')
        ..add('other-mother')
        ..add('full-sibling')
        ..add('half-sibling')
        ..add('maternal-half-sibling')
        ..add('full-nephew')
        ..add('full-niece')
        ..add('half-nephew')
        ..add('maternal-half-niece')
        ..add('grand-nephew')
        ..add('own-child')
        ..add('shared-descendant')
        ..add('unrelated')
        ..parents(rootTreePersonId, father: 'father', mother: 'mother')
        ..parents('full-sibling', father: 'father', mother: 'mother')
        ..parents('half-sibling', father: 'father', mother: 'other-mother')
        ..parents('maternal-half-sibling', mother: 'mother')
        ..parents('full-nephew', father: 'full-sibling', mother: 'unrelated')
        ..parents('full-niece', father: 'full-sibling', mother: 'unrelated')
        ..parents('half-nephew', mother: 'half-sibling')
        ..parents('maternal-half-niece', father: 'maternal-half-sibling')
        ..parents('grand-nephew', father: 'full-nephew')
        ..parents('own-child', father: rootTreePersonId, mother: 'half-sibling')
        ..parents(
          'shared-descendant',
          father: 'full-sibling',
          mother: 'own-child',
        );
      for (final mode in TreeTrunkMode.values) {
        final layout = family.layout(rootTreePersonId, mode);
        for (final id in [
          'full-nephew',
          'full-niece',
          'half-nephew',
          'maternal-half-niece',
        ]) {
          expect(layout.positions[id]!.emphasis, TreeEmphasis.cousin);
          expect(_blockFor(layout, id).emphasis, TreeEmphasis.cousin);
          expect(layout.positions[id]!.trunk, isFalse);
        }
        for (final id in ['own-child', 'shared-descendant']) {
          expect(layout.positions[id]!.emphasis, TreeEmphasis.normal);
          expect(_blockFor(layout, id).emphasis, TreeEmphasis.normal);
        }
        for (final id in ['grand-nephew', 'unrelated']) {
          expect(layout.positions[id]!.emphasis, TreeEmphasis.distant);
        }
        expect(
          _blockFor(layout, 'full-nephew').id,
          _blockFor(layout, 'full-niece').id,
        );
        _expectDescendingLinks(layout);
        _expectNoOverlap(layout);
      }
      final lydia = _lydiaFamily().layout('natalia');
      for (final id in ['olga', 'anastasia']) {
        expect(lydia.positions[id]!.emphasis, TreeEmphasis.normal);
      }
      final veronika = _lydiaFamily().layout('veronika');
      for (final id in ['olga', 'anastasia']) {
        expect(veronika.positions[id]!.emphasis, TreeEmphasis.cousin);
        expect(_blockFor(veronika, id).emphasis, TreeEmphasis.cousin);
      }
    });

    test(
      'unknown parents do not make unrelated children nieces or nephews',
      () {
        final family = _Family()
          ..add('unrelated-parent')
          ..add('unrelated-child')
          ..add('own-child')
          ..parents('unrelated-child', father: 'unrelated-parent')
          ..parents('own-child', father: rootTreePersonId);
        final layout = family.layout(rootTreePersonId);
        expect(layout.positions['own-child']!.emphasis, TreeEmphasis.normal);
        expect(
          layout.positions['unrelated-child']!.emphasis,
          TreeEmphasis.distant,
        );
        expect(
          _blockFor(layout, 'unrelated-child').emphasis,
          TreeEmphasis.distant,
        );
      },
    );

    test('selection rebuild centers new focus without changing ranks', () {
      final family = _Family()
        ..add('father')
        ..add('older')
        ..add('younger')
        ..add('mother')
        ..parents('older', father: 'father', mother: 'mother')
        ..parents('younger', father: 'father', mother: 'mother')
        ..birth('older', '2000-01-01')
        ..birth('younger', '2005-01-01');
      final older = family.layout('older');
      final younger = family.layout('younger');

      expect(older.positions['older']!.crossCenter, 0);
      expect(younger.positions['younger']!.crossCenter, 0);
      expect(younger.selectedId, 'younger');
      for (final id in family.document.people.keys) {
        expect(older.positions[id]!.level, younger.positions[id]!.level);
      }
      expect(
        younger.positions['older']!.crossCenter,
        lessThan(younger.positions['younger']!.crossCenter),
      );
    });

    test('layout is deterministic across document insertion orders', () {
      _Family make(List<String> ids) {
        final family = _Family();
        for (final id in ids) {
          family.add(id);
        }
        family
          ..parents('a', father: 'father', mother: 'mother')
          ..parents('b', father: 'father', mother: 'mother')
          ..parents(rootTreePersonId, father: 'father', mother: 'mother');
        return family;
      }

      final first = make([
        'father',
        'mother',
        'a',
        'b',
      ]).layout(rootTreePersonId);
      final second = make([
        'b',
        'a',
        'mother',
        'father',
      ]).layout(rootTreePersonId);
      expect(_snapshot(first), _snapshot(second));
    });

    test('context blocks sharing a parent stay contiguous in birth order', () {
      final family = _Family();
      for (final parent in ['a', 'b', 'c']) {
        family.add('parent-$parent');
        family.add('$parent-old');
        family.add('$parent-young');
        family.parents('$parent-old', father: 'parent-$parent');
        family.parents('$parent-young', father: 'parent-$parent');
      }
      family
        ..birth('a-old', '2000-01-01')
        ..birth('b-old', '2001-01-01')
        ..birth('c-old', '2002-01-01')
        ..birth('a-young', '2003-01-01')
        ..birth('b-young', '2004-01-01')
        ..birth('c-young', '2005-01-01');
      for (final mode in TreeTrunkMode.values) {
        final layout = family.layout(rootTreePersonId, mode);
        for (final parent in ['a', 'b', 'c']) {
          _expectConsecutive(layout, ['$parent-old', '$parent-young']);
          expect(
            layout.positions['$parent-old']!.crossCenter,
            lessThan(layout.positions['$parent-young']!.crossCenter),
          );
          // One known parent must not turn these into a full-sibling block.
          expect(
            layout.positions['$parent-old']!.blockId,
            isNot(layout.positions['$parent-young']!.blockId),
          );
        }
        _expectNoOverlap(layout);
      }
    });

    test('half-sibling grouping chooses the mode priority parent', () {
      final family = _Family()
        ..add('father-a')
        ..add('father-b')
        ..add('mother-a')
        ..add('mother-b')
        ..birth('father-a', '1960-01-01')
        ..birth('father-b', '1980-01-01')
        ..birth('mother-a', '1950-01-01')
        ..birth('mother-b', '1970-01-01');
      for (final father in ['a', 'b']) {
        for (final mother in ['a', 'b']) {
          final id = '$father$mother';
          family
            ..add(id)
            ..parents(id, father: 'father-$father', mother: 'mother-$mother');
        }
      }
      family
        ..birth('aa', '2000-01-01')
        ..birth('ab', '2001-01-01')
        ..birth('ba', '2002-01-01')
        ..birth('bb', '2003-01-01');
      final paternal = family.layout(rootTreePersonId, TreeTrunkMode.father);
      final maternal = family.layout(rootTreePersonId, TreeTrunkMode.mother);
      final both = family.layout(rootTreePersonId);

      _expectConsecutive(paternal, ['aa', 'ab']);
      _expectConsecutive(paternal, ['ba', 'bb']);
      _expectConsecutive(maternal, ['aa', 'ba']);
      _expectConsecutive(maternal, ['ab', 'bb']);
      // mother-a is older than either father, while father-a is older than
      // mother-b. The latter union must not be attached to mother-b's group.
      _expectConsecutive(both, ['aa', 'ba']);
      final aa = both.positions['aa']!.crossCenter;
      final ba = both.positions['ba']!.crossCenter;
      expect(aa, lessThan(ba));
      expect(
        both.positions['ab']!.crossCenter,
        isNot(inInclusiveRange(aa, ba)),
      );
      for (final layout in [paternal, maternal, both]) {
        _expectNoOverlap(layout);
      }
    });

    test('single trunk centers a person even for sibling ancestor unions', () {
      final family = _Family()
        ..add('great-grandfather')
        ..add('great-grandmother')
        ..add('grandfather')
        ..add('grandmother')
        ..add('father')
        ..add('mother')
        ..parents(
          'grandfather',
          father: 'great-grandfather',
          mother: 'great-grandmother',
        )
        ..parents(
          'grandmother',
          father: 'great-grandfather',
          mother: 'great-grandmother',
        )
        ..parents('father', father: 'grandfather', mother: 'grandmother')
        ..parents('mother', father: 'grandfather', mother: 'grandmother')
        ..parents(rootTreePersonId, father: 'father', mother: 'mother')
        ..birth('grandmother', '1950-01-01')
        ..birth('grandfather', '1955-01-01')
        ..birth('father', '1980-01-01')
        ..birth('mother', '1985-01-01');
      final paternal = family.layout(rootTreePersonId, TreeTrunkMode.father);
      final maternal = family.layout(rootTreePersonId, TreeTrunkMode.mother);

      for (final id in ['father', 'grandfather', 'great-grandfather']) {
        expect(paternal.positions[id]!.crossCenter, 0);
      }
      for (final id in ['mother', 'grandmother', 'great-grandmother']) {
        expect(maternal.positions[id]!.crossCenter, 0);
      }
      expect(
        paternal.positions['grandmother']!.crossCenter,
        lessThan(paternal.positions['grandfather']!.crossCenter),
      );
      _expectNoOverlap(paternal);
      _expectNoOverlap(maternal);
    });

    test(
      'single-trunk centering preserves canonical common-parent chronology',
      () {
        final family = _Family()
          ..add('grandfather')
          ..add('grandmother')
          ..add('father')
          ..add('aunt')
          ..add('older-half-aunt')
          ..add('younger-half-aunt')
          ..parents('father', father: 'grandfather', mother: 'grandmother')
          ..parents('aunt', father: 'grandfather', mother: 'grandmother')
          ..parents('older-half-aunt', father: 'grandfather')
          ..parents('younger-half-aunt', father: 'grandfather')
          ..parents(rootTreePersonId, father: 'father')
          ..birth('aunt', '1960-01-01')
          ..birth('father', '1965-01-01')
          ..birth('older-half-aunt', '1950-01-01')
          ..birth('younger-half-aunt', '1970-01-01');
        final layout = family.layout(rootTreePersonId, TreeTrunkMode.father);

        expect(layout.positions['father']!.crossCenter, 0);
        expect(_blockFor(layout, 'father').id, _blockFor(layout, 'aunt').id);
        _expectConsecutive(layout, [
          'older-half-aunt',
          'father',
          'younger-half-aunt',
        ]);
        expect(
          layout.positions['older-half-aunt']!.crossCenter,
          lessThan(layout.positions['aunt']!.crossCenter),
        );
        expect(
          layout.positions['father']!.crossCenter,
          lessThan(layout.positions['younger-half-aunt']!.crossCenter),
        );
        _expectTranslatedRow(
          family.layout('younger-half-aunt', TreeTrunkMode.father),
          layout,
          layout.positions['father']!.level,
        );
        _expectNoOverlap(layout);
      },
    );

    test('custom metrics affect every block and prevent overlap', () {
      final family = _Family()
        ..add('father')
        ..add('mother')
        ..add('sibling')
        ..add('stranger')
        ..parents(rootTreePersonId, father: 'father', mother: 'mother')
        ..parents('sibling', father: 'father', mother: 'mother');
      final layout = TreeLayout.build(
        family.document,
        selectedId: rootTreePersonId,
        mode: TreeTrunkMode.both,
        nodeExtent: 80,
        gap: 10,
      );

      expect(layout.nodeExtent, 80);
      expect(layout.gap, 10);
      expect(_blockFor(layout, rootTreePersonId).extent, 170);
      _expectNoOverlap(layout);
      final zeroGap = TreeLayout.build(
        family.document,
        selectedId: rootTreePersonId,
        mode: TreeTrunkMode.both,
        gap: 0,
      );
      _expectNoOverlap(zeroGap);
    });

    test(
      'cold sibling selections share a backbone instead of flipping context',
      () {
        final family = _siblingContextFamily();
        final first = family.layout('a');
        final second = family.layout('b');

        expect(first.positions['a']!.crossCenter, 0);
        expect(first.positions['b']!.crossCenter, 120);
        expect(first.positions['context']!.crossCenter, 264);
        expect(second.positions['a']!.crossCenter, -120);
        expect(second.positions['b']!.crossCenter, 0);
        expect(second.positions['context']!.crossCenter, 144);
        _expectTranslatedRows(first, second);
        expect(
          _snapshot(family.layout('a', TreeTrunkMode.both, null)),
          _snapshot(first),
        );
      },
    );

    test(
      'undated sibling focus cycles translate entire rows without repacking',
      () {
        final family = _siblingContextFamily();
        for (final mode in TreeTrunkMode.values) {
          for (final (extent, gap) in [
            (96.0, 24.0),
            (80.0, 10.0),
            (80.0, 0.0),
            (83.5, 7.25),
          ]) {
            TreeLayout build(String id, [TreeLayout? previous]) =>
                TreeLayout.build(
                  family.document,
                  selectedId: id,
                  mode: mode,
                  nodeExtent: extent,
                  gap: gap,
                  previousLayout: previous,
                );
            final initial = build('a');
            var previous = initial;
            for (final id in ['b', 'a', 'b', 'a', 'a', 'b', 'a']) {
              final current = build(id, previous);
              expect(current.selectedId, id);
              expect(current.positions[id]!.crossCenter, 0);
              _expectTranslatedRows(previous, current);
              _expectNoOverlap(current);
              if (id == 'a') expect(_snapshot(current), _snapshot(initial));
              previous = current;
            }
          }
        }
      },
    );

    test(
      'co-parents never flip when one becomes neutral through focus cycles',
      () {
        final family = _Family()
          ..add('father')
          ..add('mother')
          ..add('child-a')
          ..add('child-b')
          ..parents('child-a', father: 'father', mother: 'mother')
          ..parents('child-b', father: 'father', mother: 'mother');
        for (final mode in TreeTrunkMode.values) {
          // For both mode, start with the child so maternal/paternal sides are
          // established before either co-parent becomes neutral.
          final initial = family.layout('child-a', mode);
          var previous = initial;
          for (final id in [
            'mother',
            'father',
            'child-a',
            'father',
            'mother',
            'child-b',
            'mother',
            'father',
            'child-a',
          ]) {
            final current = family.layout(id, mode, previous);
            _expectTranslatedRows(previous, current);
            expect(
              current.positions['father']!.crossCenter -
                  current.positions['mother']!.crossCenter,
              initial.positions['father']!.crossCenter -
                  initial.positions['mother']!.crossCenter,
            );
            expect(current.positions[id]!.crossCenter, 0);
            if (id == 'mother') {
              expect(current.positions['father']!.branch, TreeBranch.neutral);
            }
            if (id == 'father') {
              expect(current.positions['mother']!.branch, TreeBranch.neutral);
            }
            if (id.startsWith('child') && mode == TreeTrunkMode.both) {
              expect(current.positions['mother']!.crossCenter, lessThan(0));
              expect(current.positions['father']!.crossCenter, greaterThan(0));
            }
            _expectNoOverlap(current);
            previous = current;
          }
          expect(_snapshot(previous), _snapshot(initial));
        }
      },
    );

    test('unrelated focus changes translate one canonical row', () {
      final family = _Family()
        ..add('a')
        ..add('b')
        ..add('c')
        ..add('d');
      final initial = family.layout('a');
      var previous = initial;
      for (final id in ['d', 'b', 'c', rootTreePersonId, 'a', 'd', 'a']) {
        final current = family.layout(id, TreeTrunkMode.both, previous);
        _expectTranslatedRows(previous, current);
        expect(current.positions[id]!.crossCenter, 0);
        _expectNoOverlap(current);
        previous = current;
      }
      expect(_snapshot(previous), _snapshot(initial));
    });

    test(
      'Olga and Anastasia keep their blocks through half-sibling selection',
      () {
        for (final knownOtherParent in [false, true]) {
          for (final nataliaIsMother in [false, true]) {
            for (final parentDates in [null, 'natalia-first', 'oleg-first']) {
              final family = _lydiaFamily(
                knownOtherParent: knownOtherParent,
                nataliaIsMother: nataliaIsMother,
              );
              if (parentDates != null) {
                family
                  ..birth(
                    'natalia',
                    parentDates == 'natalia-first'
                        ? '1960-01-01'
                        : '1970-01-01',
                  )
                  ..birth(
                    'oleg',
                    parentDates == 'oleg-first' ? '1960-01-01' : '1970-01-01',
                  );
              }
              for (final date in [null, '1990-01-01']) {
                if (date != null) {
                  family
                    ..birth('olga', date)
                    ..birth('anastasia', date);
                }
                for (final mode in TreeTrunkMode.values) {
                  for (final firstId in ['olga', 'anastasia']) {
                    final initial = family.layout(firstId, mode);
                    expect(
                      _blockFor(initial, 'natalia').id,
                      _blockFor(initial, 'veronika').id,
                    );
                    expect(
                      _blockFor(initial, 'olga').id,
                      isNot(_blockFor(initial, 'anastasia').id),
                    );
                    var previous = initial;
                    final otherId = firstId == 'olga' ? 'anastasia' : 'olga';
                    for (final id in [
                      otherId,
                      firstId,
                      otherId,
                      firstId,
                      firstId,
                    ]) {
                      final current = family.layout(id, mode, previous);
                      _expectTranslatedRow(
                        previous,
                        current,
                        initial.positions['olga']!.level,
                      );
                      expect(current.positions[id]!.crossCenter, 0);
                      if (id == 'olga' && !knownOtherParent) {
                        if (mode == TreeTrunkMode.both) {
                          // Parent cards touch even when their sibling blocks
                          // need a presentation-only birth-order override.
                          _expectParentCardsAdjacent(
                            current,
                            nataliaIsMother ? 'natalia' : 'oleg',
                            nataliaIsMother ? 'oleg' : 'natalia',
                          );
                        } else {
                          // Single modes retain sibling chronology; the new
                          // role inequality can prevent a literal parent seam.
                          _expectBefore(
                            current,
                            nataliaIsMother ? 'natalia' : 'oleg',
                            nataliaIsMother ? 'oleg' : 'natalia',
                          );
                        }
                      }
                      expect(
                        _snapshot(current),
                        _snapshot(family.layout(id, mode)),
                      );
                      _expectDescendingLinks(current);
                      _expectNoOverlap(current);
                      previous = current;
                    }
                    _expectTranslatedRow(
                      initial,
                      previous,
                      initial.positions['olga']!.level,
                    );
                  }
                }
              }
            }
          }
        }
      },
    );

    test('undated and equal-date unions keep canonical order for every focus', () {
      for (final date in [null, '1990-01-01']) {
        final family = _lydiaFamily()
          ..add('third-child')
          ..add('cousin')
          ..parents('third-child', mother: 'natalia')
          ..parents('cousin', mother: 'veronika');
        if (date != null) {
          for (final id in ['olga', 'anastasia', 'third-child']) {
            family.birth(id, date);
          }
        }
        for (final mode in TreeTrunkMode.values) {
          for (final firstId in [
            'olga',
            'anastasia',
            'third-child',
            'cousin',
          ]) {
            final initial = family.layout(firstId, mode);
            var previous = initial;
            for (final id in [
              'third-child',
              'anastasia',
              'olga',
              'cousin',
              'olga',
              'third-child',
              'anastasia',
              firstId,
            ]) {
              final current = family.layout(id, mode, previous);
              // These rows contain no conflicting chronology or ancestor sides;
              // cold builds preserve the same groups, order, and relative spacing.
              final row = initial.positions['olga']!.level;
              _expectTranslatedRow(previous, current, row);
              expect(current.positions[id]!.crossCenter, 0);
              _expectNoOverlap(current);
              previous = current;
            }
            _expectTranslatedRow(
              initial,
              previous,
              initial.positions['olga']!.level,
            );
          }
        }
      }
    });

    test('date edits recompute the backbone, never preserve obsolete runs', () {
      for (final date in [null, '1990-01-01']) {
        for (final mode in TreeTrunkMode.values) {
          final family = _lydiaFamily()
            ..add('third-child')
            ..add('cousin-a')
            ..add('cousin-b')
            ..add('partner')
            ..parents('third-child', mother: 'natalia')
            ..parents('cousin-a', father: 'partner', mother: 'veronika')
            ..parents('cousin-b', father: 'partner', mother: 'veronika');
          if (date != null) {
            for (final id in ['olga', 'anastasia', 'third-child']) {
              family.birth(id, date);
            }
          }
          final initial = family.layout('olga', mode);
          family.birth('cousin-b', '1980-01-01');
          final current = family.layout('third-child', mode, initial);
          expect(
            _snapshot(current),
            _snapshot(family.layout('third-child', mode)),
          );
          expect(_blockFor(current, 'cousin-a').people.map((p) => p.id), [
            'cousin-a',
            'cousin-b',
          ]);
          expect(current.positions['third-child']!.crossCenter, 0);
          _expectDescendingLinks(current);
          _expectNoOverlap(current);
        }
      }
    });

    test('half-sibling chronology survives ancestor and focus changes', () {
      final family = _Family()
        ..add('parent')
        ..add('old')
        ..add('middle')
        ..add('young')
        ..add('child')
        ..parents('old', father: 'parent')
        ..parents('middle', father: 'parent')
        ..parents('young', father: 'parent')
        ..parents('child', father: 'middle')
        ..birth('old', '1950-01-01')
        ..birth('middle', '1960-01-01')
        ..birth('young', '1970-01-01');
      for (final mode in TreeTrunkMode.values) {
        final ancestor = family.layout('child', mode);
        expect(
          ancestor.positions['old']!.crossCenter,
          lessThan(ancestor.positions['young']!.crossCenter),
        );
        // Centering a direct ancestor no longer splits its chronological
        // parent group. Only genuinely conflicting ancestry sides may do so.
        _expectConsecutive(ancestor, ['old', 'middle', 'young']);
        final context = family.layout(rootTreePersonId, mode, ancestor);
        _expectConsecutive(context, ['old', 'middle', 'young']);
        expect(
          context.positions['old']!.crossCenter,
          lessThan(context.positions['middle']!.crossCenter),
        );
        expect(
          context.positions['middle']!.crossCenter,
          lessThan(context.positions['young']!.crossCenter),
        );
        _expectNoOverlap(context);
        var previous = context;
        for (final id in [
          'child',
          'middle',
          'child',
          rootTreePersonId,
          rootTreePersonId,
          'middle',
          'child',
        ]) {
          final current = family.layout(id, mode, previous);
          expect(_snapshot(current), _snapshot(family.layout(id, mode)));
          _expectConsecutive(current, ['old', 'middle', 'young']);
          expect(
            current.positions['old']!.crossCenter,
            lessThan(current.positions['middle']!.crossCenter),
          );
          expect(
            current.positions['middle']!.crossCenter,
            lessThan(current.positions['young']!.crossCenter),
          );
          if (id == 'child') {
            expect(
              current.positions['middle']!.trunk,
              mode != TreeTrunkMode.mother,
            );
            if (mode != TreeTrunkMode.both) {
              expect(current.positions['middle']!.crossCenter, 0);
            }
          }
          _expectNoOverlap(current);
          previous = current;
        }
      }
    });

    test(
      'mode-specific priority parents and block dates ignore previous focus',
      () {
        final family = _Family()
          ..add('father-a')
          ..add('father-b')
          ..add('mother-a')
          ..add('mother-b')
          ..birth('father-a', '1960-01-01')
          ..birth('father-b', '1980-01-01')
          ..birth('mother-a', '1950-01-01')
          ..birth('mother-b', '1970-01-01');
        for (final (id, father, mother, birth) in [
          ('aa', 'a', 'a', '2000-01-01'),
          ('ab', 'a', 'b', '2001-01-01'),
          ('ba', 'b', 'a', '2002-01-01'),
          ('bb', 'b', 'b', '2003-01-01'),
        ]) {
          family
            ..add(id)
            ..parents(id, father: 'father-$father', mother: 'mother-$mother')
            ..birth(id, birth);
        }
        for (final mode in TreeTrunkMode.values) {
          var previous = family.layout('aa', mode);
          for (final id in [rootTreePersonId, 'bb', rootTreePersonId, 'ab']) {
            final current = family.layout(id, mode, previous);
            final grouped = switch (mode) {
              TreeTrunkMode.father => [
                ['aa', 'ab'],
                ['ba', 'bb'],
              ],
              TreeTrunkMode.mother => [
                ['aa', 'ba'],
                ['ab', 'bb'],
              ],
              TreeTrunkMode.both => [
                ['aa', 'ba'],
              ],
            };
            for (final group in grouped) {
              final context = group.where((member) => member != id).toList();
              if (context.length < 2) continue;
              _expectConsecutive(current, context);
              // This four-edge parent square cannot satisfy all four parent
              // intervals. Accepting a third interval may reverse whole half-
              // sibling blocks, but never member order inside a sibling block.
              expect(_snapshot(current), _snapshot(family.layout(id, mode)));
            }
            final row = _rowPeople(current, 'aa');
            expect(
              [
                ['aa', 'ab'],
                ['ba', 'bb'],
                ['aa', 'ba'],
                ['ab', 'bb'],
              ].where(
                (group) =>
                    (row.indexOf(group.first) - row.indexOf(group.last))
                        .abs() ==
                    1,
              ),
              hasLength(3),
            );
            _expectNoOverlap(current);
            previous = current;
          }
        }
      },
    );

    test(
      'canonical neutral co-parent order already satisfies child trunk sides',
      () {
        final family = _Family()
          ..add('father')
          ..add('mother')
          ..add('child')
          ..parents('child', father: 'father', mother: 'mother');
        // Parent roles supply a stable orientation even when neither partner
        // is a direct ancestor of the current selection.
        final initial = family.layout('mother');
        expect(
          initial.positions['father']!.crossCenter,
          greaterThan(initial.positions['mother']!.crossCenter),
        );
        var previous = family.layout('child', TreeTrunkMode.both, initial);
        expect(previous.positions['mother']!.crossCenter, lessThan(0));
        expect(previous.positions['father']!.crossCenter, greaterThan(0));
        _expectNoOverlap(previous);
        final repaired = previous;
        for (final id in ['mother', 'father', 'child', 'mother', 'child']) {
          final current = family.layout(id, TreeTrunkMode.both, previous);
          _expectTranslatedRows(previous, current);
          _expectNoOverlap(current);
          previous = current;
        }
        expect(_snapshot(previous), _snapshot(repaired));
      },
    );

    test(
      'ancestor-to-context ties use canonical IDs except hard side constraints',
      () {
        for (final date in [null, '1950-01-01']) {
          final family = _distinctGrandparentFamily();
          if (date != null) {
            family
              ..birth('maternal-grand-father', date)
              ..birth('maternal-grand-mother', date);
          }
          TreeLayout build(String id, [TreeLayout? previous]) =>
              TreeLayout.build(
                family.document,
                selectedId: id,
                mode: TreeTrunkMode.both,
                nodeExtent: 108,
                previousLayout: previous,
              );
          final initial = build(rootTreePersonId);
          expect(initial.levels[1].blocks.map((b) => b.people.single.id), [
            'maternal-grand-mother',
            'maternal-grand-father',
            'grand-mother',
            'grand-father',
          ]);
          _expectParentCardsAdjacent(
            initial,
            'maternal-grand-mother',
            'maternal-grand-father',
          );
          _expectParentCardsAdjacent(initial, 'grand-mother', 'grand-father');
          final father = build('father', initial);
          _expectConsecutive(father, ['grand-mother', 'grand-father']);
          _expectBefore(
            father,
            'maternal-grand-mother',
            'maternal-grand-father',
          );
          // Even context co-parents retain their role orientation. A shared
          // ancestor above this pair is not itself an ordering preference.
          expect(father.positions['grand-mother']!.crossCenter, lessThan(0));
          expect(father.positions['grand-father']!.crossCenter, greaterThan(0));
          expect(
            father.positions['maternal-grand-mother']!.crossCenter -
                father.positions['maternal-grand-father']!.crossCenter,
            (initial.positions['maternal-grand-mother']!.crossCenter -
                initial.positions['maternal-grand-father']!.crossCenter),
          );
          expect(_snapshot(father), _snapshot(build('father')));
          _expectConsecutive(father, [
            'maternal-grand-mother',
            'maternal-grand-father',
          ]);
          _expectNoOverlap(father);
          var previous = father;
          for (final id in [
            'mother',
            rootTreePersonId,
            'sibling',
            'father',
            'mother',
            rootTreePersonId,
            'father',
            'mother',
            'sibling',
            rootTreePersonId,
          ]) {
            final current = build(id, previous);
            expect(_snapshot(current), _snapshot(build(id)));
            _expectDescendingLinks(current);
            _expectNoOverlap(current);
            previous = current;
          }
        }
      },
    );

    test('context birth edits and date ties always use current document', () {
      final family = _distinctGrandparentFamily();
      final initial = family.layout(rootTreePersonId);
      final father = family.layout('father', TreeTrunkMode.both, initial);
      _expectBefore(father, 'maternal-grand-mother', 'maternal-grand-father');
      expect(_snapshot(father), _snapshot(family.layout('father')));
      family
        ..birth('maternal-grand-father', '1940-01-01')
        ..birth('maternal-grand-mother', '1950-01-01');
      final chronological = family.layout('father', TreeTrunkMode.both, father);
      _expectBefore(
        chronological,
        'maternal-grand-mother',
        'maternal-grand-father',
      );
      expect(
        chronological.positions['maternal-grand-father']!.personId,
        'maternal-grand-father',
      );
      expect(
        _blockFor(
          chronological,
          'maternal-grand-father',
        ).people.single.birthDate,
        DateTime.utc(1940),
      );
      _expectConsecutive(chronological, [
        'maternal-grand-father',
        'maternal-grand-mother',
      ]);
      _expectNoOverlap(chronological);

      // Direct co-parent orientation supersedes their dates/ID tie. Unrelated
      // context still recomputes ordinary chronology from the current document.
      family.birth('maternal-grand-mother', '1930-01-01');
      final olderMother = family.layout(
        'father',
        TreeTrunkMode.both,
        chronological,
      );
      expect(
        olderMother.positions['maternal-grand-mother']!.crossCenter,
        lessThan(olderMother.positions['maternal-grand-father']!.crossCenter),
      );
      family.birth('maternal-grand-father', '1930-01-01');
      final editedTie = family.layout(
        'father',
        TreeTrunkMode.both,
        olderMother,
      );
      _expectBefore(
        editedTie,
        'maternal-grand-mother',
        'maternal-grand-father',
      );
      _expectNoOverlap(editedTie);
      family
        ..add('context-a')
        ..add('context-b')
        ..birth('context-b', '1940-01-01');
      final datedContext = family.layout(
        'father',
        TreeTrunkMode.both,
        editedTie,
      );
      // An unknown birth is considered older even than a known early date.
      _expectBefore(datedContext, 'context-a', 'context-b');
      family.birth('context-a', '1930-01-01');
      final editedContext = family.layout(
        'father',
        TreeTrunkMode.both,
        datedContext,
      );
      _expectBefore(editedContext, 'context-a', 'context-b');
      family.birth('context-b', '1930-01-01');
      final contextTie = family.layout(
        'father',
        TreeTrunkMode.both,
        editedContext,
      );
      _expectBefore(contextTie, 'context-a', 'context-b');
      expect(_snapshot(contextTie), _snapshot(family.layout('father')));
    });

    test('document edits recompute birth order and use fresh person data', () {
      final family = _siblingContextFamily()
        ..birth('a', '2005-01-01')
        ..birth('b', '2010-01-01');
      final initial = family.layout('a');
      family.birth('b', '2000-01-01');
      final reordered = family.layout('a', TreeTrunkMode.both, initial);
      expect(_blockFor(reordered, 'a').people.map((person) => person.id), [
        'b',
        'a',
      ]);
      expect(reordered.positions['a']!.crossCenter, 0);
      expect(reordered.positions['b']!.crossCenter, -120);
      expect(_blockFor(initial, 'a').people.map((person) => person.id), [
        'a',
        'b',
      ]);
      expect(
        _blockFor(reordered, 'b').people.first.birthDate,
        DateTime.utc(2000),
      );
      _expectNoOverlap(reordered);
      family.birth('b', '2001-01-01');
      final current = family.layout('b', TreeTrunkMode.both, reordered);
      _expectTranslatedRows(reordered, current);
      expect(
        _blockFor(current, 'b').people.first.birthDate,
        DateTime.utc(2001),
      );
      _expectNoOverlap(current);
    });

    test(
      'one-sided trunk bounds contain the origin independent of focus history',
      () {
        for (final maternal in [false, true]) {
          final family = _Family()
            ..add('parent')
            ..parents(
              rootTreePersonId,
              father: maternal ? null : 'parent',
              mother: maternal ? 'parent' : null,
            );
          final initial = family.layout(rootTreePersonId);
          final firstRow = initial.levels.first;
          expect(maternal ? firstRow.maxCross : firstRow.minCross, 0);
          var previous = initial;
          for (final id in [
            rootTreePersonId,
            'parent',
            rootTreePersonId,
            'parent',
            rootTreePersonId,
          ]) {
            final current = family.layout(id, TreeTrunkMode.both, previous);
            expect(_snapshot(current), _snapshot(family.layout(id)));
            for (final row in current.levels) {
              expect(row.minCross, lessThanOrEqualTo(0));
              expect(row.maxCross, greaterThanOrEqualTo(0));
            }
            _expectNoOverlap(current);
            if (id == rootTreePersonId) {
              expect(_snapshot(current), _snapshot(initial));
            }
            previous = current;
          }
        }
      },
    );

    test(
      'focus cycles preserve compatible trunk sides and shared ancestor unions',
      () {
        final family = _Family()
          ..add('shared-father')
          ..add('shared-mother')
          ..add('aunt')
          ..add('uncle')
          ..add('mother')
          ..add('father')
          ..add('sibling')
          ..parents('aunt', father: 'shared-father', mother: 'shared-mother')
          ..parents('uncle', father: 'shared-father', mother: 'shared-mother')
          ..parents('mother', mother: 'aunt')
          ..parents('father', father: 'uncle')
          ..parents(rootTreePersonId, father: 'father', mother: 'mother')
          ..parents('sibling', father: 'father', mother: 'mother');
        for (final mode in TreeTrunkMode.values) {
          var previous = family.layout(rootTreePersonId, mode);
          for (final id in [
            'sibling',
            'mother',
            'father',
            rootTreePersonId,
            'sibling',
            'father',
            'mother',
            rootTreePersonId,
          ]) {
            final current = family.layout(id, mode, previous);
            expect(current.positions, hasLength(family.document.people.length));
            expect(
              _blockFor(current, 'aunt').id,
              _blockFor(current, 'uncle').id,
            );
            if (id == rootTreePersonId || id == 'sibling') {
              if (mode == TreeTrunkMode.both) {
                expect(current.positions['mother']!.crossCenter, lessThan(0));
                expect(
                  current.positions['father']!.crossCenter,
                  greaterThan(0),
                );
                expect(
                  current.positions['shared-father']!.branch,
                  TreeBranch.both,
                );
                expect(current.positions['shared-father']!.crossCenter, 0);
              } else {
                final chain = mode == TreeTrunkMode.father
                    ? ['father', 'uncle', 'shared-father']
                    : ['mother', 'aunt', 'shared-mother'];
                for (final ancestor in chain) {
                  expect(current.positions[ancestor]!.crossCenter, 0);
                }
              }
            }
            _expectNoOverlap(current);
            previous = current;
          }
        }
      },
    );

    test('generation ranks and genuine long edges ignore previous focus', () {
      final family = _Family()
        ..add('old')
        ..add('grandparent')
        ..add('parent')
        ..add('partner')
        ..add('child')
        ..parents('grandparent', father: 'old')
        ..parents('parent', father: 'grandparent')
        ..parents('partner', father: 'parent')
        ..parents('child', father: 'old', mother: 'partner');
      for (final mode in TreeTrunkMode.values) {
        var previous = family.layout('child', mode);
        for (final id in [
          'old',
          'partner',
          'parent',
          'child',
          'old',
          'child',
        ]) {
          final current = family.layout(id, mode, previous);
          for (final person in family.document.people.keys) {
            expect(
              current.positions[person]!.level,
              previous.positions[person]!.level,
            );
          }
          expect(current.positions['old']!.level, 0);
          expect(current.positions['partner']!.level, 3);
          expect(current.positions['child']!.level, 4);
          expect(
            current.links.map((link) => '${link.parentId}->${link.childId}'),
            containsAll(['old->child', 'partner->child']),
          );
          for (final link in current.links) {
            expect(
              current.positions[link.parentId]!.level,
              lessThan(current.positions[link.childId]!.level),
            );
            expect(link.blockId, current.positions[link.childId]!.blockId);
          }
          _expectNoOverlap(current);
          previous = current;
        }
      }
    });

    test('mode and metric changes never consult previous layouts', () {
      final family = _siblingContextFamily();
      final previous = family.layout('a');
      for (final (mode, extent, gap) in [
        (TreeTrunkMode.father, 96.0, 24.0),
        (TreeTrunkMode.mother, 96.0, 24.0),
        (TreeTrunkMode.both, 80.0, 24.0),
        (TreeTrunkMode.both, 96.0, 10.0),
      ]) {
        TreeLayout build(TreeLayout? history) => TreeLayout.build(
          family.document,
          selectedId: 'b',
          mode: mode,
          nodeExtent: extent,
          gap: gap,
          previousLayout: history,
        );
        expect(_snapshot(build(previous)), _snapshot(build(null)));
        _expectNoOverlap(build(previous));
      }
    });

    test('structure edits always match a fresh canonical layout', () {
      for (final edit in ['add', 'parents', 'rank']) {
        final family = _siblingContextFamily();
        final previous = family.layout('a');
        switch (edit) {
          case 'add':
            family
              ..add('new-sibling')
              ..parents('new-sibling', father: 'father', mother: 'mother');
          case 'parents':
            family.parents('b', mother: 'other-parent');
          case 'rank':
            family.parents('other-parent', father: 'father');
        }
        final current = family.layout('b', TreeTrunkMode.both, previous);
        expect(_snapshot(current), _snapshot(family.layout('b')));
        _expectNoOverlap(current);
      }
    });

    test(
      'Nikita–Olga–Nikita is canonical with selected parent block priority',
      () {
        for (final lydiaFather in [false, true]) {
          for (final reverseInsertion in [false, true]) {
            final family = _cousinFamily(
              lydiaFather: lydiaFather,
              reverseInsertion: reverseInsertion,
            );
            for (final mode in TreeTrunkMode.values) {
              for (final (extent, gap) in [
                (96.0, 24.0),
                (108.0, 24.0),
                (83.5, 7.25),
                (80.0, 0.0),
              ]) {
                TreeLayout build(String id, [TreeLayout? previous]) =>
                    TreeLayout.build(
                      family.document,
                      selectedId: id,
                      mode: mode,
                      nodeExtent: extent,
                      gap: gap,
                      previousLayout: previous,
                    );
                final initial = build('nikita');
                final row = initial.levels.firstWhere(
                  (row) => row.index == initial.positions['veronika']!.level,
                );
                expect(
                  row.blocks.expand((b) => b.people).map((p) => p.id),
                  mode == TreeTrunkMode.both
                      ? ['natalia', 'veronika', 'roman', 'oleg']
                      : ['natalia', 'veronika', 'oleg', 'roman'],
                );
                if (mode == TreeTrunkMode.both) {
                  _expectParentCardsAdjacent(initial, 'veronika', 'roman');
                } else {
                  // Both mothers must precede their co-parent. With rigid
                  // sibling chronology, both couples cannot also touch.
                  _expectBefore(initial, 'natalia', 'oleg');
                  _expectBefore(initial, 'veronika', 'roman');
                }
                _expectAdjacentPeople(initial, 'gennady', 'lydia');
                var previous = initial;
                for (final id in [
                  rootTreePersonId,
                  'nikita',
                  'anastasia',
                  'natalia',
                  'veronika',
                  rootTreePersonId,
                  'nikita',
                ]) {
                  final current = build(id, previous);
                  expect(_snapshot(current), _snapshot(build(id)));
                  _expectSameRanks(initial, current);
                  _expectDescendingLinks(current);
                  _expectNoOverlap(current);
                  if (mode == TreeTrunkMode.both) {
                    final person = family.document.people[id]!;
                    if (person.motherId != null && person.fatherId != null) {
                      _expectParentCardsAdjacent(
                        current,
                        person.motherId!,
                        person.fatherId!,
                      );
                    }
                    if (id == rootTreePersonId) {
                      expect(_rowPeople(current, 'natalia'), [
                        'veronika',
                        'natalia',
                        'oleg',
                        'roman',
                      ]);
                    }
                  } else {
                    _expectBefore(current, 'natalia', 'oleg');
                    _expectBefore(current, 'veronika', 'roman');
                    // Single modes now refine the selected person's own
                    // partners before siblings' partners; those legal block
                    // moves need not preserve the old focus-independent row.
                    if (id == 'natalia') {
                      _expectConsecutive(current, ['natalia', 'oleg']);
                    } else if (id == 'veronika') {
                      _expectConsecutive(current, ['veronika', 'roman']);
                    }
                    expect(
                      _blockFor(current, 'natalia').people.map((p) => p.id),
                      ['natalia', 'veronika'],
                    );
                  }
                  _expectAdjacentPeople(current, 'gennady', 'lydia');
                  if (id == 'nikita') {
                    expect(_snapshot(current), _snapshot(initial));
                    if (mode == TreeTrunkMode.both) {
                      _expectParentCardsAdjacent(current, 'veronika', 'roman');
                    } else {
                      _expectBefore(current, 'veronika', 'roman');
                    }
                  }
                  previous = current;
                }
              }
            }
          }
        }
      },
    );

    test(
      'Anastasia prioritizes Nekto on the right without splitting the sisters',
      () {
        for (final reverseInsertion in [false, true]) {
          for (final dates in [
            'unknown',
            'equal',
            'natalia-first',
            'veronika-first',
          ]) {
            final family = _cousinFamily(
              lydiaFather: true,
              reverseInsertion: reverseInsertion,
              anastasiaFather: true,
            );
            if (dates != 'unknown') {
              family
                ..birth(
                  'natalia',
                  dates == 'veronika-first' ? '1970-01-01' : '1960-01-01',
                )
                ..birth(
                  'veronika',
                  dates == 'natalia-first' ? '1970-01-01' : '1960-01-01',
                );
            }
            final birthOrder = dates == 'veronika-first'
                ? ['veronika', 'natalia']
                : ['natalia', 'veronika'];
            for (final (extent, gap) in [
              (96.0, 24.0),
              (108.0, 24.0),
              (83.5, 7.25),
              (80.0, 0.0),
            ]) {
              TreeLayout build(String id, [TreeLayout? previous]) =>
                  TreeLayout.build(
                    family.document,
                    selectedId: id,
                    mode: TreeTrunkMode.both,
                    nodeExtent: extent,
                    gap: gap,
                    previousLayout: previous,
                  );
              final initial = build('anastasia');
              final olga = build(rootTreePersonId);
              // A cold focus change swaps equal-width father slots, not the
              // shared mother block or the whole parent row's model origin.
              final parents = _rowPeople(initial, 'natalia');
              for (final id in parents.where(
                (id) => id != 'oleg' && id != 'nekto',
              )) {
                expect(
                  olga.positions[id]!.crossCenter,
                  initial.positions[id]!.crossCenter,
                  reason: '$dates: $id must stay anchored',
                );
              }
              expect(
                olga.positions['oleg']!.crossCenter,
                initial.positions['nekto']!.crossCenter,
              );
              expect(
                olga.positions['nekto']!.crossCenter,
                initial.positions['oleg']!.crossCenter,
              );
              expect(
                _blockFor(olga, 'natalia').start,
                _blockFor(initial, 'natalia').start,
              );
              expect(
                _blockFor(olga, 'natalia').id,
                _blockFor(initial, 'natalia').id,
              );
              _expectParentCardsAdjacent(olga, 'natalia', 'oleg');
              var previous = initial;
              for (final id in [
                'nikita',
                rootTreePersonId,
                'anastasia',
                'nekto',
                'anastasia',
                rootTreePersonId,
                'nikita',
                'anastasia',
              ]) {
                final current = build(id, previous);
                final person = family.document.people[id]!;
                if (person.motherId != null && person.fatherId != null) {
                  _expectParentCardsAdjacent(
                    current,
                    person.motherId!,
                    person.fatherId!,
                  );
                }
                expect(
                  _blockFor(current, 'natalia').people.map((p) => p.id),
                  id == 'anastasia' || id == rootTreePersonId
                      ? ['veronika', 'natalia']
                      : id == 'nikita'
                      ? ['natalia', 'veronika']
                      : birthOrder,
                  reason: '$dates / $id: ${_rowPeople(current, id)}',
                );
                if (id == 'anastasia' && dates != 'veronika-first') {
                  expect(_rowPeople(current, 'natalia'), [
                    'veronika',
                    'natalia',
                    'nekto',
                    'oleg',
                    'roman',
                  ]);
                }
                expect(_snapshot(current), _snapshot(build(id)));
                _expectSameRanks(initial, current);
                _expectDescendingLinks(current);
                _expectNoOverlap(current);
                previous = current;
              }
              expect(_snapshot(previous), _snapshot(initial));
            }
          }
        }
      },
    );

    test(
      'Roman and Veronika keep focused blocks adjacent without reordering sisters',
      () {
        for (final reverseInsertion in [false, true]) {
          for (final dates in [
            'unknown',
            'equal',
            'natalia-first',
            'veronika-first',
          ]) {
            final family = _cousinFamily(
              lydiaFather: true,
              reverseInsertion: reverseInsertion,
              anastasiaFather: true,
            );
            if (dates != 'unknown') {
              family
                ..birth(
                  'natalia',
                  dates == 'veronika-first' ? '1970-01-01' : '1960-01-01',
                )
                ..birth(
                  'veronika',
                  dates == 'natalia-first' ? '1970-01-01' : '1960-01-01',
                );
            }
            final people = family.document.people;
            for (final (extent, gap) in [
              (96.0, 24.0),
              (108.0, 24.0),
              (83.5, 7.25),
              (80.0, 0.0),
            ]) {
              TreeLayout build(String id, [TreeLayout? previous]) =>
                  TreeLayout.build(
                    family.document,
                    selectedId: id,
                    mode: TreeTrunkMode.both,
                    nodeExtent: extent,
                    gap: gap,
                    previousLayout: previous,
                  );
              final initial = build('roman');
              if (dates == 'unknown' || dates == 'equal') {
                expect(_rowPeople(initial, 'roman'), [
                  'natalia',
                  'veronika',
                  'roman',
                  'nekto',
                  'oleg',
                ]);
                expect(_rowPeople(build('nikita'), 'roman'), [
                  'natalia',
                  'veronika',
                  'roman',
                  'oleg',
                  'nekto',
                ]);
              }
              var previous = initial;
              for (final id in [
                'veronika',
                rootTreePersonId,
                'anastasia',
                'natalia',
                'nikita',
                'roman',
                'veronika',
                'roman',
              ]) {
                final current = build(id, previous);
                expect(_snapshot(current), _snapshot(build(id)));
                expect(current.positions[id]!.crossCenter, 0);
                if (id == 'roman' || id == 'veronika') {
                  _expectConsecutive(current, ['veronika', 'roman']);
                  _expectBefore(current, 'veronika', 'roman');
                  if (dates != 'veronika-first') {
                    _expectParentCardsAdjacent(current, 'veronika', 'roman');
                  } else {
                    // Co-parent focus may move the blocks, but cannot move
                    // Veronika past her younger sister to expose a card seam.
                    final row = _rowPeople(current, 'veronika');
                    expect(row.indexOf('roman') - row.indexOf('veronika'), 2);
                  }
                  expect(
                    _blockFor(current, 'veronika').people.map((p) => p.id),
                    dates == 'veronika-first'
                        ? ['veronika', 'natalia']
                        : ['natalia', 'veronika'],
                  );
                  _expectTranslatedRow(
                    initial,
                    current,
                    initial.positions['roman']!.level,
                  );
                }
                _expectSameRanks(initial, current);
                expect(
                  current.links.map((e) => (e.parentId, e.childId, e.blockId)),
                  initial.links.map((e) => (e.parentId, e.childId, e.blockId)),
                );
                _expectDescendingLinks(current);
                _expectNoOverlap(current);
                previous = current;
              }
              expect(_snapshot(previous), _snapshot(initial));
              for (final mode in [TreeTrunkMode.father, TreeTrunkMode.mother]) {
                final single = family.layout('roman', mode, initial);
                expect(
                  _blockFor(single, 'veronika').people.map((p) => p.id),
                  dates == 'veronika-first'
                      ? ['veronika', 'natalia']
                      : ['natalia', 'veronika'],
                );
                _expectSameRanks(initial, single);
                expect(
                  single.links.map((e) => (e.parentId, e.childId, e.blockId)),
                  initial.links.map((e) => (e.parentId, e.childId, e.blockId)),
                );
              }
            }
            expect(identical(family.document.people, people), isTrue);
          }
        }
      },
    );

    test(
      'Natalia keeps both co-parents compact without bringing Roman inside',
      () {
        final family = _cousinFamily(anastasiaFather: true);
        final context = family.layout(rootTreePersonId);
        final selected = family.layout('natalia', TreeTrunkMode.both, context);
        _expectConsecutive(selected, ['natalia', 'oleg', 'nekto']);
        final row = _rowPeople(selected, 'natalia');
        expect(row, ['natalia', 'veronika', 'nekto', 'oleg', 'roman']);
        final slots = [
          for (final id in ['natalia', 'oleg', 'nekto']) row.indexOf(id),
        ]..sort();
        expect(
          row.indexOf('roman'),
          isNot(inInclusiveRange(slots.first, slots.last)),
        );
        expect(
          _blockFor(selected, 'natalia').id,
          _blockFor(context, 'natalia').id,
        );
        expect(
          _blockFor(selected, 'natalia').extent,
          _blockFor(context, 'natalia').extent,
        );
        _expectSameRanks(context, selected);
        _expectNoOverlap(selected);
      },
    );

    test(
      'multiple partners form one compact component in either parent role',
      () {
        for (final selectedIsMother in [false, true]) {
          for (final reverseInsertion in [false, true]) {
            final family = _Family();
            final ids = [
              'selected',
              'partner-a',
              'partner-b',
              'partner-c',
              'partner-d',
              'unrelated-a',
              'unrelated-b',
              'unrelated-child',
              for (var i = 0; i < 4; i++) 'child-$i',
            ];
            for (final id in reverseInsertion ? ids.reversed : ids) {
              family.add(id);
            }
            final partners = [
              'partner-a',
              'partner-b',
              'partner-c',
              'partner-d',
            ];
            for (final (i, partner) in partners.indexed) {
              family.parents(
                'child-$i',
                mother: selectedIsMother ? 'selected' : partner,
                father: selectedIsMother ? partner : 'selected',
              );
            }
            family.parents(
              'unrelated-child',
              mother: 'unrelated-a',
              father: 'unrelated-b',
            );
            final initial = family.layout('selected');
            _expectConsecutive(initial, ['selected', ...partners]);
            _expectParentCardsAdjacent(initial, 'unrelated-a', 'unrelated-b');
            // All four partners have the same opposite parent role, so they
            // must stay on one side. Only one can touch the selected card.
            final row = _rowPeople(initial, 'selected');
            final selectedIndex = row.indexOf('selected');
            expect(
              partners.where(
                (p) => (row.indexOf(p) - selectedIndex).abs() == 1,
              ),
              hasLength(1),
            );
            for (final partner in partners) {
              _expectBefore(
                initial,
                selectedIsMother ? 'selected' : partner,
                selectedIsMother ? partner : 'selected',
              );
            }
            expect(initial.links, hasLength(10));
            expect(
              _snapshot(initial),
              _snapshot(family.layout('selected', TreeTrunkMode.both, initial)),
            );
            _expectDescendingLinks(initial);
            _expectNoOverlap(initial);
          }
        }
      },
    );

    test('selected partner ordering never uses the shared children IDs', () {
      List<Object> parentRow(bool reverseChildren, bool reverseInsertion) {
        final family = _Family();
        final ids = [
          'selected',
          'partner-a',
          'partner-b',
          'partner-c',
          'unrelated',
          'a-child',
          'm-child',
          'z-child',
        ];
        for (final id in reverseInsertion ? ids.reversed : ids) {
          family.add(id);
        }
        final children = ['a-child', 'm-child', 'z-child'];
        for (final (i, child)
            in (reverseChildren ? children.reversed : children).indexed) {
          family.parents(
            child,
            mother: ['partner-a', 'partner-b', 'partner-c'][i],
            father: 'selected',
          );
        }
        final layout = family.layout('selected');
        _expectConsecutive(layout, [
          'selected',
          'partner-a',
          'partner-b',
          'partner-c',
        ]);
        return [
          for (final id in _rowPeople(layout, 'selected'))
            (id, layout.positions[id]!.crossCenter),
        ];
      }

      final canonical = parentRow(false, false);
      for (final reverseChildren in [false, true]) {
        for (final reverseInsertion in [false, true]) {
          expect(parentRow(reverseChildren, reverseInsertion), canonical);
        }
      }
    });

    test(
      'focused boundary repair keeps compatible independent sibling seams',
      () {
        _Family make(bool independentMotherOutside) => _Family()
          ..add('grandfather')
          ..add('grandmother')
          ..add('partner')
          ..add('partner-sibling')
          ..add('sibling-partner')
          ..add('selected')
          ..add('other-partner')
          ..add('child-a')
          ..add('child-b')
          ..add('cousin')
          ..parents('partner', father: 'grandfather', mother: 'grandmother')
          ..parents(
            'partner-sibling',
            father: 'grandfather',
            mother: 'grandmother',
          )
          ..parents('child-a', mother: 'partner', father: 'selected')
          ..parents('child-b', mother: 'other-partner', father: 'selected')
          ..parents(
            'cousin',
            mother: independentMotherOutside
                ? 'sibling-partner'
                : 'partner-sibling',
            father: independentMotherOutside
                ? 'partner-sibling'
                : 'sibling-partner',
          )
          ..birth('partner', '1960-01-01')
          ..birth('partner-sibling', '1970-01-01');
        for (final independentMotherOutside in [false, true]) {
          final selected = make(independentMotherOutside).layout('selected');
          _expectConsecutive(selected, [
            'partner',
            'selected',
            'other-partner',
          ]);
          _expectBefore(selected, 'partner', 'selected');
          _expectBefore(selected, 'other-partner', 'selected');
          _expectBefore(
            selected,
            independentMotherOutside ? 'sibling-partner' : 'partner-sibling',
            independentMotherOutside ? 'partner-sibling' : 'sibling-partner',
          );
          expect(_blockFor(selected, 'partner').people.map((p) => p.id), [
            'partner',
            'partner-sibling',
          ]);
          if (independentMotherOutside) {
            // The independent couple's blocks still touch, but chronology keeps
            // the older partner between its mother and father cards.
            _expectConsecutive(selected, [
              'sibling-partner',
              'partner-sibling',
            ]);
          } else {
            // Keeping focused blocks compact and both mothers left makes the
            // outside card seam impossible; neither sibling may be reordered.
            expect(_rowPeople(selected, 'selected'), [
              'partner',
              'partner-sibling',
              'other-partner',
              'selected',
              'sibling-partner',
            ]);
          }
          _expectDescendingLinks(selected);
          _expectNoOverlap(selected);
        }
      },
    );

    test(
      'an already exposed selected partner leaves the rest of its row alone',
      () {
        final family = _Family()
          ..add('a-context')
          ..add('mother')
          ..add('father')
          ..add('z-context')
          ..add('child')
          ..parents('child', mother: 'mother', father: 'father');
        final context = family.layout(rootTreePersonId);
        for (final id in ['mother', 'father']) {
          final focused = family.layout(id);
          _expectParentCardsAdjacent(focused, 'mother', 'father');
          _expectTranslatedRow(context, focused, context.positions[id]!.level);
        }
      },
    );

    test(
      'focus proximity retains incompatible ancestor seams and long links',
      () {
        final family = _Family()
          ..add('a-grandfather')
          ..add('z-grandfather')
          ..add('grandmother')
          ..add('a-parent')
          ..add('z-parent')
          ..add('selected')
          ..add('partner')
          ..add('child')
          ..add('long-child')
          ..parents('a-parent', father: 'z-grandfather', mother: 'grandmother')
          ..parents('z-parent', father: 'a-grandfather', mother: 'grandmother')
          ..parents('selected', father: 'a-parent', mother: 'z-parent')
          ..parents('child', father: 'selected', mother: 'partner')
          ..parents('long-child', father: 'selected', mother: 'grandmother');
        final initial = family.layout('selected');
        _expectParentCardsAdjacent(initial, 'z-parent', 'a-parent');
        _expectParentCardsAdjacent(initial, 'grandmother', 'a-grandfather');
        _expectBefore(initial, 'a-grandfather', 'z-grandfather');
        _expectParentCardsAdjacent(initial, 'partner', 'selected');
        expect(
          initial.positions['grandmother']!.level,
          lessThan(initial.positions['selected']!.level),
        );
        expect(
          initial.links.map((e) => (e.parentId, e.childId)),
          containsAll([
            ('grandmother', 'long-child'),
            ('selected', 'long-child'),
          ]),
        );
        for (final mode in TreeTrunkMode.values) {
          for (final id in family.document.people.keys) {
            final prior = family.layout(id, mode);
            expect(
              _snapshot(family.layout('selected', TreeTrunkMode.both, prior)),
              _snapshot(initial),
            );
            _expectSameRanks(initial, prior);
            _expectDescendingLinks(prior);
            _expectNoOverlap(prior);
          }
        }
      },
    );

    test('parent-card boundaries override all sibling birth-date orders', () {
      const orders = [
        ['old', 'parent', 'young'],
        ['old', 'young', 'parent'],
        ['parent', 'old', 'young'],
        ['parent', 'young', 'old'],
        ['young', 'old', 'parent'],
        ['young', 'parent', 'old'],
      ];
      for (var maternalDates = 0; maternalDates < 8; maternalDates++) {
        for (var paternalDates = 0; paternalDates < 8; paternalDates++) {
          final family = _Family();
          final chronology = <String, List<String>>{};
          for (final (side, dates) in [
            ('maternal', maternalDates),
            ('paternal', paternalDates),
          ]) {
            family
              ..add('$side-grandfather')
              ..add('$side-grandmother');
            final names = dates < orders.length ? orders[dates] : orders.first;
            chronology[side] = [for (final name in names) '$side-$name'];
            for (final (index, name) in names.indexed) {
              family
                ..add('$side-$name')
                ..parents(
                  '$side-$name',
                  father: '$side-grandfather',
                  mother: '$side-grandmother',
                );
              if (dates < 7) {
                family.birth(
                  '$side-$name',
                  '${dates == 6 ? 1960 : 1960 + index * 5}-01-01',
                );
              }
            }
          }
          family.parents(
            rootTreePersonId,
            father: 'paternal-parent',
            mother: 'maternal-parent',
          );
          final people = family.document.people;
          final layout = family.layout(rootTreePersonId);
          _expectParentCardsAdjacent(
            layout,
            'maternal-parent',
            'paternal-parent',
          );
          expect(layout.positions['maternal-parent']!.crossCenter, lessThan(0));
          expect(
            layout.positions['paternal-parent']!.crossCenter,
            greaterThan(0),
          );
          expect(_blockFor(layout, 'maternal-parent').people.map((p) => p.id), [
            ...chronology['maternal']!.where((id) => id != 'maternal-parent'),
            'maternal-parent',
          ]);
          expect(_blockFor(layout, 'paternal-parent').people.map((p) => p.id), [
            'paternal-parent',
            ...chronology['paternal']!.where((id) => id != 'paternal-parent'),
          ]);
          for (final mode in [TreeTrunkMode.father, TreeTrunkMode.mother]) {
            final single = family.layout(rootTreePersonId, mode, layout);
            for (final side in chronology.keys) {
              final block = _blockFor(single, '$side-parent');
              expect(block.people.map((p) => p.id), chronology[side]);
              expect(block.id, _blockFor(layout, '$side-parent').id);
              expect(block.extent, _blockFor(layout, '$side-parent').extent);
            }
            _expectSameRanks(layout, single);
            expect(
              single.links.map(
                (link) => (link.parentId, link.childId, link.blockId),
              ),
              layout.links.map(
                (link) => (link.parentId, link.childId, link.blockId),
              ),
            );
            _expectNoOverlap(single);
          }
          expect(identical(family.document.people, people), isTrue);
          _expectDescendingLinks(layout);
          _expectNoOverlap(layout);
        }
      }
    });

    test('same-block parents become an adjacent maternal/paternal pair', () {
      for (final dates in [
        'unknown',
        'equal',
        'mother-first',
        'father-first',
      ]) {
        final family = _Family()
          ..add('grandfather')
          ..add('grandmother');
        for (final id in ['a', 'father', 'middle', 'mother', 'z']) {
          family
            ..add(id)
            ..parents(id, father: 'grandfather', mother: 'grandmother');
          if (dates == 'equal') family.birth(id, '1980-01-01');
        }
        family.parents(rootTreePersonId, father: 'father', mother: 'mother');
        if (dates.endsWith('-first')) {
          family
            ..birth('a', '1960-01-01')
            ..birth('middle', '1982-01-01')
            ..birth('z', '1990-01-01')
            ..birth(
              'father',
              dates == 'father-first' ? '1980-01-01' : '1985-01-01',
            )
            ..birth(
              'mother',
              dates == 'mother-first' ? '1980-01-01' : '1985-01-01',
            );
        }
        final initial = family.layout(rootTreePersonId);
        expect(_blockFor(initial, 'father').people.map((p) => p.id), [
          'a',
          'mother',
          'father',
          'middle',
          'z',
        ]);
        _expectParentCardsAdjacent(initial, 'mother', 'father');
        _expectParentCardsAdjacent(initial, 'grandmother', 'grandfather');
        expect(
          initial.positions['father']!.blockId,
          initial.positions['mother']!.blockId,
        );
        expect(initial.positions['mother']!.crossCenter, lessThan(0));
        expect(initial.positions['father']!.crossCenter, greaterThan(0));
        for (final mode in TreeTrunkMode.values) {
          for (final id in ['mother', 'father', 'middle', rootTreePersonId]) {
            final prior = family.layout(id, mode, initial);
            final roundTrip = family.layout(
              rootTreePersonId,
              TreeTrunkMode.both,
              prior,
            );
            expect(_snapshot(roundTrip), _snapshot(initial));
            expect(
              _blockFor(prior, 'father').id,
              _blockFor(initial, 'father').id,
            );
            _expectSameRanks(initial, prior);
            _expectDescendingLinks(roundTrip);
            _expectNoOverlap(roundTrip);
          }
        }
      }
    });

    test(
      'ancestor seams yield only to incompatible common-descendant roles',
      () {
        final family = _Family()
          ..add('a-grandfather')
          ..add('z-grandfather')
          ..add('grandmother')
          ..add('a-parent')
          ..add('z-parent')
          ..parents('a-parent', father: 'z-grandfather', mother: 'grandmother')
          ..parents('z-parent', father: 'a-grandfather', mother: 'grandmother')
          ..parents(rootTreePersonId, father: 'a-parent', mother: 'z-parent');
        final initial = family.layout(rootTreePersonId);
        _expectParentCardsAdjacent(initial, 'z-parent', 'a-parent');
        // The shared grandmother precedes both fathers. Maternal a-grandfather
        // must precede paternal z-grandfather, so the old child-ID-first seam
        // grandmother/z-grandfather is no longer compatible.
        _expectParentCardsAdjacent(initial, 'grandmother', 'a-grandfather');
        _expectBefore(initial, 'a-grandfather', 'z-grandfather');
        final grandparents = _rowPeople(initial, 'grandmother');
        expect(
          grandparents.indexOf('z-grandfather') -
              grandparents.indexOf('grandmother'),
          isNot(1),
        );
        for (final mode in TreeTrunkMode.values) {
          for (final id in family.document.people.keys) {
            final prior = family.layout(id, mode);
            final current = family.layout(
              rootTreePersonId,
              TreeTrunkMode.both,
              prior,
            );
            expect(_snapshot(current), _snapshot(initial));
            _expectSameRanks(initial, current);
            _expectDescendingLinks(current);
            _expectNoOverlap(current);
          }
        }
      },
    );

    test('compatible ancestor seams still use nearest child-ID priority', () {
      final family = _Family()
        ..add('a-grandfather')
        ..add('z-grandfather')
        ..add('grandmother')
        ..add('a-parent')
        ..add('z-parent')
        ..add('opposite-child')
        ..parents('a-parent', father: 'z-grandfather', mother: 'grandmother')
        ..parents('z-parent', father: 'a-grandfather', mother: 'grandmother')
        ..parents(rootTreePersonId, father: 'a-parent', mother: 'z-parent')
        ..parents('opposite-child', father: 'z-parent', mother: 'a-parent');
      // The equally near opposite descendant cancels the inferred grandfather
      // inequality. The original child-ID-first ancestral seam is feasible again.
      final layout = family.layout(rootTreePersonId);
      _expectParentCardsAdjacent(layout, 'z-parent', 'a-parent');
      _expectParentCardsAdjacent(layout, 'grandmother', 'z-grandfather');
      _expectDescendingLinks(layout);
      _expectNoOverlap(layout);
    });

    test('every prior focus and mode produces exactly the cold layout', () {
      for (final anastasiaFather in [false, true]) {
        final family = _cousinFamily(
          lydiaFather: true,
          anastasiaFather: anastasiaFather,
        );
        final ids = family.document.people.keys.toList();
        final priors = [
          for (final mode in TreeTrunkMode.values)
            for (final id in ids) family.layout(id, mode),
        ];
        for (final mode in TreeTrunkMode.values) {
          for (final id in ids) {
            final canonical = family.layout(id, mode);
            for (final prior in priors) {
              final current = family.layout(id, mode, prior);
              expect(_snapshot(current), _snapshot(canonical));
            }
            final reversed = _cousinFamily(
              lydiaFather: true,
              reverseInsertion: true,
              anastasiaFather: anastasiaFather,
            ).layout(id, mode);
            expect(_snapshot(reversed), _snapshot(canonical));
          }
        }
      }
    });

    test('random prior documents, metrics, and paths cannot seed packing', () {
      final random = math.Random(91027);
      final family = _cousinFamily();
      final ids = family.document.people.keys.toList();
      TreeLayout? previous;
      for (var iteration = 0; iteration < 60; iteration++) {
        final other = _Family();
        final otherIds = ['x', 'y', 'z', 'a', 'b', 'c']..shuffle(random);
        for (final id in otherIds) {
          other.add(id);
          if (random.nextBool()) {
            other.birth(id, '${1940 + random.nextInt(70)}-01-01');
          }
        }
        other
          ..parents('a', father: 'x', mother: 'y')
          ..parents('b', mother: 'z')
          ..parents('c', father: 'a', mother: 'b');
        previous = TreeLayout.build(
          other.document,
          selectedId: otherIds[random.nextInt(otherIds.length)],
          mode: TreeTrunkMode.values[random.nextInt(3)],
          nodeExtent: 70.0 + random.nextInt(60),
          gap: random.nextInt(30).toDouble(),
          previousLayout: previous,
        );
        final path = ids.toList()..shuffle(random);
        for (final id in path) {
          final mode = TreeTrunkMode.values[random.nextInt(3)];
          final extent = [80.0, 96.0, 108.0, 83.5][random.nextInt(4)];
          final gap = [0.0, 10.0, 24.0, 7.25][random.nextInt(4)];
          TreeLayout build(TreeLayout? prior) => TreeLayout.build(
            family.document,
            selectedId: id,
            mode: mode,
            nodeExtent: extent,
            gap: gap,
            previousLayout: prior,
          );
          final current = build(previous);
          expect(_snapshot(current), _snapshot(build(null)));
          _expectDescendingLinks(current);
          _expectNoOverlap(current);
          previous = current;
        }
      }
    });

    test(
      'nearby cousin and half-sibling selections only translate their row',
      () {
        final family = _cousinFamily(lydiaFather: true)
          ..add('third-child')
          ..parents('third-child', mother: 'natalia')
          ..birth('anastasia', '1990-01-01')
          ..birth(rootTreePersonId, '1995-01-01')
          ..birth('nikita', '1997-01-01');
        for (final mode in TreeTrunkMode.values) {
          final first = family.layout(rootTreePersonId, mode);
          final row = first.positions[rootTreePersonId]!.level;
          for (final id in ['anastasia', 'nikita', 'third-child']) {
            // Cold builds must be stable too; passing a warm layout is not what
            // protects context from jumping to the shorter side of the focus.
            final current = family.layout(id, mode);
            _expectTranslatedRow(first, current, row);
            expect(current.positions[id]!.crossCenter, 0);
            for (final person in first.positions.keys.where(
              (person) => first.positions[person]!.level != row,
            )) {
              if (mode == TreeTrunkMode.both) continue;
              // Changes above this rank may translate a centering chain, but
              // parent-role family order and spacing remain canonical.
              final parentRow = first.positions[person]!.level;
              _expectTranslatedRow(first, current, parentRow);
            }
            _expectNoOverlap(current);
          }
        }
      },
    );

    test(
      'selected parent cards override context couples and sibling chronology',
      () {
        final family = _cousinFamily()
          ..birth('veronika', '1960-01-01')
          ..birth('natalia', '1970-01-01');
        for (final mode in TreeTrunkMode.values) {
          final initial = family.layout('nikita', mode);
          expect(
            _blockFor(initial, 'veronika').people.map((p) => p.id),
            mode == TreeTrunkMode.both
                ? ['natalia', 'veronika']
                : ['veronika', 'natalia'],
          );
          if (mode == TreeTrunkMode.both) {
            _expectParentCardsAdjacent(initial, 'veronika', 'roman');
          } else {
            _expectBefore(initial, 'veronika', 'roman');
            _expectBefore(initial, 'natalia', 'oleg');
          }
          final roundTrip = family.layout(
            'nikita',
            mode,
            family.layout(rootTreePersonId, mode, initial),
          );
          expect(_snapshot(roundTrip), _snapshot(initial));
          _expectDescendingLinks(roundTrip);
          _expectNoOverlap(roundTrip);
        }
      },
    );

    test('rejects invalid metrics and unknown selected IDs', () {
      final document = TreeDocument();
      for (final extent in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
          () => TreeLayout.build(
            document,
            selectedId: rootTreePersonId,
            mode: TreeTrunkMode.both,
            nodeExtent: extent,
          ),
          throwsArgumentError,
        );
      }
      for (final gap in [-1.0, double.nan, double.infinity]) {
        expect(
          () => TreeLayout.build(
            document,
            selectedId: rootTreePersonId,
            mode: TreeTrunkMode.both,
            gap: gap,
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => TreeLayout.build(
          document,
          selectedId: 'missing',
          mode: TreeTrunkMode.both,
        ),
        throwsArgumentError,
      );
    });
  });
}

class _Family {
  final document = TreeDocument();
  final events = <StampedTreeOperation>[];
  int _clock = 0;

  void _apply(TreeOperation operation) {
    _clock++;
    final event = StampedTreeOperation(
      id: 'layout-test-$_clock',
      author: 'layout-test',
      clock: _clock,
      createdAt: DateTime.utc(2026),
      operation: operation,
    );
    events.add(event);
    document.merge([event]);
  }

  TreeDocument reload() => TreeDocument()
    ..merge(
      events.reversed.map(
        (event) => StampedTreeOperation.fromJson(event.toJson()),
      ),
    );

  void add(String id, {String? name}) {
    _apply(document.createPerson(id, name: name ?? id));
  }

  void parents(String id, {String? father, String? mother}) {
    if (father != null) _apply(document.setValue(id, 'fatherId', father));
    if (mother != null) _apply(document.setValue(id, 'motherId', mother));
  }

  void birth(String id, String date) {
    _apply(document.setValue(id, 'birthDate', date));
  }

  void sex(String id, TreeSex sex) {
    _apply(document.setValue(id, 'sex', sex.name));
  }

  TreeLayout layout(
    String selectedId, [
    TreeTrunkMode mode = TreeTrunkMode.both,
    TreeLayout? previousLayout,
  ]) {
    return TreeLayout.build(
      document,
      selectedId: selectedId,
      mode: mode,
      previousLayout: previousLayout,
    );
  }
}

_Family _descendantCorridorFamily(bool reverse, {bool sisterOnRight = false}) {
  final family = _cousinFamily(
    reverseInsertion: reverse,
    anastasiaFather: true,
  );
  for (final (id, name) in [
    (rootTreePersonId, 'Ольга'),
    ('anastasia', 'Анастасия'),
    ('nikita', 'Никита'),
    ('natalia', 'Наталья'),
    ('veronika', 'Вероника'),
    ('oleg', 'Олег'),
    ('nekto', 'Некто'),
    ('roman', 'Роман'),
  ]) {
    family._apply(family.document.editText(id, TreeTextField.name, name)!);
  }
  // Undated fathers are older than the dated mother for BOTH priority grouping:
  // different father groups expose the real Anastasia / Nikita / Olga gap.
  family.birth('natalia', '1970-01-01');
  if (sisterOnRight) family.birth('veronika', '1980-01-01');
  return family;
}

_Family _ancestorCorridorFamily(bool reverse) {
  final family = _Family();
  final people = [
    ('maternal-great', 'a maternal great'),
    ('paternal-great', 'z paternal great'),
    ('oleg-great', 'm oleg great'),
    ('paternal-context-great', 'n paternal context great'),
    ('neutral-root', 'o neutral root'),
    ('lydia', 'a lydia'),
    ('gennady', 'b gennady'),
    ('valentina', 'z valentina'),
    ('oleg-mother', 'm oleg mother'),
    ('oleg-father', 'n oleg father'),
    ('paternal-context', 'o paternal context'),
    ('neutral', 'p neutral'),
    ('neutral-child', 'neutral child'),
    ('prikol', 'a prikol'),
    ('natalia', 'b natalia'),
    ('veronika', 'c veronika'),
    ('roman', 'roman'),
    ('oleg', 'oleg'),
    ('shrek', 'shrek'),
    ('other-partner', 'other partner'),
    ('other-child', 'other child'),
    ('nikita', 'nikita'),
    ('olga', 'olga'),
  ];
  for (final (id, name) in reverse ? people.reversed : people) {
    family.add(id, name: name);
  }
  family
    ..parents('lydia', father: 'maternal-great')
    ..parents('valentina', father: 'paternal-great')
    ..parents('oleg-mother', father: 'oleg-great')
    ..parents('paternal-context', father: 'paternal-context-great')
    ..parents('neutral', father: 'neutral-root')
    ..parents('neutral-child', father: 'neutral');
  for (final id in ['prikol', 'natalia', 'veronika']) {
    family.parents(id, mother: 'lydia', father: 'gennady');
  }
  return family
    ..parents('roman', mother: 'valentina')
    ..parents('oleg', mother: 'oleg-mother', father: 'oleg-father')
    ..parents('shrek', father: 'oleg-father')
    ..parents('other-partner', mother: 'paternal-context')
    ..parents('other-child', mother: 'other-partner', father: 'roman')
    ..parents('nikita', mother: 'veronika', father: 'roman')
    ..parents('olga', mother: 'natalia', father: 'oleg');
}

_Family _lydiaFamily({
  bool knownOtherParent = false,
  bool nataliaIsMother = true,
}) {
  final family = _Family()
    ..add('test')
    ..add('gennady')
    ..add('lydia')
    ..add('natalia')
    ..add('veronika')
    ..add('oleg')
    ..add('olga')
    ..add('anastasia')
    ..parents('lydia', father: 'test')
    ..parents('natalia', father: 'gennady', mother: 'lydia')
    ..parents('veronika', father: 'gennady', mother: 'lydia')
    ..parents(
      'olga',
      father: nataliaIsMother ? 'oleg' : 'natalia',
      mother: nataliaIsMother ? 'natalia' : 'oleg',
    );
  if (knownOtherParent) family.add('other-parent');
  family.parents(
    'anastasia',
    father: nataliaIsMother
        ? knownOtherParent
              ? 'other-parent'
              : null
        : 'natalia',
    mother: nataliaIsMother
        ? 'natalia'
        : knownOtherParent
        ? 'other-parent'
        : null,
  );
  return family;
}

_Family _cousinFamily({
  bool lydiaFather = false,
  bool reverseInsertion = false,
  bool anastasiaFather = false,
  bool romanMother = false,
}) {
  final family = _Family();
  final ids = [
    'oleg',
    'natalia',
    'anastasia',
    'veronika',
    'gennady',
    'lydia',
    'nikita',
    'roman',
    if (lydiaFather) 'test',
    if (anastasiaFather) 'nekto',
    if (romanMother) 'valentina',
  ];
  for (final id in reverseInsertion ? ids.reversed : ids) {
    family.add(id);
  }
  family
    ..sex(rootTreePersonId, TreeSex.female)
    ..sex('anastasia', TreeSex.female)
    ..sex('natalia', TreeSex.female)
    ..sex('veronika', TreeSex.female)
    ..sex('oleg', TreeSex.male)
    ..sex('roman', TreeSex.male)
    ..sex('nikita', TreeSex.male)
    ..parents(rootTreePersonId, father: 'oleg', mother: 'natalia')
    ..parents(
      'anastasia',
      father: anastasiaFather ? 'nekto' : null,
      mother: 'natalia',
    )
    ..parents('natalia', father: 'gennady', mother: 'lydia')
    ..parents('veronika', father: 'gennady', mother: 'lydia')
    ..parents('nikita', father: 'roman', mother: 'veronika');
  if (lydiaFather) family.parents('lydia', father: 'test');
  if (romanMother) family.parents('roman', mother: 'valentina');
  return family;
}

_Family _branchSideFamily(String dates, bool reverseInsertion) {
  final family =
      _cousinFamily(
          reverseInsertion: reverseInsertion,
          anastasiaFather: true,
          romanMother: true,
        )
        ..sex('gennady', TreeSex.male)
        ..sex('lydia', TreeSex.female)
        ..sex('valentina', TreeSex.female);
  if (dates != 'unknown') {
    for (final id in ['lydia', 'gennady', 'valentina']) {
      family.birth(
        id,
        dates == 'equal'
            ? '1930-01-01'
            : (id == 'valentina') == (dates == 'paternal-first')
            ? '1920-01-01'
            : '1940-01-01',
      );
    }
    family
      ..birth(
        'natalia',
        dates == 'paternal-first' ? '1970-01-01' : '1960-01-01',
      )
      ..birth(
        'veronika',
        dates == 'maternal-first' ? '1970-01-01' : '1960-01-01',
      );
  }
  return family;
}

_Family _siblingContextFamily() => _Family()
  ..add('father')
  ..add('mother')
  ..add('other-parent')
  ..add('a')
  ..add('b')
  ..add('context')
  ..parents('a', father: 'father', mother: 'mother')
  ..parents('b', father: 'father', mother: 'mother')
  ..parents('context', father: 'other-parent');

_Family _distinctGrandparentFamily() => _Family()
  ..add('great')
  ..add('great-maternal')
  ..add('grand-father')
  ..add('grand-mother')
  ..add('maternal-grand-father')
  ..add('maternal-grand-mother')
  ..parents('grand-father', father: 'great')
  ..parents('grand-mother', father: 'great')
  ..parents('maternal-grand-father', father: 'great-maternal')
  ..parents('maternal-grand-mother', father: 'great-maternal')
  ..add('father')
  ..add('mother')
  ..parents('father', father: 'grand-father', mother: 'grand-mother')
  ..parents(
    'mother',
    father: 'maternal-grand-father',
    mother: 'maternal-grand-mother',
  )
  ..add('sibling')
  ..parents(rootTreePersonId, father: 'father', mother: 'mother')
  ..parents('sibling', father: 'father', mother: 'mother');

void _expectDescendantCorridors(TreeLayout layout, TreeDocument document) {
  expect(layout.mode, TreeTrunkMode.both);
  final descendants = <String>{};
  final pending = [layout.selectedId];
  for (var i = 0; i < pending.length; i++) {
    for (final person in document.people.values) {
      if ((person.motherId == pending[i] || person.fatherId == pending[i]) &&
          descendants.add(person.id)) {
        pending.add(person.id);
      }
    }
  }
  final selectedLevel = layout.positions[layout.selectedId]!.level;
  for (final row in layout.levels.where((row) => row.index > selectedLevel)) {
    final indices = [
      for (var i = 0; i < row.blocks.length; i++)
        if (row.blocks[i].people.any(
          (person) => descendants.contains(person.id),
        ))
          i,
    ];
    if (indices.length < 2) continue;
    expect(
      indices.last - indices.first + 1,
      indices.length,
      reason:
          'Descendant blocks must form one corridor on rank ${row.index}: '
          '${row.blocks.map((b) => b.people.map((p) => p.id).toList()).toList()}',
    );
  }
}

void _expectAncestorCorridors(TreeLayout layout) {
  expect(layout.mode, TreeTrunkMode.both);
  final selectedLevel = layout.positions[layout.selectedId]!.level;
  for (final row in layout.levels.where((row) => row.index < selectedLevel)) {
    final indices = [
      for (var i = 0; i < row.blocks.length; i++)
        if (row.blocks[i].trunk) i,
    ];
    if (indices.length < 2) continue;
    expect(
      indices.last - indices.first + 1,
      indices.length,
      reason:
          'Ancestor blocks must form one corridor on rank ${row.index}: '
          '${row.blocks.map((b) => b.people.map((p) => p.id).toList()).toList()}',
    );
  }
}

void _expectSameRanks(TreeLayout previous, TreeLayout current) {
  for (final entry in previous.positions.entries) {
    expect(current.positions[entry.key]!.level, entry.value.level);
  }
}

void _expectDescendingLinks(TreeLayout layout) {
  for (final link in layout.links) {
    expect(
      layout.positions[link.parentId]!.level,
      lessThan(layout.positions[link.childId]!.level),
      reason: '${link.parentId} must precede ${link.childId}',
    );
    expect(link.blockId, layout.positions[link.childId]!.blockId);
  }
}

void _expectTranslatedRows(TreeLayout previous, TreeLayout current) {
  expect(current.positions.keys, unorderedEquals(previous.positions.keys));
  for (final row in previous.levels) {
    _expectTranslatedRow(previous, current, row.index);
  }
}

void _expectTranslatedRow(TreeLayout previous, TreeLayout current, int index) {
  final row = previous.levels.firstWhere((level) => level.index == index);
  final next = current.levels.firstWhere((level) => level.index == row.index);
  expect(
    next.blocks.map((block) => block.id),
    row.blocks.map((block) => block.id),
  );
  final firstId = row.blocks.first.people.first.id;
  final shift =
      current.positions[firstId]!.crossCenter -
      previous.positions[firstId]!.crossCenter;
  expect(next.minCross, closeTo(row.minCross + shift, 1e-9));
  expect(next.maxCross, closeTo(row.maxCross + shift, 1e-9));
  for (final block in row.blocks) {
    final nextBlock = next.blocks.firstWhere((b) => b.id == block.id);
    expect(
      nextBlock.people.map((person) => person.id),
      block.people.map((person) => person.id),
    );
    expect(nextBlock.start, closeTo(block.start + shift, 1e-9));
    expect(nextBlock.extent, block.extent);
    for (final person in block.people) {
      expect(current.positions[person.id]!.level, row.index);
      expect(
        current.positions[person.id]!.crossCenter,
        closeTo(previous.positions[person.id]!.crossCenter + shift, 1e-9),
      );
    }
  }
}

TreeSiblingBlock _blockFor(TreeLayout layout, String id) {
  final position = layout.positions[id]!;
  return layout.levels
      .firstWhere((g) => g.index == position.level)
      .blocks
      .firstWhere((b) => b.id == position.blockId);
}

void _expectConsecutive(TreeLayout layout, List<String> people) {
  final level = layout.levels.firstWhere(
    (g) => g.index == layout.positions[people.first]!.level,
  );
  final blockIds = {for (final id in people) layout.positions[id]!.blockId};
  final indices = [
    for (var i = 0; i < level.blocks.length; i++)
      if (blockIds.contains(level.blocks[i].id)) i,
  ];
  expect(indices, hasLength(blockIds.length));
  expect(indices.last - indices.first + 1, indices.length);
}

List<String> _rowPeople(TreeLayout layout, String personId) => layout.levels
    .firstWhere((row) => row.index == layout.positions[personId]!.level)
    .blocks
    .expand((block) => block.people)
    .map((p) => p.id)
    .toList();

void _expectParentCardsAdjacent(
  TreeLayout layout,
  String mother,
  String father,
) {
  expect(layout.mode, TreeTrunkMode.both);
  final maternal = _blockFor(layout, mother);
  final paternal = _blockFor(layout, father);
  expect(layout.positions[mother]!.level, layout.positions[father]!.level);
  final people = _rowPeople(layout, mother);
  expect(
    people.indexOf(father) - people.indexOf(mother),
    1,
    reason: '$mother must be immediately before $father in $people',
  );
  if (maternal.id != paternal.id) {
    final row = layout.levels.firstWhere(
      (row) => row.index == layout.positions[mother]!.level,
    );
    expect(row.blocks.indexOf(paternal), row.blocks.indexOf(maternal) + 1);
    expect(maternal.people.last.id, mother);
    expect(paternal.people.first.id, father);
  }
  expect(
    layout.positions[father]!.crossCenter -
        layout.positions[mother]!.crossCenter,
    closeTo(
      layout.nodeExtent +
          (maternal.id == paternal.id ? layout.gap : 2 * layout.gap),
      1e-9,
    ),
  );
}

void _expectBefore(
  TreeLayout layout,
  String first,
  String second, [
  String? reason,
]) {
  expect(layout.positions[first]!.level, layout.positions[second]!.level);
  expect(
    layout.positions[first]!.crossCenter,
    lessThan(layout.positions[second]!.crossCenter),
    reason:
        reason ??
        '$first must be before $second in ${_rowPeople(layout, first)}',
  );
}

void _expectAdjacentPeople(TreeLayout layout, String first, String second) {
  expect(layout.positions[first]!.level, layout.positions[second]!.level);
  final people = _rowPeople(layout, first);
  expect(
    (people.indexOf(first) - people.indexOf(second)).abs(),
    1,
    reason: '$first and $second in $people',
  );
}

void _expectNoOverlap(TreeLayout layout) {
  for (final level in layout.levels) {
    for (var i = 0; i < level.blocks.length; i++) {
      final block = level.blocks[i];
      expect(block.start, greaterThanOrEqualTo(level.minCross));
      expect(block.start + block.extent, lessThanOrEqualTo(level.maxCross));
      for (var j = 0; j < block.people.length; j++) {
        final position = layout.positions[block.people[j].id]!;
        expect(position.level, level.index);
        expect(position.blockId, block.id);
        expect(
          position.crossCenter,
          block.start +
              layout.nodeExtent / 2 +
              j * (layout.nodeExtent + layout.gap),
        );
      }
      if (i > 0) {
        final previous = level.blocks[i - 1];
        expect(
          block.start - previous.start - previous.extent,
          greaterThanOrEqualTo(2 * layout.gap),
        );
      }
    }
  }
}

List<Object?> _snapshot(TreeLayout layout) => [
  layout.selectedId,
  layout.mode,
  layout.nodeExtent,
  layout.gap,
  layout.trunkIds.toList()..sort(),
  for (final link in layout.links) [link.parentId, link.childId, link.blockId],
  for (final level in layout.levels) ...[
    level.index,
    level.minCross,
    level.maxCross,
    for (final block in level.blocks) ...[
      block.id,
      block.start,
      block.extent,
      block.fatherId,
      block.motherId,
      block.trunk,
      block.branch,
      block.emphasis,
      for (final person in block.people) ...[
        person.id,
        person.birthDate,
        layout.positions[person.id]!.level,
        layout.positions[person.id]!.trunk,
        layout.positions[person.id]!.crossCenter,
        layout.positions[person.id]!.branch,
        layout.positions[person.id]!.emphasis,
      ],
    ],
  ],
];
