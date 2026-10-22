import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'room_document.dart';
import 'room_identity.dart';

const maxRoomTransferBytes = 8 * 1024 * 1024;
const _smallMessageBytes = 12000;
const _chunkBytes = 8000;

enum RoomMessageType {
  hello,
  welcome,
  edits,
  presence,
  inventory,
  checkpoint,
  syncAck,
  diskCredentials,
}

// RoomEdit and its author base are immutable. Weak, per-object caching avoids
// rehashing large photo payloads without trusting an ID shared by another record.
final _editDigests = Expando<String>('roomEditDigest');

/// Fingerprints use a fixed field order, never an incoming map's insertion order.
String roomEditDigest(RoomEdit edit) => _editDigests[edit] ??= sha256
    .convert(
      utf8.encode(
        jsonEncode([
          edit.id,
          edit.author,
          edit.clock,
          edit.createdAt,
          edit.text,
          if (edit.kind != RoomEditKind.text) edit.kind.name,
          if (edit.targetActor != null) edit.targetActor,
          if (edit.authorSequence != null)
            [edit.authorSequence, edit.authorPrevious, edit.authorBase],
        ]),
      ),
    )
    .toString();

Map<String, String> roomHistoryInventory(Iterable<RoomEdit> history) {
  final inventory = <String, String>{};
  for (final edit in history) {
    final digest = roomEditDigest(edit);
    final previous = inventory[edit.id];
    if (previous != null && previous != digest) {
      throw const FormatException('ID изменения не является неизменяемым');
    }
    inventory[edit.id] = digest;
  }
  return Map.unmodifiable(inventory);
}

String roomHistoryDigest(Iterable<RoomEdit> history) =>
    roomInventoryDigest(roomHistoryInventory(history));

String roomInventoryDigest(Map<String, String> inventory) {
  final ids = inventory.keys.toList()..sort();
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            for (final id in ids) [id, inventory[id]],
          ]),
        ),
      )
      .toString();
}

/// Checks every shared ID before returning a diff. The journal can also supply
/// known nondurable edits here for validation, but only durable diffs are sent.
List<RoomEdit> missingRoomEdits(
  Iterable<RoomEdit> local,
  Map<String, String> remoteInventory,
) {
  final missing = <RoomEdit>[];
  for (final edit in local) {
    final remote = remoteInventory[edit.id];
    if (remote == null) {
      missing.add(edit);
    } else if (remote != roomEditDigest(edit)) {
      throw const FormatException('Попытка заменить уже сохранённое изменение');
    }
  }
  return missing;
}

/// Resolves a frozen logical set (or newly announced tails) against canonical
/// durable records, then includes each author's entire predecessor/base closure.
/// A remote inventory is not evidence that it is safe to omit predecessors.
List<RoomEdit> completeRoomAuthorHistory(
  Iterable<RoomEdit> selected,
  Iterable<RoomEdit> durableHistory,
) {
  final durable = <String, RoomEdit>{};
  for (final edit in durableHistory) {
    final previous = durable[edit.id];
    if (previous != null && !previous.sameContentAs(edit)) {
      throw const FormatException('ID изменения не является неизменяемым');
    }
    durable[edit.id] = edit;
  }
  final pending = <String>[];
  for (final edit in selected) {
    final canonical = durable[edit.id];
    if (canonical == null ||
        !edit.sameCoreAs(canonical) ||
        (edit.authorSequence != null && !edit.sameContentAs(canonical))) {
      throw const FormatException('Нет неизменяемого сохранённого изменения');
    }
    pending.add(edit.id);
  }
  final included = <String, RoomEdit>{};
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (included.containsKey(id)) continue;
    final edit = durable[id];
    if (edit == null) {
      throw const FormatException('Предыдущее изменение автора не сохранено');
    }
    included[id] = edit;
    if (edit.authorPrevious != null) pending.add(edit.authorPrevious!);
    if (edit.authorBase != null) pending.addAll(edit.authorBase!);
  }
  return orderAuthorHistory(included.values);
}

