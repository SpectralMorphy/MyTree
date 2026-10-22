import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';
import 'package:mytree_webrtc_demo/room_protocol.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';

const _roomId = '0123456789abcdef0123456789abcdef';

RoomMessage _message({
  RoomMessageType type = RoomMessageType.welcome,
  String text = '',
  String actor = 'remote',
}) => RoomMessage(
  roomId: _roomId,
  type: type,
  actor: actor,
  inventory: type == RoomMessageType.inventory ? const {} : null,
  syncId: type == RoomMessageType.checkpoint || type == RoomMessageType.syncAck
      ? 'a' * 32
      : null,
  syncDigest:
      type == RoomMessageType.checkpoint || type == RoomMessageType.syncAck
      ? roomHistoryDigest([])
      : null,
  roomReady: type == RoomMessageType.syncAck ? true : null,
  diskBindingId: type == RoomMessageType.diskCredentials ? 'binding' : null,
  diskToken: type == RoomMessageType.diskCredentials ? 'disk-token' : null,
  history:
      type == RoomMessageType.presence ||
          type == RoomMessageType.inventory ||
          type == RoomMessageType.checkpoint ||
          type == RoomMessageType.syncAck ||
          type == RoomMessageType.diskCredentials
      ? []
      : [
          RoomEdit(
            id: 'edit',
            author: actor,
            clock: 1,
            createdAt: 1,
            text: text,
          ),
        ],
  online: type == RoomMessageType.welcome || type == RoomMessageType.presence
      ? 2
      : null,
  hosting: type == RoomMessageType.welcome || type == RoomMessageType.presence
      ? true
      : null,
);

List<Map<String, dynamic>> _rawChunks(
  List<int> bytes, {
  String actor = 'remote',
}) {
  const chunkBytes = 8000;
  final count = (bytes.length + chunkBytes - 1) ~/ chunkBytes;
  return List.generate(
    count,
    (index) => {
      'v': 1,
      'roomId': _roomId,
      'type': 'chunk',
      'actor': actor,
      'transfer': 'a' * 32,
      'index': index,
      'count': count,
      'bytes': bytes.length,
      'data': base64Encode(
        bytes.sublist(
          index * chunkBytes,
          min((index + 1) * chunkBytes, bytes.length),
        ),
      ),
    },
  );
}

