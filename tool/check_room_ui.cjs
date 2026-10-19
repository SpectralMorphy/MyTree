// Usage: node tool/check_room_ui.cjs <playwright-module> <base-url> <screenshots>
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require(process.argv[2]);
const base = process.argv[3];
const screenshots = process.argv[4];
if (!base || !screenshots) throw new Error('Pass the app URL and screenshot directory.');

const editor = (page) => page.getByRole('textbox', { name: /Общее текстовое поле/ });
const titleButton = (page) => page.getByRole('button', { name: /Меню комнаты/ });
const participantButton = (page) => page.getByRole('button', { name: /^Участники:/ });
const bodyText = (page) => page.locator('body').ariaSnapshot();

async function waitUntil(check, message, timeout = 45000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  throw new Error(message);
}

async function activate(page) {
  await page.bringToFront(); // Only switches tabs inside this headless browser.
  await page.waitForFunction(() => window.__roomFirstFrame, null, { timeout: 90000 });
  const marker = page.locator('flt-semantics-placeholder');
  for (let attempt = 0; attempt < 5; attempt++) {
    if (await marker.count() === 0) break;
    if (await page.evaluate(() => navigator.maxTouchPoints > 0)) {
      // Autofocused Flutter input can move the one-pixel accessibility opt-in
      // placeholder offscreen. Position that test opt-in target, not the app UI.
      await marker.evaluate((element) => Object.assign(element.style, {
        position: 'fixed', left: '0px', top: '0px', width: '2px', height: '2px',
        transform: 'none', zIndex: '2147483647',
      }));
      await marker.tap({ force: true });
    } else {
      await marker.evaluate((element) => element.click());
    }
    await page.waitForTimeout(250);
  }
  await page.locator('flt-semantics').first().waitFor({ state: 'attached', timeout: 60000 });
}

async function load(page, url = base) {
  // Reopening a saved room is a fresh app launch, not Flutter hash routing.
  if (page.url() !== 'about:blank') await page.goto('about:blank');
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 120000 });
  await activate(page);
}

async function type(page, field, value) {
  await page.bringToFront();
  await field.click();
  await field.focus();
  await page.waitForTimeout(150);
  await page.keyboard.press('Control+A');
  await page.keyboard.press('Backspace');
  await page.keyboard.type(value, { delay: 8 });
}

async function name(page, value) {
  const field = page.getByRole('textbox', { name: /Ваше имя/ });
  await field.waitFor();
  await type(page, field, value);
  await page.getByRole('button', { name: 'Продолжить', exact: true }).click();
}

async function expectText(page, value) {
  await page.bringToFront();
  await editor(page).waitFor({ timeout: 60000 });
  await editor(page).click();
  await page.waitForFunction((text) => [...document.querySelectorAll('textarea,input')]
    .some((element) => element.value === text), value, { timeout: 45000 });
}

async function menu(page, item) {
  await page.bringToFront();
  await titleButton(page).click();
  await page.getByRole('menuitem', { name: item, exact: true }).click();
  if (item === 'Настройки комнаты') {
    await page.getByRole('textbox', { name: /Название комнаты/ }).waitFor();
  } else if (item === 'Изменить моё имя') {
    await page.getByRole('textbox', { name: /Ваше имя/ }).waitFor();
  } else if (item === 'Журнал изменений') {
    await page.getByRole('alertdialog').waitFor();
    await waitUntil(async () => (await bodyText(page)).includes('Имя участника'),
      'History dialog did not expose its entries.');
  }
}

async function openParticipants(page) {
  await page.bringToFront();
  await participantButton(page).click();
  await page.getByRole('heading', { name: 'Участники', exact: true }).waitFor();
  await page.waitForTimeout(400); // Wait for the dialog entrance animation.
}

async function closeParticipants(page) {
  await page.getByRole('button', { name: 'Закрыть', exact: true }).click();
}

async function inviteLink(page, role = 'guest') {
  await openParticipants(page);
  await page.getByRole('button', { name: 'Пригласить участников', exact: true }).click();
  if (role === 'editor') await page.getByRole('button', { name: 'Редактор', exact: true }).click();
  await page.getByRole('button', { name: 'Скопировать URL', exact: true }).click();
  const value = await page.evaluate(() => navigator.clipboard.readText());
  assert.equal(new URLSearchParams(new URL(value).hash.slice(1)).get('role'), role);
  await page.getByRole('button', { name: 'Закрыть', exact: true }).click();
  return value;
}

