'use strict';

// Read-only, real-browser existing-owner re-entry check. No journal, credential,
// URL, response body, browser trace, or storage dump is written to the report.
// Usage: node tool/check_disk_reentry.cjs <playwright-module> <token-file>
//        <base-url> <artifact-dir> [room-id]
// DISK_REENTRY_REPEATS=3 (measured reloads, after one unmeasured warmup)
// DISK_REENTRY_TIMEOUT_MS=240000; CHROME_PATH optionally overrides Chrome.
// DISK_REENTRY_VISUAL_ONLY=1 runs one separate, non-latency visual smoke.
// DISK_REENTRY_LOCAL_FONT=1 substitutes local Arial for font-CDN GETs (no CDN I/O).
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { performance } = require('node:perf_hooks');

const sha256 = value => createHash('sha256').update(value).digest('hex');
const key = value => Buffer.from(value).toString('base64url');
const round = value => Math.round(value * 10) / 10;
const canonical = value => JSON.stringify(normalize(value));
function normalize(value) {
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(k => [k, normalize(value[k])]));
  }
  return value;
}
const ordered = history => history.slice().sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const safeIdentity = value => /^[\w.:-]{1,200}$/.test(value) ? value : `sha256:${sha256(value)}`;
const providerApi = url => url.protocol === 'https:' && url.hostname === 'cloud-api.yandex.net' && !url.port;
const downloadHost = url => url.protocol === 'https:' && !url.port &&
  (url.hostname === 'downloader.disk.yandex.ru' || url.hostname.endsWith('.disk.yandex.net') ||
   url.hostname.endsWith('.storage.yandex.net'));
const forbiddenEndpoint = url => /(?:^|\/)(?:upload|publish|unpublish)(?:\/|$)/i.test(url.pathname);
const readApi = url => /^\/v1\/disk\/resources(?:\/download)?\/?$/.test(url.pathname) &&
  /^app:\/mytree(?:\/|$)/.test(url.searchParams.get('path') || '') &&
  !(url.searchParams.get('path') || '').split('/').includes('..');

const report = {
  mode: 'real-headless-existing-owner-read-only', completed: false,
  profileMode: 'one-browser-context-warmup-then-same-profile-reloads',
  policy: { remoteMethods: ['GET', 'OPTIONS'], websockets: 'blocked', mutations: 'blocked' },
  timings: {
    treeReadyMs: 'navigation to room menu visible and loading/local-copy UI gone; strict remote content observed',
    diskAcknowledgedMs: 'navigation to confirmed Disk status observed in settings (includes opening settings)',
    validatedReadyMs: 'navigation to Disk confirmation, complete canonical journal equality and screenshots',
    warmup: 'initial seeded navigation excluded from aggregate; measured runs are actual page.reload calls',
  },
  bootstrapRequests: [], runs: [], consoleErrors: [], blockedRequests: [], blockedWebSockets: 0,
};
let stage = 'arguments', browser, page, artifactDir, activeRun;
const journalFiles = new Map();

function category(url, localOrigin) {
  if (url.origin === localOrigin) return url.pathname.endsWith('/main.dart.js') ? 'local-main-bundle' : 'local-app';
  if (providerApi(url)) {
    if (url.pathname.endsWith('/download')) return 'disk-download-link';
    const diskPath = url.searchParams.get('path') || '';
    return /\/batches\/?$/.test(diskPath) ? 'disk-batch-list' : 'disk-resource-list';
  }
  return downloadHost(url) ? 'disk-download-content' : 'other-remote';
}

function summarize(requests, cutoff = Infinity) {
  const result = {};
  for (const request of requests.filter(r => r.startMs <= cutoff)) {
    const group = result[request.category] ??= { count: 0, completed: 0, failed: 0, totalMs: 0, maxMs: 0 };
    group.count++;
    if (request.durationMs !== undefined) {
      group.completed++;
      group.totalMs = round(group.totalMs + request.durationMs);
      group.maxMs = Math.max(group.maxMs, request.durationMs);
    }
    if (request.failed || request.blocked) group.failed++;
  }
  return result;
}

