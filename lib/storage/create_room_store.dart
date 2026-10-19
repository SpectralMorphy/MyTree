import 'file_room_store.dart'
    if (dart.library.js_interop) 'web_room_store.dart'
    as platform;
import 'room_store.dart';

/// Browser localStorage on web, application-support-directory JSONL on native.
/// This never silently falls back to memory when persistence is unavailable.
RoomStore createRoomStore() => platform.createPlatformRoomStore();
