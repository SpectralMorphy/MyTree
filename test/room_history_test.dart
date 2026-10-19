import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_history.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';

const _roomId = '0123456789abcdef0123456789abcdef';

RoomEdit _edit(String id, String text, {int clock = 1}) => RoomEdit(
  id: id,
  author: 'remote',
  clock: clock,
  createdAt: clock,
  text: text,
);

RoomEdit _role(
  String id,
  RoomRole role, {
  String targetActor = 'subject',
  int clock = 1,
}) => RoomEdit(
  id: id,
  author: 'editor',
  clock: clock,
  createdAt: clock,
  text: role.name,
  kind: RoomEditKind.participantRole,
  targetActor: targetActor,
);

RoomEdit _authored(
  String id,
  String text, {
  String author = 'remote',
  required int sequence,
  String? previous,
  List<String> base = const [],
  int clock = 1,
  int? createdAt,
}) => RoomEdit.fromJson({
  ..._edit(id, text, clock: clock).toJson(),
  'author': author,
  if (createdAt != null) 'createdAt': createdAt,
  'authorSequence': sequence,
  'authorPrevious': previous,
  if (sequence == 1) 'authorBase': base,
})!;

Map<String, dynamic> _core(RoomEdit edit) => Map.of(edit.toJson())
  ..remove('authorSequence')
  ..remove('authorPrevious')
  ..remove('authorBase');

List<Map<String, dynamic>> _snapshot(List<Map<String, dynamic>> operations) =>
    (jsonDecode(jsonEncode(operations)) as List)
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();

void _expectDraft(RoomEdit edit) {
  final json = edit.toJson();
  expect(json.containsKey('authorSequence'), isFalse);
  expect(json.containsKey('authorPrevious'), isFalse);
  expect(json.containsKey('authorBase'), isFalse);
}

void _expectPrefix(Iterable<RoomEdit> edits, {String author = 'local'}) {
  final ordered = edits.where((edit) => edit.author == author).toList()
    ..sort(
      (a, b) => (a.toJson()['authorSequence'] as int).compareTo(
        b.toJson()['authorSequence'] as int,
      ),
    );
  for (var index = 0; index < ordered.length; index++) {
    final json = ordered[index].toJson();
    expect(json['authorSequence'], index + 1);
    expect(json['authorPrevious'], index == 0 ? null : ordered[index - 1].id);
    if (index == 0) {
      expect(json['authorBase'], isEmpty);
    } else {
      expect(json.containsKey('authorBase'), isFalse);
    }
  }
}

class _Store extends MemoryRoomStore {
  final changes = StreamController<void>.broadcast(sync: true);
  final authoredBatches = <List<Map<String, dynamic>>>[];
  final appendBatches = <List<Map<String, dynamic>>>[];
  int authoredCalls = 0;
  int appendCalls = 0;
  int loadCalls = 0;
  int membershipCalls = 0;
  bool failAppend = false;
  bool throwAppend = false;
  bool failFlush = false;
  bool failMembership = false;
  int partialAppendCount = 0;
  Completer<void>? authoredGate;
  Completer<void>? appendGate;
  Completer<void>? flushGate;
  List<Map<String, dynamic>>? loadedHistory;

  @override
  Future<List<Map<String, dynamic>>> appendAuthoredHistory(
    String roomId,
    List<Map<String, dynamic>> drafts,
  ) {
    authoredCalls++;
    authoredBatches.add(_snapshot(drafts));
    final gate = authoredGate;
    return gate == null
        ? super.appendAuthoredHistory(roomId, drafts)
        : gate.future.then((_) => super.appendAuthoredHistory(roomId, drafts));
  }

  @override
  Future<List<Map<String, dynamic>>> loadHistory(String roomId) {
    loadCalls++;
    final override = loadedHistory;
    return override == null
        ? super.loadHistory(roomId)
        : Future.value(override);
  }

  @override
  Future<void> appendHistory(
    String roomId,
    List<Map<String, dynamic>> operations,
  ) {
    appendCalls++;
    appendBatches.add(_snapshot(operations));
    if (throwAppend) throw StateError('Synchronous disk failure');
    if (failAppend) return Future.error(StateError('Disk full'));
    final partialCount = partialAppendCount;
    if (partialCount != 0) {
      partialAppendCount = 0;
      return super
          .appendHistory(roomId, operations.take(partialCount).toList())
          .then((_) => throw StateError('Partial append failure'));
    }
    final gate = appendGate;
    return gate == null
        ? super.appendHistory(roomId, operations)
        : gate.future.then((_) => super.appendHistory(roomId, operations));
  }

  @override
  Future<void> saveMembership(String roomId) {
    membershipCalls++;
    return failMembership
        ? Future.error(StateError('Membership failed'))
        : super.saveMembership(roomId);
  }

  @override
  Stream<void> watchHistory(String roomId) => changes.stream;

  Future<void> externalAppend(List<RoomEdit> edits) async {
    await super.appendHistory(
      _roomId,
      edits.map((edit) => edit.toJson()).toList(),
    );
    changes.add(null);
  }

  @override
  Future<void> flush() {
    if (failFlush) return Future.error(StateError('Flush failed'));
    return flushGate?.future ?? super.flush();
  }
}

