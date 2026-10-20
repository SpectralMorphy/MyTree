@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mytree_webrtc_demo/cloud/yandex_disk_client.dart';
import 'package:mytree_webrtc_demo/cloud/yandex_http_web.dart';
import 'package:web/web.dart' as web;

@JS('Object.getOwnPropertyDescriptor')
external JSObject? _descriptor(JSObject target, JSString key);

@JS('Object.defineProperty')
external JSObject _defineProperty(
  JSObject target,
  JSString key,
  JSObject value,
);

extension type _Property._(JSObject _) implements JSObject {
  external factory _Property({JSAny? value, bool configurable, bool writable});
}

void _fetch(Future<web.Response> Function(String, web.RequestInit) handler) {
  final name = 'fetch'.toJS;
  final original = _descriptor(web.window, name)!;
  _defineProperty(
    web.window,
    name,
    _Property(
      value: ((JSString url, web.RequestInit options) => handler(
        url.toDart,
        options,
      ).toJS).toJS,
      configurable: true,
      writable: true,
    ),
  );
  addTearDown(() => _defineProperty(web.window, name, original));
}

web.Response _response(List<int> bytes) {
  final response = web.Response(
    Uint8List.fromList(bytes).toJS,
    web.ResponseInit(status: 200),
  );
  _defineProperty(
    response,
    'url'.toJS,
    _Property(value: 'https://storage.yandex.net/file'.toJS),
  );
  return response;
}

extension type _Source._(JSObject _) implements JSObject {
  external factory _Source({
    required JSFunction start,
    required JSFunction pull,
    required JSFunction cancel,
  });
}

/// A real JS stream with no prefetch, so each reader operation is observable.
class _StreamingBody {
  _StreamingBody({List<List<int>> chunks = const [], bool closeAtEnd = true}) {
    stream = web.ReadableStream(
      _Source(
        start: ((web.ReadableStreamDefaultController value) {
          controller = value;
        }).toJS,
        pull: ((web.ReadableStreamDefaultController value) {
          pulls++;
          if (emitted < chunks.length) {
            value.enqueue(Uint8List.fromList(chunks[emitted++]).toJS);
          } else if (closeAtEnd) {
            value.close();
          }
        }).toJS,
        cancel: (() {
          cancels++;
        }).toJS,
      ),
      web.QueuingStrategy(highWaterMark: 0),
    );
    response = web.Response(stream, web.ResponseInit(status: 200));
    _defineProperty(
      response,
      'url'.toJS,
      _Property(value: 'https://storage.yandex.net/file'.toJS),
    );
    // Streaming consumers must not fall back to whole-body buffering.
    _defineProperty(
      response,
      'arrayBuffer'.toJS,
      _Property(
        value: (() {
          arrayBufferCalls++;
          return Future<JSArrayBuffer>.error(
            StateError('Whole-body buffering is forbidden'),
          ).toJS;
        }).toJS,
      ),
    );
  }

  late final web.ReadableStream stream;
  late final web.ReadableStreamDefaultController controller;
  late final web.Response response;
  int pulls = 0;
  int emitted = 0;
  int cancels = 0;
  int arrayBufferCalls = 0;
}

TypeMatcher<http.ClientException> _safeTransportError() =>
    isA<http.ClientException>().having(
      (e) => e.toString(),
      'sanitized',
      allOf(isNot(contains('test-token')), isNot(contains('signature='))),
    );

