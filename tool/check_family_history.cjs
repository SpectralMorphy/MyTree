// Usage: node tool/check_family_history.cjs <playwright-module> <base-url> <new-artifacts-directory> [local|rtc]
// Real headless production UI and immutable storage; rtc retains production transports.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const [moduleName, base, directory, mode = 'local'] = process.argv.slice(2);
assert.ok(moduleName && base && directory);
assert.ok(['local', 'rtc'].includes(mode));
const { chromium } = require(moduleName);
const output = path.resolve(directory), origin = new URL(base).origin;
const report = { mode, headless: true, completed: false, steps: [], bundles: [], errors: [], providerErrors: [], handshakes: [], rtc: [] };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const hash = (value) => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const encode = (text) => Buffer.from(text).toString('base64url');
const room = crypto.randomBytes(16).toString('hex');
const actors = [crypto.randomBytes(16).toString('hex'), crypto.randomBytes(16).toString('hex')];
const prefix = 'mytree.room-store.v1.', roomPrefix = `${prefix}room.${encode(room)}.`;
const baseline = [];
function add(kind, text, author = 'fixture', extra = {}) {
  const n = baseline.length + 1;
  baseline.push({ id: `family-fixture-${n}`, author, clock: Date.UTC(2026, 9, 1) + n,
    createdAt: Date.UTC(2026, 9, 1), kind, text, ...extra });
}
const operation = (value) => add('tree', JSON.stringify(value));
const value = (personId, field, value) => operation({ type: 'setValue', personId, field, value });
const surname = (personId, text) => operation({ type: 'setSurname', personId, scope: 'individual', familyKey: null, text, decline: true });
for (const [index, actor] of actors.entries()) {
  add('participantName', `История ${index + 1}`, actor);
  add('participantRole', 'editor', 'fixture', { targetActor: actor });
}
add('roomName', 'История фамилий');
let left = null;
operation({ type: 'editText', personId: 'root', field: 'name', itemId: null, inserts: [...'Анна'].map((text, index) => {
  const atom = { id: `family-name-${index}`, text, left, right: null }; left = atom.id; return atom;
}), deletes: [] });
value('root', 'sex', 'female'); value('root', 'alive', true); surname('root', 'Смирнов');
operation({ type: 'createPerson', personId: 'father', name: 'Пётр', sex: 'male' });
value('root', 'fatherId', 'father');
for (const [id, name, last] of [['ivan', 'Иван', 'Иванов'], ['oleg', 'Олег', 'Петров']]) {
  operation({ type: 'createPerson', personId: id, name, sex: 'male' });
  surname(id, last); value(id, 'alive', true);
}
operation({ type: 'createPerson', personId: 'child', name: 'Алексей', sex: 'male' });
value('child', 'fatherId', 'ivan'); value('child', 'motherId', 'root'); value('child', 'birthDate', '2000-01-01');

async function until(check, message, timeout = 30000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { if (await check()) return; await sleep(120); }
  throw new Error(message);
}
async function snapshot(page) {
  return `${await page.locator('body').ariaSnapshot()}\n${(await page.getByRole('textbox')
    .evaluateAll((elements) => elements.map((element) => element.value ?? ''))).join('\n')}`;
}
const history = (page) => page.evaluate((prefix) => Object.keys(localStorage)
  .filter((key) => key.startsWith(`${prefix}operation.`)).map((key) => JSON.parse(localStorage.getItem(key)))
  .sort((a, b) => a.id.localeCompare(b.id)), roomPrefix);