bool _isDigest(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

/// Validated message data; channel admission and membership are not protocol
/// decisions. Optional fast-sync fields extend the legacy version-1 envelope.
class RoomMessage {
  RoomMessage({
    required this.roomId,
    required this.type,
    required this.actor,
    required List<RoomEdit> history,
    this.online,
    this.hosting,
    this.fastSync = false,
    this.historyDigest,
    this.durableSync = false,
    this.roomMetadata = false,
    this.roomRoles = false,
    this.familyTree = false,
    this.familySurnames = false,
    this.personalSurnames = false,
    this.explicitSiblings = false,
    this.patronymics = false,
    this.lifeStatus = false,
    this.authorHistory = false,
    this.participantIdentity = false,
    this.diskSync = false,
    this.diskBindingId,
    this.diskToken,
    this.syncId,
    this.syncDigest,
    this.roomReady,
    List<String>? onlineActors,
    Map<String, String>? inventory,
  }) : history = List.unmodifiable(history),
       onlineActors = onlineActors == null
           ? null
           : List.unmodifiable(onlineActors),
       inventory = inventory == null ? null : Map.unmodifiable(inventory);

  final String roomId;
  final RoomMessageType type;
  final String actor;
  final List<RoomEdit> history;
  final int? online;
  final List<String>? onlineActors;
  final bool? hosting;
  final bool fastSync;
  final String? historyDigest;

  /// Negotiated only in hello/welcome. Legacy v1 peers ignore this field and
  /// must never receive the new checkpoint/ack message types.
  final bool durableSync;

  /// Metadata edit kinds are unsafe for legacy readers that ignore `kind`.
  /// Negotiate this capability before sending any non-text operation.
  final bool roomMetadata;

  /// Separate hello/welcome capability: metadata-aware legacy readers still
  /// cannot interpret participant roles or enforce guest/editor permissions.
  final bool roomRoles;

  /// Character-anchored text, family relationships and person bindings.
  final bool familyTree;

  /// Separate hello/welcome capability: older tree readers reject surname edits.
  final bool familySurnames;

  /// Per-person surnames: any individual register, including a null clear,
  /// overrides historical shared family fallback. Wire payloads are unchanged.
  final bool personalSurnames;

  /// Atomic sibling creation, exact-claim unlink, and component-wide parents.
  final bool explicitSiblings;

  /// Room-wide patronymic dictionary overrides, including explicit resets.
  final bool patronymics;

  /// Explicit living/unknown death mark. Older readers reject the `alive` field.
  final bool lifeStatus;

  /// Complete, contiguous same-author history proofs. Legacy readers discard
  /// these fields and must never receive proof-bearing records.
  final bool authorHistory;

  /// Empty participant aliases and claim-specific, reversible person bindings.
  /// Older readers reject these records or retain a released identity forever.
  final bool participantIdentity;

  /// Hello/welcome-only support for private disk credential messages. Channel
  /// readiness, durability and both participants' editor roles are session rules.
  final bool diskSync;

  /// Ephemeral credentials, never part of history or a normal message envelope.
  /// These fields are serialized only for [RoomMessageType.diskCredentials].
  final String? diskBindingId;
  final String? diskToken;
  final String? syncId;
  final String? syncDigest;
  final bool? roomReady;
  final Map<String, String>? inventory;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'roomId': roomId,
    'type': type.name,
    'actor': actor,
    'history': history.map((edit) => edit.toJson()).toList(),
    if (online != null) 'online': online,
    if (onlineActors != null) 'onlineActors': onlineActors,
    if (hosting != null) 'hosting': hosting,
    if (fastSync) 'fastSync': true,
    if (historyDigest != null) 'historyDigest': historyDigest,
    if (durableSync) 'durableSync': true,
    if (roomMetadata) 'roomMetadata': true,
    if (roomRoles) 'roomRoles': true,
    if (familyTree) 'familyTree': true,
    if (familySurnames) 'familySurnames': true,
    if (personalSurnames) 'personalSurnames': true,
    if (explicitSiblings) 'explicitSiblings': true,
    if (patronymics) 'patronymics': true,
    if (lifeStatus) 'lifeStatus': true,
    if (authorHistory) 'authorHistory': true,
    if (participantIdentity) 'participantIdentity': true,
    if (diskSync) 'diskSync': true,
    if (type == RoomMessageType.diskCredentials) ...{
      if (diskBindingId != null) 'diskBindingId': diskBindingId,
      if (diskToken != null) 'diskToken': diskToken,
    },
    if (syncId != null) 'syncId': syncId,
    if (syncDigest != null) 'syncDigest': syncDigest,
    if (roomReady != null) 'roomReady': roomReady,
    if (inventory != null) 'inventory': inventory,
  };
}

