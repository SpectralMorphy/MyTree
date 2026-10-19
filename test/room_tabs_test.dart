import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/local/room_tabs.dart';
import 'package:mytree_webrtc_demo/local/room_tabs_stub.dart';

const _room = '0123456789abcdef0123456789abcdef';

RoomTabState _state({Map<String, String> inventory = const {}}) => RoomTabState(
  roomId: _room,
  actorId: 'actor',
  onlineCount: 2,
  initialSyncComplete: true,
  localCopyOpened: false,
  status: 'Онлайн · участников: 2',
  initialSyncStatus: 'История комнаты проверена',
  inventory: inventory,
);

void main() {
  test(
    'local checkpoint is immutable and JSON round-trips without editor text',
    () {
      final inventory = {'edit': 'a' * 64};
      final state = _state(inventory: inventory);
      inventory.clear();
      expect(state.inventory.keys, ['edit']);
      expect(() => state.inventory.clear(), throwsUnsupportedError);
      final decoded = RoomTabState.fromJson(
        jsonDecode(jsonEncode(state.toJson())),
      )!;
      expect(decoded.toJson(), state.toJson());
      expect(state.toJson().containsKey('history'), isFalse);
      expect(state.toJson().containsKey('text'), isFalse);
    },
  );

  test('malformed local readiness cannot become a valid checkpoint', () {
    final value = _state(inventory: {'edit': 'a' * 64}).toJson();
    for (final invalid in <Object?>[
      null,
      [],
      {...value, 'v': 1.0},
      {...value, 'v': 2},
      {...value, 'roomId': 'unknown'},
      {...value, 'actorId': ''},
      {...value, 'actorId': 'a' * 129},
      {...value, 'onlineCount': 0},
      {...value, 'onlineCount': 100001},
      {...value, 'onlineCount': 2.0},
      {...value, 'initialSyncComplete': 'true'},
      {...value, 'localCopyOpened': null},
      {...value, 'status': 1},
      {...value, 'initialSyncStatus': 'a' * 4097},
      {...value, 'initialSyncError': {}},
      {...value, 'inventory': []},
      {
        ...value,
        'inventory': {'': 'a' * 64},
      },
      {
        ...value,
        'inventory': {'edit': 'a' * 63},
      },
      {
        ...value,
        'inventory': {'edit': 'G' * 64},
      },
    ]) {
      expect(RoomTabState.fromJson(invalid), isNull, reason: '$invalid');
    }
  });

  test(
    'explicit local-copy mode stays distinct from completed network entry',
    () {
      final state = RoomTabState.fromJson({
        ..._state().toJson(),
        'initialSyncComplete': false,
        'localCopyOpened': true,
        'initialSyncError': 'Сигналинг недоступен',
      })!;
      expect(state.initialSyncComplete, isFalse);
      expect(state.localCopyOpened, isTrue);
      expect(state.initialSyncError, isNotNull);
    },
  );

  test(
    'online roster and availability round trip as immutable tab snapshots',
    () {
      final actors = ['actor', 'remote'];
      final inventory = {'name-op': 'a' * 64, 'title-op': 'b' * 64};
      final state = RoomTabState(
        roomId: _room,
        actorId: 'actor',
        onlineCount: 2,
        onlineActors: actors,
        networkAvailable: true,
        initialSyncComplete: true,
        localCopyOpened: false,
        status: 'Онлайн · участников: 2',
        initialSyncStatus: 'История комнаты проверена',
        inventory: inventory,
      );
      actors.clear();
      inventory.clear();
      expect(state.onlineActors, ['actor', 'remote']);
      expect(state.inventory, hasLength(2));
      expect(() => state.onlineActors!.clear(), throwsUnsupportedError);
      final decoded = RoomTabState.fromJson(
        jsonDecode(jsonEncode(state.toJson())),
      )!;
      expect(decoded.networkAvailable, isTrue);
      expect(decoded.onlineActors, ['actor', 'remote']);
      expect(decoded.toJson(), state.toJson());
      expect(() => decoded.onlineActors!.clear(), throwsUnsupportedError);
      for (final key in ['history', 'text', 'roomName', 'participantNames']) {
        expect(decoded.toJson().containsKey(key), isFalse);
      }
    },
  );

  test(
    'offline tab states cannot advertise online actors or imply networking',
    () {
      final value = _state().toJson();
      final legacy = {...value}..remove('networkAvailable');
      expect(RoomTabState.fromJson(legacy)!.networkAvailable, isFalse);
      expect(RoomTabState.fromJson(legacy)!.onlineActors, isNull);
      final offline = RoomTabState.fromJson({
        ...value,
        'networkAvailable': false,
        'onlineActors': [],
      })!;
      expect(offline.networkAvailable, isFalse);
      expect(offline.onlineActors, isEmpty);
      expect(offline.initialSyncComplete, isTrue);
      expect(
        RoomTabState.fromJson({
          ...value,
          'networkAvailable': false,
          'onlineActors': ['actor'],
        }),
        isNull,
      );
    },
  );

  test(
    'tab roster validates availability, actor identities, count and self',
    () {
      final value = {
        ..._state().toJson(),
        'networkAvailable': true,
        'onlineActors': ['actor', 'remote'],
      };
      expect(RoomTabState.fromJson(value), isNotNull);
      for (final invalid in <Map<String, dynamic>>[
        {'networkAvailable': null},
        {'networkAvailable': 1},
        {'networkAvailable': 'true'},
        {'onlineActors': null},
        {'onlineActors': {}},
        {'onlineActors': 'actor'},
        {'onlineActors': []},
        {
          'onlineActors': ['actor'],
        },
        {
          'onlineActors': ['actor', 'actor'],
        },
        {
          'onlineActors': ['remote', 'third'],
        },
        {
          'onlineActors': ['actor', ''],
        },
        {
          'onlineActors': ['actor', 'a' * 129],
        },
        {
          'onlineActors': ['actor', null],
        },
        {
          'onlineActors': ['actor', 1],
        },
        {'onlineCount': 3},
        {
          'onlineCount': 10001,
          'onlineActors': [for (var i = 0; i < 10001; i++) 'actor-$i'],
        },
      ]) {
        expect(
          RoomTabState.fromJson({...value, ...invalid}),
          isNull,
          reason: '$invalid',
        );
      }
      expect(
        RoomTabState.fromJson({
          ...value,
          'onlineCount': 10000,
          'onlineActors': ['actor', for (var i = 1; i < 10000; i++) 'actor-$i'],
        })!.onlineActors,
        hasLength(10000),
      );
    },
  );

  test('native local-tab factory leaves independent stores unchanged', () {
    expect(createRoomTabs(_room, 'actor'), isNull);
  });
}
