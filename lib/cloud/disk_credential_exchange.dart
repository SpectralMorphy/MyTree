import 'dart:async';

import '../signaling/signaling.dart';

/// Editor-only credential rendezvous, independent of the room's host topology.
///
/// The caller enables only the joined, leader tab with a durable explicit editor
/// role, supplies durable editor identities, and reports credential-save errors
/// in [onCredentials]. Actor/alias checks assume trusted family clients; they are
/// not cryptographic authentication. Only [RoomChannel] carries credentials.
class DiskCredentialExchange {
  DiskCredentialExchange({
    required this.roomId,
    required this.actorId,
    required this.peerFactory,
    required this.rtcConfiguration,
    required this.isEditor,
    required this.onCredentials,
    required this.readCredentials,
    required this.activeBindingId,
  });

  final String roomId;
  final String actorId;
  final SignalingPeerFactory peerFactory;
  final Map<String, dynamic> rtcConfiguration;
  final bool Function(String actor) isEditor;
  final Future<void> Function(String bindingId, String token) onCredentials;
  final Map<String, dynamic>? Function() readCredentials;
  final String? Function() activeBindingId;

  static const _retryInterval = Duration(seconds: 20);
  static const _handshakeTimeout = Duration(seconds: 8);

  final _peerSubscriptions = <StreamSubscription<dynamic>>[];
  final _channels = <String, _CredentialChannel>{};
  final _attemptedActors = <String>{};
  Set<String> _editors = {};
  SignalingPeer? _peer;
  Timer? _retryTimer;
  bool _enabled = false;
  bool _disposed = false;
  int _generation = 0;

  String _alias(String actor) => 'mytree-disk-$roomId-$actor';
  bool get _allowed => !_disposed && _enabled && isEditor(actorId);
  bool _knownEditor(String actor) =>
      _editors.contains(actor) && isEditor(actor);

  /// Safe to call after every room/storage change, including a token rotation.
  /// Unchanged updates neither register a new peer nor repeat dial attempts.
  void update({required bool enabled, required Iterable<String> editorActors}) {
    if (_disposed) return;
    final editors = {
      for (final actor in editorActors)
        if (actor != actorId && isEditor(actor)) actor,
    };
    final wasEnabled = _enabled;
    _enabled = enabled && isEditor(actorId);
    _editors = editors;
    if (!_enabled) {
      _retryTimer?.cancel();
      _retryTimer = null;
      if (wasEnabled) _stopPeer();
      return;
    }
    for (final channel in _channels.values.toList()) {
      if (!_knownEditor(channel.actor)) _closeChannel(channel);
    }
    _attemptedActors.removeWhere((actor) => !_knownEditor(actor));
    if (!wasEnabled) {
      _retryTimer = Timer.periodic(_retryInterval, (_) => _retry());
      _startPeer();
    } else {
      _connectMissing();
    }
    _publish();
  }

  void _retry() {
    if (!_allowed) {
      _enabled = false;
      _retryTimer?.cancel();
      _retryTimer = null;
      _stopPeer();
      return;
    }
    for (final channel in _channels.values.toList()) {
      if (!_current(channel) || channel.channel.disposed) {
        _closeChannel(channel);
      }
    }
    if (_peer == null || !_peer!.open || _peer!.disconnected) {
      _stopPeer();
      _startPeer();
    } else {
      _attemptedActors.clear();
      _connectMissing();
    }
    _publish();
  }

  bool _currentPeer(SignalingPeer peer, int generation) =>
      _allowed && _generation == generation && identical(_peer, peer);

