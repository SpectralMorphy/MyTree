# October 22, 2026 — Derived patronymics and name presentation

## Implemented scope

Patronymics are computed from the accepted immediate father's given-name text and the child's sex. The pure algorithm uses a built-in exception dictionary and atomic room-wide overrides; unknown sex, no accepted father or unsupported names produce no patronymic. Overrides and resets use ordinary immutable tree journal operations, independently of person/root lifetime. No editable or persisted per-person patronymic field, automatic name parsing or migration was added.

The shared toolbar selects local **ИФ** (given name, surname) or **ФИО** (surname, given name, computed patronymic). Existing given-name-only canvas cards remain unchanged. Full-name UI consumers use the selected mode, except both normal and existing-person-picker searches, which always match and display ФИО. Explicit participant aliases are not reformatted. The room menu exposes **Словарь отчеств** directly below **Настройки комнаты**; guests can read it, editors can add/change/reset entries. Failed optimistic saving retries the original immutable core even if a remote dictionary entry has since won.

The new `patronymics` handshake capability is required by the production tree profile, including empty rooms, and by retained dictionary history (including losing operations and resets). Older clients are refused before import/admission; storage envelopes and old journal fingerprints are unchanged.

## Initial automated snapshot

- `flutter analyze`: no issues.
- `flutter test`: **2109 passed, 2 skipped**; the skipped cases are not counted as passes.
- `node --test tool/serve_web_test.cjs`: **4 passed**.
- `flutter build web --release --no-web-resources-cdn --output=build/web-patronymics-20261022`: passed.
- Local release `main.dart.js`: **3,590,195 bytes**, SHA-256 `9bc88634cc924f3b68ec2bfae7fc85da8d3268b6d26057fd7009a3ab62492985`.

A subsequent read-only review found and corrected dictionary retry/reopen/reset edge cases, case-changing Unicode dictionary keys, preservation of custom forms under equivalent father-name spelling, blank compound separators, and suffixes for velar `-ий` names and `Франц/Жорж`. Each has a targeted regression. The counts and artifact above belong to the initial snapshot, not automatically to these later corrections. One subsequent combined recheck was intentionally stopped to avoid overlapping a separately running isolated build; it is not counted as a completed test pass.

These checks ran against the combined working copy, which also contained a separately developed focus/suspension fix and relative-dialog refinements. They do not imply that those unrelated changes belong to the patronymic feature. No commit or deployment was performed for this task.

## Real-browser verification

The new [headless production driver](../tool/check_patronymics.cjs) runs against the local release. Prepared assertions are not automatically counted as browser passes.

The first isolated local attempt is **partial**, stopping on a harness selector before selecting ФИО. Flutter includes the tooltip before the visible choice in the accessible name (`Фамилия Имя Отчество ФИО`); the driver originally expected ФИО at the start. Both real bundle responses matched the release hash without a service worker; ordinary explicit local-copy entry and desktop search by `Ильич` returning `Иванов Алексей Ильич` passed. There were no page/console/Flutter errors. The inspected failure PNG shows the correct ИФ/ФИО menu and unchanged given-name-only cards. No dictionary writes or synchronization are claimed from that attempt. Evidence is retained in [local attempt A](../build/patronymics-local-20261022-a/report.json), its semantic snapshots, complete synthetic journals and PNGs. Only the driver's accessible-name selector was corrected before the next attempt.

[Local attempt B](../build/patronymics-local-20261022-b/report.json) is also **partial**: the selector was fixed and the screenshot visibly shows **Иванов Алексей Ильич**, father **Иванов Илья**, and relative **Иванова Анна Ильинична**. The driver then wrongly expected a selectable/read-only caption's value in the compact ARIA text snapshot, where Flutter exposes it as a disabled textbox. No page/console/Flutter errors occurred; no dictionary mutation/reload is counted as tested there. Subsequent assertions use the live relative captions and retain actual input values/screenshots rather than treating a missing ARIA text node as a missing rendered name.

[RTC attempt A](../build/patronymics-rtc-20261022-a/report.json) reached real connected native peer connections, complete initial journal convergence, and production **hello/welcome** advertising `patronymics`, `personalSurnames` and `explicitSiblings` on both profiles. Public PeerJS returned HTTP 403; the unchanged production fallback nevertheless connected the room. The original driver grouped those provider console failures with application errors and stopped before dictionary mutations. This is a **partial**, not a dictionary synchronization pass or an error-free public-service result. Later runs keep sanitized provider outages separately while still requiring actual channels and complete convergence; no fake provider readiness or transport is introduced.
