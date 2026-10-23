# October 23, 2026 — Background timers are not a broken connection

## Corrected investigation scope

The user reported that the attached-Disk re-entry improvement had regressed from approximately five seconds and that ordinary Alt+Tab again displayed room loading. The preceding five-record, no-Disk RTC reload comparison did not test that Disk path and cannot rule out the reported delay.

A source comparison against the original `f01cae6` performance change found the strict Disk reader/client unchanged, including four workers, the same complete-history validation, accepted RTC startup before cloud HTTP, and HTTP outside the serialized admission queue. Successful strict Disk commit still completes entry independently of the RTC cohort. The UI does not wait for the entire `start()` future once its session listener receives readiness. This narrows the investigation; unchanged code alone does not disprove real latency.

## Volume-matched Disk-only browser comparison

The original live benchmark used 51 immutable files / 206 operations and measured actual tree readiness separately from the later green replica acknowledgment. No real-account credential was read for this investigation. A synthetic accepted-owner journal matched that volume: **51 batches, 206 proof-complete operations, 82,848 canonical journal bytes and 87,998 batch bytes**, with an explicit editor owner and exact active binding. It is not a reconstruction of the private room or its operation-kind distribution.

The baseline was the retained `f01cae6` Pages artifact, SHA-256 **`1d2ab87315391efa3886419fb95c775f7086d9a4a2565816cd0b538026fb10a9`** (3,562,672 bytes), not the unavailable locally measured `bd1ba…` artifact. The compared current release was `16d75b6`, SHA-256 **`c8a9da4f5687ea85413961be22520a7fcfc8ce0713712155570ef2d937c33778`** (3,717,475 bytes), before the timer changes below. Both loaded bodies were verified on every navigation, with local renderer assets, blocked WebSockets and locally fulfilled cloud responses. No provider mutation or real account access occurred.

The first one-shot run was **partial**: Playwright context routing intercepted the first 302 but not the redirected final URL, which failed DNS resolution. Both releases received zero final bodies and correctly refused entry rather than using an unconfirmed local tree. It is not an application regression or a latency result. Its original artifacts remain unchanged under `E:/mytree-disk-regression-20261023/compare-f01-vs-16d75/`.

A corrected single **60.0-second** run used native CDP Fetch interception for each initial and redirected HTTP request. Pure transport-contract tests passed before browser execution. Each of one excluded warmup plus three actual same-profile reloads per release received 51 real 302-to-200 chains, correlated by native `redirectedRequestId`, with a measured peak of **four** readers. Identical fixed delays were declared before the run: listing 150 ms, link 80 ms, redirect 30 ms, final body 180 ms. The second ordinary replica listing was held independently; real tree readiness could not depend on that later round or a green cloud ACK.

| Release | Reload tree readiness, milliseconds | Median |
| --- | --- | --- |
| `f01cae6` performance release | 5591 / 5719 / 5638 | **5638** |
| `16d75b6` before timer correction | 5618 / 5582 / 5650 | **5618** |

Strict HTTP lasted 4.72–4.83 seconds. From the last strict `Network.loadingFinished` to the real semantic tree, the wall-time was 92–105 ms for the baseline and 93–103 ms for current. Raw CDP CPU deltas reset across navigation and are **not** interpreted as CPU measurements. Every complete durable journal exactly matched all 206 original immutable records. The tree opened while the second listing remained held. No page, console or route errors occurred; expected aborted requests belong only to cleanup of the held background listing at navigation. Final PNGs were inspected, all owned browser PIDs were absent and both owned ports refused connections afterward.

Evidence: `E:/mytree-disk-regression-20261023/compare-cdp-f01-vs-16d75/summary.json`, `report.json` and adjacent screenshots. This controlled comparison did **not reproduce a Disk-code slowdown**. It cannot establish the current latency of the user's real provider, journal, devices or network, and is not presented as a fix for an unobserved real-account bottleneck.

## Confirmed Alt+Tab defect

The keep-RTC code still interpreted a delayed five-second execution timer as proof of suspension after twenty wall-clock seconds. Browser background throttling can delay that timer while native RTC remains alive. The same assumption existed in foreground/resume checks; a six-second absence of ordinary remote heartbeat could also enter the full-page barrier. Those paths reset the entry attempt and could repeat a strict Disk read despite no observed break.

Timer lateness, ordinary visibility/focus and a delayed application heartbeat now request an in-place, nonce-correlated **background** recheck rather than discarding confirmed UI readiness. The status explicitly says verification is pending; transport sends, old ACKs and a cached cloud icon are still not fresh proof. Same-origin followers request ordinary owner state instead of forcing remote resync solely because their timer was delayed. Disk-only copies schedule their ordinary background check, without a new strict entry read.

