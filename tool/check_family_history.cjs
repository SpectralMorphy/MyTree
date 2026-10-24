// Usage: node tool/check_family_history.cjs <playwright-module> <base-url> <new-artifacts-directory> [local|rtc] [all|toolbar-birth|marriage-ui|unknown-sex-ui]
// Real headless production UI and immutable storage; rtc retains production transports.
// marriage-ui: loopback/local only, desktop controls/cancellations + full 390px phone scenario, 300-second deadline.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const [moduleName, base, directory, mode = 'local', scope = 'all'] = process.argv.slice(2);
assert.ok(moduleName && base && directory);
assert.ok(['local', 'rtc'].includes(mode));
assert.ok(['all', 'toolbar-birth', 'marriage-ui', 'unknown-sex-ui'].includes(scope));
assert.ok(scope === 'all' || mode === 'local');
const { chromium } = require(moduleName);
const output = path.resolve(directory), origin = new URL(base).origin;
if (['marriage-ui', 'unknown-sex-ui'].includes(scope)) assert.ok(['localhost', '127.0.0.1', '[::1]'].includes(new URL(base).hostname),
  'marriage-ui requires a loopback base URL; external requests and WebSockets are blocked.');
const report = { mode, scope, headless: true, completed: false, steps: [], bundles: [], errors: [], providerErrors: [], handshakes: [], rtc: [] };
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
value('child', 'fatherId', 'ivan');
if (!['marriage-ui', 'unknown-sex-ui'].includes(scope)) value('child', 'motherId', 'root'); // No implied marriage in narrow fixtures.
value('child', 'birthDate', '2000-01-01');
if (scope === 'unknown-sex-ui') {
  value('root', 'birthDate', '1980-05-06');
  operation({ type: 'createPerson', personId: 'unknown-spouse', name: 'Сергей', sex: 'unknown' });
  surname('unknown-spouse', 'Какой-то');
  operation({ type: 'createPerson', personId: 'unknown-distant', name: 'Сосед', sex: 'unknown' });
  operation({ type: 'addMarriage', personId: 'root', partnerId: 'unknown-spouse', itemId: 'unknown-marriage',
    startDate: '2000-01-01', endDate: null, endMode: 'unknown', newPartner: null,
    surnameChoices: { root: { changeSurname: true, surname: { text: 'Какой-то', decline: true } },
      'unknown-spouse': { changeSurname: false, surname: null } } });
  operation({ type: 'addSurnameChange', personId: 'root', itemId: 'undated-change',
    surname: { text: 'Орлов', decline: true }, date: null, reason: 'Без даты' });
}

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
async function toolbar(page, label) {
  await sleep(500);
  const before = await history(page);
  const controls = {};
  for (const [name, locator] of [
    ['align', page.getByRole('button', { name: /^Выровнять всё(?:\s|$)/ })],
    ['name', page.getByRole('button', { name: /Формат имени/ })],
    ['minus', page.getByRole('button', { name: /^Уменьшить масштаб(?:\s|$)/ })],
    ['plus', page.getByRole('button', { name: /^Увеличить масштаб(?:\s|$)/ })],
    ['reset', page.getByRole('button', { name: /(?:Сбросить масштаб|^\d+%(?:\s|$))/ })],
    ['search', page.getByRole('textbox').first()],
  ]) {
    controls[name] = await locator.boundingBox();
    assert.ok(controls[name], `${label}: missing ${name} hit box.`);
  }
  // Native textbox semantics include padding beyond the painted search field.
  // Check button bounds strictly; search supplies only its origin/order here.
  const boxes = Object.entries(controls).filter(([name]) => name !== 'search').map(([, box]) => box);
  const viewport = page.viewportSize();
  report.steps.push({ name: `${label}-toolbar-geometry`, viewport, controls });
  for (const box of boxes) assert.ok(box.x >= -1 && box.x + box.width <= viewport.width + 1,
    `${label}: controls exceed viewport: ${JSON.stringify({ viewport, controls })}`);
  assert.ok(controls.search.x >= 0 && controls.search.x < viewport.width);
  assert.ok(Math.max(...boxes.map((box) => box.y + box.height)) - Math.min(...boxes.map((box) => box.y)) <= 48);
  for (const [left, right] of [['align', 'name'], ['name', 'minus'], ['minus', 'plus'], ['plus', 'reset'], ['reset', 'search']]) {
    assert.ok(controls[left].x + controls[left].width <= controls[right].x + 1,
      `${label}: expected Align, name format, [-][+][percentage], search: ${JSON.stringify(controls)}`);
  }
  await page.getByRole('button', { name: /Формат имени/ }).click();
  await page.getByRole('menuitem', { name: /(?:^| )ФИО$/ }).click();
  await capture(page, `${label}-toolbar-fio-before-zoom`);
  await page.getByRole('button', { name: /^Увеличить масштаб(?:\s|$)/ }).click();
  await until(async () => /110%/.test(await snapshot(page)), 'Zoom did not reach 110%.', 5000);
  await page.getByRole('button', { name: /(?:Сбросить масштаб|^\d+%(?:\s|$))/ }).click();
  await until(async () => /100%/.test(await snapshot(page)), 'Zoom did not reset to 100%.', 5000);
  await page.getByRole('button', { name: /Формат имени/ }).click();
  await page.getByRole('menuitem', { name: /(?:^| )ИФ$/ }).click();
  assert.deepEqual(await history(page), before, 'Name format and zoom wrote shared history.');
  report.steps.push({ name: `${label}-toolbar-order`, controls });
}
async function birthSurname(page, expected) {
  await until(async () => {
    const text = await snapshot(page);
    if (!text.includes('Фамилии и браки')) return false;
    return /Смирнова\s+при рождении/.test(text) === expected;
  }, `Birth-surname row did not become ${expected ? 'visible' : 'hidden'}.`, 5000);
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
  if (lifelong) await page.getByRole('checkbox', { name: 'Пожизненно', exact: true }).click();
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

// Narrow local regression: interaction through semantics/native input, observation through
// screenshots and the immutable localStorage journal only (no application internals).
const appended = (journal, before) => journal.filter((record) => !before.some((old) => old.id === record.id));
function retainRecords(journal, before) {
  assert.deepEqual(journal.filter((record) => before.some((old) => old.id === record.id)), before,
    'An existing immutable record changed or disappeared.');
}
async function marriageReady(page, editing = true) {
  await page.getByRole('button', { name: editing ? 'Просмотр' : 'Изменить', exact: true }).waitFor();
}
async function marriageTop(page) {
  await page.mouse.move(page.viewportSize().width - 35, page.viewportSize().height * .65);
  await page.mouse.wheel(0, -2400); await sleep(200);
}
async function marriageSelect(page, given) {
  await type(page, page.getByRole('textbox').first(), given);
  // Search labels use current surnames; do not freeze Anna's derived surname after later edits.
  const option = page.getByRole('button', { name: new RegExp(`^(?:[^,]* )?${given}(?: |,)[^\\n]*$`) });
  await option.waitFor(); assert.equal(await option.count(), 1);
  const selected = await option.ariaSnapshot(); await option.click();
  await until(async () => !await option.count() &&
    await page.getByRole('button', { name: 'Биография', exact: true }).isVisible(), 'Person selection did not finish.', 5000);
  return selected;
}
async function marriageBiography(page) {
  await openBiography(page, true); await marriageReady(page); await marriageTop(page);
}
async function marriageClose(page) {
  await closeBiography(page);
  await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).waitFor({ state: 'hidden' });
  await page.getByRole('button', { name: 'Биография', exact: true }).waitFor();
}
async function marriageChips(page, ongoing, dateLabel, selected, label) {
  const dialog = page.getByRole('alertdialog'); await dialog.waitFor();
  const names = [dateLabel, ongoing, 'Не известно'], boxes = [];
  // These are actual ChoiceChip controls, not the merged history text bounds.
  await reveal(page, dialog.getByRole('checkbox', { name: ongoing, exact: true }),
    { x: page.viewportSize().width / 2, y: page.viewportSize().height / 2 });
  for (const name of names) {
    const chip = dialog.getByRole('checkbox', { name, exact: true }); await chip.waitFor();
    assert.equal(await chip.isChecked(), name === selected, `${label}: incorrect ${name} selection.`);
    const box = await chip.boundingBox(); assert.ok(box); boxes.push(box);
  }
  const width = page.viewportSize().width;
  assert.ok(boxes.every((box) => box.x >= 0 && box.x + box.width <= width + 1));
  assert.ok(Math.max(...boxes.map((box) => box.y)) - Math.min(...boxes.map((box) => box.y)) <= 1.5,
    `${label}: end-date chips wrapped onto multiple rows.`);
  assert.ok(boxes[0].x + boxes[0].width <= boxes[1].x + 1 && boxes[1].x + boxes[1].width <= boxes[2].x + 1);
  report.steps.push({ name: label, chips: names, boxes });
}
async function marriageCalendar(page, input, { cancel = false, year = '1970' } = {}) {
  const dialog = page.getByRole('dialog'); await dialog.waitFor();
  const toggle = dialog.getByRole('button', { name: /Switch to input|Enter date|Ввести дату|Ввод даты/i });
  await toggle.waitFor(); await toggle.click();
  const field = dialog.getByRole('textbox').first(); await field.waitFor(); await field.click(); await field.focus();
  await until(() => page.evaluate(() => document.activeElement instanceof HTMLInputElement ||
    document.activeElement instanceof HTMLTextAreaElement), 'DatePicker native input did not build.', 5000);
  assert.ok((await page.evaluate(() => document.activeElement.value)).includes(year), `DatePicker did not default to ${year}.`);
  if (input) await type(page, field, input);
  await dialog.getByRole('button', { name: cancel ? /^(Cancel|Отмена|ОТМЕНА)$/ : /^(OK|ОК)$/ }).click();
  await dialog.waitFor({ state: 'hidden' });
}
async function marriageDeath(page) {
  await marriageReady(page); await marriageTop(page);
  const button = page.getByRole('button', { name: /^Дата смерти: / });
  await reveal(page, button); await button.click();
  await page.getByRole('alertdialog').waitFor();
  await page.getByRole('checkbox', { name: 'Жив', exact: true }).waitFor();
}
async function marriageCancel(page, before) {
  await page.getByRole('alertdialog').getByRole('button', { name: 'Отмена', exact: true }).click();
  await page.getByRole('alertdialog').waitFor({ state: 'hidden' }); await marriageReady(page);
  assert.deepEqual(await history(page), before, 'Cancelling a date/modal wrote history.');
}
async function marriageHistory(page, label, range, { belova = false } = {}) {
  await marriageReady(page); await marriageTop(page);
  await reveal(page, page.getByRole('button', { name: 'Брак', exact: true }));
  await reveal(page, page.getByRole('button', { name: /^Изменить запись(?: Изменить запись)?$/ }).last());
  await until(async () => {
    const text = await snapshot(page);
    return text.includes(range) && text.includes('Сергей Белов') && (!belova ||
      /Белова/.test(text) && /Смирнова\s+при рождении/.test(text));
  }, `${label}: marriage caption/range did not build.`, 5000);
  const text = await snapshot(page);
  assert.doesNotMatch(text, /Сергей Поздний|н\.в\./);
  // Flutter can merge the caption and range semantics: keep painted layout evidence,
  // never try to reveal() the merged history label or assert its misleading bounding box.
  await capture(page, label);
}
async function marriageSpousePixels(page, label, expected = [135, 88, 38]) {
  const root = page.getByRole('button', { name: 'Выбрать Анна', exact: true });
  const spouse = page.getByRole('button', { name: 'Выбрать Сергей', exact: true });
  await root.waitFor(); await spouse.waitFor(); await sleep(250);
  const a = await root.boundingBox(), b = await spouse.boundingBox(); assert.ok(a && b);
  const portrait = page.viewportSize().width < page.viewportSize().height;
  const rank = portrait ? 'x' : 'y', cross = portrait ? 'y' : 'x';
  assert.ok(Math.abs(a[rank] - b[rank]) <= 1.5, 'Childless spouse is not in the same generation.');
  assert.ok(Math.abs(a[cross] - b[cross]) >= 107 && Math.abs(a[cross] - b[cross]) <= 200,
    'Childless spouse is not adjacent to Anna.');
  const png = await page.screenshot({ path: path.join(output, `${label}-colored-childless-spouse.png`), animations: 'disabled' });
  // Decode the real PNG in a detached canvas; do not read or instrument the app canvas.
  const pixels = await page.evaluate(async ({ png, box }) => {
    const image = new Image(); image.src = `data:image/png;base64,${png}`; await image.decode();
    const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
    return [[25, 36], [82, 36], [54, 7], [54, 64]].map(([x, y]) =>
      [...context.getImageData(Math.round(box.x + x), Math.round(box.y + y), 1, 1).data].slice(0, 3));
  }, { png: png.toString('base64'), box: b });
  assert.ok(pixels.every((sample) => sample.every((channel, index) => Math.abs(channel - expected[index]) <= 14)),
    `Childless spouse has the wrong ring color: ${JSON.stringify({ pixels, expected })}`);
  report.steps.push({ name: `${label}-childless-spouse`, root: a, spouse: b, sameRankAxis: rank, pixels });
  await capture(page, `${label}-childless-spouse-semantics`);
}
async function marriageUi(page, label, full) {
  const initial = await history(page); assert.deepEqual(initial, [...baseline].sort((a, b) => a.id.localeCompare(b.id)));
  await page.getByRole('button', { name: /Формат имени/ }).click();
  await page.getByRole('menuitem', { name: /(?:^| )ИФ$/ }).click();
  await marriageBiography(page); await addHistory(page, 'Брак');
  const dialog = page.getByRole('alertdialog');
  await page.getByRole('textbox', { name: 'Имя нового человека', exact: true }).waitFor();
  assert.equal(await page.getByRole('checkbox', { name: 'Новый человек', exact: true }).isChecked(), true);
  await type(page, page.getByRole('textbox', { name: 'Имя нового человека', exact: true }), 'Сергей');
  await marriageChips(page, 'Пожизненно', 'Дата', 'Не известно', `${label}-marriage-chip-row`);
  const change = page.getByRole('checkbox', { name: 'Менять фамилию', exact: true });
  assert.equal(await change.isChecked(), true);
  await dialog.getByRole('checkbox', { name: 'Дата', exact: true }).click();
  await marriageCalendar(page, '01/01/2010', { cancel: true });
  await marriageChips(page, 'Пожизненно', 'Дата', 'Не известно', `${label}-marriage-date-cancelled`);
  await dialog.getByRole('checkbox', { name: 'Дата', exact: true }).click();
  await marriageCalendar(page, '01/01/2010');
  await marriageChips(page, 'Пожизненно', '01.01.2010', '01.01.2010', `${label}-marriage-date-selected`);
  await dialog.getByRole('checkbox', { name: 'Пожизненно', exact: true }).click();
  await reveal(page, dialog.getByRole('button', { name: /^Дата начала/ }),
    { x: page.viewportSize().width / 2, y: page.viewportSize().height / 2 });
  await dialog.getByRole('button', { name: /^Дата начала/ }).click(); await marriageCalendar(page, '01/01/1995');
  await marriageChips(page, 'Пожизненно', '01.01.2010', 'Пожизненно', `${label}-marriage-lifelong`);
  await capture(page, `${label}-marriage-form`);
  assert.deepEqual(await history(page), initial, 'Marriage draft wrote records before submit.');
  await dialog.getByRole('button', { name: 'Добавить', exact: true }).click();
  await dialog.waitFor({ state: 'hidden' }); await marriageReady(page);
  await until(async () => (await history(page)).length === initial.length + 1, 'Atomic marriage was not saved.', 5000);
  const created = await history(page), original = appended(created, initial)[0], marriage = JSON.parse(original.text);
  retainRecords(created, initial);
  assert.equal(marriage.type, 'addMarriage'); assert.equal(marriage.personId, 'root');
  assert.deepEqual(marriage.newPartner, { name: 'Сергей', sex: 'male', birthDate: null, birthSurname: null });
  assert.equal(marriage.startDate, '1995-01-01'); assert.equal(marriage.endMode, 'lifelong'); assert.equal(marriage.endDate, null);
  assert.deepEqual(marriage.surnameChoices.root, { changeSurname: true, surname: null });
  await marriageClose(page); await marriageSpousePixels(page, label);
  await marriageBiography(page);
  const cancellation = await history(page);
  await marriageDeath(page); await marriageChips(page, 'Жив', 'Дата', 'Жив', `${label}-death-chip-row`);
  await page.getByRole('alertdialog').getByRole('checkbox', { name: 'Дата', exact: true }).click();
  await marriageCalendar(page, '01/01/2024', { cancel: true });
  await marriageChips(page, 'Жив', 'Дата', 'Жив', `${label}-death-date-cancelled`);
  await capture(page, `${label}-death-cancellation`); await marriageCancel(page, cancellation);
  await marriageClose(page);
  if (full) {
    await marriageSelect(page, 'Сергей'); await marriageBiography(page);
    const surnameField = page.getByRole('textbox', { name: 'Фамилия при рождении', exact: true });
    await reveal(page, surnameField); await type(page, surnameField, 'Белов');
    await until(async () => (await history(page)).some((record) => {
      const op = record.kind === 'tree' ? JSON.parse(record.text) : {};
      return op.type === 'setSurname' && op.personId === marriage.partnerId && op.text === 'Белов';
    }), 'Spouse birth surname was not saved.', 5000);
    await marriageDeath(page); await marriageChips(page, 'Жив', 'Дата', 'Не известно', `${label}-spouse-death-controls`);
    await page.getByRole('alertdialog').getByRole('checkbox', { name: 'Жив', exact: true }).click();
    await page.getByRole('alertdialog').waitFor({ state: 'hidden' });
    await page.getByRole('button', { name: 'Дата смерти: Жив', exact: true }).waitFor();
    await page.getByRole('button', { name: 'Просмотр', exact: true }).click(); await marriageReady(page, false); await marriageTop(page);
    await until(async () => (await snapshot(page)).includes('Дата рождения неизвестна — н.в'), 'Living life range did not build.', 5000);
    assert.doesNotMatch(await snapshot(page), /н\.в\./); await capture(page, `${label}-spouse-living`);
    await marriageClose(page); await marriageSelect(page, 'Анна'); await marriageBiography(page);
    await marriageHistory(page, `${label}-late-birth-surname`, '(01.01.1995 — н.в)', { belova: true });
    retainRecords(await history(page), created); // Original addMarriage still has surname snapshot=null.
    await marriageClose(page); await marriageSelect(page, 'Сергей'); await marriageBiography(page);
    await addHistory(page, 'Смена фамилии');
    await page.getByRole('textbox', { name: 'Фамилия', exact: true }).waitFor();
    await type(page, page.getByRole('textbox', { name: 'Фамилия', exact: true }), 'Поздний');
    await page.getByRole('button', { name: /^Дата смены фамилии/ }).click(); await marriageCalendar(page, '01/01/2020');
    await page.getByRole('alertdialog').getByRole('button', { name: 'Добавить', exact: true }).click();
    await page.getByRole('alertdialog').waitFor({ state: 'hidden' }); await marriageReady(page);
    await marriageClose(page);
    assert.match(await marriageSelect(page, 'Сергей'), /Поздний/, 'Spouse current surname did not change.');
    await marriageSelect(page, 'Анна'); await marriageBiography(page);
    await marriageHistory(page, `${label}-partner-name-before-marriage`, '(01.01.1995 — н.в)');
    await marriageDeath(page);
    await page.getByRole('alertdialog').getByRole('checkbox', { name: 'Не известно', exact: true }).click();
    await page.getByRole('alertdialog').waitFor({ state: 'hidden' });
    await page.getByRole('button', { name: 'Дата смерти: Не известно', exact: true }).waitFor();
    await marriageHistory(page, `${label}-unknown-death-endpoint`, '(01.01.1995 — ?)');
    await marriageDeath(page); await page.getByRole('checkbox', { name: 'Дата', exact: true }).click();
    await marriageCalendar(page, '01/01/2025');
    await page.getByRole('alertdialog').waitFor({ state: 'hidden' });
    await page.getByRole('button', { name: 'Дата смерти: 01.01.2025', exact: true }).waitFor();
    await marriageHistory(page, `${label}-first-known-death-endpoint`, '(01.01.1995 — 01.01.2025)');
    const beforeCancel = await history(page);
    await marriageDeath(page); await marriageChips(page, 'Жив', '01.01.2025', '01.01.2025', `${label}-death-date-reopened`);
    await capture(page, `${label}-death-date-chip`);
    await page.getByRole('checkbox', { name: '01.01.2025', exact: true }).click();
    await marriageCalendar(page, '01/01/2026', { cancel: true, year: '2025' });
    await marriageChips(page, 'Жив', '01.01.2025', '01.01.2025', `${label}-persisted-date-cancelled`);
    await marriageCancel(page, beforeCancel); await marriageClose(page);
  }
  const final = await history(page); retainRecords(final, created); verifyJournal(final);
  const ops = appended(final, initial).map((record) => { assert.equal(record.kind, 'tree'); return JSON.parse(record.text); });
  assert.deepEqual(ops.filter((op) => /Marriage/.test(op.type)), [marriage], 'Unexpected additional marriage operation.');
  assert.deepEqual(ops.filter((op) => op.type === 'setValue' && ['fatherId', 'motherId'].includes(op.field)), [],
    'Marriage authored a new parent edge.');
  if (full) {
    assert.equal(ops.filter((op) => op.type === 'addSurnameChange').length, 1);
    assert.ok(ops.some((op) => op.type === 'addSurnameChange' && op.personId === marriage.partnerId && op.date === '2020-01-01'));
    assert.ok(ops.some((op) => op.type === 'setValue' && op.personId === 'root' && op.field === 'deathDate' && op.value === '2025-01-01'));
    assert.ok(ops.some((op) => op.type === 'setValue' && op.personId === marriage.partnerId && op.field === 'alive' && op.value === true));
  } else assert.deepEqual(final, created, 'Desktop controls/cancellations appended extra records.');
  return final;
}

