import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../room_identity.dart' show isValidDiskPublicUrl;
import 'yandex_http_stub.dart'
    if (dart.library.js_interop) 'yandex_http_web.dart';

/// A safe, user-facing failure. Neither server bodies nor credentials are kept.
class YandexDiskException implements Exception {
  const YandexDiskException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'YandexDiskException: $message'
      : 'YandexDiskException (HTTP $statusCode): $message';
}

/// Private application-folder access and anonymous published-folder reads.
///
/// Private paths must be `app:/mytree` or descendants and require
/// cloud_api:disk.app_folder. Public paths are relative to the shared folder.
/// [timeout] bounds each complete operation, including pagination/read-back.
/// Writes are immutable and confirmed by reading the actual remote bytes.
/// An injected client remains owned by its caller.
class YandexDiskClient {
  YandexDiskClient({
    http.Client? client,
    Duration timeout = const Duration(seconds: 30),
  }) : _timeout = timeout,
       _ownsClient = client == null,
       _client = client ?? createYandexHttpClient() {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Должен быть больше нуля.');
    }
  }

  static const _endpoint = 'https://cloud-api.yandex.net/v1/disk';
  static const _listFields =
      '_embedded.items.name,_embedded.items.type,'
      '_embedded.total,_embedded.offset,_embedded.limit';
  static const _linkDomains = [
    'yandex.net',
    'yandex.ru',
    'yandex.com',
    'yadi.sk',
  ];
  static const _confirmationAttempts = 5;
  static const _maxPublicItems = 2048;
  static const _maxBodyBytes = 8 * 1024 * 1024;

  final http.Client _client;
  final bool _ownsClient;
  final Duration _timeout;
  bool _closed = false;

  Future<void> createDirectory(String token, String path) async {
    _validate(token, path);
    final clock = Stopwatch()..start();
    final response = await _api('PUT', '/resources', token, {
      'path': path,
    }, clock);
    if (response.statusCode == 201) return;
    if (response.statusCode != 409) throw _httpError(response.statusCode);

    // A 409 alone does not distinguish an existing directory from a file.
    final metadata = await _api('GET', '/resources', token, {
      'path': path,
      'fields': 'type',
    }, clock);
    _expect(metadata, 200);
    final type = _json(metadata)['type'];
    if (type == 'dir') return;
    if (type != 'file') throw _invalidResponse(metadata.statusCode);
    throw const YandexDiskException(
      'По этому пути уже существует файл, а не папка.',
      statusCode: 409,
    );
  }

  /// Publishes a private folder and confirms its share URL from metadata.
  /// Callers must obtain explicit publication confirmation in the UI first.
  Future<String> publishDirectory(String token, String path) async {
    _validate(token, path);
    final clock = Stopwatch()..start();
    final published = await _api('PUT', '/resources/publish', token, {
      'path': path,
    }, clock);
    _expect(published, 200);
    // Never follow a link returned by PUT or infer success from its status alone.
    final metadata = await _api('GET', '/resources', token, {
      'path': path,
      'fields': 'type,public_url',
    }, clock);
    _expect(metadata, 200);
    final value = _json(metadata);
    final publicUrl = value['public_url'];
    if (value['type'] != 'dir' ||
        publicUrl is! String ||
        !isValidDiskPublicUrl(publicUrl)) {
      throw _invalidResponse(metadata.statusCode);
    }
    return publicUrl;
  }

  /// [isCurrent] gates every subrequest; [deadline] is an absolute read budget.
  /// Every response body is bounded to 8 MiB while streaming.
  Future<List<String>> listFiles(
    String token,
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    _validate(token, path);
    return _listFiles(
      (offset, clock) => _api(
        'GET',
        '/resources',
        token,
        {
          'path': path,
          'fields': _listFields,
          'limit': '1000',
          'offset': '$offset',
        },
        clock,
        isCurrent: isCurrent,
        deadline: deadline,
      ),
      isCurrent: isCurrent,
      deadline: deadline,
    );
  }

  /// Lists files without OAuth or browser cookies. Names remain untrusted;
  /// the batch coordinator must validate them before constructing file paths.
  Future<List<String>> listPublicFiles(
    String publicUrl, {
    String path = '/batches',
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    _validatePublic(publicUrl, path, file: false);
    return _listFiles(
      (offset, clock) {
        final remaining = _maxPublicItems - offset;
        return _publicApi(
          '/public/resources',
          {
            'public_key': publicUrl,
            'path': path,
            'fields': _listFields,
            'limit': '${remaining < 1000 ? remaining : 1000}',
            'offset': '$offset',
          },
          clock,
          isCurrent: isCurrent,
          deadline: deadline,
        );
      },
      maxItems: _maxPublicItems,
      isCurrent: isCurrent,
      deadline: deadline,
    );
  }

  Future<List<String>> _listFiles(
    Future<http.Response> Function(int, Stopwatch) page, {
    int? maxItems,
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    final clock = Stopwatch()..start();
    final names = <String>[];
    final seenNames = <String>{};
    var offset = 0;
    while (true) {
      _remaining(clock, isCurrent: isCurrent, deadline: deadline);
      final response = await page(offset, clock);
      _expect(response, 200);
      final embedded = _json(response)['_embedded'];
      if (embedded is! Map<String, dynamic>) {
        throw _invalidResponse(response.statusCode);
      }
      final items = embedded['items'];
      final total = embedded['total'];
      final pageOffset = embedded['offset'];
      final limit = embedded['limit'];
      if (items is! List ||
          total is! int ||
          total < 0 ||
          pageOffset != offset ||
          pageOffset is! int ||
          limit is! int ||
          limit <= 0 ||
          (maxItems != null && (total > maxItems || limit > 1000)) ||
          items.length > limit ||
          offset + items.length > total ||
          (items.isEmpty && offset < total)) {
        throw _invalidResponse(response.statusCode);
      }
      for (final item in items) {
        if (item is! Map<String, dynamic> ||
            item['name'] is! String ||
            (item['name'] as String).isEmpty ||
            (item['type'] != 'file' && item['type'] != 'dir')) {
          throw _invalidResponse(response.statusCode);
        }
        final name = item['name'] as String;
        // Overlapping/repeated pages are not a complete remote inventory, even
        // when their offsets and totals appear to progress consistently.
        if (!seenNames.add(name)) throw _invalidResponse(response.statusCode);
        if (item['type'] == 'file') names.add(name);
      }
      offset += items.length;
      if (offset >= total) {
        _remaining(clock, isCurrent: isCurrent, deadline: deadline);
        return names;
      }
    }
  }

  /// [isCurrent] gates both metadata and transfer; [deadline] bounds both.
  /// Downloads are bounded to 8 MiB while streaming, including private reads.
  Future<Uint8List> readFile(
    String token,
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    _validate(token, path);
    return _readFile(
      token,
      path,
      Stopwatch()..start(),
      isCurrent: isCurrent,
      deadline: deadline,
    );
  }

  /// Downloads an untrusted public batch, bounded to 8 MiB while streaming.
  Future<Uint8List> readPublicFile(
    String publicUrl,
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    _validatePublic(publicUrl, path, file: true);
    final clock = Stopwatch()..start();
    final link = await _publicApi(
      '/public/resources/download',
      {'public_key': publicUrl, 'path': path},
      clock,
      isCurrent: isCurrent,
      deadline: deadline,
    );
    _expect(link, 200);
    final response = await _send(
      'GET',
      _link(link),
      clock,
      followDownloadRedirects: true,
      isCurrent: isCurrent,
      deadline: deadline,
    );
    _expect(response, 200);
    return response.bodyBytes;
  }

  Future<void> writeFile(String token, String path, Uint8List bytes) async {
    _validate(token, path);
    final clock = Stopwatch()..start();
    // Do not let caller mutations change the upload or the comparison mid-flight.
    final expected = Uint8List.fromList(bytes);
    final link = await _api('GET', '/resources/upload', token, {
      'path': path,
      'overwrite': 'false',
    }, clock);
    if (link.statusCode == 409) {
      await _confirm(token, path, expected, clock, 409);
      return;
    }
    _expect(link, 200);
    final uploaded = await _send('PUT', _link(link), clock, bytes: expected);
    final status = uploaded.statusCode;
    if (status != 201 && status != 202 && status != 204 && status != 409) {
      throw _httpError(status);
    }
    await _confirm(token, path, expected, clock, status);
  }

  /// Idempotent. Only closes the underlying client if this adapter created it.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  Future<Uint8List> _readFile(
    String token,
    String path,
    Stopwatch clock, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    final link = await _api(
      'GET',
      '/resources/download',
      token,
      {'path': path},
      clock,
      isCurrent: isCurrent,
      deadline: deadline,
    );
    _expect(link, 200);
    final response = await _send(
      'GET',
      _link(link),
      clock,
      followDownloadRedirects: true,
      isCurrent: isCurrent,
      deadline: deadline,
    );
    _expect(response, 200);
    return response.bodyBytes;
  }

  Future<void> _confirm(
    String token,
    String path,
    Uint8List expected,
    Stopwatch clock,
    int uploadStatus,
  ) async {
    for (var attempt = 0; attempt < _confirmationAttempts; attempt++) {
      try {
        final actual = await _readFile(token, path, clock);
        if (_equalBytes(actual, expected)) return;
        if (uploadStatus == 409) {
          throw const YandexDiskException(
            'Файл уже существует и содержит другие данные.',
            statusCode: 409,
          );
        }
      } on YandexDiskException catch (error) {
        final status = error.statusCode;
        // A new upload may not yet be visible, or may still be processing.
        if (status != 404 &&
            status != 423 &&
            status != 429 &&
            !(status != null && status >= 500 && status <= 599)) {
          rethrow;
        }
      }
      if (attempt + 1 == _confirmationAttempts) break;
      final delay = Duration(milliseconds: 200 * (1 << attempt));
      if (_remaining(clock) <= delay) break;
      await Future<void>.delayed(delay);
    }
    throw YandexDiskException(
      uploadStatus == 409
          ? 'Файл уже существует, но совпадение данных не подтверждено.'
          : 'Не удалось подтвердить сохранение файла на Яндекс Диске.',
      statusCode: uploadStatus,
    );
  }

  Future<http.Response> _api(
    String method,
    String resource,
    String token,
    Map<String, String> query,
    Stopwatch clock, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) => _send(
    method,
    Uri.parse('$_endpoint$resource').replace(queryParameters: query),
    clock,
    token: token,
    isCurrent: isCurrent,
    deadline: deadline,
  );

  Future<http.Response> _publicApi(
    String resource,
    Map<String, String> query,
    Stopwatch clock, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) => _send(
    'GET',
    Uri.parse('$_endpoint$resource').replace(queryParameters: query),
    clock,
    isCurrent: isCurrent,
    deadline: deadline,
  );

  Future<http.Response> _send(
    String method,
    Uri uri,
    Stopwatch clock, {
    String? token,
    Uint8List? bytes,
    bool followDownloadRedirects = false,
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    _ensureOpen();
    final remaining = _remaining(
      clock,
      isCurrent: isCurrent,
      deadline: deadline,
    );
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(method, uri, abortTrigger: abort.future)
          ..followRedirects = followDownloadRedirects
          ..maxRedirects = 5;
    if (token != null) {
      request.headers['Authorization'] = 'OAuth $token';
      request.headers['Accept'] = 'application/json';
    }
    if (bytes != null) {
      request.headers['Content-Type'] = 'application/octet-stream';
      request.bodyBytes = bytes;
    }
    StreamIterator<List<int>>? body;
    try {
      // Apply the deadline to both receiving headers and consuming the body.
      return await (() async {
        final response = await _client.send(request);
        // Even clients that ignore abortTrigger must not consume a late body.
        if (abort.isCompleted) {
          _discardBody(response);
          throw TimeoutException('');
        }
        try {
          _remaining(clock, isCurrent: isCurrent, deadline: deadline);
        } catch (_) {
          _discardBody(response);
          rethrow;
        }
        if (followDownloadRedirects &&
            response is http.BaseResponseWithUrl &&
            !_trustedTransferUri((response as http.BaseResponseWithUrl).url)) {
          _discardBody(response);
          throw _invalidResponse(response.statusCode);
        }
        final declaredLength = response.contentLength;
        final lengthHeader = response.headers['content-length'];
        final headerLength = int.tryParse(lengthHeader ?? '');
        if (lengthHeader != null &&
            (headerLength == null || headerLength < 0)) {
          _discardBody(response);
          throw _invalidResponse(response.statusCode);
        }
        if ((declaredLength != null && declaredLength > _maxBodyBytes) ||
            (headerLength != null && headerLength > _maxBodyBytes)) {
          _discardBody(response);
          throw _bodyTooLarge(response.statusCode);
        }
        final reader = StreamIterator<List<int>>(response.stream);
        body = reader;
        final received = BytesBuilder(copy: false);
        var length = 0;
        while (await reader.moveNext()) {
          _remaining(clock, isCurrent: isCurrent, deadline: deadline);
          final chunk = reader.current;
          length += chunk.length;
          if (length > _maxBodyBytes) {
            throw _bodyTooLarge(response.statusCode);
          }
          received.add(chunk);
        }
        _remaining(clock, isCurrent: isCurrent, deadline: deadline);
        return http.Response.bytes(
          received.takeBytes(),
          response.statusCode,
          request: response.request,
          headers: response.headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase,
        );
      })().timeout(remaining);
    } on YandexDiskException {
      rethrow;
    } on TimeoutException {
      throw const YandexDiskException(
        'Время ожидания ответа Яндекс Диска истекло.',
      );
    } catch (_) {
      // Transport failures (including header validation Errors) may contain
      // signed URLs or request headers. Do not retain the original failure.
      throw const YandexDiskException('Не удалось связаться с Яндекс Диском.');
    } finally {
      // Future.timeout alone leaves Fetch/body consumption alive. Releasing the
      // trigger also frees the adapter's cancellation callback after success.
      abort.complete();
      final reader = body;
      if (reader != null) {
        // Cleanup must not outlive the operation's deadline or replace a safe
        // error with transport details from a failing cancellation callback.
        try {
          unawaited(reader.cancel().catchError((Object _) {}));
        } catch (_) {
          // Some injected transports also throw synchronously during cleanup.
        }
      }
      // Complete the request lifecycle before its caller can start a follow-up
      // page/transfer. Async abort listeners may invalidate the read guard;
      // without this barrier an await fast path can send once more first.
      // Await only our completed signal, never transport cancellation futures.
      await abort.future;
    }
  }

  static void _discardBody(http.StreamedResponse response) {
    try {
      unawaited(
        response.stream.listen((_) {}).cancel().catchError((Object _) {}),
      );
    } catch (_) {
      // The request's abort trigger is also released in _send's finally block.
    }
  }

  Duration _remaining(
    Stopwatch clock, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) {
    _ensureOpen();
    if (isCurrent != null) {
      var current = false;
      try {
        current = isCurrent();
      } catch (_) {
        // A guard may capture credentials; never expose its original failure.
      }
      if (!current) {
        throw const YandexDiskException('Чтение Яндекс Диска отменено.');
      }
    }
    var remaining = _timeout - clock.elapsed;
    if (deadline != null) {
      final absoluteRemaining = deadline.difference(DateTime.now());
      if (absoluteRemaining < remaining) remaining = absoluteRemaining;
    }
    if (remaining <= Duration.zero) {
      throw const YandexDiskException(
        'Время ожидания ответа Яндекс Диска истекло.',
      );
    }
    return remaining;
  }

  void _ensureOpen() {
    if (_closed) {
      throw const YandexDiskException('Подключение к Яндекс Диску закрыто.');
    }
  }

  void _validate(String token, String path) {
    _ensureOpen();
    if (token.trim().isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(token)) {
      throw const YandexDiskException(
        'Не указан корректный токен Яндекс Диска.',
      );
    }
    final segments = path.split('/');
    if ((path != 'app:/mytree' && !path.startsWith('app:/mytree/')) ||
        path.contains('\\') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(path) ||
        segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const YandexDiskException(
        'Путь должен находиться в папке app:/mytree.',
      );
    }
  }

  void _validatePublic(String publicUrl, String path, {required bool file}) {
    _ensureOpen();
    if (!isValidDiskPublicUrl(publicUrl)) {
      throw const YandexDiskException(
        'Не указана корректная публичная ссылка Яндекс Диска.',
      );
    }
    final segments = path.split('/');
    final canonical = file
        ? segments.length == 3 &&
              segments[0].isEmpty &&
              segments[1] == 'batches' &&
              segments[2].isNotEmpty &&
              segments[2] != '.' &&
              segments[2] != '..'
        : path == '/batches';
    if (!canonical ||
        path.contains('\\') ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(path)) {
      throw const YandexDiskException(
        'Путь должен находиться в публичной папке /batches.',
      );
    }
  }

  static Map<String, dynamic> _json(http.Response response) {
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map<String, dynamic>) return value;
    } on FormatException {
      // Do not expose response contents or a decoder's error details.
    }
    throw _invalidResponse(response.statusCode);
  }

  static Uri _link(http.Response response) {
    final href = _json(response)['href'];
    if (href is String) {
      final uri = Uri.tryParse(href);
      if (uri != null && _trustedTransferUri(uri)) return uri;
    }
    throw _invalidResponse(response.statusCode);
  }

  static bool _trustedTransferUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.hasAuthority &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      !uri.hasFragment &&
      _linkDomains.any(
        (domain) => uri.host == domain || uri.host.endsWith('.$domain'),
      );

  static bool _equalBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static void _expect(http.Response response, int status) {
    if (response.statusCode != status) throw _httpError(response.statusCode);
  }

  static YandexDiskException _bodyTooLarge(int status) => YandexDiskException(
    'Ответ Яндекс Диска превышает допустимый размер 8 МиБ.',
    statusCode: status,
  );

  static YandexDiskException _invalidResponse(int status) =>
      YandexDiskException(
        'Яндекс Диск вернул некорректный ответ.',
        statusCode: status,
      );

  static YandexDiskException _httpError(int status) =>
      YandexDiskException(switch (status) {
        401 => 'Яндекс Диск не принял токен доступа.',
        403 => 'Нет доступа к папке приложения на Яндекс Диске.',
        404 => 'Файл или папка не найдены на Яндекс Диске.',
        409 => 'Файл или папка уже существуют на Яндекс Диске.',
        423 => 'Файл на Яндекс Диске временно заблокирован.',
        429 => 'Слишком много запросов к Яндекс Диску. Повторите позже.',
        >= 500 && <= 599 => 'Яндекс Диск временно недоступен. Повторите позже.',
        _ => 'Не удалось выполнить запрос к Яндекс Диску.',
      }, statusCode: status);
}
