import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mqtt_client/mqtt_client.dart';

import 'mqtt_client_native.dart'
    if (dart.library.js_interop) 'mqtt_client_browser.dart'
    as platform;
import '../room_identity.dart';
import 'signaling.dart';

const _namespace = 'mytree/signaling/v1';
const _maxSignalBytes = 128 * 1024;
const _maxCandidates = 256;
const _probeDelay = Duration(milliseconds: 500);
const _claimDelay = Duration(seconds: 1);
const _ephemeralClaimDelay = Duration(milliseconds: 100);
const _discoveryTimeout = Duration(seconds: 6);
const _negotiationTimeout = Duration(seconds: 30);

bool _validId(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 256 &&
    utf8.encode(value).length <= 256;

bool _validToken(Object? value) =>
    value is String && RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(value);

String _topic(String id, String kind) =>
    '$_namespace/${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}/$kind';

/// A narrow transport boundary for deterministic broker/negotiation tests.
/// Implementations must complete subscribe only after the broker acknowledges it.
abstract interface class MqttSignalingBus {
  Stream<MqttSignalingMessage> get messages;
  Stream<void> get onDisconnected;
  Future<void> connect(Uri endpoint, String clientId);
  Future<void> subscribe(String topic);
  void publish(String topic, String payload);
  Future<void> close();
}

class MqttSignalingMessage {
  const MqttSignalingMessage(this.topic, this.payload, {this.retained = false});
  final String topic;
  final String payload;
  final bool retained;
}

typedef MqttRtcFactory =
    Future<RTCPeerConnection> Function(Map<String, dynamic> configuration);

/// Public MQTT carries discovery and SDP/ICE only. Editor packets are JSON on
/// an ordered, reliable, DTLS-encrypted RTCDataChannel, never broker publishes.
///
/// This clean-session, non-retained election is best-effort alias collision
/// detection, NOT atomic reservation or authorization. A public broker can
/// observe SDP/IP metadata and anybody can publish to its topics.
class MqttSignalingPeer implements SignalingPeer, SignalingDiscovery {
  MqttSignalingPeer({
    required this.id,
    required Map<String, dynamic> config,
    Uri? endpoint,
    MqttSignalingBus? bus,
    MqttRtcFactory? rtcFactory,
    String? instanceId,
    // Opt in only for cryptographically random runtime IDs, never room aliases.
    // Non-runtime-shaped IDs keep the conservative window even when opted in.
    bool ephemeralIdentity = false,
  }) : endpoint = endpoint ?? Uri.parse('wss://test.mosquitto.org:8081/mqtt'),
       _configuration = Map<String, dynamic>.from(config),
       _bus = bus ?? _ClientMqttBus(),
       _rtcFactory = rtcFactory ?? ((config) => createPeerConnection(config)),
       _claimWindow = ephemeralIdentity && isValidRoomId(id)
           ? _ephemeralClaimDelay
           : _claimDelay,
       _instance = instanceId ?? createRoomId() {
    if (!_validId(id)) throw ArgumentError.value(id, 'id');
    if (!_validToken(_instance)) {
      throw ArgumentError.value(instanceId, 'instanceId');
    }
    if (this.endpoint.scheme != 'wss' ||
        this.endpoint.host.isEmpty ||
        this.endpoint.userInfo.isNotEmpty ||
        this.endpoint.hasFragment) {
      throw ArgumentError.value(endpoint, 'endpoint', 'Expected a TLS wss URI');
    }
  }

  @override
  final String id;
  final Uri endpoint;
  final Map<String, dynamic> _configuration;
  final MqttSignalingBus _bus;
  final MqttRtcFactory _rtcFactory;
  final Duration _claimWindow;
  final String _instance;
  final _opens = StreamController<String?>.broadcast();
  final _connections = StreamController<RoomChannel>.broadcast();
  final _errors = StreamController<SignalingFailure>.broadcast();
  final _disconnects = StreamController<void>.broadcast();
  final _closes = StreamController<void>.broadcast();
  final _discoveryChanges = StreamController<void>.broadcast();
  final _channels = <String, _MqttRoomChannel>{};
  final _retiredConnections = <String>{};
  final _contenders = <String>{};
  final _discoveries = <String, Completer<String>>{};
  final _discoveryTimers = <String, Timer>{};
  final _discoveryRetries = <String, Timer>{};
  final _retryJitter = Random();
  StreamSubscription<MqttSignalingMessage>? _messages;
  StreamSubscription<void>? _busDisconnects;
  Timer? _probeTimer;
  Timer? _claimTimer;
  Timer? _heartbeat;
  bool _started = false;
  bool _disposed = false;
  bool _stopped = false;
  bool _claiming = false;
  bool _open = false;
  bool _closeEmitted = false;

  @override
  String get service =>
      endpoint.host == 'test.mosquitto.org' ? 'MQTT / Mosquitto' : 'MQTT';
  @override
  bool get open => _open && !_disposed && !_stopped;
  @override
  bool get disconnected => _stopped || _disposed;
  @override
  Stream<String?> get onOpen => _opens.stream;
  @override
  Stream<RoomChannel> get onConnection => _connections.stream;
  @override
  Stream<SignalingFailure> get onError => _errors.stream;
  @override
  Stream<void> get onDisconnected => _disconnects.stream;
  @override
  Stream<void> get onClose => _closes.stream;
  @override
  bool get discoveryComplete => open;
  @override
  Stream<void> get onDiscoveryChanged => _discoveryChanges.stream;

  @override
  void start() {
    if (_started || _disposed || _stopped) return;
    _started = true;
    _discoveryChanges.add(null);
    _messages = _bus.messages.listen(
      _receive,
      onError: (_) => _unavailable(),
      onDone: () {
        if (!_disposed && !_stopped) _unavailable();
      },
    );
    _busDisconnects = _bus.onDisconnected.listen((_) => _unavailable());
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      // The logical alias is deliberately NOT the MQTT client identifier.
      await _bus.connect(endpoint, 'mytree-$_instance');
      if (_disposed || _stopped) return;
      // Issue both subscriptions in one network round trip, but never probe
      // or begin admission before both subscriptions have been acknowledged.
      await Future.wait<void>([
        _bus.subscribe(_topic(id, 'mailbox')),
        _bus.subscribe(_topic(id, 'presence')),
      ]);
      if (_disposed || _stopped) return;
      _presence('probe');
      _probeTimer = Timer(_probeDelay, () {
        if (_disposed || _stopped) return;
        _claiming = true;
        _contenders.add(_instance);
        _presence('claim');
        if (_stopped) return;
        _claimTimer = Timer(_claimWindow, _confirmClaim);
      });
    } catch (_) {
      _unavailable();
    }
  }

  void _confirmClaim() {
    if (_disposed || _stopped) return;
    if (_contenders.any((other) => other.compareTo(_instance) < 0)) {
      _idTaken();
      return;
    }
    _open = true;
    _presence('owner');
    if (_stopped) return;
    _heartbeat = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _presence('owner'),
    );
    _discoveryChanges.add(null);
    _opens.add(id);
  }

  void _presence(String type, {String? recipient}) {
    _publish(_topic(id, 'presence'), {
      'v': 1,
      'type': type,
      'from': id,
      'instance': _instance,
      if (recipient != null) 'recipient': recipient,
    });
  }

  bool _publish(String topic, Map<String, dynamic> packet) {
    if (_disposed || _stopped) return false;
    try {
      final payload = jsonEncode(packet);
      if (utf8.encode(payload).length > _maxSignalBytes) {
        throw const FormatException('Signaling message is too large');
      }
      _bus.publish(topic, payload);
      return true;
    } catch (_) {
      _unavailable();
      return false;
    }
  }

  void _receive(MqttSignalingMessage message) {
    if (_disposed || _stopped || message.retained) return;
    if (message.payload.length > _maxSignalBytes ||
        utf8.encode(message.payload).length > _maxSignalBytes) {
      return;
    }
    Map<String, dynamic> packet;
    try {
      final decoded = jsonDecode(message.payload);
      if (decoded is! Map<String, dynamic>) return;
      packet = decoded;
    } catch (_) {
      return;
    }
    if (packet['v'] != 1 ||
        !_validId(packet['from']) ||
        !_validToken(packet['instance'])) {
      return;
    }
    final source = packet['from'] as String;
    final instance = packet['instance'] as String;
    if (source == id && instance == _instance) return;
    if (message.topic == _topic(id, 'presence') && source == id) {
      _receivePresence(packet, instance);
    } else if (message.topic == _topic(id, 'mailbox')) {
      _receiveMailbox(packet, source, instance);
    }
  }

  void _receivePresence(Map<String, dynamic> packet, String instance) {
    final recipient = packet['recipient'];
    if (recipient != null && recipient != _instance) return;
    switch (packet['type']) {
      case 'probe':
        if (open) {
          _presence('occupied', recipient: instance);
        } else if (_claiming) {
          _presence('claim');
        }
      case 'claim':
        if (open) {
          // A challenge response also defeats a contender that opened while
          // this broker reply was in flight, regardless of instance ordering.
          _presence('occupied', recipient: instance);
        } else {
          final firstClaim = _contenders.add(instance);
          if (_claiming && firstClaim) {
            _presence('claim', recipient: instance);
          }
        }
      case 'occupied':
        if (recipient == _instance) _idTaken();
      case 'owner':
        // Two owners after a network partition converge deterministically.
        if (!open || instance.compareTo(_instance) < 0) {
          _idTaken();
        } else {
          _presence('owner', recipient: instance);
        }
    }
  }

  void _receiveMailbox(
    Map<String, dynamic> packet,
    String source,
    String instance,
  ) {
    if (source == id || packet['to'] != id) return;
    if (packet['type'] == 'discover') {
      if (open && _validToken(packet['request'])) {
        _publish(_topic(source, 'mailbox'), {
          'v': 1,
          'type': 'available',
          'from': id,
          'instance': _instance,
          'to': source,
          'recipient': instance,
          'request': packet['request'],
        });
      }
      return;
    }
    if (packet['recipient'] != _instance || !open) return;
    if (packet['type'] == 'available') {
      final key = '$source/${packet['request']}';
      final pending = _discoveries.remove(key);
      _discoveryTimers.remove(key)?.cancel();
      _discoveryRetries.remove(key)?.cancel();
      if (pending != null && !pending.isCompleted) pending.complete(instance);
      return;
    }
    final connection = packet['connection'];
    if (!_validToken(connection)) return;
    final key = '$source/$instance/$connection';
    if (_retiredConnections.contains(key)) return;
    var channel = _channels[connection];
    if (packet['type'] == 'offer') {
      if (channel != null || !_validSdp(packet['sdp'])) return;
      // Protect the public mailbox from allocating unlimited RTC objects.
      if (_channels.length >= 64) return;
      channel = _newChannel(source, connection as String, instance);
      _connections.add(channel);
      // Subscribers see onConnection before negotiation can emit channel events.
      scheduleMicrotask(() {
        if (!channel!.disposed) {
          channel._run(() => channel!._answer(packet['sdp'] as String));
        }
      });
      return;
    }
    if (channel == null ||
        channel.peer != source ||
        channel._remoteInstance != instance) {
      return;
    }
    if (packet['type'] == 'answer' && _validSdp(packet['sdp'])) {
      channel._run(() => channel!._acceptAnswer(packet['sdp'] as String));
    } else if (packet['type'] == 'candidate') {
      final candidate = packet['candidate'];
      final mid = packet['sdpMid'];
      final line = packet['sdpMLineIndex'];
      if (candidate is! String ||
          candidate.isEmpty ||
          candidate.length > 8192 ||
          (mid != null && mid is! String) ||
          (line != null && (line is! int || line < 0 || line > 65535))) {
        return;
      }
      channel._receiveCandidate(
        RTCIceCandidate(candidate, mid as String?, line as int?),
      );
    }
  }

  bool _validSdp(Object? sdp) =>
      sdp is String && sdp.isNotEmpty && sdp.length <= _maxSignalBytes;

  @override
  RoomChannel connect(String peer) {
    if (!_validId(peer) || peer == id) {
      throw ArgumentError.value(peer, 'peer');
    }
    if (!open) {
      throw const SignalingFailure(
        SignalingFailureKind.unavailable,
        'MQTT signaling is unavailable.',
      );
    }
    final channel = _newChannel(peer, createRoomId(), null);
    // Do not negotiate before the caller can attach stream listeners.
    scheduleMicrotask(() {
      channel._run(() async {
        final instance = await _discover(peer, channel._connection);
        if (channel.disposed || _disposed || _stopped) return;
        channel._remoteInstance = instance;
        await channel._offer();
      });
    });
    return channel;
  }

  _MqttRoomChannel _newChannel(
    String peer,
    String connection,
    String? instance,
  ) {
    final channel = _MqttRoomChannel(this, peer, connection, instance);
    _channels[connection] = channel;
    return channel;
  }

  Future<String> _discover(String peer, String request) async {
    if (!open) {
      throw const SignalingFailure(
        SignalingFailureKind.unavailable,
        'MQTT signaling is unavailable.',
      );
    }
    final key = '$peer/$request';
    final pending = Completer<String>();
    _discoveries[key] = pending;
    _discoveryTimers[key] = Timer(_discoveryTimeout, () {
      _discoveries.remove(key);
      _discoveryTimers.remove(key);
      _discoveryRetries.remove(key)?.cancel();
      if (!pending.isCompleted) {
        pending.completeError(
          const SignalingFailure(
            SignalingFailureKind.remoteUnavailable,
            'The remote peer is unavailable on MQTT.',
          ),
        );
      }
    });
    void probe(int retry) {
      if (!open || !identical(_discoveries[key], pending)) return;
      final sent = _publish(_topic(peer, 'mailbox'), {
        'v': 1,
        'type': 'discover',
        'from': id,
        'instance': _instance,
        'to': peer,
        'request': request,
      });
      // A clean-session broker may drop the first request while the host is
      // still claiming its alias. Reuse the token, never renew the deadline.
      if (sent && retry < 4 && identical(_discoveries[key], pending)) {
        _discoveryRetries[key] = Timer(
          Duration(
            milliseconds: min(2000, 500 << retry) + _retryJitter.nextInt(151),
          ),
          () => probe(retry + 1),
        );
      }
    }

    probe(0);
    return pending.future;
  }

  bool _signal(_MqttRoomChannel channel, Map<String, dynamic> payload) {
    if (!open || channel.disposed || channel._remoteInstance == null) {
      return false;
    }
    return _publish(_topic(channel.peer, 'mailbox'), {
      'v': 1,
      'from': id,
      'instance': _instance,
      'to': channel.peer,
      'recipient': channel._remoteInstance,
      'connection': channel._connection,
      ...payload,
    });
  }

  void _channelClosed(_MqttRoomChannel channel) {
    if (identical(_channels[channel._connection], channel)) {
      _channels.remove(channel._connection);
    }
    _retiredConnections.add(
      '${channel.peer}/${channel._remoteInstance}/${channel._connection}',
    );
    if (_retiredConnections.length > 256) {
      _retiredConnections.remove(_retiredConnections.first);
    }
    final key = '${channel.peer}/${channel._connection}';
    _discoveryTimers.remove(key)?.cancel();
    _discoveryRetries.remove(key)?.cancel();
    final pending = _discoveries.remove(key);
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        const SignalingFailure(
          SignalingFailureKind.negotiation,
          'The channel was closed before discovery completed.',
        ),
      );
    }
  }

  void _idTaken() => _stop(
    const SignalingFailure(
      SignalingFailureKind.idTaken,
      'This peer ID is already in use on MQTT.',
    ),
  );

  void _unavailable() => _stop(
    const SignalingFailure(
      SignalingFailureKind.unavailable,
      'The MQTT signaling service is unavailable.',
    ),
  );

  void _stop(SignalingFailure failure) {
    if (_disposed || _stopped) return;
    _stopped = true;
    _open = false;
    _cancelSignaling();
    _discoveryChanges.add(null);
    _errors.add(failure);
    _disconnects.add(null);
    _emitClose();
    for (final pending in _discoveries.values) {
      if (!pending.isCompleted) pending.completeError(failure);
    }
    _discoveries.clear();
    for (final channel in _channels.values.toList()) {
      // Signaling loss must not terminate an established encrypted RTC link.
      if (!channel.open) channel._fail(failure);
    }
    unawaited(_bus.close());
  }

  void _cancelSignaling() {
    _probeTimer?.cancel();
    _claimTimer?.cancel();
    _heartbeat?.cancel();
    for (final timer in _discoveryTimers.values) {
      timer.cancel();
    }
    _discoveryTimers.clear();
    for (final timer in _discoveryRetries.values) {
      timer.cancel();
    }
    _discoveryRetries.clear();
    unawaited(_messages?.cancel());
    unawaited(_busDisconnects?.cancel());
    _messages = null;
    _busDisconnects = null;
  }

  void _emitClose() {
    if (_closeEmitted) return;
    _closeEmitted = true;
    _closes.add(null);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _open = false;
    _cancelSignaling();
    _discoveryChanges.add(null);
    for (final channel in _channels.values.toList()) {
      channel.dispose();
    }
    _emitClose();
    unawaited(_bus.close());
    unawaited(_opens.close());
    unawaited(_connections.close());
    unawaited(_errors.close());
    unawaited(_disconnects.close());
    unawaited(_closes.close());
    unawaited(_discoveryChanges.close());
  }
}

