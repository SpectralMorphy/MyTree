// Usage: node tool/check_patronymics.cjs <playwright-module> <base-url> <new-artifacts-directory> [local|rtc]
// Headless production UI, actual storage, and optional real production RTC.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const [moduleName, base, outputName, mode = 'local'] = process.argv.slice(2);
assert.ok(moduleName && base && outputName, 'Pass Playwright, URL and a fresh artifacts directory.');
assert.ok(['local', 'rtc'].includes(mode));
const { chromium } = require(moduleName);
const output = path.resolve(outputName);
const origin = new URL(base).origin;
const report = { mode, headless: true, completed: false, steps: [], bundles: [], errors: [], providerErrors: [], rtc: [], packets: [] };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const body = async (page) => `${await page.locator('body').ariaSnapshot()}\n${
  (await page.getByRole('textbox').evaluateAll((elements) => elements.map((element) =>
    element.value ?? element.getAttribute('aria-valuetext') ?? ''))).join('\n')}`;
const hash = (value) => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const encode = (value) => Buffer.from(value).toString('base64url');
const room = crypto.randomBytes(16).toString('hex');
const actors = [crypto.randomBytes(16).toString('hex'), crypto.randomBytes(16).toString('hex')];
const prefix = 'mytree.room-store.v1.';
const roomPrefix = `${prefix}room.${encode(room)}.`;
const records = [];
function add(kind, text, author = 'fixture', extra = {}) {
  const n = records.length + 1;
  records.push({ id: `patronymic-fixture-${n}`, author, clock: Date.UTC(2026, 9, 1) + n,
    createdAt: Date.UTC(2026, 9, 1), kind, text, ...extra });
}
const op = (value) => add('tree', JSON.stringify(value));
const value = (personId, field, value) => op({ type: 'setValue', personId, field, value });
for (const [index, actor] of actors.entries()) {
  add('participantName', `Проверка ${index + 1}`, actor);
  add('participantRole', 'editor', 'fixture', { targetActor: actor });
}
add('roomName', 'Проверка отчеств');
op({ type: 'createPerson', personId: 'father', name: 'Илья', sex: 'male' });
op({ type: 'setSurname', personId: 'father', scope: 'individual', familyKey: null, text: 'Иванов', decline: true });
op({ type: 'createPerson', personId: 'anna', name: 'Анна', sex: 'female' });
value('anna', 'fatherId', 'father');
let left = null;
op({ type: 'editText', personId: 'root', field: 'name', itemId: null,
  inserts: [...'Алексей'].map((text, i) => {
    const atom = { id: `patronymic-name-${i}`, text, left, right: null };
    left = atom.id; return atom;
  }), deletes: [] });
value('root', 'sex', 'male');
value('root', 'fatherId', 'father');

