import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';

String _encodeDiskJson(String source) => base64Url.encode(utf8.encode(source));

String _linkWithDisk(String payload, {RoomRole role = RoomRole.editor}) =>
    Uri.parse('https://example.com/app/')
        .replace(
          fragment: Uri(
            queryParameters: {
              'room': 'room-123',
              'role': role.name,
              'disk': payload,
            },
          ).query,
        )
        .toString();

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

  group('RoomDiskAccess', () {
    test(
      'editor access is an immutable JSON value with a legacy binding ID',
      () {
        final access = RoomDiskAccess.editor(
          bindingId: 'legacy-connect-operation:7',
          token: 'test-editor-token',
        );
        expect(access.bindingId, 'legacy-connect-operation:7');
        expect(access.token, 'test-editor-token');
        expect(access.publicUrl, isNull);
        expect(access.isEditor, isTrue);
        expect(access.toJson(), {
          'v': 1,
          'bindingId': 'legacy-connect-operation:7',
          'token': 'test-editor-token',
        });
        final same = RoomDiskAccess.fromJson(access.toJson());
        expect(same, access);
        expect(same.hashCode, access.hashCode);
        expect(
          access,
          isNot(
            RoomDiskAccess.editor(bindingId: 'other', token: access.token!),
          ),
        );
        expect(
          access,
          isNot(
            RoomDiskAccess.editor(bindingId: access.bindingId, token: 'other'),
          ),
        );
        expect(access, isNot('test-editor-token'));
      },
    );

    test('guest access contains a public link, never an OAuth token', () {
      final access = RoomDiskAccess.guest(
        bindingId: 'connect:guest',
        publicUrl: 'https://disk.yandex.ru/d/example-share',
      );
      expect(access.bindingId, 'connect:guest');
      expect(access.token, isNull);
      expect(access.isEditor, isFalse);
      expect(access.toJson(), {
        'v': 1,
        'bindingId': 'connect:guest',
        'publicUrl': 'https://disk.yandex.ru/d/example-share',
      });
      final same = RoomDiskAccess.fromJson(access.toJson());
      expect(same, access);
      expect(same.hashCode, access.hashCode);
      expect(
        access,
        isNot(
          RoomDiskAccess.guest(
            bindingId: access.bindingId,
            publicUrl: 'https://yadi.sk/d/other-share',
          ),
        ),
      );
      expect(
        access,
        isNot(
          RoomDiskAccess.editor(bindingId: access.bindingId, token: 'test'),
        ),
      );
      final json = access.toJson();
      json['bindingId'] = 'changed';
      expect(access.bindingId, 'connect:guest');
    });

    test('uses actor validation for binding IDs, not hexadecimal room IDs', () {
      for (final bindingId in ['legacy-op', 'x' * 128]) {
        expect(
          RoomDiskAccess.editor(bindingId: bindingId, token: 'test').bindingId,
          bindingId,
        );
      }
      for (final bindingId in ['', 'x' * 129]) {
        expect(
          () => RoomDiskAccess.editor(bindingId: bindingId, token: 'test'),
          throwsFormatException,
        );
        expect(
          () => RoomDiskAccess.guest(
            bindingId: bindingId,
            publicUrl: 'https://disk.yandex.ru/d/example-share',
          ),
          throwsFormatException,
        );
      }
    });

    test('validates token length, surrounding whitespace, and controls', () {
      expect(
        RoomDiskAccess.editor(bindingId: 'op', token: 't' * 4096).token,
        hasLength(4096),
      );
      for (final token in [
        '',
        ' ',
        ' test',
        'test ',
        't' * 4097,
        'test\u0000token',
        'test\ntoken',
        'test\rtoken',
        'test\ttoken',
        'test\u007ftoken',
        'test\u0085token',
        'test\u009ftoken',
      ]) {
        expect(
          () => RoomDiskAccess.editor(bindingId: 'op', token: token),
          throwsFormatException,
        );
      }
    });

    test('validation errors do not contain rejected values', () {
      const marker = 'private-test-value';
      final safeError = throwsA(
        isA<FormatException>().having(
          (error) => error.toString(),
          'safe message',
          isNot(contains(marker)),
        ),
      );
      expect(
        () => RoomDiskAccess.editor(bindingId: 'op', token: '$marker\n'),
        safeError,
      );
      expect(
        () => RoomDiskAccess.guest(
          bindingId: 'op',
          publicUrl: 'https://unrecognized.example/d/$marker',
        ),
        safeError,
      );
      expect(
        () => RoomDiskAccess.fromJson({'private-test-value': marker}),
        safeError,
      );
    });

    test('accepts only exact HTTPS share hosts and safe /d/ paths', () {
      for (final publicUrl in [
        'https://disk.yandex.ru/d/example-share',
        'https://disk.yandex.com/d/example-share',
        'https://yadi.sk/d/example-share',
        'https://disk.yandex.ru:443/d/example-share',
        'https://disk.yandex.ru/d/example-share/folder/file?download=1',
      ]) {
        expect(isValidDiskPublicUrl(publicUrl), isTrue);
        expect(
          RoomDiskAccess.guest(bindingId: 'op', publicUrl: publicUrl).publicUrl,
          publicUrl,
        );
      }
      for (final publicUrl in [
        '',
        'not-a-url',
        'http://disk.yandex.ru/d/example-share',
        'https://disk.yandex.ru:444/d/example-share',
        'https://user@disk.yandex.ru/d/example-share',
        'https://@disk.yandex.ru/d/example-share',
        'https://disk.yandex.ru/d/example-share#fragment',
        'https://disk.yandex.ru/d/example-share#',
        'https://disk.yandex.ru.evil.example/d/example-share',
        'https://evil.example/d/example-share',
        'https://download.disk.yandex.ru/d/example-share',
        'https://disk.yandex.ru./d/example-share',
        'https://disk.yandex.ru/',
        'https://disk.yandex.ru/d',
        'https://disk.yandex.ru/d/',
        'https://disk.yandex.ru/d//file',
        'https://disk.yandex.ru/not-a-share/example-share',
        'https://disk.yandex.ru/i/example-share',
        'https://disk.yandex.ru/d/%2Fexample-share',
        'https://disk.yandex.ru/d/%5Cexample-share',
        'https://disk.yandex.ru/d/%00example-share',
        'https://disk.yandex.ru/d/%FF',
        'https://disk.yandex.ru/d/example-share\n',
        ' https://disk.yandex.ru/d/example-share',
        r'https://disk.yandex.ru/d/example\share',
      ]) {
        expect(isValidDiskPublicUrl(publicUrl), isFalse);
        expect(
          () => RoomDiskAccess.guest(bindingId: 'op', publicUrl: publicUrl),
          throwsFormatException,
        );
      }
    });

    test('requires the exact versioned, discriminated JSON schema', () {
      for (final value in <Object?>[
        null,
        [],
        'not-an-object',
        {},
        {'bindingId': 'op', 'token': 'test'},
        {'v': 2, 'bindingId': 'op', 'token': 'test'},
        {'v': '1', 'bindingId': 'op', 'token': 'test'},
        {'v': true, 'bindingId': 'op', 'token': 'test'},
        {'v': 1, 'bindingId': 1, 'token': 'test'},
        {'v': 1, 'bindingId': 'op', 'token': null},
        {'v': 1, 'bindingId': 'op', 'token': 12},
        {'v': 1, 'bindingId': 'op', 'publicUrl': false},
        {'v': 1, 'bindingId': 'op', 'unknown': 'test'},
        {'v': 1, 'bindingId': 'op', 'token': 'test', 'unknown': true},
        {
          'v': 1,
          'bindingId': 'op',
          'token': 'test',
          'publicUrl': 'https://disk.yandex.ru/d/example-share',
        },
        {
          'v': 1,
          'bindingId': 'op',
          'publicUrl': 'https://disk.yandex.ru/d/example-share',
          'token': null,
        },
      ]) {
        expect(() => RoomDiskAccess.fromJson(value), throwsFormatException);
      }
    });
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
      expect(createRoomLink(base, 'room-123', diskAccess: null), expected);
      expect(createRoomQrData(base, 'room-123', diskAccess: null), expected);
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

  group('Disk-enabled invitations', () {
    for (final role in RoomRole.values) {
      final access = role == RoomRole.editor
          ? RoomDiskAccess.editor(
              bindingId: 'legacy-connect:7',
              token: 'test-token-with+punctuation/=and-кириллица',
            )
          : RoomDiskAccess.guest(
              bindingId: 'legacy-connect:7',
              publicUrl: 'https://disk.yandex.com/d/example-share?download=1',
            );
      final invitation = RoomInvitation(
        'room-123',
        role: role,
        diskAccess: access,
      );

      test('round-trips ${role.name} access in a fragment-only web link', () {
        final base = Uri.parse(
          'https://current-host.example:8443/app/?theme=dark'
          '#peer=old&role=editor&disk=old-payload&unknown=old',
        );
        final link = createRoomLink(
          base,
          invitation.roomId,
          role: role,
          diskAccess: access,
        )!;
        expect(
          createRoomQrData(base, 'room-123', role: role, diskAccess: access),
          link,
        );
        final uri = Uri.parse(link);
        expect(uri.removeFragment(), base.removeFragment());
        expect(uri.query, 'theme=dark');
        final parameters = Uri.splitQueryString(uri.fragment);
        expect(parameters.keys.toSet(), {'room', 'role', 'disk'});
        expect(parameters['room'], 'room-123');
        expect(parameters['role'], role.name);
        expect(
          parameters['disk'],
          _encodeDiskJson(jsonEncode(access.toJson())),
        );
        expect(
          utf8.decode(base64Url.decode(parameters['disk']!)),
          jsonEncode(access.toJson()),
        );
        expect(parseRoomInvitation(link), invitation);
        expect(roomInvitationFromUri(uri), invitation);
        expect(parseRoomId(link), 'room-123');
        expect(link, isNot(contains('old-payload')));
        expect(link, isNot(contains(access.bindingId)));
      });

      test('round-trips ${role.name} access in nested native QR JSON', () {
        final base = Uri.parse('file:///app/main.dart');
        expect(
          createRoomLink(base, 'room-123', role: role, diskAccess: access),
          isNull,
        );
        final data = createRoomQrData(
          base,
          'room-123',
          role: role,
          diskAccess: access,
        );
        expect(jsonDecode(data), {
          'v': 1,
          'peerId': 'room-123',
          'role': role.name,
          'disk': access.toJson(),
        });
        expect(parseRoomInvitation(data), invitation);
        expect(parseRoomId(data), 'room-123');
      });

      test(
        'rejects ${role.name} access when the requested role mismatches',
        () {
          final wrongRole = role == RoomRole.editor
              ? RoomRole.guest
              : RoomRole.editor;
          for (final base in ['https://example.com/app/', 'file:///app/']) {
            expect(
              () => createRoomLink(
                Uri.parse(base),
                'room-123',
                role: wrongRole,
                diskAccess: access,
              ),
              throwsFormatException,
            );
            expect(
              () => createRoomQrData(
                Uri.parse(base),
                'room-123',
                role: wrongRole,
                diskAccess: access,
              ),
              throwsFormatException,
            );
          }
          final link = _linkWithDisk(
            _encodeDiskJson(jsonEncode(access.toJson())),
            role: wrongRole,
          );
          expect(parseRoomInvitation(link), isNull);
          expect(roomInvitationFromUri(Uri.parse(link)), isNull);
          expect(parseRoomId(link), 'room-123');
          final data = jsonEncode({
            'peerId': 'room-123',
            'role': wrongRole.name,
            'disk': access.toJson(),
          });
          expect(parseRoomInvitation(data), isNull);
          expect(parseRoomId(data), 'room-123');
        },
      );
    }

    test('omitted role allows guest public links, but never editor tokens', () {
      final guest = RoomDiskAccess.guest(
        bindingId: 'op',
        publicUrl: 'https://yadi.sk/d/example-share',
      );
      final editor = RoomDiskAccess.editor(bindingId: 'op', token: 'test');
      for (final base in ['https://example.com/', 'file:///app/']) {
        final uri = Uri.parse(base);
        expect(
          parseRoomInvitation(
            createRoomQrData(uri, 'room-123', diskAccess: guest),
          ),
          RoomInvitation('room-123', diskAccess: guest),
        );
        expect(
          () => createRoomQrData(uri, 'room-123', diskAccess: editor),
          throwsFormatException,
        );
      }
      expect(
        parseRoomInvitation(
          'https://example.com/#room=room-123&disk='
          '${_encodeDiskJson(jsonEncode(editor.toJson()))}',
        ),
        isNull,
      );
      expect(
        parseRoomInvitation(
          jsonEncode({'peerId': 'room-123', 'disk': editor.toJson()}),
        ),
        isNull,
      );
    });

    test('invitation equality includes the complete Disk access value', () {
      final access = RoomDiskAccess.editor(bindingId: 'op', token: 'test');
      final invitation = RoomInvitation(
        'room-123',
        role: RoomRole.editor,
        diskAccess: access,
      );
      final same = RoomInvitation(
        'room-123',
        role: RoomRole.editor,
        diskAccess: RoomDiskAccess.fromJson(access.toJson()),
      );
      expect(invitation.diskAccess, access);
      expect(invitation, same);
      expect(invitation.hashCode, same.hashCode);
      expect(
        invitation,
        isNot(const RoomInvitation('room-123', role: RoomRole.editor)),
      );
      expect(
        invitation,
        isNot(
          RoomInvitation(
            'room-123',
            role: RoomRole.editor,
            diskAccess: RoomDiskAccess.editor(
              bindingId: 'other',
              token: 'test',
            ),
          ),
        ),
      );
    });

    test('rejects invalid encoding, UTF-8, JSON, and oversized payloads', () {
      final validJson = jsonEncode({
        'v': 1,
        'bindingId': 'op',
        'token': 'test',
      });
      for (final payload in [
        '',
        'a',
        'a===',
        'AA+/',
        '%not-base64',
        'not base64',
        '${_encodeDiskJson(validJson)}\n',
        base64Url.encode([0xff]),
        _encodeDiskJson('{not-json}'),
        _encodeDiskJson('null'),
        _encodeDiskJson('[]'),
        _encodeDiskJson('${' ' * (32 * 1024)}$validJson'),
        'A' * (48 * 1024),
      ]) {
        final link = _linkWithDisk(payload);
        expect(parseRoomInvitation(link), isNull);
        expect(roomInvitationFromUri(Uri.parse(link)), isNull);
        expect(parseRoomId(link), 'room-123');
      }
      expect(
        parseRoomInvitation('https://example.com/#room=room-123&disk'),
        isNull,
      );
    });

    test('accepts unpadded base64url from other invitation producers', () {
      final access = RoomDiskAccess.editor(bindingId: 'op', token: 'test');
      final payload = _encodeDiskJson(jsonEncode(access.toJson()));
      expect(
        parseRoomInvitation(_linkWithDisk(payload.replaceAll('=', ''))),
        RoomInvitation('room-123', role: RoomRole.editor, diskAccess: access),
      );
    });

    test('never downgrades invalid Disk schemas to plain invitations', () {
      for (final disk in <Object?>[
        null,
        'not-an-object',
        [],
        {},
        {'v': 2, 'bindingId': 'op', 'token': 'test'},
        {'v': 1, 'bindingId': '', 'token': 'test'},
        {'v': 1, 'bindingId': 'op', 'token': 'test\n'},
        {'v': 1, 'bindingId': 'op', 'token': 't' * 4097},
        {'v': 1, 'bindingId': 'op', 'token': 'test', 'extra': true},
        {
          'v': 1,
          'bindingId': 'op',
          'publicUrl': 'https://unrecognized.example/d/share',
        },
        {
          'v': 1,
          'bindingId': 'op',
          'publicUrl': 'https://disk.yandex.ru/d/${'x' * (32 * 1024)}',
        },
        {
          'v': 1,
          'bindingId': 'op',
          'token': 'test',
          'publicUrl': 'https://disk.yandex.ru/d/example-share',
        },
      ]) {
        for (final role in RoomRole.values) {
          final link = _linkWithDisk(
            _encodeDiskJson(jsonEncode(disk)),
            role: role,
          );
          expect(parseRoomInvitation(link), isNull);
          final data = jsonEncode({
            'peerId': 'room-123',
            'role': role.name,
            'disk': disk,
          });
          expect(parseRoomInvitation(data), isNull);
          expect(parseRoomId(data), 'room-123');
        }
      }
    });

    test(
      'ignores query Disk data; fragment Disk data replaces it, never merges',
      () {
        final access = RoomDiskAccess.editor(bindingId: 'op', token: 'test');
        final base = Uri.parse('https://example.com/?disk=invalid&role=guest');
        final link = createRoomLink(
          base,
          'room-123',
          role: RoomRole.editor,
          diskAccess: access,
        )!;
        expect(Uri.parse(link).removeFragment(), base);
        expect(
          parseRoomInvitation(link),
          RoomInvitation('room-123', role: RoomRole.editor, diskAccess: access),
        );
        expect(
          parseRoomInvitation(
            'https://example.com/?disk=invalid#room=room-123',
          ),
          const RoomInvitation('room-123'),
        );
      },
    );
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

  group('invitation security fields', () {
    test('rejects repeated fragment room, peer, role, and Disk fields', () {
      final disk = _encodeDiskJson('{"v":1,"bindingId":"op","token":"test"}');
      for (final fragment in [
        'room=room-123&room=room-123',
        'room=room-123&ro%6fm=other',
        'peer=room-123&peer=room-123',
        'peer=room-123&pe%65r=other',
        'room=room-123&peer=other',
        'room=room-123&peer=room-123',
        'room=room-123&role=editor&role=editor',
        'room=room-123&role=editor&disk=$disk&disk=$disk',
        'room=room-123&role=editor&disk=$disk&di%73k=$disk',
      ]) {
        final uri = Uri.parse('https://example.com/#$fragment');
        expect(roomInvitationFromUri(uri), isNull);
        expect(parseRoomInvitation(uri.toString()), isNull);
        expect(roomIdFromUri(uri), isNotNull);
      }
    });

    test(
      'rejects repeated raw JSON security fields, including escaped keys',
      () {
        const disk = '{"v":1,"bindingId":"op","token":"test"}';
        final escape = String.fromCharCode(92);
        for (final source in [
          '{"peerId":"room-123","peerId":"other"}',
          '{"peerId":"room-123","peer${escape}u0049d":"other"}',
          '{"v":1,"v":1,"peerId":"room-123"}',
          '{"v":1,"${escape}u0076":1,"peerId":"room-123"}',
          '{"peerId":"room-123","room":"ambiguous"}',
          '{"peerId":"room-123","peer":"ambiguous"}',
          '{"peerId":"room-123","role":"editor","disk":$disk,"disk":$disk}',
          '{"peerId":"room-123","role":"editor","disk":$disk,'
              '"di${escape}u0073k":$disk}',
        ]) {
          expect(parseRoomInvitation(source), isNull);
          expect(parseRoomId(source), isNotNull);
        }
      },
    );

    test('decodes single escaped Disk keys without inventing duplicates', () {
      final escape = String.fromCharCode(92);
      final source =
          '{"${escape}u0076":1,"binding${escape}u0049d":"op",'
          '"to${escape}u006ben":"test"}';
      final expected = RoomInvitation(
        'room-123',
        role: RoomRole.editor,
        diskAccess: RoomDiskAccess.editor(bindingId: 'op', token: 'test'),
      );
      expect(
        parseRoomInvitation(_linkWithDisk(_encodeDiskJson(source))),
        expected,
      );
      expect(
        parseRoomInvitation(
          '{"peerId":"room-123","role":"editor","disk":$source}',
        ),
        expected,
      );
    });

    test('rejects duplicate keys inside both raw Disk JSON representations', () {
      final escape = String.fromCharCode(92);
      for (final source in [
        '{"v":1,"v":1,"bindingId":"op","token":"test"}',
        '{"v":1,"bindingId":"op","bindingId":"other","token":"test"}',
        '{"v":1,"bindingId":"op","binding${escape}u0049d":"other","token":"test"}',
        '{"v":1,"bindingId":"op","token":"test","token":"test"}',
        '{"v":1,"bindingId":"op","token":"test","to${escape}u006ben":"other"}',
      ]) {
        expect(
          parseRoomInvitation(_linkWithDisk(_encodeDiskJson(source))),
          isNull,
        );
        expect(
          parseRoomInvitation(
            '{"peerId":"room-123","role":"editor","disk":$source}',
          ),
          isNull,
        );
      }
      const guestSource =
          '{"v":1,"bindingId":"op",'
          '"publicUrl":"https://yadi.sk/d/example-share",'
          '"publicUrl":"https://yadi.sk/d/other-share"}';
      expect(
        parseRoomInvitation(
          _linkWithDisk(_encodeDiskJson(guestSource), role: RoomRole.guest),
        ),
        isNull,
      );
      expect(
        parseRoomInvitation('{"peerId":"room-123","disk":$guestSource}'),
        isNull,
      );
    });

    test('preserves legacy permissive non-security metadata', () {
      expect(
        parseRoomInvitation(
          r'{"peerId":"room-123","note":"} \"disk\":{\"token\":\"test\"} {",'
          r'"extra":{"disk":{"token":"first","token":"second"}},'
          r'"note":"new note","items":[{"room":"other","room":"ignored"}]}',
        ),
        const RoomInvitation('room-123'),
      );
      expect(
        parseRoomInvitation(
          'https://example.com/#room=room-123&note=first&note=second',
        ),
        const RoomInvitation('room-123'),
      );
    });

    test('malformed web URLs with Disk data cannot become raw room IDs', () {
      for (final value in [
        'https:/#room=room-123&disk=invalid',
        'https://[invalid]/#room=room-123&disk=invalid',
      ]) {
        expect(parseRoomInvitation(value), isNull);
      }
    });
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