class _MqttRoomChannel implements RoomChannel {
  _MqttRoomChannel(
    this._owner,
    this.peer,
    this._connection,
    this._remoteInstance,
  ) {
    _deadline = Timer(_negotiationTimeout, () {
      if (!open) {
        _fail(
          const SignalingFailure(
            SignalingFailureKind.negotiation,
            'The encrypted WebRTC channel could not be established.',
          ),
        );
      }
    });
  }

  final MqttSignalingPeer _owner;
  @override
  final String peer;
  final String _connection;
  String? _remoteInstance;
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  final _opens = StreamController<void>.broadcast();
  final _data = StreamController<Object?>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _closes = StreamController<void>.broadcast();
  final _health = StreamController<ChannelConnectivity>.broadcast();
  final _remoteCandidates = <RTCIceCandidate>[];
  final _localCandidates = <RTCIceCandidate>[];
  final _seenCandidates = <String>{};
  Future<void> _operations = Future<void>.value();
  late final Timer _deadline;
  Timer? _healthTimer;
  bool _disposed = false;
  bool _dataOpen = false;
  bool _remoteDescription = false;
  bool _localDescriptionSent = false;
  bool _offered = false;
  ChannelConnectivity _connectivity = ChannelConnectivity.connecting;
  ChannelConnectivity _iceConnectivity = ChannelConnectivity.connecting;
  ChannelConnectivity _peerConnectivity = ChannelConnectivity.connecting;
  bool _polling = false;