async function assertReadOnly(page, value) {
  await expectText(page, value);
  const before = await history(page);
  await page.keyboard.type('Гость не должен изменить текст');
  assert.deepEqual(await history(page), before, 'Guest typing changed the persistent journal.');
  assert.match(await bodyText(page), /Гость · только просмотр/);
  await menu(page, 'Настройки комнаты');
  assert.equal(await page.getByRole('button', { name: 'Сохранить', exact: true }).count(), 0);
  const input = page.getByRole('textbox', { name: /Название комнаты/ });
  await input.click();
  await page.keyboard.type('Гость не должен изменить название');
  await page.getByRole('button', { name: 'Закрыть', exact: true }).click();
  assert.deepEqual(await history(page), before, 'Guest changed the room name.');
}

async function promote(page, name) {
  await openParticipants(page);
  await page.getByRole('button', { name: new RegExp(`^${name},.*гость`) }).click();
  await page.getByRole('button', { name: 'Сделать редактором', exact: true }).click();
  await page.getByRole('button', { name: new RegExp(`^${name},.*гость`) }).waitFor({ state: 'hidden' });
  await closeParticipants(page);
}

async function history(page) {
  return page.evaluate(() => Object.keys(localStorage)
    .filter((key) => key.startsWith('mytree.room-store.v1.') && key.includes('.operation.'))
    .map((key) => JSON.parse(localStorage.getItem(key)))
    .sort((a, b) => a.id.localeCompare(b.id)));
}

async function sameHistory(pages) {
  await waitUntil(async () => {
    const histories = await Promise.all(pages.map(history));
    return histories.every((value) => JSON.stringify(value) === JSON.stringify(histories[0]));
  }, 'Persistent journals did not converge.');
}

async function count(page, value) {
  await page.bringToFront();
  await page.getByRole('button', { name: new RegExp(`^Участники: ${value} других онлайн`) })
    .waitFor({ timeout: 45000 });
}

