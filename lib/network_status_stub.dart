// Native connectivity is established by signaling/RTC, not an OS hint.
bool get networkOnlineHint => true;

Stream<bool> watchNetworkOnlineHint() => const Stream.empty();

Stream<bool> watchApplicationForeground() => const Stream.empty();

Stream<void> watchApplicationSuspension() => const Stream.empty();