void main() {
  test(
    'Disk fetch suppresses Referer and cookies without dropping OAuth',
    () async {
      _fetch((url, options) async {
        expect(url, 'https://cloud-api.yandex.net/v1/disk/resources');
        expect(options.referrerPolicy, 'no-referrer');
        expect(options.credentials, 'omit');
        expect(options.redirect, 'error');
        expect(options.method, 'GET');
        final headers = web.Headers(options.headers);
        expect(headers.get('authorization'), 'OAuth test-token');
        return _response([0, 128, 255]);
      });
      final client = createYandexHttpClient();
      addTearDown(client.close);
      final request = http.Request(
        'GET',
        Uri.parse('https://cloud-api.yandex.net/v1/disk/resources'),
      )..followRedirects = false;
      request.headers['Authorization'] = 'OAuth test-token';
      final response = await client.send(request);
      expect(
        (response as http.BaseResponseWithUrl).url.host,
        'storage.yandex.net',
      );
      expect(await response.stream.toBytes(), [0, 128, 255]);
    },
  );

  test(
    'anonymous download follows redirects with no headers or referrer',
    () async {
      _fetch((_, options) async {
        expect(options.referrerPolicy, 'no-referrer');
        expect(options.credentials, 'omit');
        expect(options.redirect, 'follow');
        expect(web.Headers(options.headers).get('authorization'), isNull);
        return _response([42]);
      });
      final client = createYandexHttpClient();
      addTearDown(client.close);
      final response = await client.send(
        http.Request(
          'GET',
          Uri.parse('https://downloader.disk.yandex.ru/file'),
        ),
      );
      expect(await response.stream.toBytes(), [42]);
    },
  );

  test('upload preserves binary bytes and rejects redirects', () async {
    _fetch((_, options) async {
      expect(options.redirect, 'error');
      expect(options.referrerPolicy, 'no-referrer');
      expect(options.credentials, 'omit');
      expect(web.Headers(options.headers).get('authorization'), isNull);
      expect(
        web.Headers(options.headers).get('content-type'),
        'application/octet-stream',
      );
      expect((options.body as JSUint8Array).toDart, [0, 128, 255]);
      return _response([]);
    });
    final client = createYandexHttpClient();
    addTearDown(client.close);
    final request = http.Request(
      'PUT',
      Uri.parse('https://uploader.disk.yandex.net/file'),
    )..followRedirects = false;
    request.headers['Content-Type'] = 'application/octet-stream';
    request.bodyBytes = [0, 128, 255];
    final response = await client.send(request);
    await response.stream.drain<void>();
  });

  test(
    'body is not consumed before final URL validation can cancel it',
    () async {
      final source = _StreamingBody(
        chunks: [
          [42],
        ],
      );
      final body = source.response;
      web.AbortSignal? signal;
      _fetch((_, options) async {
        signal = options.signal;
        return body;
      });
      final client = createYandexHttpClient();
      addTearDown(client.close);
      final response = await client.send(
        http.Request(
          'GET',
          Uri.parse('https://downloader.disk.yandex.ru/file'),
        ),
      );
      expect(body.bodyUsed, isFalse);
      await response.stream
          .listen((_) => fail('Cancelled body must not emit'))
          .cancel();
      expect(body.bodyUsed, isFalse);
      expect(signal!.aborted, isTrue);
      expect(source.stream.locked, isFalse);
      expect(source.pulls, 0);
      expect(source.cancels, 0);
      expect(source.arrayBufferCalls, 0);
    },
  );

  test(
    'streams chunks before EOF and releases the reader on completion',
    () async {
      final source = _StreamingBody(closeAtEnd: false);
      web.AbortSignal? signal;
      _fetch((_, options) async {
        signal = options.signal;
        return source.response;
      });
      final client = createYandexHttpClient();
      addTearDown(client.close);
      final response = await client.send(
        http.Request(
          'GET',
          Uri.parse('https://downloader.disk.yandex.ru/file'),
        ),
      );
      expect(source.response.bodyUsed, isFalse);
      expect(source.stream.locked, isFalse);
      final first = Completer<void>();
      final done = Completer<void>();
      final received = <List<int>>[];
      response.stream.listen(
        (chunk) {
          received.add(List.of(chunk));
          if (!first.isCompleted) first.complete();
        },
        onError: done.completeError,
        onDone: done.complete,
      );
      source.controller.enqueue(Uint8List.fromList([0, 128]).toJS);
      await first.future;
      expect(received, [
        [0, 128],
      ]);
      expect(done.isCompleted, isFalse);
      expect(source.stream.locked, isTrue);
      source.controller.enqueue(Uint8List.fromList([255, 42]).toJS);
      source.controller.close();
      await done.future;
      expect(received, [
        [0, 128],
        [255, 42],
      ]);
      expect(source.stream.locked, isFalse);
      expect(source.cancels, 0);
      expect(source.arrayBufferCalls, 0);
      // Successfully read bodies must no longer be in the pending request set.
      client.close();
      expect(signal!.aborted, isFalse);
    },
  );

  test('pause stops JS reads until the Dart subscription resumes', () async {
    final source = _StreamingBody(
      chunks: [
        [1],
        [2],
        [3],
      ],
    );
    _fetch((_, _) async => source.response);
    final client = createYandexHttpClient();
    addTearDown(client.close);
    final response = await client.send(
      http.Request('GET', Uri.parse('https://downloader.disk.yandex.ru/file')),
    );
    final paused = Completer<void>();
    final done = Completer<void>();
    final chunks = <List<int>>[];
    late final StreamSubscription<List<int>> subscription;
    subscription = response.stream.listen(
      (chunk) {
        chunks.add(List.of(chunk));
        if (chunks.length == 1) {
          subscription.pause();
          paused.complete();
        }
      },
      onError: done.completeError,
      onDone: done.complete,
    );
    await paused.future;
    await Future<void>.delayed(Duration.zero);
    expect(source.pulls, 1);
    expect(chunks, [
      [1],
    ]);
    subscription.resume();
    await done.future;
    expect(chunks, [
      [1],
      [2],
      [3],
    ]);
    expect(source.stream.locked, isFalse);
  });

  test(
    'cancelling during data stops reads, cancels the reader and aborts Fetch',
    () async {
      final source = _StreamingBody(
        chunks: [
          [1],
          [2],
          [3],
        ],
      );
      web.AbortSignal? signal;
      _fetch((_, options) async {
        signal = options.signal;
        return source.response;
      });
      final client = createYandexHttpClient();
      addTearDown(client.close);
      final response = await client.send(
        http.Request(
          'GET',
          Uri.parse('https://downloader.disk.yandex.ru/file'),
        ),
      );
      final cancelled = Completer<void>();
      final chunks = <List<int>>[];
      late final StreamSubscription<List<int>> subscription;
      subscription = response.stream.listen((chunk) {
        chunks.add(List.of(chunk));
        unawaited(subscription.cancel().then((_) => cancelled.complete()));
      });
      await cancelled.future;
      await Future<void>.delayed(Duration.zero);
      expect(chunks, [
        [1],
      ]);
      expect(source.pulls, 1);
      expect(source.cancels, 1);
      expect(source.stream.locked, isFalse);
      expect(source.arrayBufferCalls, 0);
      expect(signal!.aborted, isTrue);
    },
  );

  for (final closeClient in [false, true]) {
    test(
      '${closeClient ? 'close' : 'abort'} cancels an active stalled body',
      () async {
        final source = _StreamingBody(closeAtEnd: false);
        web.AbortSignal? signal;
        var calls = 0;
        _fetch((_, options) async {
          if (calls++ > 0) return _response([7]);
          signal = options.signal;
          return source.response;
        });
        final client = createYandexHttpClient();
        addTearDown(client.close);
        final abort = Completer<void>();
        final response = await client.send(
          http.AbortableRequest(
            'GET',
            Uri.parse('https://downloader.disk.yandex.ru/file'),
            abortTrigger: abort.future,
          ),
        );
        final consumed = expectLater(
          response.stream.toBytes(),
          throwsA(_safeTransportError()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(source.stream.locked, isTrue);
        if (closeClient) {
          client.close();
          client.close();
        } else {
          abort.complete();
        }
        await consumed;
        expect(signal!.aborted, isTrue);
        expect(source.cancels, 1);
        expect(source.stream.locked, isFalse);
        if (!closeClient) {
          final next = await client.send(
            http.Request(
              'GET',
              Uri.parse('https://downloader.disk.yandex.ru/next'),
            ),
          );
          expect(await next.stream.toBytes(), [7]);
        }
      },
    );
  }

  test('JS body errors are sanitized and release the reader', () async {
    final source = _StreamingBody(closeAtEnd: false);
    web.AbortSignal? signal;
    _fetch((_, options) async {
      signal = options.signal;
      return source.response;
    });
    final client = createYandexHttpClient();
    addTearDown(client.close);
    final response = await client.send(
      http.Request('GET', Uri.parse('https://downloader.disk.yandex.ru/file')),
    );
    final consumed = expectLater(
      response.stream.toBytes(),
      throwsA(_safeTransportError()),
    );
    source.controller.error('test-token https://host/?signature=secret'.toJS);
    await consumed;
    expect(source.stream.locked, isFalse);
    expect(signal!.aborted, isTrue);
    expect(source.arrayBufferCalls, 0);
  });

  test('empty responses finish without acquiring a reader', () async {
    final body = web.Response(null, web.ResponseInit(status: 204));
    _defineProperty(
      body,
      'url'.toJS,
      _Property(value: 'https://cloud-api.yandex.net/v1/disk/resources'.toJS),
    );
    _fetch((_, _) async => body);
    final client = createYandexHttpClient();
    addTearDown(client.close);
    final response = await client.send(
      http.Request(
        'PUT',
        Uri.parse('https://cloud-api.yandex.net/v1/disk/resources'),
      ),
    );
    expect(await response.stream.toBytes(), isEmpty);
    expect(body.bodyUsed, isFalse);
  });

  test('exposes Content-Length without consuming a body', () async {
    final source = _StreamingBody(
      chunks: [
        [42],
      ],
    );
    source.response.headers.set('content-length', '123');
    _fetch((_, _) async => source.response);
    final client = createYandexHttpClient();
    addTearDown(client.close);
    final response = await client.send(
      http.Request('GET', Uri.parse('https://downloader.disk.yandex.ru/file')),
    );
    expect(response.contentLength, 123);
    expect(response.headers['content-length'], '123');
    expect(source.response.bodyUsed, isFalse);
    await response.stream
        .listen((_) => fail('Cancelled body emitted'))
        .cancel();
    expect(source.response.bodyUsed, isFalse);
  });

  for (final declared in ['-1', 'test-token signature=secret']) {
    test(
      'invalid Content-Length is a safe aborted request failure: $declared',
      () async {
        final source = _StreamingBody(
          chunks: [
            [42],
          ],
        );
        source.response.headers.set('content-length', declared);
        web.AbortSignal? signal;
        _fetch((_, options) async {
          signal = options.signal;
          return source.response;
        });
        final client = createYandexHttpClient();
        addTearDown(client.close);
        await expectLater(
          client.send(
            http.Request(
              'GET',
              Uri.parse('https://downloader.disk.yandex.ru/file'),
            ),
          ),
          throwsA(_safeTransportError()),
        );
        expect(source.response.bodyUsed, isFalse);
        expect(source.pulls, 0);
        expect(signal!.aborted, isTrue);
      },
    );
  }

  for (final public in [false, true]) {
    for (final precheck in [false, true]) {
      test('${public ? 'public' : 'private'} body limit '
          '${precheck ? 'prechecks length' : 'counts chunks'} '
          'and aborts real JS streaming', () async {
        const limit = 8 * 1024 * 1024;
        const share = 'https://disk.yandex.ru/d/public-test-folder';
        const download =
            'https://downloader.disk.yandex.ru/file?signature=secret';
        final chunk = Uint8List(64 * 1024);
        final source = _StreamingBody(
          chunks: List<List<int>>.filled(130, chunk),
          closeAtEnd: false,
        );
        if (precheck) {
          source.response.headers.set('content-length', '${limit + 1}');
        }
        web.AbortSignal? signal;
        _fetch((url, options) async {
          expect(options.credentials, 'omit');
          expect(options.referrerPolicy, 'no-referrer');
          expect(web.Headers(options.headers).get('cookie'), isNull);
          if (url.startsWith('https://cloud-api.yandex.net/')) {
            final uri = Uri.parse(url);
            expect(
              web.Headers(options.headers).get('authorization'),
              public ? isNull : 'OAuth test-token',
            );
            expect(
              uri.path,
              public
                  ? '/v1/disk/public/resources/download'
                  : '/v1/disk/resources/download',
            );
            expect(
              uri.queryParameters,
              public
                  ? {'public_key': share, 'path': '/batches/test.json'}
                  : {'path': 'app:/mytree/batches/test.json'},
            );
            expect(options.redirect, 'error');
            return _response(utf8.encode(jsonEncode({'href': download})));
          }
          expect(url, download);
          expect(web.Headers(options.headers).get('authorization'), isNull);
          expect(options.redirect, 'follow');
          signal = options.signal;
          return source.response;
        });
        final raw = createYandexHttpClient();
        addTearDown(raw.close);
        final disk = YandexDiskClient(client: raw);
        addTearDown(disk.close);
        await expectLater(
          public
              ? disk.readPublicFile(share, '/batches/test.json')
              : disk.readFile('test-token', 'app:/mytree/batches/test.json'),
          throwsA(
            isA<YandexDiskException>()
                .having((e) => e.message, 'limit', contains('8 МиБ'))
                .having(
                  (e) => e.toString(),
                  'no OAuth token',
                  isNot(contains('test-token')),
                )
                .having(
                  (e) => e.toString(),
                  'no signed link',
                  isNot(contains('signature=')),
                )
                .having(
                  (e) => e.toString(),
                  'no share link',
                  isNot(contains(share)),
                ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(signal!.aborted, isTrue);
        expect(source.arrayBufferCalls, 0);
        expect(source.stream.locked, isFalse);
        if (precheck) {
          expect(source.response.bodyUsed, isFalse);
          expect(source.pulls, 0);
          expect(source.cancels, 0);
        } else {
          expect(source.emitted, 129);
          expect(source.cancels, 1);
        }
      });
    }
  }

  test('transport errors never retain credentials or signed URLs', () async {
    _fetch(
      (_, _) async =>
          throw StateError('test-token https://host/?signature=secret'),
    );
    final client = createYandexHttpClient();
    addTearDown(client.close);
    await expectLater(
      client.send(
        http.Request(
          'GET',
          Uri.parse('https://downloader.disk.yandex.ru/file'),
        ),
      ),
      throwsA(
        isA<http.ClientException>().having(
          (e) => e.toString(),
          'sanitized',
          allOf(isNot(contains('test-token')), isNot(contains('signature='))),
        ),
      ),
    );
  });

  test(
    'abortable request cancels Fetch without closing the shared client',
    () async {
      final pending = Completer<web.Response>();
      web.AbortSignal? signal;
      var calls = 0;
      _fetch((_, options) {
        if (calls++ > 0) return Future.value(_response([7]));
        signal = options.signal;
        return pending.future;
      });
      final client = createYandexHttpClient();
      addTearDown(client.close);
      final abort = Completer<void>();
      final sent = client.send(
        http.AbortableRequest(
          'GET',
          Uri.parse('https://downloader.disk.yandex.ru/file'),
          abortTrigger: abort.future,
        ),
      );
      for (var i = 0; i < 5 && signal == null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(signal, isNotNull);
      abort.complete();
      await Future<void>.delayed(Duration.zero);
      expect(signal!.aborted, isTrue);
      pending.completeError(StateError('Aborted test request'));
      await expectLater(sent, throwsA(isA<http.ClientException>()));
      final next = await client.send(
        http.Request(
          'GET',
          Uri.parse('https://downloader.disk.yandex.ru/next'),
        ),
      );
      expect(await next.stream.toBytes(), [7]);
    },
  );

  test('close aborts a pending request and refuses later sends', () async {
    final pending = Completer<web.Response>();
    web.AbortSignal? signal;
    _fetch((_, options) {
      signal = options.signal;
      return pending.future;
    });
    final client = createYandexHttpClient();
    final response = client.send(
      http.Request('GET', Uri.parse('https://downloader.disk.yandex.ru/file')),
    );
    for (var i = 0; i < 5 && signal == null; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(signal, isNotNull);
    client.close();
    client.close();
    expect(signal!.aborted, isTrue);
    pending.completeError(StateError('Aborted test request'));
    await expectLater(response, throwsA(isA<http.ClientException>()));
    await expectLater(
      client.send(
        http.Request(
          'GET',
          Uri.parse('https://downloader.disk.yandex.ru/file'),
        ),
      ),
      throwsA(isA<http.ClientException>()),
    );
  });
}
