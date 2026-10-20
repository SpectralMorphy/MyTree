// Usage: node tool/check_tree_ui.cjs <playwright-module> <base-url> <screenshots> [all|surnames|personal-surnames|guest-identity|guest-identity-legacy|identity-local|identity-actions-local|dialogs-local|author-history|author-history-local|initial-sync-recovery|explicit-siblings|clean-address-local|first-admission-diagnostic|first-admission-relay-diagnostic|first-admission-mqtt-startup]
// guest-identity-legacy reuses a saved seed (or creates a schema-valid one), without public peers.
// identity-local checks optional aliases, tooltip, own binding release/rebind and reload on desktop/phone; public transport is blocked.
// author-history: two fresh profiles / three pages, actual public RTC and same-author tab writers.
// author-history-local: explicit legacy fixture, public networking blocked, UTC/Moscow and failed append.
// initial-sync-recovery: saved member, actual RTC checkpoint close, fixed 30s gate, staged prefix/ACK recovery.
// Independent browser profiles, production RTC transport, headless only.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require(process.argv[2]);
const base = process.argv[3];
const output = process.argv[4];
const suite = process.argv[5] || 'all';
assert.ok(['all', 'surnames', 'personal-surnames', 'guest-identity', 'guest-identity-legacy', 'identity-local', 'identity-actions-local', 'dialogs-local', 'author-history', 'author-history-local', 'initial-sync-recovery', 'explicit-siblings', 'clean-address-local', 'first-admission-diagnostic', 'first-admission-relay-diagnostic', 'first-admission-mqtt-startup'].includes(suite), 'Unknown browser suite.');
if (!base || !output) throw new Error('Pass the application URL and screenshot directory.');
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const body = (page) => page.locator('body').ariaSnapshot();
const personalSurnameSuite = ['surnames', 'personal-surnames'].includes(suite);
const explicitSiblingSuite = suite === 'explicit-siblings';
const cleanAddressSuite = suite === 'clean-address-local';
const relayAdmissionSuite = suite === 'first-admission-relay-diagnostic';
const mqttStartupSuite = suite === 'first-admission-mqtt-startup';
if (mqttStartupSuite) assert.match(new URL(base).hostname, /^(?:127\.0\.0\.1|localhost|\[::1\])$/, 'The controlled-latency case is authorized only for the final local release.');
const firstAdmissionSuite = suite === 'first-admission-diagnostic' || relayAdmissionSuite || mqttStartupSuite;
const admissionReport = { application: base, suite, headless: true, completed: false, stage: 'prepared',
  actualBrowserBundles: [], checkpoints: [], runtimeSamples: [], providerEvents: [], http: [], consoleMessages: [], pageErrors: [] };
const cleanAddressReport = { application: base, suite, headless: true, completed: false, steps: [],
  actualBrowserBundles: [], network: { sameOriginOnly: true, http: [], blockedWebSockets: 0 } };
const tracedPublicFeature = personalSurnameSuite || explicitSiblingSuite;
const publicSiblingReport = { application: base, suite, headless: true, completed: false, steps: [], actualBrowserBundles: [] };
const publicSurnameTrace = { consoleMessages: [], http: [], webSockets: [], checkpoints: [] };

async function waitUntil(check, message, timeout = 45000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await check()) return;
    await sleep(150);
  }
  throw new Error(message);
}
async function activate(page) {
  await page.waitForFunction(() => window.__firstFrame, null, { timeout: 90000 });
  const marker = page.locator('flt-semantics-placeholder');
  for (let i = 0; i < 5 && await marker.count(); i++) {
    await marker.evaluate((element) => Object.assign(element.style, {
      position: 'fixed', left: '0px', top: '0px', width: '2px', height: '2px',
      transform: 'none', zIndex: '2147483647',
    }));
    await marker.click({ force: true });
    await page.waitForTimeout(200);
  }
}
async function load(page, url) {
  const expected = explicitSiblingSuite || cleanAddressSuite || firstAdmissionSuite ? process.env.MYTREE_EXPECTED_BUNDLE_SHA256 : null;
  if (explicitSiblingSuite || cleanAddressSuite || firstAdmissionSuite) assert.match(expected || '', /^[0-9a-f]{64}$/, 'The finite browser case requires the explicitly authorized bundle hash.');
  if (page.url() !== 'about:blank') await page.goto('about:blank');
  const actual = expected ? page.waitForResponse((response) => response.url() === new URL('main.dart.js', `${base.replace(/\/$/, '')}/`).href &&
    response.status() === 200, { timeout: 30000 }) : null;
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 120000 });
  if (actual) {
    const response = await actual, bytes = await response.body();
    const entry = { url: response.url(), bytes: bytes.length, fromServiceWorker: response.fromServiceWorker(),
      sha256: require('node:crypto').createHash('sha256').update(bytes).digest('hex') };
    const targetReport = firstAdmissionSuite ? admissionReport : cleanAddressSuite ? cleanAddressReport : publicSiblingReport;
    targetReport.actualBrowserBundles.push(entry);
    await fs.writeFile(path.join(output, 'actual-browser-bundles.json'), JSON.stringify(targetReport.actualBrowserBundles, null, 2));
    assert.equal(entry.sha256, expected); assert.equal(entry.fromServiceWorker, false);
  }
  await activate(page);
}
const nativeInputValue = (page) => page.evaluate(() => {
  const input = document.activeElement;
  return input instanceof HTMLInputElement || input instanceof HTMLTextAreaElement ? input.value : null;
});
async function focusInput(page, field, expected) {
  await field.click();
  await field.focus();
  await sleep(150);
  await waitUntil(async () => {
    const value = await nativeInputValue(page);
    // On mobile the semantic input is a mirror, not Flutter's native editor.
    return value !== null && (expected === undefined || value === expected);
  }, `The focused native input did not expose ${JSON.stringify(expected ?? 'the field value')}.`, 10000);
}
async function type(page, field, text) {
  await focusInput(page, field);
  await page.keyboard.press('Control+A');
  await waitUntil(() => page.evaluate(() => {
    const input = document.activeElement;
    return input?.selectionStart === 0 && input?.selectionEnd === input?.value?.length;
  }), 'The actual native input did not select its complete previous value.', 5000);
  // Direct replacement avoids a separate intentional clear/reset of a surname
  // register before entering its replacement; typing still uses real 30ms input.
  if (text) await page.keyboard.type(text, { delay: 30 });
  else await page.keyboard.press('Backspace');
  await waitUntil(async () => await nativeInputValue(page) === text, 'The native input lost or reordered typed characters.', 10000);
}
async function admissionName(page, text) {
  await type(page, page.getByRole('textbox', { name: /Ваше имя/ }), text);
  await page.getByRole('button', { name: 'Продолжить', exact: true }).click();
}
async function openBio(page, edit = false) {
  await page.getByRole('button', { name: 'Биография', exact: true }).click();
  await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).waitFor();
  if (edit) await page.getByRole('button', { name: 'Изменить', exact: true }).click();
}
async function closeBio(page) {
  await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).click();
  await page.waitForTimeout(300);
}
async function invite(page, role) {
  await page.getByRole('button', { name: /^Участники:/ }).click();
  await page.getByRole('button', { name: 'Пригласить участников', exact: true }).click();
  if (role === 'editor') await page.getByRole('button', { name: 'Редактор', exact: true }).click();
  await page.getByRole('button', { name: 'Скопировать URL', exact: true }).click();
  const value = await page.evaluate(() => navigator.clipboard.readText());
  await page.getByRole('button', { name: 'Закрыть', exact: true }).click();
  return value;
}
async function history(page) {
  return page.evaluate(() => Object.keys(localStorage)
    .filter((key) => key.startsWith('mytree.room-store.v1.') && key.includes('.operation.'))
    .map((key) => JSON.parse(localStorage.getItem(key)))
    .sort((a, b) => a.id.localeCompare(b.id)));
}
async function converged(pages) {
  await waitUntil(async () => {
    const values = await Promise.all(pages.map(history));
    return values.every((value) => JSON.stringify(value) === JSON.stringify(values[0]));
  }, 'Complete persistent journals did not converge.');
}
async function revealBiographyAction(page, action, direction = 1) {
  for (let attempt = 0; attempt < 18; attempt++) {
    const box = await action.count() ? await action.boundingBox() : null;
    if (box && box.y >= 70 && box.y + box.height <= page.viewportSize().height - 12) return;
    await page.mouse.move(page.viewportSize().width - 30, page.viewportSize().height / 2);
    await page.mouse.wheel(0, direction * 330);
    await sleep(180);
  }
  throw new Error('Biography action never became visible through real scrolling.');
}
async function newRelative(page, kind, name) {
  const add = page.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiographyAction(page, add);
  await add.click();
  await page.getByRole('button', { name: /^Кого добавить/ }).click();
  await page.getByRole('menuitem', { name: kind, exact: true }).click();
  await page.getByRole('checkbox', { name: 'Новый человек', exact: true }).click();
  await type(page, page.getByRole('textbox', { name: 'Имя нового человека', exact: true }), name);
  await page.getByRole('button', { name: 'Добавить', exact: true }).click();
  await page.getByRole('alertdialog').waitFor({ state: 'hidden' });
}

// The focused identity suite only drives real UI writes. The separate legacy
// check seeds a fresh, network-isolated profile before the application starts;
// it never injects a forbidden guest write into the live public room.
async function storedRoom(page) {
  return page.evaluate(() => Object.fromEntries(Object.keys(localStorage).sort()
    .filter((key) => key.startsWith('mytree.room-store.v1.'))
    .map((key) => [key, localStorage.getItem(key)])));
}
function appendedHistory(before, after) {
  const existing = new Map(before.map((record) => [record.id, record]));
  const current = new Map(after.map((record) => [record.id, record]));
  for (const record of before) assert.deepEqual(current.get(record.id), record,
    `Existing immutable record ${record.id} was removed or changed.`);
  return after.filter((record) => !existing.has(record.id));
}
async function participantPanel(page, labels, screenshot) {
  await page.getByRole('button', { name: /^Участники:/ }).click();
  try {
    await waitUntil(async () => {
      const semantics = await body(page);
      return labels.every((label) => semantics.includes(label));
    }, `Participant panel did not expose the expected labels: ${JSON.stringify(labels)}`);
    const semantics = await body(page);
    if (screenshot) await page.screenshot({ path: path.join(output, screenshot), animations: 'disabled' });
    return semantics;
  } finally {
    await page.getByRole('button', { name: 'Закрыть', exact: true }).click();
  }
}
async function guestBiography(page, screenshot) {
  await openBio(page);
  try {
    for (const name of ['Это я', 'Изменить', 'Добавить родственника', 'Удалить человека', 'Добавить факт']) {
      assert.equal(await page.getByRole('button', { name, exact: true }).count(), 0,
        `A guest biography exposed ${name}.`);
    }
    for (const name of ['Имя', 'Биография']) {
      assert.equal(await page.getByRole('textbox', { name, exact: true }).count(), 0,
        'A guest biography exposed a writable person field.');
    }
    assert.doesNotMatch(await body(page), /Ваш профиль|Сохраняем привязку/);
    assert.match(await body(page), /Алексей/);
    if (screenshot) await page.screenshot({ path: path.join(output, screenshot), animations: 'disabled' });
  } finally {
    await closeBio(page);
  }
}
async function bindEditor(page, pages, actor, cancelFirst = false) {
  const before = await history(page);
  await openBio(page);
  await page.getByRole('button', { name: 'Это я', exact: true }).click();
  assert.match(await body(page), /Связать ваш профиль с/);
  if (cancelFirst) {
    await page.getByRole('button', { name: 'Отмена', exact: true }).click();
    await converged(pages);
    assert.deepEqual(await history(page), before, 'Cancelling identity confirmation wrote history.');
    await page.getByRole('button', { name: 'Это я', exact: true }).click();
  }
  await page.getByRole('button', { name: 'Да, это я', exact: true }).click();
  await waitUntil(async () => (await body(page)).includes('Ваш профиль'), 'The editor binding was not confirmed in the biography.');
  assert.equal(await page.getByRole('button', { name: 'Это я', exact: true }).count(), 0);
  await closeBio(page);
  await converged(pages);
  const additions = appendedHistory(before, await history(page));
  assert.equal(additions.length, 1, 'Explicit editor binding must append exactly one record.');
  assert.equal(additions[0].kind, 'tree');
  assert.equal(additions[0].author, actor);
  assert.deepEqual(JSON.parse(additions[0].text), { type: 'bindActor', personId: 'root', actorId: actor });
  return additions[0];
}
async function simpleLegacySeed() {
  const [editorA, editorB, guestActor, roomId] = ['a', 'b', 'c', 'd'].map((letter) => letter.repeat(32));
  const journal = [];
  const record = (author, kind, text, targetActor) => {
    const clock = journal.length + 1;
    journal.push({ id: `identity-fixture-${clock}`, author, clock, createdAt: 1792195200000,
      kind, text, ...(targetActor ? { targetActor } : {}) });
  };
  for (const [actor, name, role] of [[editorA, 'Редактор устройства А', 'editor'],
    [editorB, 'Редактор устройства Б', 'editor'], [guestActor, 'Гость устройства', 'guest']]) {
    record(actor, 'participantName', name);
    record(editorA, 'participantRole', role, actor);
  }
  const tree = (operation, author = editorA) => record(author, 'tree', JSON.stringify(operation));
  tree({ type: 'editText', personId: 'root', field: 'name', itemId: null,
    inserts: [...'Алексей'].map((text, index) => ({ id: `fixture-name-${index}`, text,
      left: index ? `fixture-name-${index - 1}` : null, right: null })), deletes: [] });
  const portrait = await fs.readFile(path.join(__dirname, '..', 'assets', 'tree-mark.png'));
  tree({ type: 'addPhoto', personId: 'root', itemId: 'fixture-portrait',
    dataUrl: `data:image/png;base64,${portrait.toString('base64')}`, caption: '', afterId: null, beforeId: null });
  tree({ type: 'setValue', personId: 'root', field: 'avatarPhotoId', value: 'fixture-portrait' });
  for (const actor of [editorA, editorB]) tree({ type: 'bindActor', personId: 'root', actorId: actor }, actor);
  const prefix = 'mytree.room-store.v1.';
  const roomPrefix = `${prefix}room.${Buffer.from(roomId).toString('base64url')}.`;
  const storage = {
    [`${prefix}client-id`]: JSON.stringify(guestActor), [`${prefix}last-room`]: JSON.stringify(roomId),
    [`${roomPrefix}membership`]: JSON.stringify(roomId),
  };
  for (const operation of journal) storage[`${roomPrefix}operation.${Buffer.from(operation.id).toString('base64url')}`] = JSON.stringify(operation);
  return { provenance: 'explicit schema-valid isolated fixture; no public room data', fixtureVersion: 2, storage,
    journal: journal.sort((a, b) => a.id.localeCompare(b.id)), guestActor, roomId };
}
async function legacyGuestIdentity(browser, storage, expectedJournal, guestActor, roomId, errors, pages) {
  const legacy = {
    id: `legacy-guest-binding-${guestActor}`, author: guestActor,
    clock: Math.max(...expectedJournal.map((record) => record.clock)) + 1,
    createdAt: Date.now(), kind: 'tree',
    text: JSON.stringify({ type: 'bindActor', personId: 'root', actorId: guestActor }),
  };
  const operationKey = `mytree.room-store.v1.room.${Buffer.from(roomId).toString('base64url')}.operation.${Buffer.from(legacy.id).toString('base64url')}`;
  const variants = [
    { name: 'baseline', storage, journal: expectedJournal },
    { name: 'bound', storage: { ...storage, [operationKey]: JSON.stringify(legacy) },
      journal: [...expectedJournal, legacy].sort((a, b) => a.id.localeCompare(b.id)) },
  ];
  const avatars = [];
  for (const variant of variants) {
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 },
      serviceWorkers: 'block', reducedMotion: 'reduce' });
    const page = await context.newPage();
    pages.push(page);
    page.on('pageerror', (error) => errors.push(error.message));
    try {
      await context.addInitScript(() => {
        window.__firstFrame = false;
        window.addEventListener('flutter-first-frame', () => { window.__firstFrame = true; }, { once: true });
      });
      const seedUrl = new URL('__guest_identity_fixture__', base).href;
      await context.route(seedUrl, (route) => route.fulfill({ contentType: 'text/html', body: '<!doctype html><title>Legacy storage fixture</title>' }));
      await page.goto(seedUrl);
      // Explicit pre-load fixture, using WebRoomStore's actual string/operation
      // encodings. No storage writes occur after the application is loaded.
      await page.evaluate((values) => {
        for (const [key, value] of Object.entries(values)) localStorage.setItem(key, value);
      }, variant.storage);
      await context.unroute(seedUrl);
      const appOrigin = new URL(base).origin;
      await context.route('**/*', (route) => {
        const url = new URL(route.request().url());
        const engine = url.hostname === 'www.gstatic.com' && url.pathname.startsWith('/flutter-canvaskit/');
        const font = ['fonts.gstatic.com', 'fonts.googleapis.com'].includes(url.hostname);
        return url.origin === appOrigin || engine || font ? route.continue() : route.abort('internetdisconnected');
      });
      await context.routeWebSocket('**/*', (socket) => socket.close({ code: 1000, reason: 'Isolated legacy storage fixture' }));
      await load(page, base);
      await page.getByRole('button', { name: 'Открыть локальную копию', exact: true }).click({ timeout: 60000 });
      await page.getByRole('button', { name: 'Выбрать Алексей', exact: true }).waitFor();
      assert.match(await body(page), /Локальная копия · синхронизация не подтверждена/,
        'The isolated fixture must not report confirmed network synchronization.');
      await guestBiography(page, `legacy-${variant.name}-guest-biography.png`);
      await page.getByRole('button', { name: 'Участники: 0 других онлайн. Нет подключения к сети', exact: true }).click();
      const guestLabel = 'Гость устройства, вы, офлайн, гость';
      await waitUntil(async () => {
        const semantics = await body(page);
        return semantics.includes(guestLabel) && semantics.includes('Редактор устройства А, офлайн, редактор');
      }, 'The isolated fixture did not show a separate guest and bound editor group.');
      assert.equal(await page.getByRole('button', { name: /Сделать редактором/ }).count(), 0,
        'The legacy guest inherited an editor role from its bound person group.');
      const semantics = await body(page);
      assert.doesNotMatch(semantics, /Алексей, вы,|Редактор устройства Б,/);
      const box = await page.evaluate((label) => {
        const boxes = [...document.querySelectorAll('flt-semantics')]
          .filter((element) => element.getAttribute('aria-label') === label || element.textContent === label)
          .map((element) => element.getBoundingClientRect()).filter((rect) => rect.width >= 54 && rect.height >= 54)
          .sort((a, b) => a.width * a.height - b.width * b.height);
        const rect = boxes[0];
        return rect && { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
      }, guestLabel);
      assert.ok(box, 'Guest avatar semantics have no visible bounds.');
      // Equal pixels against the same profile without the legacy binding prove
      // its photo avatar is also ignored, not merely its accessible name.
      const avatar = await page.screenshot({ clip: { x: box.x + (box.width - 54) / 2, y: box.y + 8, width: 54, height: 54 },
        path: path.join(output, `legacy-${variant.name}-guest-avatar.png`), animations: 'disabled' });
      avatars.push(avatar);
      await page.screenshot({ path: path.join(output, `legacy-${variant.name}-participants.png`), animations: 'disabled' });
      await page.getByRole('button', { name: 'Закрыть', exact: true }).click();
      assert.deepEqual(await history(page), variant.journal, 'Reading a legacy guest rewrote its complete journal.');
      assert.deepEqual(await storedRoom(page), variant.storage, 'Legacy projection rewrote persisted data.');
      await page.reload({ waitUntil: 'domcontentloaded' });
      await activate(page);
      await page.getByRole('button', { name: 'Открыть локальную копию', exact: true }).click({ timeout: 60000 });
      await page.getByRole('button', { name: 'Выбрать Алексей', exact: true }).waitFor();
      await guestBiography(page);
      assert.deepEqual(await history(page), variant.journal, 'Legacy guest reload changed immutable history.');
      assert.deepEqual(await storedRoom(page), variant.storage, 'Legacy guest reload changed stored bindings.');
    } catch (error) {
      await fs.writeFile(path.join(output, `legacy-${variant.name}-failure.json`), JSON.stringify({
        failure: error.stack, semantics: await body(page).catch(() => 'unavailable'),
        completeJournal: await history(page).catch(() => null), storage: await storedRoom(page).catch(() => null),
      }, null, 2));
      await page.screenshot({ path: path.join(output, `legacy-${variant.name}-failure.png`) }).catch(() => {});
      throw error;
    } finally {
      await context.close();
    }
  }
  assert.ok(avatars[0].equals(avatars[1]), 'The persisted guest binding changed its avatar from the unbound guest baseline.');
  await fs.writeFile(path.join(output, 'legacy-guest-fixture.json'), JSON.stringify({
    roomId, guestActor, appendedLegacyRecord: legacy, networkIsolated: true,
    storedDataUnchanged: true, guestNameAndAvatarUnchanged: true, guestNotGroupedWithEditors: true,
    noInheritedEditorRole: true, reloadVerified: true,
    baselineJournal: variants[0].journal, legacyJournal: variants[1].journal,
  }, null, 2));
  console.log('PASS: isolated actual-storage legacy guest binding survives unchanged but affects no profile label, name, avatar, role or editor group; reload preserves complete history.');
}
async function publicGuestIdentity(browser, pages, errors) {
  const [a, b, guest] = pages;
  const livePages = [a, b, guest];
  const counts = async (expected) => Promise.all(livePages.map((page, index) =>
    page.getByRole('button', { name: `Участники: ${expected[index]} других онлайн`, exact: true }).waitFor({ timeout: 45000 })));
  await load(a, base);
  await a.getByRole('button', { name: 'Создать комнату', exact: true }).click();
  await admissionName(a, 'Редактор устройства А');
  await a.getByRole('button', { name: 'Выбрать Без имени', exact: true }).waitFor({ timeout: 60000 });
  await openBio(a, true);
  await type(a, a.getByRole('textbox', { name: 'Имя', exact: true }), 'Алексей');
  const album = a.getByRole('button', { name: /^Открыть фотоальбом/ });
  await revealBiographyAction(a, album);
  await album.click();
  const chooser = a.waitForEvent('filechooser');
  await a.getByRole('button', { name: 'Загрузить фотографии', exact: true }).click();
  await (await chooser).setFiles({ name: 'identity-portrait.png', mimeType: 'image/png',
    buffer: await fs.readFile(path.join(__dirname, '..', 'assets', 'tree-mark.png')) });
  await a.getByRole('button', { name: 'На аватар', exact: true }).click({ timeout: 30000 });
  await a.getByRole('button', { name: 'Выбран аватаром', exact: true }).waitFor();
  await a.getByRole('button', { name: 'Закрыть альбом', exact: true }).click();
  await closeBio(a);
  const editorInvite = await invite(a, 'editor');
  const guestInvite = await invite(a, 'guest');
  await load(b, editorInvite);
  await admissionName(b, 'Редактор устройства Б');
  await b.getByRole('button', { name: 'Выбрать Алексей', exact: true }).waitFor({ timeout: 60000 });
  await load(guest, guestInvite);
  await admissionName(guest, 'Гость устройства');
  await guest.getByRole('button', { name: 'Выбрать Алексей', exact: true }).waitFor({ timeout: 60000 });
  await converged(livePages);
  await counts([2, 2, 2]);
  const actors = await Promise.all(livePages.map((page) => page.evaluate(() => JSON.parse(localStorage.getItem('mytree.room-store.v1.client-id')))));
  assert.equal(new Set(actors).size, 3, 'The three browser profiles must have independent persistent identities.');
  const rtcEvidence = await Promise.all(livePages.map((page) => page.evaluate(() => ({
    openChannels: window.__channels.filter((channel) => channel.readyState === 'open').length,
    connectedPeers: window.__peerConnections.filter((peer) => peer.connectionState === 'connected').length,
    candidateTypes: window.__peerConnections.filter((peer) => peer.connectionState === 'connected')
      .flatMap((peer) => (peer.localDescription?.sdp || '').split('\n').filter((line) => line.startsWith('a=candidate:'))
        .map((line) => line.match(/ typ (\w+)/)?.[1])),
  }))));
  assert.ok(rtcEvidence.every((peer) => peer.openChannels > 0 && peer.connectedPeers > 0),
    `Independent public profiles did not establish actual production RTC channels: ${JSON.stringify(rtcEvidence)}`);
  const beforeInspection = await history(a);
  await guestBiography(guest, 'public-guest-readonly-biography.png');
  await participantPanel(guest, ['Редактор устройства А, онлайн, редактор', 'Редактор устройства Б, онлайн, редактор',
    'Гость устройства, вы, онлайн, гость'], 'public-independent-participants.png');
  await converged(livePages);
  for (const page of livePages) assert.deepEqual(await history(page), beforeInspection, 'Guest read-only inspection wrote history.');
  console.log('PASS: three actual public RTC profiles converge; guest biography exposes no editing or identity commands and appends no history.');
  const bindingA = await bindEditor(a, livePages, actors[0], true);
  await counts([2, 2, 2]);
  await participantPanel(a, ['Редактор устройства А, вы, онлайн, редактор', 'Редактор устройства Б, онлайн, редактор', 'Гость устройства, онлайн, гость']);
  const bindingB = await bindEditor(b, livePages, actors[1]);
  await counts([1, 1, 1]);
  const groupedAlias = actors[0].localeCompare(actors[1]) < 0 ? 'Редактор устройства А' : 'Редактор устройства Б';
  const groupedGuestPanel = await participantPanel(guest, [`${groupedAlias}, онлайн, редактор`, 'Гость устройства, вы, онлайн, гость'],
    'public-editors-grouped-guest-separate.png');
  assert.doesNotMatch(groupedGuestPanel, /Алексей, онлайн, редактор/);
  const beforeReload = await history(a);
  for (const page of [b, guest]) {
    await page.reload({ waitUntil: 'domcontentloaded' });
    await activate(page);
    await page.getByRole('button', { name: 'Выбрать Алексей', exact: true }).waitFor({ timeout: 60000 });
  }
  await converged(livePages);
  await counts([1, 1, 1]);
  await openBio(b, true);
  assert.equal(await b.getByRole('button', { name: 'Это я', exact: true }).count(), 0);
  assert.match(await body(b), /Ваш профиль/);
  await closeBio(b);
  await guestBiography(guest, 'public-guest-reloaded-biography.png');
  for (const page of livePages) assert.deepEqual(await history(page), beforeReload, 'Editor/guest reload or viewing appended an edit.');
  const guestStorage = await storedRoom(guest);
  const roomId = JSON.parse(guestStorage['mytree.room-store.v1.last-room']);
  await fs.writeFile(path.join(output, 'legacy-guest-seed.json'), JSON.stringify({
    storage: guestStorage, journal: beforeReload, guestActor: actors[2], roomId,
  }, null, 2));
  const beforePromotion = await history(a);
  await a.getByRole('button', { name: /^Участники:/ }).click();
  await a.getByRole('button', { name: /^Гость устройства, онлайн, гость/ }).click();
  const confirmation = a.getByRole('alertdialog');
  await confirmation.getByRole('button', { name: 'Сделать редактором', exact: true }).click();
  await confirmation.waitFor({ state: 'hidden' });
  await a.getByRole('button', { name: 'Закрыть', exact: true }).click();
  await converged(livePages);
  const promotion = appendedHistory(beforePromotion, await history(a));
  assert.equal(promotion.length, 1, 'Explicit promotion must append one targeted role record.');
  assert.equal(promotion[0].kind, 'participantRole');
  assert.equal(promotion[0].targetActor, actors[2]);
  assert.equal(promotion[0].text, 'editor');
  await openBio(guest);
  await guest.getByRole('button', { name: 'Изменить', exact: true }).waitFor();
  await guest.getByRole('button', { name: 'Это я', exact: true }).waitFor();
  assert.doesNotMatch(await body(guest), /Ваш профиль/);
  await guest.screenshot({ path: path.join(output, 'public-promoted-unbound-editor.png'), animations: 'disabled' });
  await closeBio(guest);
  await counts([1, 1, 1]);
  await participantPanel(guest, [`${groupedAlias}, онлайн, редактор`, 'Гость устройства, вы, онлайн, редактор']);
  const bindingPromoted = await bindEditor(guest, livePages, actors[2]);
  await counts([0, 0, 0]);
  const allGrouped = await participantPanel(a, ['Редактор устройства А, вы, онлайн, редактор'], 'public-all-editors-grouped.png');
  assert.doesNotMatch(allGrouped, /Гость устройства,|Редактор устройства Б,/);
  const finalJournal = await history(a);
  const identityWrites = appendedHistory(beforeInspection, finalJournal);
  assert.equal(identityWrites.length, 4, 'Identity/read/reload flow produced unexpected hidden writes.');
  assert.deepEqual(new Set(identityWrites.map((record) => record.id)),
    new Set([bindingA.id, bindingB.id, promotion[0].id, bindingPromoted.id]));
  await guest.reload({ waitUntil: 'domcontentloaded' });
  await activate(guest);
  await guest.getByRole('button', { name: 'Выбрать Алексей', exact: true }).waitFor({ timeout: 60000 });
  await converged(livePages);
  await counts([0, 0, 0]);
  await openBio(guest);
  assert.match(await body(guest), /Ваш профиль/);
  assert.equal(await guest.getByRole('button', { name: 'Это я', exact: true }).count(), 0);
  await closeBio(guest);
  for (const page of livePages) assert.deepEqual(await history(page), finalJournal, 'Final reload changed the complete immutable journal.');
  assert.deepEqual(errors, []);
  await fs.writeFile(path.join(output, 'public-converged-journal.json'), JSON.stringify(finalJournal, null, 2));
  await fs.writeFile(path.join(output, 'public-guest-identity-checkpoint.json'), JSON.stringify({
    completed: true, scope: 'public identity flow, before isolated legacy fixture',
    actors, rtcEvidence, exactIdentityWrites: identityWrites, completeJournal: finalJournal,
    guestReadOnly: true, editorOnlyGrouping: true, explicitPromotionAndDurableBinding: true,
    editorAndGuestReloaded: true, noHiddenWrites: true, browserErrors: errors,
  }, null, 2));
  console.log('PASS: public guest read-only identity, editor-only grouping and reloads, explicit promotion then binding; exact four identity records and complete journal convergence.');
  await legacyGuestIdentity(browser, guestStorage, beforeReload, actors[2], roomId, errors, pages);
  assert.deepEqual(errors, []);
  await fs.writeFile(path.join(output, 'public-ui-regression.json'), JSON.stringify({
    application: base, suite: 'guest-identity', headless: true, completed: true, independentClients: 3,
    transport: 'actual production RTC, relay-only candidate policy', actors, rtcEvidence,
    guestBiographyReadOnly: true, guestHasNoIdentityButtonOrProfileLabel: true,
    twoEditorsGroupWithoutGuest: true, editorAndGuestReloadVerified: true,
    legacyGuestBindingIgnoredWithoutRewritingStorage: true, guestNameAndAvatarUnaffectedByLegacyBinding: true,
    roleNotInheritedFromPersonGroup: true, explicitPromotionThenDurableBinding: true,
    exactIdentityWrites: identityWrites, noHiddenWrites: true, completeJournalConvergence: true,
    completeConvergedJournalLength: finalJournal.length, browserErrors: errors,
  }, null, 2));
  console.log('PASS: three independent public RTC profiles; guest has read-only biography and no identity UI; editor-only grouping, exact durable promotion then explicit binding, complete immutable journals and reloads.');
}