(async () => {
  assert.match(process.env.MYTREE_EXPECTED_BUNDLE_SHA256 || '', /^[0-9a-f]{64}$/);
  await fs.mkdir(output, { recursive: false });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const pages = [], contexts = [];
  const deadlineSeconds = scope === 'marriage-ui' ? 300 : 240;
  report.deadlineSeconds = deadlineSeconds;
  const timeout = setTimeout(() => { report.errors.push(`${deadlineSeconds}-second browser deadline`); void browser.close(); }, deadlineSeconds * 1000);
  try {
    for (let index = 0; index < 2; index++) {
      const context = await browser.newContext({ viewport: index ? { width: 390, height: 844 } : { width: 1440, height: 1100 },
        deviceScaleFactor: 1, isMobile: index === 1, hasTouch: index === 1 }); contexts.push(context);
      if (scope === 'marriage-ui') context.setDefaultTimeout(10000);
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
    if (scope === 'unknown-sex-ui') {
      report.coverage = 'Local desktop/phone unknown-sex blue cards, dated birth surname, undated change with ? (alignment is screenshot evidence) and biography header hierarchy; unchanged journals and real reload, no network synchronization.';
      const initial = await Promise.all(pages.map(history));
      for (const [index, page] of pages.entries()) {
        const label = index ? 'phone' : 'desktop';
        await marriageSpousePixels(page, `${label}-unknown-sex`, [37, 99, 235]);
        await openBiography(page);
        await marriageReady(page, false);
        await until(async () => /06\.05\.1980\s+Смирнова\s+при рождении/.test(await snapshot(page)), 'Birth surname has no birth-date prefix.', 5000);
        await until(async () => /\?\s+Орлова\s+Без даты/.test(await snapshot(page)), 'Undated surname change has no ? date column.', 5000);
        await capture(page, `${label}-dated-birth-and-headers`);
        await marriageClose(page);
        assert.deepEqual(await history(page), initial[index]);
      }
      await Promise.all(pages.map(load));
      for (const [index, page] of pages.entries()) {
        await marriageSpousePixels(page, `${index ? 'phone' : 'desktop'}-unknown-sex-reload`, [37, 99, 235]);
        assert.deepEqual(await history(page), initial[index]);
        verifyJournal(await history(page));
      }
      await fs.writeFile(path.join(output, 'synthetic-journals.json'), JSON.stringify(initial, null, 2));
      report.journals = initial.map((journal) => ({ records: journal.length, sha256: hash(journal) }));
      report.completed = true;
      return;
    }
    if (scope === 'marriage-ui') {
      report.coverage = 'Independent local desktop controls/create/cancel and full 390px phone flow; no RTC/external network. Range line/right alignment and absence of a painted parent line are screenshot evidence, not pixel geometry assertions.';
      const final = [];
      for (const [index, page] of pages.entries()) final.push(await marriageUi(page, index ? 'phone' : 'desktop', index === 1));
      final.forEach(verifyJournal);
      await fs.writeFile(path.join(output, 'synthetic-journals.json'), JSON.stringify(final, null, 2));
      await Promise.all(pages.map(load)); // Actual navigation: the fixture seed does not run again.
      for (const [index, page] of pages.entries()) {
        assert.deepEqual(await history(page), final[index], 'Complete journal changed across actual reload.');
        verifyJournal(await history(page));
        await page.getByRole('button', { name: /Формат имени/ }).click();
        await page.getByRole('menuitem', { name: /(?:^| )ИФ$/ }).click();
        await marriageSelect(page, 'Анна'); await marriageBiography(page);
        if (index) await marriageHistory(page, 'phone-marriage-durable-reload', '(01.01.1995 — 01.01.2025)');
        else {
          await marriageClose(page); await marriageSpousePixels(page, 'desktop-reload');
          await capture(page, 'desktop-marriage-durable-reload');
        }
        assert.deepEqual(await history(page), final[index], 'Reload observation wrote additional records.');
      }
      assert.deepEqual(report.errors, []);
      report.journals = final.map((journal) => ({ records: journal.length, sha256: hash(journal) }));
      report.completed = true;
      return;
    }
    for (const [index, page] of pages.entries()) await toolbar(page, index ? 'phone' : 'desktop');
    await openBiography(pages[1]);
    await birthSurname(pages[1], true);
    await capture(pages[1], 'phone-birth-surname');
    await closeBiography(pages[1]);
    if (scope === 'toolbar-birth') {
      for (const [index, page] of pages.entries()) {
        await openBiography(page, true);
        const before = await history(page);
        await birthSurname(page, true);
        await capture(page, `profile-${index}-birth-before-removal`);
        await deleteEntry(page, 0);
        await birthSurname(page, false);
        await capture(page, `profile-${index}-single-surname`);
        assert.equal((await history(page)).length, before.length + 1);
        await closeBiography(page);
      }
      const final = await Promise.all(pages.map(history)); final.forEach(verifyJournal);
      await Promise.all(pages.map(load));
      for (const [index, page] of pages.entries()) {
        assert.deepEqual(await history(page), final[index]);
        await openBiography(page);
        await birthSurname(page, false);
        await capture(page, `profile-${index}-single-surname-reload`);
      }
      await fs.writeFile(path.join(output, 'synthetic-journals.json'), JSON.stringify(final, null, 2));
      report.journals = final.map((journal) => ({ records: journal.length, sha256: hash(journal) }));
      report.completed = true;
      return;
    }
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
    await birthSurname(a, true);
    await capture(a, 'initial-implied-marriage');
    assert.doesNotMatch(await snapshot(a), /01\.01\.2000.*[—–]|[—–].*01\.01\.2000/);
    const unchanged = await history(a);
    await deleteEntry(a, 0, true);
    assert.deepEqual(await history(a), unchanged, 'Cancelling deletion wrote history.');
    await deleteEntry(a, 0);
    await closeBiography(a); await currentName(pages, 'Смирнова');
    await openBiography(a, true);
    await birthSurname(a, false);
    await reveal(a, section, { section: true });
    await capture(a, 'single-surname-not-repeated');
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
    await openBiography(a, true);
    await reveal(a, section, { section: true });
    await birthSurname(a, true);
    await capture(a, 'chronological-surname-history');
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
      await birthSurname(pages[index], true);
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
