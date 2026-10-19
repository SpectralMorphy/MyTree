import 'package:flutter/material.dart';

import 'ice_configuration.dart';
import 'local/room_tabs.dart';
import 'room_address_stub.dart'
    if (dart.library.js_interop) 'room_address_web.dart';
import 'room_session.dart';
import 'signaling/fallback_signaling.dart';
import 'signaling/signaling.dart';
import 'storage/room_store.dart';
import 'ui/room_page.dart';

void main() {
  final applicationUri = consumeRoomAddress();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MyTreeDemoApp(applicationUri: applicationUri));
}

class MyTreeDemoApp extends StatelessWidget {
  const MyTreeDemoApp({
    super.key,
    this.store,
    this.applicationUri,
    this.peerFactory = createSignalingPeer,
    this.roomTabsFactory,
    this.roomEditorBuilder,
    this.iceConfiguration = const IceConfiguration.fromEnvironment(),
  });

  final RoomStore? store;
  final Uri? applicationUri;
  final SignalingPeerFactory peerFactory;
  final RoomTabsFactory? roomTabsFactory;
  final Widget Function(RoomSession)? roomEditorBuilder;
  final IceConfiguration iceConfiguration;

  @override
  Widget build(BuildContext context) {
    Widget home() => RoomPage(
      store: store,
      applicationUri: applicationUri,
      peerFactory: peerFactory,
      roomTabsFactory: roomTabsFactory,
      roomEditorBuilder: roomEditorBuilder,
      iceConfiguration: iceConfiguration,
    );
    return MaterialApp(
      title: 'MyTree',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF28644B))
            .copyWith(
              primary: const Color(0xFF28644B),
              onPrimary: Colors.white,
              primaryContainer: const Color(0xFFD9E9CD),
              onPrimaryContainer: const Color(0xFF315E47),
              surface: const Color(0xFFF3F7ED),
              onSurface: const Color(0xFF315E47),
            ),
        useMaterial3: true,
      ),
      routes: {'/': (_) => home()},
      onGenerateInitialRoutes: (_) => [
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/'),
          builder: (_) => home(),
        ),
      ],
    );
  }
}
