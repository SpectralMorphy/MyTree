// Usage: node tool/check_room_resume.cjs <playwright-module> <base-url> <screenshots> [recovery-ms]
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require(process.argv[2]);
const base = process.argv[3];
const output = process.argv[4];
const recoveryMs = Number(process.argv[5] || 12000);
if (!base || !output) throw new Error('Pass the app URL and screenshot directory.');
if (!Number.isFinite(recoveryMs) || recoveryMs <= 0) throw new Error('Pass a positive recovery budget in milliseconds.');

const editor = (page) => page.getByRole('textbox', { name: /Общее текстовое поле/ });
const participants = (page) => page.getByRole('button', { name: /^Участники:/ });
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function activate(page) {
  await page.waitForFunction(() => window.__roomFirstFrame, null, { timeout: 90000 });
  const marker = page.locator('flt-semantics-placeholder');
  for (let attempt = 0; attempt < 5 && await marker.count(); attempt++) {
    await marker.evaluate((element) => Object.assign(element.style, {
      position: 'fixed', left: '0px', top: '0px', width: '2px', height: '2px',
      transform: 'none', zIndex: '2147483647',
    }));
    await marker.click({ force: true });
    await page.waitForTimeout(250);
  }
}

async function type(page, field, value) {
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
  await editor(page).waitFor({ timeout: 60000 });
}

async function history(page) {
  return page.evaluate(() => Object.keys(localStorage)
    .filter((key) => key.startsWith('mytree.room-store.v1.') && key.includes('.operation.'))
    .map((key) => JSON.parse(localStorage.getItem(key)))
    .sort((a, b) => a.id.localeCompare(b.id)));
}

async function waitUntil(check, message, timeout = 45000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await check()) return;
    await delay(150);
  }
  throw new Error(message);
}

async function connected(pages, timeout = 45000) {
  await Promise.all(pages.map((page) => page.getByRole('button', {
    name: 'Участники: 1 других онлайн', exact: true,
  }).waitFor({ timeout })));
}

// Headless Chrome does not hide its tabs like a physical mobile browser. Supply
// visibility events explicitly, and use the debugger to actually suspend JS.
async function visibility(page, hidden) {
  await page.evaluate((value) => {
    window.__roomHidden = value;
    document.dispatchEvent(new Event('visibilitychange'));
    window.dispatchEvent(new Event(value ? 'blur' : 'focus'));
    if (!value) window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true }));
  }, hidden);
}

