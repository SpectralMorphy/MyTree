import 'dart:async';
import 'dart:math';

import '../room_identity.dart';
import 'mqtt_signaling.dart';
import 'peerjs_signaling.dart';
import 'signaling.dart';

SignalingPeer createSignalingPeer(String id, Map<String, dynamic> config) =>
    FallbackSignalingPeer(
      id: id,
      configuration: config,
      // A random follower ID cannot own the room. Do not delay its already
      // ready fallback while the preferred service is still registering.
      preferenceDelay: isValidRoomId(id)
          ? const Duration(milliseconds: 250)
          : const Duration(seconds: 3),
      channelRaceDelay: const Duration(milliseconds: 250),
      providers: [
        createPeerJsPeer,
        (id, config) => MqttSignalingPeer(
          id: id,
          config: config,
          ephemeralIdentity: isValidRoomId(id),
        ),
      ],
    );

/// Registers the same identity with independent services, not isolated rooms.
/// The standby is discoverable even while PeerJS works, so a newcomer whose
/// PeerJS is blocked can still find an existing participant via MQTT.
class FallbackSignalingPeer implements SignalingPeer, SignalingDiscovery {
  FallbackSignalingPeer({
    required this.id,
    required this.configuration,
    required List<SignalingPeerFactory> providers,
    this.preferenceDelay = const Duration(seconds: 3),
    Duration? channelRaceDelay,
  }) : channelRaceDelay = channelRaceDelay ?? preferenceDelay,
       _factories = List.unmodifiable(providers) {
    if (providers.isEmpty) {
      throw ArgumentError('At least one provider is required');
    }
  }

  @override
  final String id;
  final Map<String, dynamic> configuration;
  final List<SignalingPeerFactory> _factories;
  final Duration preferenceDelay;
  final Duration channelRaceDelay;
  final _backends = <_Backend>[];
  final _pending = <_FallbackChannel>{};
  final _channels = <_FallbackChannel>{};
  final _openEvents = StreamController<String?>.broadcast(sync: true);
  final _incoming = StreamController<RoomChannel>.broadcast(sync: true);
  final _errors = StreamController<SignalingFailure>.broadcast(sync: true);
  final _disconnects = StreamController<void>.broadcast(sync: true);
  final _closes = StreamController<void>.broadcast(sync: true);
  final _discoveryChanges = StreamController<void>.broadcast();
  final _retryJitter = Random();
  static const _maxRegistrationRetries = 2;
  bool _recoveryStopped = false;
  bool _started = false;
  bool _disposed = false;
  bool _announced = false;
  bool _conflict = false;
  Timer? _preferenceTimer;

  @override
  String get service =>
      _backends.where((b) => b.ready).map((b) => b.peer!.service).join(' / ');
  @override
  bool get open => !_disposed && !_conflict && _backends.any((b) => b.ready);
  @override
  bool get disconnected => !open;
  @override
  Stream<String?> get onOpen => _openEvents.stream;
  @override
  Stream<RoomChannel> get onConnection => _incoming.stream;
  @override
  Stream<SignalingFailure> get onError => _errors.stream;
  @override
  Stream<void> get onDisconnected => _disconnects.stream;
  @override
  Stream<void> get onClose => _closes.stream;
  @override
  bool get discoveryComplete =>
      _started &&
      !_disposed &&
      !_conflict &&
      _backends.length == _factories.length &&
      _backends.every((b) => b.peer?.id == id && b.discoveryComplete);
  @override
  Stream<void> get onDiscoveryChanged => _discoveryChanges.stream;

  @override
  void start() {
    if (_started || _disposed) return;
    _started = true;
    for (var index = 0; index < _factories.length; index++) {
      _backends.add(_Backend(index));
    }
    _discoveryChanges.add(null);
    for (final backend in _backends) {
      _startBackend(backend);
    }
  }

  bool _current(_Backend backend, int epoch) =>
      !_disposed && !_conflict && !backend.failed && backend.epoch == epoch;