  void _startPeer() {
    if (!_allowed || _peer != null) return;
    final generation = _generation;
    try {
      final peer = peerFactory(_alias(actorId), rtcConfiguration);
      _peer = peer;
      _peerSubscriptions.addAll([
        peer.onOpen.listen((id) {
          if (!_currentPeer(peer, generation)) return;
          if (id != _alias(actorId) || peer.id != _alias(actorId)) {
            _stopPeer();
            return;
          }
          _connectMissing();
        }),
        peer.onConnection.listen((channel) {
          if (!_currentPeer(peer, generation)) {
            channel.dispose();
            return;
          }
          // Resolve against exact known aliases, never an actor in the payload.
          for (final actor in _editors) {
            if (channel.peer == _alias(actor) && actor.compareTo(actorId) < 0) {
              _attach(channel, actor, generation);
              return;
            }
          }
          channel.dispose();
        }),
        peer.onError.listen((error) {
          if (!_currentPeer(peer, generation)) return;
          if (error.kind == SignalingFailureKind.idTaken ||
              error.kind == SignalingFailureKind.unavailable) {
            // A same-origin follower must not invent an alternative identity.
            // Wait for the normal retry tick (or the parent's leader update).
            _stopPeer();
          }
        }),
        peer.onDisconnected.listen((_) {
          if (_currentPeer(peer, generation)) _stopPeer();
        }),
        peer.onClose.listen((_) {
          if (_currentPeer(peer, generation)) _stopPeer();
        }),
      ]);
      peer.start();
      if (_currentPeer(peer, generation) && peer.open) _connectMissing();
    } catch (_) {
      // Transport exceptions can contain provider payloads. Never retain them.
      _stopPeer();
    }
  }

  void _connectMissing() {
    final peer = _peer;
    if (!_allowed || peer == null || !peer.open || peer.disconnected) return;
    final generation = _generation;
    for (final actor in _editors.toList()) {
      if (!_currentPeer(peer, generation)) return;
      if (!_knownEditor(actor) ||
          actorId.compareTo(actor) >= 0 ||
          _channels.containsKey(actor) ||
          !_attemptedActors.add(actor)) {
        continue;
      }
      try {
        final channel = peer.connect(_alias(actor));
        if (_currentPeer(peer, generation)) {
          _attach(channel, actor, generation);
        } else {
          channel.dispose();
        }
      } catch (_) {
        // Retry on the timer, not on every room notification.
      }
    }
  }

  void _attach(RoomChannel channel, String actor, int generation) {
    final existing = _channels[actor];
    if (existing != null && identical(existing.channel, channel)) return;
    if (!_allowed ||
        _generation != generation ||
        !_knownEditor(actor) ||
        channel.peer != _alias(actor) ||
        channel.disposed ||
        existing != null) {
      channel.dispose();
      return;
    }
    final state = _CredentialChannel(channel, actor, generation);
    _channels[actor] = state;
    state.deadline = Timer(_handshakeTimeout, () => _closeChannel(state));
    state.subscriptions.addAll([
      channel.onOpen.listen((_) => _openChannel(state)),
      channel.onData.listen(
        (data) => _receive(state, data),
        onError: (Object _) => _closeChannel(state),
      ),
      channel.onError.listen((_) => _closeChannel(state)),
      channel.onClose.listen((_) => _closeChannel(state)),
      channel.onConnectivity.listen((status) {
        if (status == ChannelConnectivity.failed ||
            status == ChannelConnectivity.closed ||
            status == ChannelConnectivity.disconnected) {
          _closeChannel(state);
        }
      }),
    ]);
    if (channel.open) _openChannel(state);
  }

  bool _current(_CredentialChannel state) =>
      _allowed &&
      state.generation == _generation &&
      identical(_channels[state.actor], state) &&
      _knownEditor(state.actor) &&
      state.channel.peer == _alias(state.actor);

  bool _live(_CredentialChannel state) =>
      _current(state) && state.channel.open && !state.channel.disposed;

  Future<void> _openChannel(_CredentialChannel state) async {
    if (!_live(state) || state.helloStarted) return;
    state.helloStarted = true;
    try {
      await state.channel.send({
        'v': 1,
        'roomId': roomId,
        'actor': actorId,
        'type': 'diskHello',
      });
      if (!_live(state)) return;
      state.helloSent = true;
      _handshakeReady(state);
    } catch (_) {
      _closeChannel(state);
    }
  }

  void _handshakeReady(_CredentialChannel state) {
    if (!_live(state) || !state.helloReceived || !state.helloSent) return;
    state.deadline?.cancel();
    state.deadline = null;
    _sendCredentials(state);
  }

