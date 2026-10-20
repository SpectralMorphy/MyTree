import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../room_identity.dart';
import 'room_tabs.dart';

const _recentHostPrefix = 'mytree.room-tabs.v1.recent-host.';
const _recentHostTtl = Duration(seconds: 60);
const _recentHostWriteInterval = Duration(seconds: 5);
final _recentHostWrites = <String, DateTime>{};

/// Tab-scoped discovery optimization only. sessionStorage survives a reload,
/// but never supplies membership, history readiness, or network ownership.
DateTime? recentRoomHostSeen(String roomId) {
  if (!isValidRoomId(roomId)) return null;
  try {
    final encoded = web.window.sessionStorage.getItem(
      '$_recentHostPrefix$roomId',
    );
    if (encoded == null) return null;
    final milliseconds = int.tryParse(encoded);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (milliseconds == null ||
        milliseconds <= 0 ||
        milliseconds > now ||
        now - milliseconds >= _recentHostTtl.inMilliseconds) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  } catch (_) {
    // Optional hints must not turn blocked sessionStorage into a RoomStore error.
    return null;
  }
}

/// Call only after a validated live peer exchange, never joined/discovery alone.
/// Frequent UI notifications do not require synchronous storage on every edit.
void rememberRecentRoomHost(String roomId) {
  if (!isValidRoomId(roomId)) return;
  final now = DateTime.now();
  final previous = _recentHostWrites[roomId];
  if (previous != null) {
    final elapsed = now.difference(previous);
    if (!elapsed.isNegative && elapsed < _recentHostWriteInterval) return;
  }
  try {
    web.window.sessionStorage.setItem(
      '$_recentHostPrefix$roomId',
      now.millisecondsSinceEpoch.toString(),
    );
    _recentHostWrites[roomId] = now;
  } catch (_) {
    // Best effort only; real durable storage failures remain the store's concern.
  }
}

void forgetRecentRoomHost(String roomId) {
  if (!isValidRoomId(roomId)) return;
  _recentHostWrites.remove(roomId);
  try {
    web.window.sessionStorage.removeItem('$_recentHostPrefix$roomId');
  } catch (_) {
    // A stale advisory hint has the same bounded follower-first fallback.
  }
}

@JS('navigator.locks')
external web.LockManager? get _browserLocks;

@JS('BroadcastChannel')
external JSAny? get _broadcastChannelConstructor;

@JS('AbortController')
external JSAny? get _abortControllerConstructor;

extension type _LockMethods(JSObject _) implements JSObject {
  external JSAny? get request;
  external JSAny? get query;
}

/// Unsupported/insecure browsers keep independent conventional sessions. Never
/// pretend that a timer or localStorage lease gives exclusive network ownership.
RoomTabs? createRoomTabs(String roomId, String actorId) {
  if (!isValidRoomId(roomId) || !isValidRoomActor(actorId)) return null;
  try {
    final locks = _browserLocks;
    if (!web.window.isSecureContext ||
        locks == null ||
        !_LockMethods(locks).request.typeofEquals('function') ||
        !_LockMethods(locks).query.typeofEquals('function') ||
        !_broadcastChannelConstructor.typeofEquals('function') ||
        !_abortControllerConstructor.typeofEquals('function')) {
      return null;
    }
    final scope = 'mytree.room-tabs.v1.${jsonEncode([roomId, actorId])}';
    return _WebRoomTabs(
      roomId,
      actorId,
      locks,
      web.BroadcastChannel(scope),
      scope,
    );
  } catch (_) {
    // A blocked BroadcastChannel getter/constructor is also unsupported. Lock
    // request failures after start, unlike capability absence, surface as errors.
    return null;
  }
}

class _WebRoomTabs implements RoomTabs, RoomTabsResync {
  _WebRoomTabs(
    this.roomId,
    this.actorId,
    this._locks,
    this._channel,
    this._lockName,
  );

  static const _maxMessageBytes = 8 * 1024 * 1024;
  final String roomId;
  final String actorId;
  final web.LockManager _locks;
  final web.BroadcastChannel _channel;
  final String _lockName;
  final String _tabId = createRoomId();
  final _roles = StreamController<void>.broadcast();
  final _states = StreamController<RoomTabState>.broadcast();
  final _resyncRequests = StreamController<String>.broadcast();
  final _recentResyncRequests = <String>{};
  final _release = Completer<JSAny?>();
  Future<void>? _starting;
  Completer<bool>? _decision;
  JSFunction? _listener;
  web.AbortController? _queuedAbort;
  bool _disposed = false;
  bool _leader = false;
  int _controlRevision = 0;
  String? _term;
  String? _owner;
  String? _requestId;
  String? _requestTerm;
  String? _pendingResyncId;
  RoomTabState? _latest;

  @override
  bool get isLeader => !_disposed && _leader;

  @override
  Stream<void> get onRoleChanged => _roles.stream;

  @override
  Stream<RoomTabState> get onState => _states.stream;

  @override
  Stream<String> get onResyncRequested => _resyncRequests.stream;

