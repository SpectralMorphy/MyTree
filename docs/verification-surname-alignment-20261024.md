# October 24, 2026 — Aligned surname column in family history

## Implemented scope

Every surname first line in **Фамилии и браки** (birth row and actual changes) now reserves one date column sized for `00.00.0000` with tabular figures at the current text scale. An unknown change date is shown as **?**, like the unknown birth date, so birth, dated and undated surnames start at the same left edge. Rows without a surname change, marriage captions, the domain row order and all stored data are unchanged.

## Automated checks

`flutter analyze` found no issues. The complete `flutter test --concurrency 2` passed **2327 tests, 2 skipped**, including new 480px and 320px widget checks that the birth, undated and dated surnames have an identical left x and the date ends before it. The release web build (`--no-web-resources-cdn`) succeeded with the existing missing-CupertinoIcons-font warning; local `main.dart.js` SHA-256 `662b3c74600ca795e2eb8820969d3e96ce786c448751ef256a9191456a58e5b0`.

## Actual headless browser check

[Local attempt A](../build/surname-align-20261024-a/report.json) did not reach the app: the chosen port 52191 lies in a Windows-excluded TCP range, so the server never listened. [Attempt B](../build/surname-align-20261024-b/report.json) on port 52287 passed `local unknown-sex-ui` in independent 1440×1100 desktop and 390×844 phone profiles. All four bundle bodies matched the hash above, without service workers; off-origin requests and WebSockets were blocked. The fixture adds one undated surname change; both semantics snapshots show **? Орлова Без даты**, and the inspected screenshots show **Смирнова**, **Орлова** and **Какой-тоа** starting at the same x on desktop and phone. Alignment in the browser is screenshot evidence; exact geometry is asserted by the widget tests. Blue unknown-sex ring pixels remained [37,99,235], the 26-record journals stayed equal across real reload (SHA-256 `e401e9985a13452eb51d7c4c7d285fcbfe15e347d03ea4b556b9b03b2a436d06`), and no application errors occurred.

No network synchronization or deployment is claimed. No commit or push was performed.
