import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:peer_rtc/peer_rtc.dart';

import 'signaling.dart';

SignalingPeer createPeerJsPeer(String id, Map<String, dynamic> configuration) =>
    PeerJsSignalingPeer(
      Peer(
        id: id,
        // The package can otherwise open another socket on an attempt timeout
        // without retiring the first. The owner schedules subsequent attempts.
        options: PeerOptions(
          autoReconnect: false,
          maxRetries: 1,
          config: configuration,
        ),
      ),
    );

/// The only boundary which knows PeerJS options, error strings and RTC objects.
/// Wrapping an existing Peer also keeps network-free test doubles useful.
class PeerJsSignalingPeer
    implements SignalingPeer, SignalingDiscovery, SignalingRecovery {
  PeerJsSignalingPeer(this._peer) : _id = _peer.id ?? '';
  final Peer _peer;
  // peer_rtc clears Peer.id on disconnect. The logical identity must not change.
  final String _id;
  final _channels = <DataConnection, PeerJsRoomChannel>{};
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _opens = StreamController<String?>.broadcast(sync: true);
  final _disconnects = StreamController<void>.broadcast(sync: true);
  final _errors = StreamController<SignalingFailure>.broadcast(sync: true);
  final _discoveryChanges = StreamController<void>.broadcast();
  bool _started = false;
  bool _disposed = false;
  bool _ready = false;
  bool _conflict = false;
  bool _recovering = false;
  String? _registeredId;
  int _registrationEpoch = 0;

  @override
  String get id => _id;
  @override
  String get service => 'PeerJS';
  @override
  bool get open => !_disposed && _ready && _peer.open && !_peer.disconnected;
  @override
  bool get disconnected => !open;
  @override
  Stream<String?> get onOpen => _opens.stream;
  @override
  Stream<RoomChannel> get onConnection => _peer.onConnection.map(_wrap);
  @override
  Stream<SignalingFailure> get onError => _errors.stream;
  @override
  Stream<void> get onDisconnected => _disconnects.stream;
  @override
  Stream<void> get onClose => _peer.onClose.map((_) {});
  @override
  bool get discoveryComplete => open && _registeredId == id;
  @override
  Stream<void> get onDiscoveryChanged => _discoveryChanges.stream;

  void _registered(String? registeredId) {
    if (_disposed || _conflict) return;
    if (registeredId == null || registeredId.isEmpty || registeredId != id) {
      _invalidateRegistration();
      _errors.add(
        const SignalingFailure(
          SignalingFailureKind.unavailable,
          'Unexpected signaling identity',
        ),
      );
      return;
    }
    _registrationEpoch++;
    final changed = !_ready || _registeredId != registeredId;
    _registeredId = registeredId;
    _recovering = false;
    _ready = true;
    if (changed) _discoveryChanges.add(null);
    _opens.add(registeredId);
  }

  void _invalidateRegistration() {
    if (_disposed) return;
    _registrationEpoch++;
    _ready = false;
    _discoveryChanges.add(null);
  }

  void _disconnected() {
    if (_disposed) return;
    _invalidateRegistration();
    _disconnects.add(null);
  }

  @override
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _discoveryChanges.add(null);
    _subscriptions.addAll([
      _peer.onOpen.listen(_registered),
      _peer.onReconnected.listen((_) => _registered(_peer.id)),
      _peer.onDisconnected.listen((_) => _disconnected()),
      _peer.onReconnecting.listen((_) {
        // The owner's request starts the package's bounded attempt. Its
        // progress events are not new outages that should fail this attempt.
        if (_recovering) {
          _invalidateRegistration();
        } else {
          _disconnected();
        }
      }),
      _peer.on<void>('reconnectFailed').listen((_) => _recovering = false),
      _peer.onClose.listen((_) => _invalidateRegistration()),
      _peer.onError.listen((error) {
        if (_disposed) return;
        final kind = '$error' == 'ID $id is taken'
            ? SignalingFailureKind.idTaken
            : '$error'.startsWith('Could not connect to peer ')
            ? SignalingFailureKind.remoteUnavailable
            : SignalingFailureKind.unavailable;
        if (kind == SignalingFailureKind.idTaken) {
          _conflict = true;
          _recovering = false;
          // The package emits reconnectCancelled on the same synchronous event
          // controller. Never cancel from inside its current error callback.
          scheduleMicrotask(() {
            if (!_disposed) _peer.cancelReconnect();
          });
        }
        if (kind != SignalingFailureKind.remoteUnavailable) {
          _invalidateRegistration();
        }
        _errors.add(SignalingFailure(kind, '$error'));
      }),
    ]);
    if (_peer.open && !_peer.disconnected) {
      final epoch = _registrationEpoch;
      scheduleMicrotask(() {
        // A newer failure/reconnect/close must win over this queued replay,
        // even when the package's connection getters haven't caught up yet.
        if (_disposed || epoch != _registrationEpoch) return;
        if (_peer.open && !_peer.disconnected) _registered(_peer.id);
      });
    }
  }

  @override
  void reconnect() {
    if (!_started ||
        _disposed ||
        _conflict ||
        _recovering ||
        open ||
        _registeredId != id ||
        _peer.destroyed) {
      return;
    }
    // Do not alter options of externally supplied peers. Their own automatic
    // retries/multiple socket attempts cannot provide this narrow guarantee.
    if (_peer.options.autoReconnect || _peer.options.maxRetries != 1) return;
    _registrationEpoch++;
    _recovering = true;
    try {
      // Never call before a confirmed registration: otherwise the locked package
      // retrieves a new random ID instead of recovering the supplied identity.
      if (!_peer.tryReconnect()) _recovering = false;
    } catch (_) {
      _recovering = false;
      _invalidateRegistration();
      _errors.add(
        const SignalingFailure(
          SignalingFailureKind.unavailable,
          'PeerJS signaling recovery failed.',
        ),
      );
    }
  }

  PeerJsRoomChannel _wrap(DataConnection connection) =>
      _channels.putIfAbsent(connection, () => PeerJsRoomChannel(connection));

  @override
  RoomChannel connect(String peer) =>
      _wrap(_peer.connect(peer, options: PeerConnectOption(reliable: true)));

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _discoveryChanges.add(null);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    scheduleMicrotask(() {
      unawaited(_opens.close());
      unawaited(_disconnects.close());
      unawaited(_errors.close());
      unawaited(_discoveryChanges.close());
    });
    _peer.cancelReconnect();
    for (final channel in _channels.values) {
      if (!channel.disposed) channel.dispose();
    }
    _channels.clear();
    _peer.dispose();
  }
}