  void _receive(_CredentialChannel state, Object? data) {
    if (!_live(state)) return;
    if (data is! Map ||
        data['v'] is! int ||
        data['v'] != 1 ||
        data['roomId'] != roomId ||
        data['actor'] != state.actor) {
      _closeChannel(state);
      return;
    }
    if (data['type'] == 'diskHello' && data.length == 4) {
      state.helloReceived = true;
      _handshakeReady(state);
      return;
    }
    if (data['type'] != 'diskAccess' ||
        data.length != 6 ||
        !state.helloReceived ||
        !state.helloStarted ||
        data['bindingId'] is! String ||
        (data['bindingId'] as String).isEmpty ||
        !_validToken(data['token'])) {
      _closeChannel(state);
      return;
    }
    final bindingId = data['bindingId'] as String;
    if (bindingId != activeBindingId()) return;
    unawaited(_accept(state, bindingId, data['token'] as String));
  }

  Future<void> _accept(
    _CredentialChannel state,
    String bindingId,
    String token,
  ) async {
    if (!_live(state) || bindingId != activeBindingId()) return;
    final saved = readCredentials();
    if (saved?['bindingId'] == bindingId && saved?['token'] == token) return;
    try {
      // The caller owns persistence/error UI and must also guard its own awaits
      // against a binding change. No transport acknowledgement promises a save.
      await onCredentials(bindingId, token);
      if (_live(state) && bindingId == activeBindingId()) _publish();
    } catch (_) {
      // Do not cache a failed save, acknowledge it, or log a secret-bearing error.
      _closeChannel(state);
    }
  }

  static bool _validToken(Object? token) =>
      token is String &&
      token.isNotEmpty &&
      token.length <= 4096 &&
      !token.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e);

  void _publish() {
    for (final state in _channels.values.toList()) {
      _sendCredentials(state);
    }
  }

  Future<void> _sendCredentials(_CredentialChannel state) async {
    if (!_live(state) || !state.helloReceived || !state.helloSent) return;
    final bindingId = activeBindingId();
    final saved = readCredentials();
    final token = saved?['token'];
    if (bindingId == null ||
        bindingId.isEmpty ||
        saved?['bindingId'] != bindingId ||
        !_validToken(token)) {
      return;
    }
    final credentials = (bindingId, token as String);
    if (!_live(state) ||
        bindingId != activeBindingId() ||
        !state.sentCredentials.add(credentials)) {
      return;
    }
    // Mark before send: synchronous callbacks and frequent updates cannot echo
    // this secret repeatedly. Failure closes the channel; a retry starts fresh.
    try {
      await state.channel.send({
        'v': 1,
        'roomId': roomId,
        'actor': actorId,
        'type': 'diskAccess',
        'bindingId': bindingId,
        'token': token,
      });
    } catch (_) {
      _closeChannel(state);
    }
  }

  void _closeChannel(_CredentialChannel state) {
    if (identical(_channels[state.actor], state)) _channels.remove(state.actor);
    state.deadline?.cancel();
    state.deadline = null;
    state.sentCredentials.clear();
    for (final subscription in state.subscriptions) {
      unawaited(subscription.cancel());
    }
    state.subscriptions.clear();
    state.channel.dispose();
  }

  void _stopPeer() {
    _generation++;
    final peer = _peer;
    _peer = null;
    for (final subscription in _peerSubscriptions) {
      unawaited(subscription.cancel());
    }
    _peerSubscriptions.clear();
    for (final state in _channels.values.toList()) {
      _closeChannel(state);
    }
    _attemptedActors.clear();
    peer?.dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _enabled = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _stopPeer();
    _editors.clear();
  }
}

class _CredentialChannel {
  _CredentialChannel(this.channel, this.actor, this.generation);

  final RoomChannel channel;
  final String actor;
  final int generation;
  final subscriptions = <StreamSubscription<dynamic>>[];
  Timer? deadline;
  bool helloStarted = false;
  bool helloSent = false;
  bool helloReceived = false;
  final sentCredentials = <(String, String)>{};
}
