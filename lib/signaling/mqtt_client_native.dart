import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

/// A wss URI selects TLS; `secure` is for MQTT/TCP, not WebSockets.
/// Leave certificate validation enabled and use the system trust store.
MqttClient createMqttClient(Uri endpoint, String clientId) {
  return MqttServerClient.withPort(
      endpoint.toString(),
      clientId,
      endpoint.hasPort ? endpoint.port : 443,
      maxConnectionAttempts: 1,
    )
    ..useWebSocket = true
    ..websocketProtocols = const ['mqtt'];
}