RoomMessage decodeRoomMessage(Object? value, {required String roomId}) {
  if (value is! Map ||
      value['v'] != 1 ||
      value['v'] is! int ||
      value['roomId'] != roomId ||
      !isValidRoomActor(value['actor']) ||
      value['history'] is! List) {
    throw const FormatException('Неверный формат сообщения');
  }
  final RoomMessageType type;
  switch (value['type']) {
    case 'hello':
      type = RoomMessageType.hello;
    case 'welcome':
      type = RoomMessageType.welcome;
    case 'edits':
      type = RoomMessageType.edits;
    case 'presence':
      type = RoomMessageType.presence;
    case 'inventory':
      type = RoomMessageType.inventory;
    case 'checkpoint':
      type = RoomMessageType.checkpoint;
    case 'syncAck':
      type = RoomMessageType.syncAck;
    case 'diskCredentials':
      type = RoomMessageType.diskCredentials;
    default:
      throw const FormatException('Неверный формат сообщения');
  }
  final online = value['online'];
  final hosting = value['hosting'];
  final presence =
      type == RoomMessageType.welcome || type == RoomMessageType.presence;
  if (presence &&
      (online is! int || online < 1 || online > 100000 || hosting is! bool)) {
    throw const FormatException('Неверный список участников');
  }
  List<String>? onlineActors;
  if (value.containsKey('onlineActors')) {
    final rawActors = value['onlineActors'];
    if (!presence || rawActors is! List || rawActors.length > 10000) {
      throw const FormatException('Неверный список участников');
    }
    final actors = <String>{};
    for (final actor in rawActors) {
      if (!isValidRoomActor(actor) || !actors.add(actor as String)) {
        throw const FormatException('Неверный участник');
      }
    }
    if (online != null && actors.length != online) {
      throw const FormatException('Число участников не соответствует списку');
    }
    onlineActors = actors.toList();
  }
  final fastSync = value['fastSync'] ?? false;
  final digest = value['historyDigest'];
  final rawInventory = value['inventory'];
  final handshake =
      type == RoomMessageType.hello || type == RoomMessageType.welcome;
  final roomMetadata = value['roomMetadata'] ?? false;
  if (roomMetadata is! bool ||
      (value.containsKey('roomMetadata') && value['roomMetadata'] is! bool) ||
      (roomMetadata && !handshake)) {
    throw const FormatException('Неверная поддержка метаданных комнаты');
  }
  final roomRoles = value['roomRoles'] ?? false;
  if (roomRoles is! bool ||
      (value.containsKey('roomRoles') && value['roomRoles'] is! bool) ||
      (roomRoles && !handshake)) {
    throw const FormatException('Неверная поддержка ролей комнаты');
  }
  final familyTree = value['familyTree'] ?? false;
  if (familyTree is! bool ||
      (value.containsKey('familyTree') && value['familyTree'] is! bool) ||
      (familyTree && !handshake)) {
    throw const FormatException('Неверная поддержка семейного дерева');
  }
  final familySurnames = value['familySurnames'] ?? false;
  if (familySurnames is! bool ||
      (value.containsKey('familySurnames') &&
          value['familySurnames'] is! bool) ||
      (familySurnames && !handshake)) {
    throw const FormatException('Неверная поддержка фамилий семейного дерева');
  }
  final personalSurnames = value['personalSurnames'] ?? false;
  if (personalSurnames is! bool ||
      (value.containsKey('personalSurnames') &&
          value['personalSurnames'] is! bool) ||
      (personalSurnames && !handshake)) {
    throw const FormatException('Неверная поддержка личных фамилий');
  }
  final explicitSiblings = value['explicitSiblings'] ?? false;
  if (explicitSiblings is! bool ||
      (value.containsKey('explicitSiblings') &&
          value['explicitSiblings'] is! bool) ||
      (explicitSiblings && !handshake)) {
    throw const FormatException(
      'Неверная поддержка прямых связей братьев и сестёр',
    );
  }
  final patronymics = value['patronymics'] ?? false;
  if (patronymics is! bool ||
      (value.containsKey('patronymics') && value['patronymics'] is! bool) ||
      (patronymics && !handshake)) {
    throw const FormatException('Неверная поддержка отчеств');
  }
  final lifeStatus = value['lifeStatus'] ?? false;
  if (lifeStatus is! bool ||
      (value.containsKey('lifeStatus') && value['lifeStatus'] is! bool) ||
      (lifeStatus && !handshake)) {
    throw const FormatException('Неверная поддержка отметки о жизни');
  }
  final authorHistory = value['authorHistory'] ?? false;
  if (authorHistory is! bool ||
      (value.containsKey('authorHistory') && value['authorHistory'] is! bool) ||
      (authorHistory && !handshake)) {
    throw const FormatException('Неверная поддержка истории автора');
  }
  final participantIdentity = value['participantIdentity'] ?? false;
  if (participantIdentity is! bool ||
      (value.containsKey('participantIdentity') &&
          value['participantIdentity'] is! bool) ||
      (participantIdentity && !handshake)) {
    throw const FormatException('Неверная поддержка профилей участников');
  }
  final diskSync = value['diskSync'] ?? false;
  if (diskSync is! bool ||
      (value.containsKey('diskSync') && value['diskSync'] is! bool) ||
      (diskSync && !handshake)) {
    throw const FormatException('Неверная поддержка синхронизации диска');
  }
  final credentials = type == RoomMessageType.diskCredentials;
  final diskBindingId = value['diskBindingId'];
  final diskToken = value['diskToken'];
  if (credentials
      ? !isValidRoomActor(diskBindingId) ||
            diskToken is! String ||
            diskToken.isEmpty ||
            diskToken.length > 4096 ||
            diskToken.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)
      : value.containsKey('diskBindingId') || value.containsKey('diskToken')) {
    // Never include a token, or its enclosing source message, in an error.
    throw const FormatException('Неверные данные подключения диска');
  }
  if (fastSync is! bool ||
      (value.containsKey('fastSync') && value['fastSync'] is! bool) ||
      (fastSync && (!handshake || !_isDigest(digest))) ||
      (!fastSync && value.containsKey('historyDigest')) ||
      (type != RoomMessageType.inventory &&
          type != RoomMessageType.checkpoint &&
          value.containsKey('inventory'))) {
    throw const FormatException('Неверный формат быстрой синхронизации');
  }
  final durableSync = value['durableSync'] ?? false;
  final syncId = value['syncId'];
  final syncDigest = value['syncDigest'];
  final roomReady = value['roomReady'];
  final checkpoint = type == RoomMessageType.checkpoint;
  final ack = type == RoomMessageType.syncAck;
  if (durableSync is! bool ||
      (value.containsKey('durableSync') &&
          (!handshake || value['durableSync'] is! bool)) ||
      ((checkpoint || ack) &&
          (syncId is! String ||
              !isValidRoomId(syncId) ||
              !_isDigest(syncDigest))) ||
      (!(checkpoint || ack) &&
          (value.containsKey('syncId') || value.containsKey('syncDigest'))) ||
      (ack && roomReady is! bool) ||
      (!ack && value.containsKey('roomReady'))) {
    throw const FormatException('Неверное подтверждение сохранения');
  }
  Map<String, String>? inventory;
  if (type == RoomMessageType.inventory ||
      (checkpoint && value.containsKey('inventory'))) {
    if (rawInventory is! Map || fastSync) {
      throw const FormatException('Неверный список изменений');
    }
    inventory = <String, String>{};
    for (final entry in rawInventory.entries) {
      if (!isValidRoomActor(entry.key) || !_isDigest(entry.value)) {
        throw const FormatException('Неверная запись списка изменений');
      }
      inventory[entry.key as String] = entry.value as String;
    }
  }
  if (checkpoint &&
      inventory != null &&
      roomInventoryDigest(inventory) != syncDigest) {
    throw const FormatException('Список не соответствует контрольной точке');
  }
  final history = decodeRoomHistory(value['history']);
  if ((type == RoomMessageType.presence ||
          type == RoomMessageType.inventory ||
          checkpoint ||
          ack ||
          credentials) &&
      history.isNotEmpty) {
    throw const FormatException('История должна передаваться отдельно');
  }
  if (fastSync &&
      (history.length > 1 ||
          history.any((edit) => edit.kind != RoomEditKind.text))) {
    throw const FormatException('Быстрое подтверждение содержит только текст');
  }
  return RoomMessage(
    roomId: roomId,
    type: type,
    actor: value['actor'] as String,
    history: history,
    online: online as int?,
    onlineActors: onlineActors,
    hosting: hosting as bool?,
    fastSync: fastSync,
    historyDigest: digest as String?,
    durableSync: durableSync,
    roomMetadata: roomMetadata,
    roomRoles: roomRoles,
    familyTree: familyTree,
    familySurnames: familySurnames,
    personalSurnames: personalSurnames,
    explicitSiblings: explicitSiblings,
    patronymics: patronymics,
    lifeStatus: lifeStatus,
    authorHistory: authorHistory,
    participantIdentity: participantIdentity,
    diskSync: diskSync,
    diskBindingId: diskBindingId as String?,
    diskToken: diskToken as String?,
    syncId: syncId as String?,
    syncDigest: syncDigest as String?,
    roomReady: roomReady as bool?,
    inventory: inventory,
  );
}