(async () => {
  await fs.mkdir(output, { recursive: true });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const pages = [];
  const errors = [];
  const debuggers = [];
  try {
    const desktop = await browser.newContext({
      permissions: ['clipboard-read', 'clipboard-write'],
      viewport: { width: 1100, height: 850 },
    });
    const mobile = await browser.newContext({
      viewport: { width: 390, height: 844 }, deviceScaleFactor: 2,
      isMobile: true, hasTouch: true,
    });
    for (const context of [desktop, mobile]) {
      await context.addInitScript(() => {
        window.__roomFirstFrame = false;
        window.addEventListener('flutter-first-frame', () => { window.__roomFirstFrame = true; }, { once: true });
        window.__roomHidden = false;
        Object.defineProperty(document, 'hidden', { get: () => window.__roomHidden, configurable: true });
        Object.defineProperty(document, 'visibilityState', {
          get: () => window.__roomHidden ? 'hidden' : 'visible', configurable: true,
        });
        window.__roomChannels = [];
        window.__roomHoldInitial = sessionStorage.getItem('mytree.resume-check.hold-initial') === 'true';
        window.__roomInitialHeld = [];
        window.__roomWelcomeReceived = false;
        window.__roomReleaseInitial = () => {
          window.__roomHoldInitial = false;
          sessionStorage.removeItem('mytree.resume-check.hold-initial');
          for (const [channel, data] of window.__roomInitialHeld.splice(0)) {
            channel.dispatchEvent(new MessageEvent('message', { data }));
          }
        };
        const track = (channel) => {
          if (window.__roomChannels.includes(channel)) return channel;
          window.__roomChannels.push(channel);
          const send = channel.send.bind(channel);
          channel.send = (data) => { if (!channel.__roomStale) send(data); };
          channel.addEventListener('message', (event) => {
            if (channel.__roomStale) {
              event.stopImmediatePropagation();
              return;
            }
            if (window.__roomHoldInitial && window.__roomWelcomeReceived) {
              window.__roomInitialHeld.push([channel, event.data]);
              event.stopImmediatePropagation();
              return;
            }
            try {
              const packet = JSON.parse(event.data);
              if (packet.type === 'welcome') window.__roomWelcomeReceived = true;
            } catch (_) { /* Chunked payloads have no top-level welcome. */ }
          }, true);
          return channel;
        };
        const Native = window.RTCPeerConnection;
        window.RTCPeerConnection = class extends Native {
          constructor(config, ...rest) {
            super({ ...config, iceTransportPolicy: 'relay' }, ...rest);
            this.addEventListener('datachannel', (event) => track(event.channel), true);
          }
          createDataChannel(...args) { return track(super.createDataChannel(...args)); }
        };
      });
      const page = await context.newPage();
      page.on('pageerror', (error) => errors.push(error.message));
      pages.push(page);
      const session = await context.newCDPSession(page);
      await session.send('Debugger.enable');
      debuggers.push(session);
    }
    const [a, b] = pages;
    await a.goto(base, { waitUntil: 'domcontentloaded', timeout: 120000 });
    await activate(a);
    await a.getByRole('button', { name: 'Создать комнату', exact: true }).click();
    await name(a, 'Алина');
    await participants(a).click();
    await a.getByRole('button', { name: 'Пригласить участников', exact: true }).click();
    await a.getByRole('button', { name: 'Редактор', exact: true }).click();
    await a.getByRole('button', { name: 'Скопировать URL', exact: true }).click();
    const invite = await a.evaluate(() => navigator.clipboard.readText());
    await a.getByRole('button', { name: 'Закрыть', exact: true }).click();
    await b.goto(invite, { waitUntil: 'domcontentloaded', timeout: 120000 });
    await activate(b);
    await name(b, 'Борис');
    await connected(pages);
    await type(a, editor(a), 'До сна');
    await waitUntil(async () => JSON.stringify(await history(a)) === JSON.stringify(await history(b)),
      'Initial journals did not converge.');
    console.log('PASS: independent editors connected through real public signaling and TURN.');

    // A returning accepted member may receive welcome before its durable ACK.
    // Pause subsequent packets within the existing 12s checkpoint allowance,
    // and resume visibility while the loader must still protect that barrier.
    await b.evaluate(() => sessionStorage.setItem('mytree.resume-check.hold-initial', 'true'));
    await b.reload({ waitUntil: 'domcontentloaded' });
    await activate(b);
    await b.waitForFunction(() => window.__roomInitialHeld.length > 0, null, { timeout: 45000 });
    await visibility(b, true);
    await delay(3100);
    await visibility(b, false);
    await delay(6500);
    const waiting = await b.locator('body').ariaSnapshot();
    assert.doesNotMatch(waiting, /Не удалось открыть комнату|Связь с участником потеряна/,
      'Resume interrupted a valid initial checkpoint before its deadline.');
    assert.equal(await editor(b).count(), 0, 'Editor opened without the held durable checkpoint.');
    await b.screenshot({ path: path.join(output, 'initial-checkpoint-still-waiting.png') });
    await b.evaluate(() => window.__roomReleaseInitial());
    await editor(b).waitFor({ timeout: 15000 });
    await connected(pages);
    await waitUntil(async () => JSON.stringify(await history(a)) === JSON.stringify(await history(b)),
      'Initial journals did not converge after releasing the checkpoint.');
    console.log('PASS: wake during initial sync preserves its deadline and opens only after the durable ACK.');

    // A browser's offline emulation does not break UDP/WebRTC. Blackhole only
    // existing DataChannels while preserving their stale `open` state, as with
    // an expired NAT mapping after sleep. Newly negotiated channels are real.
    await Promise.all(pages.map((page) => page.evaluate(() => {
      for (const channel of window.__roomChannels) channel.__roomStale = true;
    })));
    await Promise.all([desktop.setOffline(true), mobile.setOffline(true)]);
    await Promise.all(pages.map((page) => page.getByRole('button', { name: /Нет подключения к сети/ }).waitFor()));
    await type(a, editor(a), 'Правка на компьютере без сети');
    await type(b, editor(b), 'Правка на телефоне без сети');
    const split = await Promise.all(pages.map(history));
    assert.notDeepEqual(split[0], split[1]);
    await Promise.all(pages.map((page) => visibility(page, true)));
    await Promise.all(debuggers.map((session) => session.send('Debugger.pause')));
    await delay(4500);
    // Network returns while JS is still suspended, as with a sleeping device.
    await Promise.all([desktop.setOffline(false), mobile.setOffline(false)]);
    const start = Date.now();
    await Promise.all(debuggers.map((session) => session.send('Debugger.resume')));
    await Promise.all(pages.map((page) => visibility(page, false)));
    await connected(pages, recoveryMs);
    await waitUntil(async () => JSON.stringify(await history(a)) === JSON.stringify(await history(b)),
      'Divergent offline journals did not converge after resume.', recoveryMs);
    await connected(pages, recoveryMs);
    const elapsed = Date.now() - start;
    assert.ok(elapsed < recoveryMs, `Resume recovery exceeded ${recoveryMs}ms: ${elapsed}ms.`);
    const merged = await history(a);
    for (const entries of split) {
      for (const edit of entries) assert.ok(merged.some((value) => JSON.stringify(value) === JSON.stringify(edit)),
        `Lost durable edit ${edit.id} after resume.`);
    }
    console.log(`PASS: both suspended clients reconnect and merge complete journals in ${elapsed}ms.`);

    // A short healthy background/foreground cycle must preserve working channels.
    let sockets = 0;
    for (const page of pages) page.on('websocket', () => sockets++);
    await Promise.all(pages.map((page) => visibility(page, true)));
    await delay(500);
    await Promise.all(pages.map((page) => visibility(page, false)));
    await delay(1500);
    await connected(pages, 10000);
    assert.equal(sockets, 0, 'A healthy short visibility cycle recreated signaling sockets.');
    await type(b, editor(b), 'После пробуждения');
    await waitUntil(async () => JSON.stringify(await history(a)) === JSON.stringify(await history(b)),
      'Live synchronization failed after the healthy visibility cycle.');
    await b.screenshot({ path: path.join(output, 'resumed-mobile.png') });
    await participants(b).click();
    await b.getByRole('heading', { name: 'Участники', exact: true }).waitFor();
    await b.waitForTimeout(400);
    await b.screenshot({ path: path.join(output, 'resumed-participants-mobile.png') });
    assert.deepEqual(errors, []);
    console.log('PASS: healthy channels survive quick visibility changes; subsequent edits synchronize.');
    console.log('Browser errors:', JSON.stringify(errors));
  } catch (error) {
    console.error(error.stack);
    for (const session of debuggers) await session.send('Debugger.resume').catch(() => {});
    for (const [index, page] of pages.entries()) {
      console.error(`Page ${index + 1}:`, await page.locator('body').ariaSnapshot().catch(() => 'unavailable'));
      await page.screenshot({ path: path.join(output, `failure-${index + 1}.png`) }).catch(() => {});
    }
    console.error('Browser errors:', JSON.stringify(errors));
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})().catch((error) => { console.error(error.stack); process.exitCode = 1; });