function verifyJournal(journal) {
  for (const record of baseline) assert.deepEqual(journal.find((entry) => entry.id === record.id), record);
  for (const author of new Set(journal.map((record) => record.author))) {
    const records = journal.filter((record) => record.author === author);
    const proven = records.filter((record) => record.authorSequence != null).sort((a, b) => a.authorSequence - b.authorSequence);
    if (!proven.length) continue;
    assert.deepEqual(proven[0].authorBase, records.filter((record) => record.authorSequence == null).map((record) => record.id).sort());
    for (const [index, record] of proven.entries()) {
      assert.equal(record.authorSequence, index + 1);
      assert.equal(record.authorPrevious, index ? proven[index - 1].id : null);
    }
  }
}
async function type(page, field, text) {
  await field.click(); await field.focus(); await sleep(150);
  await until(() => page.evaluate(() => document.activeElement instanceof HTMLInputElement ||
    document.activeElement instanceof HTMLTextAreaElement), 'No native text editor.', 5000);
  await page.keyboard.press('Control+A');
  await until(() => page.evaluate(() => document.activeElement?.selectionStart === 0 &&
    document.activeElement?.selectionEnd === document.activeElement?.value?.length), 'Native input was not selected.', 5000);
  if (text) await page.keyboard.type(text, { delay: 20 }); else await page.keyboard.press('Backspace');
  await until(() => page.evaluate((text) => document.activeElement?.value === text, text), 'Actual text input differs from draft.', 5000);
}
async function capture(page, name) {
  await sleep(200);
  await fs.writeFile(path.join(output, `${name}.txt`), await snapshot(page));
  await page.screenshot({ path: path.join(output, `${name}.png`) });
  assert.deepEqual(report.errors, []);
  report.steps.push(name);
}
async function reveal(page, target, { x = page.viewportSize().width - 35, y = page.viewportSize().height * .65, section = false } = {}) {
  for (let attempt = 0; attempt < 20; attempt++) {
    const box = await target.count() ? await target.boundingBox({ timeout: 1000 }).catch(() => null) : null;
    if (box && box.y >= 65 && (section ? box.y < page.viewportSize().height - 100 : box.y + box.height < page.viewportSize().height - 12)) return;
    await page.mouse.move(x, y); await page.mouse.wheel(0, box && box.y < 65 ? -260 : 260); await sleep(150);
  }
  throw new Error('The actual scroll view did not reveal the requested action.');
}
async function load(page) {
  const response = page.waitForResponse((response) => response.url() === new URL('main.dart.js', base).href && response.status() === 200);
  await page.goto(base, { waitUntil: 'domcontentloaded' });
  const bundle = await response;
  const identity = { sha256: crypto.createHash('sha256').update(await bundle.body()).digest('hex'), serviceWorker: bundle.fromServiceWorker() };
  report.bundles.push(identity);
  assert.equal(identity.serviceWorker, false);
  assert.equal(identity.sha256, process.env.MYTREE_EXPECTED_BUNDLE_SHA256);
  await page.waitForFunction(() => window.__familyFrame);
  const marker = page.locator('flt-semantics-placeholder');
  for (let i = 0; i < 5 && await marker.count(); i++) {
    await marker.evaluate((element) => Object.assign(element.style, { position: 'fixed', left: '0px', top: '0px', width: '2px',
      height: '2px', transform: 'none', zIndex: '2147483647' }));
    await marker.click({ force: true }); await sleep(150);
  }
  await until(async () => {
    if (await page.getByRole('button', { name: 'Выбрать Анна', exact: true }).count()) return true;
    if (mode === 'local') {
      const local = page.getByRole('button', { name: 'Открыть локальную копию', exact: true });
      if (await local.isVisible().catch(() => false)) await local.click();
    }
    return false;
  }, 'Production entry did not open.', 50000);
  verifyJournal(await history(page));
}
async function search(page, text, expected, choose = false) {
  await type(page, page.getByRole('textbox').first(), text);
  const option = page.getByRole('button', { name: new RegExp(`^${expected}(?:,|$)`) });
  await option.waitFor();
  if (choose) { await option.click(); await sleep(300); }
  else { await page.keyboard.press('Escape'); await sleep(150); }
}
async function openBiography(page, edit = false) {
  await page.getByRole('button', { name: 'Биография', exact: true }).click();
  await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).waitFor();
  if (edit) await page.getByRole('button', { name: 'Изменить', exact: true }).click();
}
async function closeBiography(page) {
  await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).click(); await sleep(250);
}
async function addHistory(page, kind) {
  const button = page.getByRole('button', { name: kind, exact: true });
  await reveal(page, button); await button.click();
  await page.getByRole('alertdialog').waitFor();
}
async function date(page, label, input) {
  await page.getByRole('button', { name: new RegExp(`^${label}(?: |$)`) }).click();
  const toggle = page.getByRole('button', { name: /Switch to input|Enter date|Ввести дату|Ввод даты/i });
  await toggle.click();
  await type(page, page.getByRole('dialog').getByRole('textbox').first(), input);
  await page.getByRole('button', { name: /^(OK|ОК)$/ }).click();
}
async function existingMarriage(page, query, fullName, start, lifelong = false) {
  const before = await history(page);
  await addHistory(page, 'Брак');
  await page.getByRole('checkbox', { name: 'Из дерева', exact: true }).click();
  await page.getByRole('button', { name: 'Выбрать', exact: true }).click();
  await search(page, query, fullName, true);
  await page.getByRole('button', { name: 'Подтвердить выбор', exact: true }).click();
  assert.deepEqual(await history(page), before, 'Picking a spouse wrote history before Add.');
  assert.equal(await page.getByRole('checkbox', { name: 'Менять фамилию', exact: true }).isChecked(), true);
  await date(page, 'Дата начала', start);
  if (lifelong) {
    await page.getByRole('button', { name: /^Окончание брака/ }).click();
    await page.getByRole('menuitem', { name: 'Пожизненно', exact: true }).click();
  }
  await page.getByRole('button', { name: 'Добавить', exact: true }).click();
  await page.getByRole('alertdialog').waitFor({ state: 'hidden' });
}
async function deleteEntry(page, index, cancel = false) {
  const action = page.getByRole('button', { name: /^Удалить запись(?: Удалить запись)?$/ }).nth(index);
  await reveal(page, action); await action.click();
  await page.getByRole('button', { name: cancel ? 'Отмена' : 'Удалить', exact: true }).click();
  await page.getByRole('alertdialog').waitFor({ state: 'hidden' });
}
async function converge(pages) {
  if (mode !== 'rtc') return;
  await until(async () => {
    const values = await Promise.all(pages.map(history));
    return JSON.stringify(values[0]) === JSON.stringify(values[1]);
  }, 'The complete immutable journals did not converge over real RTC.');
}
async function currentName(pages, surname) {
  await converge(pages);
  const relevant = mode === 'rtc' ? pages : [pages[0]];
  for (const page of relevant) await search(page, `${surname} Анна Петровна`, `${surname} Анна Петровна`);
}