function admissionSafeText(value) {
  return String(value).replace(/[0-9a-f]{32}/gi, '[synthetic-id]')
    .replace(/([?&](?:token|key|credential|password|id|peerId)=)[^\s&"']+/gi, '$1[redacted]')
    .replace(/(?:Bearer|OAuth)\s+[A-Za-z0-9._~-]+/gi, '[redacted-auth]');
}
function admissionEndpoint(value) {
  try { const url = new URL(value); return `${url.protocol}//${url.host}${url.pathname}`.replace(/[0-9a-f]{32}/gi, '[synthetic-id]'); }
  catch (_) { return admissionSafeText(value).split('?')[0]; }
}

// Observe complete MQTT packets, never retain payloads or split/rewrite messages.
function admissionMqttSummary(message) {
  if (typeof message === 'string') return { supported: false, reason: 'MQTT binary message expected.' };
  const packets = []; let offset = 0;
  while (offset < message.length) {
    const header = message[offset++]; let remaining = 0, multiplier = 1, lengthByte, count = 0;
    do {
      if (offset >= message.length || count++ === 4) return { supported: false, reason: 'Incomplete or invalid MQTT length.' };
      lengthByte = message[offset++]; remaining += (lengthByte & 127) * multiplier; multiplier *= 128;
    } while (lengthByte & 128);
    if (offset + remaining > message.length) return { supported: false, reason: 'MQTT packet crosses WebSocket-message boundary.' };
    const type = header >> 4;
    if (type < 1 || type > 14) return { supported: false, reason: 'Unknown MQTT packet type.' };
    packets.push({ type, success: type === 2 ? remaining === 2 && message[offset + 1] === 0 :
      type === 9 ? remaining >= 3 && Array.from(message.subarray(offset + 2, offset + remaining)).every((code) => code <= 2) : undefined });
    offset += remaining;
  }
  return { supported: packets.length > 0, packets };
}

async function admissionMqttStartupProxy(context, page, peer) {
  const latency = admissionReport.controlledLatency = { recipientOnly: true, origin: 'Native WebSocket constructor',
    connackTargetMilliseconds: 4200, subackTargetMilliseconds: 6550, readinessWindowMilliseconds: [7000, 8000],
    injectedSockets: 0, blockedPeerJs: [], sockets: [], errors: [], boundaries: 'Only real upstream CONNACK/SUBACK and subsequent ordered whole messages are delayed; outbound bytes and production timers/ICE/payloads are unchanged.' };
  const timers = new Set(); let stopped = false;
  const fail = (error) => latency.errors.push(admissionSafeText(error.message || error));
  await context.route(/^https?:\/\/([^/]+\.)?peerjs\.com(?::\d+)?\//i, (route) => {
    latency.blockedPeerJs.push({ transport: 'HTTP', endpoint: admissionEndpoint(route.request().url()), time: Date.now() });
    return route.abort('blockedbyclient');
  });
  await context.routeWebSocket((url) => /(^|\.)peerjs\.com$/i.test(url.hostname) || url.hostname === 'test.mosquitto.org', async (client) => {
    const address = new URL(client.url());
    if (/(^|\.)peerjs\.com$/i.test(address.hostname)) {
      latency.blockedPeerJs.push({ transport: 'WebSocket', endpoint: admissionEndpoint(client.url()), time: Date.now() });
      await client.close({ code: 1008, reason: 'Diagnostic: recipient PeerJS unavailable' }); return;
    }
    const entry = { peer, endpoint: admissionEndpoint(client.url()), time: Date.now(), forwarded: [], gates: [] };
    latency.sockets.push(entry);
    // The constructor wrapper records synchronously before the routed callback can run.
    const constructedAt = await page.evaluate((endpoint) => window.__admissionObservation.webSockets
      .filter((socket) => socket.endpoint === endpoint).at(-1)?.events[0]?.time, entry.endpoint);
    if (!Number.isFinite(constructedAt) || latency.injectedSockets !== 0) {
      entry.unverified = !Number.isFinite(constructedAt) ? 'Native construction timestamp unavailable.' : 'Reconnect: injection is never repeated.';
      client.connectToServer(); return;
    }
    latency.injectedSockets++;
    entry.constructedAt = constructedAt;
    const server = client.connectToServer();
    let pending = [], releaseAt = 0;
    const forward = (message, summary, receivedAt) => {
      client.send(message); // Original string/Buffer and complete message boundary preserved.
      entry.forwarded.push({ receivedAt, sentAt: Date.now(), bytes: message.length,
        sha256: require('node:crypto').createHash('sha256').update(message).digest('hex'), summary });
    };
    const release = () => {
      if (stopped) return;
      const held = pending; pending = []; releaseAt = 0;
      for (const item of held) forward(item.message, item.summary, item.receivedAt);
    };
    client.onMessage((message) => {
      const summary = admissionMqttSummary(message), time = Date.now();
      entry.forwarded.push({ direction: 'outgoing', time, bytes: message.length, summary });
      server.send(message); // No delay or credential/payload rewriting in this direction.
    });
    server.onMessage((message) => {
      if (stopped) return;
      try {
        const receivedAt = Date.now(), summary = admissionMqttSummary(message);
        if (!summary.supported) entry.unsupported = summary.reason;
        for (const [type, target] of [[2, 4200], [9, 6550]]) {
          if (summary.packets?.some((packet) => packet.type === type) && !entry.gates.some((gate) => gate.type === type)) {
            entry.gates.push({ type, actualUpstreamReceivedAt: receivedAt, intendedReleaseAt: constructedAt + target,
              upstreamArrivedBeforeTarget: receivedAt < constructedAt + target });
            releaseAt = Math.max(releaseAt, constructedAt + target);
          }
        }
        if (releaseAt > receivedAt || pending.length) {
          pending.push({ message, summary, receivedAt });
          if (pending.length === 1) {
            const timer = setTimeout(() => { timers.delete(timer); try { release(); } catch (error) { fail(error); } }, Math.max(0, releaseAt - Date.now()));
            timers.add(timer);
          }
        } else forward(message, summary, receivedAt);
      } catch (error) { fail(error); }
    });
  });
  return () => { stopped = true; for (const timer of timers) clearTimeout(timer); timers.clear(); };
}

async function admissionRtcEvidence(page) {
  return page.evaluate(async () => {
    const observation = window.__admissionObservation;
    if (!observation) return null;
    const peers = [];
    for (const [index, peer] of observation.peers.entries()) {
      let selectedCandidatePairs = [], statsError = null;
      try {
        const stats = await peer.getStats();
        const selected = [...stats.values()].filter((entry) => entry.type === 'transport' && entry.selectedCandidatePairId)
          .map((entry) => stats.get(entry.selectedCandidatePairId));
        const pairs = selected.length ? selected : [...stats.values()].filter((entry) => entry.type === 'candidate-pair' && entry.nominated && entry.state === 'succeeded');
        selectedCandidatePairs = pairs.map((pair) => {
          const local = stats.get(pair.localCandidateId), remote = stats.get(pair.remoteCandidateId);
          return { state: pair.state, nominated: pair.nominated, bytesSent: pair.bytesSent, bytesReceived: pair.bytesReceived,
            localType: local?.candidateType, remoteType: remote?.candidateType, protocol: local?.protocol,
            relayProtocol: local?.relayProtocol, networkType: local?.networkType };
        });
      } catch (_) { statsError = 'Native getStats unavailable for this peer.'; }
      peers.push({ index, connection: peer.connectionState, ice: peer.iceConnectionState, gathering: peer.iceGatheringState,
        signaling: peer.signalingState, policy: peer.getConfiguration().iceTransportPolicy,
        localDescriptionType: peer.localDescription?.type || null, remoteDescriptionType: peer.remoteDescription?.type || null,
        selectedCandidatePairs, statsError });
    }
    return { peers, channels: observation.channels.map((channel) => ({ state: channel.readyState, label: channel.label,
      bufferedAmount: channel.bufferedAmount })), webSockets: observation.webSockets, syncPackets: observation.syncPackets,
      configurations: observation.configurations, events: observation.events, gatheredCandidates: observation.candidates,
      gatheredCandidateCounts: observation.candidates.reduce((counts, candidate) => {
        counts[candidate.type] = (counts[candidate.type] || 0) + 1; return counts;
      }, {}), iceCandidateErrors: observation.iceErrors, handshakes: observation.handshakes };
  });
}

async function admissionProfile(browser, mobile) {
  const context = await browser.newContext({ viewport: mobile ? { width: 390, height: 844 } : { width: 1280, height: 900 },
    deviceScaleFactor: mobile ? 2 : 1, isMobile: mobile, hasTouch: mobile,
    permissions: ['clipboard-read', 'clipboard-write'], serviceWorkers: 'block' });
  await context.addInitScript(({ relayOnly }) => {
    window.__firstFrame = false;
    window.addEventListener('flutter-first-frame', () => { window.__firstFrame = true; }, { once: true });
    const observation = { peers: [], channels: [], configurations: [], events: [], candidates: [], iceErrors: [], handshakes: [], syncPackets: [], webSockets: [] };
    window.__admissionObservation = observation;
    const safeText = (value) => String(value).replace(/[0-9a-f]{32}/gi, '[synthetic-id]')
      .replace(/([?&](?:token|key|credential|password|id|peerId)=)[^\s&"']+/gi, '$1[redacted]');
    const endpoint = (value) => {
      try {
        const url = new URL(String(value).replace(/^(stuns?|turns?):(?!\/\/)/i, '$1://'));
        return `${url.protocol}//${url.host}${url.pathname}`.replace(/[0-9a-f]{32}/gi, '[synthetic-id]');
      } catch (_) { return '[unparseable endpoint]'; }
    };
    const NativeWebSocket = window.WebSocket;
    window.WebSocket = new Proxy(NativeWebSocket, { construct(target, args) {
      const socket = Reflect.construct(target, args), entry = { endpoint: endpoint(String(args[0])), state: socket.readyState,
        opened: false, events: [{ type: 'constructed', time: Date.now() }], messages: [] };
      observation.webSockets.push(entry);
      socket.addEventListener('message', async (event) => {
        const time = Date.now();
        try {
          let bytes = null, jsonType = null;
          if (typeof event.data === 'string') { try { jsonType = JSON.parse(event.data).type; } catch (_) {} }
          else bytes = new Uint8Array(event.data instanceof Blob ? await event.data.arrayBuffer() :
            ArrayBuffer.isView(event.data) ? event.data.buffer.slice(event.data.byteOffset, event.data.byteOffset + event.data.byteLength) : event.data);
          const mqttType = bytes?.length ? bytes[0] >> 4 : null;
          entry.messages.push({ time, jsonType: typeof jsonType === 'string' ? jsonType : null, mqttType,
            bytes: bytes?.length || null, registrationAck: jsonType === 'OPEN' || mqttType === 9 });
        } catch (_) { entry.messageObservationUnavailable = true; }
      });
      for (const type of ['open', 'close', 'error']) socket.addEventListener(type, (event) => {
        entry.state = socket.readyState; if (type === 'open') entry.opened = true;
        entry.events.push({ type, code: type === 'close' ? event.code : undefined,
          reason: type === 'close' ? safeText(event.reason || '') : undefined, time: Date.now() });
      });
      return socket;
    } });
    const packet = (value, direction) => {
      if (typeof value !== 'string') return;
      try {
        const data = JSON.parse(value);
        if (data.type === 'checkpoint' || data.type === 'syncAck') {
          observation.syncPackets.push({ direction, type: data.type, time: Date.now(),
            syncDigest: typeof data.syncDigest === 'string' && /^[0-9a-f]{64}$/.test(data.syncDigest) ? data.syncDigest : null });
          return;
        }
        if (data.type !== 'hello' && data.type !== 'welcome' && data.type !== 'reject' && data.type !== 'error') return;
        const capabilities = Object.fromEntries(Object.entries(data).filter(([key, value]) =>
          typeof value === 'boolean' && /^[a-zA-Z][a-zA-Z0-9]*$/.test(key)));
        observation.handshakes.push({ direction, type: data.type, capabilities, time: Date.now(),
          reason: typeof data.reason === 'string' ? safeText(data.reason) : undefined });
      } catch (_) { /* Binary fragments and ordinary edits are not handshake evidence. */ }
    };
    const tracked = new WeakSet();
    const trackChannel = (channel) => {
      if (tracked.has(channel)) return channel;
      tracked.add(channel); observation.channels.push(channel);
      channel.addEventListener('message', (event) => packet(event.data, 'incoming'));
      for (const type of ['open', 'close', 'error']) channel.addEventListener(type, () => observation.events.push({ type: `channel-${type}`, time: Date.now() }));
      return channel;
    };
    const nativeSend = RTCDataChannel.prototype.send;
    RTCDataChannel.prototype.send = function (...args) { packet(args[0], 'outgoing'); return nativeSend.apply(this, args); };
    const Native = window.RTCPeerConnection, nativeCreate = Native.prototype.createDataChannel;
    Native.prototype.createDataChannel = function (...args) { return trackChannel(nativeCreate.apply(this, args)); };
    window.RTCPeerConnection = new Proxy(Native, { construct(target, args) {
      // Only the explicitly selected relay diagnostic changes policy; keep the
      // production ICE servers, credentials and every other argument untouched.
      const nativeArgs = relayOnly ? [{ ...(args[0] || {}), iceTransportPolicy: 'relay' }, ...args.slice(1)] : args;
      const peer = Reflect.construct(target, nativeArgs), index = observation.peers.push(peer) - 1;
      observation.configurations.push({ peer: index, time: Date.now(), diagnosticRelayOnly: relayOnly,
        effectivePolicy: peer.getConfiguration().iceTransportPolicy,
        productionIceServersUnchanged: nativeArgs[0]?.iceServers === args[0]?.iceServers,
        iceServerEndpoints: (args[0]?.iceServers || []).flatMap((server) => {
          const urls = server.urls || server.url || []; return (Array.isArray(urls) ? urls : [urls]).map(endpoint);
        }) });
      peer.addEventListener('datachannel', (event) => trackChannel(event.channel));
      for (const type of ['connectionstatechange', 'iceconnectionstatechange', 'icegatheringstatechange', 'signalingstatechange']) peer.addEventListener(type, () =>
        observation.events.push({ peer: index, type, connection: peer.connectionState, ice: peer.iceConnectionState,
          gathering: peer.iceGatheringState, localDescriptionType: peer.localDescription?.type || null,
          remoteDescriptionType: peer.remoteDescription?.type || null, time: Date.now() }));
      peer.addEventListener('icecandidate', (event) => {
        if (!event.candidate) return;
        const candidate = event.candidate, type = candidate.type || / typ (\w+)/.exec(candidate.candidate)?.[1] || 'unknown';
        observation.candidates.push({ peer: index, type, protocol: candidate.protocol || null,
          relayProtocol: candidate.relayProtocol || null, time: Date.now() });
      });
      peer.addEventListener('icecandidateerror', (event) => observation.iceErrors.push({ peer: index,
        code: event.errorCode, text: safeText(event.errorText || ''), endpoint: endpoint(event.url || ''), time: Date.now() }));
      return peer;
    } });
  }, { relayOnly: relayAdmissionSuite });
  const page = await context.newPage(), peer = mobile ? 'recipient-phone-emulation' : 'host-desktop';
  page.setDefaultTimeout(12000);
  page.on('pageerror', (error) => admissionReport.pageErrors.push({ peer, text: admissionSafeText(error.message) }));
  page.on('console', (message) => admissionReport.consoleMessages.push({ peer, type: message.type(), text: admissionSafeText(message.text()) }));
  page.on('response', (response) => {
    if (admissionReport.http.length < 400) admissionReport.http.push({ peer, endpoint: admissionEndpoint(response.url()),
      status: response.status(), resourceType: response.request().resourceType() });
  });
  page.on('requestfailed', (request) => admissionReport.http.push({ peer, endpoint: admissionEndpoint(request.url()),
    failure: admissionSafeText(request.failure()?.errorText || 'requestfailed'), resourceType: request.resourceType() }));
  page.on('websocket', (socket) => {
    const endpoint = admissionEndpoint(socket.url());
    admissionReport.providerEvents.push({ peer, type: 'websocket-created', endpoint, time: Date.now() });
    for (const direction of ['framesent', 'framereceived']) socket.on(direction, ({ payload }) => {
      let messageType = null, detail = null;
      const buffer = typeof payload === 'string' ? Buffer.from(payload) : payload;
      try {
        const packet = JSON.parse(buffer.toString('utf8'));
        if (typeof packet.type === 'string') { messageType = packet.type;
          if (packet.type === 'ERROR') detail = admissionSafeText(String(packet.payload?.msg || packet.payload || 'provider-error')); }
      } catch (_) { /* MQTT WebSocket frames are binary, not JSON. */ }
      const mqttType = buffer.length ? buffer[0] >> 4 : null;
      const registrationAck = direction === 'framereceived' && (messageType === 'OPEN' || messageType === null && mqttType === 9);
      if (admissionReport.providerEvents.length < 800) admissionReport.providerEvents.push({ peer, direction, endpoint,
        jsonType: messageType, mqttType: messageType === null ? mqttType : undefined,
        mqttSummary: mqttStartupSuite && messageType === null ? admissionMqttSummary(buffer) : undefined, bytes: buffer.length,
        registrationAck, detail, time: Date.now() });
    });
    socket.on('close', () => admissionReport.providerEvents.push({ peer, type: 'websocket-closed', endpoint, time: Date.now() }));
    socket.on('socketerror', (error) => admissionReport.providerEvents.push({ peer, type: 'websocket-error', endpoint,
      error: admissionSafeText(error), time: Date.now() }));
  });
  const stopProxy = mqttStartupSuite && mobile ? await admissionMqttStartupProxy(context, page, peer) : null;
  return { page, context, peer, stopProxy };
}

function admissionTransportMilestones() {
  const latest = admissionReport.checkpoints.at(-1);
  const origin = admissionReport.recipientAdmissionStartedAt;
  const elapsed = (time) => origin && Number.isFinite(time) ? time - origin : null;
  return { timingOrigin: 'Recipient submits the anonymous admission form; negative offsets precede submission.',
    hostRegisteredBeforeInvitation: admissionReport.hostReady?.observedRegistrationBeforeInvitation || false,
    peers: (latest?.peers || []).map((profile) => {
      const rtc = profile.rtc;
      if (!rtc) return { peer: profile.peer, evidence: 'unavailable' };
      const relay = rtc.gatheredCandidates.filter((candidate) => candidate.type === 'relay');
      const descriptions = rtc.events.filter((event) =>
        ['offer', 'answer'].includes(event.localDescriptionType) && ['offer', 'answer'].includes(event.remoteDescriptionType) &&
        event.localDescriptionType !== event.remoteDescriptionType);
      const opened = rtc.events.filter((event) => event.type === 'channel-open');
      return { peer: profile.peer, policies: rtc.peers.map((peer) => peer.policy),
        productionIceServersUnchanged: rtc.configurations.length > 0 && rtc.configurations.every((config) => config.productionIceServersUnchanged),
        turnCandidateGathering: { observed: relay.length > 0, count: relay.length,
          firstObservedMilliseconds: elapsed(relay[0]?.time), candidateTypeCounts: rtc.gatheredCandidateCounts,
          nativeGatheringStates: rtc.peers.map((peer) => peer.gathering), errors: rtc.iceCandidateErrors },
        offerAnswerApplied: { observed: descriptions.length > 0, firstObservedMilliseconds: elapsed(descriptions[0]?.time),
          finalDescriptions: rtc.peers.map((peer) => ({ local: peer.localDescriptionType, remote: peer.remoteDescriptionType })) },
        selectedCandidatePairs: rtc.peers.flatMap((peer) => peer.selectedCandidatePairs),
        dataChannel: { everOpened: opened.length > 0, firstOpenedMilliseconds: elapsed(opened[0]?.time),
          currentlyOpen: rtc.channels.some((channel) => channel.state === 'open') },
        applicationHandshake: rtc.handshakes.map((packet) => ({ ...packet, elapsedMilliseconds: elapsed(packet.time) })) };
    }),
    durableAdmission: { verified: admissionReport.fullDurableSyntheticJournalsEqual === true && admissionReport.records === 4,
      verifiedMilliseconds: elapsed(admissionReport.durableAdmissionVerifiedAt),
      hostBaselineImmutable: admissionReport.hostBaselineRecordsUnchanged === true,
      fullDurableSyntheticJournalsEqual: admissionReport.fullDurableSyntheticJournalsEqual === true,
      records: admissionReport.records ?? null, journalSha256: admissionReport.journalSha256 || null } };
}

function admissionMqttStartupTiming(rtc) {
  const latency = admissionReport.controlledLatency, entry = latency?.sockets[0];
  assert.ok(entry && latency.injectedSockets === 1 && latency.sockets.length === 1, 'Exactly one MQTT latency injection without reconnect is required.');
  assert.deepEqual(latency.errors, []); assert.ok(!entry.unsupported, entry.unsupported);
  assert.ok(entry.gates.length === 2 && entry.gates.every((gate) => gate.upstreamArrivedBeforeTarget),
    'Late/unsupported upstream ACK cannot establish the controlled timing scenario.');
  const socket = rtc.webSockets.find((socket) => socket.endpoint === entry.endpoint && socket.events[0]?.time === entry.constructedAt);
  const connack = socket?.messages.find((message) => message.mqttType === 2), subacks = socket?.messages.filter((message) => message.mqttType === 9) || [];
  const subscriptions = entry.forwarded.filter((message) => message.direction === 'outgoing' && message.summary.packets?.some((packet) => packet.type === 8));
  const delivered = entry.forwarded.filter((message) => message.sentAt);
  const acceptedAcks = delivered.flatMap((message) => message.summary.packets || []).filter((packet) => packet.type === 9 && packet.success);
  assert.ok(connack && subacks.length && subscriptions.length >= 2 && acceptedAcks.length >= 2,
    'Real CONNACK and both real successful SUBACKs must reach the page.');
  const connackElapsed = connack.time - entry.constructedAt, lastSuback = subacks.at(-1).time;
  const subackElapsed = lastSuback - entry.constructedAt;
  const subscriptionElapsed = lastSuback - Math.min(...subscriptions.map((message) => message.time));
  const firstDialElapsed = Math.min(...rtc.configurations.map((config) => config.time)) - entry.constructedAt;
  const admittedElapsed = admissionReport.durableAdmissionVerifiedAt - admissionReport.recipientAdmissionStartedAt;
  const timing = latency.measured = { connackElapsedMilliseconds: connackElapsed, subackElapsedMilliseconds: subackElapsed,
    subscriptionElapsedMilliseconds: subscriptionElapsed, firstNativeRtcDialMilliseconds: firstDialElapsed,
    durableAdmissionMilliseconds: admittedElapsed, joinBudgetMilliseconds: 30000, timeoutBoundaryExercised: false,
    readinessEvidence: 'First native RTC dial after real MQTT registration/claim; not a private provider-ready hook.',
    modifiedProductionTimers: false };
  assert.ok(connackElapsed >= 4200 && connackElapsed < 4500 && connackElapsed < 5000, 'CONNACK delivery must fit the real five-second connect stage.');
  assert.ok(subackElapsed >= 6550 && subackElapsed < 6800 && subscriptionElapsed < 4000, 'Real SUBACKs must fit the real four-second subscription stage.');
  assert.ok(firstDialElapsed > 7000 && firstDialElapsed < 8000, 'Externally observed MQTT-only RTC dial must start after 7 seconds but before 8 seconds.');
  assert.ok(admittedElapsed < 30000, 'Real durable admission must finish within the unchanged 30-second join budget.');
  assert.ok(latency.blockedPeerJs.some((event) => event.transport === 'WebSocket'), 'Recipient PeerJS must actually be unavailable.');
  assert.ok(!rtc.webSockets.some((socket) => /peerjs/.test(socket.endpoint) && socket.messages.some((message) => message.jsonType === 'OPEN')),
    'No recipient PeerJS registration may substitute for MQTT fallback.');
  return timing;
}

async function firstAdmissionDiagnostic(browser) {
  const profiles = [], startedAt = Date.now(); let deadline, lastRuntimeSampleAt = 0;
  const budgetMilliseconds = relayAdmissionSuite || mqttStartupSuite ? 90000 : 120000;
  const workBudgetMilliseconds = relayAdmissionSuite || mqttStartupSuite ? 85000 : budgetMilliseconds;
  admissionReport.execution = { budgetMilliseconds, workBudgetMilliseconds, cleanupReserveMilliseconds: budgetMilliseconds - workBudgetMilliseconds,
    requestedIcePolicy: relayAdmissionSuite ? 'relay' : 'all', productionIceServersPreserved: true,
    diagnosticPolicyOverride: relayAdmissionSuite, retriesRequested: 0 };
  const sampleRuntime = async (label, force = false) => {
    const time = Date.now();
    if (!force && time - lastRuntimeSampleAt < 2000) return;
    lastRuntimeSampleAt = time;
    const peers = [];
    for (const profile of profiles) if (!profile.page.isClosed()) peers.push({ peer: profile.peer,
      semantics: admissionSafeText(await body(profile.page).catch(() => 'unavailable')),
      rtc: await admissionRtcEvidence(profile.page).catch(() => null) });
    admissionReport.runtimeSamples.push({ label, time, elapsedMilliseconds: time - startedAt,
      recipientAdmissionElapsedMilliseconds: admissionReport.recipientAdmissionStartedAt ? time - admissionReport.recipientAdmissionStartedAt : null,
      providerEventsObserved: admissionReport.providerEvents.length, peers });
    await fs.writeFile(path.join(output, 'admission-runtime-samples.json'), JSON.stringify(admissionReport.runtimeSamples, null, 2));
  };
  const saveCheckpoint = async (label) => {
    const entry = { label, stage: admissionReport.stage, elapsedMilliseconds: Date.now() - startedAt, peers: [] };
    for (const profile of profiles) if (!profile.page.isClosed()) {
      const page = profile.page, journal = await history(page).catch(() => null);
      entry.peers.push({ peer: profile.peer, url: admissionEndpoint(page.url()),
        semantics: admissionSafeText(await body(page).catch(() => 'unavailable')),
        completeSyntheticJournal: journal, rtc: await admissionRtcEvidence(page).catch(() => null) });
      await page.screenshot({ path: path.join(output, `${label}-${profile.peer}.png`), timeout: 1500 }).catch((error) => {
        entry.screenshotErrors ||= []; entry.screenshotErrors.push({ peer: profile.peer, error: admissionSafeText(error.message) });
      });
    }
    admissionReport.checkpoints.push(entry);
    await fs.writeFile(path.join(output, `${label}.json`), JSON.stringify(entry, null, 2));
    return entry;
  };
  try {
    await Promise.race([(async () => {
      admissionReport.stage = 'host-load';
      const host = await admissionProfile(browser, false); profiles.push(host);
      await load(host.page, base);
      admissionReport.stage = 'host-anonymous-create';
      await host.page.getByRole('button', { name: 'Создать комнату', exact: true }).click();
      const prompt = host.page.getByRole('alertdialog'); await prompt.getByText('Как вас зовут?', { exact: true }).waitFor();
      await prompt.getByRole('button', { name: 'Продолжить', exact: true }).click();
      await host.page.getByRole('button', { name: 'Выбрать Без имени', exact: true }).waitFor({ timeout: 45000 });
      const hostBaseline = await history(host.page);
      assert.equal(hostBaseline.length, 2); // Anonymous participant + editor grant, no person naming race.
      admissionReport.stage = 'host-signaling-registration';
      await waitUntil(async () => {
        await sampleRuntime('host-registration');
        const sockets = await host.page.evaluate(() => window.__admissionObservation.webSockets.filter((socket) => socket.opened && socket.state === 1).map((socket) => socket.endpoint));
        const events = admissionReport.providerEvents.filter((event) => event.peer === host.peer && sockets.includes(event.endpoint));
        if (mqttStartupSuite) return events.some((event) => event.jsonType === 'OPEN' && event.registrationAck) &&
          events.filter((event) => event.direction === 'framereceived').flatMap((event) => event.mqttSummary?.packets || [])
            .filter((packet) => packet.type === 9 && packet.success).length >= 2;
        return events.some((event) => event.registrationAck);
      }, 'Host did not receive a real PeerJS OPEN or MQTT subscription acknowledgment on a currently open socket before invitation.', 35000);
      const hostStatus = await host.page.getByRole('button', { name: /^Участники:/ }).ariaSnapshot();
      assert.match(hostStatus, /Участники:/);
      assert.doesNotMatch(hostStatus, /Нет подключения к сети/);
      admissionReport.hostReady = { observedRegistrationBeforeInvitation: true, participantStatus: admissionSafeText(hostStatus),
        bothProvidersRegistered: mqttStartupSuite ? true : undefined,
        elapsedMilliseconds: Date.now() - startedAt };
      await saveCheckpoint('admission-host-registered');
      admissionReport.stage = 'copy-actual-guest-invitation';
      const invitation = await invite(host.page, 'guest'); // Real clipboard URL, not address-bar reconstruction.
      const copied = new URL(invitation), application = new URL(base);
      assert.equal(copied.origin, application.origin); assert.equal(copied.pathname, application.pathname);
      assert.equal(new URLSearchParams(copied.hash.slice(1)).get('role'), 'guest');
      admissionReport.invitation = { actualUiClipboard: true, role: 'guest', hostingPath: copied.pathname,
        sha256: require('node:crypto').createHash('sha256').update(invitation).digest('hex'), roomIdentity: 'fresh synthetic room only; no existing user room or credential input' };
      admissionReport.stage = 'fresh-phone-recipient-load';
      const recipient = await admissionProfile(browser, true); profiles.push(recipient);
      await load(recipient.page, invitation);
      const name = recipient.page.getByRole('alertdialog'); await name.getByText('Как вас зовут?', { exact: true }).waitFor();
      admissionReport.stage = 'fresh-phone-first-admission';
      admissionReport.recipientAdmissionStartedAt = Date.now();
      await name.getByRole('button', { name: 'Продолжить', exact: true }).click();
      await sampleRuntime('recipient-admission-start', true);
      let entryFailure = null;
      await waitUntil(async () => {
        await sampleRuntime('recipient-admission-progress');
        const semantics = await body(recipient.page);
        if (/Выбрать Без имени/.test(semantics)) return true;
        if (/Не удалось подключиться за 30 секунд|Не удалось присоединиться|несовместим|не поддержива|отклонил|Отказано/i.test(semantics)) { entryFailure = admissionSafeText(semantics); return true; }
        return false;
      }, 'Fresh recipient did not reach the tree or a concrete production admission error within 45 seconds.', 45000);
      await sampleRuntime('recipient-admission-result', true);
      await saveCheckpoint('admission-recipient-result');
      if (entryFailure) throw new Error(`Actual first admission failed: ${entryFailure}`);
      admissionReport.stage = 'complete-durable-journal-convergence';
      await converged([host.page, recipient.page]);
      const final = await history(host.page); assert.deepEqual(await history(recipient.page), final);
      for (const old of hostBaseline) assert.deepEqual(final.find((record) => record.id === old.id), old);
      assert.equal(final.length, 4, 'Two anonymous members and two durable roles are the only expected admission records.');
      assert.equal(final.filter((record) => record.kind === 'participantRole' && record.text === 'guest').length, 1);
      Object.assign(admissionReport, { records: final.length, fullDurableSyntheticJournalsEqual: true, hostBaselineRecordsUnchanged: true,
        durableAdmissionVerifiedAt: Date.now(), journalSha256: require('node:crypto').createHash('sha256').update(JSON.stringify(final)).digest('hex') });
      const rtc = await Promise.all(profiles.map((profile) => admissionRtcEvidence(profile.page)));
      const expectedPolicy = relayAdmissionSuite ? 'relay' : 'all';
      assert.ok(rtc.every((entry) => entry.configurations.length > 0 && entry.configurations.every((config) => config.productionIceServersUnchanged)),
        'The diagnostic must preserve the actual production ICE server list and credentials.');
      assert.ok(rtc.every((entry) => entry.channels.some((channel) => channel.state === 'open') &&
        entry.peers.some((peer) => peer.connection === 'connected' && peer.policy === expectedPolicy && peer.selectedCandidatePairs.length &&
          (!relayAdmissionSuite || peer.selectedCandidatePairs.every((pair) => pair.localType === 'relay' && pair.remoteType === 'relay')))),
      `Actual ${expectedPolicy} ICE connection/selected pair and open channels are required on both profiles.`);
      assert.ok(rtc.every((entry) => entry.peers.some((peer) =>
        ['offer', 'answer'].includes(peer.localDescriptionType) && ['offer', 'answer'].includes(peer.remoteDescriptionType) &&
        peer.localDescriptionType !== peer.remoteDescriptionType)), 'Both profiles must actually apply an offer and answer, without retaining SDP.');
      if (relayAdmissionSuite) assert.ok(rtc.every((entry) => entry.gatheredCandidateCounts.relay > 0),
        'Relay admission must include a real gathered relay candidate on both profiles, not just signaling success.');
      const handshakes = rtc.flatMap((entry) => entry.handshakes);
      assert.ok(['hello', 'welcome'].every((type) => handshakes.some((packet) => packet.type === type)),
        'Real application hello/welcome were not observed; tree visibility alone is insufficient.');
      if (mqttStartupSuite) {
        const sync = rtc.flatMap((entry) => entry.syncPackets);
        const matched = sync.filter((packet) => packet.type === 'syncAck' && packet.direction === 'incoming' && packet.syncDigest &&
          sync.some((other) => other.type === 'syncAck' && other.direction === 'outgoing' && other.syncDigest === packet.syncDigest) &&
          sync.some((other) => other.type === 'checkpoint' && other.syncDigest === packet.syncDigest));
        assert.ok(matched.length, 'Real delivered syncAck matching an observed checkpoint is required; journal equality alone is not ACK evidence.');
        admissionReport.actualSyncAcks = matched.map((packet) => ({ ...packet,
          elapsedMilliseconds: packet.time - admissionReport.recipientAdmissionStartedAt,
          matchesFinalJournal: packet.syncDigest === initialSyncDigest(final), matchesHostBaseline: packet.syncDigest === initialSyncDigest(hostBaseline) }));
        admissionReport.mqttStartupTiming = admissionMqttStartupTiming(rtc[1]);
      }
      await fs.writeFile(path.join(output, 'admission-complete-synthetic-journal.json'), JSON.stringify(final, null, 2));
      await saveCheckpoint('admission-complete-convergence');
      assert.deepEqual(admissionReport.pageErrors, []);
      assert.ok(!admissionReport.consoleMessages.some((entry) => compactFlutterFailure.test(entry.text)), 'Flutter rendering failure in actual public browser.');
      Object.assign(admissionReport, { completed: true, stage: 'complete', elapsedMilliseconds: Date.now() - startedAt,
        firstAdmissionPassed: true, relayOnlyAdmissionPassed: relayAdmissionSuite ? true : undefined,
        controlledMqttStartupPassed: mqttStartupSuite ? true : undefined,
        productionIcePolicyUnchanged: !relayAdmissionSuite, iceTransportPolicy: expectedPolicy,
        independentProfiles: ['desktop host', '390x844 phone-emulated recipient'],
        rtc, handshakes,
        limitations: ['Same machine/desktop browser with phone emulation is not a physical phone or cross-NAT proof.',
          relayAdmissionSuite ? 'Only relay policy is diagnostic; actual production ICE servers and credentials are preserved. Any relay success covers this machine/network/time only.' :
            'Selected host/srflx/relay candidate types are reported, never assumed to establish public TURN reachability.',
          mqttStartupSuite ? 'Controlled latency only: recipient PeerJS blocked; real MQTT CONNACK/SUBACK delivery delayed, with unchanged whole-message bytes/order. Native RTC dial is external readiness evidence; the 30-second failure boundary is not exercised by an earlier successful join.' :
            'No provider rewriting, added server/credential, TLS bypass, extra recipient, localhost comparison, reload, old matrix, account or credential-file access.'] });
    })(), new Promise((_, reject) => {
      deadline = setTimeout(() => reject(new Error(`Finite ${suite} reached its ${workBudgetMilliseconds / 1000}-second work deadline; report partial and close owned contexts.`)), workBudgetMilliseconds);
    })]);
  } catch (error) {
    admissionReport.failure = admissionSafeText(error.stack || error);
    admissionReport.elapsedMilliseconds = Date.now() - startedAt;
    await saveCheckpoint('admission-failure');
    process.exitCode = 1;
  } finally {
    clearTimeout(deadline);
    for (const profile of profiles) profile.stopProxy?.();
    try {
      admissionReport.transportMilestones = admissionTransportMilestones();
      await fs.writeFile(path.join(output, 'admission-transport-milestones.json'), JSON.stringify(admissionReport.transportMilestones, null, 2));
      await fs.writeFile(path.join(output, `${suite}.json`), JSON.stringify(admissionReport, null, 2));
    } finally {
      await Promise.all(profiles.map((profile) => profile.context.close()));
    }
  }
}

async function connectedRelayEvidence(page) {
  const evidence = await page.evaluate(async () => ({
    openChannels: (window.__channels || []).filter((channel) => channel.readyState === 'open').length,
    peers: await Promise.all((window.__peerConnections || []).map(async (peer) => {
      const stats = await peer.getStats();
      const selected = [...stats.values()].filter((entry) => entry.type === 'transport' && entry.selectedCandidatePairId)
        .map((entry) => stats.get(entry.selectedCandidatePairId));
      const pairs = selected.length ? selected : [...stats.values()].filter((entry) =>
        entry.type === 'candidate-pair' && entry.state === 'succeeded' && entry.nominated);
      return { state: peer.connectionState, policy: peer.getConfiguration().iceTransportPolicy,
        candidatePairs: pairs.map((pair) => ({ state: pair.state,
          localType: stats.get(pair.localCandidateId)?.candidateType,
          remoteType: stats.get(pair.remoteCandidateId)?.candidateType })) };
    })),
  }));
  assert.ok(evidence.openChannels > 0 && evidence.peers.some((peer) => peer.state === 'connected' &&
    peer.policy === 'relay' && peer.candidatePairs.some((pair) => pair.localType === 'relay')),
  `Actual connected relay RTC channel is required: ${JSON.stringify(evidence)}`);
  return evidence;
}

async function publicSurnames(a, b, errors) {
  const peopleButton = (page, name) => page.getByRole('button', { name: `Выбрать ${name}`, exact: true });
  const surnameField = (page) => page.getByRole('textbox', { name: /^Фамилия(?:\s|$)/ });
  const decline = (page) => page.getByRole('checkbox', { name: 'склонять', exact: true });
  const search = (page) => page.getByRole('textbox', { name: 'Поиск по дереву', exact: true });
  const after = async (page, before) => appendedHistory(before, await history(page)).map((record) => {
    assert.equal(record.kind, 'tree'); return JSON.parse(record.text);
  });
  const browse = async (page, name, fullName) => {
    await type(page, search(page), fullName || name);
    const option = page.getByRole('button', { name: new RegExp(`^${fullName || name}${fullName ? ',' : '(?: |,)'}`) });
    await option.waitFor();
    assert.equal(await option.count(), 1);
    await option.click();
    await sleep(350);
    await peopleButton(page, name).waitFor(); // Canvas names remain given-name only.
  };
  const openPerson = async (page, name, edit = true) => {
    await browse(page, name);
    await openBio(page, edit);
    await sleep(250);
  };
  const activeSurnameField = async (page, expected, checked = true) => {
    const field = surnameField(page);
    await revealBiographyAction(page, field, -1);
    await focusInput(page, field, expected);
    assert.equal(await field.count(), 1, 'One personal surname input is required.');
    assert.equal(await decline(page).count(), 1);
    assert.equal(await decline(page).isChecked(), checked);
    assert.equal(await page.getByRole('checkbox', { name: 'отдельная', exact: true }).count(), 0);
    assert.equal(await page.getByRole('switch', { name: /фамилия|отдельная/i }).count(), 0);
    assert.doesNotMatch(await body(page), /до замужества|Фамилия блока|Фамилия человека|Указана для блока/);
    const boxes = await Promise.all([field, decline(page)].map((control) => control.boundingBox()));
    assert.ok(boxes.every((box) => box && box.x >= 0 && box.x + box.width <= page.viewportSize().width + 1));
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), page.viewportSize().width,
      'The personal surname controls caused horizontal overflow.');
    return field;
  };
  const checkpoint = async (label) => {
    assert.deepEqual(errors, [], `${label}: browser/console/Flutter errors were observed.`);
    for (const [index, page] of [a, b].entries()) await page.screenshot({
      path: path.join(output, `${label}-peer-${index + 1}.png`), animations: 'disabled' });
    await fs.writeFile(path.join(output, `${label}-errors.json`), JSON.stringify({ errors, consoleMessages: publicSurnameTrace.consoleMessages }, null, 2));
  };
  await load(a, base);
  await a.getByRole('button', { name: 'Создать комнату', exact: true }).click();
  await admissionName(a, 'Редактор фамилии А');
  await peopleButton(a, 'Без имени').waitFor({ timeout: 60000 });
  await openBio(a, true);
  await type(a, a.getByRole('textbox', { name: 'Имя', exact: true }), 'Алексей');
  await newRelative(a, 'Отца', 'Николай');
  await newRelative(a, 'Мать', 'Мария');
  await closeBio(a);
  await openPerson(a, 'Николай');
  await newRelative(a, 'Ребёнка', 'Борис');
  await closeBio(a);
  await openPerson(a, 'Борис');
  const add = a.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiographyAction(a, add);
  await add.click();
  let dialog = a.getByRole('alertdialog');
  await dialog.getByRole('button', { name: /^Кого добавить/ }).click();
  await a.getByRole('menuitem', { name: 'Мать', exact: true }).click();
  await dialog.getByRole('button', { name: 'Выбрать', exact: true }).click();
  await a.getByRole('button', { name: 'Отмена выбора', exact: true }).waitFor();
  await type(a, search(a), 'Мария');
  await a.getByRole('button', { name: /^Мария,/ }).click();
  await a.getByRole('button', { name: /^Подтвердить выбор(?:\s|$)/ }).click();
  await dialog.waitFor();
  assert.match(await dialog.ariaSnapshot(), /Мария/);
  await dialog.getByRole('button', { name: 'Добавить', exact: true }).click();
  await dialog.waitFor({ state: 'hidden' });
  await closeBio(a);
  for (const [person, child] of [['Алексей', 'Ребёнок Алексея'], ['Борис', 'Ребёнок Бориса']]) {
    await openPerson(a, person);
    await newRelative(a, 'Ребёнка', child);
    await closeBio(a);
  }
  await openPerson(a, 'Николай');
  await type(a, await activeSurnameField(a, ''), 'Иванов');
  await waitUntil(async () => (await history(a)).some((record) => record.kind === 'tree' &&
    JSON.parse(record.text).type === 'setSurname' && JSON.parse(record.text).text === 'Иванов'), 'Initial father surname was not stored.');
  await closeBio(a);
  const initial = await history(a);
  const tree = initial.filter((record) => record.kind === 'tree').map((record) => JSON.parse(record.text));
  const father = tree.find((op) => op.type === 'createPerson' && op.name === 'Николай').personId;
  const mother = tree.find((op) => op.type === 'createPerson' && op.name === 'Мария').personId;
  const brother = tree.find((op) => op.type === 'createPerson' && op.name === 'Борис').personId;
  const ownChild = tree.find((op) => op.type === 'createPerson' && op.name === 'Ребёнок Алексея').personId;
  const otherChild = tree.find((op) => op.type === 'createPerson' && op.name === 'Ребёнок Бориса').personId;
  for (const [child, parent] of [[ownChild, 'root'], [otherChild, brother]]) assert.ok(tree.some((op) =>
    op.type === 'setValue' && op.personId === child && op.field === 'fatherId' && op.value === parent),
  'Public fixture child must inherit from its actual UI-created father edge.');
  const editorInvite = await invite(a, 'editor');
  await load(b, editorInvite);
  await admissionName(b, 'Редактор фамилии Б');
  await peopleButton(b, 'Алексей').waitFor({ timeout: 60000 });
  await converged([a, b]);
  const handshakes = await Promise.all([a, b].map((page) => page.evaluate(() => window.__observedHandshakes)));
  assert.ok(handshakes.every((packets) => packets.some((packet) => packet.familyTree === true &&
    packet.familySurnames === true && packet.personalSurnames === true)),
  `Actual production peers did not negotiate personal surname semantics: ${JSON.stringify(handshakes)}`);
  assert.ok(['hello', 'welcome'].every((type) => handshakes.flat().some((packet) => packet.type === type && packet.personalSurnames === true)),
    'Need observed production hello and welcome, not injected capability bits.');
  const rtcEvidence = await Promise.all([a, b].map(connectedRelayEvidence));
  const beforeA = await history(a);
  await fs.writeFile(path.join(output, 'public-personal-journal-before.json'), JSON.stringify(beforeA, null, 2));
  const writes = [];
  const write = async (page, personId, text, checked, toggle = false) => {
    const before = await history(page);
    if (toggle) { await revealBiographyAction(page, decline(page)); await decline(page).click(); }
    else await type(page, surnameField(page), text ?? '');
    await waitUntil(async () => (await history(page)).length > before.length, 'Actual surname editor did not persist its write.');
    await converged([a, b]);
    const operations = await after(page, before);
    const expected = { type: 'setSurname', personId, scope: 'individual', familyKey: null, text, decline: text ? checked : false };
    assert.ok(operations.length && operations.every((op) => op.type === 'setSurname' && op.personId === personId &&
      op.scope === 'individual' && op.familyKey === null && op.decline === expected.decline),
    `Public personal edit escaped into shared/maiden/descendant writes: ${JSON.stringify(operations)}`);
    if (toggle || text === null) assert.deepEqual(operations, [expected], 'Public toggle/clear must append exactly one operation.');
    else assert.ok(operations.some((op) => op.text === text), 'Public edit lost its final typed value.');
    writes.push({ personId, text, checked, operations });
    await activeSurnameField(page, text ?? '', text ? checked : true);
  };
  const names = async (label, own, other) => {
    const before = await history(a);
    const labels = [];
    for (const [index, page] of [a, b].entries()) {
      for (const [name, surname] of [['Алексей', own], ['Борис', other], ['Ребёнок Алексея', own], ['Ребёнок Бориса', other]]) {
        await browse(page, name, `${name} ${surname}`);
        labels.push({ peer: index + 1, fullName: `${name} ${surname}` });
      }
    }
    assert.deepEqual(await history(a), before, 'Public name/search inspection wrote hidden records.');
    assert.deepEqual(await history(b), before, 'Public name/search inspection changed peer journal.');
    publicSurnameTrace.checkpoints.push({ label, labels, journalLength: before.length });
    await checkpoint(label);
  };
  await openPerson(a, 'Алексей');
  await openPerson(b, 'Борис');
  await activeSurnameField(a, '');
  await activeSurnameField(b, '');
  assert.deepEqual(await history(a), beforeA, 'Opening inherited controls wrote/migrated history.');
  await checkpoint('personal-inherited-controls');
  await write(a, 'root', 'Орлов', true);
  await activeSurnameField(b, ''); // Another full sibling must not receive explicit text.
  await closeBio(a); await closeBio(b);
  await names('personal-own-descendants-only', 'Орлов', 'Иванов');
  await openPerson(a, 'Алексей');
  await activeSurnameField(a, 'Орлов');
  await write(a, 'root', 'Орлов', false, true);
  await closeBio(a);
  await openPerson(b, 'Борис');
  await activeSurnameField(b, '');
  await write(b, brother, 'Ким', true);
  await closeBio(b);
  await names('personal-other-editor-isolated', 'Орлов', 'Ким');
  await openPerson(a, 'Алексей');
  await activeSurnameField(a, 'Орлов', false);
  await write(a, 'root', null, false);
  assert.match(await body(a), /Наследуется от отца: Николай Иванов/);
  await closeBio(a);
  await names('personal-clear-father-inheritance', 'Иванов', 'Ким');
  await openPerson(a, 'Николай');
  await activeSurnameField(a, 'Иванов');
  await write(a, father, 'Петров', true);
  await closeBio(a);
  await names('personal-father-propagates-unless-explicit', 'Петров', 'Ким');
  await openPerson(b, 'Борис');
  await activeSurnameField(b, 'Ким');
  await write(b, brother, null, false);
  await closeBio(b);
  await names('personal-both-cleared-inherit', 'Петров', 'Петров');
  const convergedJournal = await history(a);
  assert.deepEqual(await history(b), convergedJournal, 'Complete persistent journals differ after personal writers.');
  appendedHistory(initial, convergedJournal);
  const surnameEdits = await after(a, beforeA);
  assert.ok(surnameEdits.every((op) => op.type === 'setSurname' && op.scope === 'individual' && op.familyKey === null &&
    [father, 'root', brother].includes(op.personId)), 'Public flow emitted a shared/maiden/descendant or unrelated edit.');
  for (const [index, page] of [a, b].entries()) {
    await openPerson(page, index ? 'Борис' : 'Алексей', false);
    if (!index) await page.getByText('Алексей Петров', { exact: true }).waitFor();
    assert.equal(await surnameField(page).count(), 0, 'Readonly biography exposes surname controls.');
    await page.screenshot({ path: path.join(output, `personal-readonly-peer-${index + 1}.png`), animations: 'disabled' });
    await closeBio(page);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await activate(page);
    await peopleButton(page, 'Алексей').waitFor({ timeout: 60000 });
    await converged([a, b]);
    assert.deepEqual(await history(page), convergedJournal, 'Reload lost or rewrote the complete personal surname journal.');
    await openPerson(page, index ? 'Борис' : 'Алексей');
    await activeSurnameField(page, '');
    assert.match(await body(page), /Наследуется от отца: Николай Петров/);
    await page.screenshot({ path: path.join(output, `personal-reloaded-peer-${index + 1}.png`), animations: 'disabled' });
    await closeBio(page);
    await fs.writeFile(path.join(output, `public-personal-peer-${index + 1}-reloaded-journal.json`), JSON.stringify(await history(page), null, 2));
  }
  await names('personal-both-reloaded-descendants', 'Петров', 'Петров');
  assert.deepEqual(await history(a), convergedJournal, 'Readonly/reload appended an unwanted operation.');
  assert.deepEqual(errors, []);
  const crypto = require('node:crypto');
  const digest = crypto.createHash('sha256').update(JSON.stringify(convergedJournal)).digest('hex');
  await fs.writeFile(path.join(output, 'public-converged-journal.json'), JSON.stringify(convergedJournal, null, 2));
  await fs.writeFile(path.join(output, 'public-ui-regression.json'), JSON.stringify({
    application: base, suite, headless: true, completed: true, independentClients: 2,
    transport: 'actual production RTC, relay-only candidate policy; no capability rewriting', handshakes, rtcEvidence,
    fullSiblingIds: ['root', brother], father, mother, ownChild, otherChild, writes, trace: publicSurnameTrace,
    personalOnly: true, siblingAndOtherBranchUnaffected: true, ownDescendantsInheritFather: true,
    clearResumesFatherInheritance: true, explicitStopsFatherPropagation: true, noScopeToggle: true,
    exactOneOperationToggleAndClears: true, noSharedMaidenOrDescendantWrites: true,
    completeJournalConvergence: true, completeConvergedJournalLength: convergedJournal.length, journalSha256: digest,
    immutableHistoryPreserved: true, bothIndependentProfilesReloadVerified: true, browserErrors: errors,
    limitations: ['Finite current-client public RTC flow, not all provider/network conditions.',
      'Old-client refusal is owned by protocol/session unit tests, not a browser handshake-stripping simulation.'],
  }, null, 2));
  console.log('PASS: actual public RTC personalSurnames hello/welcome; two independent personal writers, sibling/descendant isolation, clear/father inheritance, immutable convergence and both reloads.');
}

async function publicExplicitSiblings(a, b, errors) {
  const selected = (page, name) => page.getByRole('button', { name: `Выбрать ${name}`, exact: true });
  const chip = (page, name) => page.getByRole('checkbox', { name, exact: true })
    .or(page.getByRole('button', { name, exact: true }));
  const directLabel = 'Убрать прямую братскую связь';
  const checkpoint = async (label) => {
    const entry = { label, errors: [...errors], peers: [] };
    for (const [index, page] of [a, b].entries()) {
      const semantics = await body(page);
      assert.doesNotMatch(semantics, /Не сохранено:|Не удалось добавить родственника|EXCEPTION CAUGHT|RenderFlex.*overflow/);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), page.viewportSize().width);
      await page.screenshot({ path: path.join(output, `${label}-peer-${index + 1}.png`), animations: 'disabled' });
      entry.peers.push({ peer: index + 1, semantics, completeJournal: await history(page) });
    }
    publicSiblingReport.steps.push(entry);
    await fs.writeFile(path.join(output, `${label}.json`), JSON.stringify(entry, null, 2));
    assert.deepEqual(errors, [], `${label}: public browser/console/Flutter errors.`);
  };
  const openPerson = async (page, name) => {
    await selected(page, name).click(); await sleep(280); await openBio(page, true); await sleep(150);
  };
  const addDialog = async (page, source, kind) => {
    await openPerson(page, source);
    const add = page.getByRole('button', { name: 'Добавить родственника', exact: true });
    await revealBiographyAction(page, add); await add.click();
    const dialog = page.getByRole('alertdialog');
    await dialog.getByRole('button', { name: /^Кого добавить/ }).click();
    await page.getByRole('menuitem', { name: kind, exact: true }).click();
    return dialog;
  };
  const delta = async (page, before, count, label) => {
    await waitUntil(async () => (await history(page)).length >= before.length + count, `${label}: UI command was not durable.`, 12000);
    await converged([a, b]);
    const records = appendedHistory(before, await history(page));
    assert.equal(records.length, count, `${label}: unexpected side writes.`);
    const operations = records.map((record) => { assert.equal(record.kind, 'tree'); return JSON.parse(record.text); });
    publicSiblingReport.steps.push({ label, records, operations, fullJournalConvergence: true });
    return { records, operations };
  };
  const addSibling = async (page, source, sourceId, kind, name, label) => {
    const before = await history(page), dialog = await addDialog(page, source, 'Брат/сестра');
    assert.equal(await dialog.getByRole('button', { name: 'Выбрать', exact: true }).count(), 0);
    assert.equal(await dialog.getByRole('checkbox', { name: 'Из дерева', exact: true }).count(), 0);
    assert.equal(await dialog.getByRole('checkbox', { name: 'Новый человек', exact: true }).count(), 0);
    const sex = dialog.getByRole('button', { name: /^Пол(?:\s|$)/ });
    await sex.click();
    for (const option of ['Пол не указан', 'Мужской', 'Женский']) await page.getByRole('menuitem', { name: option, exact: true }).waitFor();
    const expectedSex = kind === 'Брат' ? 'Мужской' : 'Женский';
    await page.getByRole('menuitem', { name: expectedSex, exact: true }).click();
    assert.match(await sex.getAttribute('aria-label') || await sex.innerText(), new RegExp(expectedSex));
    assert.deepEqual(await history(page), before, `${label}: opening sibling controls wrote history.`);
    await type(page, dialog.getByRole('textbox', { name: 'Имя нового человека', exact: true }), name);
    await dialog.getByRole('button', { name: 'Добавить', exact: true }).click(); await dialog.waitFor({ state: 'hidden' });
    const saved = await delta(page, before, 1, label), op = saved.operations[0];
    assert.deepEqual(op, { type: 'createSibling', personId: op.personId, siblingId: sourceId,
      name, sex: kind === 'Брат' ? 'male' : 'female', birthDate: null });
    await closeBio(page);
    return { ...op, linkId: saved.records[0].id };
  };
  const addParent = async (page, source, sourceId, kind, name, label) => {
    const before = await history(page), dialog = await addDialog(page, source, kind);
    await dialog.getByRole('checkbox', { name: 'Новый человек', exact: true }).click();
    await type(page, dialog.getByRole('textbox', { name: 'Имя нового человека', exact: true }), name);
    await dialog.getByRole('button', { name: 'Добавить', exact: true }).click(); await dialog.waitFor({ state: 'hidden' });
    const saved = await delta(page, before, 2, label), created = saved.operations.find((op) => op.type === 'createPerson');
    assert.ok(created && created.name === name && created.sex === (kind === 'Отца' ? 'male' : 'female'));
    assert.deepEqual(saved.operations.filter((op) => op.type !== 'createPerson'), [{ type: 'setValue', personId: sourceId,
      field: kind === 'Отца' ? 'fatherId' : 'motherId', value: created.personId }]);
    await closeBio(page); return created;
  };
  const inspect = async (page, source, expected, label) => {
    const before = await history(page); await openPerson(page, source);
    for (const [name, present, direct] of expected) {
      const relative = chip(page, name);
      assert.equal(await relative.count(), present ? 1 : 0, `${label}: actual ${source}↔${name} relation differs.`);
      if (present) {
        await revealBiographyAction(page, relative);
        assert.equal(await relative.getByRole('button', { name: directLabel, exact: true }).count(), direct ? 1 : 0,
          `${label}: direct-only sibling X differs.`);
      }
    }
    assert.deepEqual(await history(page), before, `${label}: inspecting relatives appended history.`);
    publicSiblingReport.steps.push({ label, actualUiRelations: expected, openingHistoryUnchanged: true });
    await page.screenshot({ path: path.join(output, `${label}.png`), animations: 'disabled' });
    await closeBio(page);
  };
  const geometry = async (page, label, groups) => {
    const nodes = {};
    for (const name of ['Алексей', 'Борис', 'Вера']) {
      const box = await selected(page, name).boundingBox(); assert.ok(box, `${label}: missing card ${name}.`);
      nodes[name] = box;
      assert.ok(box.x >= 0 && box.y >= 150 && box.x + box.width <= page.viewportSize().width &&
        box.y + box.height <= page.viewportSize().height, `${label}: tiny-fixture card clipped.`);
      assert.ok(Math.abs(box.y - nodes['Алексей'].y) <= 1.5, `${label}: sibling ranks differ.`);
    }
    const row = Object.keys(nodes).sort((x, y) => nodes[x].x - nodes[y].x);
    for (let index = 1; index < row.length; index++) {
      const first = row[index - 1], second = row[index], same = groups.some((group) => group.includes(first) && group.includes(second));
      const pitch = nodes[second].x - nodes[first].x;
      assert.ok(same ? Math.abs(pitch - 132) <= 1.5 : pitch >= 156 - 1.5,
        `${label}: sibling member/minimum separate-block pitch differs.`);
    }
    for (const group of groups) {
      const actual = row.filter((name) => group.includes(name));
      assert.deepEqual(actual, group, `${label}: canonical undated given-name order differs.`);
      const indices = actual.map((name) => row.indexOf(name));
      assert.equal(indices.at(-1) - indices[0], group.length - 1, `${label}: sibling block interleaved.`);
    }
    publicSiblingReport.steps.push({ label, nodes, groups });
  };
  await load(a, base);
  await a.getByRole('button', { name: 'Создать комнату', exact: true }).click();
  await admissionName(a, 'Редактор братьев А');
  await selected(a, 'Без имени').waitFor({ timeout: 45000 });
  await openBio(a, true);
  await type(a, a.getByRole('textbox', { name: 'Имя', exact: true }).first(), 'Алексей');
  await closeBio(a);
  const invitation = await invite(a, 'editor');
  await load(b, invitation); await admissionName(b, 'Редактор братьев Б');
  await selected(b, 'Алексей').waitFor({ timeout: 45000 });
  await converged([a, b]);
  const handshakes = await Promise.all([a, b].map((page) => page.evaluate(() => window.__observedHandshakes)));
  publicSiblingReport.handshakes = handshakes;
  assert.ok(handshakes.every((packets) => packets.some((packet) => packet.explicitSiblings === true)) &&
    ['hello', 'welcome'].every((type) => handshakes.flat().some((packet) => packet.type === type && packet.explicitSiblings === true)),
  `Production hello/welcome did not advertise explicitSiblings: ${JSON.stringify(handshakes)}`);
  publicSiblingReport.rtcEvidence = await Promise.all([a, b].map(connectedRelayEvidence));
  const initial = await history(a);
  await fs.writeFile(path.join(output, 'public-explicit-siblings-journal-before.json'), JSON.stringify(initial, null, 2));
  await checkpoint('public-siblings-capability-actual-rtc');
  const brother = await addSibling(a, 'Алексей', 'root', 'Брат', 'Борис', 'public-siblings-editor-a-atomic-brother');
  const sister = await addSibling(b, 'Борис', brother.personId, 'Сестра', 'Вера', 'public-siblings-editor-b-transitive-sister');
  await inspect(a, 'Алексей', [['Борис', true, true], ['Вера', true, false]], 'public-siblings-remote-transitive');
  await geometry(b, 'public-siblings-transitive-block', [['Алексей', 'Борис', 'Вера']]);
  const father = await addParent(a, 'Алексей', 'root', 'Отца', 'Николай', 'public-siblings-shared-father');
  for (const name of ['Алексей', 'Борис', 'Вера']) await inspect(b, name, [['Николай', true, false]], `public-siblings-remote-parent-${name}`);
  const beforeUnlink = await history(b);
  await openPerson(b, 'Алексей');
  const edge = chip(b, 'Борис'); await revealBiographyAction(b, edge);
  await edge.getByRole('button', { name: directLabel, exact: true }).click();
  const unlinked = await delta(b, beforeUnlink, 1, 'public-siblings-editor-b-unlink-bridge');
  assert.deepEqual(unlinked.operations, [{ type: 'unlinkSibling', personId: brother.personId, siblingId: 'root', linkId: brother.linkId }]);
  await closeBio(b);
  await inspect(a, 'Алексей', [['Николай', true, false], ['Борис', true, false], ['Вера', true, false]], 'public-siblings-remote-split-retains-parent');
  await geometry(a, 'public-siblings-half-separate-block', [['Алексей'], ['Борис', 'Вера']]);
  const mother = await addParent(a, 'Борис', brother.personId, 'Мать', 'Мария', 'public-siblings-materialize-remaining-group');
  for (const [page, source, other] of [[a, 'Борис', 'Вера'], [b, 'Вера', 'Борис']]) await inspect(page, source,
    [['Николай', true, false], ['Мария', true, false], [other, true, false]], `public-siblings-computed-full-${source}`);
  await inspect(b, 'Алексей', [['Мария', false, false]], 'public-siblings-detached-no-mother');
  const final = await history(a); assert.deepEqual(await history(b), final);
  const appended = appendedHistory(initial, final).map((record) => JSON.parse(record.text));
  assert.equal(appended.length, 7, 'Two atomic siblings, two two-command parents and one unlink are the only writes.');
  assert.equal(appended.filter((op) => op.type === 'unlinkSibling').length, 1, 'Claim retirement must not append cleanup writes.');
  await fs.writeFile(path.join(output, 'public-explicit-siblings-journal-after.json'), JSON.stringify(final, null, 2));
  await checkpoint('public-siblings-full-convergence-before-reload');
  for (const [index, page] of [a, b].entries()) {
    await load(page, base);
    await selected(page, 'Алексей').waitFor({ timeout: 45000 }); await converged([a, b]);
    assert.deepEqual(await history(page), final, 'Public reload changed the complete sibling journal.');
    await fs.writeFile(path.join(output, `public-explicit-siblings-peer-${index + 1}-journal-reloaded.json`), JSON.stringify(await history(page), null, 2));
    await inspect(page, 'Борис', [['Николай', true, false], ['Мария', true, false], ['Вера', true, false]], `public-siblings-reloaded-peer-${index + 1}`);
    await geometry(page, `public-siblings-reloaded-geometry-peer-${index + 1}`, [['Алексей'], ['Борис', 'Вера']]);
  }
  await checkpoint('public-siblings-both-reloaded');
  Object.assign(publicSiblingReport, { completed: true, independentEditors: 2, brother, sister, father, mother,
    completePersistentJournalConvergence: true, bothReloadsVerified: true, records: final.length,
    journalSha256: require('node:crypto').createHash('sha256').update(JSON.stringify(final)).digest('hex'),
    transport: 'Actual public production signaling + relay-only RTC; observed capability bits are never rewritten.',
    limitations: ['Finite current-client scenario; unavailable provider or loading/budget failure stays partial.',
      'No old-client capability stripping; refusal, conflicts, atomic failure/retry and exhaustive graph behavior remain unit/session coverage.'],
    trace: publicSurnameTrace, browserErrors: errors });
  await fs.writeFile(path.join(output, 'explicit-siblings-public.json'), JSON.stringify(publicSiblingReport, null, 2));
  console.log('PASS: actual public explicitSiblings hello/welcome, two-editor atomic siblings/parent propagation/bridge unlink/materialized full siblings, complete convergence and both reloads.');
}

