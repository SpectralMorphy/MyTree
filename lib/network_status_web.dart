import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

// navigator.onLine can disprove connectivity, but cannot prove that a public
// service or peer is reachable. The session still checks signaling/RTC health.
bool get networkOnlineHint => web.window.navigator.onLine;

Stream<bool> watchNetworkOnlineHint() {
  late StreamController<bool> controller;
  final listener = ((web.Event event) {
    controller.add(networkOnlineHint);
  }).toJS;
  controller = StreamController<bool>(
    onListen: () {
      web.window.addEventListener('online', listener);
      web.window.addEventListener('offline', listener);
      controller.add(networkOnlineHint);
    },
    onCancel: () {
      web.window.removeEventListener('online', listener);
      web.window.removeEventListener('offline', listener);
    },
  );
  return controller.stream;
}

Stream<bool> watchApplicationForeground() {
  late StreamController<bool> controller;
  final listener = ((web.Event event) {
    controller.add(!web.document.hidden);
  }).toJS;
  controller = StreamController<bool>(
    onListen: () {
      web.document.addEventListener('visibilitychange', listener);
      web.document.addEventListener('resume', listener);
      web.window.addEventListener('pageshow', listener);
      controller.add(!web.document.hidden);
    },
    onCancel: () {
      web.document.removeEventListener('visibilitychange', listener);
      web.document.removeEventListener('resume', listener);
      web.window.removeEventListener('pageshow', listener);
    },
  );
  return controller.stream;
}