  void _startBackend(_Backend backend) {
    if (_disposed || _conflict) return;
    final epoch = ++backend.epoch;
    backend.failed = false;
    backend.ready = false;
    if (backend.retries > 0) _discoveryChanges.add(null);
    // MQTT startup includes connect (8s), parallel SUBACKs (4s), then
    // probe/claim (up to 1.5s). Do not abort its valid stages at 7 seconds.
    backend.deadline = Timer(
      Duration(seconds: backend.index == 0 ? 3 : 14),
      () {
        if (!backend.ready) {
          _failed(
            backend,
            epoch,
            const SignalingFailure(
              SignalingFailureKind.unavailable,
              'Signaling registration timed out',
            ),
          );
        }
      },
    );
    runZonedGuarded(
      () {
        final peer = _factories[backend.index](id, configuration);
        backend.peer = peer;
        backend.subscriptions.addAll([
          peer.onOpen.listen((registeredId) {
            if (!_current(backend, epoch)) return;
            if (registeredId != id || peer.id != id) {
              _failed(
                backend,
                epoch,
                const SignalingFailure(
                  SignalingFailureKind.unavailable,
                  'Unexpected signaling identity',
                ),
              );
              return;
            }
            final wasReady = backend.ready;
            backend.ready = true;
            backend.registered = true;
            backend.deadline?.cancel();
            if (!wasReady) _discoveryChanges.add(null);
            if (backend.index == 0 || _backends.first.failed) {
              _announce();
            } else {
              _preferenceTimer ??= Timer(preferenceDelay, _announce);
            }
            for (final failed in _backends) {
              _scheduleRecovery(failed);
            }
            for (final channel in _pending.toList()) {
              channel.providerReady();
            }
          }),
          peer.onConnection.listen((channel) {
            if (!_current(backend, epoch) || !open || !backend.ready) {
              scheduleMicrotask(channel.dispose);
            } else {
              _incoming.add(channel);
            }
          }),
          peer.onError.listen((error) {
            if (!_current(backend, epoch)) return;
            if (error.kind == SignalingFailureKind.remoteUnavailable) {
              for (final channel in _pending.toList()) {
                channel.providerFailed(backend, error);
              }
            } else {
              _failed(backend, epoch, error);
            }
          }),
          peer.onDisconnected.listen(
            (_) => _failed(
              backend,
              epoch,
              SignalingFailure(
                SignalingFailureKind.unavailable,
                '${peer.service} disconnected',
              ),
            ),
          ),
          peer.onClose.listen(
            (_) => _failed(
              backend,
              epoch,
              SignalingFailure(
                SignalingFailureKind.unavailable,
                '${peer.service} closed',
              ),
            ),
          ),
        ]);
        if (peer is SignalingDiscovery) {
          final discovery = peer as SignalingDiscovery;
          backend.subscriptions.add(
            discovery.onDiscoveryChanged.listen((_) {
              if (!_current(backend, epoch)) return;
              _discoveryChanges.add(null);
            }),
          );
        }
        peer.start();
      },
      (error, stack) => _failed(
        backend,
        epoch,
        error is SignalingFailure
            ? error
            : SignalingFailure(SignalingFailureKind.unavailable, '$error'),
      ),
    );
  }

  void _scheduleRecovery(_Backend backend) {
    // Recover cold registration only. Once registered, the provider may own an
    // established outgoing or incoming RTC channel; disposing it would break
    // that channel. Keep such peers until owner disposal, without replacement
    // (retaining an old peer beside a retry also risks stale ID occupancy).
    if (_recoveryStopped ||
        !open ||
        !backend.failed ||
        backend.registered ||
        backend.retries >= _maxRegistrationRetries ||
        backend.retryTimer != null) {
      return;
    }
    final epoch = backend.epoch;
    final delay = Duration(
      milliseconds: (500 << backend.retries) + _retryJitter.nextInt(251),
    );
    backend.retryTimer = Timer(delay, () {
      backend.retryTimer = null;
      if (_recoveryStopped || !open || backend.epoch != epoch) return;
      backend.retries++;
      _startBackend(backend);
    });
  }

  void _stopRecovery() {
    _recoveryStopped = true;
    for (final backend in _backends) {
      backend.retryTimer?.cancel();
      backend.retryTimer = null;
      if (backend.retries > 0 && !backend.registered && !backend.failed) {
        backend.failed = true;
        _releaseBackend(backend);
      }
    }
  }

  void _releaseBackend(_Backend backend) {
    backend.deadline?.cancel();
    for (final subscription in backend.subscriptions) {
      unawaited(subscription.cancel());
    }
    backend.subscriptions.clear();
    final peer = backend.peer;
    backend.peer = null;
    // Never dispose a peer from inside one of its synchronous event callbacks.
    if (peer != null) scheduleMicrotask(peer.dispose);
  }

  void _announce() {
    if (_disposed || _conflict || _announced || !open) return;
    _announced = true;
    _preferenceTimer?.cancel();
    _openEvents.add(id);
  }

