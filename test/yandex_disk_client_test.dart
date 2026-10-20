import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mytree_webrtc_demo/cloud/yandex_disk_client.dart';

const _token = 'test-oauth-secret';
const _path = 'app:/mytree/room-1/изменения & данные.bin';
const _apiHost = 'cloud-api.yandex.net';
const _publicUrl = 'https://disk.yandex.ru/d/public-test-folder';
const _publicPath = '/batches/изменения & данные.bin';
const _bodyLimit = 8 * 1024 * 1024;
const _unsafePublicUrls = [
  '',
  'http://disk.yandex.ru/d/share',
  'https://evil.example/d/share',
  'https://disk.yandex.ru.evil.example/d/share',
  'https://sub.disk.yandex.ru/d/share',
  'https://yandex.net/d/share',
  'https://yadi.sk.evil.example/d/share',
  'https://disk.yandex.ru@evil.example/d/share',
  'https://user:password@disk.yandex.ru/d/share',
  'https://disk.yandex.ru:8443/d/share',
  'https://disk.yandex.ru./d/share',
  'https://disk.yandex.ru/file',
  'https://disk.yandex.ru/d/',
  'https://disk.yandex.ru/d/share/%2Fextra',
  'https://disk.yandex.ru/d/share#fragment',
  '//disk.yandex.ru/d/share',
  '/d/share',
  'https://disk.yandex.ru/d/share\n',
];
const _download =
    'https://downloader.disk.yandex.ru/disk/bytes?signature=secret';
const _storage =
    'https://storage.yandex.net/rdisk/bytes?signature=redirect-secret';
const _upload =
    'https://uploader.disk.yandex.net/upload/bytes?signature=secret';
final _bytes = Uint8List.fromList([0, 255, 128, 10, 42]);

http.Response _json(Object? value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _link(String href) => _json({'href': href});

http.StreamedResponse _streamed(http.Response response) =>
    http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );

http.Response _page(
  List<Object?> items, {
  required int total,
  int offset = 0,
  int limit = 1000,
}) => _json({
  '_embedded': {
    'items': items,
    'total': total,
    'offset': offset,
    'limit': limit,
  },
});

Map<String, String> _file(String name) => {'name': name, 'type': 'file'};
Map<String, String> _dir(String name) => {'name': name, 'type': 'dir'};

TypeMatcher<YandexDiskException> _error({
  int? status,
  String? messageContains,
}) => isA<YandexDiskException>()
    .having((e) => e.statusCode, 'statusCode', status)
    .having((e) => e.message, 'Russian message', matches(RegExp('[А-Яа-я]')))
    .having((e) => e.toString(), 'redacted token', isNot(contains(_token)))
    .having(
      (e) => e.message,
      'message',
      messageContains == null ? isNotEmpty : contains(messageContains),
    );

void _apiRequest(http.BaseRequest request, String method, String resource) {
  expect(request.method, method);
  expect(request.url.scheme, 'https');
  expect(request.url.host, _apiHost);
  expect(request.url.path, '/v1/disk$resource');
  expect(request.url.queryParameters['path'], _path);
  expect(request.headers['authorization'], 'OAuth $_token');
  expect(request.headers['accept'], 'application/json');
  expect(request.url.toString(), isNot(contains(_token)));
  expect(request.followRedirects, isFalse);
}

void _publicRequest(http.BaseRequest request, String resource, String path) {
  expect(request.method, 'GET');
  expect(request.url.scheme, 'https');
  expect(request.url.host, _apiHost);
  expect(request.url.port, 443);
  expect(request.url.path, '/v1/disk$resource');
  expect(request.url.queryParameters['public_key'], _publicUrl);
  expect(request.url.queryParameters['path'], path);
  expect(request.headers.containsKey('authorization'), isFalse);
  expect(request.headers.containsKey('cookie'), isFalse);
  expect(request.url.toString(), isNot(contains(_token)));
  expect(request.followRedirects, isFalse);
}

TypeMatcher<YandexDiskException> _publicError({
  int? status,
  String? messageContains,
}) => _error(status: status, messageContains: messageContains)
    .having((e) => e.toString(), 'no share URL', isNot(contains(_publicUrl)))
    .having((e) => e.toString(), 'no signed URL', isNot(contains(_download)))
    .having((e) => e.toString(), 'no signature', isNot(contains('signature=')))
    .having(
      (e) => e.toString(),
      'no server body',
      isNot(contains('PRIVATE-SERVER-BODY')),
    );

void _transferRequest(http.BaseRequest request, String method, String href) {
  expect(request.method, method);
  expect(request.url.toString(), href);
  expect(request.headers.containsKey('authorization'), isFalse);
  expect(request.headers.containsKey('cookie'), isFalse);
  expect(request.headers.containsKey('accept'), isFalse);
  expect(request.followRedirects, method == 'GET');
  if (method == 'GET') expect(request.maxRedirects, 5);
}

class _FinalUrlResponse extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _FinalUrlResponse(super.stream, super.statusCode, this.url);

  @override
  final Uri url;
}

class _FinalUrlClient extends MockClient {
  _FinalUrlClient(this._url, MockClientStreamHandler handler)
    : super.streaming(handler);

  final Uri _url;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await super.send(request);
    // MockClient.streaming rebuilds responses and discards BaseResponseWithUrl.
    return request.url.toString() == _download
        ? _FinalUrlResponse(response.stream, response.statusCode, _url)
        : response;
  }
}

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler);

  int closes = 0;

  @override
  void close() => closes++;
}

Future<Object> _guardedRead(
  YandexDiskClient disk,
  String operation, {
  required bool public,
  bool Function()? isCurrent,
  DateTime? deadline,
}) async {
  if (operation == 'list') {
    return public
        ? disk.listPublicFiles(
            _publicUrl,
            isCurrent: isCurrent,
            deadline: deadline,
          )
        : disk.listFiles(
            _token,
            _path,
            isCurrent: isCurrent,
            deadline: deadline,
          );
  }
  return public
      ? disk.readPublicFile(
          _publicUrl,
          _publicPath,
          isCurrent: isCurrent,
          deadline: deadline,
        )
      : disk.readFile(_token, _path, isCurrent: isCurrent, deadline: deadline);
}

