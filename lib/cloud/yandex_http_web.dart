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
      if (controller.signal.aborted) {
        throw http.ClientException('Yandex Disk HTTP request aborted.');
      }
      final headers = <String, String>{};
      for (final name in ['content-type', 'content-length']) {
        final value = response.headers.get(name);
        if (value != null) headers[name] = value;
      }
      final lengthHeader = headers['content-length'];
      final length = lengthHeader == null ? null : int.tryParse(lengthHeader);
      if (lengthHeader != null && (length == null || length < 0)) {
        throw http.ClientException('Yandex Disk HTTP response failed.');
      }
      final url = Uri.parse(response.url);
      // Expose the final address before reading bytes so the Disk boundary can
      // reject an unexpected redirect destination without consuming its body.
      return _YandexBrowserResponse(
        _bodyStream(response, controller),
        response.status,
        url: url,
        request: request,
        headers: headers,
        contentLength: length,
      );
    } catch (_) {
      // Fetch errors may include a signed URL. The domain client supplies the
      // safe user-facing failure; do not preserve platform exception details.
      _pending.remove(controller);
      controller.abort();
      throw http.ClientException('Yandex Disk HTTP request failed.');
    }
  }

  Stream<List<int>> _bodyStream(
    web.Response response,
    web.AbortController controller,
  ) {
    // Synchronous delivery propagates pause/cancel before another JS read.
    // Reader acquisition is still deferred: listen().cancel() must not disturb
    // the body before the caller has checked the response's final URL/length.
    final stream = StreamController<List<int>>(sync: true);
    web.ReadableStreamDefaultReader? reader;
    Completer<void>? resumeSignal;
    var finished = false;
    late final JSFunction onAbort;

    void resume() {
      final signal = resumeSignal;
      resumeSignal = null;
      signal?.complete();
    }

    void finish({bool abort = false, bool error = false}) {
      if (finished) return;
      finished = true;
      controller.signal.removeEventListener('abort', onAbort);
      _pending.remove(controller);
      resume();
      if (abort) controller.abort();
      final current = reader;
      reader = null;
      if (current != null) {
        if (abort) {
          try {
            // Do not let a failing or stalled JS cancel promise prevent abort
            // or leak a platform exception containing a signed URL.
            unawaited(
              current.cancel().toDart.then<void>(
                (_) {},
                onError: (Object _) {},
              ),
            );
          } catch (_) {
            // Cleanup errors must not replace the safe response failure.
          }
        }
        try {
          current.releaseLock();
        } catch (_) {
          // A reader may already have been detached by an abort.
        }
      }
      // Cancellation may occur inside a synchronous data callback. Deliver
      // terminal events later, never re-enter the controller's current event.
      scheduleMicrotask(() {
        if (error) {
          stream.addError(
            http.ClientException('Yandex Disk HTTP response failed.'),
          );
        }
        unawaited(stream.close());
      });
    }

    Future<void> read() async {
      if (finished) return;
      try {
        final body = response.body;
        if (body == null) {
          finish();
          return;
        }
        reader = body.getReader() as web.ReadableStreamDefaultReader;
        while (!finished) {
          if (stream.isPaused) {
            await (resumeSignal ??= Completer<void>()).future;
          }
          if (finished) return;
          final chunk = await reader!.read().toDart;
          if (finished) return;
          if (chunk.done) {
            finish();
            return;
          }
          stream.add((chunk.value! as JSUint8Array).toDart);
        }
      } catch (_) {
        finish(abort: true, error: true);
      }
    }

    onAbort = ((web.Event _) => finish(abort: true, error: true)).toJS;
    controller.signal.addEventListener('abort', onAbort);
    stream
      ..onListen = () {
        scheduleMicrotask(() => unawaited(read()));
      }
      ..onResume = resume
      ..onCancel = () => finish(abort: true);
    if (controller.signal.aborted) finish(abort: true, error: true);
    return stream.stream;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    // Abort listeners remove their controller from _pending synchronously.
    for (final controller in _pending.toList()) {
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
    super.contentLength,
  });

  @override
  final Uri url;
}