  void _failed(_Backend backend, int epoch, SignalingFailure error) {
    if (!_current(backend, epoch)) return;
    backend.deadline?.cancel();
    // Contention is NOT an outage. Falling back on ID-taken creates a second
    // host in another namespace and bypasses the room's election policy.
    if (error.kind == SignalingFailureKind.idTaken) {
      _conflict = true;
      _stopRecovery();
      _preferenceTimer?.cancel();
      for (final provider in _backends) {
        provider.deadline?.cancel();
      }
      for (final channel in _pending) {
        channel._raceTimer?.cancel();
      }
      _discoveryChanges.add(null);
      _errors.add(error);
      return;
    }
    backend.failed = true;
    backend.ready = false;
    if (!backend.registered) _releaseBackend(backend);
    _discoveryChanges.add(null);
    for (final channel in _pending.toList()) {
      channel.providerFailed(backend, error);
    }
    if (open) {
      _announce();
      _scheduleRecovery(backend);
    } else if (_announced) {
      // Session owns whole-peer reconnects. Do not race its fresh instance with
      // retries from this now-disconnected wrapper.
      _stopRecovery();
      _announced = false;
      _disconnects.add(null);
    } else if (_backends.every((b) => b.failed)) {
      _stopRecovery();
      _errors.add(error);
    }
  }

  @override
  RoomChannel connect(String peer) {
    if (!open) throw StateError('Signaling is not ready');
    final channel = _FallbackChannel(this, peer);
    _pending.add(channel);
    _channels.add(channel);
    scheduleMicrotask(channel.providerReady);
    return channel;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopRecovery();
    _discoveryChanges.add(null);
    _preferenceTimer?.cancel();
    for (final channel in _channels.toList()) {
      channel.dispose();
    }
    _channels.clear();
    _pending.clear();
    for (final backend in _backends) {
      _releaseBackend(backend);
    }
    scheduleMicrotask(() {
      unawaited(_openEvents.close());
      unawaited(_incoming.close());
      unawaited(_errors.close());
      unawaited(_disconnects.close());
      unawaited(_closes.close());
      unawaited(_discoveryChanges.close());
    });
  }
}

class _Backend {
  _Backend(this.index);
  final int index;
  SignalingPeer? peer;
  Timer? deadline;
  Timer? retryTimer;
  int epoch = 0;
  int retries = 0;
  bool ready = false;
  bool failed = false;
  bool registered = false;
  final subscriptions = <StreamSubscription<dynamic>>[];

  bool get discoveryComplete {
    final provider = peer;
    if (!ready || failed || provider == null) return false;
    return provider is SignalingDiscovery
        ? (provider as SignalingDiscovery).discoveryComplete
        : provider.open && !provider.disconnected;
  }
}

/// A connecting channel races another signaling path after a short delay.
/// Once open, it stays bound to one DataChannel; no history is sent twice and
/// established channels aren't torn down merely because signaling failed.
class _FallbackChannel implements RoomChannel {
  _FallbackChannel(this.owner, this.peer);
  final FallbackSignalingPeer owner;
  @override
  final String peer;
  final _attempts = <_Backend, RoomChannel>{};
  // A cold registration retry reuses its backend, but not its failed epoch.
  final _failedAttempts = <_Backend, int>{};
  bool _failureEmitted = false;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _openEvents = StreamController<void>.broadcast(sync: true);
  final _data = StreamController<Object?>.broadcast(sync: true);
  final _errors = StreamController<Object>.broadcast(sync: true);
  final _closeEvents = StreamController<void>.broadcast(sync: true);
  final _health = StreamController<ChannelConnectivity>.broadcast(sync: true);
  RoomChannel? _winner;
  Timer? _raceTimer;
  bool _disposed = false;
  bool _race = false;

  @override
  String get service => _winner?.service ?? 'PeerJS / MQTT';
  @override
  bool get open => !_disposed && _winner?.open == true;
  @override
  bool get disposed => _disposed;
  @override
  ChannelConnectivity get connectivity =>
      _winner?.connectivity ?? ChannelConnectivity.connecting;
  @override
  Stream<void> get onOpen => _openEvents.stream;
  @override
  Stream<Object?> get onData => _data.stream;
  @override
  Stream<Object> get onError => _errors.stream;
  @override
  Stream<void> get onClose => _closeEvents.stream;
  @override
  Stream<ChannelConnectivity> get onConnectivity => _health.stream;

