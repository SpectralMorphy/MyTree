import 'dart:convert';
import 'dart:math';

/// An invitation's requested role, not authentication or a security boundary.
enum RoomRole { guest, editor }

RoomRole? parseRoomRole(Object? value) => switch (value) {
  'guest' => RoomRole.guest,
  'editor' => RoomRole.editor,
  _ => null,
};

const _maxDiskAccessJsonBytes = 32 * 1024;
const _maxDiskAccessEncodedLength = ((_maxDiskAccessJsonBytes + 2) ~/ 3) * 4;
final _controlCharacters = RegExp(r'[\x00-\x1f\x7f-\x9f]');

/// Offline Disk access for one immutable binding, not room authorization.
final class RoomDiskAccess {
  const RoomDiskAccess._(this.bindingId, {this.token, this.publicUrl});

  factory RoomDiskAccess.editor({
    required String bindingId,
    required String token,
  }) {
    if (!isValidRoomActor(bindingId) ||
        token.isEmpty ||
        token.length > 4096 ||
        token.trim() != token ||
        _controlCharacters.hasMatch(token)) {
      throw const FormatException('Invalid Disk access.');
    }
    return RoomDiskAccess._(bindingId, token: token);
  }

  factory RoomDiskAccess.guest({
    required String bindingId,
    required String publicUrl,
  }) {
    if (!isValidRoomActor(bindingId) || !isValidDiskPublicUrl(publicUrl)) {
      throw const FormatException('Invalid Disk access.');
    }
    final access = RoomDiskAccess._(bindingId, publicUrl: publicUrl);
    if (utf8.encode(jsonEncode(access.toJson())).length >
        _maxDiskAccessJsonBytes) {
      throw const FormatException('Invalid Disk access.');
    }
    return access;
  }

  /// Validates the decoded schema; invitation parsers also check raw key repeats.
  factory RoomDiskAccess.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 3 ||
        value['v'] is! int ||
        value['v'] != 1 ||
        value['bindingId'] is! String) {
      throw const FormatException('Invalid Disk access.');
    }
    final bindingId = value['bindingId'] as String;
    if (value['token'] is String) {
      return RoomDiskAccess.editor(
        bindingId: bindingId,
        token: value['token'] as String,
      );
    }
    if (value['publicUrl'] is String) {
      return RoomDiskAccess.guest(
        bindingId: bindingId,
        publicUrl: value['publicUrl'] as String,
      );
    }
    throw const FormatException('Invalid Disk access.');
  }

  final String bindingId;
  final String? token;
  final String? publicUrl;

  bool get isEditor => token != null;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'bindingId': bindingId,
    if (isEditor) 'token': token else 'publicUrl': publicUrl,
  };

  @override
  bool operator ==(Object other) =>
      other is RoomDiskAccess &&
      bindingId == other.bindingId &&
      token == other.token &&
      publicUrl == other.publicUrl;

  @override
  int get hashCode => Object.hash(bindingId, token, publicUrl);
}

/// Accepts only HTTPS Yandex Disk share URLs, never arbitrary download hosts.
bool isValidDiskPublicUrl(String value) {
  const hosts = {'disk.yandex.ru', 'disk.yandex.com', 'yadi.sk'};
  if (value.isEmpty ||
      value.length > _maxDiskAccessJsonBytes ||
      value.trim() != value ||
      value.contains('\\') ||
      _controlCharacters.hasMatch(value) ||
      RegExp(r'^https://[^/?#]*@', caseSensitive: false).hasMatch(value)) {
    return false;
  }
  try {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.authority.contains('@') ||
        uri.hasFragment ||
        !hosts.contains(uri.host)) {
      return false;
    }
    final segments = uri.pathSegments;
    return segments.length >= 2 &&
        segments.first == 'd' &&
        segments[1].isNotEmpty &&
        segments.every(
          (segment) =>
              segment != '.' &&
              segment != '..' &&
              !segment.contains('/') &&
              !segment.contains('\\') &&
              !_controlCharacters.hasMatch(segment),
        );
  } on FormatException {
    return false;
  }
}

/// A room identity and its requested role; ID validation remains with callers.
class RoomInvitation {
  const RoomInvitation(
    this.roomId, {
    this.role = RoomRole.guest,
    this.diskAccess,
  });

  final String roomId;
  final RoomRole role;
  final RoomDiskAccess? diskAccess;

  @override
  bool operator ==(Object other) =>
      other is RoomInvitation &&
      roomId == other.roomId &&
      role == other.role &&
      diskAccess == other.diskAccess;