void main() {
  late List<RoomHistory> histories;
  late List<_Store> stores;

  setUp(() {
    histories = [];
    stores = [];
  });

  RoomHistory history({
    bool member = false,
    _Store? store,
    void Function()? onChanged,
    void Function(List<RoomEdit>)? onDurableEdits,
    void Function(Future<void> Function())? serializeRefresh,
  }) {
    final chosenStore = store ?? _Store();
    if (!stores.contains(chosenStore)) stores.add(chosenStore);
    final journal = RoomHistory(
      roomId: _roomId,
      actorId: 'local',
      store: chosenStore,
      existingMember: member,
      onChanged: onChanged,
      onDurableEdits: onDurableEdits,
      serializeRefresh: serializeRefresh,
    );
    histories.add(journal);
    return journal;
  }

  void testHistory(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final journal in histories) {
          journal.dispose();
        }
        await tester.pump();
      }
    });
  }

  tearDown(() async {
    for (final journal in histories) {
      journal.dispose();
    }
    for (final store in stores) {
      await store.changes.close();
    }
  });

  test(
    'durable reads reuse immutable snapshots across draft retries',
    () async {
      final store = _Store();
      final journal = history(store: store);
      final original = _edit('saved', 'saved text');
      final empty = journal.durableHistory;
      expect(journal.durableHistory, same(empty));
      expect(() => empty.add(original), throwsUnsupportedError);

      await journal.merge([original]);
      final before = journal.durableHistory;
      expect(journal.durableHistory, same(before));
      expect(before, [original]);
      expect(() => before[0] = original, throwsUnsupportedError);

      store
        ..authoredGate = Completer<void>()
        ..failAppend = true;
      final pending = journal.edit('optimistic draft');
      final draft = journal.knownEdits.last;
      _expectDraft(draft);
      expect(journal.text, draft.text);
      expect(await journal.merge([]), isEmpty);
      expect(journal.durableHistory, same(before));
      expect(store.appendCalls, 1);
      expect(store.authoredCalls, 1);
      store.authoredGate!.complete();
      expect(await pending, isNull);
      expect(journal.durableHistory, same(before));
      await expectLater(journal.flush(), throwsStateError);
      expect(journal.durableHistory, same(before));

      store.failAppend = false;
      await journal.flush();
      final saved = journal.durableHistory;
      expect(saved, isNot(same(before)));
      expect(journal.durableHistory, same(saved));
      expect(saved.map(_core), [_core(original), _core(draft)]);
      expect(saved.length, journal.durableLength);
      _expectPrefix(saved);
      expect(() => saved.clear(), throwsUnsupportedError);
      expect(empty, isEmpty);
      expect(before, [original]);
    },
  );

  test(
    'authored append starts immediately and survives disposal while queued',
    () async {
      final store = _Store()..authoredGate = Completer<void>();
      var changes = 0;
      final journal = history(store: store, onChanged: () => changes++);
      final beforeEdit = DateTime.now().toUtc().millisecondsSinceEpoch;
      final pending = journal.edit('Ж😀 immediate close');
      final afterEdit = DateTime.now().toUtc().millisecondsSinceEpoch;
      expect(store.authoredCalls, 1);
      expect(
        store.appendCalls,
        0,
        reason: 'The atomic append may await a lock',
      );
      expect(journal.text, 'Ж😀 immediate close');
      expect(journal.historyLength, 1);
      expect(journal.savingCount, 1);
      expect(journal.durableHistory, isEmpty);
      final draft = journal.knownEdits.single;
      _expectDraft(draft);
      expect(draft.createdAt, inInclusiveRange(beforeEdit, afterEdit));
      expect(store.authoredBatches.single, [draft.toJson()]);
      journal.dispose();
      final before = changes;
      store.authoredGate!.complete();
      final returned = (await pending)!;
      expect(changes, before);
      expect(journal.saving, isFalse);
      final saved = decodeRoomHistory(await store.loadHistory(_roomId)).single;
      expect(_core(saved), _core(draft));
      expect(returned.toJson()['authorSequence'], isNotNull);
      expect(returned.toJson(), saved.toJson());
      expect(journal.knownEdits.single.toJson(), saved.toJson());
      _expectPrefix([saved]);
    },
  );

  test(
    'later rapid drafts save only with their failed predecessor prefix',
    () async {
      final store = _Store()..failAppend = true;
      final sent = <List<RoomEdit>>[];
      final journal = history(store: store, onDurableEdits: sent.add);
      final first = journal.edit('first draft');
      final second = journal.edit('second draft');
      final third = journal.renameRoom('Pending title');
      expect(store.authoredCalls, 3);
      final drafts = journal.knownEdits.toList();
      expect(drafts, hasLength(3));
      for (final draft in drafts) {
        _expectDraft(draft);
      }
      expect(
        store.authoredBatches.map(
          (batch) => batch.map((edit) => edit['id']).toList(),
        ),
        [
          [drafts[0].id],
          [drafts[0].id, drafts[1].id],
          [drafts[0].id, drafts[1].id, drafts[2].id],
        ],
      );
      expect(await Future.wait([first, second, third]), everyElement(isNull));
      expect(journal.text, 'second draft');
      expect(journal.roomName, 'Pending title');
      expect(journal.durableHistory, isEmpty);
      expect(await store.loadHistory(_roomId), isEmpty);
      expect(sent, isEmpty);
      for (final draft in journal.knownEdits) {
        _expectDraft(draft);
      }

      store.failAppend = false;
      store.authoredGate = Completer<void>();
      final fourth = journal.edit('later successful draft');
      expect(store.authoredCalls, 4);
      expect(journal.durableHistory, isEmpty);
      final backlog = store.authoredBatches.last;
      expect(backlog.take(3), drafts.map((edit) => edit.toJson()));
      expect(backlog, hasLength(4));
      final fourthDraft = journal.knownEdits.last;
      _expectDraft(fourthDraft);
      expect(backlog.last, fourthDraft.toJson());
      store.authoredGate!.complete();
      final saved = (await fourth)!;
      expect(saved.id, fourthDraft.id);
      expect(journal.durableHistory.map(_core), [
        ...drafts.map(_core),
        _core(fourthDraft),
      ]);
      _expectPrefix(journal.durableHistory);
      final persisted = decodeRoomHistory(await store.loadHistory(_roomId));
      _expectPrefix(persisted);
      expect(
        persisted.map((edit) => edit.toJson()),
        journal.durableHistory.map((edit) => edit.toJson()),
      );
      expect(sent, isNotEmpty);
      for (final batch in sent) {
        expect(
          batch.map((edit) => edit.id),
          containsAll(drafts.map((edit) => edit.id)),
        );
        _expectPrefix(batch);
      }
    },
  );

  test(
    'partial append retry reuses stable cores and already committed proof',
    () async {
      final store = _Store()..failAppend = true;
      final journal = history(store: store);
      final before = journal.durableHistory;
      await journal.edit('first partial');
      await journal.edit('second partial');
      final drafts = journal.knownEdits.toList();
      store.failAppend = false;
      store.partialAppendCount = 1;
      await expectLater(journal.flush(), throwsStateError);
      expect(journal.error, contains('Partial append failure'));
      final partial = decodeRoomHistory(await store.loadHistory(_roomId));
      expect(partial, hasLength(1));
      expect(_core(partial.single), _core(drafts.first));
      _expectPrefix(partial);
      for (final draft in journal.knownEdits) {
        _expectDraft(draft);
      }
      expect(journal.durableHistory, same(before));
      expect(before, isEmpty);
      expect(store.appendBatches.last.single, partial.single.toJson());
      expect(
        store.appendBatches
            .expand((batch) => batch)
            .where((edit) => edit['id'] == drafts.last.id),
        isEmpty,
        reason:
            'The default store stopped before attempting the next prefix record',
      );
      final otherTab = history(store: store);
      final intervening = (await otherTab.edit('another tab between retries'))!;
      expect(intervening.toJson()['authorSequence'], 2);
      expect(intervening.toJson()['authorPrevious'], drafts.first.id);
      await journal.flush();
      final saved = journal.durableHistory;
      expect(saved, isNot(same(before)));
      expect(journal.durableHistory, same(saved));
      expect(before, isEmpty);
      expect(journal.error, isNull);
      expect(
        {for (final edit in journal.knownEdits) edit.id: _core(edit)},
        {
          for (final edit in [...drafts, intervening]) edit.id: _core(edit),
        },
      );
      _expectPrefix(journal.durableHistory);
      final persisted = decodeRoomHistory(await store.loadHistory(_roomId));
      expect(persisted, hasLength(3));
      expect(persisted.first.toJson(), partial.single.toJson());
      expect(persisted[1].toJson(), intervening.toJson());
      expect(_core(persisted.last), _core(drafts.last));
      expect(persisted.last.toJson()['authorSequence'], 3);
      expect(persisted.last.toJson()['authorPrevious'], intervening.id);
      expect(
        journal.durableHistory.map((edit) => edit.toJson()),
        persisted.map((edit) => edit.toJson()),
      );
      _expectPrefix(persisted);
    },
  );

  test(
    'same-actor concurrent histories allocate one shared canonical prefix',
    () async {
      final store = _Store()..authoredGate = Completer<void>();
      final first = history(store: store);
      final second = history(store: store);
      final pending = [
        first.edit('tab one first'),
        second.edit('tab two first'),
        first.edit('tab one second'),
        second.edit('tab two second'),
      ];
      expect(store.authoredCalls, 4);
      expect(first.durableHistory, isEmpty);
      expect(second.durableHistory, isEmpty);
      final drafts = [...first.knownEdits, ...second.knownEdits];
      for (final draft in drafts) {
        _expectDraft(draft);
      }
      store.authoredGate!.complete();
      final saved = await Future.wait(pending);
      expect(saved, everyElement(isNotNull));
      final persisted = decodeRoomHistory(await store.loadHistory(_roomId));
      expect(persisted, hasLength(4));
      _expectPrefix(persisted);
      expect(
        persisted.map((edit) => edit.id).toSet(),
        drafts.map((edit) => edit.id).toSet(),
      );
      expect(
        {for (final edit in persisted) edit.id: _core(edit)},
        {for (final edit in drafts) edit.id: _core(edit)},
      );
      for (var index = 0; index < saved.length; index++) {
        final returned = saved[index]!;
        expect(
          returned.toJson(),
          persisted.singleWhere((edit) => edit.id == returned.id).toJson(),
        );
      }
      expect(
        second.durableLength,
        4,
        reason: 'Canonical authored reads include other-tab predecessors',
      );
      final caughtUp = await first.renameRoom('Canonical catch-up');
      expect(caughtUp, isNotNull);
      expect(first.durableLength, 5);
      _expectPrefix(first.durableHistory);
      expect(
        first.durableHistory.map((edit) => edit.id),
        containsAll(second.durableHistory.map((edit) => edit.id)),
      );
    },
  );

  test(
    'tree draft finalization preserves its complete optimistic core',
    () async {
      final store = _Store()..authoredGate = Completer<void>();
      final journal = history(store: store);
      final operation = TreeDocument().editText(
        'root',
        TreeTextField.name,
        'Анна',
      )!;
      final payload = jsonEncode(operation.toJson());
      final pending = journal.appendTreeOperation(payload);
      expect(store.authoredCalls, 1);
      final draft = journal.knownEdits.single;
      _expectDraft(draft);
      expect(draft.kind, RoomEditKind.tree);
      expect(draft.text, payload);
      expect(journal.changes.single.toJson(), draft.toJson());
      store.authoredGate!.complete();
      final saved = (await pending)!;
      expect(_core(saved), _core(draft));
      expect(_core(journal.changes.single), _core(draft));
      expect(journal.changes.single.toJson(), saved.toJson());
      _expectPrefix(journal.durableHistory);
    },
  );

  test(
    'wall-clock rollback leaves local clock, prefix, and journal order stable',
    () async {
      final store = _Store();
      final journal = history(store: store);
      final future = DateTime.utc(2040, 1, 1).millisecondsSinceEpoch;
      final legacy = RoomEdit(
        id: 'before-clock-rollback',
        author: 'local',
        clock: future,
        createdAt: future,
        text: 'before rollback',
      );
      await journal.merge([legacy]);
      store.authoredGate = Completer<void>();
      final before = DateTime.now().toUtc().millisecondsSinceEpoch;
      final first = journal.edit('after rollback first');
      final second = journal.edit('after rollback second');
      final after = DateTime.now().toUtc().millisecondsSinceEpoch;
      final drafts = journal.knownEdits
          .where((edit) => edit.id != legacy.id)
          .toList();
      expect(drafts.map((edit) => edit.clock), [future + 1, future + 2]);
      for (final draft in drafts) {
        _expectDraft(draft);
        expect(draft.createdAt, inInclusiveRange(before, after));
        expect(draft.createdAt, lessThan(legacy.createdAt));
      }
      expect(journal.changes.map((edit) => edit.id), [
        legacy.id,
        ...drafts.map((edit) => edit.id),
      ]);
      store.authoredGate!.complete();
      expect(await Future.wait([first, second]), everyElement(isNotNull));
      final saved = journal.durableHistory;
      expect(saved.map(_core), [_core(legacy), ...drafts.map(_core)]);
      expect(saved[1].toJson()['authorSequence'], 1);
      expect(saved[1].toJson()['authorPrevious'], isNull);
      expect(saved[1].toJson()['authorBase'], [legacy.id]);
      expect(saved[2].toJson()['authorSequence'], 2);
      expect(saved[2].toJson()['authorPrevious'], drafts.first.id);
      expect(journal.text, 'after rollback second');
    },
  );

  test(
    'overlapping merges share pending writes and retain losing edits',
    () async {
      final store = _Store()..appendGate = Completer<void>();
      final journal = history(store: store);
      final winner = _edit('winner', 'latest', clock: 3);
      final loser = _edit('loser', 'older');
      final first = journal.merge([winner]);
      final second = journal.merge([winner, loser, loser]);
      expect(store.appendCalls, 2);
      expect(journal.savingCount, 2);
      expect(
        journal.text,
        isEmpty,
        reason: 'Remote text must first be durable',
      );
      store.appendGate!.complete();
      expect(await first, [winner]);
      expect((await second)!.map((edit) => edit.toJson()), [
        loser.toJson(),
        winner.toJson(),
      ]);
      expect(journal.text, 'latest');
      expect(journal.historyLength, 2);
      expect(journal.durableHistory.map((edit) => edit.id), [
        'loser',
        'winner',
      ]);
      expect(await journal.merge([winner, loser]), isEmpty);
      expect(store.appendCalls, 2);
    },
  );

  test('whole-batch immutable validation precedes every write', () async {
    final store = _Store();
    final journal = history(store: store);
    final original = _edit('immutable', 'original');
    await journal.merge([original]);
    final durable = journal.durableHistory;
    expect(
      () => journal.merge([
        _edit('new', 'must not save'),
        _edit('immutable', 'mutated', clock: 10),
      ]),
      throwsFormatException,
    );
    expect(
      () => journal.merge([_edit('duplicate', 'a'), _edit('duplicate', 'b')]),
      throwsFormatException,
    );
    expect(store.appendCalls, 1);
    expect(journal.historyLength, 1);
    expect(journal.text, 'original');
    expect(journal.durableHistory, same(durable));
    expect(durable, [original]);
  });

  test(
    'incomplete or forked remote prefixes reject before any append',
    () async {
      final store = _Store();
      final journal = history(store: store);
      final first = _authored('prefix-1', 'first', sequence: 1);
      final second = _authored(
        'prefix-2',
        'second',
        sequence: 2,
        previous: first.id,
      );
      expect(() => journal.merge([second]), throwsFormatException);
      expect(store.appendCalls, 0);
      expect(store.authoredCalls, 0);
      expect(journal.knownEdits, isEmpty);
      expect(journal.durableHistory, isEmpty);
      await journal.merge([first]);
      final durable = journal.durableHistory;
      final before = store.appendCalls;
      final forks = [
        _authored('fork-1', 'fork root', sequence: 1),
        _authored(
          'hole-3',
          'missing predecessor',
          sequence: 3,
          previous: second.id,
        ),
        _authored(
          'wrong-parent',
          'wrong predecessor',
          sequence: 2,
          previous: 'unrelated',
        ),
        _authored(
          'other-root',
          'missing base',
          author: 'other',
          sequence: 1,
          base: ['absent'],
        ),
      ];
      for (final invalid in forks) {
        expect(
          () =>
              journal.merge([_role('must-not-save', RoomRole.guest), invalid]),
          throwsFormatException,
        );
        expect(store.appendCalls, before);
        expect(journal.knownEdits.map((edit) => edit.id), [first.id]);
        expect(journal.durableHistory, same(durable));
      }
      await journal.merge([second]);
      expect(durable, [first]);
      expect(journal.durableHistory.map((edit) => edit.id), [
        first.id,
        second.id,
      ]);
      final sibling = _authored(
        'fork-2',
        'same sequence',
        sequence: 2,
        previous: first.id,
      );
      expect(() => journal.merge([sibling]), throwsFormatException);
      expect(store.appendCalls, before + 1);
    },
  );

  test(
    'a complete out-of-order remote batch is appended in prefix order',
    () async {
      final store = _Store();
      final journal = history(store: store);
      final first = _authored('ordered-1', 'first', sequence: 1, clock: 300);
      final second = _authored(
        'ordered-2',
        'second',
        sequence: 2,
        previous: first.id,
        clock: 200,
      );
      final third = _authored(
        'ordered-3',
        'third',
        sequence: 3,
        previous: second.id,
        clock: 100,
      );
      final merged = await journal.merge([third, first, second]);
      expect(
        merged!.map((edit) => edit.id),
        unorderedEquals([first.id, second.id, third.id]),
      );
      expect(store.appendCalls, 1);
      expect(store.authoredCalls, 0);
      expect(store.appendBatches.single.map((edit) => edit['id']), [
        first.id,
        second.id,
        third.id,
      ]);
      expect(journal.changes.map((edit) => edit.id), [
        first.id,
        second.id,
        third.id,
      ]);
      _expectPrefix(journal.durableHistory, author: 'remote');
      expect(await journal.merge([second, third, first]), isEmpty);
      expect(store.appendCalls, 1);
    },
  );

  test(
    'sealed legacy base admits its exact legacy records but rejects additions',
    () async {
      final store = _Store();
      final journal = history(store: store);
      final legacy = _edit('legacy-old', 'legacy');
      final first = _authored(
        'sealed-1',
        'sealed',
        sequence: 1,
        base: [legacy.id],
        clock: 2,
      );
      await journal.merge([first, legacy]);
      expect(journal.historyLength, 2);
      expect(store.appendBatches.single.map((edit) => edit['id']), [
        legacy.id,
        first.id,
      ]);
      final before = store.appendCalls;
      expect(
        () => journal.merge([
          _edit('unexpected-old', 'not in sealed base', clock: 0),
        ]),
        throwsFormatException,
      );
      expect(store.appendCalls, before);
      expect(journal.historyLength, 2);
      expect(journal.text, 'sealed');
      expect((await store.loadHistory(_roomId)).map((edit) => edit['id']), [
        legacy.id,
        first.id,
      ]);
      expect(await journal.merge([legacy]), isEmpty);
      final independent = _role('unsealed-legacy', RoomRole.guest);
      expect(await journal.merge([independent]), [independent]);
      expect(journal.participantRoles, {'subject': RoomRole.guest});
    },
  );

  test(
    'canonical finalization cannot replace an arbitrary legacy record',
    () async {
      final store = _Store();
      final journal = history(store: store);
      final legacy = RoomEdit.fromJson({
        ..._edit('legacy-local', 'unchanged').toJson(),
        'author': 'local',
      })!;
      await journal.merge([legacy]);
      final forged = _authored(
        legacy.id,
        legacy.text,
        author: 'local',
        sequence: 1,
      );
      expect(_core(forged), _core(legacy));
      expect(() => journal.merge([forged]), throwsFormatException);
      expect(store.appendCalls, 1);
      expect(journal.knownEdits.single.toJson(), legacy.toJson());
      expect(journal.durableHistory.single.toJson(), legacy.toJson());
    },
  );

  test(
    'failed IDs remain immutable; flush throws until the draft saves',
    () async {
      final store = _Store()..failAppend = true;
      final sent = <List<RoomEdit>>[];
      final journal = history(store: store, onDurableEdits: sent.add);
      expect(await journal.edit('keep this draft'), isNull);
      expect(journal.text, 'keep this draft');
      expect(journal.error, contains('Disk full'));
      expect(journal.durableHistory, isEmpty);
      expect(sent, isEmpty);
      final draft = journal.knownEdits.single;
      _expectDraft(draft);
      final mutatedDraft = RoomEdit.fromJson({
        ...draft.toJson(),
        'text': 'must not replace a failed optimistic core',
      })!;
      expect(() => journal.merge([mutatedDraft]), throwsFormatException);
      expect(journal.knownEdits.single.toJson(), draft.toJson());
      expect(store.authoredCalls, 1);
      await expectLater(journal.flush(), throwsStateError);
      expect(journal.text, 'keep this draft');
      store.failAppend = false;
      await journal.flush();
      expect(journal.error, isNull);
      expect(journal.durableHistory.single.text, 'keep this draft');
      expect(sent.single.single.text, 'keep this draft');
      final saved = journal.durableHistory.single;
      expect(_core(saved), _core(draft));
      _expectPrefix([saved]);
      expect(
        () => journal.merge([
          RoomEdit(
            id: saved.id,
            author: saved.author,
            clock: saved.clock,
            createdAt: saved.createdAt,
            text: 'replacement',
          ),
        ]),
        throwsFormatException,
      );
      store.failFlush = true;
      await expectLater(journal.flush(), throwsStateError);
      expect(journal.error, contains('Flush failed'));
    },
  );

  test(
    'synchronous append exceptions become recoverable storage errors',
    () async {
      final store = _Store()..throwAppend = true;
      final journal = history(store: store);
      expect(await journal.edit('draft'), isNull);
      expect(journal.error, contains('Synchronous disk failure'));
      expect(journal.savingCount, 0);
      store.throwAppend = false;
      await journal.flush();
      expect(journal.error, isNull);
      expect((await store.loadHistory(_roomId)).single['text'], 'draft');
    },
  );

  test(
    'flush includes edits started while its store flush is pending',
    () async {
      final store = _Store()..flushGate = Completer<void>();
      final journal = history(store: store);
      final flushed = journal.flush();
      store.appendGate = Completer<void>();
      final edited = journal.edit('during flush');
      store.flushGate!.complete();
      await Future<void>.value();
      expect(journal.saving, isTrue);
      store.appendGate!.complete();
      await Future.wait([flushed, edited]);
      expect(journal.saving, isFalse);
      expect(journal.durableHistory.single.text, 'during flush');
      expect(store.appendCalls, 1);
    },
  );

  testHistory(
    'supplied history skips the initial read and refreshes intervening edits',
    (tester) async {
      final store = _Store();
      final first = _authored('supplied-1', 'first', sequence: 1, clock: 2);
      final second = _authored(
        'supplied-2',
        'second',
        sequence: 2,
        previous: first.id,
      );
      await store.externalAppend([first]);
      final supplied = [first];
      // This event precedes subscription, so only the watch-gap refresh sees it.
      await store.externalAppend([second]);
      final sent = <List<RoomEdit>>[];
      final journal = history(
        member: true,
        store: store,
        onDurableEdits: sent.add,
      );
      await journal.load(initialHistory: supplied);
      final before = journal.durableHistory;
      supplied.clear();
      expect(journal.loaded, isTrue);
      expect(journal.error, isNull);
      expect(store.loadCalls, 0);
      expect(store.changes.hasListener, isTrue);
      expect(before, [first]);
      expect(journal.durableHistory, same(before));

      await tester.pump(const Duration(milliseconds: 40));
      final refreshed = journal.durableHistory;
      expect(refreshed, isNot(same(before)));
      expect(journal.durableHistory, same(refreshed));
      expect(refreshed.map((edit) => edit.toJson()), [
        first.toJson(),
        second.toJson(),
      ]);
      expect(() => refreshed.clear(), throwsUnsupportedError);
      expect(before, [first]);
      expect(sent.single.single.toJson(), second.toJson());
      expect(store.loadCalls, 1);
      expect(store.appendCalls, 0);
      expect(store.authoredCalls, 0);
    },
  );

  test(
    'supplied history rejects incomplete and forked author prefixes',
    () async {
      final first = _authored('supplied-1', 'first', sequence: 1);
      final second = _authored(
        'supplied-2',
        'second',
        sequence: 2,
        previous: first.id,
      );
      final fork = _authored('supplied-fork', 'fork', sequence: 1);
      final store = _Store()..loadedHistory = [first.toJson(), second.toJson()];
      final journal = history(member: true, store: store);
      final empty = journal.durableHistory;
      for (final supplied in [
        [second],
        [first, fork],
      ]) {
        await journal.load(initialHistory: supplied);
        expect(journal.loaded, isFalse);
        expect(journal.error, contains('Не удалось загрузить'));
        expect(journal.knownEdits, isEmpty);
        expect(journal.changes, isEmpty);
        expect(journal.durableHistory, same(empty));
        expect(store.changes.hasListener, isFalse);
      }
      expect(
        await journal.edit('must not replace an invalid snapshot'),
        isNull,
      );
      expect(store.loadCalls, 0);
      expect(store.appendCalls, 0);
      expect(store.authoredCalls, 0);
    },
  );

  testHistory('invalid saved batch never becomes an empty writable model', (
    tester,
  ) async {
    final store = _Store()
      ..loadedHistory = [
        _edit('valid', 'must not merge').toJson(),
        {'id': 'bad'},
      ];
    final journal = history(member: true, store: store);
    await journal.load();
    expect(journal.loaded, isFalse);
    expect(journal.historyLength, 0);
    expect(store.changes.hasListener, isFalse);
    await journal.edit('must not overwrite');
    expect(store.appendCalls, 0);
    store.loadedHistory = [_edit('valid', 'recovered').toJson()];
    await journal.load();
    expect(journal.loaded, isTrue);
    expect(journal.text, 'recovered');
    expect(store.changes.hasListener, isTrue);
  });

  testHistory('load and refresh require full immutable canonical closure', (
    tester,
  ) async {
    final first = _authored('loaded-1', 'first saved', sequence: 1);
    final second = _authored(
      'loaded-2',
      'second saved',
      sequence: 2,
      previous: first.id,
      clock: 2,
    );
    final store = _Store()..loadedHistory = [second.toJson()];
    final journal = history(member: true, store: store);
    await journal.load();
    expect(journal.loaded, isFalse);
    expect(journal.changes, isEmpty);
    expect(journal.knownEdits, isEmpty);
    expect(journal.error, contains('Не удалось загрузить'));
    expect(store.changes.hasListener, isFalse);
    expect(await journal.edit('cannot replace an incomplete prefix'), isNull);
    expect(store.appendCalls, 0);
    expect(store.authoredCalls, 0);

    store.loadedHistory = [second.toJson(), first.toJson()];
    await journal.load();
    final durable = journal.durableHistory;
    expect(journal.durableHistory, same(durable));
    expect(() => durable.clear(), throwsUnsupportedError);
    expect(journal.loaded, isTrue);
    expect(journal.changes.map((edit) => edit.id), [first.id, second.id]);
    expect(journal.error, isNull);
    expect(store.changes.hasListener, isTrue);
    store.loadedHistory = [second.toJson()];
    await journal.refresh();
    expect(journal.error, contains('Не удалось обновить'));
    expect(journal.durableHistory, same(durable));
    expect(journal.durableHistory.map((edit) => edit.id), [
      first.id,
      second.id,
    ]);

    final extraLegacy = _edit('proof-added-base', 'must not become visible');
    final changedProof = _authored(
      first.id,
      first.text,
      sequence: 1,
      base: [extraLegacy.id],
    );
    expect(_core(changedProof), _core(first));
    store.loadedHistory = [
      extraLegacy.toJson(),
      changedProof.toJson(),
      second.toJson(),
    ];
    await journal.refresh();
    expect(journal.error, contains('Не удалось обновить'));
    expect(journal.durableHistory, same(durable));

    store.loadedHistory = [
      _role('must-not-merge', RoomRole.guest).toJson(),
      _authored('loaded-fork', 'forked root', sequence: 1).toJson(),
    ];
    await journal.refresh();
    expect(journal.error, contains('Не удалось обновить'));
    expect(journal.durableHistory, same(durable));
    expect(
      {for (final edit in journal.knownEdits) edit.id: edit.toJson()},
      {first.id: first.toJson(), second.id: second.toJson()},
    );
    expect(journal.durableLength, 2);
    expect(store.appendCalls, 0);
    expect(store.authoredCalls, 0);
  });

  testHistory(
    'watch closes subscription gap, coalesces and uses shared queue',
    (tester) async {
      final store = _Store();
      final queued = <Future<void> Function()>[];
      final sent = <List<RoomEdit>>[];
      final journal = history(
        member: true,
        store: store,
        serializeRefresh: queued.add,
        onDurableEdits: sent.add,
      );
      await journal.load();
      await store.externalAppend([_edit('external', 'another tab')]);
      store.changes.add(null);
      await tester.pump(const Duration(milliseconds: 40));
      expect(queued, hasLength(1));
      expect(
        journal.text,
        isEmpty,
        reason: 'Refresh is ordered with network work',
      );
      await queued.removeAt(0)();
      expect(journal.text, 'another tab');
      expect(store.loadCalls, 2);
      expect(store.appendCalls, 0);
      expect(sent.single.single.id, 'external');
      journal.dispose();
      expect(store.changes.hasListener, isFalse);
      store.changes.add(null);
      await tester.pump(const Duration(milliseconds: 40));
      expect(queued, isEmpty);
    },
  );

  testHistory('fresh history does not watch or infer acceptance from storage', (
    tester,
  ) async {
    final store = _Store();
    final journal = history(store: store);
    await store.externalAppend([_edit('before', 'saved before admission')]);
    await tester.pump(const Duration(milliseconds: 40));
    expect(store.changes.hasListener, isFalse);
    expect(journal.text, isEmpty);
    expect(store.membershipCalls, 0);
    journal.watchAcceptedHistory();
    await tester.pump(const Duration(milliseconds: 40));
    expect(journal.text, 'saved before admission');
    expect(store.membershipCalls, 0);
    expect(store.appendCalls, 0);
  });

  testHistory(
    'external refresh preserves a failed draft and rejects replacement',
    (tester) async {
      final store = _Store();
      final journal = history(member: true, store: store);
      await journal.load();
      store.failAppend = true;
      await journal.edit('failed optimistic draft');
      await store.externalAppend([_edit('external', 'durable old text')]);
      await tester.pump(const Duration(milliseconds: 40));
      expect(journal.text, 'failed optimistic draft');
      expect(journal.historyLength, 2);
      expect(journal.error, contains('Disk full'));
      store.loadedHistory = [
        _edit('new', 'must not merge').toJson(),
        _edit('external', 'mutated', clock: 10).toJson(),
      ];
      store.changes.add(null);
      await tester.pump(const Duration(milliseconds: 40));
      expect(journal.historyLength, 2);
      expect(journal.error, contains('Не удалось обновить'));
      expect(store.appendCalls, 1);
    },
  );

  testHistory(
    'refresh finalizes only tracked local draft proof without changing its core',
    (tester) async {
      final store = _Store();
      final sent = <List<RoomEdit>>[];
      final journal = history(
        member: true,
        store: store,
        onDurableEdits: sent.add,
      );
      await journal.load();
      final before = journal.durableHistory;
      store.failAppend = true;
      expect(await journal.edit('partially saved draft'), isNull);
      expect(journal.durableHistory, same(before));
      final draft = journal.knownEdits.single;
      _expectDraft(draft);
      final canonical = RoomEdit.fromJson({
        ...draft.toJson(),
        'authorSequence': 1,
        'authorPrevious': null,
        'authorBase': <String>[],
      })!;
      await store.externalAppend([canonical]);
      await journal.refresh();
      final saved = journal.durableHistory;
      expect(saved, isNot(same(before)));
      expect(journal.durableHistory, same(saved));
      expect(before, isEmpty);
      expect(journal.error, isNull);
      expect(saved.single.toJson(), canonical.toJson());
      expect(journal.knownEdits.single.toJson(), canonical.toJson());
      expect(_core(journal.changes.single), _core(draft));
      expect(sent.single.single.toJson(), canonical.toJson());
      expect(store.appendCalls, 1);
      store.failAppend = false;
      await journal.flush();
      expect(
        store.authoredCalls,
        1,
        reason: 'Refresh resolved the outstanding append',
      );
      expect((await store.loadHistory(_roomId)).single, canonical.toJson());
    },
  );

  testHistory('watch errors surface and pending refresh stops after disposal', (
    tester,
  ) async {
    final store = _Store();
    final journal = history(member: true, store: store);
    await journal.load();
    store.changes.addError(StateError('Watch failed'));
    expect(journal.error, contains('Watch failed'));
    journal.dispose();
    await tester.pump(const Duration(milliseconds: 40));
    expect(store.loadCalls, 1);
  });

  test(
    'local role appends start immediately but return only after saving',
    () async {
      final store = _Store();
      final journal = history(store: store);
      final text = await journal.edit('Заметка');
      await journal.setParticipantName('Анна');
      await journal.renameRoom('Семья');
      store.appendGate = Completer<void>();
      final pending = journal.setParticipantRole('subject', RoomRole.guest);
      expect(store.authoredCalls, 4);
      expect(journal.roleFor('subject'), RoomRole.guest);
      expect(journal.participantRoles, {'subject': RoomRole.guest});
      expect(journal.roleFor('legacy'), RoomRole.editor);
      expect(journal.text, 'Заметка');
      expect(journal.participantNames, {'local': 'Анна'});
      expect(journal.roomName, 'Семья');
      expect(journal.durableLength, 3);
      expect(
        journal.durableHistory.where(
          (edit) => edit.kind == RoomEditKind.participantRole,
        ),
        isEmpty,
      );
      expect(journal.saving, isTrue);
      final snapshot = journal.participantRoles;
      expect(
        () => snapshot['subject'] = RoomRole.editor,
        throwsUnsupportedError,
      );
      store.appendGate!.complete();
      final saved = (await pending)!;
      expect(saved.kind, RoomEditKind.participantRole);
      expect(saved.author, 'local');
      expect(saved.targetActor, 'subject');
      expect(saved.text, 'guest');
      expect(journal.durableHistory, contains(saved));
      expect(journal.durableHistory, contains(text));
      expect(journal.saving, isFalse);
      final promoted = (await journal.setParticipantRole(
        'subject',
        RoomRole.editor,
      ))!;
      expect(promoted.author, 'local');
      expect(promoted.targetActor, 'subject');
      expect(promoted.text, 'editor');
      expect(journal.roleFor('subject'), RoomRole.editor);
      expect(snapshot, {'subject': RoomRole.guest});
      expect(journal.text, 'Заметка');
      expect((await store.loadHistory(_roomId)).last, promoted.toJson());
    },
  );

  test(
    'role no-ops use explicit records and never create a downgrade',
    () async {
      final store = _Store();
      final journal = history(store: store);
      expect(journal.roleFor('legacy'), RoomRole.editor);
      final explicitEditor = await journal.setParticipantRole(
        'legacy',
        RoomRole.editor,
      );
      expect(
        explicitEditor,
        isNotNull,
        reason: 'Legacy fallback is not an explicit immutable editor record',
      );
      expect(
        await journal.setParticipantRole('legacy', RoomRole.editor),
        isNull,
      );
      expect(
        await journal.setParticipantRole('legacy', RoomRole.guest),
        isNull,
      );
      final guest = await journal.setParticipantRole('subject', RoomRole.guest);
      expect(guest, isNotNull);
      expect(
        await journal.setParticipantRole('subject', RoomRole.guest),
        isNull,
      );
      expect(store.appendCalls, 2);
      expect(journal.historyLength, 2);
      expect(journal.roleFor('legacy'), RoomRole.editor);
      expect(journal.roleFor('subject'), RoomRole.guest);
      await journal.setParticipantRole('subject', RoomRole.editor);
      expect(
        await journal.setParticipantRole('subject', RoomRole.guest),
        isNull,
      );
      expect(store.appendCalls, 3);
      expect(journal.roleFor('subject'), RoomRole.editor);
    },
  );

  test(
    'failed role promotion stays nondurable and retries the same payload',
    () async {
      final store = _Store();
      final sent = <List<RoomEdit>>[];
      final journal = history(store: store, onDurableEdits: sent.add);
      final guest = (await journal.setParticipantRole(
        'subject',
        RoomRole.guest,
      ))!;
      store.failAppend = true;
      expect(
        await journal.setParticipantRole('subject', RoomRole.editor),
        isNull,
      );
      expect(journal.roleFor('subject'), RoomRole.editor);
      expect(journal.error, contains('Disk full'));
      expect(journal.durableHistory, [guest]);
      final durable = RoomDocument()..merge(journal.durableHistory);
      expect(durable.roleFor('subject'), RoomRole.guest);
      final failed = journal.knownEdits.singleWhere(
        (edit) => edit.text == 'editor',
      );
      _expectDraft(failed);
      expect(
        await journal.setParticipantRole('subject', RoomRole.editor),
        isNull,
      );
      expect(store.appendCalls, 2);
      expect(journal.changes, hasLength(2));
      await expectLater(journal.flush(), throwsStateError);
      expect(journal.durableHistory, [guest]);
      expect(sent, isEmpty);
      store.failAppend = false;
      await journal.flush();
      expect(journal.error, isNull);
      final saved = journal.durableHistory.last;
      expect(_core(saved), _core(failed));
      expect(journal.durableHistory.map(_core), [_core(guest), _core(failed)]);
      _expectPrefix(journal.durableHistory);
      expect(sent.single.single.toJson(), saved.toJson());
      expect(journal.knownEdits, hasLength(2));
      expect((await store.loadHistory(_roomId)).last, saved.toJson());
      expect(journal.text, isEmpty);
    },
  );

  test(
    'remote roles are projected only once durable, including delayed guests',
    () async {
      final store = _Store()..appendGate = Completer<void>();
      final journal = history(store: store);
      final guest = _role('initial', RoomRole.guest, clock: 100);
      final pending = journal.merge([guest]);
      expect(journal.participantRoles, isEmpty);
      store.appendGate!.complete();
      expect(await pending, [guest]);
      expect(journal.roleFor('subject'), RoomRole.guest);
      final editor = _role('promotion', RoomRole.editor);
      await journal.merge([editor]);
      final delayed = _role('delayed', RoomRole.guest, clock: 1000);
      await journal.merge([delayed]);
      expect(journal.roleFor('subject'), RoomRole.editor);
      expect(journal.changes, hasLength(3));
      expect(journal.text, isEmpty);
      expect(journal.participantNames, isEmpty);
    },
  );

  test(
    'whole-batch role conflicts check kind and subject before any write',
    () async {
      final store = _Store();
      final journal = history(store: store);
      final original = _role('same', RoomRole.guest);
      await journal.merge([original]);
      for (final mutation in <Map<String, dynamic>>[
        {'author': 'different'},
        {'clock': 2},
        {'createdAt': 2},
        {'text': 'editor'},
        {'targetActor': 'different'},
      ]) {
        final changed = RoomEdit.fromJson({...original.toJson(), ...mutation})!;
        expect(
          () => journal.merge([_edit('new', 'must not save'), changed]),
          throwsFormatException,
        );
        expect(store.appendCalls, 1);
      }
      final text = _edit('same', 'guest');
      expect(() => journal.merge([text]), throwsFormatException);
      final other = _role('duplicate', RoomRole.editor);
      expect(
        () => journal.merge([
          other,
          _role('duplicate', RoomRole.editor, targetActor: 'different'),
        ]),
        throwsFormatException,
      );
      expect(store.appendCalls, 1);
      expect(journal.participantRoles, {'subject': RoomRole.guest});
      expect(journal.historyLength, 1);
    },
  );

  testHistory('roles survive reload and validated storage refresh', (
    tester,
  ) async {
    final store = _Store();
    final guest = _role('initial', RoomRole.guest, clock: 100);
    await store.externalAppend([guest]);
    final journal = history(member: true, store: store);
    expect(
      await journal.setParticipantRole('subject', RoomRole.editor),
      isNull,
    );
    expect(store.appendCalls, 0);
    expect(journal.error, contains('Сначала'));
    await journal.load();
    expect(journal.roleFor('subject'), RoomRole.guest);
    expect(journal.durableHistory, hasLength(1));
    await store.externalAppend([_role('promotion', RoomRole.editor)]);
    await tester.pump(const Duration(milliseconds: 40));
    expect(journal.roleFor('subject'), RoomRole.editor);
    expect(journal.durableLength, 2);
    expect(store.appendCalls, 0);
    final reloaded = history(member: true, store: store);
    await reloaded.load();
    expect(reloaded.participantRoles, journal.participantRoles);
    expect(
      reloaded.durableHistory.map((edit) => edit.toJson()),
      journal.durableHistory.map((edit) => edit.toJson()),
    );
    store.loadedHistory = [
      _role('new', RoomRole.guest, targetActor: 'new').toJson(),
      {...guest.toJson(), 'targetActor': 'changed'},
    ];
    await journal.refresh();
    expect(journal.error, contains('Не удалось обновить'));
    expect(journal.participantRoles, {'subject': RoomRole.editor});
    expect(journal.durableLength, 2);
  });

  test('invalid role targets do not start a durable write', () async {
    final store = _Store();
    final journal = history(store: store);
    for (final target in ['', 'a' * 129]) {
      expect(
        () => journal.setParticipantRole(target, RoomRole.guest),
        throwsFormatException,
      );
    }
    expect(store.appendCalls, 0);
    expect(journal.participantRoles, isEmpty);
    expect(journal.changes, isEmpty);
    journal.dispose();
    expect(await journal.setParticipantRole('subject', RoomRole.guest), isNull);
    expect(store.appendCalls, 0);
  });

  test(
    'membership guard runs after saving notification; errors are visible',
    () async {
      final store = _Store();
      var admissible = true;
      final journal = history(
        store: store,
        onChanged: () => admissible = false,
      );
      expect(
        await journal.saveMembership(stillAdmissible: () => admissible),
        isFalse,
      );
      expect(store.membershipCalls, 0);
      expect(journal.saving, isFalse);
      store.failMembership = true;
      expect(
        await journal.saveMembership(stillAdmissible: () => true),
        isFalse,
      );
      expect(store.membershipCalls, 1);
      expect(journal.error, contains('Membership failed'));
      expect(journal.savingCount, 0);
      expect(await store.hasMembership(_roomId), isFalse);
    },
  );
}
