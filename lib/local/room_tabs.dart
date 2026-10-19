import '../room_identity.dart';

/// Same-origin tabs share durable storage and one network session per room.
/// This is a local lifecycle boundary, not membership or a second database.
abstract interface class RoomTabs {
  bool get isLeader;
  Stream<void> get onRoleChanged;
  Stream<RoomTabState> get onState;
  Future<void> start();
  void publish(RoomTabState state);
  void requestState();
  void dispose();
}

typedef RoomTabsFactory = RoomTabs? Function(String roomId, String actorId);

/// An accepted tab's checkpoint. Followers verify its immutable inventory in
/// shared storage before inheriting readiness; a message alone is insufficient.
class RoomTabState {
  RoomTabState({
    required this.roomId,
    required this.actorId,
    required this.onlineCount,
    required this.initialSyncComplete,
    required this.localCopyOpened,
    required this.status,
    required this.initialSyncStatus,
    required Map<String, String> inventory,
    this.initialSyncError,
    this.networkAvailable = false,
    List<String>? onlineActors,
  }) : inventory = Map.unmodifiable(inventory),
       onlineActors = onlineActors == null
           ? null
           : List.unmodifiable(onlineActors);

  final String roomId;
  final String actorId;
  final int onlineCount;
  final bool networkAvailable;
  final List<String>? onlineActors;
  final bool initialSyncComplete;
  final bool localCopyOpened;
  final String status;
  final String initialSyncStatus;
  final String? initialSyncError;
  final Map<String, String> inventory;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'roomId': roomId,
    'actorId': actorId,
    'onlineCount': onlineCount,
    'networkAvailable': networkAvailable,
    if (onlineActors != null) 'onlineActors': onlineActors,
    'initialSyncComplete': initialSyncComplete,
    'localCopyOpened': localCopyOpened,
    'status': status,
    'initialSyncStatus': initialSyncStatus,
    'initialSyncError': initialSyncError,
    'inventory': inventory,
  };

  static RoomTabState? fromJson(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['v'] is! int ||
        value['roomId'] is! String ||
        !isValidRoomId(value['roomId'] as String) ||
        !isValidRoomActor(value['actorId']) ||
        value['onlineCount'] is! int ||
        (value['onlineCount'] as int) < 1 ||
        (value['onlineCount'] as int) > 100000 ||
        value['initialSyncComplete'] is! bool ||
        value['localCopyOpened'] is! bool ||
        value['status'] is! String ||
        (value['status'] as String).length > 4096 ||
        value['initialSyncStatus'] is! String ||
        (value['initialSyncStatus'] as String).length > 4096 ||
        (value['initialSyncError'] != null &&
            (value['initialSyncError'] is! String ||
                (value['initialSyncError'] as String).length > 4096)) ||
        value['inventory'] is! Map) {
      return null;
    }
    final network = value.containsKey('networkAvailable')
        ? value['networkAvailable']
        : false;
    if (network is! bool) return null;
    List<String>? onlineActors;
    if (value.containsKey('onlineActors')) {
      final actors = value['onlineActors'];
      if (actors is! List ||
          actors.length > 10000 ||
          actors.any((actor) => !isValidRoomActor(actor)) ||
          actors.toSet().length != actors.length ||
          (network &&
              (actors.length != value['onlineCount'] ||
                  !actors.contains(value['actorId']))) ||
          (!network && actors.isNotEmpty)) {
        return null;
      }
      onlineActors = actors.cast<String>();
    }
    final inventory = <String, String>{};
    for (final entry in (value['inventory'] as Map).entries) {
      if (!isValidRoomActor(entry.key) ||
          entry.value is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.value as String)) {
        return null;
      }
      inventory[entry.key as String] = entry.value as String;
    }
    return RoomTabState(
      roomId: value['roomId'] as String,
      actorId: value['actorId'] as String,
      onlineCount: value['onlineCount'] as int,
      networkAvailable: network,
      onlineActors: onlineActors,
      initialSyncComplete: value['initialSyncComplete'] as bool,
      localCopyOpened: value['localCopyOpened'] as bool,
      status: value['status'] as String,
      initialSyncStatus: value['initialSyncStatus'] as String,
      initialSyncError: value['initialSyncError'] as String?,
      inventory: inventory,
    );
  }
}
