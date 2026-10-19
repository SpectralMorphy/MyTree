@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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
      final body = _response([42]);
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
    },
  );

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
