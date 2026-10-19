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