async function until(check, message, timeout = 45000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { if (await check()) return; await sleep(150); }
  throw new Error(message);
}
async function history(page) {
  return page.evaluate((prefix) => Object.keys(localStorage).filter((key) => key.startsWith(`${prefix}operation.`))
    .map((key) => JSON.parse(localStorage.getItem(key))).sort((a, b) => a.id.localeCompare(b.id)), roomPrefix);
}
function validateJournal(journal) {
  for (const original of records) assert.deepEqual(journal.find((edit) => edit.id === original.id), original);
  for (const author of new Set(journal.map((edit) => edit.author))) {
    const entries = journal.filter((edit) => edit.author === author);
    const sealed = entries.filter((edit) => edit.authorSequence != null).sort((a, b) => a.authorSequence - b.authorSequence);
    if (!sealed.length) continue;
    assert.deepEqual(sealed[0].authorBase, entries.filter((edit) => edit.authorSequence == null).map((edit) => edit.id).sort());
    for (const [index, edit] of sealed.entries()) {
      assert.equal(edit.authorSequence, index + 1);
      assert.equal(edit.authorPrevious, index ? sealed[index - 1].id : null);
    }
  }
}
async function settled(page) { await page.mouse.move(1, 1); await sleep(350); }
async function revealBiography(page, target) {
  for (let attempt = 0; attempt < 16; attempt++) {
    const box = await target.boundingBox().catch(() => null);
    if (box && box.y >= 150 && box.y + box.height < page.viewportSize().height - 12) return;
    await page.mouse.move(page.viewportSize().width - 40, page.viewportSize().height * .65);
    await page.mouse.wheel(0, 250);
    await sleep(160);
  }
  throw new Error('Biography action was not revealed through actual wheel scrolling.');
}
async function load(page) {
  const bundle = page.waitForResponse((response) => response.url() === new URL('main.dart.js', base).href && response.status() === 200);
  await page.goto(base, { waitUntil: 'domcontentloaded' });
  const response = await bundle;
  const bundleIdentity = { sha256: crypto.createHash('sha256').update(await response.body()).digest('hex'), serviceWorker: response.fromServiceWorker() };
  report.bundles.push(bundleIdentity);
  assert.equal(bundleIdentity.serviceWorker, false);
  if (process.env.MYTREE_EXPECTED_BUNDLE_SHA256) assert.equal(bundleIdentity.sha256, process.env.MYTREE_EXPECTED_BUNDLE_SHA256);
  await page.waitForFunction(() => window.__patronymicFrame);
  const marker = page.locator('flt-semantics-placeholder');
  for (let i = 0; i < 5 && await marker.count(); i++) {
    await marker.evaluate((element) => Object.assign(element.style, { position: 'fixed', left: '0px', top: '0px',
      width: '2px', height: '2px', transform: 'none', zIndex: '2147483647' }));
    await marker.click({ force: true }); await sleep(150);
  }
  await until(async () => {
    if (await page.getByRole('button', { name: 'Выбрать Алексей', exact: true }).count()) return true;
    if (mode === 'local') {
      const local = page.getByRole('button', { name: 'Открыть локальную копию', exact: true });
      if (await local.isVisible().catch(() => false)) await local.click();
    }
    return false;
  }, 'The actual room entry gate did not open.', 50000);
  await settled(page);
}
async function type(page, field, text) {
  await field.click(); await field.focus(); await sleep(150);
  await until(() => page.evaluate(() => {
    const input = document.activeElement;
    return input instanceof HTMLInputElement || input instanceof HTMLTextAreaElement;
  }), 'The field did not acquire actual native focus.', 5000);
  await page.keyboard.press('Control+A');
  await until(() => page.evaluate(() => {
    const input = document.activeElement;
    return input?.selectionStart === 0 && input?.selectionEnd === input?.value?.length;
  }), 'The actual native input did not select its previous value.', 5000);
  if (text) await page.keyboard.type(text, { delay: 20 }); else await page.keyboard.press('Backspace');
  await until(() => page.evaluate((text) => document.activeElement?.value === text, text), 'Native input differs from typed text.', 5000);
}
async function search(page, query, expected) {
  // The hint ceases to be the accessible name once Flutter has a query.
  // This helper runs only on the normal/picker canvas, with one search input.
  const field = page.getByRole('textbox').first();
  await type(page, field, query);
  await until(async () => (await body(page)).includes(expected), `Missing FIO result: ${expected}`);
  assert.equal(await page.getByRole('button', { name: new RegExp(`^${expected}`) }).count(), 1);
}
async function dismissSearch(page) { await page.keyboard.press('Escape'); await settled(page); }
async function nameMode(page, label) {
  await page.getByRole('button', { name: /Формат имени/ }).click();
  await page.getByRole('menuitem', { name: new RegExp(`(?:^| )${label}$`) }).click();
  await settled(page);
}
async function dictionary(page) {
  await page.getByRole('button', { name: /^Меню комнаты(?: |$)/ }).click();
  await page.getByRole('menuitem', { name: 'Словарь отчеств', exact: true }).waitFor();
  await until(async () => {
    const snapshot = await body(page);
    return snapshot.includes('Настройки комнаты') && snapshot.includes('Словарь отчеств');
  }, 'Room menu did not finish opening.');
  const menu = await body(page);
  assert.ok(menu.indexOf('Настройки комнаты') < menu.indexOf('Словарь отчеств'));
  await page.getByRole('menuitem', { name: 'Словарь отчеств', exact: true }).click();
}
async function addOverride(page) {
  await dictionary(page);
  await page.getByRole('button', { name: 'Добавить', exact: true }).click();
  await type(page, page.getByRole('textbox', { name: /^Имя отца(?: |$)/ }), 'Илья');
  await type(page, page.getByRole('textbox', { name: /^Мужское отчество(?: |$)/ }), 'Илиевич');
  await type(page, page.getByRole('textbox', { name: /^Женское отчество(?: |$)/ }), 'Илиевна');
  await capture(page, 'dictionary-edit-forms');
  await page.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await page.getByRole('button', { name: 'Закрыть', exact: true }).waitFor();
  await page.getByRole('button', { name: 'Закрыть', exact: true }).click();
}
async function resetOverride(page) {
  await dictionary(page);
  await until(async () => {
    const entry = page.getByText(/^Илья\s+Илиевич\s*\/\s*Илиевна$/)
      .or(page.locator('[aria-label^="Илья"][aria-label*="Илиевич"][aria-label*="Илиевна"]')).first();
    if (await entry.isVisible().catch(() => false)) { await entry.click(); return true; }
    await page.mouse.move(page.viewportSize().width / 2, page.viewportSize().height / 2);
    await page.mouse.wheel(0, 250); return false;
  }, 'Dictionary entry did not become visible.', 8000);
  await page.getByRole('button', { name: 'Сбросить запись комнаты', exact: true }).click();
  await page.getByRole('button', { name: 'Закрыть', exact: true }).click();
}
async function converge(pages) {
  if (mode !== 'rtc') return;
  await until(async () => {
    const journals = await Promise.all(pages.map(history));
    return journals.every((journal) => JSON.stringify(journal) === JSON.stringify(journals[0]));
  }, 'Independent real RTC journals did not converge.');
}
async function capture(page, name) {
  // Moving a synthetic mouse on a touch profile can blur its native editor.
  // Keep the real search focus intact while retaining the painted result.
  await sleep(200);
  await fs.writeFile(path.join(output, `${name}.txt`), await body(page));
  await page.screenshot({ path: path.join(output, `${name}.png`) });
  assert.doesNotMatch(await body(page), /Не сохранено:|Не удалось прочитать локальные данные|Не удалось загрузить историю/);
  assert.deepEqual(report.errors, []);
  report.steps.push(name);
}

