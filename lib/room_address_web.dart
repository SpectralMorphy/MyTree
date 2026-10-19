import 'package:web/web.dart' as web;

/// Consume an incoming invitation without leaving it in the address/history.
Uri consumeRoomAddress() {
  final uri = Uri.base;
  if (uri.hasFragment) {
    web.window.history.replaceState(null, '', uri.removeFragment().toString());
  }
  return uri;
}
