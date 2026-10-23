# October 23, 2026 — Re-entry beside a retained stalled RTC

## Investigation and ordinary reload comparison

The user reported that repeated room entry felt slower after the keep-RTC release. A real headless benchmark compared the final pre-fix keep-RTC bundle (`41ed9ab79587173e903465fb5f818ba2c13c77772c62beb28fd9e73bca5eed25`, 3,713,625 bytes) with the earlier lifecycle-only bundle (`41c750b272d445b253933bf493cf1fcb39e0397a79ae887e37767a2b0bd7e4fc`, 3,564,561 bytes). Each used the same compatible synthetic five-record tree, a continuously open host and three actual member reloads; assets were local, public signaling and native RTC were real, production ICE policy was unchanged.

| Release | Reload to loaded tree, milliseconds | Median |
| --- | --- | --- |
| Keep-RTC, before this fix | 1927 / 1888 / 1898 | 1898 |
| Previous lifecycle release | 1920 / 1826 / 1937 | 1920 |

Ordinary reload did **not** reproduce a general slowdown. In both versions, the first checkpoint arrived after roughly 0.74–0.85 seconds, followed by the existing one-second host quiet interval: a matching `roomReady:false` ACK, then a matching `roomReady:true` ACK. Tree presentation followed the ready ACK by 49–75 ms. Old native channels closed 6–8 ms after reload, so this benchmark did not exercise retained stale links. All actual bundle bodies matched the expected hashes; complete durable journals stayed identical, and JS/Flutter errors were absent. Final screenshots were inspected. The single run took 36.8 seconds and both owned browsers/servers closed.

Evidence: `E:/mytree-reentry-20261023/timings.json`, `report.json` and the adjacent final PNGs. The timings file derives the correct directed ACKs offline from retained native receive traces; an unused raw-summary `pair.ready` field incorrectly inspected checkpoint rather than ACK fields. No browser rerun or app modification was used to correct that analysis. This small local fixture is not a real-account Disk, large-journal, physical-phone, VPN or production-latency benchmark.

## Confirmed conditional regression and fix

The longer native-channel grace introduced a different reproducible problem. A previously established peer can remain native-open after its application stops responding. At 20 seconds, its soft watchdog starts a durable recheck and clears its old import/ACK proof, but the host still included it in every new member's initial cohort. That peer could survive for 90 foreground seconds while each new entry had only 30 seconds. A fresh valid connection therefore received `roomReady:false` and waited for an unrelated old recheck. This can also affect an accepted participant returning with the same actor. It is a confirmed code/test scenario, not proof that the user's device had exactly that state.

The host now excludes only an established channel with an overdue recheck, no pending assembly and no declared history missing locally from another real member's initial cohort. Native RTC remains available for independent recovery. A sticky overdue-verification flag is cleared by fresh durable proof, not ordinary presence; heartbeat-only traffic cannot restore the old dependency. If no real eligible cohort remains, the original connection set is retained as evidence against unsupported solo inference. First admission, actual assemblies, fresh nonces, exact ACKs and the quiet interval remain strict.

Each channel retains still-missing immutable ID/digest claims from ordinary inventories, nonce requests and checkpoints across recheck resets. Only exact durable containment clears a claim; a smaller later checkpoint cannot erase it, and contradictory claims are rejected. The retained map is bounded. Missing claims participate in checkpoint deadlines, recheck completion, follower readiness and cohort import; repeated presence cannot turn an announced but undelivered history into an unbounded wait without the normal bounded recovery path.

## Regression verification

Two new-member/returning-member regressions failed before the change (`expected ready`, `actual false`) and passed after it. They keep the old RTC open, wait through its soft timeout and inject an ordinary heartbeat before the new entry, proving that presence does not restore the stale prerequisite.

Three negative cases announce missing history through a plain inventory, a checkpoint without prior inventory, or a nonce recheck request. They keep presence flowing, cross the recheck reset, provide a smaller fresh cutoff and hold the actual storage append. Entry stays blocked until the originally announced record is durable. A fourth negative case retains a real partial assembly on an established silent peer; the newcomer still waits for the transfer and its durable proof.

Review caught two related boundary cases during implementation: using current responsiveness alone let a heartbeat re-add the overdue channel, and an announced inventory without a checkpoint needed to start the checkpoint watchdog. The sticky flag and full pending-contribution readiness guard cover both. The nonce-request case additionally requires updating the entry barrier after its response; the regression caught and verified that call. The focused session suite passed after these fixes.

## Final source checks

The final frozen source passed `flutter analyze` with no issues, the complete **2291 Flutter tests (2 skipped)**, all **4 HTTP server tests**, and a fresh release web build. Local build stamp: **2026.10.23-094202 UTC**; `main.dart.js`: **3,714,695 bytes**, SHA-256 **`91e597df526e4822e89c06203f62bde4d0e8febf2aa15c2d8f6dcf44072855fb`**. The existing non-fatal CupertinoIcons font warning remained; MaterialIcons was generated normally. Source was not changed during the final verification/build. These are local checks, not a new public deployment.

## Final native headless scenario

One bounded final scenario **passed** in **42.5 seconds** on that exact local release. A continuously running host A and saved member B established native RTC; B was then genuinely paused through `Debugger.paused` for **28.259 seconds**. While B was still paused and the original A–B native channel remained open, accepted member C received its fresh matching `roomReady:true` ACK in **2620 ms** and rendered the real tree without a loader in **2696 ms**. A/C complete durable journals were identical. Entry did not wait for B's deferred recheck or destroy its channel to finish.

After native resume, B completed a fresh inventory-nonce/checkpoint-echo/ACK exchange and a separate current tracked checkpoint/ready ACK in **1111 ms**, on the same original RTC channel. All A/B/C complete immutable seven-record journals matched. One actual C reload then restored the real tree in **1925 ms** with the same exact persisted journal. It observed a real server HTTP **304** without the historical HTTP200-only wait; a separate read-only, cache-disabled body fetch returned HTTP **200**, **3,714,695 bytes** and the exact expected SHA-256. Playwright could not expose a response body for the 304 itself; its body-read error is retained in the trace. The original three loaded 200 bodies, matching cached ETag and the separate no-store 200 body supplied the explicit hash evidence, without another navigation. The host document never reloaded. No JS/Flutter errors occurred. Phase screenshots were inspected: C while B was paused, resumed B, and C after reload all rendered the expected tree without a loader/error. The driver closed its owned browser and server, without touching the user's browser; the owned PID was absent and its localhost port refused connections.

Evidence: `E:/mytree-reentry-20261023/final-91e597d/summary.json`, `report.json`, four phase JSON captures and their PNGs. This is actual native suspension and new saved-member admission beside it, not mocked lifecycle/RTC or a physical-phone screen-off guarantee. Production ICE/signaling settings were retained; no cloud account/token, live application-state injection, blackhole or synthetic visibility event was used. The conditional latency defect is fixed in this local source; these results do not measure the user's particular room/network and are not a new public deployment.