(async () => {
  await fs.mkdir(output, { recursive: false });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const contexts = [], pages = [];
  const watchdog = setTimeout(() => { report.errors.push('180-second browser deadline'); void browser.close(); }, 180000);
  try {
    for (let index = 0; index < 2; index++) {
      const context = await browser.newContext({ viewport: index ? { width: 390, height: 844 } : { width: 1440, height: 1000 },
        deviceScaleFactor: 1, isMobile: index === 1, hasTouch: index === 1 });
      contexts.push(context);
      await context.route('**/*', (route) => {
        const url = new URL(route.request().url());
        return url.origin === origin || (mode === 'rtc' && route.request().resourceType() !== 'font')
          ? route.continue() : route.abort();
      });
      if (mode === 'local') await context.routeWebSocket('**/*', (socket) => socket.close());
      const entries = [[`${prefix}client-id`, JSON.stringify(actors[index])], [`${prefix}last-room`, JSON.stringify(room)],
        [`${roomPrefix}membership`, JSON.stringify(room)], ...records.map((record) =>
          [`${roomPrefix}operation.${encode(record.id)}`, JSON.stringify(record)])];
      await context.addInitScript(({ entries, origin }) => {
        window.addEventListener('flutter-first-frame', () => { window.__patronymicFrame = true; }, { once: true });
        if (location.origin === origin && !localStorage.getItem('patronymic-fixture-seeded')) {
          for (const [key, value] of entries) localStorage.setItem(key, value);
          localStorage.setItem('patronymic-fixture-seeded', 'true');
        }
        window.__patronymicPackets = [];
        window.__patronymicPeers = [];
        const observe = (channel) => {
          const record = (data, direction) => {
            if (typeof data !== 'string') return;
            try {
              const packet = JSON.parse(data);
              if (['hello', 'welcome'].includes(packet.type)) window.__patronymicPackets.push({ type: packet.type,
                direction, patronymics: packet.patronymics, explicitSiblings: packet.explicitSiblings,
                personalSurnames: packet.personalSurnames });
            } catch {}
          };
          channel.addEventListener('message', (event) => record(event.data, 'in'));
          const send = channel.send.bind(channel);
          channel.send = (data) => { record(data, 'out'); return send(data); };
        };
        const Native = window.RTCPeerConnection;
        window.RTCPeerConnection = class extends Native {
          constructor(...args) { super(...args); window.__patronymicPeers.push(this);
            this.addEventListener('datachannel', (event) => observe(event.channel)); }
          createDataChannel(...args) { const channel = super.createDataChannel(...args); observe(channel); return channel; }
        };
      }, { entries, origin });
      const page = await context.newPage(); pages.push(page);
      page.on('pageerror', (error) => report.errors.push(`profile ${index}: ${error.message}`));
      page.on('console', (message) => {
        const text = message.text();
        if (/^WebSocket connection to 'wss:\/\/(?:0\.peerjs\.com|test\.mosquitto\.org)(?::\d+)?[/]/.test(text)) {
          // Keep provider outages distinct from Flutter errors. Production
          // fallback still has to establish an actual channel and convergence.
          report.providerErrors.push(`profile ${index}: ${text.replace(/wss:\/\/[^']+/g, (address) => {
            const url = new URL(address); return `${url.origin}${url.pathname}`;
          })}`);
        } else if (message.type() === 'error' || /EXCEPTION CAUGHT|RenderFlex overflowed|Another exception was thrown/.test(text)) {
          report.errors.push(`profile ${index}: ${text}`);
        }
      });
    }
    await Promise.all(pages.map(load));
    if (mode === 'rtc') {
      await converge(pages);
      await until(async () => {
        const packets = await Promise.all(pages.map((page) => page.evaluate(() => window.__patronymicPackets)));
        return packets.every((list) => list.some((packet) => packet.type === 'hello') && list.some((packet) => packet.type === 'welcome'));
      }, 'No actual production hello/welcome.');
      for (const page of pages) {
        const packets = await page.evaluate(() => window.__patronymicPackets);
        assert.ok(packets.every((packet) => packet.patronymics === true &&
          packet.explicitSiblings === true && packet.personalSurnames === true));
        assert.ok(await page.evaluate(() => window.__patronymicPeers.some((peer) => peer.connectionState === 'connected')),
          'No actual connected native RTCPeerConnection.');
        report.packets.push(packets);
      }
    }
    const before = await Promise.all(pages.map(history));
    for (const [index, page] of pages.entries()) {
      await search(page, 'Ильич', 'Иванов Алексей Ильич');
      await capture(page, `profile-${index}-search-always-fio`);
      await dismissSearch(page);
      await nameMode(page, 'ФИО');
      await page.getByRole('button', { name: 'Биография', exact: true }).click();
      await until(async () => (await body(page)).includes('Иванова Анна Ильинична'), 'FIO biography relatives did not update.');
      assert.equal(await page.getByRole('textbox', { name: /Отчество/ }).count(), 0);
      await capture(page, `profile-${index}-fio-biography`);
      await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).click();
      assert.deepEqual(await history(page), before[index], 'Presentation/search wrote history.');
    }
    // The second search is on the genuine existing-relative picker route.
    await pages[0].getByRole('button', { name: 'Биография', exact: true }).click();
    await pages[0].getByRole('button', { name: 'Изменить', exact: true }).click();
    const addRelative = pages[0].getByRole('button', { name: 'Добавить родственника', exact: true });
    await revealBiography(pages[0], addRelative);
    await addRelative.click();
    await pages[0].getByRole('checkbox', { name: 'Из дерева', exact: true }).click();
    await pages[0].getByRole('button', { name: 'Выбрать', exact: true }).click();
    await nameMode(pages[0], 'ИФ');
    await search(pages[0], 'Ильич', 'Иванов Алексей Ильич');
    await capture(pages[0], 'picker-search-always-fio');
    await dismissSearch(pages[0]);
    await pages[0].getByRole('button', { name: 'Отмена выбора', exact: true }).click();
    await pages[0].getByRole('button', { name: 'Отмена', exact: true }).click();
    await pages[0].getByRole('button', { name: 'Закрыть биографию', exact: true }).click();
    assert.deepEqual(await history(pages[0]), before[0], 'Picker browsing/cancellation wrote history.');
    await addOverride(pages[0]);
    await converge(pages);
    const affected = mode === 'rtc' ? pages : [pages[0]];
    for (const [index, page] of affected.entries()) {
      await search(page, 'Илиевич', 'Иванов Алексей Илиевич');
      await dismissSearch(page);
      await search(page, 'Илиевна', 'Иванова Анна Илиевна');
      await capture(page, `profile-${index}-room-override`);
      await dismissSearch(page);
    }
    const afterOverride = await history(pages[0]); validateJournal(afterOverride);
    const dictionaryEdits = afterOverride.filter((edit) => edit.kind === 'tree' && JSON.parse(edit.text).type === 'setPatronymicOverride');
    assert.equal(dictionaryEdits.length, 1);
    assert.deepEqual(JSON.parse(dictionaryEdits[0].text), { type: 'setPatronymicOverride', name: 'илья', male: 'Илиевич', female: 'Илиевна' });
    await resetOverride(pages[0]); await converge(pages);
    await search(pages[0], 'Ильич', 'Иванов Алексей Ильич'); await dismissSearch(pages[0]);
    const final = await Promise.all(pages.map(history)); final.forEach(validateJournal);
    await Promise.all(pages.map(load));
    for (let index = 0; index < pages.length; index++) {
      assert.deepEqual(await history(pages[index]), final[index], 'Reload changed complete immutable history.');
      await search(pages[index], 'Ильич', 'Иванов Алексей Ильич');
      await capture(pages[index], `profile-${index}-durable-reload`);
      report.packets.push(await pages[index].evaluate(() => window.__patronymicPackets));
      report.rtc.push(await pages[index].evaluate(async () => Promise.all(window.__patronymicPeers.map(async (peer) => {
        const stats = await peer.getStats();
        const pairs = [...stats.values()].filter((entry) => entry.type === 'candidate-pair' && entry.state === 'succeeded' && entry.nominated);
        return { connectionState: peer.connectionState, pairs: pairs.map((entry) => ({
          local: stats.get(entry.localCandidateId)?.candidateType,
          remote: stats.get(entry.remoteCandidateId)?.candidateType,
          bytesSent: entry.bytesSent, bytesReceived: entry.bytesReceived,
        })) };
      }))));
    }
    report.journals = final.map((journal) => ({ records: journal.length, sha256: hash(journal) }));
    await fs.writeFile(path.join(output, 'synthetic-journals.json'), JSON.stringify(final, null, 2));
    report.completed = true;
  } catch (error) {
    report.failure = error.stack;
    for (const [index, page] of pages.entries()) if (!page.isClosed()) {
      await page.screenshot({ path: path.join(output, `failure-${index}.png`) }).catch(() => {});
      await fs.writeFile(path.join(output, `failure-${index}.txt`), await body(page).catch(() => '')).catch(() => {});
      await fs.writeFile(path.join(output, `failure-${index}-journal.json`), JSON.stringify(await history(page).catch(() => []), null, 2)).catch(() => {});
    }
    process.exitCode = 1;
  } finally {
    clearTimeout(watchdog);
    await fs.writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
    await browser.close();
    console.log(JSON.stringify({ mode, completed: report.completed, steps: report.steps, errors: report.errors, providerErrors: report.providerErrors, failure: report.failure }));
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
