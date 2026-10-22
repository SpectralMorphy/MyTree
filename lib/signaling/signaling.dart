import 'dart:async';

/// Signaling only discovers peers and negotiates encrypted WebRTC channels.
/// Neither provider is a room database or a transport for editor history.
typedef SignalingPeerFactory =
    SignalingPeer Function(String id, Map<String, dynamic> rtcConfiguration);

enum SignalingFailureKind {
  idTaken,
  unavailable,
  remoteUnavailable,
  negotiation,
}

class SignalingFailure implements Exception {
  const SignalingFailure(this.kind, this.message);
  final SignalingFailureKind kind;
  final String message;
  @override
  String toString() => message;
}

enum ChannelConnectivity { connecting, connected, disconnected, failed, closed }

abstract interface class SignalingPeer {
  String get id;
  String get service;
  bool get open;
  bool get disconnected;
  Stream<String?> get onOpen;
  Stream<RoomChannel> get onConnection;
  Stream<SignalingFailure> get onError;
  Stream<void> get onDisconnected;
  Stream<void> get onClose;
  void start();
  RoomChannel connect(String peer);
  void dispose();
}

/// Optional in-place registration recovery. Existing RTC channels and the
/// logical peer identity must be retained; never create a parallel registration.
abstract interface class SignalingRecovery {
  /// Requests another registration attempt after signaling loss. Repeated calls
  /// while registering, before initial registration, or after conflict/disposal
  /// are harmless. Success is confirmed only by [SignalingPeer.onOpen].
  void reconnect();
}

/// Optional registration coverage, separate from [SignalingPeer] so existing
/// custom peers can continue to implement just the transport contract.
abstract interface class SignalingDiscovery {
  /// Every configured provider has validated registration for the current
  /// logical ID, with no registration pending, failure or identity conflict.
  /// This is stronger than [SignalingPeer.open], not proof the room is empty.
  bool get discoveryComplete;

  /// Registration status changed; reread [discoveryComplete]. A provider can
  /// finish or fail while overall coverage remains false. No initial replay.
  Stream<void> get onDiscoveryChanged;
}

abstract interface class RoomChannel {
  String get peer;
  String get service;
  bool get open;
  bool get disposed;
  ChannelConnectivity get connectivity;
  Stream<void> get onOpen;
  Stream<Object?> get onData;
  Stream<Object> get onError;
  Stream<void> get onClose;
  Stream<ChannelConnectivity> get onConnectivity;
  Future<void> send(Map<String, dynamic> data);
  void dispose();
}