/// Checks the total UTF-8 size immediately; large transfers generate bounded
/// base64 packets lazily as the channel sends them, not a second full history.
Iterable<Map<String, dynamic>> encodeRoomMessage(RoomMessage message) {
  final value = message.toJson();
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value)));
  if (bytes.length > maxRoomTransferBytes) {
    throw const FormatException('История превышает предел синхронизации 8 МиБ');
  }
  if (bytes.length <= _smallMessageBytes) return [value];
  return _fragmentMessage(message, bytes);
}

Iterable<Map<String, dynamic>> _fragmentMessage(
  RoomMessage message,
  Uint8List bytes,
) sync* {
  final transfer = createRoomId();
  final count = (bytes.length + _chunkBytes - 1) ~/ _chunkBytes;
  for (var index = 0; index < count; index++) {
    final start = index * _chunkBytes;
    yield {
      'v': 1,
      'roomId': message.roomId,
      'type': 'chunk',
      'actor': message.actor,
      'transfer': transfer,
      'index': index,
      'count': count,
      'bytes': bytes.length,
      'data': base64Encode(
        bytes.sublist(start, min(start + _chunkBytes, bytes.length)),
      ),
    };
  }
}

/// Decoder facts let the coordinator apply its handshake/transfer/liveness
/// timers without moving channel lifecycle into the protocol. An identical
/// duplicate fragment is not newly accepted and must not renew liveness.
class RoomPacketResult {
  const RoomPacketResult({
    this.message,
    this.startedTransfer = false,
    this.acceptedFragment = false,
    this.completedTransfer = false,
  });