void main() {
  group('createDirectory', () {
    test(
      'creates a private application directory with OAuth and encoded path',
      () async {
        final raw = MockClient((request) async {
          _apiRequest(request, 'PUT', '/resources');
          expect(request.url.queryParameters, {'path': _path});
          expect(request.bodyBytes, isEmpty);
          return http.Response('', 201);
        });
        final disk = YandexDiskClient(client: raw);
        addTearDown(disk.close);
        await disk.createDirectory(_token, _path);
      },
    );

    test(
      '409 is idempotent only after metadata confirms a directory',
      () async {
        var calls = 0;
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            if (calls++ == 0) {
              _apiRequest(request, 'PUT', '/resources');
              return http.Response('ignored', 409);
            }
            _apiRequest(request, 'GET', '/resources');
            expect(request.url.queryParameters['fields'], 'type');
            return _json({'type': 'dir'});
          }),
        );
        addTearDown(disk.close);
        await disk.createDirectory(_token, _path);
        expect(calls, 2);
      },
    );

    for (final type in ['file', 'unknown', null]) {
      test('409 does not accept metadata type $type', () async {
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            return request.method == 'PUT'
                ? http.Response('', 409)
                : _json({'type': type});
          }),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.createDirectory(_token, _path),
          throwsA(_error(status: type == 'file' ? 409 : 200)),
        );
      });
    }

    test(
      'does not mask an error while checking conflicting metadata',
      () async {
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            return http.Response('', request.method == 'PUT' ? 409 : 403);
          }),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.createDirectory(_token, _path),
          throwsA(_error(status: 403)),
        );
      },
    );
  });

  group('publishDirectory', () {
    test(
      'publishes only when called, then reads back directory metadata',
      () async {
        var calls = 0;
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            if (calls++ == 0) {
              _apiRequest(request, 'PUT', '/resources/publish');
              expect(request.url.queryParameters, {'path': _path});
              expect(request.bodyBytes, isEmpty);
              // The PUT's link is not a trusted destination or confirmation.
              return _link('https://evil.example/$_token');
            }
            _apiRequest(request, 'GET', '/resources');
            expect(request.url.queryParameters['fields'], 'type,public_url');
            return _json({'type': 'dir', 'public_url': _publicUrl});
          }),
        );
        addTearDown(disk.close);
        expect(calls, 0);
        expect(await disk.publishDirectory(_token, _path), _publicUrl);
        expect(calls, 2);
      },
    );

    for (final metadata in <Object?>[
      null,
      [],
      {},
      {'type': 'file', 'public_url': _publicUrl},
      {'type': 'unknown', 'public_url': _publicUrl},
      {'type': 'dir'},
      {'type': 'dir', 'public_url': 42},
      for (final url in _unsafePublicUrls) {'type': 'dir', 'public_url': url},
    ].indexed) {
      test(
        'does not confirm invalid publication metadata ${metadata.$1}',
        () async {
          var calls = 0;
          final disk = YandexDiskClient(
            client: MockClient((request) async {
              calls++;
              return request.method == 'PUT'
                  ? http.Response('', 200)
                  : _json(metadata.$2);
            }),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.publishDirectory(_token, _path),
            throwsA(_publicError(status: 200)),
          );
          expect(calls, 2);
        },
      );
    }

    for (final metadataFailure in [false, true]) {
      for (final status in [202, 302, 401, 403, 503]) {
        test(
          'safe HTTP $status error at '
          '${metadataFailure ? 'publication metadata' : 'publication PUT'}',
          () async {
            var calls = 0;
            final disk = YandexDiskClient(
              client: MockClient((request) async {
                calls++;
                if (metadataFailure && request.method == 'PUT') {
                  return http.Response('', 200);
                }
                return http.Response(
                  '$_token $_publicUrl signature=secret PRIVATE-SERVER-BODY',
                  status,
                );
              }),
            );
            addTearDown(disk.close);
            await expectLater(
              disk.publishDirectory(_token, _path),
              throwsA(_publicError(status: status)),
            );
            expect(calls, metadataFailure ? 2 : 1);
          },
        );
      }
    }

    test(
      'publication metadata must be valid JSON, without leaking it',
      () async {
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            return http.Response(
              request.method == 'PUT'
                  ? ''
                  : '$_token $_publicUrl signature=secret PRIVATE-SERVER-BODY',
              200,
            );
          }),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.publishDirectory(_token, _path),
          throwsA(_publicError(status: 200)),
        );
      },
    );

    test(
      'does not complete before publication read-back confirms the URL',
      () async {
        final entered = Completer<void>();
        final metadata = Completer<http.Response>();
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            if (request.method == 'PUT') return http.Response('', 200);
            entered.complete();
            return metadata.future;
          }),
        );
        addTearDown(disk.close);
        var completed = false;
        final published = disk.publishDirectory(_token, _path).then((url) {
          completed = true;
          return url;
        });
        await entered.future;
        expect(completed, isFalse);
        metadata.complete(_json({'type': 'dir', 'public_url': _publicUrl}));
        expect(await published, _publicUrl);
      },
    );

    test('publication and metadata share one operation deadline', () async {
      var calls = 0;
      final disk = YandexDiskClient(
        timeout: const Duration(milliseconds: 150),
        client: MockClient((request) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return request.method == 'PUT'
              ? http.Response('', 200)
              : _json({'type': 'dir', 'public_url': _publicUrl});
        }),
      );
      addTearDown(disk.close);
      await expectLater(
        disk.publishDirectory(_token, _path),
        throwsA(_publicError(messageContains: 'Время ожидания')),
      );
      expect(calls, 2);
    });

    test(
      'validates private credentials and app paths before publishing',
      () async {
        final disk = YandexDiskClient(
          client: MockClient((_) async => fail('Invalid publication request')),
        );
        addTearDown(disk.close);
        await expectLater(disk.publishDirectory('', _path), throwsA(_error()));
        await expectLater(
          disk.publishDirectory(_token, 'app:/mytree/../other'),
          throwsA(_error()),
        );
      },
    );
  });

  group('listFiles', () {
    test(
      'paginates all items, filters directories, and preserves names',
      () async {
        final offsets = <String>[];
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            _apiRequest(request, 'GET', '/resources');
            final query = request.url.queryParameters;
            expect(
              query['fields'],
              '_embedded.items.name,_embedded.items.type,'
              '_embedded.total,_embedded.offset,_embedded.limit',
            );
            expect(query['limit'], '1000');
            offsets.add(query['offset']!);
            return switch (query['offset']) {
              '0' => _page(
                [_file('первый.json'), _dir('folder')],
                total: 5,
                limit: 2,
              ),
              '2' => _page(
                [_file('two & %.bin'), _dir('other')],
                total: 5,
                offset: 2,
                limit: 2,
              ),
              '4' => _page([_file('last')], total: 5, offset: 4, limit: 2),
              _ => throw StateError('Unexpected offset'),
            };
          }),
        );
        addTearDown(disk.close);
        expect(await disk.listFiles(_token, _path), [
          'первый.json',
          'two & %.bin',
          'last',
        ]);
        expect(offsets, ['0', '2', '4']);
      },
    );

    test('handles empty directories', () async {
      final disk = YandexDiskClient(
        client: MockClient((_) async => _page([], total: 0)),
      );
      addTearDown(disk.close);
      expect(await disk.listFiles(_token, _path), isEmpty);
    });

    test('continues beyond a full 1000-item page', () async {
      var calls = 0;
      final disk = YandexDiskClient(
        client: MockClient((request) async {
          calls++;
          return request.url.queryParameters['offset'] == '0'
              ? _page(List.generate(1000, (i) => _file('$i')), total: 1001)
              : _page([_file('1000')], total: 1001, offset: 1000);
        }),
      );
      addTearDown(disk.close);
      final names = await disk.listFiles(_token, _path);
      expect(names, hasLength(1001));
      expect(names.last, '1000');
      expect(calls, 2);
    });

    for (final malformed in <Object?>[
      null,
      [],
      {},
      {'_embedded': []},
      {
        '_embedded': {'items': [], 'total': 1, 'offset': 0, 'limit': 1000},
      },
      {
        '_embedded': {'items': [], 'total': 0, 'offset': 1, 'limit': 1000},
      },
      {
        '_embedded': {'items': [], 'total': -1, 'offset': 0, 'limit': 1000},
      },
      {
        '_embedded': {'items': [], 'total': 0, 'offset': 0, 'limit': 0},
      },
      {
        '_embedded': {'items': [], 'total': '0', 'offset': 0, 'limit': 1000},
      },
      {
        '_embedded': {
          'items': [_file('a')],
          'total': 0,
          'offset': 0,
          'limit': 1000,
        },
      },
      {
        '_embedded': {
          'items': [null],
          'total': 1,
          'offset': 0,
          'limit': 1000,
        },
      },
      {
        '_embedded': {
          'items': [
            {'name': 'a', 'type': 'unknown'},
          ],
          'total': 1,
          'offset': 0,
          'limit': 1000,
        },
      },
      {
        '_embedded': {
          'items': [
            {'name': 1, 'type': 'file'},
          ],
          'total': 1,
          'offset': 0,
          'limit': 1000,
        },
      },
    ].indexed) {
      test(
        'rejects malformed/non-progressing pagination ${malformed.$1}',
        () async {
          final disk = YandexDiskClient(
            client: MockClient((_) async => _json(malformed.$2)),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.listFiles(_token, _path),
            throwsA(_error(status: 200)),
          );
        },
      );
    }

    test('propagates errors on later pages, not a partial listing', () async {
      final disk = YandexDiskClient(
        client: MockClient((request) async {
          return request.url.queryParameters['offset'] == '0'
              ? _page([_file('a')], total: 2)
              : http.Response('', 503);
        }),
      );
      addTearDown(disk.close);
      await expectLater(
        disk.listFiles(_token, _path),
        throwsA(_error(status: 503)),
      );
    });
  });

  group('public folder access', () {
    test(
      'lists anonymously at the fixed API, preserving untrusted names',
      () async {
        final offsets = <String>[];
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            _publicRequest(request, '/public/resources', '/batches');
            final query = request.url.queryParameters;
            expect(
              query['fields'],
              '_embedded.items.name,_embedded.items.type,'
              '_embedded.total,_embedded.offset,_embedded.limit',
            );
            expect(query['limit'], '1000');
            offsets.add(query['offset']!);
            return query['offset'] == '0'
                ? _page(
                    [_file('первый.json'), _dir('folder')],
                    total: 3,
                    limit: 2,
                  )
                : _page([_file('two & %.bin')], total: 3, offset: 2, limit: 2);
          }),
        );
        addTearDown(disk.close);
        expect(await disk.listPublicFiles(_publicUrl), [
          'первый.json',
          'two & %.bin',
        ]);
        expect(offsets, ['0', '2']);
      },
    );

    test(
      'empty public directory uses the explicit canonical path too',
      () async {
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            _publicRequest(request, '/public/resources', '/batches');
            return _page([], total: 0);
          }),
        );
        addTearDown(disk.close);
        expect(
          await disk.listPublicFiles(_publicUrl, path: '/batches'),
          isEmpty,
        );
      },
    );

    test('reads public download metadata and bytes without OAuth', () async {
      var calls = 0;
      // Ordinary injected clients do not provide BaseResponseWithUrl.
      final disk = YandexDiskClient(
        client: MockClient((request) async {
          if (calls++ == 0) {
            _publicRequest(request, '/public/resources/download', _publicPath);
            expect(request.url.queryParameters, {
              'public_key': _publicUrl,
              'path': _publicPath,
            });
            return _link(_download);
          }
          _transferRequest(request, 'GET', _download);
          return http.Response.bytes(_bytes, 200);
        }),
      );
      addTearDown(disk.close);
      expect(await disk.readPublicFile(_publicUrl, _publicPath), _bytes);
      expect(calls, 2);
    });

    test('does not publish implicitly when listing or reading', () async {
      final disk = YandexDiskClient(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, isNot(contains('/publish')));
          if (request.url.path == '/v1/disk/public/resources') {
            return _page([], total: 0);
          }
          return request.url.host == _apiHost
              ? _link(_download)
              : http.Response.bytes(_bytes, 200);
        }),
      );
      addTearDown(disk.close);
      await disk.listPublicFiles(_publicUrl);
      await disk.readPublicFile(_publicUrl, _publicPath);
    });

    for (final url in _unsafePublicUrls.indexed) {
      test(
        'rejects unsafe public share URL ${url.$1} before requests',
        () async {
          final disk = YandexDiskClient(
            client: MockClient(
              (_) async => fail('Invalid share URL reached HTTP'),
            ),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.listPublicFiles(url.$2),
            throwsA(_publicError()),
          );
          await expectLater(
            disk.readPublicFile(url.$2, _publicPath),
            throwsA(_publicError()),
          );
        },
      );
    }

    for (final path in [
      '',
      '/',
      'batches',
      'app:/mytree/batches',
      '//batches',
      '/other',
      '/batches/',
      '/batches/name',
      '/batches/..',
      '/batches/./',
      '/batches\\name',
      '/batches\n',
      '/batches\x7f',
    ]) {
      test(
        'rejects noncanonical public listing path ${jsonEncode(path)}',
        () async {
          final disk = YandexDiskClient(
            client: MockClient(
              (_) async => fail('Invalid listing path reached HTTP'),
            ),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.listPublicFiles(_publicUrl, path: path),
            throwsA(_publicError()),
          );
        },
      );
    }

    for (final path in [
      '',
      '/',
      '/batches',
      '/batches/',
      'batches/name',
      'app:/mytree/batches/name',
      '//batches/name',
      '/other/name',
      '/batches-other/name',
      '/batches//name',
      '/batches/.',
      '/batches/..',
      '/batches/../name',
      '/batches/./name',
      '/batches/nested/name',
      '/batches/name/',
      '/batches/name\\other',
      '/batches/na\nme',
      '/batches/name\x00',
      '/batches/name\x7f',
      '/batches/name\x85',
    ]) {
      test(
        'rejects noncanonical public file path ${jsonEncode(path)}',
        () async {
          final disk = YandexDiskClient(
            client: MockClient(
              (_) async => fail('Invalid file path reached HTTP'),
            ),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.readPublicFile(_publicUrl, path),
            throwsA(_publicError()),
          );
        },
      );
    }

    test('accepts exactly 2048 listed items across bounded pages', () async {
      final offsets = <int>[];
      final disk = YandexDiskClient(
        client: MockClient((request) async {
          _publicRequest(request, '/public/resources', '/batches');
          final offset = int.parse(request.url.queryParameters['offset']!);
          offsets.add(offset);
          final limit = offset == 2000 ? 48 : 1000;
          expect(request.url.queryParameters['limit'], '$limit');
          return _page(
            List.generate(limit, (i) => _file('batch-${offset + i}.json')),
            total: 2048,
            offset: offset,
            limit: limit,
          );
        }),
      );
      addTearDown(disk.close);
      final names = await disk.listPublicFiles(_publicUrl);
      expect(names, hasLength(2048));
      expect(names.last, 'batch-2047.json');
      expect(offsets, [0, 1000, 2000]);
    });

    for (final oversizedLater in [false, true]) {
      test(
        'rejects oversized total ${oversizedLater ? 'on a later page' : 'up front'}',
        () async {
          var calls = 0;
          final disk = YandexDiskClient(
            client: MockClient((_) async {
              calls++;
              return oversizedLater && calls == 1
                  ? _page([_file('first')], total: 2)
                  : _page(
                      [_file('other')],
                      total: 2049,
                      offset: oversizedLater ? 1 : 0,
                    );
            }),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.listPublicFiles(_publicUrl),
            throwsA(_publicError(status: 200)),
          );
          expect(calls, oversizedLater ? 2 : 1);
        },
      );
    }

    for (final page in [
      _page([], total: 1),
      _page([_dir('directory')], total: 2, offset: 1),
      _page([_file('a')], total: 0),
      _page([_file('a')], total: 1, limit: 0),
      _page([_file('a')], total: 1, limit: 2049),
      _page([
        {'name': 'a', 'type': 'unknown'},
      ], total: 1),
      _json({
        '_embedded': {'items': [], 'total': '0', 'offset': 0, 'limit': 1000},
      }),
    ].indexed) {
      test('rejects invalid public pagination ${page.$1}', () async {
        var calls = 0;
        final disk = YandexDiskClient(
          client: MockClient((_) async {
            calls++;
            return page.$2;
          }),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.listPublicFiles(_publicUrl),
          throwsA(_publicError(status: 200)),
        );
        expect(calls, 1);
      });
    }

    test(
      'does not return a partial public listing after a page error',
      () async {
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            return request.url.queryParameters['offset'] == '0'
                ? _page([_file('first')], total: 2)
                : http.Response('PRIVATE-SERVER-BODY $_publicUrl', 503);
          }),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.listPublicFiles(_publicUrl),
          throwsA(_publicError(status: 503)),
        );
      },
    );

    test('rejects an unsafe public download link before transfer', () async {
      var calls = 0;
      final disk = YandexDiskClient(
        client: MockClient((request) async {
          calls++;
          _publicRequest(request, '/public/resources/download', _publicPath);
          return _link('https://evil.example/$_token?signature=secret');
        }),
      );
      addTearDown(disk.close);
      await expectLater(
        disk.readPublicFile(_publicUrl, _publicPath),
        throwsA(_publicError(status: 200)),
      );
      expect(calls, 1);
    });

    test(
      'public transfer checks the final URL before reading any bytes',
      () async {
        var consumed = false;
        var cancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () => cancelled = true,
        );
        body.add(utf8.encode('$_publicUrl PRIVATE-SERVER-BODY'));
        final closed = body.close();
        addTearDown(() => closed);
        final disk = YandexDiskClient(
          client: _FinalUrlClient(Uri.parse('https://evil.example/file'), (
            request,
            _,
          ) async {
            return request.url.host == _apiHost
                ? _streamed(_link(_download))
                : http.StreamedResponse(
                    body.stream.map((chunk) {
                      consumed = true;
                      return chunk;
                    }),
                    200,
                  );
          }),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.readPublicFile(_publicUrl, _publicPath),
          throwsA(_publicError(status: 200)),
        );
        expect(consumed, isFalse);
        expect(cancelled, isTrue);
      },
    );

    for (final transfer in [false, true]) {
      test(
        'public ${transfer ? 'transfer' : 'API'} redirects remain errors',
        () async {
          var calls = 0;
          final disk = YandexDiskClient(
            client: MockClient((request) async {
              calls++;
              if (transfer && request.url.host == _apiHost) {
                return _link(_download);
              }
              return http.Response(
                'PRIVATE-SERVER-BODY',
                302,
                headers: {'location': 'https://evil.example/file'},
              );
            }),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.readPublicFile(_publicUrl, _publicPath),
            throwsA(_publicError(status: 302)),
          );
          expect(calls, transfer ? 2 : 1);
        },
      );
    }
  });

  group('public response body bounds', () {
    for (final atApi in [false, true]) {
      for (final declaration in ['property', 'header', 'both']) {
        test('rejects oversized ${atApi ? 'metadata' : 'download'} '
            'Content-Length from $declaration before reading', () async {
          var consumed = false;
          var cancelled = false;
          var aborted = false;
          final body = StreamController<List<int>>(
            onCancel: () => cancelled = true,
          );
          body.add(utf8.encode('$_publicUrl $_token PRIVATE-SERVER-BODY'));
          final closed = body.close();
          addTearDown(() => closed);
          final disk = YandexDiskClient(
            client: MockClient.streaming((request, _) async {
              if (!atApi && request.url.host == _apiHost) {
                return _streamed(_link(_download));
              }
              unawaited(
                (request as http.Abortable).abortTrigger!.then((_) {
                  aborted = true;
                }),
              );
              return http.StreamedResponse(
                body.stream.map((chunk) {
                  consumed = true;
                  return chunk;
                }),
                200,
                contentLength: declaration == 'header' ? null : _bodyLimit + 1,
                headers: {
                  if (declaration != 'property')
                    'content-length': '${_bodyLimit + 1}',
                },
              );
            }),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.readPublicFile(_publicUrl, _publicPath),
            throwsA(_publicError(status: 200, messageContains: '8 МиБ')),
          );
          await Future<void>.delayed(Duration.zero);
          expect(consumed, isFalse);
          expect(cancelled, isTrue);
          expect(aborted, isTrue);
        });
      }
    }

    for (final misleadingLength in [false, true]) {
      test(
        'counts streaming bytes and aborts at 8 MiB + 1 '
        'with ${misleadingLength ? 'short' : 'absent'} Content-Length',
        () async {
          final chunk = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 42);
          var emitted = 0;
          var cancelled = false;
          var aborted = false;
          Stream<List<int>> chunks() async* {
            try {
              for (var i = 0; i < 128; i++) {
                emitted++;
                yield chunk;
              }
              emitted++;
              yield [1];
              emitted++;
              yield utf8.encode('$_token $_publicUrl PRIVATE-SERVER-BODY');
            } finally {
              cancelled = true;
            }
          }

          final disk = YandexDiskClient(
            client: MockClient.streaming((request, _) async {
              if (request.url.host == _apiHost) {
                return _streamed(_link(_download));
              }
              unawaited(
                (request as http.Abortable).abortTrigger!.then((_) {
                  aborted = true;
                }),
              );
              return http.StreamedResponse(
                chunks(),
                200,
                contentLength: misleadingLength ? 1 : null,
                headers: {if (misleadingLength) 'content-length': '1'},
              );
            }),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.readPublicFile(_publicUrl, _publicPath),
            throwsA(_publicError(status: 200, messageContains: '8 МиБ')),
          );
          await Future<void>.delayed(Duration.zero);
          expect(emitted, 129);
          expect(cancelled, isTrue);
          expect(aborted, isTrue);
        },
      );
    }

    test('accepts exactly 8 MiB streamed in multiple chunks', () async {
      final chunk = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 42);
      final disk = YandexDiskClient(
        client: MockClient.streaming((request, _) async {
          return request.url.host == _apiHost
              ? _streamed(_link(_download))
              : http.StreamedResponse(
                  Stream<List<int>>.fromIterable(List.filled(128, chunk)),
                  200,
                  contentLength: _bodyLimit,
                );
        }),
      );
      addTearDown(disk.close);
      final bytes = await disk.readPublicFile(_publicUrl, _publicPath);
      expect(bytes.length, _bodyLimit);
      expect(bytes.first, 42);
      expect(bytes.last, 42);
    });

    test('oversized stream cancellation cannot stall the safe error', () async {
      final cancel = Completer<void>();
      var cancelled = false;
      var aborted = false;
      final body = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
          return cancel.future;
        },
      );
      body.add(Uint8List(_bodyLimit + 1));
      final disk = YandexDiskClient(
        timeout: const Duration(milliseconds: 100),
        client: MockClient.streaming((request, _) async {
          if (request.url.host == _apiHost) return _streamed(_link(_download));
          unawaited(
            (request as http.Abortable).abortTrigger!.then((_) {
              aborted = true;
            }),
          );
          return http.StreamedResponse(body.stream, 200);
        }),
      );
      addTearDown(disk.close);
      addTearDown(() async {
        if (!cancel.isCompleted) cancel.complete();
        await body.close();
      });
      await expectLater(
        disk.readPublicFile(_publicUrl, _publicPath),
        throwsA(_publicError(status: 200, messageContains: '8 МиБ')),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isTrue);
      expect(aborted, isTrue);
    });

    test(
      'body stream errors are redacted and abort only their request',
      () async {
        var aborted = false;
        final raw = MockClient.streaming((request, _) async {
          if (request.url.host == _apiHost) return _streamed(_link(_download));
          unawaited(
            (request as http.Abortable).abortTrigger!.then((_) {
              aborted = true;
            }),
          );
          return http.StreamedResponse(
            Stream<List<int>>.error(
              StateError('$_publicUrl $_token $_download PRIVATE-SERVER-BODY'),
            ),
            200,
          );
        });
        final disk = YandexDiskClient(client: raw);
        addTearDown(disk.close);
        await expectLater(
          disk.readPublicFile(_publicUrl, _publicPath),
          throwsA(_publicError()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(aborted, isTrue);
      },
    );
  });

  group('private response body bounds', () {
    for (final operation in ['metadata', 'listing', 'download']) {
      for (final declaration in ['absent', 'short', 'property', 'header']) {
        test(
          '$operation rejects oversized private body with $declaration length',
          () async {
            final precheck =
                declaration == 'property' || declaration == 'header';
            var consumed = 0;
            var cancelled = false;
            var aborted = false;
            var calls = 0;
            final body = StreamController<List<int>>(
              onCancel: () {
                cancelled = true;
              },
            );
            if (!precheck) {
              final chunk = Uint8List(64 * 1024);
              for (var i = 0; i < 128; i++) {
                body.add(chunk);
              }
              body.add([1]);
            }
            body.add(utf8.encode('$_token $_download PRIVATE-SERVER-BODY'));
            final closed = body.close();
            addTearDown(() => closed);
            final raw = MockClient.streaming((request, _) async {
              calls++;
              if (operation == 'download' && request.url.host == _apiHost) {
                _apiRequest(request, 'GET', '/resources/download');
                return _streamed(_link(_download));
              }
              if (operation == 'download') {
                _transferRequest(request, 'GET', _download);
              } else {
                _apiRequest(
                  request,
                  'GET',
                  operation == 'metadata'
                      ? '/resources/download'
                      : '/resources',
                );
              }
              unawaited(
                (request as http.Abortable).abortTrigger!.then((_) {
                  aborted = true;
                }),
              );
              return http.StreamedResponse(
                body.stream.map((chunk) {
                  consumed++;
                  return chunk;
                }),
                200,
                contentLength: declaration == 'property'
                    ? _bodyLimit + 1
                    : declaration == 'short'
                    ? 1
                    : null,
                headers: {
                  if (declaration == 'header')
                    'content-length': '${_bodyLimit + 1}',
                  if (declaration == 'short') 'content-length': '1',
                },
              );
            });
            final disk = YandexDiskClient(client: raw);
            addTearDown(disk.close);
            await expectLater(
              operation == 'listing'
                  ? disk.listFiles(_token, _path)
                  : disk.readFile(_token, _path),
              throwsA(_publicError(status: 200, messageContains: '8 МиБ')),
            );
            await Future<void>.delayed(Duration.zero);
            expect(consumed, precheck ? 0 : 129);
            expect(cancelled, isTrue);
            expect(aborted, isTrue);
            expect(calls, operation == 'download' ? 2 : 1);
            // The caller-owned transport remains usable after one rejected body.
            raw.close();
          },
        );
      }
    }

    test('private download accepts exactly 8 MiB streamed in chunks', () async {
      final chunk = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 42);
      final disk = YandexDiskClient(
        client: MockClient.streaming((request, _) async {
          return request.url.host == _apiHost
              ? _streamed(_link(_download))
              : http.StreamedResponse(
                  Stream<List<int>>.fromIterable(List.filled(128, chunk)),
                  200,
                  contentLength: _bodyLimit,
                );
        }),
      );
      addTearDown(disk.close);
      final bytes = await disk.readFile(_token, _path);
      expect(bytes.length, _bodyLimit);
      expect(bytes.first, 42);
      expect(bytes.last, 42);
    });
  });

  group('complete listings and compound read guards', () {
    for (final public in [false, true]) {
      final access = public ? 'public' : 'private';
      for (final samePage in [false, true]) {
        for (final directory in [false, true]) {
          test('$access rejects duplicate ${directory ? 'directory' : 'file'} '
              'names ${samePage ? 'within' : 'across'} pages', () async {
            var calls = 0;
            final item = directory ? _dir('duplicate') : _file('duplicate');
            final disk = YandexDiskClient(
              client: MockClient((_) async {
                final offset = calls++;
                return samePage
                    ? _page([item, item], total: 2)
                    : _page([item], total: 2, offset: offset, limit: 1);
              }),
            );
            addTearDown(disk.close);
            await expectLater(
              _guardedRead(disk, 'list', public: public),
              throwsA(_publicError(status: 200)),
            );
            expect(calls, samePage ? 1 : 2);
          });
        }
      }

      for (final operation in ['list', 'read']) {
        test(
          '$access $operation accepts a current guard and future deadline',
          () async {
            var calls = 0;
            final disk = YandexDiskClient(
              client: MockClient((request) async {
                calls++;
                if (operation == 'list') {
                  return _page([_file('batch.json')], total: 1);
                }
                return request.url.host == _apiHost
                    ? _link(_download)
                    : http.Response.bytes(_bytes, 200);
              }),
            );
            addTearDown(disk.close);
            expect(
              await _guardedRead(
                disk,
                operation,
                public: public,
                isCurrent: () => true,
                deadline: DateTime.now().add(const Duration(seconds: 5)),
              ),
              operation == 'list' ? ['batch.json'] : _bytes,
            );
            expect(calls, operation == 'list' ? 1 : 2);
          },
        );

        test(
          '$access $operation rejects an obsolete guard before HTTP',
          () async {
            final disk = YandexDiskClient(
              client: MockClient(
                (_) async => fail('Obsolete read reached HTTP'),
              ),
            );
            addTearDown(disk.close);
            await expectLater(
              _guardedRead(
                disk,
                operation,
                public: public,
                isCurrent: () => false,
              ),
              throwsA(_publicError(messageContains: 'отменено')),
            );
          },
        );

        test('$access $operation redacts a throwing current guard', () async {
          final disk = YandexDiskClient(
            client: MockClient(
              (_) async => fail('Throwing guard reached HTTP'),
            ),
          );
          addTearDown(disk.close);
          await expectLater(
            _guardedRead(
              disk,
              operation,
              public: public,
              isCurrent: () =>
                  throw StateError('$_token $_publicUrl $_download'),
            ),
            throwsA(_publicError(messageContains: 'отменено')),
          );
        });

        test(
          '$access $operation rejects an expired absolute deadline before HTTP',
          () async {
            final disk = YandexDiskClient(
              client: MockClient(
                (_) async => fail('Expired read reached HTTP'),
              ),
            );
            addTearDown(disk.close);
            await expectLater(
              _guardedRead(
                disk,
                operation,
                public: public,
                deadline: DateTime.now().subtract(const Duration(seconds: 1)),
              ),
              throwsA(_publicError(messageContains: 'Время ожидания')),
            );
          },
        );

        test(
          '$access $operation rechecks guard after '
          '${operation == 'list' ? 'page one' : 'download metadata'}',
          () async {
            var calls = 0;
            var current = true;
            final disk = YandexDiskClient(
              client: MockClient.streaming((request, _) async {
                calls++;
                // _send releases the first request after fully consuming its
                // response, before a compound operation can issue another one.
                unawaited(
                  (request as http.Abortable).abortTrigger!.then((_) {
                    current = false;
                  }),
                );
                return _streamed(
                  operation == 'list'
                      ? _page([_file('first')], total: 2, limit: 1)
                      : _link(_download),
                );
              }),
            );
            addTearDown(disk.close);
            await expectLater(
              _guardedRead(
                disk,
                operation,
                public: public,
                isCurrent: () => current,
              ),
              throwsA(_publicError(messageContains: 'отменено')),
            );
            expect(calls, 1);
          },
        );

        test(
          '$access $operation uses the remaining absolute budget for later HTTP',
          () async {
            var calls = 0;
            var aborted = false;
            var cancelled = false;
            final stalled = StreamController<List<int>>(
              onCancel: () {
                cancelled = true;
              },
            );
            final raw = MockClient.streaming((request, _) async {
              calls++;
              if (calls == 1) {
                await Future<void>.delayed(const Duration(milliseconds: 150));
                return _streamed(
                  operation == 'list'
                      ? _page([_file('first')], total: 2, limit: 1)
                      : _link(_download),
                );
              }
              unawaited(
                (request as http.Abortable).abortTrigger!.then((_) {
                  aborted = true;
                }),
              );
              return http.StreamedResponse(stalled.stream, 200);
            });
            final disk = YandexDiskClient(
              client: raw,
              timeout: const Duration(seconds: 5),
            );
            addTearDown(disk.close);
            addTearDown(() => stalled.close());
            final clock = Stopwatch()..start();
            await expectLater(
              _guardedRead(
                disk,
                operation,
                public: public,
                deadline: DateTime.now().add(const Duration(milliseconds: 400)),
              ),
              throwsA(_publicError(messageContains: 'Время ожидания')),
            );
            await Future<void>.delayed(Duration.zero);
            expect(calls, 2);
            expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)));
            expect(aborted, isTrue);
            expect(cancelled, isTrue);
          },
        );
      }

      test(
        '$access guard rejection after headers cancels an unread body',
        () async {
          var current = true;
          var consumed = false;
          var cancelled = false;
          var aborted = false;
          var calls = 0;
          final body = StreamController<List<int>>(
            onCancel: () {
              cancelled = true;
            },
          );
          body.add(utf8.encode('$_token PRIVATE-SERVER-BODY'));
          final closed = body.close();
          addTearDown(() => closed);
          final disk = YandexDiskClient(
            client: MockClient.streaming((request, _) async {
              calls++;
              unawaited(
                (request as http.Abortable).abortTrigger!.then((_) {
                  aborted = true;
                }),
              );
              current = false;
              return http.StreamedResponse(
                body.stream.map((chunk) {
                  consumed = true;
                  return chunk;
                }),
                200,
              );
            }),
          );
          addTearDown(disk.close);
          await expectLater(
            _guardedRead(
              disk,
              'read',
              public: public,
              isCurrent: () => current,
            ),
            throwsA(_publicError(messageContains: 'отменено')),
          );
          await Future<void>.delayed(Duration.zero);
          expect(calls, 1);
          expect(consumed, isFalse);
          expect(cancelled, isTrue);
          expect(aborted, isTrue);
        },
      );
    }
  });

  group('readFile and transfer security', () {
    test('uses private download API then anonymous binary GET', () async {
      var calls = 0;
      final disk = YandexDiskClient(
        client: MockClient((request) async {
          if (calls++ == 0) {
            _apiRequest(request, 'GET', '/resources/download');
            return _link(_download);
          }
          _transferRequest(request, 'GET', _download);
          return http.Response.bytes(_bytes, 200);
        }),
      );
      addTearDown(disk.close);
      expect(await disk.readFile(_token, _path), orderedEquals(_bytes));
      expect(calls, 2);
    });

    for (final host in [
      'yandex.net',
      'download.yandex.net',
      'yandex.ru',
      'downloader.disk.yandex.ru',
      'yandex.com',
      'download.yandex.com',
      'yadi.sk',
      'download.yadi.sk',
    ]) {
      test('allows HTTPS transfer domain $host', () async {
        final href = 'https://$host/file';
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            if (request.url.host == _apiHost) return _link(href);
            _transferRequest(request, 'GET', href);
            return http.Response.bytes([], 200);
          }),
        );
        addTearDown(disk.close);
        expect(await disk.readFile(_token, _path), isEmpty);
      });
    }

    for (final href in [
      _storage,
      'https://storage.yandex.net:443/rdisk/bytes?signature=redirect-secret',
    ]) {
      test('reads exact bytes from allowed final storage URL $href', () async {
        var calls = 0;
        final disk = YandexDiskClient(
          client: _FinalUrlClient(Uri.parse(href), (request, body) async {
            expect(await body.toBytes(), isEmpty);
            if (calls++ == 0) {
              _apiRequest(request, 'GET', '/resources/download');
              return _streamed(_link(_download));
            }
            _transferRequest(request, 'GET', _download);
            return _streamed(http.Response.bytes(_bytes, 200));
          }),
        );
        addTearDown(disk.close);
        expect(await disk.readFile(_token, _path), orderedEquals(_bytes));
        expect(calls, 2);
      });
    }

    for (final href in [
      'http://storage.yandex.net/rdisk/bytes',
      'https://evil.example/rdisk/bytes',
      'https://yandex.net.evil.example/rdisk/bytes',
      'https://evilyandex.net/rdisk/bytes',
      'https://yandex.net@evil.example/rdisk/bytes',
      'https://user:password@yandex.net/rdisk/bytes',
      'https://storage.yandex.net:8443/rdisk/bytes',
      'https://127.0.0.1/rdisk/bytes',
      'https://storage.yandex.net./rdisk/bytes',
      'https://storage.yandex.net/rdisk/bytes#fragment',
      '//storage.yandex.net/rdisk/bytes',
      '/rdisk/bytes',
    ]) {
      test('rejects unsafe final URL without reading body: $href', () async {
        final finalUrl = Uri.parse(href).replace(
          queryParameters: {'signature': 'redirect-secret', 'token': _token},
        );
        var calls = 0;
        var consumed = false;
        var cancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () {
            cancelled = true;
          },
        );
        body.add(utf8.encode('$_token PRIVATE-SERVER-BODY $finalUrl'));
        final closed = body.close();
        addTearDown(() => closed);
        final disk = YandexDiskClient(
          client: _FinalUrlClient(finalUrl, (request, requestBody) async {
            expect(await requestBody.toBytes(), isEmpty);
            if (calls++ == 0) {
              _apiRequest(request, 'GET', '/resources/download');
              return _streamed(_link(_download));
            }
            _transferRequest(request, 'GET', _download);
            return http.StreamedResponse(
              body.stream.map((chunk) {
                consumed = true;
                return chunk;
              }),
              200,
            );
          }),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.readFile(_token, _path),
          throwsA(
            _error(status: 200)
                .having(
                  (e) => e.toString(),
                  'no original signed URL',
                  isNot(contains(_download)),
                )
                .having(
                  (e) => e.toString(),
                  'no final signed URL',
                  isNot(contains(finalUrl.toString())),
                )
                .having(
                  (e) => e.toString(),
                  'no signature',
                  isNot(contains('signature=')),
                )
                .having(
                  (e) => e.toString(),
                  'no server body',
                  isNot(contains('PRIVATE-SERVER-BODY')),
                ),
          ),
        );
        expect(calls, 2);
        expect(cancelled, isTrue);
        expect(consumed, isFalse);
      });
    }

    for (final href in [
      'http://downloader.disk.yandex.ru/file',
      'https://evil.example/file',
      'https://yandex.net.evil.example/file',
      'https://evilyandex.net/file',
      'https://yandex.net@evil.example/file',
      'https://user:password@yandex.net/file',
      'https://yandex.net:8443/file',
      'https://127.0.0.1/file',
      'https://yandex.net./file',
      'https://yandex.net/file#fragment',
      '//yandex.net/file',
      '/file',
      'not a URL',
      null,
      12,
    ]) {
      for (final write in [false, true]) {
        test(
          'rejects unsafe ${write ? 'upload' : 'download'} href $href',
          () async {
            var calls = 0;
            final disk = YandexDiskClient(
              client: MockClient((_) async {
                calls++;
                return _json({'href': href});
              }),
            );
            addTearDown(disk.close);
            await expectLater(
              write
                  ? disk.writeFile(_token, _path, _bytes)
                  : disk.readFile(_token, _path),
              throwsA(_error(status: 200)),
            );
            expect(calls, 1);
          },
        );
      }
    }

    for (final apiRedirect in [false, true]) {
      for (final write in [false, true]) {
        test('rejects exposed ${write ? 'upload' : 'download'} redirects at '
            '${apiRedirect ? 'API' : 'transfer'} boundary', () async {
          var calls = 0;
          final disk = YandexDiskClient(
            client: MockClient((request) async {
              calls++;
              if (request.url.host == _apiHost) {
                _apiRequest(
                  request,
                  'GET',
                  '/resources/${write ? 'upload' : 'download'}',
                );
                if (!apiRedirect) return _link(write ? _upload : _download);
              } else {
                _transferRequest(
                  request,
                  write ? 'PUT' : 'GET',
                  write ? _upload : _download,
                );
              }
              return http.Response(
                '',
                302,
                headers: {'location': 'https://evil.example/'},
              );
            }),
          );
          addTearDown(disk.close);
          await expectLater(
            write
                ? disk.writeFile(_token, _path, _bytes)
                : disk.readFile(_token, _path),
            throwsA(_error(status: 302)),
          );
          expect(calls, apiRedirect ? 1 : 2);
        });
      }
    }

    test(
      'does not return a partial download or a transfer error body as data',
      () async {
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            return request.url.host == _apiHost
                ? _link(_download)
                : http.Response('$_token signed-link-secret', 206);
          }),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.readFile(_token, _path),
          throwsA(_error(status: 206)),
        );
      },
    );
  });

  group('writeFile', () {
    for (final status in [201, 202, 204]) {
      test(
        'confirms upload $status via anonymous redirected storage readback',
        () async {
          final calls = <String>[];
          final disk = YandexDiskClient(
            client: _FinalUrlClient(Uri.parse(_storage), (request, body) async {
              final sent = await body.toBytes();
              calls.add('${request.method} ${request.url.path}');
              if (request.url.path == '/v1/disk/resources/upload') {
                _apiRequest(request, 'GET', '/resources/upload');
                expect(request.url.queryParameters['overwrite'], 'false');
                return _streamed(_link(_upload));
              }
              if (request.url.toString() == _upload) {
                _transferRequest(request, 'PUT', _upload);
                expect(
                  request.headers['content-type'],
                  'application/octet-stream',
                );
                expect(sent, orderedEquals(_bytes));
                return _streamed(http.Response('', status));
              }
              if (request.url.host == _apiHost) {
                _apiRequest(request, 'GET', '/resources/download');
                return _streamed(_link(_download));
              }
              _transferRequest(request, 'GET', _download);
              return _streamed(http.Response.bytes(_bytes, 200));
            }),
          );
          addTearDown(disk.close);
          await disk.writeFile(_token, _path, _bytes);
          expect(calls, [
            'GET /v1/disk/resources/upload',
            'PUT /upload/bytes',
            'GET /v1/disk/resources/download',
            'GET /disk/bytes',
          ]);
        },
      );
    }

    test('does not finish while confirmation is still pending', () async {
      final confirmation = Completer<http.Response>();
      final entered = Completer<void>();
      final disk = YandexDiskClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/upload')) return _link(_upload);
          if (request.method == 'PUT') return http.Response('', 202);
          if (request.url.path.endsWith('/download')) return _link(_download);
          entered.complete();
          return confirmation.future;
        }),
      );
      addTearDown(disk.close);
      var completed = false;
      final write = disk
          .writeFile(_token, _path, _bytes)
          .then((_) => completed = true);
      await entered.future;
      expect(completed, isFalse);
      confirmation.complete(http.Response.bytes(_bytes, 200));
      await write;
      expect(completed, isTrue);
    });

    for (final conflictAtLink in [true, false]) {
      for (final identical in [true, false]) {
        test(
          '409 at ${conflictAtLink ? 'link' : 'PUT'} requires identical=$identical',
          () async {
            var puts = 0;
            final disk = YandexDiskClient(
              client: MockClient((request) async {
                if (request.url.path.endsWith('/upload')) {
                  expect(request.url.queryParameters['overwrite'], 'false');
                  return conflictAtLink
                      ? http.Response('', 409)
                      : _link(_upload);
                }
                if (request.method == 'PUT') {
                  puts++;
                  _transferRequest(request, 'PUT', _upload);
                  return http.Response('', 409);
                }
                if (request.url.path.endsWith('/download')) {
                  return _link(_download);
                }
                return http.Response.bytes(
                  identical ? _bytes : [1, 2, 3, 4, 5],
                  200,
                );
              }),
            );
            addTearDown(disk.close);
            if (identical) {
              await disk.writeFile(_token, _path, _bytes);
            } else {
              await expectLater(
                disk.writeFile(_token, _path, _bytes),
                throwsA(_error(status: 409)),
              );
            }
            expect(puts, conflictAtLink ? 0 : 1);
          },
        );
      }
    }

    test('409 rejects differing content with the same length', () async {
      final different = Uint8List.fromList(_bytes)..[2] = 0;
      final disk = YandexDiskClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/upload')) {
            return http.Response('', 409);
          }
          if (request.url.path.endsWith('/download')) return _link(_download);
          return http.Response.bytes(different, 200);
        }),
      );
      addTearDown(disk.close);
      await expectLater(
        disk.writeFile(_token, _path, _bytes),
        throwsA(_error(status: 409)),
      );
    });

    test(
      '202 polls through missing, processing, and temporarily stale bytes',
      () async {
        var reads = 0;
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/upload')) return _link(_upload);
            if (request.method == 'PUT') return http.Response('', 202);
            if (request.url.path.endsWith('/download')) {
              reads++;
              if (reads == 1) return http.Response('', 404);
              if (reads == 2) return http.Response('', 423);
              return _link(_download);
            }
            return http.Response.bytes(reads == 3 ? [42] : _bytes, 200);
          }),
        );
        addTearDown(disk.close);
        await disk.writeFile(_token, _path, _bytes);
        expect(reads, 4);
      },
    );

    test(
      'confirmation stops after five attempts, even with a long deadline',
      () async {
        var reads = 0;
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/upload')) return _link(_upload);
            if (request.method == 'PUT') return http.Response('', 202);
            reads++;
            return http.Response('', 404);
          }),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.writeFile(_token, _path, _bytes),
          throwsA(_error(status: 202)),
        );
        expect(reads, 5);
      },
    );

    for (final status in [201, 202, 204, 409]) {
      for (final missing in [true, false]) {
        test(
          '$status never succeeds with ${missing ? 'missing' : 'different'} persisted bytes',
          () async {
            var reads = 0;
            final disk = YandexDiskClient(
              timeout: const Duration(milliseconds: 150),
              client: MockClient((request) async {
                if (request.url.path.endsWith('/upload')) return _link(_upload);
                if (request.method == 'PUT') return http.Response('', status);
                if (request.url.path.endsWith('/download')) {
                  reads++;
                  return missing ? http.Response('', 404) : _link(_download);
                }
                return http.Response.bytes([42], 200);
              }),
            );
            addTearDown(disk.close);
            await expectLater(
              disk.writeFile(_token, _path, _bytes),
              throwsA(_error(status: status)),
            );
            expect(reads, 1);
          },
        );
      }
    }

    test(
      'confirmation propagates authentication failures immediately',
      () async {
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/upload')) return _link(_upload);
            if (request.method == 'PUT') return http.Response('', 202);
            return http.Response('', 401);
          }),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.writeFile(_token, _path, _bytes),
          throwsA(_error(status: 401)),
        );
      },
    );

    test('freezes caller-owned bytes before the first await', () async {
      final supplied = Uint8List.fromList(_bytes);
      final disk = YandexDiskClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/upload')) {
            supplied.fillRange(0, supplied.length, 1);
            return _link(_upload);
          }
          if (request.method == 'PUT') {
            expect(request.bodyBytes, orderedEquals(_bytes));
            return http.Response('', 201);
          }
          if (request.url.path.endsWith('/download')) return _link(_download);
          return http.Response.bytes(_bytes, 200);
        }),
      );
      addTearDown(disk.close);
      await disk.writeFile(_token, _path, supplied);
    });

    test('supports a confirmed empty immutable file', () async {
      final disk = YandexDiskClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/upload')) return _link(_upload);
          if (request.method == 'PUT') {
            expect(request.bodyBytes, isEmpty);
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/download')) return _link(_download);
          return http.Response.bytes([], 200);
        }),
      );
      addTearDown(disk.close);
      await disk.writeFile(_token, _path, Uint8List(0));
    });

    for (final atLink in [true, false]) {
      test(
        'propagates upload ${atLink ? 'link' : 'PUT'} errors without confirming',
        () async {
          var calls = 0;
          final disk = YandexDiskClient(
            client: MockClient((request) async {
              calls++;
              if (!atLink && request.url.path.endsWith('/upload')) {
                return _link(_upload);
              }
              return http.Response('', 507);
            }),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.writeFile(_token, _path, _bytes),
            throwsA(_error(status: 507)),
          );
          expect(calls, atLink ? 1 : 2);
        },
      );
    }
  });

  group('errors, deadlines, and ownership', () {
    for (final status in [400, 401, 403, 404, 409, 423, 429, 500, 503, 507]) {
      test(
        'reports safe Russian HTTP $status errors, never server bodies',
        () async {
          final disk = YandexDiskClient(
            client: MockClient((_) async {
              return http.Response(
                '$_token signature=secret PRIVATE-SERVER-BODY',
                status,
              );
            }),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.readFile(_token, _path),
            throwsA(
              _error(status: status)
                  .having(
                    (e) => e.toString(),
                    'no server body',
                    isNot(contains('PRIVATE-SERVER-BODY')),
                  )
                  .having(
                    (e) => e.toString(),
                    'no signature',
                    isNot(contains('signature=secret')),
                  ),
            ),
          );
        },
      );
    }

    for (final payload in [
      'not JSON $_token',
      '{"href": "$_token"',
      'null',
      '[]',
    ]) {
      test('does not expose malformed JSON: ${payload.length} chars', () async {
        final disk = YandexDiskClient(
          client: MockClient((_) async => http.Response(payload, 200)),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.readFile(_token, _path),
          throwsA(_error(status: 200)),
        );
      });
    }

    test('redacts network exception URLs and headers', () async {
      final disk = YandexDiskClient(
        client: MockClient((_) async {
          throw http.ClientException(
            'Authorization: OAuth $_token',
            Uri.parse(_download),
          );
        }),
      );
      addTearDown(disk.close);
      await expectLater(
        disk.readFile(_token, _path),
        throwsA(
          _error().having(
            (e) => e.toString(),
            'no link',
            isNot(contains('signature=secret')),
          ),
        ),
      );
    });

    for (final failure in [
      ArgumentError('Authorization: OAuth $_token'),
      StateError('$_token $_download'),
    ]) {
      test('redacts transport ${failure.runtimeType} failures', () async {
        final disk = YandexDiskClient(
          client: MockClient((_) async => throw failure),
        );
        addTearDown(disk.close);
        await expectLater(
          disk.readFile(_token, _path),
          throwsA(
            _error().having(
              (e) => e.toString(),
              'no signed URL',
              isNot(contains('signature=secret')),
            ),
          ),
        );
      });
    }

    test('redacts failures while consuming the response body', () async {
      final disk = YandexDiskClient(
        client: MockClient.streaming((request, _) async {
          return http.StreamedResponse(
            Stream<List<int>>.error(http.ClientException('$_token $_download')),
            200,
          );
        }),
      );
      addTearDown(disk.close);
      await expectLater(disk.readFile(_token, _path), throwsA(_error()));
    });

    for (final stalledBody in [false, true]) {
      test(
        'deadline aborts a stalled ${stalledBody ? 'body' : 'header'} request without closing the client',
        () async {
          var aborted = false;
          final pending = Completer<http.StreamedResponse>();
          final body = StreamController<List<int>>();
          final raw = MockClient.streaming((request, _) async {
            final trigger = (request as http.Abortable).abortTrigger!;
            unawaited(
              trigger.then((_) {
                aborted = true;
                if (stalledBody) {
                  body.addError(http.RequestAbortedException());
                  unawaited(body.close());
                } else {
                  pending.completeError(http.RequestAbortedException());
                }
              }),
            );
            return stalledBody
                ? http.StreamedResponse(body.stream, 200)
                : pending.future;
          });
          final disk = YandexDiskClient(
            client: raw,
            timeout: const Duration(milliseconds: 30),
          );
          addTearDown(disk.close);
          await expectLater(
            disk.readFile(_token, _path),
            throwsA(_error(messageContains: 'Время ожидания')),
          );
          await Future<void>.delayed(Duration.zero);
          expect(aborted, isTrue);
          // This caller-owned transport is not closed just to cancel one request.
          raw.close();
        },
      );
    }

    test('bounds a request waiting indefinitely for headers', () async {
      final pending = Completer<http.Response>();
      final disk = YandexDiskClient(
        client: MockClient((_) => pending.future),
        timeout: const Duration(milliseconds: 30),
      );
      addTearDown(disk.close);
      await expectLater(
        disk.readFile(_token, _path),
        throwsA(_error(messageContains: 'Время ожидания')),
      );
      pending.complete(_link(_download));
    });

    test('bounds an indefinitely streaming response body', () async {
      final body = StreamController<List<int>>();
      final disk = YandexDiskClient(
        client: MockClient.streaming(
          (request, _) async => http.StreamedResponse(body.stream, 200),
        ),
        timeout: const Duration(milliseconds: 30),
      );
      addTearDown(disk.close);
      await expectLater(
        disk.readFile(_token, _path),
        throwsA(_error(messageContains: 'Время ожидания')),
      );
      await body.close();
    });

    test('shares the deadline between API and anonymous transfer', () async {
      final disk = YandexDiskClient(
        timeout: const Duration(milliseconds: 150),
        client: MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return request.url.host == _apiHost
              ? _link(_download)
              : http.Response.bytes(_bytes, 200);
        }),
      );
      addTearDown(disk.close);
      await expectLater(
        disk.readFile(_token, _path),
        throwsA(_error(messageContains: 'Время ожидания')),
      );
    });

    for (final timeout in [Duration.zero, const Duration(seconds: -1)]) {
      test('rejects nonpositive timeout $timeout', () {
        expect(
          () => YandexDiskClient(
            client: MockClient((_) async => http.Response('', 201)),
            timeout: timeout,
          ),
          throwsArgumentError,
        );
      });
    }

    for (final path in [
      '/mytree/room',
      'disk:/mytree/room',
      'app:/other/room',
      'app:/mytree-other/room',
      'app:/mytree/../secret',
      'app:/mytree/room/./file',
      'app:/mytree//file',
      'app:/mytree/room\\file',
      'app:/mytree/room\nfile',
    ]) {
      test('rejects paths outside canonical app scope: $path', () async {
        final disk = YandexDiskClient(
          client: MockClient((_) async {
            fail('Invalid paths must not reach the network');
          }),
        );
        addTearDown(disk.close);
        await expectLater(disk.readFile(_token, path), throwsA(_error()));
      });
    }

    for (final path in ['app:/mytree', 'app:/mytree/room']) {
      test('accepts canonical folder $path', () async {
        final disk = YandexDiskClient(
          client: MockClient((request) async {
            expect(request.url.queryParameters['path'], path);
            return http.Response('', 201);
          }),
        );
        addTearDown(disk.close);
        await disk.createDirectory(_token, path);
      });
    }

    for (final token in [
      '',
      '   ',
      'secret\r\nInjected: value',
      'secret\x00',
    ]) {
      test(
        'rejects invalid tokens without requests: length ${token.length}',
        () async {
          final disk = YandexDiskClient(
            client: MockClient((_) async {
              fail('Invalid tokens must not reach the network');
            }),
          );
          addTearDown(disk.close);
          await expectLater(disk.readFile(token, _path), throwsA(_error()));
        },
      );
    }

    test('close is idempotent and leaves an injected client open', () async {
      final raw = _TrackedClient((_) async => http.Response('', 201));
      final disk = YandexDiskClient(client: raw);
      disk.close();
      disk.close();
      expect(raw.closes, 0);
      await expectLater(
        disk.readFile(_token, _path),
        throwsA(_error(messageContains: 'закрыто')),
      );
      await expectLater(
        disk.listFiles(_token, _path),
        throwsA(_error(messageContains: 'закрыто')),
      );
      await expectLater(
        disk.createDirectory(_token, _path),
        throwsA(_error(messageContains: 'закрыто')),
      );
      await expectLater(
        disk.writeFile(_token, _path, _bytes),
        throwsA(_error(messageContains: 'закрыто')),
      );
      await expectLater(
        disk.publishDirectory(_token, _path),
        throwsA(_error(messageContains: 'закрыто')),
      );
      await expectLater(
        disk.listPublicFiles(_publicUrl),
        throwsA(_publicError(messageContains: 'закрыто')),
      );
      await expectLater(
        disk.readPublicFile(_publicUrl, _publicPath),
        throwsA(_publicError(messageContains: 'закрыто')),
      );
      expect((await raw.get(Uri.https(_apiHost, '/test'))).statusCode, 201);
      raw.close();
    });

    test(
      'close closes an internally created native client exactly once',
      () {
        final raw = _TrackedClient((_) async => http.Response('', 201));
        http.runWithClient(() {
          final disk = YandexDiskClient();
          disk.close();
          disk.close();
        }, () => raw);
        expect(raw.closes, 1);
      },
      skip:
          kIsWeb, // The scoped Fetch adapter's lifetime has its own web suite.
    );

    test('exception has a stable structured public representation', () {
      const error = YandexDiskException('Нет доступа.', statusCode: 403);
      expect(error.message, 'Нет доступа.');
      expect(error.statusCode, 403);
      expect(error.toString(), 'YandexDiskException (HTTP 403): Нет доступа.');
      expect(
        const YandexDiskException('Ошибка.').toString(),
        'YandexDiskException: Ошибка.',
      );
    });
  });
}
