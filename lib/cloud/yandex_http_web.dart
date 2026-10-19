import 'dart:async';
import 'dart:js_interop';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

http.Client createYandexHttpClient() => _YandexBrowserClient();

/// Disk's signed download hosts reject browser Referer headers. Keep this
/// policy scoped to Disk requests rather than changing the whole application's
/// referrer policy. No browser cookies accompany API or signed-link requests.
class _YandexBrowserClient extends http.BaseClient {
  final _pending = <web.AbortController>{};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('HTTP client is closed.');
    final controller = web.AbortController();
    _pending.add(controller);
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(abortTrigger.then((_) => controller.abort()));
    }
    try {
      final body = await request.finalize().toBytes();
      if (_closed) throw http.ClientException('HTTP client is closed.');
      final response = await web.window
          .fetch(
            request.url.toString().toJS,
            web.RequestInit(
              method: request.method,
              headers: request.headers.jsify()! as web.HeadersInit,
              body: body.isEmpty ? null : body.toJS,
              credentials: 'omit',
              referrerPolicy: 'no-referrer',
              redirect: request.followRedirects ? 'follow' : 'error',
              signal: controller.signal,
            ),
          )
          .toDart;
      final headers = <String, String>{};
      for (final name in ['content-type', 'content-length']) {
        final value = response.headers.get(name);
        if (value != null) headers[name] = value;
      }
      final stream = StreamController<List<int>>();
      var cancelled = false;
      stream.onListen = () {
        scheduleMicrotask(() async {
          if (cancelled) return;
          try {
            final buffer = await response.arrayBuffer().toDart;
            if (!cancelled) stream.add(buffer.toDart.asUint8List());
          } catch (_) {
            if (!cancelled) {
              stream.addError(
                http.ClientException('Yandex Disk HTTP response failed.'),
              );
            }
          } finally {
            _pending.remove(controller);
            unawaited(stream.close());
          }
        });
      };
      stream.onCancel = () {
        cancelled = true;
        _pending.remove(controller);
        controller.abort();
      };
      // Expose the final address before reading bytes so the Disk boundary can
      // reject an unexpected redirect destination without consuming its body.
      return _YandexBrowserResponse(
        stream.stream,
        response.status,
        url: Uri.parse(response.url),
        request: request,
        headers: headers,
      );
    } catch (_) {
      // Fetch errors may include a signed URL. The domain client supplies the
      // safe user-facing failure; do not preserve platform exception details.
      _pending.remove(controller);
      controller.abort();
      throw http.ClientException('Yandex Disk HTTP request failed.');
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final controller in _pending) {
      controller.abort();
    }
    _pending.clear();
    super.close();
  }
}

class _YandexBrowserResponse extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _YandexBrowserResponse(
    super.stream,
    super.statusCode, {
    required this.url,
    required super.request,
    required super.headers,
  });

  @override
  final Uri url;
}