class PeerJsRoomChannel implements RoomChannel {
  PeerJsRoomChannel(this._connection);
  final DataConnection _connection;

  @override
  String get peer => _connection.peer;
  @override
  String get service => 'PeerJS';
  @override
  bool get open => _connection.open;
  @override
  bool get disposed => _connection.disposed;
  @override
  ChannelConnectivity get connectivity {
    if (disposed) return ChannelConnectivity.closed;
    final pc = _connection.peerConnection;
    if (pc?.connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      return ChannelConnectivity.failed;
    }
    if (pc?.connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      return ChannelConnectivity.closed;
    }
    return _ice(pc?.iceConnectionState) ??
        (open ? ChannelConnectivity.connected : ChannelConnectivity.connecting);
  }

  static ChannelConnectivity? _ice(Object? state) => switch (state) {
    RTCIceConnectionState.RTCIceConnectionStateConnected ||
    RTCIceConnectionState.RTCIceConnectionStateCompleted =>
      ChannelConnectivity.connected,
    RTCIceConnectionState.RTCIceConnectionStateDisconnected =>
      ChannelConnectivity.disconnected,
    RTCIceConnectionState.RTCIceConnectionStateFailed =>
      ChannelConnectivity.failed,
    RTCIceConnectionState.RTCIceConnectionStateClosed =>
      ChannelConnectivity.closed,
    RTCIceConnectionState.RTCIceConnectionStateChecking ||
    RTCIceConnectionState.RTCIceConnectionStateNew =>
      ChannelConnectivity.connecting,
    _ => null,
  };

  @override
  Stream<void> get onOpen => _connection.onOpen.map((_) {});
  @override
  Stream<Object?> get onData => _connection.onData;
  @override
  Stream<Object> get onError => _connection.onError.cast<Object>();
  @override
  Stream<void> get onClose => _connection.onClose.map((_) {});
  @override
  Stream<ChannelConnectivity> get onConnectivity => _connection
      .onIceStateChanged
      .map(_ice)
      .where((state) => state != null)
      .cast<ChannelConnectivity>();
  @override
  Future<void> send(Map<String, dynamic> data) => _connection.send(data);
  @override
  void dispose() => _connection.dispose();
}
