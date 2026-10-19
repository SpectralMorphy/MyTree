// Usage: node tool/check_yandex_disk.cjs <playwright-module> <base-url> <artifacts>
// Drives the release Flutter UI headlessly with an isolated, emulated Disk REST
// service. No real token, publication, or upload to a personal account is used.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require(process.argv[2]);
const base = process.argv[3], output = process.argv[4];
const origin = new URL(base).origin;
const room = 'd'.repeat(32), owner = 'a'.repeat(32), samePerson = 'b'.repeat(32);
const stranger = 'c'.repeat(32), guest = 'e'.repeat(32);
const token = 'browser-fixture-not-a-real-oauth-token';
const prefix = 'mytree.room-store.v1.';
const roomPrefix = `${prefix}room.${Buffer.from(room).toString('base64url')}.`;
const errors = [], calls = [], files = new Map(), directories = new Set();
const report = { headless: true, completed: false, mode: 'emulated-rest-real-browser', checks: [], browserBundles: [] };
const sha256 = (bytes) => require('node:crypto').createHash('sha256').update(bytes).digest('hex');
let expectedBundle;
let unavailable = false;
let heldListing;
let listingHeld = false;
const diskAction = (page) => page.getByRole('button', { name: /^Яндекс Диск:/ });
const diskStatus = (page) => diskAction(page).ariaSnapshot();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check, message, timeout = 45000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await check()) return;
    await sleep(120);
  }
  throw new Error(message);
}
const semantics = (page) => page.locator('body').ariaSnapshot();
async function activate(page) {
  await page.waitForFunction(() => window.__firstFrame, null, { timeout: 90000 });
  const marker = page.locator('flt-semantics-placeholder');
  if (await marker.count()) {
    await marker.evaluate((element) => Object.assign(element.style, {
      position: 'fixed', left: '0', top: '0', width: '2px', height: '2px',
      transform: 'none', zIndex: '2147483647',
    }));
    await marker.click({ force: true });
  }
}
async function history(page) {
  return page.evaluate(() => Object.keys(localStorage).filter((key) => key.includes('.operation.'))
    .map((key) => JSON.parse(localStorage.getItem(key))));
}
async function fill(page, field, value) {
  await field.click();
  await field.focus();
  await page.keyboard.press('Control+A');
  await page.keyboard.type(value, { delay: 10 });
}
function seed() {
  const records = [];
  function record(author, kind, text, targetActor) {
    const clock = records.length + 1;
    records.push({ id: `disk-fixture-${clock}`, author, kind, text,
      clock, createdAt: 1792368000000, ...(targetActor ? { targetActor } : {}) });
  }
  for (const [actor, name, role] of [[owner, 'Владелец', 'editor'], [samePerson, 'То же лицо', 'editor'],
    [stranger, 'Другой редактор', 'editor'], [guest, 'Гость', 'guest']]) {
    record(actor, 'participantName', name);
    record(owner, 'participantRole', role, actor);
  }
  for (const actorId of [owner, samePerson]) {
    record(actorId, 'tree', JSON.stringify({ type: 'bindActor', personId: 'root', actorId }));
  }
  return records;
}
async function rest(route) {
  const request = route.request(), url = new URL(request.url());
  assert.equal(request.headers().referer, undefined, 'Disk request sent the application referrer.');
  const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*',
    'access-control-allow-methods': 'GET, PUT, OPTIONS' };
  const respond = (status, body = {}, extra = {}) => route.fulfill({ status,
    headers: { ...cors, ...extra }, contentType: 'application/json', body: JSON.stringify(body) });
  if (request.method() === 'OPTIONS') return respond(204);
  if (url.hostname === 'cloud-api.yandex.net') {
    assert.equal(request.headers().authorization, `OAuth ${token}`);
    calls.push({ method: request.method(), resource: url.pathname, path: url.searchParams.get('path') });
    if (unavailable) return respond(503);
    const diskPath = url.searchParams.get('path');
    if (url.pathname.endsWith('/resources/upload')) {
      if (files.has(diskPath)) return respond(409);
      return respond(200, { href: `https://uploader.yandex.net/disk-fixture?path=${encodeURIComponent(diskPath)}` });
    }
    if (url.pathname.endsWith('/resources/download')) {
      if (!files.has(diskPath)) return respond(404);
      return respond(200, { href: `https://downloader.yandex.net/disk-fixture?path=${encodeURIComponent(diskPath)}` });
    }
    if (request.method() === 'PUT') {
      if (directories.has(diskPath)) return respond(409);
      directories.add(diskPath);
      return respond(201);
    }
    if (url.searchParams.get('fields') === 'type') return respond(200, { type: 'dir' });
    if (heldListing) {
      const waiting = heldListing;
      heldListing = null;
      listingHeld = true;
      await waiting;
    }
    const names = [...files.keys()].filter((name) => name.startsWith(`${diskPath}/`))
      .map((name) => ({ name: name.slice(diskPath.length + 1), type: 'file' }));
    const offset = Number(url.searchParams.get('offset') || 0);
    // Force pagination, including when a later reconciliation uploads more files.
    return respond(200, { _embedded: { items: names.slice(offset, offset + 1),
      total: names.length, offset, limit: 1 } });
  }
  assert.equal(request.headers().authorization, undefined, 'Token leaked to transfer href.');
  calls.push({ method: request.method(), resource: 'transfer', host: url.hostname });
  const diskPath = url.searchParams.get('path');
  if (request.method() === 'PUT') {
    files.set(diskPath, request.postDataBuffer());
    return respond(201);
  }
  return route.fulfill({ status: 200, headers: cors, contentType: 'application/octet-stream', body: files.get(diskPath) });
}
async function profile(browser, actor, records, credentials, mobile = false) {
  const context = await browser.newContext({ viewport: mobile ? { width: 390, height: 844 } : { width: 1280, height: 900 },
    serviceWorkers: 'block', reducedMotion: 'reduce', isMobile: mobile, hasTouch: mobile });
  await context.route('**/*', (route) => {
    const url = new URL(route.request().url());
    if (['cloud-api.yandex.net', 'uploader.yandex.net', 'downloader.yandex.net'].includes(url.hostname)) return rest(route);
    return url.origin === origin ? route.continue() : route.abort('internetdisconnected');
  });
  await context.routeWebSocket('**/*', (socket) => socket.close());
  const storage = { [`${prefix}client-id`]: JSON.stringify(actor), [`${prefix}last-room`]: JSON.stringify(room),
    [`${roomPrefix}membership`]: JSON.stringify(room) };
  for (const edit of records) storage[`${roomPrefix}operation.${Buffer.from(edit.id).toString('base64url')}`] = JSON.stringify(edit);
  if (credentials) storage[`${roomPrefix}disk-credentials`] = JSON.stringify(credentials);
  await context.addInitScript(({ origin, storage }) => {
    window.__firstFrame = false;
    window.addEventListener('flutter-first-frame', () => window.__firstFrame = true, { once: true });
    if (location.origin === origin && !localStorage.getItem('disk-fixture-seeded')) {
      for (const [key, value] of Object.entries(storage)) localStorage.setItem(key, value);
      localStorage.setItem('disk-fixture-seeded', 'true');
    }
  }, { origin, storage });
  const page = await context.newPage();
  page.on('pageerror', (error) => errors.push(error.message));
  page.on('console', (message) => {
    if (/EXCEPTION CAUGHT|Another exception was thrown|RenderFlex.*overflow|RenderBox was not laid out/i.test(message.text())) errors.push(message.text());
    if (message.type() === 'error') (report.consoleErrors ??= []).push(message.text().replaceAll(token, '<redacted>'));
  });
  page.on('requestfailed', (request) => (report.requestFailures ??= []).push({
    host: new URL(request.url()).hostname, failure: request.failure()?.errorText,
  }));
  const bundleResponse = page.waitForResponse((response) => response.url() === new URL('main.dart.js', base).href);
  await page.goto(base, { waitUntil: 'domcontentloaded' });
  const response = await bundleResponse;
  const bundle = { sha256: sha256(await response.body()), status: response.status(), fromServiceWorker: response.fromServiceWorker() };
  report.browserBundles.push(bundle);
  assert.equal(bundle.sha256, expectedBundle, 'Browser did not receive the release build being checked.');
  assert.equal(bundle.status, 200);
  assert.equal(bundle.fromServiceWorker, false);
  await activate(page);
  await until(async () => await page.getByRole('button', { name: 'Открыть локальную копию', exact: true }).count() ||
    await page.getByRole('button', { name: 'Биография', exact: true }).count(), 'Saved room did not open.');
  const local = page.getByRole('button', { name: 'Открыть локальную копию', exact: true });
  if (await local.count()) await local.click();
  await page.getByRole('button', { name: /Меню комнаты/ }).waitFor();
  return { page, context };
}
async function settings(page) {
  await page.getByRole('button', { name: /Меню комнаты/ }).click();
  await page.getByRole('menuitem', { name: 'Настройки комнаты', exact: true }).click();
  await page.getByRole('alertdialog').last().waitFor();
}
async function closeSettings(page, guestRole = false) {
  await page.getByRole('button', { name: guestRole ? 'Закрыть' : 'Отмена', exact: true }).click();
}
async function compactCloud(page, state, screenshot) {
  const cloud = diskAction(page);
  await cloud.waitFor();
  const [disk, participants] = await Promise.all([cloud.boundingBox(),
    page.getByRole('button', { name: /^Участники:/ }).boundingBox()]);
  assert.ok(disk && participants);
  assert.ok(disk.x + disk.width <= participants.x + 1, 'Disk is not immediately left of participants.');
  assert.ok(Math.abs(disk.y - participants.y) < 8, 'Disk left the header row.');
  assert.ok(disk.x >= 0 && disk.y >= 0 && disk.x + disk.width <= page.viewportSize().width);
  assert.ok(disk.width <= 56 && disk.height <= 56, 'Disk status is not a compact icon target.');
  assert.equal(await page.getByText('Копия на Диске подтверждена', { exact: true }).count(), 0,
    'The standalone Disk status row was not removed.');
  const label = await cloud.ariaSnapshot();
  if (state === 'confirmed') assert.match(label, /Копия на Диске подтверждена/);
  if (state === 'busy') {
    assert.match(label, /Синхронизация с Диском/);
    assert.equal(await cloud.isEnabled(), false);
  }
  if (state === 'error') assert.match(label, /HTTP 503/);
  (report.headerStates ??= []).push({ state, viewport: page.viewportSize(), disk, participants, label });
  if (screenshot) await page.screenshot({ path: path.join(output, screenshot) });
}
(async () => {
  await fs.mkdir(output, { recursive: true });
  expectedBundle = sha256(await fs.readFile(path.resolve(__dirname, '../build/web/main.dart.js')));
  const browser = await chromium.launch({ executablePath: 'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
  let main;
  try {
    main = await profile(browser, owner, seed(), null, true);
    const page = main.page;
    await settings(page);
    await page.getByRole('button', { name: 'Подключить Яндекс Диск', exact: true }).click();
    await fill(page, page.getByRole('textbox', { name: 'OAuth-токен', exact: true }), token);
    await page.getByRole('button', { name: 'Подключить', exact: true }).click();
    await page.getByRole('alertdialog').last()
      .getByRole('button', { name: 'Подключить', exact: true }).click();
    await until(async () => (await semantics(page)).includes('Копия на Диске подтверждена'), 'Disk upload was not acknowledged.');
    assert.ok(files.size > 0);
    const records = await history(page);
    const binding = records.find((edit) => edit.kind === 'diskConnection');
    assert.ok(binding);
    assert.equal(JSON.stringify(records).includes(token), false);
    assert.equal(await page.getByRole('textbox', { name: 'OAuth-токен', exact: true }).count(), 0);
    assert.equal(await page.getByRole('button', { name: 'Подключить Яндекс Диск', exact: true }).count(), 0);
    await page.screenshot({ path: path.join(output, 'connected-phone.png') });
    report.checks.push('phone connect + immutable upload read-back + token absent from history');
    await closeSettings(page);
    await compactCloud(page, 'confirmed', 'cloud-confirmed-phone.png');
    const beforeHeader = (await history(page)).sort((a, b) => a.id.localeCompare(b.id));
    let releaseListing;
    heldListing = new Promise(resolve => { releaseListing = resolve; });
    listingHeld = false;
    await diskAction(page).click();
    await until(() => listingHeld, 'Header click did not start synchronization.', 10000);
    await compactCloud(page, 'busy', 'cloud-syncing-phone.png');
    assert.equal(await page.getByRole('alertdialog').count(), 0, 'Cloud action opened settings instead of syncing.');
    releaseListing();
    await until(async () => await diskAction(page).isEnabled() &&
      /Копия на Диске подтверждена/.test(await diskStatus(page)),
      'Header synchronization did not finish.');
    assert.deepEqual((await history(page)).sort((a, b) => a.id.localeCompare(b.id)), beforeHeader,
      'Manual synchronization without changes authored history.');
    report.checks.push('phone compact header confirmed/busy overlays + direct synchronization without settings or writes');
    await page.reload({ waitUntil: 'domcontentloaded' });
    await activate(page);
    const local = page.getByRole('button', { name: 'Открыть локальную копию', exact: true });
    await local.waitFor({ timeout: 60000 });
    await local.click();
    await settings(page);
    await until(async () => (await semantics(page)).includes('Копия на Диске подтверждена'), 'Reload did not restore Disk access.');
    report.checks.push('credential persistence + asynchronous reconciliation after reload');
    await closeSettings(page);
    unavailable = true;
    await diskAction(page).click();
    await until(async () => /HTTP 503/.test(await diskStatus(page)),
      'Cloud error was not exposed in the header tooltip.');
    await compactCloud(page, 'error', 'cloud-error-phone.png');
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.waitForTimeout(400);
    await diskAction(page).hover();
    await until(async () => await page.getByRole('tooltip').filter({ hasText: /HTTP 503/ }).count() > 0 ||
      await page.getByText(/Яндекс Диск:[\s\S]*HTTP 503/).first().isVisible().catch(() => false),
      'Real hover did not display the full Disk error tooltip.', 10000);
    await page.waitForTimeout(250);
    await page.screenshot({ path: path.join(output, 'cloud-error-tooltip-desktop.png') });
    await page.mouse.move(10, 70);
    await page.waitForTimeout(300);
    unavailable = false;
    await diskAction(page).click();
    await until(async () => /Копия на Диске подтверждена/.test(await diskStatus(page)) &&
      await diskAction(page).isEnabled(), 'Header error retry did not recover.');
    await compactCloud(page, 'confirmed', 'cloud-recovered-desktop.png');
    await page.setViewportSize({ width: 390, height: 844 });
    await page.waitForTimeout(400);
    await page.getByRole('button', { name: 'Биография', exact: true }).click();
    await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).click();
    report.checks.push('outage visible + local UI stays usable');
    unavailable = false;
    const credentials = { v: 1, bindingId: binding.id, token };
    for (const [actor, canUnlink, role] of [[stranger, false, 'editor'], [guest, false, 'guest'], [samePerson, true, 'editor']]) {
      const other = await profile(browser, actor, records, role === 'editor' ? credentials : null);
      if (role === 'guest') {
        assert.equal(await diskAction(other.page).count(), 0, 'Guest received a cloud synchronization action.');
      }
      await settings(other.page);
      await until(async () => !(await semantics(other.page)).includes('Синхронизация с Диском…'), 'Background sync did not settle.');
      assert.equal(await other.page.getByRole('button', { name: 'Отвязать Яндекс Диск', exact: true }).count(), canUnlink ? 1 : 0);
      assert.equal(await other.page.getByRole('button', { name: 'Подключить Яндекс Диск', exact: true }).count(), 0);
      if (role === 'guest') {
        assert.equal(await other.page.getByRole('button', { name: 'Синхронизировать', exact: true }).count(), 0);
        assert.equal(await other.page.evaluate((key) => localStorage.getItem(key), `${roomPrefix}disk-credentials`), null);
      }
      await other.page.screenshot({ path: path.join(output, `${role}-${actor.slice(0, 1)}-permissions.png`) });
      if (actor === stranger) {
        const previousFiles = files.size;
        await fill(other.page, other.page.getByRole('textbox', { name: 'Название комнаты', exact: true }), 'Облачная комната');
        await other.page.getByRole('button', { name: 'Сохранить', exact: true }).click();
        await until(() => files.size > previousFiles, 'Offline editor did not upload its local room rename.');
        await until(async () => await diskAction(page).isEnabled(), 'Owner header sync remained busy.');
        await diskAction(page).click();
        await until(async () => (await history(page)).some((edit) => edit.kind === 'roomName' && edit.text === 'Облачная комната'), 'Owner did not import asynchronous editor update.');
        report.checks.push('independent editor rename reaches owner through Disk without WebRTC');
      }
      if (canUnlink) {
        await other.page.getByRole('button', { name: 'Отвязать Яндекс Диск', exact: true }).click();
        await other.page.getByRole('alertdialog').last()
          .getByRole('button', { name: 'Отвязать', exact: true }).click();
        await until(async () => (await history(other.page)).some((edit) => edit.kind === 'diskConnection' && JSON.parse(edit.text).action === 'disconnect'), 'Same-person editor could not unlink.');
        await until(() => [...files.values()].some((bytes) => JSON.parse(bytes).history.some((edit) =>
          edit.kind === 'diskConnection' && JSON.parse(edit.text).action === 'disconnect')), 'Detach was not persisted to Disk.');
        await until(async () => await other.page.evaluate((key) => localStorage.getItem(key) === null,
          `${roomPrefix}disk-credentials`), 'Confirmed unlink retained the local token.');
        report.checks.push('unlink uploaded durably, files retained and local token removed');
      }
      await other.context.close();
    }
    report.checks.push('same-person owner device may unlink; other editor/guest cannot; guests hold no token');
    assert.deepEqual(errors, []);
    report.completed = true;
    report.requests = calls;
    report.cloudFiles = [...files.keys()];
  } catch (error) {
    report.failure = error.stack;
    if (main) {
      report.semantics = await semantics(main.page).catch(() => null);
      await main.page.screenshot({ path: path.join(output, 'failure.png') }).catch(() => {});
    }
    process.exitCode = 1;
  } finally {
    report.errors = errors;
    report.requests = calls;
    report.cloudFileCount = files.size;
    await fs.writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
    await browser.close();
  }
})();
