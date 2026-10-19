@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/local/room_tabs.dart';
import 'package:mytree_webrtc_demo/local/room_tabs_web.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';
import 'package:mytree_webrtc_demo/storage/web_room_store.dart';
import 'package:web/web.dart' as web;

const _clientKey = 'mytree.room-store.v1.client-id';

@JS('Storage.prototype')
external JSObject get _storagePrototype;

@JS('Object.getOwnPropertyDescriptor')
external JSObject? _descriptor(JSObject target, JSString key);

@JS('Object.defineProperty')
external JSObject _defineProperty(
  JSObject target,
  JSString key,
  JSObject value,
);

@JS('Reflect.deleteProperty')
external JSBoolean _deleteProperty(JSObject target, JSString key);

extension type _Property._(JSObject _) implements JSObject {
  external factory _Property({JSAny? value, bool configurable, bool writable});
}

extension type _StorageMethods(JSObject _) implements JSObject {
  external JSFunction get setItem;
}

void _replaceProperty(JSObject target, String name, JSAny? value) {
  final key = name.toJS;
  final original = _descriptor(target, key);
  _defineProperty(
    target,
    key,
    _Property(value: value, configurable: true, writable: true),
  );
  addTearDown(() {
    if (original == null) {
      _deleteProperty(target, key);
    } else {
      _defineProperty(target, key, original);
    }
  });
}