(async () => {
  await fs.mkdir(screenshots, { recursive: true });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const pages = [];
  const errors = [];
  try {
    const desktop = await browser.newContext({
      permissions: ['clipboard-read', 'clipboard-write'],
      viewport: { width: 1100, height: 850 },
    });
    const mobile = await browser.newContext({
      viewport: { width: 390, height: 844 },
      deviceScaleFactor: 3,
      isMobile: true,
      hasTouch: true,
    });
    const third = await browser.newContext({
      permissions: ['clipboard-read', 'clipboard-write'],
      viewport: { width: 950, height: 800 },
    });
    const fourth = await browser.newContext({ viewport: { width: 950, height: 800 } });
    for (const context of [desktop, mobile, third, fourth]) {
      await context.addInitScript(() => {
        window.__roomFirstFrame = false;
        window.addEventListener('flutter-first-frame', () => { window.__roomFirstFrame = true; }, { once: true });
        const Native = window.RTCPeerConnection;
        window.RTCPeerConnection = class extends Native {
          constructor(config, ...rest) { super({ ...config, iceTransportPolicy: 'relay' }, ...rest); }
        };
      });
    }
    async function page(context) {
      const value = await context.newPage();
      value.on('pageerror', (error) => errors.push(error.message));
      pages.push(value);
      return value;
    }
    const a = await page(desktop);
    const b = await page(mobile);
    const c = await page(third);
    await load(a);
    await a.getByRole('button', { name: 'Создать комнату', exact: true }).click();
    await name(a, 'Алина');
    await editor(a).waitFor({ timeout: 45000 });
    await type(a, editor(a), 'Текст не должен меняться при переименовании комнаты');
    await menu(a, 'Настройки комнаты');
    await type(a, a.getByRole('textbox', { name: /Название комнаты/ }), 'Семья на ладони');
    await a.getByRole('button', { name: 'Сохранить', exact: true }).click();
    await expectText(a, 'Текст не должен меняться при переименовании комнаты');
    assert.doesNotMatch(await bodyText(a), /Сохранено на устройстве|изменений:|button "Настройки"/);
    await titleButton(a).click();
    await a.getByRole('menuitem', { name: 'Выход в меню', exact: true }).waitFor();
    assert.deepEqual(await a.getByRole('menuitem').evaluateAll((items) => items.map((item) => item.getAttribute('aria-label') || item.textContent)), [
      'Настройки комнаты', 'Журнал изменений', 'Изменить моё имя', 'Выход в меню',
    ]);
    await a.keyboard.press('Escape');
    await openParticipants(a);
    await a.getByRole('button', { name: 'Пригласить участников', exact: true }).click();
    await a.getByRole('button', { name: 'Скопировать URL', exact: true }).click();
    const invite = await a.evaluate(() => navigator.clipboard.readText());
    assert.ok(new URL(invite).hash.startsWith('#room='));
    assert.equal(new URLSearchParams(new URL(invite).hash.slice(1)).get('role'), 'guest');
    await a.getByRole('button', { name: 'Закрыть', exact: true }).click();
    const editorInvite = await inviteLink(a, 'editor');
    console.log('PASS: create/name prompt, rename, exact title menu, guest/editor invitation URLs.');

    await load(b, invite);
    await name(b, 'Борис');
    await expectText(b, 'Текст не должен меняться при переименовании комнаты');
    await count(a, 1);
    await count(b, 1);
    await sameHistory([a, b]);
    await assertReadOnly(b, 'Текст не должен меняться при переименовании комнаты');
    await openParticipants(b);
    await b.getByRole('button', { name: 'Пригласить участников', exact: true }).click();
    assert.equal(await b.getByRole('button', { name: 'Редактор', exact: true }).isEnabled(), false);
    await b.getByRole('button', { name: 'Закрыть', exact: true }).click();
    await load(c, editorInvite);
    await name(c, 'Вера');
    await editor(c).waitFor({ timeout: 60000 });
    await count(a, 2);
    await count(b, 2);
    await count(c, 2);
    await sameHistory([a, b, c]);
    await openParticipants(b);
    let roster = await bodyText(b);
    for (const person of ['Алина', 'Борис', 'Вера']) assert.match(roster, new RegExp(person));
    assert.doesNotMatch(roster, /heading "Редакторы"|heading "Гости"|Изменить имя/);
    assert.ok(roster.indexOf('Вера,') < roster.indexOf('Борис,'));
    assert.match(roster, /Алина,.*редактор/);
    assert.match(roster, /Борис,.*гость/);
    assert.match(roster, /Вера,.*редактор/);
    await b.screenshot({ path: path.join(screenshots, 'participants-mobile-online.png') });
    const delegatedInvite = await inviteLink(c, 'editor');
    assert.equal(delegatedInvite, editorInvite, 'An invited editor could not invite editors.');
    assert.doesNotMatch(await bodyText(c), /Гость · только просмотр/);
    await c.close();
    await count(a, 1);
    await waitUntil(async () => /Вера.*офлайн/.test(await bodyText(b)), 'Open participant panel did not update after disconnect.');
    roster = await bodyText(b);
    assert.ok(roster.indexOf('Вера,') < roster.indexOf('Борис,'), 'Offline editor was placed after an online guest.');
    await b.screenshot({ path: path.join(screenshots, 'participants-mobile-offline.png') });
    await closeParticipants(b);
    await sameHistory([a, b]);
    console.log('PASS: unified editor-first roster, non-editing guests, and live offline presence.');

    await menu(b, 'Журнал изменений');
    assert.match(await bodyText(b), /Имя участника/);
    assert.match(await bodyText(b), /Роль участника/);
    for (let attempt = 0; attempt < 8 && !(await bodyText(b)).includes('Семья на ладони'); attempt++) {
      await b.mouse.move(180, 420);
      await b.mouse.wheel(0, 240);
      await b.waitForTimeout(200);
    }
    const changes = await bodyText(b);
    assert.match(changes, /Алина/);
    assert.match(changes, /Семья на ладони/);
    await b.screenshot({ path: path.join(screenshots, 'history-mobile.png') });
    await b.getByRole('button', { name: 'Закрыть', exact: true }).click();
    await load(b, editorInvite);
    await assertReadOnly(b, 'Текст не должен меняться при переименовании комнаты');
    await openParticipants(b);
    assert.equal(await b.getByRole('button', { name: /^Борис, вы,/ }).count(), 0);
    assert.doesNotMatch(await bodyText(b), /Изменить имя/);
    await closeParticipants(b);
    await menu(b, 'Изменить моё имя');
    await type(b, b.getByRole('textbox', { name: /Ваше имя/ }), 'Борис II');
    await b.getByRole('button', { name: 'Сохранить', exact: true }).click();
    await editor(b).waitFor();
    await sameHistory([a, b]);
    console.log('PASS: guest cannot edit or rename; editor URL does not elevate saved guest; own name is editable.');
    await menu(a, 'Выход в меню');
    await a.getByRole('button', { name: 'Присоединиться', exact: true }).waitFor();
    await count(b, 0);
    await b.waitForTimeout(2500);
    await load(a, editorInvite);
    await editor(a).waitFor({ timeout: 60000 });
    await count(b, 1);
    await type(a, editor(a), 'Правка через гостевой узел');
    await expectText(b, 'Правка через гостевой узел');
    await type(a, editor(a), 'Текст не должен меняться при переименовании комнаты');
    await sameHistory([a, b]);
    assert.match(await bodyText(b), /Гость · только просмотр/);
    console.log('PASS: guest takes network ownership and relays editor changes without editor rights.');
    const guestSibling = await page(mobile);
    let guestSiblingSockets = 0;
    guestSibling.on('websocket', () => guestSiblingSockets++);
    await load(guestSibling, editorInvite);
    await assertReadOnly(guestSibling, 'Текст не должен меняться при переименовании комнаты');
    assert.equal(guestSiblingSockets, 0);
    await promote(a, 'Борис II');
    await waitUntil(async () => !(await bodyText(b)).includes('Гость · только просмотр') &&
      !(await bodyText(guestSibling)).includes('Гость · только просмотр'), 'Promotion did not enable all local tabs.');
    await sameHistory([a, b, guestSibling]);
    await guestSibling.close();
    await type(b, editor(b), 'Правка повышенного редактора');
    await expectText(a, 'Правка повышенного редактора');
    await type(b, editor(b), 'Текст не должен меняться при переименовании комнаты');
    await sameHistory([a, b]);
    await b.reload({ waitUntil: 'domcontentloaded' });
    await activate(b);
    await editor(b).waitFor({ timeout: 60000 });
    assert.equal(await b.getByRole('textbox', { name: /Ваше имя/ }).count(), 0);
    await expectText(b, 'Текст не должен меняться при переименовании комнаты');
    await sameHistory([a, b]);
    console.log('PASS: complete history and names/title persist across reload without another name prompt.');

    const sibling = await page(desktop);
    let siblingSockets = 0;
    sibling.on('websocket', () => siblingSockets++);
    await load(sibling, invite);
    await editor(sibling).waitFor({ timeout: 45000 });
    await count(a, 1);
    await count(sibling, 1);
    await count(b, 1);
    assert.equal(siblingSockets, 0, 'Local sibling created an external signaling connection.');
    await menu(sibling, 'Настройки комнаты');
    await type(sibling, sibling.getByRole('textbox', { name: /Название комнаты/ }), 'Общее семейное дерево');
    await sibling.getByRole('button', { name: 'Сохранить', exact: true }).click();
    await waitUntil(async () => (await bodyText(b)).includes('Общее семейное дерево'), 'Room name was not relayed from local follower.');
    await sameHistory([a, sibling, b]);
    await sibling.close();
    console.log('PASS: sibling shares identity and renames locally with zero extra public connections.');

    let d = await page(fourth);
    await load(d, invite);
    await name(d, 'Глеб');
    await editor(d).waitFor({ timeout: 60000 });
    await assertReadOnly(d, 'Текст не должен меняться при переименовании комнаты');
    await sameHistory([a, b, d]);
    await d.close();
    await count(b, 1);
    await promote(b, 'Глеб');
    await sameHistory([a, b]);
    d = await page(fourth);
    await load(d, invite);
    await editor(d).waitFor({ timeout: 60000 });
    assert.doesNotMatch(await bodyText(d), /Гость · только просмотр/);
    assert.equal(await d.getByRole('textbox', { name: /Ваше имя/ }).count(), 0);
    await type(d, editor(d), 'Правка редактора после повышения офлайн');
    await expectText(a, 'Правка редактора после повышения офлайн');
    await type(d, editor(d), 'Текст не должен меняться при переименовании комнаты');
    await sameHistory([a, b, d]);
    await d.close();
    await count(b, 1);
    console.log('PASS: promoted editor promotes an offline guest; role survives reconnect and allows editing.');

    await mobile.setOffline(true);
    await b.getByRole('button', { name: /Нет подключения к сети/ }).waitFor();
    await openParticipants(b);
    roster = await bodyText(b);
    assert.match(roster, /офлайн/);
    for (const person of ['Алина', 'Борис', 'Вера']) assert.match(roster, new RegExp(person));
    await b.screenshot({ path: path.join(screenshots, 'participants-no-network.png') });
    const bounds = await b.evaluate(() => ({ width: innerWidth, scroll: document.documentElement.scrollWidth }));
    assert.equal(bounds.width, 390);
    assert.equal(bounds.scroll, 390);
    await closeParticipants(b);
    await mobile.setOffline(false);
    await expectText(b, 'Текст не должен меняться при переименовании комнаты');
    await a.screenshot({ path: path.join(screenshots, 'room-desktop.png') });
    await b.screenshot({ path: path.join(screenshots, 'room-mobile.png') });
    console.log('PASS: offline cloud, retained roster, mobile layout; no hidden saved/edit-count strip.');
    assert.deepEqual(errors, []);
    console.log('Browser errors:', JSON.stringify(errors));
  } catch (error) {
    console.error(error.stack);
    console.error('Browser errors:', JSON.stringify(errors));
    for (const [index, page] of pages.entries()) {
      if (page.isClosed()) continue;
      console.error(`Page ${index + 1}:`, await bodyText(page).catch(() => 'unavailable'));
      await page.screenshot({ path: path.join(screenshots, `failure-${index + 1}.png`) }).catch(() => {});
    }
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