  void providerReady() {
    if (_disposed ||
        _failureEmitted ||
        _winner != null ||
        owner._disposed ||
        owner._conflict) {
      return;
    }
    final available = owner._backends
        .where((b) => b.ready && !b.failed)
        .toList();
    if (available.isEmpty) return;
    if (_attempts.isEmpty) _attempt(available.first);
    if (_race) {
      for (final backend in available) {
        _attempt(backend);
      }
    } else {
      _raceTimer ??= Timer(owner.channelRaceDelay, () {
        _race = true;
        providerReady();
      });
    }
  }

  void _attempt(_Backend backend) {
    if (_attempts.containsKey(backend) ||
        _failedAttempts[backend] == backend.epoch ||
        _disposed ||
        _winner != null) {
      return;
    }
    try {
      final channel = backend.peer!.connect(peer);
      _attempts[backend] = channel;
      _subscriptions.addAll([
        channel.onOpen.listen((_) => _opened(channel)),
        channel.onData.listen((data) {
          if (!_disposed && identical(channel, _winner)) _data.add(data);
        }),
        channel.onError.listen(
          (error) => _attemptFailed(backend, channel, error),
        ),
        channel.onClose.listen((_) {
          if (!_disposed && identical(channel, _winner)) {
            _closeEvents.add(null);
          } else {
            _attemptFailed(
              backend,
              channel,
              StateError('Channel closed before opening'),
            );
          }
        }),
        channel.onConnectivity.listen((state) {
          if (!_disposed && identical(channel, _winner)) {
            _health.add(state);
          } else if (state == ChannelConnectivity.failed ||
              state == ChannelConnectivity.closed) {
            _attemptFailed(
              backend,
              channel,
              StateError('Channel negotiation failed'),
            );
          }
        }),
      ]);
      if (channel.open) scheduleMicrotask(() => _opened(channel));
    } catch (error) {
      _failedAttempts[backend] = backend.epoch;
      _race = true;
      providerReady();
      _reportExhausted(error);
    }
  }

  void _opened(RoomChannel channel) {
    if (_disposed) return;
    if (_failureEmitted || (owner._conflict && _winner == null)) {
      scheduleMicrotask(channel.dispose);
      return;
    }
    final valid = _attempts.entries.any(
      (entry) =>
          identical(entry.value, channel) &&
          _failedAttempts[entry.key] != entry.key.epoch,
    );
    if (!valid || channel.disposed) {
      scheduleMicrotask(channel.dispose);
      return;
    }
    if (_winner != null) {
      if (!identical(_winner, channel)) scheduleMicrotask(channel.dispose);
      return;
    }
    _winner = channel;
    _raceTimer?.cancel();
    owner._pending.remove(this);
    for (final other in _attempts.values) {
      if (!identical(other, channel)) scheduleMicrotask(other.dispose);
    }
    _openEvents.add(null);
  }

  void _attemptFailed(_Backend backend, RoomChannel channel, Object error) {
    if (_disposed) return;
    if (identical(channel, _winner)) {
      _errors.add(error);
      return;
    }
    if (_winner != null || _failedAttempts[backend] == backend.epoch) return;
    _failedAttempts[backend] = backend.epoch;
    scheduleMicrotask(channel.dispose);
    _race = true;
    providerReady();
    _reportExhausted(error);
  }

  void _reportExhausted(Object error) {
    if (_disposed || _winner != null || _failureEmitted) return;
    if (owner._backends.every(
      (b) => b.failed || _failedAttempts[b] == b.epoch,
    )) {
      _failureEmitted = true;
      _errors.add(error);
    }
  }

  void providerFailed(_Backend backend, Object error) {
    final channel = _attempts[backend];
    if (channel != null) {
      _attemptFailed(backend, channel, error);
    } else {
      _failedAttempts[backend] = backend.epoch;
      _race = true;
      providerReady();
      _reportExhausted(error);
    }
  }

  @override
  Future<void> send(Map<String, dynamic> data) {
    final channel = _winner;
    if (!open || channel == null) {
      return Future.error(StateError('Channel is not open'));
    }
    return channel.send(data);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    owner._pending.remove(this);
    owner._channels.remove(this);
    _raceTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    for (final channel in _attempts.values) {
      scheduleMicrotask(channel.dispose);
    }
    scheduleMicrotask(() {
      unawaited(_openEvents.close());
      unawaited(_data.close());
      unawaited(_errors.close());
      unawaited(_closeEvents.close());
      unawaited(_health.close());
    });
  }
}
