import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:mqtt_client/mqtt_client.dart';

/// Browser WebSockets perform TLS and certificate validation for a wss URI.
MqttClient createMqttClient(Uri endpoint, String clientId) {
  return MqttBrowserClient.withPort(
    endpoint.toString(),
    clientId,
    endpoint.hasPort ? endpoint.port : 443,
    maxConnectionAttempts: 1,
  )..websocketProtocols = const ['mqtt'];
}
