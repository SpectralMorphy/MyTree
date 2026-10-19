import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';

void main() {
  group('room IDs', () {
    test('generates 32 lowercase hexadecimal characters', () {
      final id = createRoomId();
      expect(id, hasLength(32));
      expect(isValidRoomId(id), isTrue);
    });

    test('successive calls produce distinct IDs', () {
      final ids = List<String>.generate(100, (_) => createRoomId());
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('room validation rejects malformed identities', () {
      for (final id in ['', 'short', 'a' * 31, 'a' * 33, 'G' * 32, 'A' * 32]) {
        expect(isValidRoomId(id), isFalse);
      }
    });
  });

  group('room invitations', () {
    test('uses the current domain without a fixed host', () {
      final data = createRoomQrData(
        Uri.parse('https://current-tunnel.example/'),
        'room-123',
      );
      expect(data, 'https://current-tunnel.example/#room=room-123');
      expect(parseRoomId(data), 'room-123');
    });

    test('preserves HTTP, port, hosting path, and query parameters', () {
      final data = createRoomQrData(
        Uri.parse('http://localhost:52173/mytree/?theme=dark#peer=old-room'),
        'new-room',
      );
      expect(data, 'http://localhost:52173/mytree/?theme=dark#room=new-room');
      expect(parseRoomId(data), 'new-room');
    });

    test('replaces the incoming invitation with the local room ID', () {
      final data = createRoomQrData(
        Uri.parse('https://example.com/app/#peer=remote-room'),
        'local-room',
      );
      expect(data, 'https://example.com/app/#room=local-room');
    });

    test('encodes the room ID as one fragment value', () {
      final data = createRoomQrData(
        Uri.parse('https://example.com/'),
        'room+one&two=three',
      );
      expect(parseRoomId(data), 'room+one&two=three');
      expect(Uri.splitQueryString(Uri.parse(data).fragment), {
        'room': 'room+one&two=three',
      });
    });

    test('does not send the ID in the URL query or path', () {
      final uri = Uri.parse(
        createRoomQrData(Uri.parse('https://example.com/app/'), 'private-room'),
      );
      expect(uri.fragment, 'room=private-room');
      expect(uri.removeFragment().toString(), 'https://example.com/app/');
    });

    for (final base in ['file:///app/main.dart', 'mytree://app/', '']) {
      test('keeps legacy JSON for a non-web URI: $base', () {
        final data = createRoomQrData(Uri.parse(base), 'native-room');
        expect(data, '{"v":1,"peerId":"native-room"}');
        expect(jsonDecode(data), {'v': 1, 'peerId': 'native-room'});
        expect(parseRoomId(data), 'native-room');
      });
    }
  });

  group('role-aware room invitations', () {
    test('is a value with a guest default', () {
      const invitation = RoomInvitation('room-123');
      const same = RoomInvitation('room-123', role: RoomRole.guest);
      expect(invitation.roomId, 'room-123');
      expect(invitation.role, RoomRole.guest);
      expect(invitation, same);
      expect(invitation.hashCode, same.hashCode);
      expect(
        invitation,
        isNot(const RoomInvitation('room-123', role: RoomRole.editor)),
      );
      expect(invitation, isNot(const RoomInvitation('other-room')));
      expect(invitation, isNot('room-123'));
    });

    test('keeps link output unchanged when the role is omitted or null', () {
      final base = Uri.parse(
        'https://example.com/app/?theme=dark#peer=old&role=editor',
      );
      const expected = 'https://example.com/app/?theme=dark#room=room-123';
      expect(createRoomLink(base, 'room-123'), expected);
      expect(createRoomLink(base, 'room-123', role: null), expected);
      expect(createRoomQrData(base, 'room-123', role: null), expected);
      expect(
        createRoomQrData(Uri.parse('file:///app/'), 'room-123', role: null),
        '{"v":1,"peerId":"room-123"}',
      );
    });

    for (final role in RoomRole.values) {
      test('round-trips the exact ${role.name} link and web QR data', () {
        final base = Uri.parse(
          'http://localhost:52173/mytree/?theme=dark#peer=old&role=editor&old=1',
        );
        final expected =
            'http://localhost:52173/mytree/?theme=dark'
            '#room=room%2Bone%26two%3Dthree&role=${role.name}';
        final invitation = RoomInvitation('room+one&two=three', role: role);
        final link = createRoomLink(base, invitation.roomId, role: role);
        expect(link, expected);
        expect(createRoomQrData(base, invitation.roomId, role: role), expected);
        expect(parseRoomInvitation(link!), invitation);
        expect(roomInvitationFromUri(Uri.parse(link)), invitation);
        expect(parseRoomId(link), invitation.roomId);
      });

      test('keeps the ${role.name} invitation only in the fragment', () {
        final base = Uri.parse(
          'https://current-host.example:8443/app/?theme=dark',
        );
        final link = Uri.parse(
          createRoomLink(base, 'private-room', role: role)!,
        );
        expect(link.origin, base.origin);
        expect(link.path, base.path);
        expect(link.query, base.query);
        expect(link.removeFragment(), base);
        expect(Uri.splitQueryString(link.fragment), {
          'room': 'private-room',
          'role': role.name,
        });
      });

      for (final base in ['file:///app/main.dart', 'mytree://app/', '']) {
        test('round-trips exact ${role.name} non-web JSON for $base', () {
          final uri = Uri.parse(base);
          expect(createRoomLink(uri, 'native-room', role: role), isNull);
          final data = createRoomQrData(uri, 'native-room', role: role);
          expect(data, '{"v":1,"peerId":"native-room","role":"${role.name}"}');
          expect(jsonDecode(data), {
            'v': 1,
            'peerId': 'native-room',
            'role': role.name,
          });
          expect(
            parseRoomInvitation(data),
            RoomInvitation('native-room', role: role),
          );
          expect(parseRoomId(data), 'native-room');
        });
      }
    }

    test('parses only the two exact role names', () {
      expect(parseRoomRole('guest'), RoomRole.guest);
      expect(parseRoomRole('editor'), RoomRole.editor);
      for (final value in [
        null,
        '',
        'owner',
        'EDITOR',
        ' editor ',
        1,
        true,
        [],
      ]) {
        expect(parseRoomRole(value), isNull);
      }
    });
  });

  group('parseRoomInvitation', () {
    for (final value in [
      '  room-123  ',
      '{"v":1,"peerId":"room-123"}',
      '{"peerId":"  room-123  "}',
      ' https://example.com/app/#room=room-123 ',
      'https://example.com/app/#peer=room-123',
    ]) {
      test('defaults raw and legacy input to guest: $value', () {
        expect(parseRoomInvitation(value), const RoomInvitation('room-123'));
      });
    }

    test('reads an explicit role from legacy peer links and JSON', () {
      for (final role in RoomRole.values) {
        final expected = RoomInvitation('room-123', role: role);
        expect(
          parseRoomInvitation(
            'https://example.com/app/#peer=%20room-123%20&role=${role.name}',
          ),
          expected,
        );
        expect(
          parseRoomInvitation(
            '{"peerId":"  room-123  ","role":"${role.name}"}',
          ),
          expected,
        );
      }
    });

    test('decodes escaped JSON role keys and values', () {
      final escape = String.fromCharCode(92);
      expect(
        parseRoomInvitation(
          '{"peerId":"room-123","${escape}u0072ole":"ed${escape}u0069tor"}',
        ),
        const RoomInvitation('room-123', role: RoomRole.editor),
      );
      expect(
        parseRoomInvitation(
          '{"peerId":"room-123","role":"guest",'
          '"ro${escape}u006ce":"editor"}',
        ),
        isNull,
      );
    });

    test('does not confuse JSON contents or nested keys with the role', () {
      expect(
        parseRoomInvitation(
          r'{"peerId":"room-123",'
          r'"note":"} \"role\":\"editor\" {",'
          r'"extra":{"role":"invalid"},"items":[{"role":"guest"}],'
          r'"role":"editor"}',
        ),
        const RoomInvitation('room-123', role: RoomRole.editor),
      );
      expect(
        parseRoomInvitation('{"peerId":"room-123","extra":{"role":"editor"}}'),
        const RoomInvitation('room-123'),
      );
    });

    for (final value in [
      '',
      '   ',
      '{}',
      '{not-json}',
      '{"peerId":12}',
      '{"peerId":""}',
      '{"peerId":"  "}',
      'https://example.com/',
      'https://example.com/#peer=',
      'https://example.com/#other=room',
      'https://example.com/?room=room-123&role=editor',
      'https://example.com/room-123/editor',
    ]) {
      test('rejects missing IDs in $value', () {
        expect(parseRoomInvitation(value), isNull);
      });
    }

    for (final roleValue in [
      'owner',
      'EDITOR',
      'Guest',
      '',
      'null',
      'guest,editor',
      '%20editor%20',
      'editor&role=guest',
      'guest&role=editor',
      'editor&role=editor',
      '&role=editor',
      'invalid&role=editor',
      'editor&ro%6ce=guest',
    ]) {
      test('rejects invalid or repeated fragment roles: $roleValue', () {
        final uri = Uri.parse(
          'https://example.com/#room=room-123&role=$roleValue',
        );
        expect(roomInvitationFromUri(uri), isNull);
        expect(parseRoomInvitation(uri.toString()), isNull);
        expect(roomIdFromUri(uri), 'room-123');
        expect(parseRoomId(uri.toString()), 'room-123');
      });
    }

    test('rejects invalid UTF-8 in the fragment', () {
      final uri = Uri.parse('https://example.com/#room=room-123&role=%FF');
      expect(roomInvitationFromUri(uri), isNull);
      expect(parseRoomInvitation(uri.toString()), isNull);
    });

    test('rejects a bare role key rather than treating it as absent', () {
      final uri = Uri.parse('https://example.com/#peer=room-123&role');
      expect(roomInvitationFromUri(uri), isNull);
      expect(parseRoomInvitation(uri.toString()), isNull);
      expect(roomIdFromUri(uri), 'room-123');
    });

    for (final roleJson in [
      'null',
      'false',
      '1',
      '""',
      '"owner"',
      '"EDITOR"',
      '" editor "',
      '["editor"]',
      '{}',
      '"guest","role":"editor"',
      '"editor","role":"guest"',
      '"editor","role":"editor"',
      'null,"role":"editor"',
    ]) {
      test('rejects invalid or repeated JSON roles: $roleJson', () {
        final data = '{"peerId":"room-123","role":$roleJson}';
        expect(parseRoomInvitation(data), isNull);
        expect(parseRoomId(data), 'room-123');
      });
    }
  });

  group('roomInvitationFromUri', () {
    test('reads current and legacy fragments with a guest default', () {
      for (final key in ['room', 'peer']) {
        expect(
          roomInvitationFromUri(
            Uri.parse('https://example.com/app/#$key=room-123'),
          ),
          const RoomInvitation('room-123'),
        );
      }
    });

    test('never reads room IDs or roles from query parameters or paths', () {
      expect(
        roomInvitationFromUri(
          Uri.parse(
            'https://example.com/editor/?room=query-room&role=editor'
            '#room=fragment-room',
          ),
        ),
        const RoomInvitation('fragment-room'),
      );
      expect(
        roomInvitationFromUri(
          Uri.parse(
            'https://example.com/guest/?role=guest&role=invalid'
            '#room=fragment-room&role=editor',
          ),
        ),
        const RoomInvitation('fragment-room', role: RoomRole.editor),
      );
    });

    for (final value in [
      'file:///app/#room=room-123&role=editor',
      'mytree://app/#peer=room-123&role=editor',
      'https://example.com/',
      'https://example.com/#other=room-123',
      'https://example.com/#peer=',
      'https://example.com/#room=%20',
      'https://example.com/#role=editor',
      'https://example.com/room-123/?role=editor',
      'https://example.com/?room=room-123#role=editor',
    ]) {
      test('rejects non-web URIs or missing fragment IDs: $value', () {
        expect(roomInvitationFromUri(Uri.parse(value)), isNull);
      });
    }
  });

  group('roomIdFromUri', () {
    test('reads current and legacy web invitations', () {
      expect(
        roomIdFromUri(Uri.parse('https://example.com/#room=current')),
        'current',
      );
      expect(
        roomIdFromUri(Uri.parse('https://example.com/#peer=legacy')),
        'legacy',
      );
      expect(roomIdFromUri(Uri.parse('file:///app/#peer=room')), isNull);
      expect(roomIdFromUri(Uri.parse('https://example.com/')), isNull);
      expect(
        roomIdFromUri(Uri.parse('https://example.com/#other=room')),
        isNull,
      );
      expect(roomIdFromUri(Uri.parse('https://example.com/#peer=')), isNull);
      expect(roomIdFromUri(Uri.parse('https://example.com/#peer=%20')), isNull);
    });
  });

  group('parseRoomId', () {
    test('still accepts raw IDs and legacy QR JSON', () {
      expect(parseRoomId('  room-123  '), 'room-123');
      expect(parseRoomId('{"v":1,"peerId":"room-123"}'), 'room-123');
      expect(parseRoomId('{"peerId":"  room-123  "}'), 'room-123');
    });

    test('accepts copied links as well as scanned links', () {
      expect(
        parseRoomId(' https://example.com/app/#peer=room-123 '),
        'room-123',
      );
    });

    for (final value in [
      '',
      '   ',
      '{}',
      '{not-json}',
      '{"peerId":12}',
      '{"peerId":""}',
      '{"peerId":"  "}',
      'https://example.com/',
      'https://example.com/#peer=',
      'https://example.com/#other=room',
    ]) {
      test('rejects missing IDs in $value', () {
        expect(parseRoomId(value), isNull);
      });
    }
  });
}
