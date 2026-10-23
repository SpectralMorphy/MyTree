# October 23, 2026 — Family-history and date-control refinements

## Implemented scope

- Stepparent cards retain cousin-style saturation and muted connections, but stepparent-only membership no longer promotes an otherwise grey sibling-block wash. Genuine normal/cousin relatives in a mixed block retain precedence.
- New spouses default to the opposite known sex, with unknown retained when the initiating sex is unknown. Existing childless-marriage color/proximity already used explicit partners; an unknown-sex card's neutral palette explained the reproducible grey new-spouse case. No cache workaround or migration of existing people was added.
- Checked surname adoption with an initially null snapshot resolves from a later concrete spouse surname. Persisted nonempty snapshots remain fixed, immutable marriage records are not rewritten, and derived transfers never become recursive concrete sources.
- Partner captions use the canonical surname before that episode, including hidden canonical no-op transfers and deterministic same-date ordering. Periods have their own right-aligned line without extra spacing.
- Marriage endings use one row of Date/Lifelong/Unknown choices. Date opens the calendar immediately and displays its selected value inside the choice. Death has one birth-style button opening the same choice interface with Living instead of Lifelong. Canceling changes nothing.
- Ongoing read-mode life/marriage endings use **н.в**. An unknown life ending remains unknown; a lifelong marriage uses the earliest known death when available.

## Automated verification

The stepparent block regression first failed against the old implementation (`expected distant`, `actual cousin`), then all **112 layout tests** passed. One earlier full-suite attempt was deliberately interrupted when the user added the marriage/date requests; no full-suite pass is attributed to that interrupted snapshot.

The combined final Dart source passed:

- `flutter analyze`: no issues;
- **230 focused domain/history/biography tests**;
- complete `flutter test`: **2309 passed, 2 skipped**;
- `flutter build web --release --no-web-resources-cdn`;
- **4 static-server tests**, both changed driver syntax checks and `git diff --check`.

The existing missing-CupertinoIcons-font build warning remains. Two intermediate focused runs failed only because new cancellation tests expected `CANCEL` rather than Flutter's actual `Cancel`; the corrected focused/full suites passed. An intermediate formatting attempt caught a conditional/null-aware-index parse ambiguity; parenthesizing the map access fixed it before the clean analyzer/build/tests.

Final local `main.dart.js`: **3,717,475 bytes**, SHA-256 `c8a9da4f5687ea85413961be22520a7fcfc8ce0713712155570ef2d937c33778`.

## Actual headless browser results

### Stepparent grey block

[Step-parent attempt A](../build/stepparent-grey-block-20261023-a/canvas-regression.json) passed on the earlier isolated grey-block release (`9f575c1fc7884e633e076e6ce15554f50c0281e913d7fad8730e6395d19e773b`), before the subsequent marriage/date refinements. At 100% in 1800×1200 landscape and 1200×1800 portrait, Olga → Nastyusha → Olga plus real reload preserved complete journals and compact geometry. Actual PNG checks distinguished the grey step-parent block from the genuine cousin's lighter olive block, retained matching cousin photo saturation, and verified muted `.40` versus actual-parent `.60` curves. Both initial orientation PNGs were inspected. Page/console/Flutter errors were absent; all assets were local and WebSockets blocked. This is not a final-bundle rerun of that layout scenario.

### Final marriage/date release

[Marriage UI attempt A](../build/marriage-ui-20261023-a/report.json) passed the finite `local marriage-ui` case in independent **1440×1100 desktop** and **390×844 touch-emulated phone** profiles. All four actual initial/reloaded bundle bodies matched the final `c8a9da4f…` hash, without service workers. Off-origin requests and WebSockets were blocked; entry used the ordinary explicit unconfirmed-local-copy gate.

Both profiles exercised real one-row date choices, immediate calendar opening, in-choice date display, cancellation without a journal write, atomic childless-spouse creation with automatically male sex, same-generation adjacency, and normal brown `#875826` ring pixels in actual screenshots. No new parent edge was authored. The inspected desktop/phone canvases show no marriage line; this is visual evidence, not an automatic all-pixels assertion.

The phone additionally filled the new spouse's initially missing birth surname, producing **Белова** with **Смирнова / при рождении** while retaining the original null-snapshot marriage record. A later 2020 generic surname changed the spouse's current name without replacing **Брак с Сергей Белов**, the pre-1995 caption. Actual death controls switched lifelong endings through **н.в**, **?**, and the known **01.01.2025** boundary; reopening showed that date in its choice, and canceled calendar/modal edits left the complete journal unchanged. Inspected PNGs confirm the separate right-aligned period line, the three-choice death modal, and the childless spouse's color/proximity. One form PNG retains a transient hover tooltip over part of the last choice; separate semantic/geometry assertions verified all three names and same-row bounds.

All baseline immutable records were retained, author-prefix chains validated, no extra marriage/parent operations were introduced, and the exact full journals survived actual reloads: **21 desktop records**, SHA-256 `ccc29d0c844ad57aeb187911ade74900641c130fa5a08cbbdbbf8765c6ec9e2e`; **31 phone records**, SHA-256 `03a2e4515eaa55ab88c2b80831abea249bfa7319fc643dcc132e240e4e35b4ac`. There were no page/console/Flutter errors. The desktop intentionally did not repeat the full phone surname/death mutation flow. Public synchronization, real cloud accounts, physical-phone behavior and the older broad marriage matrix were not tested.

All owned headless contexts and the local server were closed. No commit, push, deployment or external publication was performed.