  @override
  String get service => _owner.service;
  @override
  bool get open => _dataOpen && !_disposed;
  @override
  bool get disposed => _disposed;
  @override
  ChannelConnectivity get connectivity => _connectivity;
  @override
  Stream<void> get onOpen => _opens.stream;
  @override
  Stream<Object?> get onData => _data.stream;
  @override
  Stream<Object> get onError => _errors.stream;
  @override
  Stream<void> get onClose => _closes.stream;
  @override
  Stream<ChannelConnectivity> get onConnectivity => _health.stream;

  void _run(Future<void> Function() operation) {
    _operations = _operations.then((_) async {
      if (_disposed) return;
      try {
        await operation();
      } catch (error) {
        if (_disposed) return;
        _fail(
          error is SignalingFailure
              ? error
              : const SignalingFailure(
                  SignalingFailureKind.negotiation,
                  'WebRTC channel negotiation failed.',
                ),
        );
      }
    });
  }

  Future<RTCPeerConnection?> _createRtc() async {
    if (_disposed) return null;
    final pc = await _owner._rtcFactory(
      Map<String, dynamic>.from(_owner._configuration),
    );
    if (_disposed) {
      await _releaseRtc(pc, null);
      return null;
    }
    _pc = pc;
    pc.onIceCandidate = _localCandidate;
    pc.onDataChannel = _attachDataChannel;
    pc.onIceConnectionState = (state) => _iceState(state);
    pc.onConnectionState = (state) => _peerState(state);
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollHealth());
    });
    return pc;
  }

  Future<void> _offer() async {
    final pc = await _createRtc();
    if (pc == null || _disposed) return;
    _attachDataChannel(
      await pc.createDataChannel(
        'mytree',
        RTCDataChannelInit()..ordered = true,
      ),
    );
    if (_disposed) return;
    final offer = await pc.createOffer();
    if (_disposed) return;
    _offered = true;
    await pc.setLocalDescription(offer);
    if (_disposed) return;
    _sendDescription('offer', offer);
  }

  Future<void> _answer(String sdp) async {
    final pc = await _createRtc();
    if (pc == null || _disposed) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    if (_disposed) return;
    _remoteDescription = true;
    await _flushRemoteCandidates();
    if (_disposed) return;
    final answer = await pc.createAnswer();
    if (_disposed) return;
    await pc.setLocalDescription(answer);
    if (_disposed) return;
    _sendDescription('answer', answer);
  }

  Future<void> _acceptAnswer(String sdp) async {
    if (!_offered || _remoteDescription || _pc == null || _disposed) return;
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    if (_disposed) return;
    _remoteDescription = true;
    await _flushRemoteCandidates();
  }

  void _sendDescription(String type, RTCSessionDescription description) {
    if (!_owner._signal(this, {'type': type, 'sdp': description.sdp})) {
      _fail(
        const SignalingFailure(
          SignalingFailureKind.unavailable,
          'MQTT signaling was lost during negotiation.',
        ),
      );
      return;
    }
    // Trickle ICE may fire inside setLocalDescription; always publish SDP first.
    _localDescriptionSent = true;
    for (final candidate in _localCandidates.toList()) {
      _publishCandidate(candidate);
    }
    _localCandidates.clear();
  }

  void _localCandidate(RTCIceCandidate candidate) {
    if (_disposed ||
        candidate.candidate == null ||
        candidate.candidate!.isEmpty) {
      return;
    }
    if (!_localDescriptionSent) {
      if (_localCandidates.length >= _maxCandidates) {
        _fail(
          const SignalingFailure(
            SignalingFailureKind.negotiation,
            'Too many ICE candidates during negotiation.',
          ),
        );
      } else {
        _localCandidates.add(candidate);
      }
    } else {
      _publishCandidate(candidate);
    }
  }

  void _publishCandidate(RTCIceCandidate candidate) {
    if (_disposed || !_owner.open) return;
    _owner._signal(this, {
      'type': 'candidate',
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    });
  }

  void _receiveCandidate(RTCIceCandidate candidate) {
    if (_disposed) return;
    final key =
        '${candidate.sdpMid}/${candidate.sdpMLineIndex}/${candidate.candidate}';
    if (!_seenCandidates.add(key)) return;
    if (_seenCandidates.length > _maxCandidates) {
      _fail(
        const SignalingFailure(
          SignalingFailureKind.negotiation,
          'Too many ICE candidates during negotiation.',
        ),
      );
      return;
    }
    // Includes ICE received while the factory or setRemoteDescription is pending.
    _remoteCandidates.add(candidate);
    if (_remoteDescription) _run(_flushRemoteCandidates);
  }

  Future<void> _flushRemoteCandidates() async {
    if (_disposed || !_remoteDescription || _pc == null) return;
    while (!_disposed && _remoteCandidates.isNotEmpty) {
      final candidate = _remoteCandidates.removeAt(0);
      await _pc!.addCandidate(candidate);
    }
  }

  void _attachDataChannel(RTCDataChannel dc) {
    if (_disposed || _dc != null) {
      unawaited(_releaseRtc(null, dc));
      return;
    }
    _dc = dc;
    dc.onMessage = (message) {
      if (_disposed) return;
      try {
        if (message.isBinary) throw const FormatException();
        final packet = jsonDecode(message.text);
        if (packet is! Map<String, dynamic>) throw const FormatException();
        _data.add(packet);
      } catch (_) {
        _errors.add(
          const SignalingFailure(
            SignalingFailureKind.negotiation,
            'Invalid JSON packet received on the WebRTC channel.',
          ),
        );
      }
    };
    dc.onDataChannelState = _dataState;
    final state = dc.state;
    if (state != null) _dataState(state);
  }

  void _dataState(RTCDataChannelState state) {
    if (_disposed) return;
    if (state == RTCDataChannelState.RTCDataChannelOpen && !_dataOpen) {
      _dataOpen = true;
      _deadline.cancel();
      _refreshConnectivity();
      _opens.add(null);
    } else if (state == RTCDataChannelState.RTCDataChannelClosing ||
        state == RTCDataChannelState.RTCDataChannelClosed) {
      _finish(ChannelConnectivity.closed);
    }
  }

  void _iceState(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _iceConnectivity = ChannelConnectivity.connected;
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _iceConnectivity = ChannelConnectivity.disconnected;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        _fail(
          const SignalingFailure(
            SignalingFailureKind.negotiation,
            'The WebRTC ICE connection failed.',
          ),
        );
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        _finish(ChannelConnectivity.closed);
      default:
        _iceConnectivity = ChannelConnectivity.connecting;
    }
    _refreshConnectivity();
  }

  void _peerState(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _peerConnectivity = ChannelConnectivity.connected;
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        _peerConnectivity = ChannelConnectivity.disconnected;
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _fail(
          const SignalingFailure(
            SignalingFailureKind.negotiation,
            'The WebRTC peer connection failed.',
          ),
        );
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _finish(ChannelConnectivity.closed);
      default:
        _peerConnectivity = ChannelConnectivity.connecting;
    }
    _refreshConnectivity();
  }

  void _refreshConnectivity() {
    if (_iceConnectivity == ChannelConnectivity.disconnected ||
        _peerConnectivity == ChannelConnectivity.disconnected) {
      _setConnectivity(ChannelConnectivity.disconnected);
    } else if (_dataOpen ||
        _iceConnectivity == ChannelConnectivity.connected ||
        _peerConnectivity == ChannelConnectivity.connected) {
      _setConnectivity(ChannelConnectivity.connected);
    } else {
      _setConnectivity(ChannelConnectivity.connecting);
    }
  }

  Future<void> _pollHealth() async {
    final pc = _pc;
    if (_disposed || pc == null || _polling) return;
    _polling = true;
    try {
      final ice = await pc.getIceConnectionState();
      if (_disposed) return;
      if (ice != null) _iceState(ice);
      final state = await pc.getConnectionState();
      if (_disposed) return;
      if (state != null) _peerState(state);
    } catch (_) {
      // Callbacks and the negotiation deadline remain authoritative if polling
      // is unsupported on a platform; do not report an unverified healthy link.
    } finally {
      _polling = false;
    }
  }

  void _setConnectivity(ChannelConnectivity value) {
    if (_disposed || _connectivity == value) return;
    _connectivity = value;
    _health.add(value);
  }

  @override
  Future<void> send(Map<String, dynamic> data) async {
    if (!open || _dc == null) {
      throw const SignalingFailure(
        SignalingFailureKind.negotiation,
        'The encrypted WebRTC data channel is not open.',
      );
    }
    await _dc!.send(RTCDataChannelMessage(jsonEncode(data)));
  }

  void _fail(SignalingFailure failure) {
    if (_disposed) return;
    _errors.add(failure);
    _finish(ChannelConnectivity.failed);
  }

  void _finish(ChannelConnectivity finalState) {
    if (_disposed) return;
    _setConnectivity(finalState);
    _disposed = true;
    _dataOpen = false;
    _deadline.cancel();
    _healthTimer?.cancel();
    _remoteCandidates.clear();
    _localCandidates.clear();
    final pc = _pc;
    final dc = _dc;
    _pc = null;
    _dc = null;
    _owner._channelClosed(this);
    _closes.add(null);
    unawaited(_releaseRtc(pc, dc));
    unawaited(_opens.close());
    unawaited(_data.close());
    unawaited(_errors.close());
    unawaited(_closes.close());
    unawaited(_health.close());
  }

  @override
  void dispose() => _finish(ChannelConnectivity.closed);
}