async function remoteGet(url, token, requestCategory) {
  let target = new URL(url);
  for (let redirects = 0; redirects <= 5; redirects++) {
    assert.ok(!target.username && !target.password && !forbiddenEndpoint(target), 'Unsafe remote target.');
    assert.ok(providerApi(target) ? readApi(target) : downloadHost(target), 'Remote target not allowlisted.');
    const start = performance.now();
    const record = { category: requestCategory, method: 'GET', startMs: round(start - report.bootstrapStarted) };
    report.bootstrapRequests.push(record);
    try {
      const response = await fetch(target, {
        method: 'GET', redirect: 'manual', signal: AbortSignal.timeout(60000),
        headers: providerApi(target) ? { Authorization: `OAuth ${token}` } : {},
      });
      record.status = response.status;
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get('location');
        assert.ok(location, 'Download redirect missing.');
        target = new URL(location, target);
        await response.body?.cancel();
        continue;
      }
      assert.equal(response.status, 200, 'Read-only bootstrap GET failed.');
      assert.ok(Number(response.headers.get('content-length') || 0) <= 64 * 1024 * 1024, 'Remote file too large.');
      const bytes = Buffer.from(await response.arrayBuffer());
      assert.ok(bytes.length <= 64 * 1024 * 1024, 'Remote file too large.');
      record.bytes = bytes.length;
      return bytes;
    } catch (error) {
      record.failed = true;
      throw error;
    } finally {
      record.durationMs = round(performance.now() - start);
    }
  }
  throw new Error('Too many download redirects.');
}

async function listDirectory(directory, token) {
  const items = [];
  for (let offset = 0; ; offset += 1000) {
    const url = new URL('https://cloud-api.yandex.net/v1/disk/resources');
    url.search = new URLSearchParams({ path: directory, limit: '1000', offset: String(offset),
      fields: '_embedded.items.name,_embedded.items.type,_embedded.total' });
    const body = JSON.parse(await remoteGet(url, token, 'disk-resource-list'));
    assert.ok(Array.isArray(body._embedded?.items), 'Invalid resource listing.');
    for (const item of body._embedded.items) {
      assert.ok(typeof item.name === 'string' && !/[\\/\u0000]/.test(item.name) &&
        !['.', '..'].includes(item.name), 'Invalid remote entry.');
      items.push(item);
    }
    if (body._embedded.items.length < 1000 || items.length >= body._embedded.total) return items;
  }
}

async function readBatch(directory, name, token) {
  const diskPath = `${directory}/${name}`;
  if (journalFiles.has(diskPath)) return journalFiles.get(diskPath);
  const url = new URL('https://cloud-api.yandex.net/v1/disk/resources/download');
  url.search = new URLSearchParams({ path: diskPath });
  const link = JSON.parse(await remoteGet(url, token, 'disk-download-link'));
  assert.equal(typeof link.href, 'string', 'Missing read-only download link.');
  const bytes = await remoteGet(link.href, token, 'disk-download-content');
  assert.equal(`${sha256(bytes)}.json`, name, 'Remote journal digest mismatch.');
  const batch = JSON.parse(bytes);
  assert.equal(batch.v, 1, 'Unsupported remote journal schema.');
  assert.ok(typeof batch.roomId === 'string' && batch.roomId.length > 0, 'Invalid room identity.');
  assert.ok(typeof batch.bindingId === 'string' && batch.bindingId.length > 0, 'Invalid binding identity.');
  assert.ok(Array.isArray(batch.history) && batch.history.length > 0, 'Invalid batch history.');
  for (const operation of batch.history) {
    assert.ok(operation && typeof operation === 'object' && !Array.isArray(operation), 'Invalid journal operation.');
    for (const field of ['id', 'kind', 'author', 'text']) {
      assert.ok(typeof operation[field] === 'string', 'Invalid operation schema.');
    }
    assert.ok(operation.id && operation.kind && operation.author, 'Missing operation identity.');
  }
  const result = { batch, file: name, bytes: bytes.length };
  journalFiles.set(diskPath, result);
  return result;
}