Strict loading remains for actual network/channel loss, explicit platform suspension and a current recheck reply announcing immutable records absent from durable storage. The latter retains the in-flight nonce and waits for those records to be durably merged and the current checkpoint confirmed. Native `paused` is remembered and invalidation occurs on the subsequent `resumed`, not before the OS actually stops execution. Trusted browser freeze/resume signals are separate from generic visibility. An ordinary negative presence hint is not itself proof that a native channel closed.

## Verification

Focused tests distinguish foreground-first and timer-first delays on healthy RTC, local followers and Disk-only editor/guest copies. A short focus with delayed remote heartbeat keeps the editor visible; actual last-channel closure and explicitly suspended guest/editor reads retain their strict gates, held append checks, fresh nonces and stale-ACK rejection. Existing tests which called a clock jump a suspension now supply an explicit platform-suspension signal. A UI lifecycle test uses Flutter's valid inactive/hidden/paused/resumed transition order and distinguishes ordinary hidden focus from a genuinely paused return.

Final review identified two remaining boundary distinctions. The platform network hint is now remembered at hide, so returning to an already-offline copy is not mistaken for a new online-to-offline transition; an actual loss event remains latched. Same-origin owner state has an optional strict Boolean `verificationRequired`, separate from negative presence and a pending ordinary cohort. It propagates a real owner's invalidation to an already-open follower, which still needs the matching resync completion and durable inventory. Codec and follower tests reject contradictory/malformed flags, preserve the UI on a soft negative update, and reject old cached readiness after actual invalidation. An earlier full run passed 2318 tests (2 skipped); the final source is checked separately after these last distinctions.

## Final source checks

The final frozen source passed `flutter analyze` with no issues, all **2320 Flutter tests (2 skipped)**, all **4 static-server tests**, and a fresh release web build. Local stamp: **2026.10.23-150642 UTC**. `main.dart.js`: **3,719,461 bytes**, SHA-256 **`6fc23b3f1c52f2875072c868b73c0b63bf41d9bc8fe3c7b6fdd08429b07db428`**. The existing non-fatal CupertinoIcons font warning remained; MaterialIcons was generated normally. These are local checks, not a published release or a guarantee of the user's real Disk latency.

## Final native headless evidence

A single final **81.9-second** headless run loaded the exact final bundle and exercised native RTC without synthetic visibility, replaced clocks, packet interception or live application-state injection. Its independently checked **equal-history phase passed**: B was genuinely paused with `Debugger.paused/resumed` for **26.482 seconds**, neither A nor B showed a full-page loader or lost root controls, the same native channels remained open, and a fresh background nonce plus separate current tracked-ready ACK completed **238 ms** after resume.

A second **25.514-second** native pause included a real, correctly focused name edit through A's UI. The native queued edit became durable at B before any fresh inventory advertised it as absent. The observed **durable-first branch passed**, with exact immutable journal convergence, the same RTC channels and fresh proof in **250 ms**. The strict held-missing-inventory branch did not naturally occur and is **not claimed as browser coverage**; its gate/persistence/nonce invariants are covered by the deterministic regressions. One ordinary B reload restored the tree in **3184 ms**, observed an actual server HTTP **304**, and separately fetched the exact **3,719,461-byte / `6fc23b3…b428`** body with cache disabled, without another navigation. Equal, updated and reloaded-tree PNGs were inspected.

The whole driver's raw result remains **partial**, not a whole-suite pass: its final error guard found one B `pageerror` from the test's passive observer reading `localStorage` on B's initial opaque `about:blank`, **7.728 seconds before B's first actual app-bundle response**. The observer's `journal()` lacked an origin guard; this is not evidence of a product storage failure. The driver retained only the error message, not its stack/source URL, so those are not reconstructed. All useful phase assertions occurred after real app navigation; app console errors were absent. Original artifacts are unchanged and no retry was run. The owned browser PID was absent and the owned server port refused connections after cleanup.

Evidence: `E:/mytree-timer-throttle-20261023/run-final-6fc23b3/summary.json`, `report.json` and adjacent phase captures/PNGs. These changes do not claim that a web page can prevent browser/OS discard, maintain native RTC indefinitely or distinguish every debugger interruption from timer throttling without additional evidence. The real-account delay reported by the user remains unproven by the synthetic Disk comparison; it is not relabeled as solved merely because Alt+Tab no longer restarts entry.
