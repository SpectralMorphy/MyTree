# October 22, 2026 — Marriage and surname history

## Implemented scope

The biography's **Фамилии и браки** section follows **Родные**. Explicit marriages are shared, repeatable episodes; common accepted children supply a computed marriage when no explicit episode or pair-level exclusion exists. Removing an episode requires confirmation and suppresses automatic re-inference for that pair; a fresh explicit episode restores it. Marriage periods distinguish unknown end, lifelong, and a concrete date. Child birth dates can order undated records but are never presented as marriage/change dates.

Each partner has an independent surname choice, with female defaults. Explicit surname adoption saves a canonical snapshot, not a recursive reference to the spouse's current name. Other surname changes have their own date/reason. Full names/search use the latest surname, while birth surnames remain the source of paternal inheritance and family-block labels. Explicit history remains accessible to a surviving tree identity when its spouse identity is deleted. Creating a new partner and marriage is one immutable operation.

Explicit spouses extend existing partner ranks/proximity/full-color cards without adding marriage curves or parent/ancestry links. The `marriageHistory` capability prevents older production clients from silently applying different implied-marriage/current-name semantics, including an empty room. All persistence and exchange use the existing immutable journal and author-prefix lifecycle.

## Verification progress

The domain's 106 targeted tests and the session/protocol agent's 322-suite test run passed. Layout verification passed 108 layout tests plus 12 focused editor cases. These focused results belong to their tested intermediate snapshots, not an automatic claim that the final combined source passed every check.

A read-only review found three UI/persistence boundary issues: multiline reasons were rejected by the single-line validator, retry of a two-operation marriage form could omit an operation rejected before append, and valid marriage/surname records with the same raw ID collided in widget keys. The reason validator was narrowed to allow line breaks only for the custom reason, with round-trip coverage. The form now tracks each frozen requested payload separately, retries existing cores without replacing them and submits only payloads that never acquired a draft; a partial pre-append rejection cannot close as a successful complete save. Widget keys now include their record kind, so the domain's independent ID namespaces remain valid. Dedicated regressions cover all three paths.

One initial analyzer run sampled the UI's pending-operation refactor mid-edit and reported two stale catch-block references. It is a failed/intermediate run, not a clean analyzer result. The reviewed combined snapshot subsequently passed `flutter analyze` and **2254 Flutter tests, 2 skipped** (4m07s). After a final reason-only presentation adjustment, the three targeted generic/marriage-row tests passed. The next analyzer/build chain sampled another session's in-progress stepparent regression tests (three temporary undefined/wrong-arity test calls) and stopped before build; those tests were subsequently corrected by their author. It is not counted as a clean final analyzer/build result. A later narrow domain check also made actual-change detection compare rendered surnames rather than canonical decline flags; all three current-name/birth-inheritance tests passed. This preserves a changed canonical configuration without rendering a duplicate visible surname. A final combined build is coordinated with the independent stepparent-layout correction; final shared-source checks and actual browser outcomes are recorded below.

## Final combined snapshot

The coordinating stepparent-layout session reported the final combined frozen source passed `flutter analyze`, **2257 Flutter tests / 2 skipped** (3m21s), the release web build with local renderer resources, all **4 server tests**, and JS syntax checks. The release is `build/web/main.dart.js`, SHA-256 `bca52187d1afb574422b7bb79f54cc034c27cdbc07b4e8789d2a4848abdf0d3f`. The build exited successfully with the existing missing-CupertinoIcons-font warning. These are shared-source automated results supplied by that coordinating session; the actual marriage-history release-browser check is recorded separately below.

## Completed real-browser scenario

[RTC attempt B](../build/family-history-rtc-20261022-b/report.json) **completed successfully** in headless Chrome with independent 1440×1100 desktop and 390×844 touch-emulated profiles. Every actual initial/reloaded bundle response matched `bca52187…` without a service worker. Production hello/welcome carried `marriageHistory: true` and real native connections were connected; the unchanged public fallback worked despite separately recorded PeerJS HTTP 403 outages.

Actual UI input verified:

- inferred female surname/marriage with no invented dates, cancellation of deletion without a write, then confirmed pair suppression returning to the birth surname;
- re-adding that partner with a real 1995 start and lifelong end, then adding a childless partner with a real 2010 start and default unknown end;
- the childless spouse in the same feasible generation, existing full-color partner treatment and no marriage curve in the inspected canvas PNG;
- a 2020 custom surname change/reason, current-name search on both profiles, and confirmed removal returning to the previous surname;
- a new partner plus a 2030 marriage in **exactly one** immutable `addMarriage` record, with no orphan creation or parent-edge changes;
- complete durable reload on both profiles, keeping all baseline records and author-prefix proofs. The final complete journals were identical: **27 records**, SHA-256 `4cc1fce7f286e8e1de1cedd26d49630608cd0d299ec6fc6f47febf2c6ced4599`.

There were **no application/page/Flutter errors**. PeerJS 403 outages are not hidden or counted as error-free provider availability. The selected pairs after reload were **host↔host**, not physical-phone/NAT traversal/TURN proof. Initial, childless-canvas and phone-reload PNGs were inspected. The 390px reload visibly shows **Анна Орлова** plus the ordered 1995/2010/2030 surname rows, `н.в.` versus unknown `?`, and named partners below relatives, without clipping. The intermediate desktop file named `chronological-surname-history.png` caught the biography's upper edit region rather than the full lower list; chronology/persisted dates and the later phone list provide that evidence instead. Guest permissions, no-change rows, multiline reasons, partial pre-append retry, independent same-ID record kinds and broader concurrency remain the dedicated automated-test coverage, not claims about this two-editor browser run.

All owned headless contexts and the local release server were closed. No push, deployment, real cloud/account mutation or external infrastructure creation was performed during verification. The subsequent user-requested local commit includes this feature and its verification artifacts, excluding independent ongoing lifecycle/signaling changes. The tested artifact includes the separately developed stepparent layout correction; later session-lifecycle edits by another session are outside this frozen snapshot.

## Scoped commit check

Before the user-requested local commit, the staged feature tree was exported separately from the shared working directory. The ongoing `recheckSync`/`recheckId`, lifecycle and signaling changes from another task were excluded. This exact source snapshot passed `flutter analyze` and **383 focused protocol/session/domain/history-widget tests**. Only these explanatory verification notes changed after that isolated source check; the working files and other task's unstaged edits were not replaced.

## Retained partial attempt

[RTC attempt A](../build/family-history-rtc-20261022-a/report.json) is **partial**, stopping before any mutation on a driver selector. The real biography section is a merged accessibility group (`Фамилии и браки Иванова Брак с Иван Иванов`), not a standalone exact text node. Both actual bundle bodies matched the final hash, production native RTC/hello/welcome advertised `marriageHistory`, and always-ФИО search found the inferred current surname on both profiles. The inspected PNG shows **Иванова** and the undated implied marriage immediately below relatives; no child DOB is presented as a marriage date. There were no application errors; PeerJS 403 failures remain separately retained while the production fallback connected. The driver now locates the actual merged section and accounts for duplicate tooltip semantics on the Delete action; source code is unchanged. No save, suppression or reload pass is inferred from this partial attempt.