async function chooseRoom(token, filter) {
  const queue = [{ directory: 'app:/mytree', depth: 0 }];
  let visited = 0;
  while (queue.length) {
    const { directory, depth } = queue.shift();
    assert.ok(++visited <= 1000, 'Room enumeration limit reached.');
    const items = await listDirectory(directory, token);
    const files = items.filter(item => item.type === 'file' && /^[a-f0-9]{64}\.json$/.test(item.name))
      .sort((a, b) => a.name.localeCompare(b.name));
    if (files.length) {
      const batches = [];
      for (const file of files) batches.push(await readBatch(directory, file.name, token));
      const roomId = batches[0].batch.roomId, bindingId = batches[0].batch.bindingId;
      for (const { batch } of batches) {
        assert.equal(batch.roomId, roomId, 'Mixed room identities in journal folder.');
        assert.equal(batch.bindingId, bindingId, 'Mixed binding identities in journal folder.');
      }
      if (!filter || filter === roomId || filter === safeIdentity(roomId)) {
        const history = new Map();
        for (const { batch } of batches) for (const operation of batch.history) {
          if (history.has(operation.id)) {
            assert.equal(canonical(history.get(operation.id)), canonical(operation), 'Conflicting duplicate operation.');
          }
          history.set(operation.id, operation);
        }
        const binding = history.get(bindingId);
        assert.equal(binding?.kind, 'diskConnection', 'Binding operation missing.');
        assert.equal(JSON.parse(binding.text).action, 'connect', 'Binding is not a connection.');
        const diskOperations = [...history.values()].filter(operation => operation.kind === 'diskConnection')
          .sort((a, b) => a.clock - b.clock || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
        let active;
        for (const operation of diskOperations) {
          assert.ok(Number.isSafeInteger(operation.clock), 'Invalid Disk operation clock.');
          const payload = JSON.parse(operation.text);
          assert.ok(['connect', 'disconnect'].includes(payload.action), 'Invalid Disk operation action.');
          if (payload.action === 'connect') active ??= operation;
          else if (payload.bindingId === active?.id) active = undefined;
        }
        const bindingFolder = directory.endsWith('/batches') ? directory.split('/').at(-2) : directory.split('/').at(-1);
        const validation = { activeBindingMatches: active?.id === bindingId && bindingFolder === bindingId,
          editorOwner: [...history.values()].some(operation => operation.kind === 'participantRole' &&
            operation.targetActor === active?.author && operation.text === 'editor') };
        report.candidateValidation = validation;
        if (!validation.activeBindingMatches || !validation.editorOwner) continue;
        return { roomId, bindingId, history: ordered([...history.values()]), actor: binding.author, validation,
          files: batches.map(value => ({ file: value.file, bytes: value.bytes })), directory };
      }
    }
    if (depth < 6) {
      for (const folder of items.filter(item => item.type === 'dir').sort((a, b) => a.name.localeCompare(b.name))) {
        queue.push({ directory: `${directory}/${folder.name}`, depth: depth + 1 });
      }
    }
  }
  throw new Error('No matching existing journal room.');
}

async function saveReport() {
  if (artifactDir) await fs.writeFile(path.join(artifactDir, 'disk-reentry.json'), JSON.stringify(report, null, 2));
}

async function treeState() {
  const visible = locator => locator.first().isVisible().catch(() => false);
  return {
    roomMenu: await visible(page.getByRole('button', { name: /Меню комнаты/ })),
    localCopy: await visible(page.getByRole('button', { name: 'Открыть локальную копию', exact: true })),
    progress: await visible(page.getByRole('progressbar')),
    returnToMenu: await visible(page.getByRole('button', { name: 'Вернуться в меню', exact: true })),
    opening: await visible(page.getByText('Открываем комнату', { exact: true })),
    openFailed: await visible(page.getByText('Не удалось открыть комнату', { exact: true })),
    verifying: await visible(page.getByText('Проверяем историю на Диске…', { exact: true })),
    verificationFailed: await visible(page.getByText('Не удалось проверить историю комнаты', { exact: true })),
  };
}

async function failureState(error) {
  const message = String(error.message || ''); // Classify in memory; never store exception text.
  const failure = { stage, type: /timeout/i.test(error.name) ? 'timeout' : /strict mode violation/i.test(message)
    ? 'locator-ambiguity' : error.code === 'ERR_ASSERTION' ? 'assertion' : 'driver-error',
    elapsedMs: activeRun?.started ? round(performance.now() - activeRun.started) : undefined,
    detail: 'Exception text, URLs, credentials and journal contents suppressed.' };
  if (page && !page.isClosed()) failure.ui = await treeState();
  return failure;
}

async function main() {
  const [modulePath, tokenFile, base, output, roomFilter] = process.argv.slice(2);
  assert.ok(modulePath && tokenFile && base && output, 'Expected module, token file, base URL, artifact directory.');
  const visualOnly = process.env.DISK_REENTRY_VISUAL_ONLY === '1';
  const repeats = visualOnly ? 0 : Number(process.env.DISK_REENTRY_REPEATS || 3);
  const timeout = Number(process.env.DISK_REENTRY_TIMEOUT_MS || 240000);
  assert.ok(Number.isInteger(repeats) && (visualOnly || repeats > 0) && repeats <= 100, 'Invalid repeat count.');
  if (visualOnly) report.mode = 'real-headless-read-only-visual-smoke-not-a-latency-run';
  assert.ok(Number.isFinite(timeout) && timeout >= 1000, 'Invalid timeout.');
  const local = new URL(base);
  assert.ok(['http:', 'https:'].includes(local.protocol) &&
    ['127.0.0.1', 'localhost', '[::1]'].includes(local.hostname) &&
    !local.username && !local.password && !local.search && !local.hash, 'Expected local app URL.');
  await fs.mkdir(path.resolve(output), { recursive: false });
  artifactDir = path.resolve(output);
  const token = (await fs.readFile(tokenFile, 'utf8')).trim();
  assert.ok(token && !/\s/.test(token), 'Invalid token file.');
  report.repeats = repeats;
  report.bootstrapStarted = performance.now();
  stage = 'GET-only-bootstrap';
  const selected = await chooseRoom(token, roomFilter);
  const expectedHistory = canonical(selected.history);
  report.remote = { roomId: safeIdentity(selected.roomId), bindingId: safeIdentity(selected.bindingId),
    directorySha256: sha256(selected.directory), files: selected.files, validation: selected.validation };
  report.expectedJournal = { operationCount: selected.history.length, canonicalBytes: Buffer.byteLength(expectedHistory),
    sha256: sha256(expectedHistory), canonicalization: 'recursive-sorted-keys; operations-sorted-by-id-codepoint' };
  report.bootstrapElapsedMs = round(performance.now() - report.bootstrapStarted);
  delete report.bootstrapStarted;
  report.bootstrapSummary = summarize(report.bootstrapRequests);
  const prefix = 'mytree.room-store.v1.', rp = `${prefix}room.${key(selected.roomId)}.`;
  const credentials = JSON.stringify({ v: 1, bindingId: selected.bindingId, token });
  const seed = {
    [prefix + 'client-id']: JSON.stringify(selected.actor), [prefix + 'last-room']: JSON.stringify(selected.roomId),
    [rp + 'membership']: JSON.stringify(selected.roomId), [rp + 'disk-credentials']: credentials,
    [rp + 'disk-credentials.binding.' + key(selected.bindingId)]: credentials,
    ...Object.fromEntries(selected.history.map(operation => [rp + 'operation.' + key(operation.id), JSON.stringify(operation)])),
  };
  stage = 'launch-headless-browser';
  const { chromium } = require(path.resolve(modulePath));
  browser = await chromium.launch({ headless: true,
    executablePath: process.env.CHROME_PATH || 'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe' });
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true,
    hasTouch: true, serviceWorkers: 'block' });
  await context.routeWebSocket('**/*', socket => { report.blockedWebSockets++; socket.close(); });
  const requestRecords = new Map();
  let localFont;
  report.policy.staticResources = process.env.DISK_REENTRY_LOCAL_FONT === '1'
    ? 'renderer from local build; font-CDN responses use local Windows Arial, never remote CDN'
    : 'renderer from local build; unrelated remote resources, including font CDN, blocked';
  context.on('request', request => {
    if (!activeRun) return;
    const record = { category: category(new URL(request.url()), local.origin), method: request.method(),
      startMs: round(performance.now() - activeRun.started) };
    activeRun.requests.push(record);
    requestRecords.set(request, { record, started: performance.now() });
  });
  context.on('response', response => {
    const entry = requestRecords.get(response.request());
    if (entry) entry.record.status = response.status();
  });
  const finish = (request, failed) => {
    const entry = requestRecords.get(request);
    if (!entry) return;
    entry.record.durationMs = round(performance.now() - entry.started);
    if (failed) entry.record.failed = true;
    const timing = request.timing();
    if (timing.responseStart >= 0) entry.record.responseStartMs = round(timing.responseStart);
    if (timing.responseEnd >= 0) entry.record.responseEndMs = round(timing.responseEnd);
    requestRecords.delete(request);
  };
  context.on('requestfinished', request => finish(request, false));
  context.on('requestfailed', request => finish(request, true));
  await context.route('**/*', async route => {
    try {
    const request = route.request(), url = new URL(request.url()), method = request.method();
    let reason;
    if (url.username || url.password || forbiddenEndpoint(url)) reason = 'forbidden-endpoint';
    else if (url.origin === local.origin) {
      if (['GET', 'HEAD', 'OPTIONS'].includes(method)) return await route.continue();
      reason = 'local-non-read';
    } else if (!['GET', 'OPTIONS'].includes(method)) reason = 'remote-non-read';
    else if ((providerApi(url) && readApi(url)) || downloadHost(url)) return await route.continue();
    else {
      // Flutter may request its bundled renderer through its default CDN URL.
      // Substitute only the local build's renderer; never contact that CDN.
      const font = url.protocol === 'https:' && url.hostname === 'fonts.gstatic.com' &&
        /^\/s\/[a-z0-9_-]+\//i.test(url.pathname) && /\.(?:ttf|otf|woff2?)$/i.test(url.pathname);
      if (method === 'GET' && font && process.env.DISK_REENTRY_LOCAL_FONT === '1') {
        localFont ??= await fs.readFile(process.env.DISK_REENTRY_FONT || 'C:/Windows/Fonts/arial.ttf');
        const entry = requestRecords.get(request);
        if (entry) entry.record.category = 'local-font-substitute';
        return await route.fulfill({ status: 200, body: localFont,
          contentType: 'font/ttf', headers: { 'access-control-allow-origin': '*' } });
      }
      const renderer = url.hostname === 'www.gstatic.com' &&
        url.pathname.match(/^\/flutter-canvaskit\/[^/]+\/(.+)$/);
      if (method === 'GET' && renderer && !renderer[1].includes('..')) {
        const response = await context.request.get(new URL(`canvaskit/${renderer[1]}`, local).href,
          { maxRedirects: 0 });
        assert.equal(response.status(), 200, 'Local renderer unavailable.');
        const entry = requestRecords.get(request);
        if (entry) entry.record.category = 'local-renderer-substitute';
        return await route.fulfill({ response, headers: { ...response.headers(), 'access-control-allow-origin': '*' } });
      }
      reason = 'remote-host-not-allowlisted';
    }
    const entry = requestRecords.get(request);
    if (entry) entry.record.blocked = true;
    report.blockedRequests.push({ run: activeRun?.name || 'outside-run', category: category(url, local.origin), method, reason });
    return await route.abort('blockedbyclient');
    } catch {
      report.consoleErrors.push({ run: activeRun?.name, kind: 'route-error', text: '[redacted]' });
      await route.abort('blockedbyclient').catch(() => {});
    }
  });
  await context.addInitScript(({ origin, seed }) => {
    window.__diskReentryFirstFrame = false;
    window.addEventListener('flutter-first-frame', () => { window.__diskReentryFirstFrame = true; }, { once: true });
    if (location.origin === origin && !localStorage.getItem('disk-reentry-check-seeded')) {
      for (const [k, v] of Object.entries(seed)) localStorage.setItem(k, v);
      localStorage.setItem('disk-reentry-check-seeded', 'true');
    }
  }, { origin: local.origin, seed });
  page = await context.newPage();
  page.on('pageerror', () => report.consoleErrors.push({ run: activeRun?.name, kind: 'page-error', text: '[redacted]' }));
  page.on('console', message => {
    const rendering = /EXCEPTION CAUGHT|Another exception was thrown|RenderFlex.*overflow/i.test(message.text());
    if (message.type() === 'error' || rendering) report.consoleErrors.push({ run: activeRun?.name,
      kind: rendering ? 'flutter-error' : 'console-error', text: '[redacted]' });
  });
  const bundles = new Set(), bundleChecks = [];
  page.on('response', response => {
    if (new URL(response.url()).origin === local.origin && new URL(response.url()).pathname.endsWith('/main.dart.js') &&
        response.status() === 200) bundleChecks.push(response.body().then(bytes => bundles.add(sha256(bytes)))
          .catch(() => report.consoleErrors.push({ run: activeRun?.name, kind: 'bundle-read-error', text: '[redacted]' })));
  });
  for (let index = 0; index <= repeats; index++) {
    const run = { name: index ? `reload-${index}` : 'warmup', measured: index > 0, requests: [], started: performance.now() };
    activeRun = run;
    report.runs.push(run);
    stage = `${run.name}-fresh-strict-read`;
    try {
    if (index) await page.reload({ waitUntil: 'domcontentloaded', timeout });
    else await page.goto(base, { waitUntil: 'domcontentloaded', timeout });
    stage = `${run.name}-first-frame`;
    await page.waitForFunction(() => window.__diskReentryFirstFrame, null, { timeout });
    stage = `${run.name}-enable-semantics`;
    const placeholder = page.locator('flt-semantics-placeholder');
    if (await placeholder.count()) {
      await placeholder.evaluate(element => Object.assign(element.style, { position: 'fixed', left: '0px', top: '0px',
        width: '2px', height: '2px', transform: 'none', zIndex: '2147483647' }));
      await placeholder.click({ force: true, timeout });
    }
    const menu = page.getByRole('button', { name: /Меню комнаты/ });
    stage = `${run.name}-wait-for-actual-tree`;
    for (;;) {
      const ui = await treeState();
      const freshContent = run.requests.some(r => r.category === 'disk-download-content' && r.status === 200);
      if (ui.roomMenu && !Object.entries(ui).some(([name, visible]) => name !== 'roomMenu' && visible) && freshContent) break;
      if (performance.now() - run.started >= timeout) {
        const error = new Error('Validated tree readiness deadline exceeded.');
        error.name = 'TimeoutError';
        throw error;
      }
      await page.waitForTimeout(75);
    }
    run.treeReadyMs = round(performance.now() - run.started);
    run.preTreeRequests = summarize(run.requests, run.treeReadyMs);
    assert.ok(run.requests.some(r => r.category === 'disk-download-link' && r.status === 200), 'No fresh Disk download link before tree.');
    assert.ok(run.requests.some(r => r.category === 'disk-download-content' && r.status === 200), 'No fresh Disk content before tree.');
    stage = `${run.name}-disk-acknowledgement`;
    await menu.click({ timeout });
    await page.getByRole('menuitem', { name: 'Настройки комнаты', exact: true }).click({ timeout });
    await page.getByText('Копия на Диске подтверждена', { exact: true }).waitFor({ state: 'visible', timeout });
    run.diskAcknowledgedMs = round(performance.now() - run.started);
    const localHistory = await page.evaluate(prefix => Object.keys(localStorage).filter(k => k.startsWith(prefix))
      .map(k => JSON.parse(localStorage.getItem(k))), rp + 'operation.');
    const actualHistory = canonical(ordered(localHistory));
    run.localJournal = { operationCount: localHistory.length, sha256: sha256(actualHistory), equal: actualHistory === expectedHistory };
    assert.equal(run.localJournal.equal, true, 'Complete local journal differs from validated remote history.');
    const semantics = await page.locator('body').ariaSnapshot();
    assert.equal(semantics.includes(token), false, 'Credential visible in UI.');
    await page.screenshot({ path: path.join(artifactDir, `${run.name}-disk-confirmed.png`) });
    await page.getByRole('button', { name: 'Отмена', exact: true }).click({ timeout });
    if (visualOnly) {
      await page.getByText('Копия на Диске подтверждена', { exact: true }).first().waitFor({ state: 'hidden', timeout });
      await page.waitForTimeout(300); // Capture the tree after the closing paint, outside latency runs.
    }
    await page.screenshot({ path: path.join(artifactDir, `${run.name}-tree.png`) });
    run.validatedReadyMs = round(performance.now() - run.started);
    run.completed = true;
    } catch (error) {
      run.completed = false;
      run.failure = await failureState(error);
      await page.screenshot({ path: path.join(artifactDir, `${run.name}-failure.png`), timeout: 5000 }).catch(() => {});
      const localHistory = await page.evaluate(prefix => Object.keys(localStorage).filter(k => k.startsWith(prefix))
        .map(k => JSON.parse(localStorage.getItem(k))), rp + 'operation.').catch(() => null);
      if (localHistory) {
        const actual = canonical(ordered(localHistory));
        run.localJournal = { operationCount: localHistory.length, sha256: sha256(actual), equal: actual === expectedHistory };
      }
      // A baseline timeout is a measured RED result, not a reason to skip the
      // remaining reloads or bypass verification through the local-copy button.
    }
    run.elapsedMs = round(performance.now() - run.started);
    run.requestSummary = summarize(run.requests);
    delete run.started;
    await saveReport();
  }
  stage = 'final-validation';
  await Promise.all(bundleChecks);
  report.bundleSha256 = [...bundles];
  assert.equal(bundles.size, 1, 'Application build changed during measurement.');
  assert.equal(report.consoleErrors.filter(error => error.kind !== 'console-error').length, 0, 'Browser or Flutter error.');
  assert.equal(report.blockedRequests.filter(request => request.reason !== 'remote-host-not-allowlisted').length, 0,
    'Application attempted a forbidden endpoint or mutation.');
  const measured = report.runs.filter(run => run.measured);
  const stats = field => {
    const values = measured.map(run => run[field]).filter(Number.isFinite).sort((a, b) => a - b);
    if (!values.length) return null;
    return { minMs: values[0], medianMs: round((values[Math.floor((values.length - 1) / 2)] + values[Math.ceil((values.length - 1) / 2)]) / 2),
      meanMs: round(values.reduce((a, b) => a + b, 0) / values.length), maxMs: values.at(-1) };
  };
  report.aggregate = { attemptedReloads: measured.length, successfulReloads: measured.filter(run => run.completed).length,
    timeouts: measured.filter(run => run.failure?.type === 'timeout').length,
    treeReady: stats('treeReadyMs'), diskAcknowledged: stats('diskAcknowledgedMs'),
    validatedReady: stats('validatedReadyMs'), requests: summarize(measured.flatMap(run => run.requests)) };
  report.completed = report.runs.every(run => run.completed);
  if (!report.completed) {
    report.failure = { stage: 'measured-reentry', detail: 'One or more reloads did not reach validated readiness; no fallback clicked.' };
    process.exitCode = 1;
  }
}

main().catch(async error => {
  report.failure = await failureState(error);
  if (page && !page.isClosed() && artifactDir) {
    await page.screenshot({ path: path.join(artifactDir, 'failure.png'), timeout: 5000 }).catch(() => {});
  }
  process.exitCode = 1;
}).finally(async () => {
  if (activeRun?.started) delete activeRun.started;
  if (browser) await browser.close().catch(() => {});
  await saveReport();
  console.log(JSON.stringify({ completed: report.completed, failure: report.failure, remote: report.remote,
    expectedJournal: report.expectedJournal, bundleSha256: report.bundleSha256, aggregate: report.aggregate,
    runs: report.runs.map(run => ({ name: run.name, completed: run.completed, failure: run.failure,
      treeReadyMs: run.treeReadyMs, elapsedMs: run.elapsedMs,
      diskAcknowledgedMs: run.diskAcknowledgedMs, localJournal: run.localJournal, requests: summarize(run.requests) })),
    consoleErrorCount: report.consoleErrors.length, blockedRequestCount: report.blockedRequests.length,
    blockedWebSockets: report.blockedWebSockets }, null, 2));
}).catch(() => {
  console.error('Read-only measurement report could not be saved; sensitive diagnostics suppressed.');
  process.exitCode = 1;
});
