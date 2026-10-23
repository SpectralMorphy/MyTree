# October 23, 2026 — Toolbar order and birth-surname row

The shared editor/picker toolbar now places **ИФ / ФИО** before the zoom group. Biography history prepends the known birth surname with **при рождении** only when its existing chronological projection contains an actual surname change. It uses the sex-specific canonical birth surname, including father inheritance; marriages and no-change reasons remain visible. No protocol or stored format changed.

## Automated checks

- `flutter analyze`: no issues.
- Focused history/editor suites: **268 passed**.
- Complete `flutter test`: **2294 passed, 2 skipped**.
- Release web build with local renderer resources: passed; the existing missing-CupertinoIcons-font warning remains.
- Static-server tests: **4 passed**; both changed browser drivers pass Node syntax checks.

Release `main.dart.js` SHA-256: `d17d492f15841ef37f8ea9a29f47fe63a66b317f97035d863b792efaa8ed6461`.

## Actual headless browser check

[Focused attempt E](../build/toolbar-birth-surnames-20261023-e/report.json) passed `local toolbar-birth` in independent **1440×1100 desktop** and **390×844 touch-emulated** Chrome profiles. All four actual initial/reloaded bundle bodies matched the release hash, without service workers. Off-origin requests and WebSockets were blocked; ordinary explicit unconfirmed-local-copy gates were used, not simulated network readiness.

Both viewports verified name-format-before-zoom hit-box order, actual ИФ/ФИО switching and 110%/100% zoom without journal writes. The real biography showed **Смирнова / при рождении** before the changed surname. Confirmed removal of the sole implied marriage removed the extra birth row. Each complete journal retained all original records and exactly one removal (22 records), validated author prefixes, and survived a real reload without additional records; the birth row stayed absent. There were no page/console/Flutter errors. Desktop toolbar, phone birth-history and phone single-surname reload PNGs were inspected.

Attempts A/B stopped on a harness geometry assertion: Flutter's native search-textbox semantics extend 8 px beyond the painted field. The focused check now records that raw rectangle but strictly bounds the changed button controls and checks the search origin/order, not its inflated native width. Attempt C reached both toolbar interactions and the visible phone birth history, then stopped on the merged section's scroll-box geometry. Attempt D stopped on reading biography semantics before the route finished building. These remain partial, preserved beside E; production code was unchanged during all browser attempts. The focused case waits for actual biography content and avoids the unrelated merged-section scrolling prerequisite.

This run does not establish public RTC/cloud synchronization, physical-phone behavior, or the broader marriage/date/new-partner browser scenario. All owned browser contexts and the local server were closed. No commit, deployment or external publication was performed.