  @override
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (_disposed) return;
    // Register first: an owner can announce or answer during our lock decision.
    final listener = ((web.Event event) {
      if (!_disposed) _receive((event as web.MessageEvent).data);
    }).toJS;
    _listener = listener;
    _channel.addEventListener('message', listener);
    final decision = _decision = Completer<bool>();
    final callback = ((web.Lock? lock) {
      if (lock == null) {
        decision.complete(false);
        return Future<JSAny?>.value(null).toJS;
      }
      return _holdLock(decision).toJS;
    }).toJS;
    _observeLock(
      _locks
          .request(
            _lockName,
            web.LockOptions(mode: 'exclusive', ifAvailable: true),
            callback,
          )
          .toDart,
      decision,
    );
    // The request promise itself resolves only on release. Startup must instead
    // wait for its local role decision, not for the lifetime of the leader.
    final acquired = await decision.future;
    if (_disposed || acquired) return;
    _queuedAbort = web.AbortController();
    _observeLock(
      _locks
          .request(
            _lockName,
            web.LockOptions(mode: 'exclusive', signal: _queuedAbort!.signal),
            ((web.Lock lock) => _holdLock(null).toJS).toJS,
          )
          .toDart,
    );
    requestState();
  }

  void _observeLock(Future<JSAny?> completion, [Completer<bool>? decision]) {
    unawaited(
      completion.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (_disposed) return; // Aborting a disposed follower is expected.
          if (decision != null && !decision.isCompleted) {
            decision.completeError(error, stackTrace);
          } else {
            _roles.addError(error, stackTrace);
          }
        },
      ),
    );
  }

  Future<String?> _heldOwner() async {
    final snapshot = await _locks.query().toDart;
    for (final lock in snapshot.held.toDart) {
      if (lock.name == _lockName && lock.mode == 'exclusive') {
        return lock.clientId;
      }
    }
    return null;
  }

  Future<JSAny?> _holdLock(Completer<bool>? decision) async {
    if (_disposed) {
      if (decision != null && !decision.isCompleted) decision.complete(false);
      return null;
    }
    final term = createRoomId();
    final owner = await _heldOwner();
    if (_disposed) {
      if (decision != null && !decision.isCompleted) decision.complete(false);
      return null;
    }
    if (owner == null || owner.isEmpty) {
      throw StateError('The granted room lock has no observable owner');
    }
    _controlRevision++;
    _term = term;
    _owner = owner;
    _requestId = null;
    _requestTerm = null;
    _latest = null;
    _leader = true;
    _roles.add(null);
    _post('leader', {'term': term, 'owner': owner});
    if (decision != null && !decision.isCompleted) decision.complete(true);
    // Only dispose resolves this promise. The session must retire networking
    // before calling it. No heartbeat, timeout, or steal can create two owners.
    return _release.future;
  }

  @override
  void publish(RoomTabState state) {
    if (!isLeader) return;
    final validated = RoomTabState.fromJson(state.toJson());
    if (validated == null ||
        state.roomId != roomId ||
        state.actorId != actorId ||
        utf8.encode(jsonEncode(state.toJson())).length >
            _maxMessageBytes - 1024) {
      _roles.addError(const FormatException('Invalid or oversized tab state'));
      return;
    }
    _latest = validated;
    // Unsolicited snapshots could outlive their owner. Advertise a change only;
    // followers ask the live, targeted term for the actual checkpoint.
    _post('changed', {'term': _term, 'owner': _owner});
  }

  @override
  void requestState() {
    if (_disposed || _leader || _listener == null) return;
    final request = createRoomId();
    _requestId = request;
    _requestTerm = _term;
    _post(_term == null ? 'discover' : 'request', {
      'from': _tabId,
      'request': request,
      if (_term != null) 'term': _term,
    });
    final pending = _pendingResyncId;
    if (_term != null && _owner != null && pending != null) {
      _post('resync', {'term': _term, 'from': _tabId, 'request': pending});
    }
  }

  @override
  void requestResync(String requestId) {
    if (_disposed || _leader || !isValidRoomId(requestId)) return;
    // Discovery/owner selection may still be in flight. Keep this independent
    // of ordinary state request IDs and retry only with a selected live term.
    _pendingResyncId = requestId;
    requestState();
  }

  void _post(String kind, Map<String, Object?> fields) {
    if (_disposed) return;
    try {
      final encoded = jsonEncode({
        'v': 1,
        'roomId': roomId,
        'actorId': actorId,
        'kind': kind,
        ...fields,
      });
      if (utf8.encode(encoded).length > _maxMessageBytes) {
        throw const FormatException('Oversized tab control message');
      }
      _channel.postMessage(encoded.toJS);
    } catch (error, stackTrace) {
      _roles.addError(error, stackTrace);
    }
  }

  void _receive(JSAny? data) {
    if (data == null || !data.isA<JSString>()) return;
    final encoded = (data as JSString).toDart;
    if (encoded.length > _maxMessageBytes ||
        utf8.encode(encoded).length > _maxMessageBytes) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      return;
    }
    if (decoded is! Map ||
        decoded['v'] != 1 ||
        decoded['v'] is! int ||
        decoded['roomId'] != roomId ||
        decoded['actorId'] != actorId) {
      return;
    }
    final kind = decoded['kind'];
    if (kind == 'resync') {
      final from = decoded['from'];
      final request = decoded['request'];
      if (!isLeader ||
          decoded['term'] != _term ||
          from is! String ||
          !isValidRoomId(from) ||
          request is! String ||
          !isValidRoomId(request) ||
          _recentResyncRequests.contains(request)) {
        return;
      }
      if (_recentResyncRequests.length == 64) {
        _recentResyncRequests.remove(_recentResyncRequests.first);
      }
      _recentResyncRequests.add(request);
      // Cached readiness is not a live proof. The session must perform the
      // exchange and explicitly publish this ID in completedResyncs later.
      _resyncRequests.add(request);
      return;
    }
    if (kind == 'discover' || kind == 'request') {
      final from = decoded['from'];
      final request = decoded['request'];
      if (!isLeader ||
          from is! String ||
          !isValidRoomId(from) ||
          request is! String ||
          !isValidRoomId(request)) {
        return;
      }
      if (kind == 'discover') {
        _post('leader', {
          'term': _term,
          'owner': _owner,
          'to': from,
          'request': request,
        });
      } else if (decoded['term'] == _term && _latest != null) {
        _post('state', {
          'term': _term,
          'owner': _owner,
          'to': from,
          'request': request,
          'state': _latest!.toJson(),
        });
      }
      return;
    }
    if (_leader) return;
    final term = decoded['term'];
    final owner = decoded['owner'];
    if (term is! String ||
        !isValidRoomId(term) ||
        owner is! String ||
        owner.isEmpty ||
        owner.length > 512) {
      return;
    }
    if (kind == 'leader' || kind == 'changed') {
      if (decoded['to'] != null &&
          (decoded['to'] != _tabId ||
              decoded['request'] != _requestId ||
              _requestTerm != null)) {
        return;
      }
      if (term == _term && owner == _owner) {
        requestState();
      } else {
        unawaited(_selectOwner(term, owner));
      }
    } else if (kind == 'bye' && term == _term && owner == _owner) {
      _controlRevision++;
      _term = null;
      _owner = null;
      _requestId = null;
      _requestTerm = null;
      _roles.add(null);
      requestState();
    } else if (kind == 'state' &&
        decoded['to'] == _tabId &&
        decoded['request'] == _requestId &&
        term == _term &&
        term == _requestTerm &&
        owner == _owner) {
      final state = RoomTabState.fromJson(decoded['state']);
      if (state != null && state.roomId == roomId && state.actorId == actorId) {
        unawaited(_deliverState(state, term, owner, _requestId!));
      }
    }
  }

  Future<void> _selectOwner(String term, String owner) async {
    final revision = ++_controlRevision;
    try {
      final heldOwner = await _heldOwner();
      if (_disposed || _leader || revision != _controlRevision) return;
      if (heldOwner != owner) return;
      _term = term;
      _owner = owner;
      _requestId = null;
      _requestTerm = null;
      // Also invalidate a follower's inherited transient readiness on handoff.
      _roles.add(null);
      // A fresh directed request is issued only after selecting the owner. A
      // discovery response itself is never accepted as a ready checkpoint.
      requestState();
    } catch (error, stackTrace) {
      if (!_disposed && revision == _controlRevision) {
        _roles.addError(error, stackTrace);
      }
    }
  }

  Future<void> _deliverState(
    RoomTabState state,
    String term,
    String owner,
    String request,
  ) async {
    try {
      final heldOwner = await _heldOwner();
      if (_disposed ||
          _leader ||
          heldOwner != owner ||
          term != _term ||
          term != _requestTerm ||
          request != _requestId) {
        return;
      }
      _requestId = null;
      _requestTerm = null;
      if (state.completedResyncs.contains(_pendingResyncId)) {
        _pendingResyncId = null;
      }
      _states.add(state);
    } catch (error, stackTrace) {
      if (!_disposed && request == _requestId) {
        _roles.addError(error, stackTrace);
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    // BroadcastChannel preserves sender order: retire this runtime term before
    // releasing ownership, so queued old replies cannot cross a live handoff.
    if (_leader) _post('bye', {'term': _term, 'owner': _owner});
    _disposed = true;
    final decision = _decision;
    if (decision != null && !decision.isCompleted) decision.complete(false);
    _controlRevision++;
    _leader = false;
    _latest = null;
    _requestId = null;
    _requestTerm = null;
    _pendingResyncId = null;
    _recentResyncRequests.clear();
    _queuedAbort?.abort();
    final listener = _listener;
    if (listener != null) _channel.removeEventListener('message', listener);
    _listener = null;
    _channel.close();
    if (!_release.isCompleted) _release.complete(null);
    unawaited(_roles.close());
    unawaited(_states.close());
    unawaited(_resyncRequests.close());
  }
}