function compactIdentitySeed(role = 'editor') {
  const editor = '1'.repeat(32), otherEditor = '2'.repeat(32), guest = '3'.repeat(32), roomId = '4'.repeat(32);
  const actor = role === 'guest' ? guest : editor;
  const longAlias = 'Александр ОченьДлинноеОтображаемоеИмяДляПроверкиПодсказки';
  const records = [];
  const add = (author, kind, text, extra = {}) => {
    const record = { id: `compact-identity-${records.length + 1}`, author, clock: records.length + 1,
      createdAt: Date.UTC(2026, 9, 17), kind, text, ...extra };
    records.push(record);
    return record;
  };
  for (const [id, name, permission] of [[editor, longAlias, 'editor'],
    [otherEditor, 'Другое устройство', 'editor'], [guest, '', 'guest']]) {
    add(id, 'participantName', name);
    add(editor, 'participantRole', permission, { targetActor: id });
  }
  const tree = (author, operation) => add(author, 'tree', JSON.stringify(operation));
  tree(editor, { type: 'editText', personId: 'root', field: 'name', itemId: null,
    inserts: [...'Алексей'].map((text, index) => ({ id: `compact-name-${index}`, text,
      left: index ? `compact-name-${index - 1}` : null, right: null })), deletes: [] });
  tree(editor, { type: 'setSurname', personId: 'root', scope: 'individual', familyKey: null, text: 'Семейный', decline: false });
  const selfBinding = tree(editor, { type: 'bindActor', personId: 'root', actorId: editor });
  tree(otherEditor, { type: 'bindActor', personId: 'root', actorId: otherEditor });
  // A historical guest claim remains immutable but must not grant editor identity.
  tree(guest, { type: 'bindActor', personId: 'root', actorId: guest });
  const prefix = 'mytree.room-store.v1.';
  const roomPrefix = `${prefix}room.${Buffer.from(roomId).toString('base64url')}.`;
  const storage = { [`${prefix}client-id`]: JSON.stringify(actor), [`${prefix}last-room`]: JSON.stringify(roomId),
    [`${roomPrefix}membership`]: JSON.stringify(roomId) };
  for (const record of records) storage[`${roomPrefix}operation.${Buffer.from(record.id).toString('base64url')}`] = JSON.stringify(record);
  return { role, actor, roomId, storage, records: records.sort((a, b) => a.id.localeCompare(b.id)), longAlias,
    selfBindingId: selfBinding.id, otherEditor, fullName: 'Алексей Семейный' };
}
async function compactIdentityProfile(browser, pages, errors, mobile, seed) {
  const context = await browser.newContext({ viewport: mobile ? { width: 390, height: 844 } : { width: 1280, height: 900 },
    deviceScaleFactor: 1, isMobile: mobile, hasTouch: mobile, serviceWorkers: 'block', reducedMotion: 'reduce',
    ...(cleanAddressSuite ? { permissions: ['clipboard-read', 'clipboard-write'] } : {}) });
  const origin = new URL(base).origin;
  await context.route('**/*', (route) => {
    const url = new URL(route.request().url());
    const renderer = !['dialogs-local', 'clean-address-local'].includes(suite) && url.hostname === 'www.gstatic.com' && url.pathname.startsWith('/flutter-canvaskit/');
    const font = !['dialogs-local', 'clean-address-local'].includes(suite) && ['fonts.gstatic.com', 'fonts.googleapis.com'].includes(url.hostname);
    const allowed = url.origin === origin || renderer || font;
    if (cleanAddressSuite) cleanAddressReport.network.http.push({ origin: url.origin, path: url.pathname,
      allowed, resourceType: route.request().resourceType() });
    return allowed ? route.continue() : route.abort('internetdisconnected');
  });
  await context.routeWebSocket('**/*', (socket) => {
    if (cleanAddressSuite) cleanAddressReport.network.blockedWebSockets++;
    socket.close({ code: 1000, reason: 'Isolated compact identity UI fixture' });
  });
  await context.addInitScript(({ origin, storage, membership }) => {
    window.__firstFrame = false;
    window.addEventListener('flutter-first-frame', () => { window.__firstFrame = true; }, { once: true });
    if (storage && location.origin === origin && localStorage.getItem(membership) === null) {
      for (const [key, value] of Object.entries(storage)) localStorage.setItem(key, value);
    }
  }, { origin, storage: seed?.storage, membership: seed && Object.keys(seed.storage).find((key) => key.endsWith('.membership')) });
  if (cleanAddressSuite) await context.addInitScript(() => {
    // Passive URL observations only: do not wrap history or change location.
    const safe = () => ({ hashEmpty: location.hash === '', path: location.pathname, query: location.search });
    const trace = { initiallyHadFragment: location.hash !== '', firstFrame: null, observations: [] };
    window.__cleanAddressTrace = trace;
    window.addEventListener('flutter-first-frame', () => {
      trace.firstFrame = safe();
      let remaining = 180;
      const sample = () => { trace.observations.push(safe()); if (--remaining > 0) requestAnimationFrame(sample); };
      requestAnimationFrame(sample);
    }, { once: true });
    for (const event of ['hashchange', 'popstate']) window.addEventListener(event, () => trace.observations.push(safe()));
  });
  if (suite === 'dialogs-local') await context.addInitScript(() => {
    // Test only the browser storage boundary; no production app hooks or state
    // setters are exposed. Form changes and retry still use real dialog buttons.
    window.__compactQuotaBlocked = false;
    window.__compactAppendAttempts = [];
    const nativeSet = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      if (this === localStorage && String(key).startsWith('mytree.room-store.v1.') && String(key).includes('.operation.')) {
        window.__compactAppendAttempts.push({ record: JSON.parse(String(value)), failed: window.__compactQuotaBlocked });
        if (window.__compactQuotaBlocked) throw new DOMException('Focused dialog check: storage append unavailable', 'QuotaExceededError');
      }
      return nativeSet.call(this, key, value);
    };
  });
  const page = await context.newPage();
  page.setDefaultTimeout(15000);
  pages.push(page);
  page.on('pageerror', (error) => errors.push(error.message));
  page.__compactConsoleErrors = [];
  page.__compactFlutterErrors = [];
  page.__compactCheckpoints = [];
  page.on('console', (message) => {
    if (message.type() === 'error') page.__compactConsoleErrors.push(message.text());
    if (compactFlutterFailure.test(message.text())) page.__compactFlutterErrors.push({ type: message.type(), text: message.text() });
  });
  return { context, page };
}
async function compactIdentityLoad(page, seed) {
  await load(page, base);
  const local = page.getByRole('button', { name: 'Открыть локальную копию', exact: true });
  const root = page.getByRole('button', { name: 'Выбрать Алексей', exact: true });
  await waitUntil(async () => await local.count() || await root.count(), 'The identity fixture never exposed its saved tree/local-copy action.', 60000);
  if (await local.count()) await local.click();
  await root.waitFor();
  assert.match(await body(page), /Локальная копия · синхронизация не подтверждена/);
  for (const record of seed.records) assert.deepEqual((await history(page)).find((entry) => entry.id === record.id), record);
}
async function cleanAddressLocal(browser, pages, errors) {
  const seed = compactIdentitySeed('editor'), profiles = [];
  const clean = new URL(base); clean.hash = '';
  clean.searchParams.set('address_smoke', '1'); // Prove query preservation, no sensitive value.
  const incoming = (fragment) => { const url = new URL(clean); url.hash = fragment; return url.href; };
  const digest = (value) => require('node:crypto').createHash('sha256').update(JSON.stringify(value)).digest('hex');
  const checkpoint = async (page, label, screenshot = true) => {
    assert.equal(page.url(), clean.href, `${label}: actual browser address is not the clean hosting path/query.`);
    const trace = await page.evaluate(() => window.__cleanAddressTrace);
    assert.ok(trace?.firstFrame?.hashEmpty, `${label}: first Flutter frame still exposed an initial fragment.`);
    assert.ok(trace.observations.every((entry) => entry.hashEmpty && entry.path === new URL(clean).pathname && entry.query === new URL(clean).search),
      `${label}: an observed frame/history event re-announced the fragment or lost the hosting path/query.`);
    const semantics = await body(page);
    assert.doesNotMatch(semantics, /Не сохранено:|EXCEPTION CAUGHT|RenderFlex.*overflow/);
    assert.deepEqual(page.__compactConsoleErrors, []); assert.deepEqual(page.__compactFlutterErrors, []); assert.deepEqual(errors, []);
    const entry = { label, cleanUrl: clean.href, trace, records: (await history(page)).length,
      journalSha256: digest(await history(page)), pageErrors: [...errors], consoleErrors: [...page.__compactConsoleErrors],
      flutterErrors: [...page.__compactFlutterErrors] };
    cleanAddressReport.steps.push(entry);
    if (screenshot) await page.screenshot({ path: path.join(output, `${label}.png`), animations: 'disabled' });
    return entry;
  };
  const waitSavedCanvas = async (page) => {
    const root = page.getByRole('button', { name: 'Выбрать Алексей', exact: true });
    const local = page.getByRole('button', { name: 'Открыть локальную копию', exact: true });
    await waitUntil(async () => await root.count() || await local.count(), 'Saved room did not expose its normal canvas/local-copy gate.', 45000);
    if (await local.count()) await local.click();
    await root.waitFor();
    assert.match(await body(page), /Локальная копия · синхронизация не подтверждена/);
  };
  const pendingProbes = async (page) => {
    // New entrants cancel before admission; no mocked peer or role grant.
    for (const role of ['guest', 'editor']) {
      await load(page, incoming(`room=${'5'.repeat(32)}&role=${role}`));
      const dialog = page.getByRole('alertdialog');
      await dialog.getByText('Как вас зовут?', { exact: true }).waitFor();
      await checkpoint(page, `clean-address-incoming-${role}-prompt`);
      await dialog.getByRole('button', { name: 'Отмена', exact: true }).click();
      await page.getByRole('button', { name: 'Создать комнату', exact: true }).waitFor();
      await checkpoint(page, `clean-address-incoming-${role}-cancel`, false);
      assert.deepEqual(await history(page), [], 'Cancelling fresh invitation wrote admission history.');
      assert.equal(await page.evaluate(() => localStorage.getItem('mytree.room-store.v1.last-room')), null);
    }
    for (const [label, fragment, message] of [
      ['invalid-role', `room=${'5'.repeat(32)}&role=owner`, /неизвестная роль/],
      ['invalid-id', 'room=invalid&role=guest', /корректный ID комнаты/],
      ['malformed', 'room=%E0%A4%A&role=guest', null],
      ['unrelated', 'not-a-route', null],
    ]) {
      await load(page, incoming(fragment));
      await page.getByRole('button', { name: 'Создать комнату', exact: true }).waitFor();
      if (message) assert.match(await body(page), message);
      await checkpoint(page, `clean-address-${label}`, label === 'invalid-role');
      assert.deepEqual(await history(page), [], `${label}: invalid/unrelated fragment appended history.`);
    }
    await page.getByRole('button', { name: 'Создать комнату', exact: true }).click();
    let dialog = page.getByRole('alertdialog'); await dialog.getByText('Как вас зовут?', { exact: true }).waitFor();
    await dialog.getByRole('button', { name: 'Отмена', exact: true }).click();
    assert.deepEqual(await history(page), [], 'Cancelled room creation wrote history.');
    await checkpoint(page, 'clean-address-create-cancel', false);
    await page.getByRole('button', { name: 'Создать комнату', exact: true }).click();
    dialog = page.getByRole('alertdialog'); await dialog.getByText('Как вас зовут?', { exact: true }).waitFor();
    await dialog.getByRole('button', { name: 'Продолжить', exact: true }).click(); // Actual supported empty alias, no typing race.
    await page.getByRole('button', { name: 'Выбрать Без имени', exact: true }).waitFor();
    const created = await history(page);
    assert.ok(created.some((record) => record.kind === 'participantRole' && record.text === 'editor'));
    assert.match(await page.evaluate(() => JSON.parse(localStorage.getItem('mytree.room-store.v1.last-room'))), /^[0-9a-f]{32}$/);
    await checkpoint(page, 'clean-address-created-room');
    cleanAddressReport.freshCreation = { records: created.length, journalSha256: digest(created), actualEditorRole: true,
      identityRedacted: true, reloadStatus: 'unrun: prioritized saved-room clean-URL reload, not a second ~30s gate.' };
  };
  const explicitCopies = async (page) => {
    await page.getByRole('button', { name: /^Участники:/ }).click();
    await page.getByRole('button', { name: 'Пригласить участников', exact: true }).click();
    const copies = [];
    await page.getByRole('button', { name: 'Скопировать ID', exact: true }).click();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), seed.roomId);
    for (const role of ['guest', 'editor']) {
      await page.getByRole('button', { name: role === 'guest' ? 'Гость' : 'Редактор', exact: true }).click();
      await page.getByRole('button', { name: 'Скопировать URL', exact: true }).click();
      const copied = await page.evaluate(() => navigator.clipboard.readText()), parsed = new URL(copied);
      assert.equal(parsed.origin, clean.origin); assert.equal(parsed.pathname, clean.pathname); assert.equal(parsed.search, clean.search);
      const fragment = new URLSearchParams(parsed.hash.slice(1));
      assert.equal(fragment.get('room'), seed.roomId); assert.equal(fragment.get('role'), role);
      assert.equal(page.url(), clean.href, 'Explicit copy exposed the invitation in the browser address.');
      await page.getByRole('button', { name: 'Показать QR', exact: true }).click();
      await page.getByText(role === 'guest' ? 'QR · Гость' : 'QR · Редактор', { exact: true }).waitFor();
      const file = `clean-address-explicit-${role}-qr.png`, png = await page.screenshot({ path: path.join(output, file), animations: 'disabled' });
      const decoded = await page.evaluate(async (base64) => {
        try {
          if (!globalThis.BarcodeDetector || !(await BarcodeDetector.getSupportedFormats()).includes('qr_code')) return { status: 'unverified', reason: 'No installed native QR decoder; no dependency is downloaded.' };
          const image = new Image(); image.src = `data:image/png;base64,${base64}`; await image.decode();
          const codes = await new BarcodeDetector({ formats: ['qr_code'] }).detect(image);
          return codes.length === 1 ? { status: 'decoded', value: codes[0].rawValue } : { status: 'unverified', reason: 'Actual QR raster was not uniquely decoded.' };
        } catch (_) { return { status: 'unverified', reason: 'Installed native QR decoder could not decode this actual raster.' }; }
      }, png.toString('base64'));
      if (decoded.status === 'decoded') assert.equal(decoded.value, copied, 'Actual QR encoded a different invitation than Copy URL.');
      copies.push({ role, copiedUrlSha256: digest(copied), syntheticRoomMatches: true, hostingPathQueryPreserved: true,
        screenshot: file, qrPayload: { status: decoded.status, reason: decoded.reason, matchesClipboard: decoded.status === 'decoded' } });
      await page.getByRole('alertdialog').getByRole('button', { name: 'Закрыть', exact: true }).click();
    }
    await page.getByRole('alertdialog').getByRole('button', { name: 'Закрыть', exact: true }).click();
    assert.deepEqual(await history(page), seed.records, 'Explicit invite/copy/QR viewing changed a complete immutable record.');
    cleanAddressReport.explicitInvitations = copies;
    await checkpoint(page, 'clean-address-after-explicit-copy-qr', false);
  };
  let deadline;
  try {
    await Promise.race([(async () => {
    const editorProfile = await compactIdentityProfile(browser, pages, errors, false, seed);
    profiles.push(editorProfile);
    const freshProfile = await compactIdentityProfile(browser, pages, errors, false);
    profiles.push(freshProfile);
    const page = editorProfile.page;
    await Promise.all([(async () => {
      await load(page, incoming(`room=${seed.roomId}&role=editor`));
      await checkpoint(page, 'clean-address-saved-incoming-first-ui', false);
      await waitSavedCanvas(page); assert.deepEqual(await history(page), seed.records);
      await checkpoint(page, 'clean-address-saved-editor-canvas');
    })(), pendingProbes(freshProfile.page)]);
    await explicitCopies(page);
    await fs.writeFile(path.join(output, 'clean-address-synthetic-journal-before.json'), JSON.stringify(seed.records, null, 2));
    await load(page, clean.href); // No room or role anywhere in the reload URL.
    await checkpoint(page, 'clean-address-reload-first-ui', false);
    await waitSavedCanvas(page);
    assert.deepEqual(await history(page), seed.records, 'Clean-URL reload did not restore the complete saved room.');
    await fs.writeFile(path.join(output, 'clean-address-synthetic-journal-reloaded.json'), JSON.stringify(await history(page), null, 2));
    await checkpoint(page, 'clean-address-saved-room-reloaded');
    await page.getByRole('button', { name: /Меню комнаты/ }).click();
    await page.getByRole('menuitem', { name: 'Выход в меню', exact: true }).click();
    await page.getByRole('button', { name: 'Присоединиться', exact: true }).waitFor();
    await checkpoint(page, 'clean-address-exited-menu', false);
    await page.getByRole('button', { name: 'Присоединиться', exact: true }).click();
    const join = page.getByRole('alertdialog'), field = join.getByRole('textbox', { name: 'ID комнаты или ссылка', exact: true });
    await field.waitFor();
    // The genuine join dialog defaults to the saved ID; submit it without a
    // per-character text race or synthetic app command.
    await focusInput(page, field, seed.roomId);
    assert.equal(await nativeInputValue(page), seed.roomId);
    await join.getByRole('button', { name: 'Подключиться', exact: true }).click();
    await join.waitFor({ state: 'hidden' }); await checkpoint(page, 'clean-address-manual-saved-id-pending');
    assert.deepEqual(await history(page), seed.records, 'Manual saved-ID opening appended history.');
    Object.assign(cleanAddressReport, { completed: true, corePassed: true,
      verificationStatus: cleanAddressReport.explicitInvitations.every((entry) => entry.qrPayload.status === 'decoded') ? 'passed' : 'core-passed-qr-payload-unverified',
      savedEditorRecords: seed.records.length, completeSyntheticJournalReloadEqual: true,
      journalSha256: digest(seed.records), manualSavedId: 'Actual submission/address checked; second offline room-entry wait deliberately unrun.',
      incomingRoleAdmission: 'Fresh guest/editor prompts cancelled. Actual durable role/admission remains source/session coverage, not an offline peer claim.',
      publicSynchronization: 'unrun: all WebSockets blocked', qrPayloadGuarantee: 'Only decoded actual raster is a payload pass; rendered PNG/title alone is unverified.' });
    })(), new Promise((_, reject) => {
      deadline = setTimeout(() => reject(new Error('Finite clean-address-local exceeded its 90-second budget; report partial.')), 90000);
    })]);
  } catch (error) {
    cleanAddressReport.failure = String(error.stack || error).replace(/[0-9a-f]{32}/gi, '[synthetic-id]');
    for (const [index, profile] of profiles.entries()) if (!profile.page.isClosed()) {
      const page = profile.page;
      await page.screenshot({ path: path.join(output, `clean-address-failure-${index + 1}.png`), animations: 'disabled' }).catch(() => {});
      cleanAddressReport.steps.push({ label: `failure-${index + 1}`, urlHasFragment: new URL(page.url()).hash !== '',
        journalSha256: digest(await history(page).catch(() => [])), records: (await history(page).catch(() => [])).length,
        pageErrors: [...errors], consoleErrors: page.__compactConsoleErrors || [], flutterErrors: page.__compactFlutterErrors || [] });
    }
    process.exitCode = 1;
  } finally {
    clearTimeout(deadline);
    await fs.writeFile(path.join(output, 'clean-address-local.json'), JSON.stringify(cleanAddressReport, null, 2));
    await Promise.all(profiles.map((profile) => profile.context.close()));
  }
}

