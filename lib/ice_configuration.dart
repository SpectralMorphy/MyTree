class IceConfiguration {
  const IceConfiguration({
    this.turnUrls = '',
    this.turnUsername = '',
    this.turnCredential = '',
    this.forceRelay = false,
  });

  const IceConfiguration.fromEnvironment()
    : turnUrls = _hasTurnOverrides
          ? const String.fromEnvironment('TURN_URLS')
          : _publicTurnUrls,
      turnUsername = _hasTurnOverrides
          ? const String.fromEnvironment('TURN_USERNAME')
          : _publicTurnUsername,
      turnCredential = _hasTurnOverrides
          ? const String.fromEnvironment('TURN_CREDENTIAL')
          : _publicTurnCredential,
      forceRelay = const bool.fromEnvironment('TURN_FORCE_RELAY');

  // The operator explicitly publishes these guest credentials for public use:
  // https://github.com/Evan-Brass/masquerade
  static const _publicTurnUrls =
      'turn:turn.evan-brass.net,'
      'turn:turn.evan-brass.net?transport=tcp,'
      'turns:turn.evan-brass.net:443?transport=tcp';
  static const _publicTurnUsername = 'guest';
  static const _publicTurnCredential = 'password';
  static const _hasTurnOverrides =
      bool.hasEnvironment('TURN_URLS') ||
      bool.hasEnvironment('TURN_USERNAME') ||
      bool.hasEnvironment('TURN_CREDENTIAL');

  final String turnUrls;
  final String turnUsername;
  final String turnCredential;
  final bool forceRelay;

  static final _turnUrlPattern = RegExp(
    r'^(?:turn|turns):(\[[0-9a-fA-F:.]+\]|[a-zA-Z0-9.-]+)(?::([0-9]+))?(?:\?transport=(?:udp|tcp))?$',
  );
  static final _hostLabelPattern = RegExp(
    r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
  );

  List<String> get _urls =>
      turnUrls.split(',').map((url) => url.trim()).toList();

  String? get validationError {
    if (turnUrls.isEmpty && turnUsername.isEmpty && turnCredential.isEmpty) {
      return forceRelay
          ? 'TURN_FORCE_RELAY requires a complete TURN configuration.'
          : null;
    }
    if (turnUrls.trim().isEmpty) {
      return 'TURN_URLS is required when TURN credentials are provided.';
    }
    if (turnUsername.trim().isEmpty || turnCredential.trim().isEmpty) {
      return 'TURN_USERNAME and TURN_CREDENTIAL are required with TURN_URLS.';
    }
    if (_urls.any((url) => !_isValidTurnUrl(url))) {
      return 'TURN_URLS must contain comma-separated turn: or turns: URLs '
          'with a valid host, optional port, and optional transport=udp '
          'or transport=tcp.';
    }
    return null;
  }

  bool get hasTurn => turnUrls.isNotEmpty && validationError == null;

  Map<String, dynamic> toRtcConfiguration() {
    final error = validationError;
    if (error != null) {
      throw ArgumentError(error);
    }

    return <String, dynamic>{
      'iceServers': <Map<String, dynamic>>[
        {
          'urls': <String>['stun:stun.l.google.com:19302'],
        },
        {
          'urls': <String>['stun:stun1.l.google.com:19302'],
        },
        if (hasTurn)
          {
            'urls': _urls,
            'username': turnUsername,
            'credential': turnCredential,
          },
      ],
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': forceRelay ? 'relay' : 'all',
    };
  }

  static bool _isValidTurnUrl(String url) {
    if (RegExp(r'\s').hasMatch(url)) {
      return false;
    }
    final match = _turnUrlPattern.firstMatch(url);
    if (match == null) {
      return false;
    }

    final portText = match.group(2);
    if (portText != null) {
      final port = int.tryParse(portText);
      if (port == null || port < 1 || port > 65535) {
        return false;
      }
    }

    final host = match.group(1)!;
    if (host.startsWith('[')) {
      try {
        Uri.parseIPv6Address(host.substring(1, host.length - 1));
        return true;
      } on FormatException {
        return false;
      }
    }

    final hostname = host.endsWith('.')
        ? host.substring(0, host.length - 1)
        : host;
    if (hostname.isEmpty || hostname.length > 253) {
      return false;
    }
    if (RegExp(r'^[0-9]+(?:\.[0-9]+){3}$').hasMatch(hostname)) {
      return hostname
          .split('.')
          .every((part) => part.length <= 3 && int.parse(part) <= 255);
    }
    return hostname.split('.').every(_hostLabelPattern.hasMatch);
  }
}