String _key(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');
String _journalLock(String room) =>
    'mytree.room-store.v1.journal.${_key(room)}';
String _operationKey(String room, String id) =>
    'mytree.room-store.v1.room.${_key(room)}.operation.${_key(id)}';
String _credentialsKey(String room, [String? bindingId]) =>
    'mytree.room-store.v1.room.${_key(room)}.disk-credentials'
    '${bindingId == null ? '' : '.binding.${_key(bindingId)}'}';
Map<String, dynamic> _credentials({
  String bindingId = 'binding',
  String token = 'local-only-token',
}) => {'v': 1, 'bindingId': bindingId, 'token': token};

String _newRoom() {
  final room = createRoomId();
  addTearDown(() {
    final storage = web.window.localStorage;
    final prefix = 'mytree.room-store.v1.room.${_key(room)}.';
    final keys = [
      for (var index = 0; index < storage.length; index++) storage.key(index),
    ];
    for (final key in keys) {
      if (key != null && key.startsWith(prefix)) storage.removeItem(key);
    }
    const lastRoomKey = 'mytree.room-store.v1.last-room';
    if (storage.getItem(lastRoomKey) == jsonEncode(room)) {
      storage.removeItem(lastRoomKey);
    }
  });
  return room;
}

RoomEdit _draft(String id, {String author = 'actor', int clock = 1}) =>
    RoomEdit(id: id, author: author, clock: clock, createdAt: 1, text: id);

List<RoomEdit> _prefix() {
  final first = sequenceAuthoredEdit(_draft('first', clock: 3), []);
  final second = sequenceAuthoredEdit(_draft('second', clock: 2), [first]);
  final third = sequenceAuthoredEdit(_draft('third', clock: 1), [
    first,
    second,
  ]);
  return [first, second, third];
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for browser tab coordination');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

RoomTabState _state(String room, String actor, {int count = 2}) => RoomTabState(
  roomId: room,
  actorId: actor,
  onlineCount: count,
  initialSyncComplete: true,
  localCopyOpened: false,
  status: 'Online',
  initialSyncStatus: 'Ready',
  inventory: {'edit': List.filled(64, 'a').join()},
);

void main() {
  setUp(() => web.window.localStorage.removeItem(_clientKey));
  tearDown(() => web.window.localStorage.removeItem(_clientKey));

  test(
    'recent-host hint is tab sessionStorage only and never membership',
    () async {
      final room = createRoomId();
      final key = 'mytree.room-tabs.v1.recent-host.$room';
      addTearDown(() => forgetRecentRoomHost(room));
      expect(recentRoomHostSeen(room), isNull);
      rememberRecentRoomHost(room);
      final seen = recentRoomHostSeen(room);
      expect(seen, isNotNull);
      final stored = web.window.sessionStorage.getItem(key);
      expect(stored, seen!.millisecondsSinceEpoch.toString());
      expect(web.window.localStorage.getItem(key), isNull);
      expect(await WebRoomStore().hasMembership(room), isFalse);
      // UI notifications/typing do not rewrite storage inside the 5s throttle.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      rememberRecentRoomHost(room);
      expect(web.window.sessionStorage.getItem(key), stored);
      forgetRecentRoomHost(room);
      expect(recentRoomHostSeen(room), isNull);
      expect(web.window.sessionStorage.getItem(key), isNull);
      rememberRecentRoomHost(room);
      expect(
        recentRoomHostSeen(room),
        isNotNull,
        reason: 'forget also resets the throttle',
      );
    },
  );

  test('expired, malformed and future host hints are ignored', () {
    final room = createRoomId();
    final key = 'mytree.room-tabs.v1.recent-host.$room';
    addTearDown(() => forgetRecentRoomHost(room));
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final invalid in [
      'not an integer',
      '0',
      '-1',
      '${now + 10000}',
      '${now - 60001}',
    ]) {
      web.window.sessionStorage.setItem(key, invalid);
      expect(recentRoomHostSeen(room), isNull, reason: invalid);
    }
    web.window.sessionStorage.setItem(key, '${now - 59000}');
    expect(recentRoomHostSeen(room), isNotNull);
    rememberRecentRoomHost('invalid-room');
    forgetRecentRoomHost('invalid-room');
    expect(recentRoomHostSeen('invalid-room'), isNull);
  });

  test('browser stores share one durable random client identity', () async {
    final stores = List.generate(24, (_) => WebRoomStore());
    expect(stores.every((store) => store.sharedAcrossTabs), isTrue);
    final ids = await Future.wait(stores.map((store) => store.loadClientId()));
    expect(ids.toSet(), hasLength(1));
    expect(isValidRoomId(ids.first), isTrue);
    expect(await WebRoomStore().loadClientId(), ids.first);
    expect(jsonDecode(web.window.localStorage.getItem(_clientKey)!), ids.first);
  });

  test(
    'client ID re-read and write wait inside the origin-wide lock',
    () async {
      final held = Completer<void>();
      final release = Completer<JSAny?>();
      addTearDown(() {
        if (!release.isCompleted) release.complete(null);
      });
      final blocker = web.window.navigator.locks
          .request(
            _clientKey,
            web.LockOptions(mode: 'exclusive'),
            ((web.Lock lock) {
              held.complete();
              return release.future.toJS;
            }).toJS,
          )
          .toDart;
      await held.future;
      var completed = false;
      final reading = WebRoomStore().loadClientId().then((id) {
        completed = true;
        return id;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(completed, isFalse);
      final existing = createRoomId();
      web.window.localStorage.setItem(_clientKey, jsonEncode(existing));
      release.complete(null);
      expect(await reading, existing);
      await blocker;
    },
  );

  test(
    'malformed durable identity errors and a retry releases its lock',
    () async {
      final store = WebRoomStore();
      for (final encoded in ['not JSON', 'null', '"not-a-client-id"']) {
        web.window.localStorage.setItem(_clientKey, encoded);
        await expectLater(store.loadClientId(), throwsFormatException);
        expect(web.window.localStorage.getItem(_clientKey), encoded);
      }
      web.window.localStorage.removeItem(_clientKey);
      expect(isValidRoomId(await store.loadClientId()), isTrue);
    },
  );

  test(
    'Disk credentials persist separately from history and membership',
    () async {
      final room = _newRoom();
      final other = _newRoom();
      final store = WebRoomStore();
      expect(await store.loadDiskCredentials(room), isNull);
      final input = _credentials();
      final saving = store.saveDiskCredentials(room, input);
      input['token'] = 'mutated-input';
      await saving;
      expect(await WebRoomStore().loadDiskCredentials(room), _credentials());
      expect(await store.loadDiskCredentials(other), isNull);
      expect(await store.loadHistory(room), isEmpty);
      expect(await store.hasMembership(room), isFalse);
      expect(await store.loadLastRoom(), isNull);
      expect(
        jsonDecode(web.window.localStorage.getItem(_credentialsKey(room))!),
        _credentials(),
      );
      final loaded = (await store.loadDiskCredentials(room))!;
      loaded['token'] = 'mutated-return';
      expect(await store.loadDiskCredentials(room), _credentials());
      final connect = RoomDocument().createEdit(
        'actor',
        '{"action":"connect"}',
        kind: RoomEditKind.diskConnection,
        id: 'binding',
      );
      await store.appendAuthoredHistory(room, [connect.toJson()]);
      await store.saveMembership(room);
      final history = await store.loadHistory(room);
      expect(history.single['id'], 'binding');
      expect(jsonEncode(history), isNot(contains('token')));
      await store.saveDiskCredentials(room, _credentials(token: 'replacement'));
      expect(
        await WebRoomStore().loadDiskCredentials(room),
        _credentials(token: 'replacement'),
      );
      await store.saveDiskCredentials(room, null);
      await store.saveDiskCredentials(room, null);
      expect(web.window.localStorage.getItem(_credentialsKey(room)), isNull);
      expect(await WebRoomStore().loadDiskCredentials(room), isNull);
      expect(await store.loadHistory(room), history);
      expect(await store.hasMembership(room), isTrue);
      expect(await store.loadLastRoom(), room);
    },
  );

  test(
    'competing browser credential stages retain both binding archives',
    () async {
      final room = _newRoom();
      final first = _credentials(bindingId: 'first', token: 'first-secret');
      final second = _credentials(bindingId: 'second', token: 'second-secret');
      final firstStore = WebRoomStore();
      final secondStore = WebRoomStore();
      await Future.wait([
        firstStore.saveDiskCredentials(room, first),
        secondStore.saveDiskCredentials(room, second, bindingId: 'second'),
      ]);
      final reopened = WebRoomStore();
      expect(await reopened.loadDiskCredentials(room), second);
      expect(
        await reopened.loadDiskCredentials(room, bindingId: 'first'),
        first,
      );
      expect(
        await reopened.loadDiskCredentials(room, bindingId: 'second'),
        second,
      );
      await firstStore.saveDiskCredentials(room, null, bindingId: 'first');
      expect(
        await reopened.loadDiskCredentials(room, bindingId: 'first'),
        isNull,
      );
      expect(await reopened.loadDiskCredentials(room), second);
      await firstStore.saveDiskCredentials(room, first);
      await secondStore.saveDiskCredentials(room, null, bindingId: 'first');
      expect(await reopened.loadDiskCredentials(room), isNull);
      expect(
        await reopened.loadDiskCredentials(room, bindingId: 'second'),
        second,
      );
      await reopened.saveDiskCredentials(room, null);
      expect(
        await reopened.loadDiskCredentials(room, bindingId: 'second'),
        isNull,
      );
      expect(
        web.window.localStorage.getItem(_credentialsKey(room, 'second')),
        isNull,
      );
      expect(await reopened.loadHistory(room), isEmpty);
    },
  );

  test(
    'browser credentials support legacy pointers and validate archive bindings',
    () async {
      final room = _newRoom();
      final first = _credentials(bindingId: 'first');
      final second = _credentials(bindingId: 'second', token: 'second-secret');
      final storage = web.window.localStorage;
      storage.setItem(_credentialsKey(room), jsonEncode(first));
      final store = WebRoomStore();
      expect(await store.loadDiskCredentials(room, bindingId: 'first'), first);
      expect(
        await store.loadDiskCredentials(room, bindingId: 'second'),
        isNull,
      );
      await store.saveDiskCredentials(room, second);
      expect(
        await WebRoomStore().loadDiskCredentials(room, bindingId: 'first'),
        first,
      );
      storage.setItem(
        _credentialsKey(room, 'first'),
        jsonEncode(_credentials(bindingId: 'wrong')),
      );
      await expectLater(
        store.loadDiskCredentials(room, bindingId: 'first'),
        throwsFormatException,
      );
      for (final invalidId in ['', 'x' * 129]) {
        await expectLater(
          store.loadDiskCredentials(room, bindingId: invalidId),
          throwsArgumentError,
        );
        await expectLater(
          store.saveDiskCredentials(room, null, bindingId: invalidId),
          throwsArgumentError,
        );
      }
      await expectLater(
        store.saveDiskCredentials(room, second, bindingId: 'different'),
        throwsFormatException,
      );
      expect(await store.loadDiskCredentials(room), second);
      await store.saveDiskCredentials(room, null, bindingId: 'first');
      expect(await store.loadDiskCredentials(room), second);
      expect(await store.loadDiskCredentials(room, bindingId: 'first'), isNull);
    },
  );

  test(
    'Disk credentials reject malformed values and redact stored secrets',
    () async {
      final room = _newRoom();
      final store = WebRoomStore();
      final value = _credentials();
      await store.saveDiskCredentials(room, value);
      for (final invalid in <Map<String, dynamic>>[
        {},
        {...value}..remove('v'),
        {...value}..remove('bindingId'),
        {...value}..remove('token'),
        {...value, 'extra': 'secret-marker'},
        for (final v in <Object?>[0, 2, '1', null, true]) {...value, 'v': v},
        for (final id in <Object?>['', 'x' * 129, null, 1])
          {...value, 'bindingId': id},
        for (final token in <Object?>[
          '',
          ' secret-marker',
          'secret-marker\n',
          'secret-marker\u007f',
          'секрет',
          'x' * 4097,
          null,
          1,
          {},
          Object(),
        ])
          {...value, 'token': token},
      ]) {
        await expectLater(
          store.saveDiskCredentials(room, invalid),
          throwsFormatException,
        );
        expect(await store.loadDiskCredentials(room), value);
      }
      for (final invalidRoom in ['', 'room', ' ', '../room', 'A' * 32]) {
        await expectLater(
          store.loadDiskCredentials(invalidRoom),
          throwsArgumentError,
        );
        await expectLater(
          store.saveDiskCredentials(invalidRoom, value),
          throwsArgumentError,
        );
        await expectLater(
          store.saveDiskCredentials(invalidRoom, null),
          throwsArgumentError,
        );
      }
      await store.appendHistory(room, [
        {'id': 'intact'},
      ]);
      final key = _credentialsKey(room);
      for (final encoded in [
        'secret-marker not JSON',
        'null',
        '[]',
        '"secret-marker"',
        '{}',
        '{"v":1,"bindingId":"binding","token":null}',
        '{"v":1,"bindingId":"binding","token":"secret-marker","extra":1}',
        '{"v":1,"bindingId":"binding","token":"secret-marker","token":"duplicate"}',
      ]) {
        web.window.localStorage.setItem(key, encoded);
        await expectLater(
          store.loadDiskCredentials(room),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'redacted diagnostic',
              isNot(contains('secret-marker')),
            ),
          ),
        );
        await expectLater(
          store.saveDiskCredentials(room, value),
          throwsFormatException,
        );
        expect(web.window.localStorage.getItem(key), encoded);
        expect(await store.loadHistory(room), [
          {'id': 'intact'},
        ]);
      }
      await store.saveDiskCredentials(room, null);
      expect(await store.loadDiskCredentials(room), isNull);
      expect(await store.loadHistory(room), [
        {'id': 'intact'},
      ]);
      final maximumToken = _credentials(token: '!' * 4096);
      await store.saveDiskCredentials(room, maximumToken);
      expect(await store.loadDiskCredentials(room), maximumToken);
    },
  );

  test(
    'credential save failure propagates without modifying history',
    () async {
      final room = _newRoom();
      final store = WebRoomStore();
      await store.saveDiskCredentials(room, _credentials());
      await store.appendHistory(room, [
        {'id': 'intact'},
      ]);
      final key = _credentialsKey(room);
      final storage = web.window.localStorage;
      final setItem = _StorageMethods(storage).setItem;
      var failWrite = true;
      _replaceProperty(
        _storagePrototype,
        'setItem',
        ((JSString name, JSString value) {
          if (name.toDart == key && failWrite) {
            throw StateError('Injected quota failure');
          }
          setItem.callAsFunction(storage, name, value);
        }).toJS,
      );
      await expectLater(
        store.saveDiskCredentials(room, _credentials(token: 'replacement')),
        throwsStateError,
      );
      expect(await store.loadDiskCredentials(room), _credentials());
      expect(
        await store.loadDiskCredentials(room, bindingId: 'binding'),
        _credentials(token: 'replacement'),
      );
      expect(await store.loadHistory(room), [
        {'id': 'intact'},
      ]);
      failWrite = false;
      await store.saveDiskCredentials(room, _credentials(token: 'replacement'));
      expect(
        await store.loadDiskCredentials(room),
        _credentials(token: 'replacement'),
      );
    },
  );

  test(
    'history watcher signals credential changes without exposing values',
    () async {
      final room = _newRoom();
      final store = WebRoomStore();
      final signals = <void>[];
      final subscription = store.watchHistory(room).listen(signals.add);
      addTearDown(subscription.cancel);
      final frame = web.HTMLIFrameElement()..src = 'about:blank';
      frame.style.display = 'none';
      final loaded = Completer<void>();
      frame.addEventListener('load', ((web.Event _) => loaded.complete()).toJS);
      web.document.body!.appendChild(frame);
      addTearDown(() => frame.remove());
      await loaded.future;
      // A second real same-origin document writes its own Storage object. The
      // browser, not the test, must deliver the corresponding storage event.
      final otherStorage = frame.contentWindow!.localStorage;
      otherStorage.setItem(_credentialsKey(room), jsonEncode(_credentials()));
      await _until(() => signals.isNotEmpty);
      expect(signals, [null]);
      expect(await store.loadDiskCredentials(room), _credentials());
      expect(await store.loadHistory(room), isEmpty);
      final staged = _credentials(bindingId: 'second');
      otherStorage.setItem(_credentialsKey(room, 'second'), jsonEncode(staged));
      await _until(() => signals.length == 2);
      expect(
        await store.loadDiskCredentials(room, bindingId: 'second'),
        staged,
      );
      otherStorage.setItem(
        _credentialsKey(_newRoom()),
        jsonEncode(_credentials()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(signals, hasLength(2));
      otherStorage.removeItem(_credentialsKey(room));
      await _until(() => signals.length == 3);
      expect(await store.loadDiskCredentials(room), isNull);
      expect(
        await store.loadDiskCredentials(room, bindingId: 'second'),
        staged,
      );
    },
  );

  test(
    'journal authoring serializes independent stores of the same actor',
    () async {
      final room = _newRoom();
      final stores = List.generate(12, (_) => WebRoomStore());
      final writes = [
        for (var index = 0; index < stores.length; index++)
          stores[index].appendAuthoredHistory(room, [
            _draft('edit-$index', clock: stores.length - index).toJson(),
          ]),
      ];
      final returned = await Future.wait(writes);
      expect(
        returned.map((history) => history.length),
        orderedEquals(List.generate(12, (index) => index + 1)),
      );
      final history = validateAuthorHistory(
        decodeRoomHistory(await WebRoomStore().loadHistory(room)),
      );
      expect(
        history.map((edit) => edit.authorSequence),
        orderedEquals(List.generate(12, (index) => index + 1)),
      );
      expect(
        history.map((edit) => edit.id),
        orderedEquals(List.generate(12, (index) => 'edit-$index')),
      );
      for (var index = 1; index < history.length; index++) {
        expect(history[index].authorPrevious, history[index - 1].id);
      }
    },
  );

  test(
    'authored, remote, and read operations wait for the same journal lock',
    () async {
      final room = _newRoom();
      final held = Completer<void>();
      final release = Completer<JSAny?>();
      addTearDown(() {
        if (!release.isCompleted) release.complete(null);
      });
      final blocker = web.window.navigator.locks
          .request(
            _journalLock(room),
            web.LockOptions(mode: 'exclusive'),
            ((web.Lock lock) {
              held.complete();
              return release.future.toJS;
            }).toJS,
          )
          .toDart;
      await held.future;
      final completed = <String>[];
      final draft = _draft('local').toJson();
      final authored = WebRoomStore().appendAuthoredHistory(room, [draft]).then(
        (history) {
          completed.add('authored');
          return history;
        },
      );
      draft['text'] = 'mutated after queueing';
      final remote = sequenceAuthoredEdit(
        _draft('remote', author: 'other'),
        [],
      );
      final writing = WebRoomStore()
          .appendHistory(room, [remote.toJson()])
          .then((_) => completed.add('remote'));
      final reading = WebRoomStore().loadHistory(room).then((history) {
        completed.add('read');
        return history;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(completed, isEmpty);
      final legacy = _draft('legacy', clock: 10).toJson();
      web.window.localStorage.setItem(
        _operationKey(room, 'legacy'),
        jsonEncode(legacy),
      );
      release.complete(null);
      final result = await authored;
      expect(result.map((raw) => raw['id']), ['legacy', 'local']);
      expect(result.last['authorBase'], ['legacy']);
      expect(result.last['text'], 'local');
      await writing;
      expect(await reading, hasLength(3));
      expect(completed, ['authored', 'remote', 'read']);
      await blocker;
    },
  );

  test(
    'remote author closure is checked before writes and stored predecessor-first',
    () async {
      final room = _newRoom();
      final store = WebRoomStore();
      final prefix = _prefix();
      await expectLater(
        store.appendHistory(room, [
          _draft('unrelated', author: 'other').toJson(),
          prefix.last.toJson(),
        ]),
        throwsFormatException,
      );
      expect(await store.loadHistory(room), isEmpty);
      final storage = web.window.localStorage;
      final setItem = _StorageMethods(storage).setItem;
      final writes = <String>[];
      _replaceProperty(
        _storagePrototype,
        'setItem',
        ((JSString key, JSString value) {
          writes.add(key.toDart);
          setItem.callAsFunction(storage, key, value);
        }).toJS,
      );
      await store.appendHistory(
        room,
        prefix.reversed.map((edit) => edit.toJson()).toList(),
      );
      expect(writes, [for (final edit in prefix) _operationKey(room, edit.id)]);
      expect(
        await store.loadHistory(room),
        prefix.map((edit) => edit.toJson()),
      );
      await expectLater(
        store.appendHistory(room, [
          sequenceAuthoredEdit(_draft('fork'), []).toJson(),
        ]),
        throwsFormatException,
      );
      expect(writes, hasLength(3));
    },
  );

  test(
    'authored retry reuses exact canonical bytes after a partial write failure',
    () async {
      final room = _newRoom();
      final store = WebRoomStore();
      final storage = web.window.localStorage;
      final setItem = _StorageMethods(storage).setItem;
      var writes = 0;
      _replaceProperty(
        _storagePrototype,
        'setItem',
        ((JSString key, JSString value) {
          writes++;
          if (writes == 2) throw StateError('Injected quota-like failure');
          setItem.callAsFunction(storage, key, value);
        }).toJS,
      );
      final drafts = [
        for (final id in ['a', 'b', 'c']) _draft(id).toJson(),
      ];
      await expectLater(
        store.appendAuthoredHistory(room, drafts),
        throwsStateError,
      );
      final prefix = await store.loadHistory(room);
      expect(prefix, hasLength(1));
      final original = storage.getItem(_operationKey(room, 'a'));
      final result = await WebRoomStore().appendAuthoredHistory(room, drafts);
      expect(result.map((raw) => raw['authorSequence']), [1, 2, 3]);
      expect(storage.getItem(_operationKey(room, 'a')), original);
      expect(writes, 4, reason: 'Canonical prefix is not rewritten on retry');
      expect(await store.appendAuthoredHistory(room, drafts), result);
      expect(writes, 4);
    },
  );

  test('browser reads reject a persisted incomplete author prefix', () async {
    final room = _newRoom();
    final raw = _prefix().last.toJson();
    final key = _operationKey(room, raw['id'] as String);
    final encoded = jsonEncode(raw);
    web.window.localStorage.setItem(key, encoded);
    final store = WebRoomStore();
    await expectLater(store.loadHistory(room), throwsFormatException);
    await expectLater(
      store.appendAuthoredHistory(room, [_draft('new').toJson()]),
      throwsFormatException,
    );
    expect(web.window.localStorage.getItem(key), encoded);
    expect(web.window.localStorage.getItem(_operationKey(room, 'new')), isNull);
  });

  test(
    'without Web Locks new authoring fails explicitly but legacy JSON still works',
    () async {
      final room = _newRoom();
      _replaceProperty(web.window.navigator, 'locks', null);
      final store = WebRoomStore();
      await expectLater(
        store.appendAuthoredHistory(room, [_draft('new').toJson()]),
        throwsUnsupportedError,
      );
      expect(
        web.window.localStorage.getItem(_operationKey(room, 'new')),
        isNull,
      );
      final prefix = _prefix();
      await expectLater(
        store.appendHistory(room, prefix.map((edit) => edit.toJson()).toList()),
        throwsUnsupportedError,
      );
      expect(await store.loadHistory(room), isEmpty);
      final legacy = {
        'id': 'plain-json',
        'nested': {'value': 1},
      };
      final saving = store.appendHistory(room, [legacy]);
      (legacy['nested'] as Map)['value'] = 99;
      await saving;
      expect(await store.loadHistory(room), [
        {
          'id': 'plain-json',
          'nested': {'value': 1},
        },
      ]);
    },
  );

  test(
    'shared history stays in storage, tab state never saves membership',
    () async {
      final room = createRoomId();
      final store = WebRoomStore();
      final actor = await store.loadClientId();
      final leader = createRoomTabs(room, actor)!;
      final follower = createRoomTabs(room, actor)!;
      addTearDown(leader.dispose);
      addTearDown(follower.dispose);
      await leader.start();
      await follower.start().timeout(const Duration(seconds: 5));
      expect(leader.isLeader, isTrue);
      expect(follower.isLeader, isFalse);
      final states = <RoomTabState>[];
      final subscription = follower.onState.listen(states.add);
      addTearDown(subscription.cancel);
      await store.appendHistory(room, [
        {'id': 'edit', 'text': 'persisted before checkpoint'},
      ]);
      leader.publish(_state(room, actor));
      await _until(() => states.isNotEmpty);
      expect(states.last.initialSyncComplete, isTrue);
      expect(states.last.inventory, _state(room, actor).inventory);
      expect(await WebRoomStore().loadHistory(room), [
        {'id': 'edit', 'text': 'persisted before checkpoint'},
      ]);
      expect(await store.hasMembership(room), isFalse);
      expect(await store.loadLastRoom(), isNull);
      leader.publish(_state(room, actor, count: 3));
      await _until(() => states.last.onlineCount == 3);
      // A later follower asks a live owner for its cached state, rather than
      // treating localStorage history or somebody else's ready response as proof.
      final later = createRoomTabs(room, actor)!;
      addTearDown(later.dispose);
      final laterState = later.onState.first;
      await later.start();
      expect((await laterState).onlineCount, 3);
      expect(await store.hasMembership(room), isFalse);
    },
  );

  test(
    'dispose aborts queued tabs and elects one owner without lock stealing',
    () async {
      final room = createRoomId();
      final actor = await WebRoomStore().loadClientId();
      final leader = createRoomTabs(room, actor)!;
      final cancelled = createRoomTabs(room, actor)!;
      final successor = createRoomTabs(room, actor)!;
      final follower = createRoomTabs(room, actor)!;
      for (final tabs in [leader, cancelled, successor, follower]) {
        addTearDown(tabs.dispose);
      }
      await leader.start();
      await cancelled.start();
      await successor.start();
      await follower.start();
      cancelled.dispose();
      leader.dispose();
      await _until(() => successor.isLeader);
      expect(cancelled.isLeader, isFalse);
      expect(leader.isLeader, isFalse);
      expect(follower.isLeader, isFalse);
      final nextState = follower.onState.first;
      successor.publish(_state(room, actor, count: 4));
      expect((await nextState).onlineCount, 4);
      successor.dispose();
      await _until(() => follower.isLeader);
    },
  );

  test(
    'a tab disposed during startup cannot later acquire ownership',
    () async {
      final room = createRoomId();
      final actor = await WebRoomStore().loadClientId();
      final disposed = createRoomTabs(room, actor)!;
      final starting = disposed.start();
      disposed.dispose();
      await starting.timeout(const Duration(seconds: 5));
      final replacement = createRoomTabs(room, actor)!;
      addTearDown(replacement.dispose);
      await replacement.start();
      await _until(() => replacement.isLeader);
      expect(disposed.isLeader, isFalse);
    },
  );

  test(
    'unmatched or invalid bus snapshots never become accepted tab state',
    () async {
      final room = createRoomId();
      final actor = await WebRoomStore().loadClientId();
      final channel = web.BroadcastChannel(
        'mytree.room-tabs.v1.${jsonEncode([room, actor])}',
      );
      addTearDown(() => channel.close());
      final traffic = <Map<String, dynamic>>[];
      final listener = ((web.Event event) {
        final data = (event as web.MessageEvent).data;
        if (data != null && data.isA<JSString>()) {
          traffic.add(
            jsonDecode((data as JSString).toDart) as Map<String, dynamic>,
          );
        }
      }).toJS;
      channel.addEventListener('message', listener);
      addTearDown(() => channel.removeEventListener('message', listener));
      final leader = createRoomTabs(room, actor)!;
      final follower = createRoomTabs(room, actor)!;
      addTearDown(leader.dispose);
      addTearDown(follower.dispose);
      final states = <RoomTabState>[];
      final subscription = follower.onState.listen(states.add);
      addTearDown(subscription.cancel);
      await leader.start();
      await follower.start();
      await _until(
        () => traffic.any((message) => message['kind'] == 'request'),
      );
      final owner = traffic.firstWhere(
        (message) => message['kind'] == 'leader',
      );
      final request = traffic.lastWhere(
        (message) => message['kind'] == 'request',
      );
      final response = <String, dynamic>{
        'v': 1,
        'roomId': room,
        'actorId': actor,
        'kind': 'state',
        'term': owner['term'],
        'owner': owner['owner'],
        'to': request['from'],
        'request': request['request'],
        'state': _state(room, actor).toJson(),
      };
      for (final bad in <Map<String, dynamic>>[
        {...response, 'request': createRoomId()},
        {...response, 'term': createRoomId()},
        {...response, 'roomId': createRoomId()},
        {...response, 'actorId': createRoomId()},
        {
          ...response,
          'state': {..._state(room, actor).toJson(), 'onlineCount': 0},
        },
        {
          ...response,
          'state': {..._state(room, actor).toJson(), 'roomId': createRoomId()},
        },
      ]) {
        channel.postMessage(jsonEncode(bad).toJS);
      }
      channel.postMessage('not JSON'.toJS);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(states, isEmpty);
      leader.publish(_state(room, actor));
      await _until(() => states.isNotEmpty);
      expect(states.single.roomId, room);
      expect(
        traffic.every((message) => !message.containsKey('history')),
        isTrue,
      );
    },
  );
}
