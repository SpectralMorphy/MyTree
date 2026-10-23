# October 23, 2026 — Unknown-sex blue cards and biography hierarchy

## Implemented scope

The screenshot's neutral husband had unknown sex. Following the user's clarification, no spouse-specific palette inference or stored-sex migration was retained. **All unknown-sex cards** now use blue `#2563EB` for names, initials/fallbacks, avatar rings and selection outlines, without a sex badge. They deliberately bypass cousin/distant desaturation as an incomplete-data cue. Known-sex styling, partner proximity, block washes, parent-curve colors and all stored identities remain unchanged.

The birth-surname row uses the same date/surname layout as later changes, with the actual birth date on the left or `?` when unknown. It is still absent when no actual surname changes exist. Surname entries are 16px; the biography's relatives, family history, facts and biography titles are 22px semibold inside matching lightly tinted header bands. Add Fact stays inside its header. The shared widget belongs to `biography_section.dart`, without session/storage dependencies.

## Automated checks

`flutter analyze`, the release web build with local renderer assets, and all **4 static-server tests** passed. The existing missing-CupertinoIcons-font build warning remains. Both browser drivers pass Node syntax checks.

The first focused presentation run passed the new date/header/blue tests but failed six older filter assertions: their synthetic cousin/distant controls had omitted sex. Those controls now explicitly supply sex when testing the unchanged known-sex desaturation contract; separate unknown-sex tests assert blue without writes or badges. Production code was not changed to appease those old assertions. The next default-concurrency full run passed all UI checks but failed one unchanged Disk-client timing assertion (577ms versus a <500ms threshold). That failed run is retained rather than counted as a complete pass. The unchanged timing test passed separately, and the final complete `flutter test --concurrency 2` passed **2325 tests, 2 skipped** in 4m38s without relaxing its bound.

## Actual headless browser check

[Local attempt A](../build/blue-unknown-biography-20261023-a/report.json) passed `local unknown-sex-ui` with independent **1440×1100 desktop** and **390×844 touch-emulated phone** profiles. All four actual initial/reloaded bundle bodies matched SHA-256 `a8abe0911a1d7e882f2acbfc547a297536d906b85885a09cb1aaa1e48a7926e0`, without service workers. Off-origin requests and all WebSockets were blocked; the ordinary explicit unconfirmed-local-copy gate was used.

Real PNG avatar-ring samples were exactly **[37,99,235]** before and after reload. The inspected canvases show both the unknown-sex spouse and a separate unrelated unknown person in blue, without a sex corner badge; their blocks remain grey. Inspected desktop/phone biographies show **06.05.1980 Смирнова** above **при рождении**, smaller surname content, and distinct tinted section headers. The desktop screenshot additionally shows the matching Facts header. No application/page/console/Flutter errors occurred.

The complete **25-record** synthetic journal stayed byte-equivalent in both profiles before/after browsing and after real reload, SHA-256 `e63ce6887c8ee7a1b0a85a813d5fa895dfd882cbedc5f5e64dc9e086f6c43e74`. No sex, marriage, surname, parent or presentation operation was added. Unknown birth-date display, both theme header styles and selection-independent blue behavior have widget coverage; the real-browser scenario used a known birth date and the light theme only.

The older broad canvas/kinship pixel oracles were updated for unknown-sex blue/full-color while retaining independent block-alpha and known-sex checks; those broader scenarios were not run here. No public network synchronization, cloud account, physical-phone behavior or deployment is claimed. All owned headless contexts and the local server were closed. No commit, push or new publication was performed for these changes.