(async () => {
  assert.match(process.env.MYTREE_EXPECTED_BUNDLE_SHA256 || '', /^[0-9a-f]{64}$/);
  await fs.mkdir(output, { recursive: false });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const pages = [], contexts = [];
  const timeout = setTimeout(() => { report.errors.push('240-second browser deadline'); void browser.close(); }, 240000);
  try {
    for (let index = 0; index < 2; index++) {
      const context = await browser.newContext({ viewport: index ? { width: 390, height: 844 } : { width: 1440, height: 1100 },
        deviceScaleFactor: 1, isMobile: index === 1, hasTouch: index === 1 }); contexts.push(context);
      await context.route('**/*', (route) => {
        const url = new URL(route.request().url());
        return url.origin === origin || (mode === 'rtc' && /(?:peerjs\.com|test\.mosquitto\.org)$/.test(url.hostname))
          ? route.continue() : route.abort();
      });
      if (mode === 'local') await context.routeWebSocket('**/*', (socket) => socket.close());
      const entries = [[`${prefix}client-id`, JSON.stringify(actors[index])], [`${prefix}last-room`, JSON.stringify(room)],
        [`${roomPrefix}membership`, JSON.stringify(room)], ...baseline.map((record) =>
          [`${roomPrefix}operation.${encode(record.id)}`, JSON.stringify(record)])];
      await context.addInitScript(({ entries, origin }) => {
        window.addEventListener('flutter-first-frame', () => { window.__familyFrame = true; }, { once: true });
        if (location.origin === origin && !localStorage.getItem('family-fixture-seeded')) {
          for (const [key, value] of entries) localStorage.setItem(key, value);
          localStorage.setItem('family-fixture-seeded', 'true');
        }
        window.__familyPeers = []; window.__familyHandshakes = [];
        const observe = (channel) => {
          const record = (data) => {
            if (typeof data !== 'string') return;
            try { const packet = JSON.parse(data); if (['hello', 'welcome'].includes(packet.type))
              window.__familyHandshakes.push({ type: packet.type, marriageHistory: packet.marriageHistory }); } catch {}
          };
          channel.addEventListener('message', (event) => record(event.data));
          const send = channel.send.bind(channel); channel.send = (data) => { record(data); return send(data); };
        };
        const Native = window.RTCPeerConnection;
        window.RTCPeerConnection = class extends Native {
          constructor(...args) { super(...args); window.__familyPeers.push(this); this.addEventListener('datachannel', (event) => observe(event.channel)); }
          createDataChannel(...args) { const channel = super.createDataChannel(...args); observe(channel); return channel; }
        };
      }, { entries, origin });
      const page = await context.newPage(); pages.push(page);
      page.on('pageerror', (error) => report.errors.push(`profile ${index}: ${error.message}`));
      page.on('console', (message) => {
        const text = message.text();
        if (/^WebSocket connection to 'wss:\/\/(?:0\.peerjs\.com|test\.mosquitto\.org)(?::\d+)?[/]/.test(text)) {
          report.providerErrors.push(text.replace(/wss:\/\/[^']+/g, (value) => { const url = new URL(value); return `${url.origin}${url.pathname}`; }));
        } else if (message.type() === 'error' || /EXCEPTION CAUGHT|RenderFlex overflowed|Another exception was thrown/.test(text)) report.errors.push(text);
      });
    }
    await Promise.all(pages.map(load)); await converge(pages);
    if (mode === 'rtc') for (const page of pages) {
      await until(() => page.evaluate(() => window.__familyPeers.some((peer) => peer.connectionState === 'connected') &&
        window.__familyHandshakes.some((packet) => packet.type === 'hello') &&
        window.__familyHandshakes.some((packet) => packet.type === 'welcome')), 'Actual RTC/capability handshake did not complete.');
      const packets = await page.evaluate(() => window.__familyHandshakes);
      assert.ok(packets.every((packet) => packet.marriageHistory === true)); report.handshakes.push(packets);
    }
    const a = pages[0];
    await currentName(pages, 'Иванова');
    await openBiography(a, true);
    const section = a.locator('[aria-label^="Фамилии и браки"]').first(); await reveal(a, section, { section: true });
    await capture(a, 'initial-implied-marriage');
    assert.doesNotMatch(await snapshot(a), /01\.01\.2000.*[—–]|[—–].*01\.01\.2000/);
    const unchanged = await history(a);
    await deleteEntry(a, 0, true);
    assert.deepEqual(await history(a), unchanged, 'Cancelling deletion wrote history.');
    await deleteEntry(a, 0);
    await closeBiography(a); await currentName(pages, 'Смирнова');
    await openBiography(a, true);
    await existingMarriage(a, 'Иван', 'Иванов Иван', '01/01/1995', true);
    await closeBiography(a); await currentName(pages, 'Иванова');
    await openBiography(a, true);
    await existingMarriage(a, 'Олег', 'Петров Олег', '01/01/2010');
    await capture(a, 'childless-explicit-marriage');
    await closeBiography(a); await currentName(pages, 'Петрова');
    const selectedCard = await a.getByRole('button', { name: 'Выбрать Анна', exact: true }).boundingBox();
    const spouseCard = await a.getByRole('button', { name: 'Выбрать Олег', exact: true }).boundingBox();
    assert.ok(selectedCard && spouseCard && Math.abs(selectedCard.y - spouseCard.y) <= 1.5,
      'A childless spouse was not in the same feasible generation.');
    await capture(a, 'childless-partner-canvas');
    await openBiography(a, true); await addHistory(a, 'Смена фамилии');
    await type(a, a.getByRole('textbox', { name: 'Фамилия', exact: true }), 'Кузнецов');
    await type(a, a.getByRole('textbox', { name: 'Причина', exact: true }), 'Личная причина');
    await date(a, 'Дата смены фамилии', '01/01/2020');
    await a.getByRole('button', { name: 'Добавить', exact: true }).click();
    await a.getByRole('alertdialog').waitFor({ state: 'hidden' });
    await closeBiography(a); await currentName(pages, 'Кузнецова');
    await openBiography(a, true); await capture(a, 'chronological-surname-history');
    await deleteEntry(a, 2);
    await closeBiography(a); await currentName(pages, 'Петрова');
    await openBiography(a, true); const beforeNewPartner = await history(a);
    await addHistory(a, 'Брак');
    await type(a, a.getByRole('textbox', { name: 'Имя нового человека', exact: true }), 'Сергей');
    await type(a, a.getByRole('textbox', { name: 'Фамилия при рождении', exact: true }), 'Орлов');
    await date(a, 'Дата начала', '01/01/2030');
    await a.getByRole('button', { name: 'Добавить', exact: true }).click();
    await a.getByRole('alertdialog').waitFor({ state: 'hidden' });
    const newRecords = (await history(a)).filter((record) => !beforeNewPartner.some((old) => old.id === record.id));
    assert.equal(newRecords.length, 1, 'New spouse and marriage were not one atomic record.');
    const newOperation = JSON.parse(newRecords[0].text);
    assert.equal(newOperation.type, 'addMarriage'); assert.equal(newOperation.newPartner.name, 'Сергей');
    await closeBiography(a); await currentName(pages, 'Орлова');
    const final = await Promise.all(pages.map(history)); final.forEach(verifyJournal);
    const edits = final[0].filter((record) => !baseline.some((old) => old.id === record.id));
    assert.ok(edits.every((record) => record.kind === 'tree'));
    const appendedOperations = edits.map((record) => JSON.parse(record.text));
    const marriages = appendedOperations.filter((entry) => entry.type === 'addMarriage');
    assert.deepEqual(marriages.map((entry) => entry.startDate).sort(), ['1995-01-01', '2010-01-01', '2030-01-01']);
    assert.equal(marriages.find((entry) => entry.startDate === '1995-01-01').endMode, 'lifelong');
    assert.equal(marriages.find((entry) => entry.startDate === '2010-01-01').endMode, 'unknown');
    assert.equal(appendedOperations.find((entry) => entry.type === 'addSurnameChange').date, '2020-01-01');
    const childParentWrites = edits.map((record) => JSON.parse(record.text))
      .filter((op) => op.type === 'setValue' && ['fatherId', 'motherId'].includes(op.field));
    assert.deepEqual(childParentWrites, [], 'Marriage history changed a parent edge.');
    await Promise.all(pages.map(load)); await converge(pages);
    for (let index = 0; index < pages.length; index++) {
      assert.deepEqual(await history(pages[index]), final[index]);
      await search(pages[index], index === 0 || mode === 'rtc' ? 'Орлова Анна' : 'Иванова Анна',
        index === 0 || mode === 'rtc' ? 'Орлова Анна Петровна' : 'Иванова Анна Петровна');
      await openBiography(pages[index]);
      await reveal(pages[index], pages[index].locator('[aria-label^="Фамилии и браки"]').first(), { section: true });
      await capture(pages[index], `profile-${index}-durable-reload`);
      report.rtc.push(await pages[index].evaluate(async () => Promise.all(window.__familyPeers.map(async (peer) => {
        const stats = await peer.getStats(); return { connectionState: peer.connectionState,
          pairs: [...stats.values()].filter((entry) => entry.type === 'candidate-pair' && entry.state === 'succeeded' && entry.nominated)
            .map((entry) => ({ local: stats.get(entry.localCandidateId)?.candidateType, remote: stats.get(entry.remoteCandidateId)?.candidateType })) };
      }))));
    }
    await fs.writeFile(path.join(output, 'synthetic-journals.json'), JSON.stringify(final, null, 2));
    report.journals = final.map((journal) => ({ records: journal.length, sha256: hash(journal) }));
    report.completed = true;
  } catch (error) {
    report.failure = error.stack; process.exitCode = 1;
    for (const [index, page] of pages.entries()) if (!page.isClosed()) {
      await page.screenshot({ path: path.join(output, `failure-${index}.png`) }).catch(() => {});
      await fs.writeFile(path.join(output, `failure-${index}.txt`), await snapshot(page).catch(() => '')).catch(() => {});
      await fs.writeFile(path.join(output, `failure-${index}-journal.json`), JSON.stringify(await history(page).catch(() => []), null, 2)).catch(() => {});
    }
  } finally {
    clearTimeout(timeout); await fs.writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
    await browser.close(); console.log(JSON.stringify({ completed: report.completed, steps: report.steps, errors: report.errors, failure: report.failure }));
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