void main() {
  test('all typed messages preserve the version-1 small JSON format', () {
    for (final type in RoomMessageType.values) {
      final message = _message(type: type, text: 'Ж😀');
      final encoded = encodeRoomMessage(message).single;
      expect(encoded['v'], 1);
      expect(encoded['roomId'], _roomId);
      expect(encoded['type'], type.name);
      final decoder = RoomMessageDecoder(roomId: _roomId);
      for (final value in [encoded, jsonEncode(encoded)]) {
        final packet = decoder.decode(value);
        expect(packet.message!.toJson(), message.toJson());
        expect(packet.startedTransfer, isFalse);
        expect(packet.acceptedFragment, isFalse);
        expect(packet.completedTransfer, isFalse);
        expect(decoder.assembling, isFalse);
      }
    }
  });

  test('typed message captures history rather than a mutable caller list', () {
    final edits = List<RoomEdit>.of(_message(text: 'original').history);
    final message = RoomMessage(
      roomId: _roomId,
      type: RoomMessageType.edits,
      actor: 'remote',
      history: edits,
    );
    edits.clear();
    expect(message.history.single.text, 'original');
    expect(() => message.history.clear(), throwsUnsupportedError);
  });

  test(
    'envelope, presence, membership counts and full history are validated',
    () {
      final valid = _message(text: 'valid').toJson();
      for (final invalid in <Object?>[
        null,
        [],
        {...valid, 'v': 1.0},
        {...valid, 'v': 2},
        {...valid, 'roomId': 'f' * 32},
        {...valid, 'type': 'unknown'},
        {...valid, 'actor': ''},
        {...valid, 'actor': 'a' * 129},
        {...valid, 'history': {}},
        {...valid, 'online': 0},
        {...valid, 'online': 100001},
        {...valid, 'online': 2.0},
        {...valid, 'hosting': null},
        {...valid, 'type': 'presence'},
        {
          ...valid,
          'history': [
            valid['history'][0],
            {'id': 'bad'},
          ],
        },
        {
          ...valid,
          'history': [
            valid['history'][0],
            {...valid['history'][0], 'text': 'mutated'},
          ],
        },
      ]) {
        expect(
          () => RoomMessageDecoder(roomId: _roomId).decode(invalid),
          throwsFormatException,
          reason: '$invalid',
        );
      }
      final presence = _message(type: RoomMessageType.presence).toJson();
      for (final online in [1, 100000]) {
        expect(
          decodeRoomMessage({
            ...presence,
            'online': online,
          }, roomId: _roomId).online,
          online,
        );
      }
    },
  );

  test('legacy hello and welcome omit fast-sync extension fields', () {
    for (final type in [RoomMessageType.hello, RoomMessageType.welcome]) {
      final encoded = _message(type: type).toJson();
      expect(encoded.containsKey('fastSync'), isFalse);
      expect(encoded.containsKey('historyDigest'), isFalse);
      expect(encoded.containsKey('inventory'), isFalse);
      expect(encoded.containsKey('durableSync'), isFalse);
      expect(encoded.containsKey('roomMetadata'), isFalse);
      expect(encoded.containsKey('roomRoles'), isFalse);
      expect(encoded.containsKey('familyTree'), isFalse);
      expect(encoded.containsKey('familySurnames'), isFalse);
      expect(encoded.containsKey('personalSurnames'), isFalse);
      expect(encoded.containsKey('explicitSiblings'), isFalse);
      expect(encoded.containsKey('patronymics'), isFalse);
      expect(encoded.containsKey('authorHistory'), isFalse);
      expect(encoded.containsKey('participantIdentity'), isFalse);
      expect(encoded.containsKey('diskSync'), isFalse);
      expect(encoded.containsKey('diskBindingId'), isFalse);
      expect(encoded.containsKey('diskToken'), isFalse);
      expect(encoded.containsKey('onlineActors'), isFalse);
      expect(encoded.containsKey('syncId'), isFalse);
      expect(encoded.containsKey('syncDigest'), isFalse);
      expect(encoded.containsKey('roomReady'), isFalse);
    }
  });

  test('metadata capability defaults false and only handshakes carry true', () {
    for (final type in RoomMessageType.values) {
      final raw = _message(type: type).toJson();
      expect(raw.containsKey('roomMetadata'), isFalse);
      expect(decodeRoomMessage(raw, roomId: _roomId).roomMetadata, isFalse);
      expect(
        decodeRoomMessage({
          ...raw,
          'roomMetadata': false,
        }, roomId: _roomId).roomMetadata,
        isFalse,
      );
      final supported = {...raw, 'roomMetadata': true};
      if (type == RoomMessageType.hello || type == RoomMessageType.welcome) {
        final decoded = decodeRoomMessage(supported, roomId: _roomId);
        expect(decoded.roomMetadata, isTrue);
        expect(decoded.toJson()['roomMetadata'], isTrue);
      } else {
        expect(
          () => decodeRoomMessage(supported, roomId: _roomId),
          throwsFormatException,
        );
      }
      for (final invalid in <Object?>[null, 1, 'true', [], {}]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'roomMetadata': invalid,
          }, roomId: _roomId),
          throwsFormatException,
          reason: '$type: $invalid',
        );
      }
    }
  });

  test('roles capability defaults false and only handshakes carry true', () {
    for (final type in RoomMessageType.values) {
      final raw = _message(type: type).toJson();
      expect(raw.containsKey('roomRoles'), isFalse);
      expect(decodeRoomMessage(raw, roomId: _roomId).roomRoles, isFalse);
      expect(
        decodeRoomMessage({
          ...raw,
          'roomRoles': false,
        }, roomId: _roomId).roomRoles,
        isFalse,
      );
      if (type == RoomMessageType.hello || type == RoomMessageType.welcome) {
        final message = RoomMessage(
          roomId: _roomId,
          type: type,
          actor: 'remote',
          history: const [],
          roomRoles: true,
          online: type == RoomMessageType.welcome ? 1 : null,
          hosting: type == RoomMessageType.welcome ? true : null,
        );
        final encoded = encodeRoomMessage(message).single;
        expect(encoded['roomRoles'], isTrue);
        final decoded = decodeRoomMessage(encoded, roomId: _roomId);
        expect(decoded.roomRoles, isTrue);
        expect(decoded.toJson(), message.toJson());
        expect(
          decoded.roomMetadata,
          isFalse,
          reason: 'Roles is an independently negotiated capability',
        );
      } else {
        expect(
          () => decodeRoomMessage({...raw, 'roomRoles': true}, roomId: _roomId),
          throwsFormatException,
        );
      }
      for (final invalid in <Object?>[null, 1, 'true', [], {}]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'roomRoles': invalid,
          }, roomId: _roomId),
          throwsFormatException,
          reason: '$type: $invalid',
        );
      }
    }
  });

  test(
    'family-tree capability defaults false and only handshakes carry true',
    () {
      for (final type in RoomMessageType.values) {
        final raw = _message(type: type).toJson();
        expect(raw.containsKey('familyTree'), isFalse);
        expect(decodeRoomMessage(raw, roomId: _roomId).familyTree, isFalse);
        expect(
          decodeRoomMessage({
            ...raw,
            'familyTree': false,
          }, roomId: _roomId).familyTree,
          isFalse,
        );
        if (type == RoomMessageType.hello || type == RoomMessageType.welcome) {
          final message = RoomMessage(
            roomId: _roomId,
            type: type,
            actor: 'remote',
            history: const [],
            familyTree: true,
            online: type == RoomMessageType.welcome ? 1 : null,
            hosting: type == RoomMessageType.welcome ? true : null,
          );
          final encoded = encodeRoomMessage(message).single;
          expect(encoded['familyTree'], isTrue);
          final decoded = decodeRoomMessage(encoded, roomId: _roomId);
          expect(decoded.familyTree, isTrue);
          expect(decoded.toJson(), message.toJson());
          expect(decoded.roomMetadata, isFalse);
          expect(decoded.roomRoles, isFalse);
        } else {
          expect(
            () => decodeRoomMessage({
              ...raw,
              'familyTree': true,
            }, roomId: _roomId),
            throwsFormatException,
          );
        }
        for (final invalid in <Object?>[null, 1, 'true', [], {}]) {
          expect(
            () => decodeRoomMessage({
              ...raw,
              'familyTree': invalid,
            }, roomId: _roomId),
            throwsFormatException,
            reason: '$type: $invalid',
          );
        }
      }
    },
  );

  test('surname capability defaults false and only handshakes carry true', () {
    for (final type in RoomMessageType.values) {
      final raw = _message(type: type).toJson();
      expect(raw.containsKey('familySurnames'), isFalse);
      expect(decodeRoomMessage(raw, roomId: _roomId).familySurnames, isFalse);
      final unsupported = decodeRoomMessage({
        ...raw,
        'familySurnames': false,
      }, roomId: _roomId);
      expect(unsupported.familySurnames, isFalse);
      expect(unsupported.toJson(), raw);
      if (type == RoomMessageType.hello || type == RoomMessageType.welcome) {
        final message = RoomMessage(
          roomId: _roomId,
          type: type,
          actor: 'remote',
          history: const [],
          familySurnames: true,
          online: type == RoomMessageType.welcome ? 1 : null,
          hosting: type == RoomMessageType.welcome ? true : null,
        );
        final encoded = encodeRoomMessage(message).single;
        expect(encoded['familySurnames'], isTrue);
        final decoded = decodeRoomMessage(encoded, roomId: _roomId);
        expect(decoded.familySurnames, isTrue);
        expect(decoded.toJson(), message.toJson());
        expect(decoded.familyTree, isFalse);
        expect(decoded.roomMetadata, isFalse);
        expect(decoded.roomRoles, isFalse);
      } else {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'familySurnames': true,
          }, roomId: _roomId),
          throwsFormatException,
        );
      }
      for (final invalid in <Object?>[
        null,
        0,
        1,
        1.0,
        'true',
        'false',
        [],
        {},
      ]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'familySurnames': invalid,
          }, roomId: _roomId),
          throwsFormatException,
          reason: '$type: $invalid',
        );
      }
    }
  });

  test('personal surname semantics are a separate handshake capability', () {
    for (final type in RoomMessageType.values) {
      final raw = _message(type: type).toJson();
      expect(raw.containsKey('personalSurnames'), isFalse);
      expect(decodeRoomMessage(raw, roomId: _roomId).personalSurnames, isFalse);
      final unsupported = decodeRoomMessage({
        ...raw,
        'personalSurnames': false,
      }, roomId: _roomId);
      expect(unsupported.personalSurnames, isFalse);
      expect(unsupported.toJson(), raw);
      if (type == RoomMessageType.hello || type == RoomMessageType.welcome) {
        final message = RoomMessage(
          roomId: _roomId,
          type: type,
          actor: 'remote',
          history: const [],
          personalSurnames: true,
          online: type == RoomMessageType.welcome ? 1 : null,
          hosting: type == RoomMessageType.welcome ? true : null,
        );
        final decoded = decodeRoomMessage(
          encodeRoomMessage(message).single,
          roomId: _roomId,
        );
        expect(decoded.personalSurnames, isTrue);
        expect(decoded.familySurnames, isFalse);
        expect(decoded.toJson(), message.toJson());
      } else {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'personalSurnames': true,
          }, roomId: _roomId),
          throwsFormatException,
        );
      }
      for (final invalid in <Object?>[
        null,
        0,
        1,
        1.0,
        'true',
        'false',
        [],
        {},
      ]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'personalSurnames': invalid,
          }, roomId: _roomId),
          throwsFormatException,
          reason: '$type: $invalid',
        );
      }
    }
  });

  test(
    'explicit siblings are an independent optional handshake capability',
    () {
      for (final type in RoomMessageType.values) {
        final raw = _message(type: type).toJson();
        expect(raw.containsKey('explicitSiblings'), isFalse);
        expect(
          decodeRoomMessage(raw, roomId: _roomId).explicitSiblings,
          isFalse,
        );
        expect(
          decodeRoomMessage({
            ...raw,
            'explicitSiblings': false,
          }, roomId: _roomId).toJson(),
          raw,
        );
        if (type == RoomMessageType.hello || type == RoomMessageType.welcome) {
          final message = RoomMessage(
            roomId: _roomId,
            type: type,
            actor: 'remote',
            history: const [],
            explicitSiblings: true,
            online: type == RoomMessageType.welcome ? 1 : null,
            hosting: type == RoomMessageType.welcome ? true : null,
          );
          final decoded = decodeRoomMessage(
            encodeRoomMessage(message).single,
            roomId: _roomId,
          );
          expect(decoded.explicitSiblings, isTrue);
          expect(decoded.familyTree, isFalse);
          expect(decoded.toJson(), message.toJson());
        } else {
          expect(
            () => decodeRoomMessage({
              ...raw,
              'explicitSiblings': true,
            }, roomId: _roomId),
            throwsFormatException,
          );
        }
        for (final invalid in <Object?>[null, 0, 1, 1.0, 'true', [], {}]) {
          expect(
            () => decodeRoomMessage({
              ...raw,
              'explicitSiblings': invalid,
            }, roomId: _roomId),
            throwsFormatException,
          );
        }
      }
    },
  );

  test(
    'atomic sibling payloads round trip without changing stored edit cores',
    () {
      final op = TreeDocument().createSibling(
        rootTreePersonId,
        'new',
        name: 'Сестра',
        sex: TreeSex.female,
        birthDate: DateTime.utc(1990),
      );
      final edit = RoomEdit(
        id: 'sibling',
        author: 'remote',
        clock: 1,
        createdAt: 2,
        text: jsonEncode(op.toJson()),
        kind: RoomEditKind.tree,
      );
      final message = RoomMessage(
        roomId: _roomId,
        type: RoomMessageType.hello,
        actor: 'remote',
        history: [edit],
        explicitSiblings: true,
      );
      final decoded = decodeRoomMessage(
        encodeRoomMessage(message).single,
        roomId: _roomId,
      );
      expect(decoded.history.single.toJson(), edit.toJson());
      expect(roomEditDigest(decoded.history.single), roomEditDigest(edit));
      expect(jsonDecode(decoded.history.single.text), op.toJson());
    },
  );

  test('lifeStatus is an independent optional handshake capability', () {
    for (final type in RoomMessageType.values) {
      final raw = _message(type: type).toJson();
      expect(raw.containsKey('lifeStatus'), isFalse);
      expect(decodeRoomMessage(raw, roomId: _roomId).lifeStatus, isFalse);
      expect(
        decodeRoomMessage({
          ...raw,
          'lifeStatus': false,
        }, roomId: _roomId).toJson(),
        raw,
      );
      if (type == RoomMessageType.hello || type == RoomMessageType.welcome) {
        final message = RoomMessage(
          roomId: _roomId,
          type: type,
          actor: 'remote',
          history: const [],
          lifeStatus: true,
          online: type == RoomMessageType.welcome ? 1 : null,
          hosting: type == RoomMessageType.welcome ? true : null,
        );
        final decoded = decodeRoomMessage(
          encodeRoomMessage(message).single,
          roomId: _roomId,
        );
        expect(decoded.lifeStatus, isTrue);
        expect(decoded.patronymics, isFalse);
        expect(decoded.toJson(), message.toJson());
      } else {
        expect(
          () =>
              decodeRoomMessage({...raw, 'lifeStatus': true}, roomId: _roomId),
          throwsFormatException,
        );
      }
      for (final invalid in <Object?>[null, 0, 1, 'true', []]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'lifeStatus': invalid,
          }, roomId: _roomId),
          throwsFormatException,
          reason: '$type: $invalid',
        );
      }
    }
  });

  test('patronymics is an independent optional handshake capability', () {
    for (final type in RoomMessageType.values) {
      final raw = _message(type: type).toJson();
      expect(raw.containsKey('patronymics'), isFalse);
      expect(decodeRoomMessage(raw, roomId: _roomId).patronymics, isFalse);
      expect(
        decodeRoomMessage({
          ...raw,
          'patronymics': false,
        }, roomId: _roomId).toJson(),
        raw,
      );
      if (type == RoomMessageType.hello || type == RoomMessageType.welcome) {
        final message = RoomMessage(
          roomId: _roomId,
          type: type,
          actor: 'remote',
          history: const [],
          patronymics: true,
          online: type == RoomMessageType.welcome ? 1 : null,
          hosting: type == RoomMessageType.welcome ? true : null,
        );
        final decoded = decodeRoomMessage(
          encodeRoomMessage(message).single,
          roomId: _roomId,
        );
        expect(decoded.patronymics, isTrue);
        expect(decoded.familyTree, isFalse);
        expect(decoded.toJson(), message.toJson());
      } else {
        expect(
          () =>
              decodeRoomMessage({...raw, 'patronymics': true}, roomId: _roomId),
          throwsFormatException,
        );
      }
      for (final invalid in <Object?>[
        null,
        0,
        1,
        1.0,
        'true',
        'false',
        [],
        {},
      ]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'patronymics': invalid,
          }, roomId: _roomId),
          throwsFormatException,
          reason: '$type: $invalid',
        );
      }
    }
  });

  test(
    'room dictionary overrides and resets preserve immutable wire records',
    () {
      for (final reset in [false, true]) {
        final operation = TreeDocument().setPatronymicOverride(
          ' ПЁТР ',
          male: reset ? null : ' Петрович ',
          female: reset ? null : ' Петровна ',
        );
        expect(operation.isRoomScoped, isTrue);
        expect(operation.personId, isEmpty);
        expect(operation.toJson(), {
          'type': 'setPatronymicOverride',
          'name': 'петр',
          'male': reset ? null : 'Петрович',
          'female': reset ? null : 'Петровна',
        });
        final edit = RoomEdit(
          id: reset ? 'dictionary-reset' : 'dictionary-override',
          author: 'remote',
          clock: 1,
          createdAt: 2,
          kind: RoomEditKind.tree,
          text: jsonEncode(operation.toJson()),
        );
        final message = RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.hello,
          actor: 'remote',
          history: [edit],
          patronymics: true,
        );
        final encoded = encodeRoomMessage(message).single;
        expect(encoded['v'], 1);
        final decoded = decodeRoomMessage(encoded, roomId: _roomId);
        expect(decoded.history.single.toJson(), edit.toJson());
        expect(roomEditDigest(decoded.history.single), roomEditDigest(edit));
        expect(
          TreeOperation.fromJson(
            jsonDecode(decoded.history.single.text),
          ).toJson(),
          operation.toJson(),
        );
      }
    },
  );

  test('author-history capability is optional and true only in handshakes', () {
    for (final type in RoomMessageType.values) {
      final raw = _message(type: type).toJson();
      expect(raw.containsKey('authorHistory'), isFalse);
      expect(decodeRoomMessage(raw, roomId: _roomId).authorHistory, isFalse);
      expect(
        decodeRoomMessage({
          ...raw,
          'authorHistory': false,
        }, roomId: _roomId).toJson(),
        raw,
      );
      if (type == RoomMessageType.hello || type == RoomMessageType.welcome) {
        final decoded = decodeRoomMessage({
          ...raw,
          'authorHistory': true,
        }, roomId: _roomId);
        expect(decoded.authorHistory, isTrue);
        expect(decoded.toJson(), {...raw, 'authorHistory': true});
      } else {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'authorHistory': true,
          }, roomId: _roomId),
          throwsFormatException,
        );
      }
      for (final invalid in <Object?>[null, 0, 1, 1.0, 'true', [], {}]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'authorHistory': invalid,
          }, roomId: _roomId),
          throwsFormatException,
          reason: '$type: $invalid',
        );
      }
    }
  });

  test('participant identity capability is optional and handshake-only', () {
    for (final type in RoomMessageType.values) {
      final raw = _message(type: type).toJson();
      expect(raw.containsKey('participantIdentity'), isFalse);
      expect(
        decodeRoomMessage(raw, roomId: _roomId).participantIdentity,
        isFalse,
      );
      expect(
        decodeRoomMessage({
          ...raw,
          'participantIdentity': false,
        }, roomId: _roomId).toJson(),
        raw,
      );
      if (type == RoomMessageType.hello || type == RoomMessageType.welcome) {
        final decoded = decodeRoomMessage({
          ...raw,
          'participantIdentity': true,
        }, roomId: _roomId);
        expect(decoded.participantIdentity, isTrue);
        expect(decoded.toJson(), {...raw, 'participantIdentity': true});
        final message = RoomMessage(
          roomId: _roomId,
          type: type,
          actor: 'actor',
          history: const [],
          online: type == RoomMessageType.welcome ? 1 : null,
          hosting: type == RoomMessageType.welcome ? true : null,
          participantIdentity: true,
        );
        expect(
          decodeRoomMessage(
            message.toJson(),
            roomId: _roomId,
          ).participantIdentity,
          isTrue,
        );
      } else {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'participantIdentity': true,
          }, roomId: _roomId),
          throwsFormatException,
        );
      }
      for (final invalid in <Object?>[null, 0, 1, 1.0, 'true', [], {}]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'participantIdentity': invalid,
          }, roomId: _roomId),
          throwsFormatException,
          reason: '$type: $invalid',
        );
      }
    }
  });

  test('disk sync defaults false and true is handshake-only', () {
    for (final type in RoomMessageType.values) {
      final raw = _message(type: type).toJson();
      expect(raw.containsKey('diskSync'), isFalse);
      expect(decodeRoomMessage(raw, roomId: _roomId).diskSync, isFalse);
      expect(
        decodeRoomMessage({
          ...raw,
          'diskSync': false,
        }, roomId: _roomId).toJson(),
        raw,
      );
      if (type == RoomMessageType.hello || type == RoomMessageType.welcome) {
        final message = RoomMessage(
          roomId: _roomId,
          type: type,
          actor: 'remote',
          history: const [],
          online: type == RoomMessageType.welcome ? 1 : null,
          hosting: type == RoomMessageType.welcome ? true : null,
          diskSync: true,
        );
        final decoded = decodeRoomMessage(
          encodeRoomMessage(message).single,
          roomId: _roomId,
        );
        expect(decoded.diskSync, isTrue);
        expect(decoded.toJson(), message.toJson());
        expect(decoded.durableSync, isFalse);
        expect(decoded.roomRoles, isFalse);
        expect(decoded.diskBindingId, isNull);
        expect(decoded.diskToken, isNull);
      } else {
        expect(
          () => decodeRoomMessage({...raw, 'diskSync': true}, roomId: _roomId),
          throwsFormatException,
        );
      }
      for (final invalid in <Object?>[null, 0, 1, 1.0, 'true', [], {}]) {
        expect(
          () =>
              decodeRoomMessage({...raw, 'diskSync': invalid}, roomId: _roomId),
          throwsFormatException,
          reason: type.name,
        );
      }
    }
  });

  test(
    'disk credentials round-trip canonical tokens and bounded binding IDs',
    () {
      final printableAscii = String.fromCharCodes([
        for (var unit = 0x21; unit <= 0x7e; unit++) unit,
      ]);
      for (final token in ['x', printableAscii, 't' * 4096]) {
        for (final bindingId in ['b', 'b' * 128]) {
          final message = RoomMessage(
            roomId: _roomId,
            type: RoomMessageType.diskCredentials,
            actor: 'remote',
            history: const [],
            diskBindingId: bindingId,
            diskToken: token,
          );
          final encoded = encodeRoomMessage(message).single;
          expect(encoded['type'], 'diskCredentials');
          expect(encoded['diskBindingId'], bindingId);
          expect(encoded['diskToken'], token);
          final decoded = RoomMessageDecoder(
            roomId: _roomId,
          ).decode(jsonEncode(encoded)).message!;
          expect(decoded.toJson(), message.toJson());
          expect(decoded.diskSync, isFalse);
          expect(decoded.diskBindingId, bindingId);
          expect(decoded.diskToken, token);
          expect(decoded.history, isEmpty);
        }
      }
    },
  );

  test('credential fields are rejected on every other message, even null', () {
    for (final type in RoomMessageType.values) {
      if (type == RoomMessageType.diskCredentials) continue;
      final raw = _message(type: type).toJson();
      for (final fields in <Map<String, dynamic>>[
        {'diskBindingId': 'binding'},
        {'diskBindingId': null},
        {'diskToken': 'secret-token'},
        {'diskToken': null},
        {'diskBindingId': 'binding', 'diskToken': 'secret-token'},
      ]) {
        expect(
          () => decodeRoomMessage({...raw, ...fields}, roomId: _roomId),
          throwsFormatException,
          reason: '${type.name}: ${fields.keys.join(', ')}',
        );
      }
    }
  });

  test(
    'disk credentials require valid binding, canonical token and no history',
    () {
      final raw = _message(type: RoomMessageType.diskCredentials).toJson();
      for (final field in ['diskBindingId', 'diskToken']) {
        final missing = Map<String, dynamic>.of(raw)..remove(field);
        expect(
          () => decodeRoomMessage(missing, roomId: _roomId),
          throwsFormatException,
          reason: 'Missing $field',
        );
      }
      for (final bindingId in <Object?>[null, '', 'b' * 129, 1, [], {}]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'diskBindingId': bindingId,
          }, roomId: _roomId),
          throwsFormatException,
        );
      }
      for (final token in <Object?>[
        null,
        '',
        't' * 4097,
        ' token',
        'token ',
        'to ken',
        'to\tken',
        'token\n',
        'to\rken',
        'to\u0000ken',
        'to\u001fken',
        'to\u007fken',
        'to ken',
        'токен',
        1,
        [],
        {},
      ]) {
        expect(
          () =>
              decodeRoomMessage({...raw, 'diskToken': token}, roomId: _roomId),
          throwsFormatException,
        );
      }
      expect(
        () => decodeRoomMessage({
          ...raw,
          'history': _message(type: RoomMessageType.edits).toJson()['history'],
        }, roomId: _roomId),
        throwsFormatException,
      );
    },
  );

  test('credential validation errors never include token values or source', () {
    const secret = 'never-report-this-token';
    final raw = _message(type: RoomMessageType.diskCredentials).toJson();
    for (final invalid in [
      {...raw, 'diskBindingId': '', 'diskToken': secret},
      {...raw, 'diskToken': '$secret '},
      {...raw, 'history': _message().toJson()['history'], 'diskToken': secret},
      {...raw, 'diskSync': true, 'diskToken': secret},
      {..._message().toJson(), 'diskToken': secret},
    ]) {
      expect(
        () => decodeRoomMessage(invalid, roomId: _roomId),
        throwsA(
          isA<FormatException>()
              .having(
                (error) => error.toString(),
                'error text',
                isNot(contains(secret)),
              )
              .having((error) => error.source, 'error source', isNull),
        ),
      );
    }
  });

  test('malformed JSON errors never retain credential source text', () {
    const secret = 'never-report-this-token';
    final raw = {
      ..._message(type: RoomMessageType.diskCredentials).toJson(),
      'diskToken': secret,
    };
    final redactedError = throwsA(
      isA<FormatException>()
          .having(
            (error) => error.toString(),
            'error text',
            isNot(contains(secret)),
          )
          .having((error) => error.source, 'error source', isNull),
    );
    final malformed = jsonEncode(raw).replaceFirst('}', ',}');
    expect(
      () => RoomMessageDecoder(roomId: _roomId).decode(malformed),
      redactedError,
    );
    final chunks = _rawChunks(utf8.encode('$malformed${' ' * 13000}'));
    final decoder = RoomMessageDecoder(roomId: _roomId);
    for (final chunk in chunks.take(chunks.length - 1)) {
      decoder.decode(chunk);
    }
    expect(() => decoder.decode(chunks.last), redactedError);
  });

  test(
    'normal-message serialization never emits credential fields or secrets',
    () {
      const secret = 'never-serialize-this-token';
      for (final type in RoomMessageType.values) {
        if (type == RoomMessageType.diskCredentials) continue;
        final normal = _message(type: type, text: 'a' * 13000);
        final message = RoomMessage(
          roomId: normal.roomId,
          type: normal.type,
          actor: normal.actor,
          history: normal.history,
          online: normal.online,
          hosting: normal.hosting,
          inventory: normal.inventory,
          syncId: normal.syncId,
          syncDigest: normal.syncDigest,
          roomReady: normal.roomReady,
          diskBindingId: 'private-binding',
          diskToken: secret,
        );
        final encoded = message.toJson();
        expect(encoded.containsKey('diskBindingId'), isFalse);
        expect(encoded.containsKey('diskToken'), isFalse);
        expect(jsonEncode(encoded), isNot(contains(secret)));
        expect(encoded, normal.toJson());
        final decoder = RoomMessageDecoder(roomId: _roomId);
        RoomMessage? decoded;
        for (final packet in encodeRoomMessage(message)) {
          decoded = decoder.decode(packet).message ?? decoded;
        }
        expect(decoded!.toJson(), normal.toJson());
        expect(decoded.diskBindingId, isNull);
        expect(decoded.diskToken, isNull);
      }
    },
  );

  test('empty alias payload round-trips without substituting its label', () {
    const cleared = RoomEdit(
      id: 'cleared',
      author: 'actor',
      clock: 20,
      createdAt: 20,
      text: '',
      kind: RoomEditKind.participantName,
    );
    final message = RoomMessage(
      roomId: _roomId,
      type: RoomMessageType.edits,
      actor: 'actor',
      history: [cleared],
    );
    final decoded = decodeRoomMessage(message.toJson(), roomId: _roomId);
    expect(decoded.history.single.text, '');
    expect(decoded.history.single.sameContentAs(cleared), isTrue);
    expect(roomEditDigest(decoded.history.single), roomEditDigest(cleared));
    expect(decoded.toJson(), message.toJson());
  });

  test('digest cache is per immutable record, never per ID', () {
    final draft = RoomEdit(
      id: 'cached',
      author: 'actor',
      clock: 1,
      createdAt: 1,
      text: List.filled(10000, 'photo payload').join(),
    );
    final digest = roomEditDigest(draft);
    expect(identical(roomEditDigest(draft), digest), isTrue);
    final stored = draft.withAuthorProof(
      authorSequence: 1,
      authorPrevious: null,
      authorBase: [],
    );
    expect(roomEditDigest(stored), isNot(digest));
    final conflicting = RoomEdit(
      id: draft.id,
      author: draft.author,
      clock: draft.clock,
      createdAt: draft.createdAt,
      text: 'changed payload',
    );
    expect(roomEditDigest(conflicting), isNot(digest));
    expect(
      () => roomHistoryInventory([draft, conflicting]),
      throwsFormatException,
    );
    expect(
      () => missingRoomEdits([conflicting], roomHistoryInventory([draft])),
      throwsFormatException,
    );
    expect(roomEditDigest(RoomEdit.fromJson(draft.toJson())!), digest);
    expect(identical(roomEditDigest(draft), digest), isTrue);
  });

  test(
    'author proofs round-trip and participate in immutable fingerprints',
    () {
      const legacy = RoomEdit(
        id: 'legacy',
        author: 'A',
        clock: 10,
        createdAt: 10,
        text: 'old',
      );
      const draft = RoomEdit(
        id: 'first',
        author: 'A',
        clock: 1,
        createdAt: 1,
        text: 'new',
      );
      final first = sequenceAuthoredEdit(draft, [legacy]);
      final message = RoomMessage(
        roomId: _roomId,
        type: RoomMessageType.edits,
        actor: 'remote',
        history: [legacy, first],
      );
      final decoded = decodeRoomMessage(message.toJson(), roomId: _roomId);
      expect(decoded.toJson(), message.toJson());
      expect(decoded.history.last.authorSequence, 1);
      expect(decoded.history.last.authorPrevious, isNull);
      expect(decoded.history.last.authorBase, ['legacy']);
      expect(roomEditDigest(first), isNot(roomEditDigest(draft)));
      final changed = RoomEdit.fromJson({...first.toJson(), 'authorBase': []})!;
      expect(roomEditDigest(changed), isNot(roomEditDigest(first)));
      final later = draft.withAuthorProof(
        authorSequence: 2,
        authorPrevious: 'previous',
      );
      final changedPrevious = later.withAuthorProof(
        authorSequence: 2,
        authorPrevious: 'changed-previous',
      );
      final changedSequence = later.withAuthorProof(
        authorSequence: 3,
        authorPrevious: 'previous',
      );
      expect(roomEditDigest(later), isNot(roomEditDigest(first)));
      expect(roomEditDigest(later), isNot(roomEditDigest(changedPrevious)));
      expect(roomEditDigest(later), isNot(roomEditDigest(changedSequence)));
      expect(
        () => missingRoomEdits([changed], roomHistoryInventory([first])),
        throwsFormatException,
      );
    },
  );

  test(
    'tail batches resolve canonical proof and complete same-author closure',
    () {
      const legacy = RoomEdit(
        id: 'legacy',
        author: 'A',
        clock: 30,
        createdAt: 30,
        text: 'legacy',
      );
      const other = RoomEdit(
        id: 'other',
        author: 'B',
        clock: 0,
        createdAt: 0,
        text: 'unrelated',
      );
      const draft = RoomEdit(
        id: 'first',
        author: 'A',
        clock: 20,
        createdAt: 20,
        text: 'first',
      );
      final first = sequenceAuthoredEdit(draft, [legacy]);
      final tail = sequenceAuthoredEdit(
        const RoomEdit(
          id: 'tail',
          author: 'A',
          clock: 1,
          createdAt: 1,
          text: 'tail',
        ),
        [legacy, first],
      );
      final durable = [tail, other, first, legacy];
      expect(
        completeRoomAuthorHistory([tail, tail], durable).map((edit) => edit.id),
        ['legacy', 'first', 'tail'],
      );
      final frozen = completeRoomAuthorHistory([draft], durable);
      expect(frozen.map((edit) => edit.id), ['legacy', 'first']);
      expect(frozen.last.sameContentAs(first), isTrue);
      expect(
        () => completeRoomAuthorHistory([tail], [tail, first]),
        throwsFormatException,
      );
      expect(
        () => completeRoomAuthorHistory([tail], [first, legacy]),
        throwsFormatException,
      );
      final changed = RoomEdit.fromJson({...tail.toJson(), 'text': 'changed'})!;
      expect(
        () => completeRoomAuthorHistory([changed], durable),
        throwsFormatException,
      );
      final changedProof = first.withAuthorProof(
        authorSequence: 1,
        authorPrevious: null,
        authorBase: [],
      );
      expect(
        () => completeRoomAuthorHistory([changedProof], durable),
        throwsFormatException,
      );
    },
  );

  test('surname capability preserves legacy JSON and edit fingerprints', () {
    const edit = RoomEdit(
      id: 'a',
      author: 'A',
      clock: 1,
      createdAt: 2,
      text: 'Ж😀',
    );
    final legacy = {
      'v': 1,
      'roomId': _roomId,
      'type': 'hello',
      'actor': 'remote',
      'history': [edit.toJson()],
    };
    for (final enabled in [false, true]) {
      for (final personal in [false, true]) {
        final message = RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.hello,
          actor: 'remote',
          history: const [edit],
          familySurnames: enabled,
          personalSurnames: personal,
        );
        final encoded = encodeRoomMessage(message).single;
        expect(
          jsonEncode(encoded),
          jsonEncode({
            ...legacy,
            if (enabled) 'familySurnames': true,
            if (personal) 'personalSurnames': true,
          }),
        );
        final decoded = decodeRoomMessage(encoded, roomId: _roomId);
        expect(
          roomEditDigest(decoded.history.single),
          '719124f8eb440137e080755dd11eb63d22f0b22ea9bb45e0180850afd957d1d3',
        );
        expect(roomHistoryDigest(decoded.history), roomHistoryDigest([edit]));
      }
    }
  });

  test(
    'tree history validates JSON payloads and whole-batch immutable conflicts',
    () {
      final operation = TreeDocument().createPerson('anna', name: 'Анна');
      final edit = RoomEdit(
        id: 'tree',
        author: 'remote',
        clock: 1,
        createdAt: 2,
        text: jsonEncode(operation.toJson()),
        kind: RoomEditKind.tree,
      );
      for (final type in [
        RoomMessageType.hello,
        RoomMessageType.welcome,
        RoomMessageType.edits,
      ]) {
        final message = RoomMessage(
          roomId: _roomId,
          type: type,
          actor: 'remote',
          history: [edit],
          familyTree: type != RoomMessageType.edits,
          roomMetadata: type != RoomMessageType.edits,
          online: type == RoomMessageType.welcome ? 1 : null,
          hosting: type == RoomMessageType.welcome ? true : null,
        );
        final decoded = decodeRoomMessage(
          encodeRoomMessage(message).single,
          roomId: _roomId,
        );
        expect(decoded.toJson(), message.toJson());
        expect(decoded.history.single.sameContentAs(edit), isTrue);
        expect(
          TreeOperation.fromJson(
            jsonDecode(decoded.history.single.text),
          ).toJson(),
          operation.toJson(),
        );
      }
      final raw = _message(type: RoomMessageType.edits).toJson();
      for (final payload in [
        'not JSON',
        'null',
        '[]',
        '{}',
        jsonEncode({...operation.toJson(), 'sex': 'invalid'}),
        jsonEncode({...operation.toJson(), 'extra': true}),
        jsonEncode({'type': 'unknown', 'personId': 'anna'}),
        jsonEncode({
          'type': 'editText',
          'personId': 'anna',
          'field': 'name',
          'itemId': null,
          'inserts': [
            {'id': 'atom', 'text': 'too long', 'left': null, 'right': null},
          ],
          'deletes': [],
        }),
      ]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'history': [
              edit.toJson(),
              {...edit.toJson(), 'id': 'invalid-tree', 'text': payload},
            ],
          }, roomId: _roomId),
          throwsFormatException,
          reason: payload,
        );
      }
      final changedPayload = jsonEncode({
        ...operation.toJson(),
        'name': 'Другое имя',
      });
      final changed = RoomEdit.fromJson({
        ...edit.toJson(),
        'text': changedPayload,
      })!;
      expect(roomEditDigest(changed), isNot(roomEditDigest(edit)));
      expect(roomHistoryDigest([changed]), isNot(roomHistoryDigest([edit])));
      expect(missingRoomEdits([edit], const {}), [edit]);
      expect(missingRoomEdits([edit], roomHistoryInventory([edit])), isEmpty);
      expect(
        () => roomHistoryInventory([edit, changed]),
        throwsFormatException,
      );
      expect(
        () => missingRoomEdits([edit], roomHistoryInventory([changed])),
        throwsFormatException,
      );
      expect(
        () => decodeRoomMessage({
          ...raw,
          'history': [edit.toJson(), changed.toJson()],
        }, roomId: _roomId),
        throwsFormatException,
      );
      final duplicates = decodeRoomMessage({
        ...raw,
        'history': [edit.toJson(), edit.toJson()],
      }, roomId: _roomId);
      expect(duplicates.history, hasLength(2));
      expect(
        duplicates.history.every((value) => value.sameContentAs(edit)),
        isTrue,
      );
      final legacyText = RoomEdit(
        id: edit.id,
        author: edit.author,
        clock: edit.clock,
        createdAt: edit.createdAt,
        text: edit.text,
      );
      expect(roomEditDigest(edit), isNot(roomEditDigest(legacyText)));
      expect(
        () => roomHistoryInventory([edit, legacyText]),
        throwsFormatException,
      );
    },
  );

  test(
    'large tree JSON uses bounded fragmentation and never becomes a fast text preview',
    () {
      final edit = RoomEdit(
        id: 'large-tree',
        author: 'remote',
        clock: 1,
        createdAt: 2,
        text: jsonEncode(
          TreeDocument().createPerson('anna', name: 'Ж' * 7000).toJson(),
        ),
        kind: RoomEditKind.tree,
      );
      final message = RoomMessage(
        roomId: _roomId,
        type: RoomMessageType.edits,
        actor: 'remote',
        history: [edit],
      );
      final chunks = encodeRoomMessage(message).toList();
      expect(chunks.length, greaterThan(1));
      final decoder = RoomMessageDecoder(roomId: _roomId);
      RoomMessage? restored;
      for (final chunk in chunks.reversed) {
        expect(utf8.encode(jsonEncode(chunk)).length, lessThan(12000));
        restored = decoder.decode(chunk).message ?? restored;
      }
      expect(restored!.toJson(), message.toJson());
      expect(decoder.assembling, isFalse);
      expect(
        () => decodeRoomMessage({
          ..._message(type: RoomMessageType.hello).toJson(),
          'familyTree': true,
          'roomMetadata': true,
          'fastSync': true,
          'historyDigest': roomHistoryDigest([edit]),
          'history': [edit.toJson()],
        }, roomId: _roomId),
        throwsFormatException,
      );
    },
  );

  test('online actor lists round trip as immutable presence snapshots', () {
    for (final type in [RoomMessageType.welcome, RoomMessageType.presence]) {
      final source = ['remote', 'local'];
      final message = RoomMessage(
        roomId: _roomId,
        type: type,
        actor: 'remote',
        history: const [],
        online: 2,
        hosting: true,
        onlineActors: source,
      );
      source.clear();
      expect(message.onlineActors, ['remote', 'local']);
      expect(() => message.onlineActors!.clear(), throwsUnsupportedError);
      final decoded = decodeRoomMessage(message.toJson(), roomId: _roomId);
      expect(decoded.onlineActors, ['remote', 'local']);
      expect(decoded.online, 2);
      expect(decoded.toJson(), message.toJson());
      expect(() => decoded.onlineActors!.clear(), throwsUnsupportedError);
    }
    for (final type in RoomMessageType.values) {
      final raw = _message(type: type).toJson();
      expect(raw.containsKey('onlineActors'), isFalse);
      expect(decodeRoomMessage(raw, roomId: _roomId).onlineActors, isNull);
    }
  });

  test(
    'online actor lists require unique valid actors and the stated count',
    () {
      for (final type in [RoomMessageType.welcome, RoomMessageType.presence]) {
        final raw = _message(type: type).toJson();
        for (final invalid in <Object?>[
          null,
          'remote',
          {},
          [],
          ['remote'],
          ['remote', 'local', 'third'],
          ['remote', 'remote'],
          ['remote', ''],
          ['remote', 'a' * 129],
          ['remote', 1],
          ['remote', null],
        ]) {
          expect(
            () => decodeRoomMessage({
              ...raw,
              'onlineActors': invalid,
            }, roomId: _roomId),
            throwsFormatException,
            reason: '$type: $invalid',
          );
        }
      }
      for (final type in RoomMessageType.values) {
        if (type == RoomMessageType.welcome ||
            type == RoomMessageType.presence) {
          continue;
        }
        expect(
          () => decodeRoomMessage({
            ..._message(type: type).toJson(),
            'onlineActors': ['remote', 'local'],
          }, roomId: _roomId),
          throwsFormatException,
        );
      }
    },
  );

  test('online actor list bound does not change the legacy count bound', () {
    final raw = _message(type: RoomMessageType.presence).toJson();
    final actors = [for (var i = 0; i < 10000; i++) 'actor-$i'];
    final decoded = decodeRoomMessage({
      ...raw,
      'online': actors.length,
      'onlineActors': actors,
    }, roomId: _roomId);
    expect(decoded.onlineActors, hasLength(10000));
    expect(
      () => decodeRoomMessage({
        ...raw,
        'online': 10001,
        'onlineActors': [...actors, 'extra'],
      }, roomId: _roomId),
      throwsFormatException,
    );
    expect(
      decodeRoomMessage({...raw, 'online': 100000}, roomId: _roomId).online,
      100000,
    );
  });

  test('durability capability is optional and handshake-only', () {
    for (final type in [RoomMessageType.hello, RoomMessageType.welcome]) {
      final raw = {..._message(type: type).toJson(), 'durableSync': true};
      expect(decodeRoomMessage(raw, roomId: _roomId).durableSync, isTrue);
      expect(
        decodeRoomMessage({
          ...raw,
          'durableSync': false,
        }, roomId: _roomId).durableSync,
        isFalse,
      );
      for (final invalid in [null, 1, 'true']) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'durableSync': invalid,
          }, roomId: _roomId),
          throwsFormatException,
        );
      }
    }
    expect(
      () => decodeRoomMessage({
        ..._message(type: RoomMessageType.edits).toJson(),
        'durableSync': true,
      }, roomId: _roomId),
      throwsFormatException,
    );
  });

  test(
    'checkpoints bind immutable inventory to root and ACK to a fixed token',
    () {
      final inventory = roomHistoryInventory(_message().history);
      final checkpoint = {
        ..._message(type: RoomMessageType.checkpoint).toJson(),
        'syncDigest': roomInventoryDigest(inventory),
        'inventory': inventory,
      };
      expect(
        decodeRoomMessage(checkpoint, roomId: _roomId).inventory,
        inventory,
      );
      final ack = _message(type: RoomMessageType.syncAck).toJson();
      for (final invalid in [
        {...checkpoint, 'syncId': null},
        {...checkpoint, 'syncId': 'b' * 31},
        {...checkpoint, 'syncDigest': null},
        {...checkpoint, 'syncDigest': 'z' * 64},
        {...checkpoint, 'syncDigest': 'a' * 64},
        {...checkpoint, 'history': _message().toJson()['history']},
        {...checkpoint, 'roomReady': true},
        {...ack, 'roomReady': null},
        {...ack, 'roomReady': 1},
        {...ack, 'inventory': {}},
        {...ack, 'history': _message().toJson()['history']},
        {..._message(type: RoomMessageType.edits).toJson(), 'syncId': 'a' * 32},
        {..._message(type: RoomMessageType.hello).toJson(), 'roomReady': true},
      ]) {
        expect(
          () => decodeRoomMessage(invalid, roomId: _roomId),
          throwsFormatException,
          reason: '$invalid',
        );
      }
    },
  );

  test(
    'history digests are deterministic and include losing immutable edits',
    () {
      final a = RoomEdit(
        id: 'a',
        author: 'A',
        clock: 1,
        createdAt: 2,
        text: 'Ж😀',
      );
      final b = RoomEdit(
        id: 'b',
        author: 'B',
        clock: 3,
        createdAt: 4,
        text: 'new',
      );
      // The exact legacy five-item JSON array must retain its fingerprint.
      expect(
        roomEditDigest(a),
        '719124f8eb440137e080755dd11eb63d22f0b22ea9bb45e0180850afd957d1d3',
      );
      final root = roomHistoryDigest([a, b]);
      expect(root, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(roomHistoryDigest([b, a]), root);
      expect(roomHistoryDigest([b]), isNot(root));
      expect(roomHistoryDigest([]), matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(roomEditDigest(RoomEdit.fromJson(a.toJson())!), roomEditDigest(a));
      for (final changed in [
        RoomEdit(
          id: 'changed',
          author: a.author,
          clock: a.clock,
          createdAt: a.createdAt,
          text: a.text,
        ),
        RoomEdit(
          id: a.id,
          author: 'changed',
          clock: a.clock,
          createdAt: a.createdAt,
          text: a.text,
        ),
        RoomEdit(
          id: a.id,
          author: a.author,
          clock: 7,
          createdAt: a.createdAt,
          text: a.text,
        ),
        RoomEdit(
          id: a.id,
          author: a.author,
          clock: a.clock,
          createdAt: 7,
          text: a.text,
        ),
        RoomEdit(
          id: a.id,
          author: a.author,
          clock: a.clock,
          createdAt: a.createdAt,
          text: 'changed',
        ),
      ]) {
        expect(roomEditDigest(changed), isNot(roomEditDigest(a)));
        expect(roomHistoryDigest([changed, b]), isNot(root));
      }
    },
  );

  test(
    'metadata kinds participate in digests and immutable inventory checks',
    () {
      final variants = [
        for (final kind in [
          RoomEditKind.text,
          RoomEditKind.participantName,
          RoomEditKind.roomName,
        ])
          RoomEdit(
            id: 'same',
            author: 'author',
            clock: 1,
            createdAt: 2,
            text: 'Анна',
            kind: kind,
          ),
      ];
      expect(variants.map(roomEditDigest).toSet(), hasLength(3));
      // Existing six-item metadata fingerprints are unchanged by role support.
      expect(
        roomEditDigest(variants[1]),
        'ad9f798ddee2dcf85396db3935ff2e10f651518a801b8b03913c826dab603fb1',
      );
      expect(
        roomEditDigest(variants[2]),
        'f878c30ac5179ced5197e1001a5b191cf28dfae5618239e3b4d1e5ba33f83feb',
      );
      for (final edit in variants) {
        expect(
          roomEditDigest(RoomEdit.fromJson(edit.toJson())!),
          roomEditDigest(edit),
        );
      }
      expect(
        () => roomHistoryInventory([variants[0], variants[1]]),
        throwsFormatException,
      );
      expect(
        () => missingRoomEdits([
          variants[0],
        ], roomHistoryInventory([variants[1]])),
        throwsFormatException,
      );
    },
  );

  test(
    'role digests bind the complete immutable payload including subject',
    () {
      const original = RoomEdit(
        id: 'role',
        author: 'editor',
        clock: 1,
        createdAt: 2,
        text: 'guest',
        kind: RoomEditKind.participantRole,
        targetActor: 'subject',
      );
      final digest = roomEditDigest(original);
      expect(
        digest,
        '574b708614fc681f02933a4bb9730b30fc8521ec11e26984df3382d8c555824a',
      );
      final reordered = {
        'targetActor': 'subject',
        'kind': 'participantRole',
        'text': 'guest',
        'createdAt': 2,
        'clock': 1,
        'author': 'editor',
        'id': 'role',
      };
      expect(roomEditDigest(RoomEdit.fromJson(reordered)!), digest);
      final inventory = roomHistoryInventory([original]);
      expect(inventory, {'role': digest});
      expect(missingRoomEdits([original], inventory), isEmpty);
      expect(missingRoomEdits([original], const {}), [original]);
      for (final mutation in <Map<String, dynamic>>[
        {'id': 'different'},
        {'author': 'different'},
        {'clock': 3},
        {'createdAt': 3},
        {'text': 'editor'},
        {'targetActor': 'different'},
      ]) {
        final changed = RoomEdit.fromJson({...original.toJson(), ...mutation})!;
        expect(roomEditDigest(changed), isNot(digest));
        expect(
          roomHistoryDigest([changed]),
          isNot(roomHistoryDigest([original])),
        );
        if (changed.id == original.id) {
          expect(
            () => roomHistoryInventory([original, changed]),
            throwsFormatException,
          );
          expect(
            () => missingRoomEdits([original], roomHistoryInventory([changed])),
            throwsFormatException,
          );
        }
      }
      for (final kind in [
        RoomEditKind.text,
        RoomEditKind.participantName,
        RoomEditKind.roomName,
      ]) {
        final changed = RoomEdit(
          id: original.id,
          author: original.author,
          clock: original.clock,
          createdAt: original.createdAt,
          text: original.text,
          kind: kind,
        );
        expect(roomEditDigest(changed), isNot(digest));
        expect(
          () => roomHistoryInventory([original, changed]),
          throwsFormatException,
        );
        expect(
          () => missingRoomEdits([original], roomHistoryInventory([changed])),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'role history rejects invalid targets and whole-batch immutable conflicts',
    () {
      const role = RoomEdit(
        id: 'role',
        author: 'editor',
        clock: 1,
        createdAt: 2,
        text: 'guest',
        kind: RoomEditKind.participantRole,
        targetActor: 'subject',
      );
      final raw = _message(type: RoomMessageType.edits).toJson();
      final roleJson = role.toJson();
      final noTarget = Map<String, dynamic>.of(roleJson)..remove('targetActor');
      for (final invalid in [
        noTarget,
        {...roleJson, 'targetActor': null},
        {...roleJson, 'targetActor': ''},
        {...roleJson, 'targetActor': 'x' * 129},
        {...roleJson, 'targetActor': 1},
        {...roleJson, 'text': 'owner'},
        {...roleJson, 'kind': 'text'},
      ]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'history': [roleJson, invalid],
          }, roomId: _roomId),
          throwsFormatException,
        );
      }
      for (final mutation in <Map<String, dynamic>>[
        {'author': 'other-editor'},
        {'clock': 3},
        {'createdAt': 3},
        {'text': 'editor'},
        {'targetActor': 'other-subject'},
      ]) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'history': [
              roleJson,
              {...roleJson, ...mutation},
            ],
          }, roomId: _roomId),
          throwsFormatException,
        );
      }
      final decoded = decodeRoomMessage({
        ...raw,
        'history': [roleJson, roleJson],
      }, roomId: _roomId);
      expect(decoded.history, hasLength(2));
      expect(decoded.history.every((edit) => edit.sameContentAs(role)), isTrue);
    },
  );

  test('full history and inventory retain metadata as well as losing text', () {
    final edits = [
      for (final kind in RoomEditKind.values)
        RoomEdit(
          id: kind.name,
          author: 'remote',
          clock: kind.index + 1,
          createdAt: kind.index + 1,
          text: switch (kind) {
            RoomEditKind.participantRole => 'guest',
            RoomEditKind.tree => jsonEncode(
              TreeDocument().createPerson('anna', name: 'Анна').toJson(),
            ),
            RoomEditKind.diskConnection => jsonEncode({'action': 'connect'}),
            _ => 'Семья',
          },
          kind: kind,
          targetActor: kind == RoomEditKind.participantRole ? 'subject' : null,
        ),
    ];
    final document = RoomDocument()..merge(edits);
    final inventory = roomHistoryInventory(document.history);
    expect(inventory, hasLength(RoomEditKind.values.length));
    expect(
      missingRoomEdits(document.history, roomHistoryInventory([edits.first])),
      edits.skip(1).toList(),
    );
    expect(
      roomHistoryDigest(document.history),
      isNot(roomHistoryDigest([edits.first])),
    );
    for (final type in [
      RoomMessageType.hello,
      RoomMessageType.welcome,
      RoomMessageType.edits,
    ]) {
      final message = RoomMessage(
        roomId: _roomId,
        type: type,
        actor: 'remote',
        history: edits,
        roomMetadata: type != RoomMessageType.edits,
        roomRoles: type != RoomMessageType.edits,
        familyTree: type != RoomMessageType.edits,
        online: type == RoomMessageType.welcome ? 1 : null,
        hosting: type == RoomMessageType.welcome ? true : null,
      );
      final decoded = decodeRoomMessage(
        encodeRoomMessage(message).single,
        roomId: _roomId,
      );
      expect(decoded.toJson(), message.toJson());
      final restored = RoomDocument()..merge(decoded.history);
      expect(restored.text, 'Семья');
      expect(restored.latest!.kind, RoomEditKind.text);
      expect(restored.roomName, 'Семья');
      expect(restored.participantNames, {'remote': 'Семья'});
      expect(restored.participantRoles, {'subject': RoomRole.guest});
      expect(restored.toJson(), document.toJson());
    }
  });

  test(
    'fast preview contains only text even after metadata becomes latest',
    () {
      final text = _message().history.single;
      final document = RoomDocument()..merge([text]);
      final names = [
        for (final kind in [
          RoomEditKind.participantName,
          RoomEditKind.roomName,
          RoomEditKind.participantRole,
        ])
          RoomEdit(
            id: kind.name,
            author: 'remote',
            clock: 100,
            createdAt: 100,
            text: kind == RoomEditKind.participantRole ? 'guest' : 'Семья',
            kind: kind,
            targetActor: kind == RoomEditKind.participantRole
                ? 'subject'
                : null,
          ),
      ];
      document.merge(names);
      final raw = {
        ..._message(type: RoomMessageType.hello).toJson(),
        'roomMetadata': true,
        'roomRoles': true,
        'fastSync': true,
        'historyDigest': roomHistoryDigest(document.history),
        'history': [document.latest!.toJson()],
      };
      final decoded = decodeRoomMessage(raw, roomId: _roomId);
      expect(decoded.history.single.kind, RoomEditKind.text);
      expect(decoded.history.single.text, text.text);
      expect(
        decodeRoomMessage({...raw, 'history': []}, roomId: _roomId).history,
        isEmpty,
      );
      for (final metadata in names) {
        expect(
          () => decodeRoomMessage({
            ...raw,
            'history': [metadata.toJson()],
          }, roomId: _roomId),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'inventory diff sends missing edits but rejects a conflicting shared ID',
    () {
      final a = _message(actor: 'a', text: 'A').history.single;
      final b = RoomEdit(
        id: 'b',
        author: 'b',
        clock: 2,
        createdAt: 2,
        text: 'B',
      );
      expect(missingRoomEdits([a, b], roomHistoryInventory([a])), [b]);
      expect(missingRoomEdits([a, b], roomHistoryInventory([a, b])), isEmpty);
      expect(missingRoomEdits([a, b], const {}), [a, b]);
      final changed = RoomEdit(
        id: a.id,
        author: a.author,
        clock: a.clock,
        createdAt: a.createdAt,
        text: 'tampered',
      );
      expect(
        () => missingRoomEdits([a, b], roomHistoryInventory([changed])),
        throwsFormatException,
      );
    },
  );

  test('fast-sync metadata and inventory maps are validated before use', () {
    final hello = {
      ..._message(type: RoomMessageType.hello).toJson(),
      'fastSync': true,
      'historyDigest': 'a' * 64,
    };
    expect(decodeRoomMessage(hello, roomId: _roomId).fastSync, isTrue);
    final inventory = {
      'v': 1,
      'roomId': _roomId,
      'actor': 'remote',
      'type': 'inventory',
      'history': [],
      'inventory': {'edit': 'a' * 64},
    };
    expect(decodeRoomMessage(inventory, roomId: _roomId).inventory, {
      'edit': 'a' * 64,
    });
    for (final invalid in [
      {...hello, 'fastSync': 'true'},
      {...hello, 'historyDigest': null},
      {...hello, 'historyDigest': 'a' * 63},
      {...hello, 'historyDigest': 'G' * 64},
      {...hello, 'type': 'edits'},
      {...hello, 'inventory': {}},
      {...inventory, 'inventory': null},
      {...inventory, 'inventory': []},
      {
        ...inventory,
        'inventory': {'': 'a' * 64},
      },
      {
        ...inventory,
        'inventory': {'a' * 129: 'a' * 64},
      },
      {
        ...inventory,
        'inventory': {'edit': 1},
      },
      {
        ...inventory,
        'inventory': {'edit': 'a' * 63},
      },
      {...inventory, 'history': _message().toJson()['history']},
    ]) {
      expect(
        () => decodeRoomMessage(invalid, roomId: _roomId),
        throwsFormatException,
        reason: '$invalid',
      );
    }
  });

  test(
    'inventory snapshots are immutable and use ordinary bounded fragmentation',
    () {
      final source = {
        for (var index = 0; index < 300; index++) 'edit-$index': 'a' * 64,
      };
      final message = RoomMessage(
        roomId: _roomId,
        type: RoomMessageType.inventory,
        actor: 'remote',
        history: const [],
        inventory: source,
      );
      source.clear();
      expect(message.inventory, hasLength(300));
      expect(() => message.inventory!.clear(), throwsUnsupportedError);
      final chunks = encodeRoomMessage(message).toList();
      expect(chunks.length, greaterThan(1));
      final decoder = RoomMessageDecoder(roomId: _roomId);
      RoomMessage? decoded;
      for (final chunk in chunks) {
        decoded = decoder.decode(chunk).message ?? decoded;
      }
      expect(decoded!.toJson(), message.toJson());
      expect(decoder.assembling, isFalse);
    },
  );

  test('small-message boundary measures UTF-8 JSON, not text length', () {
    final overhead = utf8.encode(jsonEncode(_message().toJson())).length;
    final exact = _message(text: 'a' * (12000 - overhead));
    expect(encodeRoomMessage(exact).single['type'], 'welcome');
    final larger = _message(text: 'a' * (12001 - overhead));
    final chunks = encodeRoomMessage(larger).toList();
    expect(chunks, hasLength(2));
    expect(chunks.first['type'], 'chunk');
    expect(chunks.first['bytes'], 12001);
  });

  test('Unicode fragmentation is bounded and reassembles out of order', () {
    final message = _message(text: List.filled(16000, 'Ж😀').join());
    final chunks = encodeRoomMessage(message).toList();
    expect(chunks.length, greaterThan(2));
    for (final chunk in chunks) {
      expect(utf8.encode(jsonEncode(chunk)).length, lessThan(12000));
      expect(
        base64Decode(chunk['data'] as String).length,
        lessThanOrEqualTo(8000),
      );
    }
    final decoder = RoomMessageDecoder(roomId: _roomId);
    final first = decoder.decode(chunks.last);
    expect(first.startedTransfer, isTrue);
    expect(first.acceptedFragment, isTrue);
    expect(first.completedTransfer, isFalse);
    expect(first.message, isNull);
    expect(decoder.assembling, isTrue);
    final duplicate = decoder.decode(chunks.last);
    expect(duplicate.startedTransfer, isFalse);
    expect(duplicate.acceptedFragment, isFalse);
    expect(duplicate.message, isNull);
    RoomPacketResult? last;
    for (final chunk in chunks.take(chunks.length - 1)) {
      last = decoder.decode(jsonEncode(chunk));
    }
    expect(last!.acceptedFragment, isTrue);
    expect(last.completedTransfer, isTrue);
    expect(last.message!.toJson(), message.toJson());
    expect(decoder.assembling, isFalse);
    expect(
      decoder
          .decode(_message(type: RoomMessageType.presence).toJson())
          .message!
          .type,
      RoomMessageType.presence,
    );
  });

  test('oversized send/receive fail before starting a transfer', () {
    // The 8-MiB limit includes the JSON envelope and counts multibyte text.
    final oversized = _message(text: 'Ж' * (maxRoomTransferBytes ~/ 2));
    expect(() => encodeRoomMessage(oversized), throwsFormatException);
    final decoder = RoomMessageDecoder(roomId: _roomId);
    final value = oversized.toJson();
    expect(() => decoder.decode(value), throwsFormatException);
    expect(() => decoder.decode(jsonEncode(value)), throwsFormatException);
    expect(decoder.assembling, isFalse);
  });

  test('malformed chunk metadata and byte lengths never start assembly', () {
    final first = encodeRoomMessage(_message(text: 'a' * 13000)).first;
    for (final mutation in <Map<String, dynamic>>[
      {'v': 1.0},
      {'roomId': 'f' * 32},
      {'transfer': 'not-a-transfer-id'},
      {'actor': ''},
      {'actor': 'a' * 129},
      {'index': -1},
      {'index': first['count']},
      {'index': 0.0},
      {'count': 999999},
      {'count': 2.0},
      {'bytes': 12000},
      {'bytes': maxRoomTransferBytes + 1},
      {'data': '?'},
      {'data': 'a' * 11001},
      {
        'data': base64Encode([1, 2, 3]),
      },
    ]) {
      final decoder = RoomMessageDecoder(roomId: _roomId);
      expect(
        () => decoder.decode({...first, ...mutation}),
        throwsFormatException,
        reason: '${mutation.keys}',
      );
      expect(decoder.assembling, isFalse);
    }
    final decoder = RoomMessageDecoder(roomId: _roomId);
    expect(
      () => decoder.decode(first, expectedActor: 'another-member'),
      throwsFormatException,
    );
    expect(decoder.assembling, isFalse);
  });

  test('mixed transfers and changing duplicate fragments are rejected', () {
    final chunks = encodeRoomMessage(_message(text: 'a' * 20000)).toList();
    for (final mutation in <Map<String, dynamic>>[
      {'transfer': 'b' * 32},
      {'actor': 'changed'},
      // First chunk remains the same size; total metadata still contradicts it.
      {'bytes': chunks.first['bytes'] + 1},
    ]) {
      final decoder = RoomMessageDecoder(roomId: _roomId);
      decoder.decode(chunks.first);
      expect(
        () => decoder.decode({...chunks[1], ...mutation}),
        throwsFormatException,
      );
    }
    final decoder = RoomMessageDecoder(roomId: _roomId);
    decoder.decode(chunks.first);
    final changed = base64Decode(chunks.first['data'] as String);
    changed[0] ^= 1;
    expect(
      () => decoder.decode({...chunks.first, 'data': base64Encode(changed)}),
      throwsFormatException,
    );
    decoder.reset();
    expect(decoder.assembling, isFalse);
    expect(decoder.decode(chunks.first).startedTransfer, isTrue);
  });

  test(
    'assembled inner room, version, actor and history are validated again',
    () {
      final valid = _message(text: 'a' * 13000).toJson();
      for (final mutation in <Map<String, dynamic>>[
        {'roomId': 'f' * 32},
        {'v': 2},
        {'actor': 'different-envelope-author'},
        {'type': 'presence'},
        {
          'history': [
            {...valid['history'][0], 'clock': 9007199254740992},
          ],
        },
      ]) {
        final chunks = _rawChunks(
          utf8.encode(jsonEncode({...valid, ...mutation})),
        );
        final decoder = RoomMessageDecoder(roomId: _roomId);
        for (final chunk in chunks.take(chunks.length - 1)) {
          decoder.decode(chunk);
        }
        expect(() => decoder.decode(chunks.last), throwsFormatException);
      }
    },
  );

  test('assembled bytes must be strictly valid UTF-8 JSON', () {
    for (final bytes in [
      List<int>.filled(13000, 0xff),
      utf8.encode('not JSON ${'x' * 13000}'),
    ]) {
      final chunks = _rawChunks(bytes);
      final decoder = RoomMessageDecoder(roomId: _roomId);
      decoder.decode(chunks.first);
      expect(() => decoder.decode(chunks.last), throwsFormatException);
    }
  });
}