async function compactIdentityFailure(page, label, error) {
  await fs.writeFile(path.join(output, `${label}-failure.json`), JSON.stringify({ failure: error.stack,
    semantics: await body(page).catch(() => 'unavailable'), completeJournal: await history(page).catch(() => null),
    completeStorage: await storedRoom(page).catch(() => null), consoleErrors: page.__compactConsoleErrors || [],
    flutterErrors: page.__compactFlutterErrors || [], checkpoints: page.__compactCheckpoints || [],
    appendAttempts: await page.evaluate(() => window.__compactAppendAttempts || []).catch(() => []) }, null, 2));
  await page.screenshot({ path: path.join(output, `${label}-failure.png`), animations: 'disabled' }).catch(() => {});
}
const compactFlutterFailure = /EXCEPTION CAUGHT|Another exception was thrown|RenderFlex.*overflow|RenderBox was not laid out|Unexpected null value|Null check operator used on a null value|Incorrect use of ParentDataWidget|Assertion failed/i;
async function compactDialogCheckpoint(page, errors, label) {
  await sleep(220);
  const semantics = await body(page);
  const entry = { label, semantics, pageErrors: [...errors], consoleErrors: [...page.__compactConsoleErrors],
    flutterErrors: [...page.__compactFlutterErrors] };
  page.__compactCheckpoints.push(entry);
  await fs.writeFile(path.join(output, `${label}.json`), JSON.stringify(entry, null, 2));
  await page.screenshot({ path: path.join(output, `${label}.png`), animations: 'disabled' });
  assert.deepEqual(entry.pageErrors, [], `${label}: uncaught intermediate application error.`);
  assert.deepEqual(entry.consoleErrors, [], `${label}: intermediate console error.`);
  assert.deepEqual(entry.flutterErrors, [], `${label}: Flutter rendering error (all console levels).`);
  assert.doesNotMatch(semantics, compactFlutterFailure);
}
async function assertMinimalNameDialog(dialog, bound = true) {
  const semantics = await dialog.ariaSnapshot();
  assert.doesNotMatch(semantics, /Имя необязательно|Указанное имя увидят|Если оставить поле|Профиль связан|Это я:|Отвяжется только|Дерево и привязки/,
    'The own-name modal still contains removed helper paragraphs or a static bound-person caption.');
  assert.equal(await dialog.getByRole('textbox', { name: /Ваше имя/ }).count(), 1);
  assert.equal(await dialog.getByRole('button', { name: 'Отменить «Это я»', exact: true }).count(), bound ? 1 : 0);
  assert.equal(await dialog.getByRole('button', { name: 'Сохранить', exact: true }).count(), 1);
  assert.equal(await dialog.getByRole('button', { name: 'Отмена', exact: true }).count(), 1);
  assert.equal(await dialog.getByRole('button').count(), bound ? 3 : 2, 'The minimal modal has unexpected extra commands.');
}
async function ownNameDialog(page) {
  await page.getByRole('button', { name: /Меню комнаты/ }).click();
  await page.getByRole('menuitem', { name: 'Изменить моё имя', exact: true }).click();
  const dialog = page.getByRole('alertdialog');
  await dialog.getByText('Изменить моё имя', { exact: true }).waitFor();
  return dialog;
}
async function compactRoster(page, label, name, tooltipPieces = []) {
  await page.getByRole('button', { name: /^Участники:/ }).click();
  try {
    await page.getByRole('dialog').getByRole('heading', { name: 'Участники', exact: true }).waitFor();
    await waitUntil(async () => (await body(page)).includes(label), `Participant dialog did not expose ${label}.`, 10000);
    const before = await body(page);
    assert.ok(before.includes(label), `Missing actual roster label ${label}: ${before}`);
    let tooltip;
    if (tooltipPieces.length) {
      const box = await page.locator('flt-semantics').evaluateAll((elements, label) => {
        const rects = elements.filter((element) => (element.getAttribute('aria-label') || '').endsWith(label) ||
          (element.textContent || '').endsWith(label))
          .map((element) => element.getBoundingClientRect()).filter((rect) => rect.width >= 54 && rect.height >= 54)
          .sort((a, b) => a.width * a.height - b.width * b.height);
        const rect = rects[0];
        return rect && { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
      }, label);
      assert.ok(box, 'The actual participant tile has no hover target.');
      await page.mouse.move(box.x + box.width / 2, box.y + box.height - 14);
      await waitUntil(async () => {
        tooltip = (await body(page)).split('\n').filter((line) => !before.split('\n').includes(line)).join('\n');
        return tooltipPieces.every((piece) => tooltip.includes(piece));
      }, `The real roster tooltip did not reveal ${tooltipPieces.join(' / ')}.`, 5000);
    }
    await page.screenshot({ path: path.join(output, `${name}.png`), animations: 'disabled' });
    return { label, semantics: await body(page), tooltip };
  } catch (error) {
    await compactIdentityFailure(page, name, error);
    throw error;
  } finally {
    await page.mouse.move(1, 1);
    await page.getByRole('button', { name: 'Закрыть', exact: true }).click();
  }
}
async function minimalDialogConfirmAndFailure(page, seed, errors) {
  const before = await history(page);
  await openBio(page);
  await page.getByRole('button', { name: 'Это я', exact: true }).click();
  const confirmation = page.getByRole('alertdialog');
  await confirmation.getByText(`Связать ваш профиль с «${seed.fullName}»?`, { exact: true }).waitFor();
  assert.doesNotMatch(await confirmation.ariaSnapshot(), /не даёт права|редактировать дерево|Отменить связь можно|Изменить моё имя/);
  assert.equal(await confirmation.getByRole('button').count(), 2);
  await compactDialogCheckpoint(page, errors, 'phone-minimal-this-is-me-cancel');
  await confirmation.getByRole('button', { name: 'Отмена', exact: true }).click();
  assert.deepEqual(await history(page), before, 'Cancelling the compact binding confirmation appended history.');
  await page.getByRole('button', { name: 'Это я', exact: true }).click();
  await confirmation.getByRole('button', { name: 'Да, это я', exact: true }).click();
  await waitUntil(async () => (await body(page)).includes('Ваш профиль'), 'Explicit compact confirmation did not save the binding.');
  await compactDialogCheckpoint(page, errors, 'phone-minimal-this-is-me-bound');
  await closeBio(page);
  const rebound = appendedHistory(before, await history(page));
  assert.equal(rebound.length, 1);
  assert.deepEqual(JSON.parse(rebound[0].text), { type: 'bindActor', personId: 'root', actorId: seed.actor });

  const dialog = await ownNameDialog(page);
  await assertMinimalNameDialog(dialog);
  const nameField = dialog.getByRole('textbox', { name: /Ваше имя/ });
  const draft = 'Проверка сохранения';
  await type(page, nameField, draft);
  const beforeFailure = await history(page);
  await page.evaluate(() => { window.__compactQuotaBlocked = true; });
  await dialog.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await waitUntil(async () => (await dialog.ariaSnapshot()).includes('Не удалось сохранить имя:'), 'A failed real storage append was hidden by the name modal.');
  assert.equal(await dialog.count(), 1, 'The name modal closed despite a saving failure.');
  assert.ok((await dialog.ariaSnapshot()).includes(draft), 'The failed save discarded the visible draft.');
  assert.deepEqual(await history(page), beforeFailure, 'The deliberately failed alias was falsely reported as durable.');
  await compactDialogCheckpoint(page, errors, 'phone-name-save-failure-visible-draft-retained');
  const failed = await page.evaluate(() => window.__compactAppendAttempts.filter((attempt) => attempt.failed));
  assert.ok(failed.length > 0, 'The case did not actually reach browser storage.');
  const failedRecord = failed.at(-1).record;
  assert.equal(failedRecord.kind, 'participantName');
  assert.equal(failedRecord.text, draft);
  await page.evaluate(() => { window.__compactQuotaBlocked = false; });
  await dialog.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await dialog.waitFor({ state: 'hidden' });
  const finalJournal = await history(page);
  const retried = appendedHistory(beforeFailure, finalJournal);
  assert.equal(retried.length, 1, 'Retry must persist the same unsaved alias, not append another hidden name.');
  assert.deepEqual(retried[0], failedRecord, 'Retry changed the failed alias core/proof instead of committing the same record.');
  validatePersistentAuthorHistory(finalJournal);
  await compactDialogCheckpoint(page, errors, 'phone-name-save-retry-durable');
  const reopened = await ownNameDialog(page);
  await assertMinimalNameDialog(reopened);
  await focusInput(page, reopened.getByRole('textbox', { name: /Ваше имя/ }), draft);
  await reopened.getByRole('button', { name: 'Отмена', exact: true }).click();
  assert.deepEqual(await history(page), finalJournal, 'Cancelling a reopened name modal wrote a hidden alias.');
  await compactIdentityLoad(page, seed);
  assert.deepEqual(await history(page), finalJournal, 'Reload lost a compact-dialog binding or recovered alias.');
  await compactDialogCheckpoint(page, errors, 'phone-minimal-dialogs-final-reload');
  return { rebound: rebound[0], visibleFailure: true, failedAppendAttempts: failed, exactRetriedAlias: retried[0],
    completeJournal: finalJournal, immutableReloadVerified: true };
}
async function localIdentityActions(browser, pages, errors) {
  const seed = compactIdentitySeed();
  const { context, page } = await compactIdentityProfile(browser, pages, errors, true, seed);
  try {
    await compactIdentityLoad(page, seed);
    const before = await history(page);
    const dialog = await ownNameDialog(page);
    await assertMinimalNameDialog(dialog);
    if (suite === 'dialogs-local') await compactDialogCheckpoint(page, errors, 'phone-minimal-name-dialog-bound');
    const nameField = page.getByRole('textbox', { name: /Ваше имя/ });
    const draft = 'Новый псевдоним';
    await type(page, nameField, draft);
    await page.screenshot({ path: path.join(output, 'phone-name-modal-before-release.png'), animations: 'disabled' });
    assert.deepEqual(await history(page), before, 'Typing an unsaved alias wrote a hidden record.');
    await dialog.getByRole('button', { name: 'Отменить «Это я»', exact: true }).click();
    await waitUntil(async () => (await history(page)).length === before.length + 1, 'Own-device release did not become durable.');
    assert.equal(await dialog.count(), 1, 'Release closed the name modal.');
    await focusInput(page, nameField, draft);
    const release = appendedHistory(before, await history(page));
    assert.equal(release.length, 1);
    assert.equal(release[0].kind, 'tree');
    assert.equal(release[0].author, seed.actor);
    assert.deepEqual(JSON.parse(release[0].text), { type: 'unbindActor', personId: 'root', actorId: seed.actor, bindingId: seed.selfBindingId });
    await waitUntil(async () => await dialog.getByRole('button', { name: 'Отменить «Это я»', exact: true }).count() === 0,
      'Durable release left a stale unbind command.');
    await page.screenshot({ path: path.join(output, 'phone-name-modal-after-release-draft-preserved.png'), animations: 'disabled' });
    await assertMinimalNameDialog(dialog, false);
    if (suite === 'dialogs-local') await compactDialogCheckpoint(page, errors, 'phone-minimal-name-dialog-released-draft-retained');
    const released = await history(page);
    await dialog.getByRole('button', { name: 'Сохранить', exact: true }).click();
    await dialog.waitFor({ state: 'hidden' });
    const named = await history(page);
    const alias = appendedHistory(released, named);
    assert.equal(alias.length, 1);
    assert.equal(alias[0].kind, 'participantName');
    assert.equal(alias[0].author, seed.actor);
    assert.equal(alias[0].text, draft);
    const namedRoster = await participantPanel(page, [`${draft}, вы, офлайн, редактор`, 'Другое устройство, офлайн, редактор'],
      'phone-released-alias-and-other-bound-editor.png');
    await ownNameDialog(page);
    await type(page, nameField, '');
    await dialog.getByRole('button', { name: 'Сохранить', exact: true }).click();
    await dialog.waitFor({ state: 'hidden' });
    const cleared = await history(page);
    const clear = appendedHistory(named, cleared);
    assert.equal(clear.length, 1);
    assert.equal(clear[0].kind, 'participantName');
    assert.equal(clear[0].text, '');
    const anonymousRoster = await participantPanel(page, ['Аноним, вы, офлайн, редактор', 'Другое устройство, офлайн, редактор'],
      'phone-released-clear-alias-anonymous.png');
    assert.equal(appendedHistory(before, cleared).length, 3, 'Release/save/clear appended unexpected hidden IDs.');
    validatePersistentAuthorHistory(cleared);
    await compactIdentityLoad(page, seed);
    assert.deepEqual(await history(page), cleared, 'Reload lost or rewrote the complete identity action history.');
    await participantPanel(page, ['Аноним, вы, офлайн, редактор', 'Другое устройство, офлайн, редактор'],
      'phone-released-anonymous-after-reload.png');
    await openBio(page);
    await page.getByRole('button', { name: 'Это я', exact: true }).waitFor();
    assert.doesNotMatch(await body(page), /Ваш профиль/);
    await page.screenshot({ path: path.join(output, 'phone-released-biography-after-reload.png'), animations: 'disabled' });
    await closeBio(page);
    assert.deepEqual(await history(page), cleared, 'Read-only reload inspection appended hidden IDs.');
    const minimalDialogs = suite === 'dialogs-local' ? await minimalDialogConfirmAndFailure(page, seed, errors) : undefined;
    const finalJournal = minimalDialogs?.completeJournal || cleared;
    assert.deepEqual(errors, []);
    if (suite === 'dialogs-local') {
      assert.deepEqual(page.__compactConsoleErrors, []);
      assert.deepEqual(page.__compactFlutterErrors, []);
    }
    await fs.writeFile(path.join(output, `${suite}.json`), JSON.stringify({ application: base,
      suite, completed: true, headless: true, networkIsolated: true,
      viewport: page.viewportSize(), exactRelease: release[0], exactAlias: alias[0], exactClear: clear[0],
      pendingAliasPreservedWhileModalRemains: true, otherDeviceStillBound: true,
      anonymousAfterClearAndReload: true, completeHistoryImmutable: true, authorPrefixesValid: true,
      completeJournal: finalJournal, completeStorage: await storedRoom(page), namedRoster, anonymousRoster, browserErrors: errors,
      minimalDialogs, checkpoints: page.__compactCheckpoints, consoleErrors: page.__compactConsoleErrors, flutterErrors: page.__compactFlutterErrors,
      notVerified: ['actual roster tooltip hover (separate identity-local harness limitation)',
        'public RTC convergence; guest fresh admission and blank-name forms are not run by this case'] }, null, 2));
    console.log('PASS: phone own-name modal preserves typed alias while releasing exact own binding ID; alias save/clear, separate still-bound device, Anonymous, complete immutable author-prefix journal and reload.');
  } catch (error) {
    await compactIdentityFailure(page, suite, error);
    throw error;
  } finally { await context.close(); }
}

async function localCompactIdentity(browser, pages, errors) {
  const scenarios = [];
  for (const mobile of [false, true]) {
    const viewport = mobile ? 'mobile-390x844' : 'desktop-1280x900';
    const seed = compactIdentitySeed();
    const { context, page } = await compactIdentityProfile(browser, pages, errors, mobile, seed);
    try {
      await compactIdentityLoad(page, seed);
      assert.deepEqual(await history(page), seed.records, 'Initial rendering changed immutable identity history.');
      await openBio(page);
      assert.match(await body(page), /Ваш профиль/);
      assert.equal(await page.getByRole('button', { name: 'Это я', exact: true }).count(), 0);
      await closeBio(page);
      const aliasRoster = await compactRoster(page, `${seed.longAlias}, вы, офлайн, редактор`, `${viewport}-explicit-alias-tooltip`,
        [seed.longAlias, seed.fullName]);
      let dialog = await ownNameDialog(page);
      await assertMinimalNameDialog(dialog);
      const nameField = page.getByRole('textbox', { name: /Ваше имя/ });
      await type(page, nameField, '');
      const beforeClear = await history(page);
      await dialog.getByRole('button', { name: 'Сохранить', exact: true }).click();
      await dialog.waitFor({ state: 'hidden' });
      const clear = appendedHistory(beforeClear, await history(page));
      assert.equal(clear.length, 1);
      assert.equal(clear[0].kind, 'participantName');
      assert.equal(clear[0].text, '');
      const givenNameRoster = await compactRoster(page, 'Алексей, вы, офлайн, редактор', `${viewport}-given-name-full-name-tooltip`, [seed.fullName]);
      dialog = await ownNameDialog(page);
      await type(page, nameField, 'Новое имя');
      const beforeUnbind = await history(page);
      await dialog.getByRole('button', { name: 'Отменить «Это я»', exact: true }).click();
      await waitUntil(async () => (await history(page)).length === beforeUnbind.length + 1, 'Unbind was not durably appended.');
      assert.equal(await dialog.count(), 1, 'Unbinding prematurely closed the name modal.');
      await focusInput(page, nameField, 'Новое имя');
      const release = appendedHistory(beforeUnbind, await history(page));
      assert.equal(release.length, 1);
      assert.equal(release[0].author, seed.actor);
      assert.equal(release[0].kind, 'tree');
      assert.deepEqual(JSON.parse(release[0].text), { type: 'unbindActor', personId: 'root', actorId: seed.actor, bindingId: seed.selfBindingId });
      assert.equal(await dialog.getByRole('button', { name: 'Отменить «Это я»', exact: true }).count(), 0);
      const beforeAliasSave = await history(page);
      await dialog.getByRole('button', { name: 'Сохранить', exact: true }).click();
      await dialog.waitFor({ state: 'hidden' });
      const savedAlias = appendedHistory(beforeAliasSave, await history(page));
      assert.equal(savedAlias.length, 1);
      assert.equal(savedAlias[0].kind, 'participantName');
      assert.equal(savedAlias[0].text, 'Новое имя');
      await compactRoster(page, 'Новое имя, вы, офлайн, редактор', `${viewport}-unbound-saved-alias`);
      dialog = await ownNameDialog(page);
      await type(page, nameField, '');
      const beforeAnonymous = await history(page);
      await dialog.getByRole('button', { name: 'Сохранить', exact: true }).click();
      await dialog.waitFor({ state: 'hidden' });
      const anonymousClear = appendedHistory(beforeAnonymous, await history(page));
      assert.equal(anonymousClear.length, 1);
      assert.equal(anonymousClear[0].kind, 'participantName');
      assert.equal(anonymousClear[0].text, '');
      const anonymousRoster = await compactRoster(page, 'Аноним, вы, офлайн, редактор', `${viewport}-unbound-anonymous`);
      assert.ok(anonymousRoster.semantics.includes('Другое устройство, офлайн, редактор'),
        'Releasing this device incorrectly released the other bound editor.');
      const afterUnbind = await history(page);
      await compactIdentityLoad(page, seed);
      assert.deepEqual(await history(page), afterUnbind, 'Reload rewrote/lost the immutable alias clear or binding release.');
      await compactRoster(page, 'Аноним, вы, офлайн, редактор', `${viewport}-unbound-reloaded`);
      await openBio(page);
      assert.doesNotMatch(await body(page), /Ваш профиль/);
      await page.getByRole('button', { name: 'Это я', exact: true }).click();
      await page.getByRole('button', { name: 'Да, это я', exact: true }).click();
      await waitUntil(async () => (await body(page)).includes('Ваш профиль'), 'A released editor could not explicitly rebind.');
      await closeBio(page);
      const rebound = appendedHistory(afterUnbind, await history(page));
      assert.equal(rebound.length, 1);
      assert.deepEqual(JSON.parse(rebound[0].text), { type: 'bindActor', personId: 'root', actorId: seed.actor });
      await compactRoster(page, 'Алексей, вы, офлайн, редактор', `${viewport}-rebound-given-name`, [seed.fullName]);
      const finalHistory = await history(page);
      assert.equal(appendedHistory(seed.records, finalHistory).length, 5, 'Identity editing appended unexpected hidden operations.');
      validatePersistentAuthorHistory(finalHistory);
      await compactIdentityLoad(page, seed);
      assert.deepEqual(await history(page), finalHistory, 'Final reload appended a hidden identity write.');
      await fs.writeFile(path.join(output, `${viewport}-identity-complete-journal.json`), JSON.stringify(finalHistory, null, 2));
      scenarios.push({ name: viewport, role: 'editor', aliasRoster, givenNameRoster, anonymousRoster,
        exactClear: clear[0], exactUnbind: release[0], exactSavedAlias: savedAlias[0], exactAnonymousClear: anonymousClear[0],
        exactRebind: rebound[0], immutableReloadVerified: true,
        pendingAliasPreservedDuringUnbind: true, otherDeviceStillBound: true, fullJournal: finalHistory });
    } catch (error) {
      await compactIdentityFailure(page, `${viewport}-editor`, error);
      throw error;
    } finally { await context.close(); }
    const guestSeed = compactIdentitySeed('guest');
    const guestProfile = await compactIdentityProfile(browser, pages, errors, mobile, guestSeed);
    try {
      const guest = guestProfile.page;
      await compactIdentityLoad(guest, guestSeed);
      await guestBiography(guest, `${viewport}-guest-readonly.png`);
      const guestRoster = await compactRoster(guest, 'Аноним, вы, офлайн, гость', `${viewport}-guest-anonymous`);
      const dialog = await ownNameDialog(guest);
      assert.equal(await dialog.getByRole('button', { name: 'Отменить «Это я»', exact: true }).count(), 0,
        'An old guest binding exposed an editor-only unbind command.');
      await dialog.getByRole('button', { name: 'Отмена', exact: true }).click();
      assert.deepEqual(await storedRoom(guest), guestSeed.storage, 'Guest inspection changed actual stored identity data.');
      await compactIdentityLoad(guest, guestSeed);
      assert.deepEqual(await history(guest), guestSeed.records);
      scenarios.push({ name: viewport, role: 'guest', guestRoster, legacyClaimIgnored: true,
        noEditorOrBindOrUnbindCommands: true, completeStorageUnchangedAcrossReload: true });
    } catch (error) {
      await compactIdentityFailure(guestProfile.page, `${viewport}-guest`, error);
      throw error;
    } finally { await guestProfile.context.close(); }
    console.log(`PASS: ${viewport} explicit alias/given-name/Anonymous, real tooltip, exact self-targeted unbind + rebind, durable reload, guest editor restrictions.`);
  }
  // A fresh guest invitation may accept blank input, but cannot be admitted without
  // a real peer. Assert that distinction rather than fabricating network success.
  const fresh = await compactIdentityProfile(browser, pages, errors, true);
  try {
    const { page } = fresh;
    const url = new URL(base);
    url.hash = `room=${'5'.repeat(32)}&role=guest`;
    await load(page, url.href);
    const prompt = page.getByRole('alertdialog');
    await prompt.getByText('Как вас зовут?', { exact: true }).waitFor();
    await prompt.getByRole('button', { name: 'Продолжить', exact: true }).click();
    await prompt.waitFor({ state: 'hidden' });
    assert.doesNotMatch(await body(page), /Укажите имя:/);
    assert.deepEqual(await history(page), [], 'An unavailable peer must not cause a fake durable guest admission.');
    await page.screenshot({ path: path.join(output, 'mobile-empty-name-invitation-awaits-real-peer.png'), animations: 'disabled' });
    scenarios.push({ name: 'fresh-mobile-guest-blank-admission-form', optionalNameAccepted: true,
      realPeerUnavailableAndNoAdmissionClaimed: true, completeHistory: await history(page) });
    await load(page, base);
    await page.getByRole('button', { name: 'Создать комнату', exact: true }).click();
    await prompt.getByText('Как вас зовут?', { exact: true }).waitFor();
    await prompt.getByRole('button', { name: 'Продолжить', exact: true }).click();
    await prompt.waitFor({ state: 'hidden' });
    await page.getByRole('button', { name: 'Выбрать Без имени', exact: true }).waitFor();
    const created = await history(page);
    validatePersistentAuthorHistory(created);
    assert.equal(created.filter((record) => record.kind === 'participantName' && record.text === '').length, 1,
      'Creating without a name must durably preserve the explicit empty alias.');
    const roster = await compactRoster(page, 'Аноним, вы, офлайн, редактор', 'mobile-fresh-anonymous-creator');
    await load(page, base);
    const local = page.getByRole('button', { name: 'Открыть локальную копию', exact: true });
    await local.click({ timeout: 60000 });
    await page.getByRole('button', { name: 'Выбрать Без имени', exact: true }).waitFor();
    assert.equal(await prompt.count(), 0, 'Reload asked for a name despite a saved explicit empty alias.');
    assert.deepEqual(await history(page), created, 'Reload of an anonymous creator changed persisted history.');
    scenarios.push({ name: 'fresh-mobile-anonymous-creator', optionalNameAccepted: true, roster,
      explicitEmptyAliasDurable: true, reloadDoesNotPromptOrRewrite: true, completeHistory: created });
  } catch (error) {
    await compactIdentityFailure(fresh.page, 'fresh-mobile-blank-name', error);
    throw error;
  } finally { await fresh.context.close(); }
  assert.deepEqual(errors, []);
  await fs.writeFile(path.join(output, 'identity-local.json'), JSON.stringify({ application: base, suite: 'identity-local', headless: true,
    completed: true, networkIsolated: true, scenarios, browserErrors: errors,
    skipped: ['public signaling/RTC; no independent-peer convergence is claimed'] }, null, 2));
}

// These checks intentionally inspect WebRoomStore's real operation JSON. RTC
// payloads may be PeerJS binary encoded: observing channel.send is not evidence
// that a decoded hello/welcome or a complete author closure was on the wire.
function validatePersistentAuthorHistory(records) {
  const ids = new Map();
  const authors = new Map();
  const has = (record, key) => Object.prototype.hasOwnProperty.call(record, key);
  for (const record of records) {
    assert.ok(record && typeof record === 'object' && !Array.isArray(record));
    for (const field of ['id', 'author']) assert.ok(typeof record[field] === 'string' &&
      record[field].length > 0 && record[field].length <= 128, `Invalid RoomEdit.${field}.`);
    assert.ok(!ids.has(record.id), `Duplicate persistent operation ID ${record.id}.`);
    ids.set(record.id, record);
    for (const field of ['clock', 'createdAt']) assert.ok(Number.isSafeInteger(record[field]) &&
      record[field] >= 0, `Invalid RoomEdit.${field} in ${record.id}.`);
    assert.equal(typeof record.text, 'string');
    assert.ok(['text', 'participantName', 'participantRole', 'roomName', 'tree'].includes(record.kind || 'text'));
    if (record.kind === 'tree') assert.equal(typeof JSON.parse(record.text).type, 'string');
    if (record.kind === 'participantRole') {
      assert.ok(['guest', 'editor'].includes(record.text));
      assert.equal(typeof record.targetActor, 'string');
    } else assert.equal(has(record, 'targetActor'), false);
    if (!has(record, 'authorSequence')) {
      assert.equal(has(record, 'authorPrevious'), false, 'Legacy record carries a partial proof.');
      assert.equal(has(record, 'authorBase'), false, 'Legacy record carries a partial proof.');
    } else {
      assert.ok(Number.isSafeInteger(record.authorSequence) && record.authorSequence > 0,
        `Invalid positive author sequence in ${record.id}.`);
      assert.ok(has(record, 'authorPrevious'), 'Every author proof must explicitly include authorPrevious.');
      if (record.authorSequence === 1) {
        assert.equal(record.authorPrevious, null);
        assert.ok(Array.isArray(record.authorBase), 'Sequence 1 must seal a sorted legacy ID list.');
        assert.ok(record.authorBase.every((id) => typeof id === 'string' && id.length > 0 && id.length <= 128));
        assert.deepEqual(record.authorBase, [...new Set(record.authorBase)].sort(), 'authorBase is not sorted and unique.');
      } else {
        assert.equal(typeof record.authorPrevious, 'string');
        assert.equal(has(record, 'authorBase'), false, 'Only sequence 1 may carry authorBase.');
      }
    }
    if (!authors.has(record.author)) authors.set(record.author, []);
    authors.get(record.author).push(record);
  }
  const heads = {};
  for (const [author, entries] of authors) {
    const legacy = entries.filter((record) => !has(record, 'authorSequence')).map((record) => record.id).sort();
    const sequenced = entries.filter((record) => has(record, 'authorSequence'))
      .sort((a, b) => a.authorSequence - b.authorSequence);
    for (const [index, record] of sequenced.entries()) {
      assert.equal(record.authorSequence, index + 1,
        `Author ${author} has a hole or duplicate sequence near ${record.id}.`);
      assert.equal(record.authorPrevious, index ? sequenced[index - 1].id : null,
        `Missing/wrong predecessor in ${record.id}; the full persistent prefix is required.`);
      if (!index) assert.deepEqual(record.authorBase, legacy, 'First proof does not exactly seal its own known legacy records.');
    }
    heads[author] = { sequence: sequenced.length, id: sequenced.at(-1)?.id || null,
      orderedIds: [...legacy, ...sequenced.map((record) => record.id)] };
  }
  return heads;
}
async function actualAuthorJournal(page) {
  const snapshot = await page.evaluate(() => {
    const prefix = 'mytree.room-store.v1.';
    const roomId = JSON.parse(localStorage.getItem(`${prefix}last-room`));
    const actor = JSON.parse(localStorage.getItem(`${prefix}client-id`));
    return { roomId, actor, entries: Object.keys(localStorage).sort()
      .filter((key) => key.startsWith(prefix) && key.includes('.operation.'))
      .map((key) => ({ key, record: JSON.parse(localStorage.getItem(key)) })) };
  });
  assert.match(snapshot.roomId, /^[0-9a-f]{32}$/);
  assert.match(snapshot.actor, /^[0-9a-f]{32}$/);
  for (const { key, record } of snapshot.entries) assert.equal(key,
    `mytree.room-store.v1.room.${Buffer.from(snapshot.roomId).toString('base64url')}.operation.${Buffer.from(record.id).toString('base64url')}`,
    'An operation key does not identify its actual room/RoomEdit ID.');
  const records = snapshot.entries.map(({ record }) => record).sort((a, b) => a.id.localeCompare(b.id));
  return { roomId: snapshot.roomId, actor: snapshot.actor, records, heads: validatePersistentAuthorHistory(records) };
}
async function authorConverged(pages, requiredRecords = []) {
  let snapshots;
  await waitUntil(async () => {
    snapshots = await Promise.all(pages.map(actualAuthorJournal));
    for (const snapshot of snapshots) for (const record of requiredRecords) {
      const actual = snapshot.records.find((entry) => entry.id === record.id);
      if (actual) assert.deepEqual(actual, record, `Immutable record ${record.id} changed.`);
    }
    return snapshots.every((snapshot) => snapshot.roomId === snapshots[0].roomId &&
      JSON.stringify(snapshot.records) === JSON.stringify(snapshots[0].records) &&
      requiredRecords.every((record) => snapshot.records.some((entry) => entry.id === record.id)));
  }, 'Complete actual-storage author-prefix journals did not converge.', 60000);
  return snapshots;
}
async function settledAuthorWrites(pages) {
  const roomId = (await actualAuthorJournal(pages[0])).roomId;
  const lockName = `mytree.room-store.v1.journal.${Buffer.from(roomId).toString('base64url')}`;
  await Promise.all(pages.map((page) => page.evaluate((name) => navigator.locks.request(name, () => null), lockName)));
  const committed = await Promise.all(pages.map(actualAuthorJournal));
  const required = [...new Map(committed.flatMap((snapshot) => snapshot.records).map((record) => [record.id, record])).values()];
  return authorConverged(pages, required);
}
function unchangedAuthorPrefix(before, after) {
  appendedHistory(before.records, after.records);
  for (const [author, head] of Object.entries(before.heads)) assert.deepEqual(
    after.heads[author].orderedIds.slice(0, head.orderedIds.length), head.orderedIds,
    `Earlier author order changed after appending beyond captured head ${head.sequence}.`);
}
function authorTreeEdits(records, author, personId, field) {
  return records.filter((record) => {
    if (record.author !== author || record.kind !== 'tree') return false;
    const operation = JSON.parse(record.text);
    return operation.type === 'editText' && operation.personId === personId && operation.field === field;
  });
}
async function authorContext(browser, pages, errors, { timezoneId = 'UTC', isolated = false } = {}) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, timezoneId,
    permissions: ['clipboard-read', 'clipboard-write'], serviceWorkers: 'block', reducedMotion: 'reduce' });
  await context.addInitScript(() => {
    window.__firstFrame = false;
    window.addEventListener('flutter-first-frame', () => { window.__firstFrame = true; }, { once: true });
    window.__channels = [];
    window.__peerConnections = [];
    window.__authorAppendAttempts = [];
    window.__authorQuotaRemaining = 0;
    const nativeSet = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      if (this === localStorage && String(key).startsWith('mytree.room-store.v1.') && String(key).includes('.operation.')) {
        const attempt = { key: String(key), record: JSON.parse(String(value)), failed: window.__authorQuotaRemaining > 0 };
        window.__authorAppendAttempts.push(attempt);
        if (attempt.failed) {
          window.__authorQuotaRemaining--;
          throw new DOMException('Authorized author-history browser check: one failed append', 'QuotaExceededError');
        }
      }
      return nativeSet.call(this, key, value);
    };
    const track = (channel) => { window.__channels.push(channel); return channel; };
    const Native = window.RTCPeerConnection;
    window.RTCPeerConnection = class extends Native {
      constructor(...args) {
        super(...args); // Preserve the production ICE configuration and policy.
        window.__peerConnections.push(this);
        this.addEventListener('datachannel', (event) => track(event.channel), true);
      }
      createDataChannel(...args) { return track(super.createDataChannel(...args)); }
    };
  });
  if (isolated) {
    const appOrigin = new URL(base).origin;
    await context.route('**/*', (route) => {
      const url = new URL(route.request().url());
      const engine = url.hostname === 'www.gstatic.com' && url.pathname.startsWith('/flutter-canvaskit/');
      const font = ['fonts.gstatic.com', 'fonts.googleapis.com'].includes(url.hostname);
      return url.origin === appOrigin || engine || font ? route.continue() : route.abort('internetdisconnected');
    });
    await context.routeWebSocket('**/*', (socket) => socket.close({ code: 1000, reason: 'Explicit isolated author-history fixture' }));
  }
  return { context, async page() {
    const page = await context.newPage();
    page.setDefaultTimeout(20000);
    pages.push(page);
    page.on('pageerror', (error) => errors.push(error.message));
    return page;
  } };
}
async function authorField(page, label) {
  const field = page.getByRole('textbox', { name: label, exact: true });
  await revealBiographyAction(page, field, label === 'Биография' ? 1 : -1);
  return field;
}
async function authorInput(page, label, expected) {
  await focusInput(page, await authorField(page, label), expected);
  return nativeInputValue(page);
}
async function authorType(page, label, value) {
  await type(page, await authorField(page, label), value);
}
async function heldAuthorWrites(pages, fieldsAndValues) {
  const { roomId } = await actualAuthorJournal(pages[0]);
  const lockName = `mytree.room-store.v1.journal.${Buffer.from(roomId).toString('base64url')}`;
  await pages[0].evaluate(async (name) => {
    let acquired;
    const ready = new Promise((resolve) => { acquired = resolve; });
    window.__authorHeldLock = navigator.locks.request(name, async () => {
      await new Promise((resolve) => { window.__authorReleaseLock = resolve; acquired(); });
    });
    await ready;
  }, lockName);
  const start = Date.now();
  try {
    await Promise.all(pages.map(async (page, index) => {
      const [field, value] = fieldsAndValues[index];
      await authorType(page, field, value);
    }));
    const lockStates = await Promise.all(pages.map((page) => page.evaluate(() => navigator.locks.query())));
    assert.ok(lockStates.some((state) => state.pending.filter((lock) => lock.name === lockName).length >= 2),
      'Both same-actor writers did not queue behind the actual room journal Web Lock.');
    return { startedAt: start, completedTypingAt: Date.now(), lockName, lockStates };
  } finally {
    await pages[0].evaluate(async () => { window.__authorReleaseLock(); await window.__authorHeldLock; });
    await pages[0].evaluate((name) => navigator.locks.request(name, () => null), lockName);
  }
}
async function publicAuthorHistory(browser, pages, errors) {
  // Exactly two profiles and three pages; no public-provider fan-out/stress.
  const profileA = await authorContext(browser, pages, errors);
  const profileB = await authorContext(browser, pages, errors);
  const a = await profileA.page();
  const b = await profileB.page();
  await load(a, base);
  await a.getByRole('button', { name: 'Создать комнату', exact: true }).click();
  await admissionName(a, 'Автор А');
  await a.getByRole('button', { name: 'Выбрать Без имени', exact: true }).waitFor({ timeout: 60000 });
  await openBio(a, true);
  await type(a, a.getByRole('textbox', { name: 'Имя', exact: true }), 'Якорь');
  await newRelative(a, 'Отца', 'Отец');
  await closeBio(a);
  const initial = await actualAuthorJournal(a);
  assert.ok(initial.records.length > 0 && initial.records.every((record) => record.authorSequence > 0),
    'A fresh room must persist author proofs, not legacy optimistic drafts.');
  assert.deepEqual(initial.records.find((record) => record.authorSequence === 1).authorBase, []);
  const father = initial.records.filter((record) => record.kind === 'tree').map((record) => JSON.parse(record.text))
    .find((operation) => operation.type === 'createPerson' && operation.name === 'Отец')?.personId;
  assert.ok(father, 'The UI-created stable second person is missing from actual storage.');
  const editorInvite = await invite(a, 'editor');
  await load(b, editorInvite);
  await admissionName(b, 'Автор Б');
  await b.getByRole('button', { name: 'Выбрать Якорь', exact: true }).waitFor({ timeout: 60000 });
  await authorConverged([a, b], initial.records);
  const same = await profileA.page();
  await load(same, base);
  await same.getByRole('button', { name: 'Выбрать Якорь', exact: true }).waitFor({ timeout: 60000 });
  const livePages = [a, same, b];
  const baseline = await authorConverged(livePages, initial.records);
  assert.equal(baseline[0].actor, baseline[1].actor, 'Same-origin tabs did not share the persistent actor.');
  assert.notEqual(baseline[0].actor, baseline[2].actor, 'Fresh independent profiles share an actor.');
  const actorA = baseline[0].actor;
  const actorB = baseline[2].actor;
  const rtc = await Promise.all([a, b].map((page) => page.evaluate(() => ({
    connectedPeers: window.__peerConnections.filter((peer) => peer.connectionState === 'connected').length,
    openChannels: window.__channels.filter((channel) => channel.readyState === 'open').length,
    candidateTypes: window.__peerConnections.filter((peer) => peer.connectionState === 'connected')
      .flatMap((peer) => (peer.localDescription?.sdp || '').split('\n').filter((line) => line.startsWith('a=candidate:'))
        .map((line) => line.match(/ typ (\w+)/)?.[1])),
  }))));
  assert.ok(rtc.every((entry) => entry.connectedPeers > 0 && entry.openChannels > 0),
    `Independent editors have no actual production RTC channel: ${JSON.stringify(rtc)}`);
  await a.getByRole('button', { name: 'Выбрать Якорь', exact: true }).click();
  await openBio(a, true);
  await same.getByRole('button', { name: 'Выбрать Отец', exact: true }).click();
  await openBio(same, true);
  await b.getByRole('button', { name: 'Выбрать Якорь', exact: true }).click();
  await openBio(b, true);
  const contention = await heldAuthorWrites([a, same], [['Имя', 'Якорь-А'], ['Биография', 'Таб-Б']]);
  const firstSnapshots = await settledAuthorWrites(livePages);
  const first = firstSnapshots[0];
  unchangedAuthorPrefix(baseline[0], first);
  const firstAdded = appendedHistory(baseline[0].records, first.records);
  const nameWrites = authorTreeEdits(firstAdded, actorA, 'root', 'name');
  const bioWrites = authorTreeEdits(firstAdded, actorA, father, 'biography');
  assert.ok(nameWrites.length >= 2 && bioWrites.length >= 2, 'Both same-actor tabs must author multiple real edits.');
  assert.equal(nameWrites.length + bioWrites.length, firstAdded.length, 'Concurrent tab typing appended unexpected IDs.');
  await authorInput(a, 'Имя', 'Якорь-А');
  await authorInput(same, 'Биография', 'Таб-Б');
  await authorInput(b, 'Имя', 'Якорь-А');
  await a.screenshot({ path: path.join(output, 'public-same-author-name.png'), animations: 'disabled' });
  await same.screenshot({ path: path.join(output, 'public-same-author-biography.png'), animations: 'disabled' });
  // Capture every author's exact earlier order at head N, then append beyond N
  // from both local tabs and the independent RTC editor on separate registers.
  const checkpoint = { records: first.records, heads: first.heads };
  await Promise.all([
    authorType(a, 'Биография', 'Префикс-А'),
    authorType(same, 'Имя', 'Отец-Б'),
    authorType(b, 'Имя', 'Якорь-В'),
  ]);
  const after = (await settledAuthorWrites(livePages))[0];
  unchangedAuthorPrefix(checkpoint, after);
  const later = appendedHistory(first.records, after.records);
  const laterA = authorTreeEdits(later, actorA, 'root', 'biography');
  const laterSame = authorTreeEdits(later, actorA, father, 'name');
  const laterB = authorTreeEdits(later, actorB, 'root', 'name');
  assert.ok(laterA.length && laterSame.length && laterB.length, 'One of the three actual writers did not append.');
  assert.equal(laterA.length + laterSame.length + laterB.length, later.length, 'Further typing appended unrelated IDs.');
  for (const record of appendedHistory(initial.records, after.records)) {
    assert.ok(record.authorSequence > 0, 'An unfinalized optimistic draft reached persistent history.');
    assert.ok(record.createdAt >= contention.startedAt - 300000 && record.createdAt <= Date.now() + 10000,
      'New createdAt is not a current UTC epoch millisecond timestamp.');
  }
  for (const page of [a, b]) {
    await authorInput(page, 'Имя', 'Якорь-В');
    await authorInput(page, 'Биография', 'Префикс-А');
  }
  await authorInput(same, 'Имя', 'Отец-Б');
  await authorInput(same, 'Биография', 'Таб-Б');
  await b.screenshot({ path: path.join(output, 'public-independent-peer-complete-prefix.png'), animations: 'disabled' });
  for (const page of livePages) await closeBio(page);
  for (const [index, page] of livePages.entries()) {
    await page.reload({ waitUntil: 'domcontentloaded' });
    await activate(page);
    await page.getByRole('button', { name: 'Выбрать Якорь-В', exact: true }).waitFor({ timeout: 60000 });
    await authorConverged(livePages, after.records);
    const reloaded = await actualAuthorJournal(page);
    assert.deepEqual(reloaded.records, after.records, 'Reload removed, added or rewrote immutable history.');
    unchangedAuthorPrefix(checkpoint, reloaded);
    await page.getByRole('button', { name: index === 1 ? 'Выбрать Отец-Б' : 'Выбрать Якорь-В', exact: true }).click();
    await openBio(page, true);
    await authorInput(page, 'Имя', index === 1 ? 'Отец-Б' : 'Якорь-В');
    await authorInput(page, 'Биография', index === 1 ? 'Таб-Б' : 'Префикс-А');
    await page.screenshot({ path: path.join(output, `public-author-reloaded-${index + 1}.png`), animations: 'disabled' });
    await closeBio(page);
  }
  const finals = await authorConverged(livePages, after.records);
  for (const snapshot of finals) assert.deepEqual(snapshot.records, after.records, 'Read-only checks/reloads appended hidden IDs.');
  assert.deepEqual(errors, []);
  await fs.writeFile(path.join(output, 'public-author-history-journal.json'), JSON.stringify(after.records, null, 2));
  await fs.writeFile(path.join(output, 'author-history-public.json'), JSON.stringify({
    application: base, suite: 'author-history', headless: true, completed: true,
    independentProfiles: 2, pages: 3, actors: [actorA, actorA, actorB], rtc,
    assertions: { actualProductionRTC: true, freshRoomEmptyFirstBase: true, sameActorWritersContendedOnRoomWebLock: true,
      fullPersistentChainsContiguousAndClosed: true, noDuplicateSequencesOrExtraIds: true,
      earlierPerAuthorOrderStableAfterFurtherAppends: true, allThreeJournalsCompleteAndEqual: true,
      allPagesReloadedWithoutHistoryMutation: true, expectedNameAndBiographyOnAllPages: true },
    contention, earlierHeads: checkpoint.heads, finalHeads: after.heads,
    concurrentWriterRecords: { nameIds: nameWrites.map((record) => record.id), biographyIds: bioWrites.map((record) => record.id) },
    laterWriterRecords: { localIds: laterA.map((record) => record.id), sameActorTabIds: laterSame.map((record) => record.id),
      independentPeerIds: laterB.map((record) => record.id) },
    completeJournal: after.records, browserErrors: errors,
    notAssertedAtBrowserWireLayer: ['authorHistory capability and empty fast-welcome preview (PeerJS encoding is not decoded here)',
      'malformed missing-predecessor injection (unit tests; every observed actual persistent journal is fully validated)'],
  }, null, 2));
  console.log('PASS: actual public RTC, two independent editor profiles / three pages; same-actor concurrent Web Lock writers, full contiguous author prefixes, exact typed-operation IDs, stable earlier order and complete journals after every reload.');
}
// Only the focused recovery mode installs these faults. They operate on real
// native DataChannels, leave production signaling/ICE/security unchanged, and
// never fabricate a packet, a storage write, an open event, or a successful ACK.
function initialSyncInstrumentation() {
  if (!['http:', 'https:'].includes(location.protocol)) return;
  const armed = sessionStorage.getItem('mytree-check.initial-sync-recovery') === 'armed';
  const state = window.__initialSyncCheck = { armed, holdAck: armed, cut: false, trace: [], queued: [], overflow: false };
  const durable = () => Object.keys(localStorage).filter((key) =>
    key.startsWith('mytree.room-store.v1.') && key.includes('.operation.'))
    .map((key) => JSON.parse(localStorage.getItem(key))).sort((a, b) => a.id.localeCompare(b.id));
  const record = (entry) => {
    if (state.trace.length >= 1000) { state.overflow = true; return; }
    state.trace.push({ seq: state.trace.length, at: Date.now(), ...entry });
  };
  const parse = (data) => {
    try { return typeof data === 'string' ? JSON.parse(data) : null; } catch (_) { return null; }
  };
  let channelId = 0;
  const admitted = new Set();
  const track = (channel) => {
    const id = ++channelId;
    let incoming = false;
    const send = channel.send.bind(channel);
    const evidence = (packet) => packet ? { type: packet.type, actor: packet.actor,
      syncId: packet.syncId, syncDigest: packet.syncDigest, roomReady: packet.roomReady,
      authorHistory: packet.authorHistory, durableSync: packet.durableSync,
      historyIds: packet.history?.map((edit) => edit.id), inventory: packet.inventory } : { opaque: true };
    channel.addEventListener('close', () => { admitted.delete(channel); record({ event: 'closed', channel: id, incoming }); });
    channel.addEventListener('message', (event) => {
      const packet = parse(event.data);
      if (packet?.type === 'hello') { incoming = true; admitted.add(channel); }
      if (packet?.type === 'welcome') admitted.add(channel);
      record({ event: 'receive', channel: id, incoming, ...evidence(packet) });
    }, true);
    channel.send = (data) => {
      const packet = parse(data);
      const entry = { channel: id, incoming, ...evidence(packet) };
      if (armed && incoming && !state.cut && packet?.type === 'checkpoint') {
        state.cut = true;
        record({ event: 'cut-before-send', ...entry, admittedChannels: admitted.size, durable: durable() });
        channel.close();
        return;
      }
      if (state.holdAck && packet?.type === 'syncAck') {
        record({ event: 'held-ack', ...entry, durable: durable() });
        state.queued.push({ channel, send, data, entry });
        return;
      }
      send(data);
      record({ event: 'send', ...entry, ...(packet?.type === 'syncAck' ? { durable: durable() } : {}) });
    };
    return channel;
  };
  window.__releaseInitialSyncAck = () => {
    state.holdAck = false;
    for (const queued of state.queued.splice(0)) {
      if (queued.channel.readyState !== 'open') continue; // Never replay a stale generation into another channel.
      queued.send(queued.data);
      record({ event: 'send-released-ack', ...queued.entry, durable: durable() });
    }
  };
  const Native = window.RTCPeerConnection;
  window.RTCPeerConnection = class extends Native {
    constructor(...args) {
      super(...args);
      this.addEventListener('datachannel', (event) => track(event.channel), true);
    }
    createDataChannel(...args) { return track(super.createDataChannel(...args)); }
  };
}
function initialSyncFixture() {
  const crypto = require('node:crypto');
  const actorA = crypto.randomBytes(16).toString('hex');
  const actorB = crypto.randomBytes(16).toString('hex');
  const roomId = crypto.randomBytes(16).toString('hex');
  const source = authorLegacySeed();
  const records = [...source.records.map((record) => ({ ...record, author: actorA,
    ...(record.targetActor ? { targetActor: actorA } : {}) })),
  { kind: 'participantRole', text: 'editor', author: actorA, targetActor: actorB },
  { kind: 'participantName', text: 'Сохранённый редактор Б', author: actorB }];
  const previous = new Map();
  for (const [index, record] of records.entries()) {
    const head = previous.get(record.author);
    Object.assign(record, { id: `initial-sync-${roomId}-${index + 1}`, clock: index + 1,
      createdAt: source.createdAt, authorSequence: (head?.authorSequence || 0) + 1,
      authorPrevious: head?.id || null, ...(head ? {} : { authorBase: [] }) });
    previous.set(record.author, record);
  }
  validatePersistentAuthorHistory(records);
  const prefix = 'mytree.room-store.v1.';
  const roomPrefix = `${prefix}room.${Buffer.from(roomId).toString('base64url')}.`;
  const storage = { [`${prefix}last-room`]: JSON.stringify(roomId), [`${roomPrefix}membership`]: JSON.stringify(roomId) };
  for (const record of records) storage[`${roomPrefix}operation.${Buffer.from(record.id).toString('base64url')}`] = JSON.stringify(record);
  return { roomId, actors: [actorA, actorB], records, storage };
}
function initialSyncDigest(records) {
  const hash = (value) => require('node:crypto').createHash('sha256').update(JSON.stringify(value)).digest('hex');
  return hash(records.map((record) => [record.id, hash([record.id, record.author, record.clock,
    record.createdAt, record.text, ...((record.kind || 'text') !== 'text' ? [record.kind] : []),
    ...(record.targetActor != null ? [record.targetActor] : []),
    ...(record.authorSequence != null ? [[record.authorSequence, record.authorPrevious, record.authorBase ?? null]] : [])])])
    .sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
}
async function initialSyncPending(page) {
  const semantics = await body(page);
  assert.match(semantics, /Открываем комнату|Не удалось открыть комнату/, 'The unconfirmed saved room escaped its initial entry gate.');
  assert.doesNotMatch(semantics, /Онлайн ·|История комнаты проверена|Локальная копия ·/,
    'An unconfirmed checkpoint was presented as online, confirmed, or an automatic local copy.');
  assert.equal(await page.getByRole('button', { name: /^Выбрать Якорь/ }).count(), 0,
    'The production editor appeared before a durable checkpoint ACK.');
  return semantics;
}
async function initialSyncRecovery(browser, pages, errors) {
  let fixture = initialSyncFixture();
  const retryPath = process.env.MYTREE_INITIAL_SYNC_RETRY;
  if (retryPath) {
    const previous = JSON.parse(await fs.readFile(retryPath, 'utf8'));
    assert.equal(previous.suite, 'initial-sync-recovery');
    assert.equal(previous.application, base, 'A harness retry must retain the same application origin.');
    assert.equal(previous.diagnostics.length, 2);
    const captured = previous.diagnostics;
    const roomId = JSON.parse(captured[0].storage['mytree.room-store.v1.last-room']);
    assert.equal(JSON.parse(captured[1].storage['mytree.room-store.v1.last-room']), roomId);
    fixture = { roomId, actors: captured.map((entry) => JSON.parse(entry.storage['mytree.room-store.v1.client-id'])),
      records: captured[1].completeJournal, completeJournal: captured[0].completeJournal,
      capturedStorage: captured.map((entry) => entry.storage) };
    fixture.capturedStorage.forEach((storage, index) => validatePersistentAuthorHistory(captured[index].completeJournal));
  }
  const consoleErrors = [];
  const profiles = [];
  for (const [profileIndex, actor] of fixture.actors.entries()) {
    const profile = await authorContext(browser, pages, errors);
    await profile.context.addInitScript(initialSyncInstrumentation);
    const page = await profile.page();
    page.__initialSyncConsoleErrors = [];
    page.on('console', (message) => {
      if (message.type() !== 'error') return;
      const error = { actor, text: message.text() };
      consoleErrors.push(error);
      page.__initialSyncConsoleErrors.push(error);
    });
    const seedUrl = new URL('__initial_sync_fixture__', base).href;
    await profile.context.route(seedUrl, (route) => route.fulfill({ contentType: 'text/html', body: '<!doctype html><title>Saved room fixture</title>' }));
    await page.goto(seedUrl);
    await page.evaluate((storage) => { for (const [key, value] of Object.entries(storage)) localStorage.setItem(key, value); },
      fixture.capturedStorage?.[profileIndex] || { ...fixture.storage, 'mytree.room-store.v1.client-id': JSON.stringify(actor) });
    if (retryPath) await page.evaluate(() => sessionStorage.setItem('mytree-check.initial-sync-recovery', 'armed'));
    await profile.context.unroute(seedUrl);
    profiles.push({ ...profile, page });
  }
  const live = profiles.map((profile) => profile.page);
  // One bounded public baseline attempt. A targeted harness-only retry can
  // restore that attempt's exact saved journals without repeating its baseline.
  const traces = () => Promise.all(live.map((page) => page.evaluate(() => ({
    armed: window.__initialSyncCheck.armed, cut: window.__initialSyncCheck.cut,
    overflow: window.__initialSyncCheck.overflow, trace: window.__initialSyncCheck.trace,
    peers: window.__peerConnections.map((peer) => ({ connection: peer.connectionState, ice: peer.iceConnectionState })),
    channels: window.__channels.map((channel) => channel.readyState),
  }))));
  let baseline;
  let baselineTransport;
  let before;
  let startedAt;
  if (retryPath) {
    baseline = await Promise.all(live.map(actualAuthorJournal));
    before = baseline[0];
    assert.deepEqual(before.records, fixture.completeJournal);
    assert.ok(before.records.length > fixture.records.length, 'The exact captured UI tail is missing.');
    baselineTransport = { priorAttempt: retryPath, repeated: false };
    startedAt = Date.now();
    await Promise.all(live.map((page) => load(page, base)));
  } else {
    await Promise.all(live.map((page) => load(page, base)));
    await Promise.all(live.map((page) => page.getByRole('button', { name: 'Выбрать Якорь', exact: true }).waitFor({ timeout: 65000 })));
    baseline = await authorConverged(live, fixture.records);
    baselineTransport = await traces();
    assert.ok(baselineTransport.every((entry) => entry.channels.includes('open') &&
      entry.peers.some((peer) => peer.connection === 'connected')), 'The two saved profiles did not establish actual public RTC.');
    assert.notEqual(baseline[0].actor, baseline[1].actor);
    for (const snapshot of baseline) assert.deepEqual(snapshot.records,
      [...fixture.records].sort((a, b) => a.id.localeCompare(b.id)), 'Saved-member baseline appended hidden writes.');
    // Retain the unloaded member's prefix; author the durable tail via real UI.
    await live[1].evaluate(() => sessionStorage.setItem('mytree-check.initial-sync-recovery', 'armed'));
    await live[1].goto('about:blank');
    await openBio(live[0], true);
    await authorType(live[0], 'Биография', 'Новая сохранённая история');
    await closeBio(live[0]);
    before = (await settledAuthorWrites([live[0]]))[0];
    unchangedAuthorPrefix(baseline[0], before);
    assert.ok(before.records.length > baseline[0].records.length, 'The host did not persist its actual UI-authored tail.');
    await live[0].evaluate(() => sessionStorage.setItem('mytree-check.initial-sync-recovery', 'armed'));
    startedAt = Date.now();
    await Promise.all([live[0].reload({ waitUntil: 'domcontentloaded' }).then(() => activate(live[0])), load(live[1], base)]);
  }
  const initialSemantics = await Promise.all(live.map(body));
  const pendingSamples = [];
  await waitUntil(async () => {
    pendingSamples.push({ at: Date.now(), semantics: await Promise.all(live.map(body)) });
    return (await traces()).some((entry) => entry.cut);
  }, 'No actual incoming-host initial checkpoint was reached and closed; public-service or harness limitation.', 45000);
  const atCut = await traces();
  const atCutSemantics = await Promise.all(live.map(body));
  const pendingIndices = atCutSemantics.flatMap((semantics, index) =>
    /Открываем комнату|Не удалось открыть комнату/.test(semantics) ? [index] : []);
  assert.ok(pendingIndices.length, 'Neither saved member remained in its initial gate at the actual channel cut.');
  const pendingPages = pendingIndices.map((index) => live[index]);
  await Promise.all(pendingPages.map(initialSyncPending));
  const cuts = atCut.flatMap((entry, profile) => entry.trace.filter((event) => event.event === 'cut-before-send').map((event) => ({ profile, ...event })));
  assert.ok(cuts.length && cuts.every((event) => event.incoming && event.type === 'checkpoint' && event.admittedChannels === 1),
    'The fault did not close the last admitted incoming host-side checkpoint channel.');
  await Promise.all(live.map((page, index) => page.screenshot({ path: path.join(output, `initial-checkpoint-closed-${index + 1}.png`), animations: 'disabled' })));
  // A single ACK hold retains the real fixed 30s entry watchdog. The app may
  // renegotiate naturally; no retry/local-copy button or second load is used.
  while (Date.now() - startedAt < 33000) {
    pendingSamples.push({ at: Date.now(), profiles: pendingIndices, semantics: await Promise.all(pendingPages.map(initialSyncPending)) });
    await sleep(500);
  }
  const timedOut = await Promise.all(pendingPages.map(initialSyncPending));
  assert.ok(timedOut.some((text) => /30 секунд/.test(text)), 'The fixed 30s entry watchdog was not observable under held ACKs.');
  const beforeRelease = await Promise.all(live.map(actualAuthorJournal));
  beforeRelease.forEach((snapshot, index) => unchangedAuthorPrefix(baseline[index], snapshot));
  await Promise.all(live.map((page, index) => page.screenshot({ path: path.join(output, `saved-room-30s-unconfirmed-${index + 1}.png`), animations: 'disabled' })));
  const heldTransport = await traces();
  assert.ok(heldTransport.some((entry) => entry.trace.some((event) => event.event === 'held-ack')),
    'No real JSON checkpoint ACK was held; this is not durable-gate evidence.');
  await fs.writeFile(path.join(output, 'initial-sync-before-recovery.json'), JSON.stringify({ startedAt, cuts, baselineTransport,
    initialSemantics, atCutSemantics, pendingIndices, pendingSamples, timedOut, beforeRelease, heldTransport,
    expectedCompleteJournal: before.records, retrySource: retryPath, consoleErrors, browserErrors: errors }, null, 2));
  await Promise.all(live.map((page) => page.evaluate(() => window.__releaseInitialSyncAck())));
  await Promise.all(live.map((page) => page.getByRole('button', { name: 'Выбрать Якорь', exact: true }).waitFor({ timeout: 65000 })));
  const recovered = await authorConverged(live, before.records);
  const recoveryTransport = await traces();
  assert.ok(recoveryTransport.some((entry) => {
    const cut = entry.trace.find((event) => event.event === 'cut-before-send');
    return cut && entry.trace.some((event) => event.channel !== cut.channel && event.seq > cut.seq &&
      ['hello', 'welcome'].includes(event.type) && ['receive', 'send'].includes(event.event));
  }), 'No new actual channel handshake followed the incoming-host channel close.');
  const ackEvidence = [];
  for (const [profile, entry] of recoveryTransport.entries()) {
    assert.equal(entry.overflow, false, 'The bounded RTC evidence buffer overflowed.');
    for (const event of entry.trace.filter((item) => item.event === 'send' || item.event === 'send-released-ack')) {
      if (event.type !== 'syncAck') continue;
      const checkpoint = entry.trace.find((item) => item.channel === event.channel && item.event === 'receive' &&
        item.type === 'checkpoint' && item.syncId === event.syncId && item.syncDigest === event.syncDigest);
      assert.ok(checkpoint, 'A delivered real ACK has no matching observed checkpoint.');
      validatePersistentAuthorHistory(event.durable);
      const candidates = [fixture.records, before.records, event.durable];
      const expected = candidates.find((records) => initialSyncDigest(records) === event.syncDigest);
      assert.ok(expected, 'ACK digest does not identify an observed complete immutable author prefix.');
      for (const record of expected) assert.deepEqual(event.durable.find((actual) => actual.id === record.id), record,
        'A real ACK preceded durable full-prefix persistence.');
      ackEvidence.push({ profile, channel: event.channel, at: event.at, roomReady: event.roomReady,
        syncId: event.syncId, syncDigest: event.syncDigest, durableIds: event.durable.map((record) => record.id) });
    }
  }
  assert.ok(ackEvidence.some((entry) => entry.roomReady), 'Recovery has no observed final roomReady ACK.');
  for (const [index, snapshot] of recovered.entries()) {
    unchangedAuthorPrefix(baseline[index], snapshot);
    assert.deepEqual(snapshot.records, before.records, 'Recovery added, removed, or rewrote immutable journal records.');
  }
  for (const [index, page] of live.entries()) {
    assert.doesNotMatch(await body(page), /Локальная копия ·|Не удалось открыть комнату/);
    await openBio(page, true);
    await authorInput(page, 'Биография', 'Новая сохранённая история');
    await page.screenshot({ path: path.join(output, `recovered-complete-journal-${index + 1}.png`), animations: 'disabled' });
    await closeBio(page);
    await page.evaluate(() => sessionStorage.removeItem('mytree-check.initial-sync-recovery'));
    await page.reload({ waitUntil: 'domcontentloaded' });
    await activate(page);
    await page.getByRole('button', { name: 'Выбрать Якорь', exact: true }).waitFor({ timeout: 65000 });
    assert.deepEqual((await actualAuthorJournal(page)).records, before.records, 'Reload changed the complete canonical journal.');
    await page.screenshot({ path: path.join(output, `complete-journal-reloaded-${index + 1}.png`), animations: 'disabled' });
  }
  await authorConverged(live, before.records);
  assert.deepEqual(errors, []);
  await fs.writeFile(path.join(output, 'initial-sync-recovery.json'), JSON.stringify({ application: base, suite,
    headless: true, completed: true, independentProfiles: 2, roomId: fixture.roomId, actors: fixture.actors,
    fixtureProvenance: retryPath ? 'exact saved journals captured after the first attempt actual public baseline and real UI-authored tail; baseline not repeated'
      : 'unique pre-load saved memberships and complete schema-valid author-prefix journals; later tail authored through actual UI',
    startedAt, cuts, baselineTransport, initialSemantics, atCutSemantics, pendingIndices, pendingSamples, timedOut,
    heldTransport, recoveryTransport, ackEvidence, retrySource: retryPath,
    coverage: { incomingHostStillInitiallyGatedAtCut: cuts.some((cut) => pendingIndices.includes(cut.profile)),
      alreadySoloReadyProfilesAtCut: live.map((_, index) => index).filter((index) => !pendingIndices.includes(index)) },
    assertions: { actualPublicRTC: true, incomingHostCheckpointClosed: true, fixed30sGateStayedUnconfirmed: true,
      recoveredAutomaticallyWithoutRetryOrLocalCopy: true, ackFollowedCompleteDurablePrefix: true,
      savedHistoryImmutable: true, noAutomaticLocalCopyOrFalseOnline: true, completeJournalOnBothReloads: true },
    completeJournal: before.records, consoleErrors, browserErrors: errors }, null, 2));
  console.log('PASS: real two-profile saved-room initial checkpoint close, truthful 30s gate, automatic fresh-channel recovery, full durable-prefix ACK, immutable journals and reload.');
}
function authorLegacySeed() {
  const actor = 'e'.repeat(32);
  const roomId = 'f'.repeat(32);
  const createdAt = Date.UTC(2026, 9, 16, 22, 30);
  const records = [
    { kind: 'participantName', text: 'UTC fixture' },
    { kind: 'participantRole', text: 'editor', targetActor: actor },
    { kind: 'tree', text: JSON.stringify({ type: 'editText', personId: 'root', field: 'name', itemId: null,
      inserts: [...'Якорь'].map((text, index) => ({ id: `utc-name-${index}`, text,
        left: index ? `utc-name-${index - 1}` : null, right: null })), deletes: [] }) },
    { kind: 'roomName', text: 'UTC fixture room' },
  ].map((record, index) => ({ id: `utc-legacy-${index + 1}`, author: actor, clock: index + 1, createdAt, ...record }));
  const prefix = 'mytree.room-store.v1.';
  const roomPrefix = `${prefix}room.${Buffer.from(roomId).toString('base64url')}.`;
  const storage = { [`${prefix}client-id`]: JSON.stringify(actor), [`${prefix}last-room`]: JSON.stringify(roomId),
    [`${roomPrefix}membership`]: JSON.stringify(roomId) };
  for (const record of records) storage[`${roomPrefix}operation.${Buffer.from(record.id).toString('base64url')}`] = JSON.stringify(record);
  return { provenance: 'explicit schema-valid isolated all-legacy fixture; no public room data', actor, roomId, createdAt,
    records: records.sort((a, b) => a.id.localeCompare(b.id)), storage };
}
async function seedAuthorPage(profile, seed) {
  const page = await profile.page();
  const seedUrl = new URL('__author_history_fixture__', base).href;
  await profile.context.route(seedUrl, (route) => route.fulfill({ contentType: 'text/html', body: '<!doctype html><title>Author history fixture</title>' }));
  await page.goto(seedUrl);
  await page.evaluate((storage) => { for (const [key, value] of Object.entries(storage)) localStorage.setItem(key, value); }, seed.storage);
  await profile.context.unroute(seedUrl);
  await load(page, base);
  await page.getByRole('button', { name: 'Открыть локальную копию', exact: true }).click({ timeout: 60000 });
  await page.getByRole('button', { name: 'Выбрать Якорь', exact: true }).waitFor();
  assert.match(await body(page), /Локальная копия · синхронизация не подтверждена/);
  assert.deepEqual((await actualAuthorJournal(page)).records, seed.records, 'Reading an old empty-proof journal changed its bytes.');
  return page;
}
async function timezoneJournal(page, timezoneId, expectedDay, expectedHour, screenshot) {
  const browserTime = await page.evaluate((epoch) => ({ timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    day: new Date(epoch).getDate(), hour: new Date(epoch).getHours() }), Date.UTC(2026, 9, 16, 22, 30));
  assert.equal(browserTime.timezone, timezoneId);
  assert.equal(browserTime.day, expectedDay);
  assert.equal(browserTime.hour, expectedHour);
  await page.getByRole('button', { name: /Меню комнаты/ }).click();
  await page.getByRole('menuitem', { name: 'Журнал изменений', exact: true }).click();
  const dialog = page.getByRole('alertdialog');
  await dialog.waitFor();
  const semantics = await dialog.ariaSnapshot();
  if (timezoneId === 'UTC') {
    assert.match(semantics, /Oct 16, 2026|10\/16\/2026|16[./]10[./]2026/);
    assert.match(semantics, /10:30\s*PM|22:30/);
  } else {
    assert.match(semantics, /Oct 17, 2026|10\/17\/2026|17[./]10[./]2026/);
    assert.match(semantics, /1:30\s*AM|0?1:30/);
  }
  await page.screenshot({ path: path.join(output, screenshot), animations: 'disabled' });
  await dialog.getByRole('button', { name: 'Закрыть', exact: true }).click();
  return { browserTime, semantics };
}
async function localAuthorHistory(browser, pages, errors) {
  const seed = authorLegacySeed();
  const utcProfile = await authorContext(browser, pages, errors, { isolated: true });
  const moscowProfile = await authorContext(browser, pages, errors, { isolated: true, timezoneId: 'Europe/Moscow' });
  const a = await seedAuthorPage(utcProfile, seed);
  const moscow = await seedAuthorPage(moscowProfile, seed);
  const utcJournal = await timezoneJournal(a, 'UTC', 16, 22, 'local-journal-utc.png');
  const moscowJournal = await timezoneJournal(moscow, 'Europe/Moscow', 17, 1, 'local-journal-moscow.png');
  assert.deepEqual(await storedRoom(a), seed.storage, 'Journal display mutated legacy UTC storage.');
  assert.deepEqual(await storedRoom(moscow), seed.storage, 'Local timezone conversion mutated epoch timestamps.');
  // Close the timezone-only fixture before opening the second actual writer.
  await moscowProfile.context.close();
  const same = await utcProfile.page();
  await load(same, base);
  const local = same.getByRole('button', { name: 'Открыть локальную копию', exact: true });
  await waitUntil(async () => await local.count() || await same.getByRole('button', { name: 'Выбрать Якорь', exact: true }).count(),
    'The second isolated tab exposed neither a local-copy action nor the saved tree.', 60000);
  if (await local.count()) await local.click();
  await same.getByRole('button', { name: 'Выбрать Якорь', exact: true }).waitFor({ timeout: 60000 });
  const baseline = (await authorConverged([a, same], seed.records))[0];
  await openBio(a, true);
  await openBio(same, true);
  const contention = await heldAuthorWrites([a, same], [['Имя', 'Якорь-А'], ['Биография', 'Локально-Б']]);
  const first = (await settledAuthorWrites([a, same]))[0];
  unchangedAuthorPrefix(baseline, first);
  const firstAdded = appendedHistory(seed.records, first.records);
  assert.ok(firstAdded.length > 2 && firstAdded.every((record) => record.authorSequence > 0));
  assert.deepEqual(firstAdded.find((record) => record.authorSequence === 1).authorBase, seed.records.map((record) => record.id).sort());
  await authorInput(a, 'Имя', 'Якорь-А');
  await authorInput(same, 'Биография', 'Локально-Б');
  // One authorized synchronous quota error on a real local UI append. Keep its
  // core JSON, let the sibling advance the frontier, then retry the same ID.
  await authorInput(a, 'Имя', 'Якорь-А');
  await a.keyboard.press('Control+End');
  await a.evaluate(() => { window.__authorQuotaRemaining = 1; });
  await a.keyboard.insertText('!');
  await waitUntil(async () => /Не сохранено:|Не удалось сохранить изменения/.test(await body(a)),
    'A failed actual storage append was hidden.');
  const failed = await a.evaluate(() => window.__authorAppendAttempts.filter((attempt) => attempt.failed));
  assert.equal(failed.length, 1, 'The authorized quota hook must fail exactly one attempted operation append.');
  const failedRecord = failed[0].record;
  const afterFailure = await actualAuthorJournal(a);
  assert.deepEqual(afterFailure.records, first.records, 'The failed append persisted an optimistic ID or reserved a sequence hole.');
  await a.screenshot({ path: path.join(output, 'local-author-unsaved-visible.png'), animations: 'disabled' });
  await authorInput(same, 'Биография', 'Локально-Б');
  await same.keyboard.press('Control+End');
  await same.keyboard.insertText('+');
  await waitUntil(async () => (await actualAuthorJournal(same)).records.length === first.records.length + 1,
    'The sibling could not advance the persistent prefix after another tab failed.');
  const sibling = await actualAuthorJournal(same);
  const siblingRecord = appendedHistory(first.records, sibling.records)[0];
  assert.equal(siblingRecord.authorSequence, first.heads[seed.actor].sequence + 1, 'A failed append consumed a sequence.');
  assert.ok(!sibling.records.some((record) => record.id === failedRecord.id), 'A sibling refresh accidentally published the unsaved draft.');
  // There can be a main status retry and a biography failure-dialog retry. Both
  // are real UI actions; never call a runtime session/storage method directly.
  const retry = a.getByRole('button', { name: 'Повторить сохранение', exact: true }).last();
  await revealBiographyAction(a, retry, -1);
  await retry.click();
  await waitUntil(async () => (await actualAuthorJournal(a)).records.some((record) => record.id === failedRecord.id),
    'Retry did not persist the exact original draft ID.');
  const recovered = (await authorConverged([a, same], sibling.records))[0];
  const canonical = recovered.records.find((record) => record.id === failedRecord.id);
  const core = (record) => Object.fromEntries(Object.entries(record).filter(([key]) => !['authorSequence', 'authorPrevious', 'authorBase'].includes(key)));
  assert.deepEqual(core(canonical), core(failedRecord), 'Retry changed the original ID/payload/clock/createdAt core.');
  assert.equal(canonical.authorSequence, siblingRecord.authorSequence + 1);
  assert.equal(canonical.authorPrevious, siblingRecord.id);
  assert.equal(recovered.records.length, first.records.length + 2, 'Retry added duplicate/unexpected IDs.');
  unchangedAuthorPrefix(first, recovered);
  await waitUntil(async () => !/Не сохранено:|Не удалось сохранить изменения/.test(await body(a)),
    'Successful retry did not clear the actual save error.');
  for (const page of [a, same]) {
    await authorInput(page, 'Имя', 'Якорь-А!');
    await authorInput(page, 'Биография', 'Локально-Б+');
    await closeBio(page);
  }
  for (const [index, page] of [a, same].entries()) {
    await page.reload({ waitUntil: 'domcontentloaded' });
    await activate(page);
    const openLocal = page.getByRole('button', { name: 'Открыть локальную копию', exact: true });
    await waitUntil(async () => await openLocal.count() || await page.getByRole('button', { name: 'Выбрать Якорь-А!', exact: true }).count(),
      'An isolated reload exposed neither a local-copy action nor the complete tree.', 60000);
    if (await openLocal.count()) await openLocal.click();
    await page.getByRole('button', { name: 'Выбрать Якорь-А!', exact: true }).waitFor({ timeout: 60000 });
    assert.match(await body(page), /Локальная копия · синхронизация не подтверждена/);
    assert.deepEqual((await actualAuthorJournal(page)).records, recovered.records, 'Reload rewrote or lost legacy/proven history.');
    await openBio(page, true);
    await authorInput(page, 'Имя', 'Якорь-А!');
    await authorInput(page, 'Биография', 'Локально-Б+');
    await page.screenshot({ path: path.join(output, `local-author-reloaded-${index + 1}.png`), animations: 'disabled' });
    await closeBio(page);
  }
  assert.deepEqual(errors, []);
  await fs.writeFile(path.join(output, 'author-history-local.json'), JSON.stringify({
    application: base, suite: 'author-history-local', headless: true, completed: true, networkIsolated: true,
    provenance: seed.provenance, timezoneEvidence: { epoch: seed.createdAt, utcJournal, moscowJournal },
    assertions: { legacyJSONReadableUnchanged: true, firstProofSealsExactOwnLegacyBase: true,
      actualBrowserTimezoneDateRollover: true, concurrentSameActorWebLockWriters: true,
      fullPersistentPrefixesContiguous: true, failedAppendVisibleAndConsumesNoSequence: true,
      siblingAdvancesBeforeRetry: true, retryPreservesCoreIdPayloadClockAndTime: true,
      retryReallocatesAgainstCurrentCanonicalHead: true, noExtraIds: true,
      earlierAuthorOrderStable: true, bothTabsReloadPreserveCompleteJournal: true,
      localCopyNeverClaimsConfirmedNetworkSync: true },
    contention, failedAttempt: failed[0], siblingRecord, retriedCanonicalRecord: canonical,
    earlierHeads: first.heads, finalHeads: recovered.heads, completeJournal: recovered.records, browserErrors: errors,
    skipped: ['public RTC and independent live peer (intentionally blocked in this fixture mode)'],
  }, null, 2));
  console.log('PASS: isolated actual localStorage, legacy base sealing, concurrent same-author tabs, visible failed append/no sequence hole, stable-core retry after sibling append, complete journals/reloads; real UTC/Moscow journal date rollover.');
}

(async () => {
  await fs.mkdir(output, { recursive: true });
  if (tracedPublicFeature || cleanAddressSuite || firstAdmissionSuite) assert.deepEqual(await fs.readdir(output), [],
    'Use a fresh empty focused-feature artifacts directory; failed evidence is never overwritten.');
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const pages = [];
  const errors = [];
  try {
    if (firstAdmissionSuite) {
      await firstAdmissionDiagnostic(browser);
      return;
    }
    if (cleanAddressSuite) {
      await cleanAddressLocal(browser, pages, errors);
      return;
    }
    if (suite === 'initial-sync-recovery') {
      await initialSyncRecovery(browser, pages, errors);
      return;
    }
    if (['identity-actions-local', 'dialogs-local'].includes(suite)) {
      await localIdentityActions(browser, pages, errors);
      return;
    }
    if (suite === 'identity-local') {
      await localCompactIdentity(browser, pages, errors);
      return;
    }
    if (suite === 'author-history') {
      await publicAuthorHistory(browser, pages, errors);
      return;
    }
    if (suite === 'author-history-local') {
      await localAuthorHistory(browser, pages, errors);
      return;
    }
    if (suite === 'guest-identity-legacy') {
      let seed;
      try {
        seed = JSON.parse(await fs.readFile(path.join(output, 'legacy-guest-seed.json'), 'utf8'));
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
        seed = await simpleLegacySeed();
        await fs.writeFile(path.join(output, 'legacy-guest-seed.json'), JSON.stringify(seed, null, 2));
      }
      if (seed.provenance === 'explicit schema-valid isolated fixture; no public room data' && seed.fixtureVersion !== 2) {
        seed = await simpleLegacySeed();
        await fs.writeFile(path.join(output, 'legacy-guest-seed.json'), JSON.stringify(seed, null, 2));
      }
      await legacyGuestIdentity(browser, seed.storage, seed.journal, seed.guestActor, seed.roomId, errors, pages);
      assert.deepEqual(errors, []);
      await fs.writeFile(path.join(output, 'legacy-guest-regression.json'), JSON.stringify({
        application: base, suite, headless: true, completed: true, isolatedFromPublicPeers: true,
        provenance: seed.provenance || 'captured complete pre-promotion room storage', browserErrors: errors,
      }, null, 2));
      return;
    }
    const contexts = [];
    const profileSizes = explicitSiblingSuite ? [false, false] : personalSurnameSuite ? [false, true]
      : suite === 'guest-identity' ? [false, false, false] : [false, true, true];
    for (const mobile of profileSizes) {
      const context = await browser.newContext({
        permissions: ['clipboard-read', 'clipboard-write'],
        viewport: mobile ? { width: 390, height: 844 } : { width: 1280, height: 900 },
        deviceScaleFactor: mobile ? 2 : 1, isMobile: mobile, hasTouch: mobile,
        serviceWorkers: 'block', reducedMotion: 'reduce',
      });
      contexts.push(context);
      if (tracedPublicFeature) await context.route('**/*', (route) => {
        const request = route.request(), url = new URL(request.url());
        const sameOrigin = url.origin === new URL(base).origin;
        const publicAsset = ['script', 'stylesheet', 'image', 'font'].includes(request.resourceType()) ||
          /(?:canvaskit|fonts\.gstatic|fonts\.googleapis)/i.test(url.href);
        const allowed = sameOrigin || !publicAsset;
        publicSurnameTrace.http.push({ url: url.href, resourceType: request.resourceType(), allowed });
        return allowed ? route.continue() : route.abort('internetdisconnected');
      });
      await context.addInitScript(() => {
        window.__firstFrame = false;
        window.addEventListener('flutter-first-frame', () => { window.__firstFrame = true; }, { once: true });
        window.__channels = [];
        window.__peerConnections = [];
        window.__observedHandshakes = [];
        const track = (channel) => {
          window.__channels.push(channel);
          const send = channel.send.bind(channel);
          channel.send = (data) => {
            if (window.__isolateTreeEdits || channel.__blackhole) return;
            // Observe the production handshake; never add/replace capability bits.
            try {
              const packet = JSON.parse(data);
              if (packet.type === 'hello' || packet.type === 'welcome') {
                window.__observedHandshakes.push({ type: packet.type, actor: packet.actor,
                  familyTree: packet.familyTree, familySurnames: packet.familySurnames,
                  personalSurnames: packet.personalSurnames, explicitSiblings: packet.explicitSiblings });
              }
            } catch (_) { /* Fragment/binary packets are not handshake evidence. */ }
            send(data);
          };
          channel.addEventListener('message', (event) => {
            if (window.__isolateTreeEdits || channel.__blackhole) event.stopImmediatePropagation();
          }, true);
          return channel;
        };
        const Native = window.RTCPeerConnection;
        window.RTCPeerConnection = class extends Native {
          constructor(config, ...args) {
            super({ ...config, iceTransportPolicy: 'relay' }, ...args);
            window.__peerConnections.push(this);
            this.addEventListener('datachannel', (event) => track(event.channel), true);
          }
          createDataChannel(...args) { return track(super.createDataChannel(...args)); }
        };
      });
      const page = await context.newPage();
      page.on('pageerror', (error) => errors.push(error.message));
      if (tracedPublicFeature) {
        page.on('websocket', (socket) => publicSurnameTrace.webSockets.push({ url: socket.url(), publicTransport: true }));
        page.on('console', (message) => {
          publicSurnameTrace.consoleMessages.push({ peer: pages.indexOf(page) + 1, type: message.type(), text: message.text() });
          if (message.type() === 'error' || /(?:EXCEPTION CAUGHT BY|A RenderFlex overflowed|RenderBox was not laid out|Incorrect use of ParentDataWidget|The following (?:assertion|[A-Za-z]+Error|exception) was thrown)/i.test(message.text())) {
            errors.push({ peer: pages.indexOf(page) + 1, type: message.type(), text: message.text() });
          }
        });
      }
      pages.push(page);
    }
    const [a, b, guest] = pages;
    if (explicitSiblingSuite) {
      let deadline;
      try {
        await Promise.race([publicExplicitSiblings(a, b, errors), new Promise((_, reject) => {
          deadline = setTimeout(() => reject(new Error('Finite public explicit-siblings exceeded its 120-second budget; report partial.')), 120000);
        })]);
      } finally { clearTimeout(deadline); }
      return;
    }
    if (personalSurnameSuite) {
      await publicSurnames(a, b, errors);
      return;
    }
    if (suite === 'guest-identity') {
      await publicGuestIdentity(browser, pages, errors);
      return;
    }
    await load(a, base);
    await a.getByRole('button', { name: 'Создать комнату', exact: true }).click();
    await admissionName(a, 'Первый редактор');
    await a.getByRole('button', { name: /Выбрать Без имени/ }).waitFor({ timeout: 60000 });
    assert.equal(await a.getByRole('textbox', { name: /Общее текстовое поле/ }).count(), 0);
    await openBio(a, true);
    await type(a, a.getByRole('textbox', { name: 'Имя', exact: true }), 'Алексей');
    await type(a, a.getByRole('textbox', { name: 'Биография', exact: true }), 'Родился у большой реки.');
    await newRelative(a, 'Отца', 'Николай');
    await newRelative(a, 'Мать', 'Мария');
    await newRelative(a, 'Ребёнка', 'Ольга');
    await a.getByRole('button', { name: /^Открыть фотоальбом/ }).click();
    const chooser = a.waitForEvent('filechooser');
    await a.getByRole('button', { name: 'Загрузить фотографии', exact: true }).click();
    await (await chooser).setFiles({
      name: 'portrait.png', mimeType: 'image/png',
      buffer: await fs.readFile(path.join(__dirname, '..', 'assets', 'tree-mark.png')),
    });
    await a.getByRole('button', { name: 'На аватар', exact: true }).waitFor({ timeout: 30000 });
    await type(a, a.getByRole('textbox', { name: 'Подпись к фотографии', exact: true }), 'Семейный альбом');
    await a.getByRole('button', { name: 'На аватар', exact: true }).click();
    await a.getByRole('button', { name: 'Выбран аватаром', exact: true }).waitFor();
    await a.screenshot({ path: path.join(output, 'photo-album.png') });
    await a.getByRole('button', { name: 'Закрыть альбом', exact: true }).click();
    await a.screenshot({ path: path.join(output, 'desktop-biography.png') });
    await a.getByRole('button', { name: 'Добавить факт', exact: true }).click();
    await type(a, a.getByRole('textbox', { name: 'Факт', exact: true }), 'Любил семейные встречи.');
    await a.getByRole('button', { name: 'Цвет факта', exact: true }).click();
    await a.getByRole('menuitem', { name: 'Цвет 2', exact: true }).click();
    await closeBio(a);
    for (const mode of ['По отцу', 'По матери', 'Обе линии']) {
      await a.getByRole('button', { name: /^Линия дерева:/ }).click();
      const choices = a.getByRole('menuitem');
      await waitUntil(async () => await choices.count() === 3, 'Mode menu did not expose its three choices.');
      await a.getByRole('menuitem', { name: new RegExp(mode) }).click();
      await a.waitForTimeout(300);
    }
    await a.screenshot({ path: path.join(output, 'desktop-tree.png') });
    const editorInvite = await invite(a, 'editor');
    const guestInvite = await invite(a, 'guest');
    console.log('PASS: actual tree replaces demo; biography, parent and child creation persist.');

    await load(b, editorInvite);
    await admissionName(b, 'Второй редактор');
    await b.getByRole('button', { name: /Выбрать Алексей/ }).waitFor({ timeout: 60000 });
    await converged([a, b]);
    await b.mouse.move(0, 0);
    await b.waitForTimeout(1200);
    await b.screenshot({ path: path.join(output, 'mobile-tree.png') });
    await openBio(b, true);
    await type(b, b.getByRole('textbox', { name: 'Биография', exact: true }), 'Жил у большой реки.');
    await closeBio(b);
    await openBio(a, true);
    await a.getByRole('textbox', { name: 'Биография', exact: true }).click();
    await a.getByRole('textbox', { name: 'Биография', exact: true }).focus();
    await waitUntil(async () => (await a.getByRole('textbox', { name: 'Биография', exact: true }).inputValue()) === 'Жил у большой реки.',
      'Biography did not update through the real RTC channel.');
    await converged([a, b]);
    console.log('PASS: mobile portrait generations and actual per-field realtime synchronization.');

    await openBio(b, true);
    const editFieldA = a.getByRole('textbox', { name: 'Биография', exact: true });
    const editFieldB = b.getByRole('textbox', { name: 'Биография', exact: true });
    const commonBase = 'Жил у большой реки.';
    const activeValue = (page) => page.evaluate(() => document.activeElement?.value);
    const focusBiography = async (page, field) => {
      await field.click();
      await field.focus();
      await page.waitForTimeout(150);
      await waitUntil(async () => await activeValue(page) === commonBase,
        'The actual focused biography input did not contain the common base.');
    };
    await focusBiography(a, editFieldA);
    await focusBiography(b, editFieldB);
    await Promise.all([a, b].map((page) => page.evaluate(() => {
      window.__isolateTreeEdits = true;
      for (const channel of window.__channels) channel.__blackhole = true;
    })));
    // Verify real caret/input state before reconnect: convergence alone cannot
    // prove that the browser generated the two intended independent insertions.
    const positionCaret = async (page, field, key, offset) => {
      await focusBiography(page, field);
      await page.keyboard.press(key);
      await waitUntil(() => page.evaluate((target) => {
        const input = document.activeElement;
        return input?.selectionStart === target && input?.selectionEnd === target;
      }, offset), 'The native biography caret did not reach its intended boundary.');
    };
    try {
      await positionCaret(a, editFieldA, 'Control+Home', 0);
      await a.keyboard.type('Слева. ', { delay: 30 });
      await waitUntil(async () => await activeValue(a) === `Слева. ${commonBase}`,
        'The local prefix insertion was not generated correctly.');
      assert.equal(await activeValue(b), commonBase, 'The split leaked an edit before reconnection.');
      await positionCaret(b, editFieldB, 'Control+End', commonBase.length);
      await b.keyboard.type(' Справа.', { delay: 30 });
      await waitUntil(async () => await activeValue(b) === `${commonBase} Справа.`,
        'The local suffix insertion was not generated correctly.');
      assert.equal(await activeValue(a), `Слева. ${commonBase}`, 'The split leaked an edit before reconnection.');
    } finally {
      await fs.writeFile(path.join(output, 'offline-input-checkpoints.json'), JSON.stringify(
        await Promise.all([a, b].map(async (page) => ({
          input: await page.evaluate(() => {
            const input = document.activeElement;
            return { tag: input?.tagName, value: input?.value,
              start: input?.selectionStart, end: input?.selectionEnd,
              channels: window.__channels.map((channel) => ({ state: channel.readyState,
                blackhole: Boolean(channel.__blackhole) })) };
          }),
          history: await history(page),
        }))), null, 2));
    }
    const split = await Promise.all([a, b].map(history));
    assert.notDeepEqual(split[0], split[1]);
    await Promise.all([a, b].map((page) => page.evaluate(() => {
      for (const channel of window.__channels) channel.close();
      window.__isolateTreeEdits = false;
    })));
    await converged([a, b]);
    const expected = 'Слева. Жил у большой реки. Справа.';
    await waitUntil(async () => (await Promise.all([a, b].map((page) => page.evaluate((value) =>
      [...document.querySelectorAll('textarea,input')].some((input) => input.value === value), expected))))
      .every(Boolean), 'Anchored concurrent edits lost one side.');
    for (const records of split) for (const edit of records) {
      assert.ok((await history(a)).some((value) => JSON.stringify(value) === JSON.stringify(edit)), `Lost ${edit.id}.`);
    }
    await b.screenshot({ path: path.join(output, 'mobile-collaborative-biography.png') });
    console.log('PASS: divergent anchored text edits merge without losing either side or immutable records.');
    await closeBio(a);
    await closeBio(b);

    await load(guest, guestInvite);
    await admissionName(guest, 'Гость');
    await guest.getByRole('button', { name: /Выбрать Алексей/ }).waitFor({ timeout: 60000 });
    await openBio(guest);
    assert.equal(await guest.getByRole('button', { name: 'Изменить', exact: true }).count(), 0);
    assert.equal(await guest.getByRole('button', { name: 'Это я', exact: true }).count(), 0);
    assert.doesNotMatch(await body(guest), /Ваш профиль/);
    await closeBio(guest);
    await openBio(a);
    await a.getByRole('button', { name: 'Это я', exact: true }).click();
    assert.match(await body(a), /Связать ваш профиль с/);
    await a.getByRole('button', { name: 'Да, это я', exact: true }).click();
    await waitUntil(async () => !(await body(a)).includes('button "Это я"'), 'Durable editor binding did not hide its button.');
    await closeBio(a);
    await openBio(b);
    await b.getByRole('button', { name: 'Это я', exact: true }).click();
    await b.getByRole('button', { name: 'Да, это я', exact: true }).click();
    await closeBio(b);
    await converged(pages);
    await a.getByRole('button', { name: 'Участники: 1 других онлайн', exact: true }).waitFor({ timeout: 30000 });
    console.log('PASS: guest reads without identity/editor commands; two bound editor devices group separately from the guest.');

    // Delete an unbound child, not the shared bound root used by the rest of
    // this collaboration flow. No storage or network hooks implement deletion.
    const beforeDeletion = await history(a);
    const childCreation = beforeDeletion.filter((record) => record.kind === 'tree')
      .map((record) => JSON.parse(record.text)).find((operation) => operation.type === 'createPerson' && operation.name === 'Ольга');
    assert.ok(childCreation, 'The UI-created unbound child is missing from the actual journal.');
    await a.getByRole('button', { name: 'Выбрать Ольга', exact: true }).click();
    await openBio(a);
    assert.equal(await a.getByRole('button', { name: 'Удалить человека', exact: true }).count(), 0,
      'Person deletion must not be offered in biography read mode.');
    await a.getByRole('button', { name: 'Изменить', exact: true }).click();
    const removePerson = a.getByRole('button', { name: 'Удалить человека', exact: true });
    await revealBiographyAction(a, removePerson);
    await removePerson.click();
    const confirmation = a.getByRole('alertdialog');
    await confirmation.getByText('Удалить человека?', { exact: true }).waitFor();
    assert.match(await body(a), /Другие люди останутся в дереве/);
    await confirmation.getByRole('button', { name: 'Отмена', exact: true }).click();
    assert.deepEqual(await history(a), beforeDeletion, 'Cancelling deletion appended an immutable operation.');
    await removePerson.click();
    await confirmation.getByRole('button', { name: 'Удалить', exact: true }).click();
    await a.getByRole('button', { name: 'Закрыть биографию', exact: true }).waitFor({ state: 'hidden' });
    await converged(pages);
    const afterDeletion = await history(a);
    const appended = afterDeletion.filter((record) => !beforeDeletion.some((old) => old.id === record.id));
    assert.equal(appended.length, 1, 'Deleting a person should append one pure tombstone operation.');
    assert.deepEqual(JSON.parse(appended[0].text), { type: 'deletePerson', personId: childCreation.personId });
    for (const record of beforeDeletion) {
      assert.deepEqual(afterDeletion.find((entry) => entry.id === record.id), record, `Deletion removed or changed history ${record.id}.`);
    }
    for (const page of pages) {
      await waitUntil(async () => await page.getByRole('button', { name: 'Выбрать Ольга', exact: true }).count() === 0,
        'Deleted child remained projected on an independent client.');
      for (const survivor of ['Алексей', 'Николай', 'Мария']) {
        assert.equal(await page.getByRole('button', { name: `Выбрать ${survivor}`, exact: true }).count(), 1,
          `Deleting the child removed surviving ${survivor}.`);
      }
    }
    await a.screenshot({ path: path.join(output, 'desktop-deleted-child.png') });
    await guest.screenshot({ path: path.join(output, 'guest-deleted-child.png') });
    await guest.reload({ waitUntil: 'domcontentloaded' });
    await activate(guest);
    await guest.getByRole('button', { name: 'Выбрать Алексей', exact: true }).waitFor({ timeout: 60000 });
    await converged(pages);
    assert.equal(await guest.getByRole('button', { name: 'Выбрать Ольга', exact: true }).count(), 0);
    assert.deepEqual(await history(guest), afterDeletion, 'Guest reload did not retain the complete tombstoned history.');
    console.log('PASS: cancelled/confirmed deletion of unbound child synchronizes to three independent clients; immutable history and guest reload preserve the tombstone.');

    await b.reload({ waitUntil: 'domcontentloaded' });
    await activate(b);
    await b.getByRole('button', { name: /Выбрать Алексей/ }).waitFor({ timeout: 60000 });
    await converged(pages);
    await openBio(b, true);
    assert.equal(await b.getByRole('button', { name: 'Это я', exact: true }).count(), 0);
    await b.getByRole('textbox', { name: 'Биография', exact: true }).click();
    await b.getByRole('textbox', { name: 'Биография', exact: true }).focus();
    await b.waitForFunction((value) => [...document.querySelectorAll('textarea,input')]
      .some((input) => input.value === value), expected, { timeout: 10000 });
    const bounds = await b.evaluate(() => [innerWidth, document.documentElement.scrollWidth]);
    assert.deepEqual(bounds, [390, 390]);
    assert.equal(await b.getByRole('button', { name: 'Выбрать Ольга', exact: true }).count(), 0);
    assert.deepEqual(await history(b), afterDeletion, 'Editor reload resurrected the deleted person or lost immutable history.');
    assert.deepEqual(errors, []);
    await fs.writeFile(path.join(output, 'public-converged-journal.json'), JSON.stringify(afterDeletion, null, 2));
    await fs.writeFile(path.join(output, 'public-ui-regression.json'), JSON.stringify({
      application: base, headless: true, completed: true, independentClients: pages.length,
      deleted: JSON.parse(appended[0].text), cancelledDeletionUnchanged: true,
      immutableHistoryPreserved: true, editorAndGuestReloadVerified: true,
      completeConvergedJournalLength: afterDeletion.length, browserErrors: errors,
    }, null, 2));
    console.log('PASS: tree, complete history and durable binding survive reload; no browser errors.');
    console.log('Browser errors:', JSON.stringify(errors));
  } catch (error) {
    console.error(error.stack);
    const diagnostics = [];
    for (const [index, page] of pages.entries()) {
      if (page.isClosed()) continue;
      const semantics = await body(page).catch(() => 'unavailable');
      console.error(`Page ${index + 1}:`, semantics);
      diagnostics.push({ page: index + 1, url: page.url(), semantics,
        ...(suite === 'initial-sync-recovery' ? { consoleErrors: page.__initialSyncConsoleErrors || [] } : {}),
        completeJournal: await history(page).catch(() => null), storage: await storedRoom(page).catch(() => null),
        network: await page.evaluate(() => ({
        peers: (window.__peerConnections || []).map((peer) => ({
          connection: peer.connectionState, ice: peer.iceConnectionState,
          gathering: peer.iceGatheringState, signaling: peer.signalingState,
          candidateTypes: (peer.localDescription?.sdp || '').split('\n').filter((line) => line.startsWith('a=candidate:'))
            .map((line) => line.match(/ typ (\w+)/)?.[1]),
        })),
        channels: (window.__channels || []).map((channel) => ({ state: channel.readyState, blackhole: Boolean(channel.__blackhole) })),
        initialSyncRecovery: window.__initialSyncCheck ? { armed: window.__initialSyncCheck.armed,
          cut: window.__initialSyncCheck.cut, holdAck: window.__initialSyncCheck.holdAck,
          overflow: window.__initialSyncCheck.overflow, trace: window.__initialSyncCheck.trace } : undefined,
      })).catch(() => null) });
      await page.screenshot({ path: path.join(output, `failure-${index + 1}.png`) }).catch(() => {});
    }
    const failureReport = explicitSiblingSuite ? 'explicit-siblings-public.json'
      : suite === 'initial-sync-recovery' ? 'initial-sync-recovery.json'
      : suite === 'author-history' ? 'author-history-public.json'
      : suite === 'author-history-local' ? 'author-history-local.json'
        : suite === 'guest-identity-legacy' ? 'legacy-guest-regression.json'
          : suite === 'identity-local' ? 'identity-local.json'
            : ['identity-actions-local', 'dialogs-local'].includes(suite) ? `${suite}.json` : 'public-ui-regression.json';
    await fs.writeFile(path.join(output, failureReport), JSON.stringify({
      application: base, suite, headless: true, completed: false, failure: error.stack, diagnostics, browserErrors: errors,
      ...(tracedPublicFeature ? { trace: publicSurnameTrace } : {}),
      ...(explicitSiblingSuite ? { preparedScenarioEvidence: publicSiblingReport } : {}),
    }, null, 2));
    console.error('Browser errors:', JSON.stringify(errors));
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})().catch((error) => { console.error(error.stack); process.exitCode = 1; });