  @override
  int get hashCode => Object.hash(roomId, role, diskAccess);
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

bool _diskAccessMatchesRole(RoomRole role, RoomDiskAccess? diskAccess) =>
    diskAccess == null || diskAccess.isEditor == (role == RoomRole.editor);

/// Preserves the hosting path and keeps invitation data out of HTTP requests.
String? createRoomLink(
  Uri applicationUri,
  String roomId, {
  RoomRole? role,
  RoomDiskAccess? diskAccess,
}) {
  if (!_diskAccessMatchesRole(role ?? RoomRole.guest, diskAccess)) {
    throw const FormatException('Invalid invitation Disk access.');
  }
  if (!_isWebUri(applicationUri)) return null;
  final fragment = Uri(
    queryParameters: {
      'room': roomId,
      if (role != null) 'role': role.name,
      if (diskAccess != null)
        'disk': base64Url.encode(utf8.encode(jsonEncode(diskAccess.toJson()))),
    },
  ).query;
  return applicationUri.replace(fragment: fragment).toString();
}

String createRoomQrData(
  Uri applicationUri,
  String roomId, {
  RoomRole? role,
  RoomDiskAccess? diskAccess,
}) =>
    createRoomLink(
      applicationUri,
      roomId,
      role: role,
      diskAccess: diskAccess,
    ) ??
    jsonEncode(<String, dynamic>{
      'v': 1,
      'peerId': roomId,
      if (role != null) 'role': role.name,
      if (diskAccess != null) 'disk': diskAccess.toJson(),
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

/// Reads fragment-only invitations; malformed access never becomes ID-only.
RoomInvitation? roomInvitationFromUri(Uri uri) {
  if (!_isWebUri(uri) || uri.fragment.isEmpty) return null;
  try {
    final parameters = Uri(query: uri.fragment).queryParametersAll;
    for (final key in ['room', 'peer', 'role', 'disk']) {
      final values = parameters[key];
      if (values != null && values.length != 1) return null;
    }
    if (parameters.containsKey('room') && parameters.containsKey('peer')) {
      return null;
    }
    final roles = parameters['role'];
    final role = roles == null ? RoomRole.guest : parseRoomRole(roles.single);
    final roomId = (parameters['room'] ?? parameters['peer'])?.single.trim();
    if (roomId == null || roomId.isEmpty || role == null) return null;
    final disks = parameters['disk'];
    final diskAccess = disks == null ? null : _decodeDiskAccess(disks.single);
    if (!_diskAccessMatchesRole(role, diskAccess)) return null;
    return RoomInvitation(roomId, role: role, diskAccess: diskAccess);
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
  if (RegExp(r'^https?:', caseSensitive: false).hasMatch(trimmed)) return null;
  if (trimmed.startsWith('{')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map || decoded['peerId'] is! String) return null;
      if (_hasDuplicateJsonKeys(trimmed, invitation: true) ||
          decoded.containsKey('room') ||
          decoded.containsKey('peer')) {
        return null;
      }
      final roomId = (decoded['peerId'] as String).trim();
      final role = decoded.containsKey('role')
          ? parseRoomRole(decoded['role'])
          : RoomRole.guest;
      if (roomId.isEmpty || role == null) return null;
      final diskAccess = decoded.containsKey('disk')
          ? RoomDiskAccess.fromJson(decoded['disk'])
          : null;
      if (!_diskAccessMatchesRole(role, diskAccess)) return null;
      return RoomInvitation(roomId, role: role, diskAccess: diskAccess);
    } on FormatException {
      return null;
    }
  }
  return RoomInvitation(trimmed);
}

RoomDiskAccess _decodeDiskAccess(String value) {
  if (value.isEmpty ||
      value.length > _maxDiskAccessEncodedLength ||
      !RegExp(r'^[A-Za-z0-9_-]+={0,2}$').hasMatch(value)) {
    throw const FormatException('Invalid invitation Disk access.');
  }
  final bytes = base64Url.decode(value);
  if (bytes.length > _maxDiskAccessJsonBytes ||
      base64Url.encode(bytes).replaceAll('=', '') !=
          value.replaceAll('=', '')) {
    throw const FormatException('Invalid invitation Disk access.');
  }
  final source = utf8.decode(bytes);
  final decoded = jsonDecode(source);
  if (_hasDuplicateJsonKeys(source)) {
    throw const FormatException('Invalid invitation Disk access.');
  }
  return RoomDiskAccess.fromJson(decoded);
}

bool _hasDuplicateJsonKeys(String source, {bool invitation = false}) {
  // Decoders discard duplicate keys, including before revivers on web. Scan
  // already valid JSON, decoding escaped keys and skipping strings/nesting.
  // Legacy metadata stays permissive; the root security fields and the direct
  // disk object are strict. A standalone disk payload has no permissive keys.
  const securityFields = {'v', 'peerId', 'room', 'peer', 'role', 'disk'};
  final tokens = RegExp(r'("(?:[^"\\]|\\.)*")(\s*:)?|[{}\[\]]');
  final keys = <String>{};
  final diskKeys = <String>{};
  var depth = 0;
  var inDisk = false;
  for (final match in tokens.allMatches(source)) {
    switch (match[0]) {
      case '{' || '[':
        depth++;
      case '}' || ']':
        depth--;
      default:
        if (match[2] == null) continue;
        final key = jsonDecode(match[1]!) as String;
        if (depth == 1) {
          if ((!invitation || securityFields.contains(key)) && !keys.add(key)) {
            return true;
          }
          inDisk = invitation && key == 'disk';
          diskKeys.clear();
        } else if (inDisk && depth == 2 && !diskKeys.add(key)) {
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
