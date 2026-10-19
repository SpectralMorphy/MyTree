import 'dart:convert';

// Shared on-disk/browser encoding. Room and operation IDs are opaque, so never
// put their raw contents in paths or delimit keys with unescaped IDs.
String encodeStoreKey(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

void requireRoomId(String roomId) {
  if (roomId.trim().isEmpty) {
    throw ArgumentError.value(roomId, 'roomId', 'Must not be empty');
  }
}

String decodeStoredString(String encoded, String source) {
  final value = decodeStoredJson(encoded, source);
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Expected a nonempty string in $source');
  }
  return value;
}

Object? decodeStoredJson(String encoded, String source) {
  try {
    return jsonDecode(encoded);
  } on FormatException catch (error) {
    throw FormatException('Malformed JSON in $source: ${error.message}');
  }
}

/// A detached, canonical JSON snapshot, including the immutable operation ID.
class HistoryRecord {
  HistoryRecord(Map<String, dynamic> operation)
    : id = _readId(operation),
      encoded = jsonEncode(_canonicalJson(operation));

  factory HistoryRecord.decode(String encoded, String source) {
    final value = decodeStoredJson(encoded, source);
    if (value is! Map<String, dynamic>) {
      throw FormatException('Expected an operation object in $source');
    }
    try {
      return HistoryRecord(value);
    } on FormatException catch (error) {
      throw FormatException('Invalid operation in $source: ${error.message}');
    }
  }

  final String id;
  final String encoded;

  Map<String, dynamic> toJson() => jsonDecode(encoded) as Map<String, dynamic>;

  static String _readId(Map<String, dynamic> operation) {
    final id = operation['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Operation id must be a nonempty string');
    }
    return id;
  }
}

// Sorting object keys lets identical JSON compare equal even when callers
// construct their maps in different insertion orders. Reject non-JSON values.
Object? _canonicalJson(Object? value) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) {
    return value;
  }
  if (value is List) {
    return value.map(_canonicalJson).toList();
  }
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('JSON object keys must be strings');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, dynamic>{
      for (final key in keys) key: _canonicalJson(value[key]),
    };
  }
  throw FormatException('Unsupported JSON value: ${value.runtimeType}');
}

void addHistoryRecord(
  Map<String, HistoryRecord> history,
  HistoryRecord record,
) {
  final existing = history[record.id];
  if (existing != null && existing.encoded != record.encoded) {
    throw FormatException('Conflicting contents for operation id ${record.id}');
  }
  history.putIfAbsent(record.id, () => record);
}

/// Validate the entire batch before any write, including duplicate IDs in it.
List<HistoryRecord> newHistoryRecords(
  Map<String, HistoryRecord> existing,
  List<HistoryRecord> operations,
) {
  final additions = <String, HistoryRecord>{};
  for (final record in operations) {
    final previous = existing[record.id];
    if (previous != null) {
      if (previous.encoded != record.encoded) {
        throw FormatException(
          'Conflicting contents for operation id ${record.id}',
        );
      }
    } else {
      addHistoryRecord(additions, record);
    }
  }
  return additions.values.toList();
}