Future<void> _releaseRtc(RTCPeerConnection? pc, RTCDataChannel? dc) async {
  if (pc != null) {
    pc.onIceCandidate = null;
    pc.onIceConnectionState = null;
    pc.onConnectionState = null;
    pc.onDataChannel = null;
  }
  if (dc != null) {
    dc.onMessage = null;
    dc.onDataChannelState = null;
    try {
      await dc.close();
    } catch (_) {
      // Best-effort cleanup of an already closed native/browser channel.
    }
  }
  if (pc != null) {
    try {
      await pc.close();
    } catch (_) {
      // Continue releasing platform resources even when close already ran.
    }
    try {
      await pc.dispose();
    } catch (_) {
      // A disposed platform handle must not escape as an unhandled future.
    }
  }
}

class _ClientMqttBus implements MqttSignalingBus {
  final _messages = StreamController<MqttSignalingMessage>.broadcast();
  final _disconnects = StreamController<void>.broadcast();
  final _subscriptions = <String, Completer<void>>{};
  MqttClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  bool _closed = false;

  @override
  Stream<MqttSignalingMessage> get messages => _messages.stream;
  @override
  Stream<void> get onDisconnected => _disconnects.stream;

  @override
  Future<void> connect(Uri endpoint, String clientId) async {
    if (_closed) throw StateError('MQTT bus is closed');
    final client = platform.createMqttClient(endpoint, clientId);
    _client = client;
    client
      ..logging(on: false)
      ..setProtocolV311()
      ..autoReconnect = false
      ..keepAlivePeriod = 20
      ..disconnectOnNoResponsePeriod = 10
      ..connectTimeoutPeriod = 5000
      ..connectionMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .startClean()
      ..onDisconnected = () {
        if (!_closed) _disconnects.add(null);
        _rejectSubscriptions();
      }
      ..onSubscribed = (topic) {
        _subscriptions.remove(topic)?.complete();
      }
      ..onSubscribeFail = (topic) => _subscriptions
          .remove(topic)
          ?.completeError(StateError('MQTT subscription rejected'));
    final connecting = client.connect();
    // Future.timeout cannot abort the library's native websocket handshake.
    // If it completes after disposal/timeout, immediately close the late socket.
    unawaited(
      connecting.then<void>((_) {
        if (_closed) _disconnectClient();
      }, onError: (Object _, StackTrace __) {}),
    );
    await connecting.timeout(const Duration(seconds: 8));
    if (_closed) {
      _disconnectClient();
      throw StateError('MQTT bus was closed while connecting');
    }
    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      throw StateError('MQTT broker did not accept the connection');
    }
    _updates = client.updates!.listen(
      (updates) {
        if (_closed) return;
        for (final update in updates) {
          final message = update.payload;
          if (message is! MqttPublishMessage ||
              message.payload.message.length > _maxSignalBytes) {
            continue;
          }
          try {
            _messages.add(
              MqttSignalingMessage(
                update.topic,
                utf8.decode(message.payload.message),
                retained: message.header?.retain ?? false,
              ),
            );
          } catch (_) {
            // Malformed UTF-8 from an untrusted public topic is ignored.
          }
        }
      },
      onError: (_) {
        if (!_closed) _disconnects.add(null);
      },
    );
  }

  @override
  Future<void> subscribe(String topic) async {
    final client = _client;
    if (_closed || client == null) throw StateError('MQTT bus is closed');
    final pending = Completer<void>();
    _subscriptions[topic] = pending;
    try {
      if (client.subscribe(topic, MqttQos.atLeastOnce) == null) {
        throw StateError('MQTT subscription failed');
      }
      await pending.future.timeout(const Duration(seconds: 4));
    } finally {
      _subscriptions.remove(topic);
    }
  }

  @override
  void publish(String topic, String payload) {
    final client = _client;
    if (_closed || client == null) throw StateError('MQTT bus is closed');
    final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
    // Never retain identity, SDP, ICE, or any application/history content.
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void _disconnectClient() {
    try {
      _client?.disconnect();
    } catch (_) {
      // A timed-out/late websocket can already have had its handler released.
    }
  }

  void _rejectSubscriptions() {
    for (final pending in _subscriptions.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('MQTT disconnected during subscribe'));
      }
    }
    _subscriptions.clear();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _rejectSubscriptions();
    await _updates?.cancel();
    final client = _client;
    if (client != null) {
      client.onDisconnected = null;
      client.onSubscribed = null;
      client.onSubscribeFail = null;
      _disconnectClient();
    }
    await _messages.close();
    await _disconnects.close();
  }
}
