import 'dart:convert';
import 'dart:math';

/// An invitation's requested role, not authentication or a security boundary.
enum RoomRole { guest, editor }

RoomRole? parseRoomRole(Object? value) => switch (value) {
  'guest' => RoomRole.guest,
  'editor' => RoomRole.editor,
  _ => null,
};

/// A room identity and its requested role; ID validation remains with callers.
class RoomInvitation {
  const RoomInvitation(this.roomId, {this.role = RoomRole.guest});

  final String roomId;
  final RoomRole role;

  @override
  bool operator ==(Object other) =>
      other is RoomInvitation && roomId == other.roomId && role == other.role;

  @override
  int get hashCode => Object.hash(roomId, role);
}

/// A local 128-bit identity, shared by rooms, actors, and immutable edits.
String createRoomId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

bool isValidRoomId(String id) => RegExp(r'^[0-9a-f]{32}$').hasMatch(id);

bool isValidRoomActor(Object? value) =>
    value is String && value.isNotEmpty && value.length <= 128;

bool _isWebUri(Uri uri) =>
    (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty;

/// Preserves the hosting path and keeps the room ID out of HTTP requests.
String? createRoomLink(Uri applicationUri, String roomId, {RoomRole? role}) {
  if (!_isWebUri(applicationUri)) return null;
  final fragment = Uri(
    queryParameters: {'room': roomId, if (role != null) 'role': role.name},
  ).query;
  return applicationUri.replace(fragment: fragment).toString();
}

String createRoomQrData(Uri applicationUri, String roomId, {RoomRole? role}) =>
    createRoomLink(applicationUri, roomId, role: role) ??
    jsonEncode(<String, dynamic>{
      'v': 1,
      'peerId': roomId,
      if (role != null) 'role': role.name,
    });

String? roomIdFromUri(Uri uri) {
  if (!_isWebUri(uri) || uri.fragment.isEmpty) return null;
  try {
    final parameters = Uri.splitQueryString(uri.fragment);
    final roomId = (parameters['room'] ?? parameters['peer'])?.trim();
    return roomId == null || roomId.isEmpty ? null : roomId;
  } on FormatException {
    return null;
  }
}

/// Reads fragment-only web invitations, rejecting invalid or repeated roles.
RoomInvitation? roomInvitationFromUri(Uri uri) {
  if (!_isWebUri(uri) || uri.fragment.isEmpty) return null;
  try {
    final parameters = Uri(query: uri.fragment).queryParametersAll;
    final roles = parameters['role'];
    if (roles != null && roles.length != 1) return null;
    final role = roles == null ? RoomRole.guest : parseRoomRole(roles.single);
    if (role == null) return null;
    final roomId = roomIdFromUri(uri);
    return roomId == null ? null : RoomInvitation(roomId, role: role);
  } on FormatException {
    return null;
  }
}

/// Accepts raw IDs, web links, and legacy JSON; missing roles mean guest.
RoomInvitation? parseRoomInvitation(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri != null && _isWebUri(uri)) return roomInvitationFromUri(uri);
  if (trimmed.startsWith('{')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map || decoded['peerId'] is! String) return null;
      if (_hasDuplicateJsonRole(trimmed)) return null;
      final roomId = (decoded['peerId'] as String).trim();
      final role = decoded.containsKey('role')
          ? parseRoomRole(decoded['role'])
          : RoomRole.guest;
      if (roomId.isEmpty || role == null) return null;
      return RoomInvitation(roomId, role: role);
    } on FormatException {
      return null;
    }
  }
  return RoomInvitation(trimmed);
}

bool _hasDuplicateJsonRole(String source) {
  // JSON decoders discard duplicate keys, including before revivers on web.
  // Scan the already valid JSON's top-level keys, skipping strings and nesting.
  final tokens = RegExp(r'("(?:[^"\\]|\\.)*")(\s*:)?|[{}\[\]]');
  var depth = 0;
  var roleCount = 0;
  for (final match in tokens.allMatches(source)) {
    switch (match[0]) {
      case '{' || '[':
        depth++;
      case '}' || ']':
        depth--;
      default:
        if (depth == 1 &&
            match[2] != null &&
            jsonDecode(match[1]!) == 'role' &&
            ++roleCount > 1) {
          return true;
        }
    }
  }
  return false;
}

/// Accepts room links, legacy JSON QR codes, and manually entered IDs.
String? parseRoomId(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri != null && _isWebUri(uri)) return roomIdFromUri(uri);
  if (trimmed.startsWith('{')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map && decoded['peerId'] is String) {
        final roomId = (decoded['peerId'] as String).trim();
        return roomId.isEmpty ? null : roomId;
      }
    } on FormatException {
      return null;
    }
    return null;
  }
  return trimmed;
}