  final RoomMessage? message;
  final bool startedTransfer;
  final bool acceptedFragment;
  final bool completedTransfer;
}

/// One bounded in-flight assembly per channel. No networking or timers: the
/// session owns deadlines and calls [reset] when retiring that channel.
class RoomMessageDecoder {
  RoomMessageDecoder({required this.roomId});

  final String roomId;
  _Assembly? _assembly;

  bool get assembling => _assembly != null;

  RoomPacketResult decode(Object? data, {String? expectedActor}) {
    if (data is String) {
      if (utf8.encode(data).length > maxRoomTransferBytes) {
        throw const FormatException('Слишком большое сообщение');
      }
      data = _decodeMessageJson(data);
    }
    if (data is! Map ||
        data['v'] != 1 ||
        data['v'] is! int ||
        data['roomId'] != roomId) {
      throw const FormatException('Неверная версия или ID комнаты');
    }
    if (data['type'] == 'chunk') {
      return _acceptChunk(data, expectedActor: expectedActor);
    }
    if (utf8.encode(jsonEncode(data)).length > maxRoomTransferBytes) {
      throw const FormatException('Слишком большое сообщение');
    }
    return RoomPacketResult(message: decodeRoomMessage(data, roomId: roomId));
  }

  RoomPacketResult _acceptChunk(Map chunk, {String? expectedActor}) {
    final transfer = chunk['transfer'];
    final actor = chunk['actor'];
    final index = chunk['index'];
    final count = chunk['count'];
    final bytes = chunk['bytes'];
    final data = chunk['data'];
    if (transfer is! String ||
        !isValidRoomId(transfer) ||
        !isValidRoomActor(actor) ||
        (expectedActor != null && expectedActor != actor) ||
        index is! int ||
        count is! int ||
        bytes is! int ||
        data is! String ||
        bytes <= _smallMessageBytes ||
        bytes > maxRoomTransferBytes ||
        count != (bytes + _chunkBytes - 1) ~/ _chunkBytes ||
        index < 0 ||
        index >= count ||
        data.length > 11000) {
      throw const FormatException('Неверный фрагмент истории');
    }
    final decoded = base64Decode(data);
    if (decoded.length != min(_chunkBytes, bytes - index * _chunkBytes)) {
      throw const FormatException('Неверная длина фрагмента');
    }
    var assembly = _assembly;
    final started = assembly == null;
    if (assembly == null) {
      assembly = _Assembly(transfer, actor as String, bytes, count);
      _assembly = assembly;
    }
    if (assembly.id != transfer ||
        assembly.actor != actor ||
        assembly.bytes != bytes ||
        assembly.parts.length != count) {
      throw const FormatException('Перемешанные передачи истории');
    }
    final previous = assembly.parts[index];
    if (previous != null) {
      if (!_sameBytes(previous, decoded)) {
        throw const FormatException('Фрагмент изменился');
      }
      return const RoomPacketResult();
    }
    assembly.parts[index] = decoded;
    assembly.received++;
    if (assembly.received != count) {
      return RoomPacketResult(startedTransfer: started, acceptedFragment: true);
    }
    final builder = BytesBuilder(copy: false);
    for (final part in assembly.parts) {
      builder.add(part!);
    }
    _assembly = null;
    final value = _decodeMessageJson(
      utf8.decode(builder.takeBytes(), allowMalformed: false),
    );
    if (value is! Map || value['actor'] != actor) {
      throw const FormatException('Автор передачи не совпадает');
    }
    // Validate the inner envelope again, including room/version and history.
    return RoomPacketResult(
      message: decodeRoomMessage(value, roomId: roomId),
      startedTransfer: started,
      acceptedFragment: true,
      completedTransfer: true,
    );
  }

  void reset() => _assembly = null;
}

Object? _decodeMessageJson(String source) {
  try {
    return jsonDecode(source);
  } on FormatException {
    // JSON syntax exceptions retain the source, which may contain credentials.
    throw const FormatException('Неверный JSON сообщения');
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

class _Assembly {
  _Assembly(this.id, this.actor, this.bytes, int count)
    : parts = List<Uint8List?>.filled(count, null);
  final String id;
  final String actor;
  final int bytes;
  final List<Uint8List?> parts;
  int received = 0;
}
