const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
const { createWebServer } = require('./serve_web.cjs');

async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'mytree-web-server-test-'));
  const root = path.join(directory, 'web');
  await fs.mkdir(root);
  const source = 'const hello = "семейная история";\n'.repeat(300);
  await fs.writeFile(path.join(root, 'main.dart.js'), source);
  await fs.writeFile(path.join(root, 'index.html'), '<h1>MyTree</h1>');
  await fs.writeFile(path.join(directory, 'secret.json'), 'private fixture');
  const server = await createWebServer(root);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(directory, { recursive: true, force: true });
  });
  return { root, source, base: `http://127.0.0.1:${server.address().port}` };
}

test('compresses JavaScript with Brotli/gzip and preserves decoded bytes', async (t) => {
  const { source, base } = await fixture(t);
  for (const encoding of ['br', 'gzip']) {
    const response = await fetch(`${base}/main.dart.js`, { headers: { 'accept-encoding': encoding } });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-encoding'), encoding);
    assert.ok(Number(response.headers.get('content-length')) < Buffer.byteLength(source) / 4);
    assert.equal(await response.text(), source);
    assert.match(response.headers.get('content-type'), /javascript/);
    assert.equal(response.headers.get('vary'), 'Accept-Encoding');
  }
});

test('conditional reload uses 304, while rebuilt assets get a new ETag', async (t) => {
  const { root, base } = await fixture(t);
  const response = await fetch(`${base}/main.dart.js`, { headers: { 'accept-encoding': 'gzip' } });
  const etag = response.headers.get('etag');
  await response.arrayBuffer();
  const cached = await fetch(`${base}/main.dart.js`, { headers: { 'accept-encoding': 'gzip', 'if-none-match': etag } });
  assert.equal(cached.status, 304);
  assert.equal((await cached.arrayBuffer()).byteLength, 0);
  const weak = await fetch(`${base}/main.dart.js`, { headers: { 'accept-encoding': 'gzip', 'if-none-match': `W/${etag}` } });
  assert.equal(weak.status, 304);
  await fs.writeFile(path.join(root, 'main.dart.js'), 'new build');
  const rebuilt = await fetch(`${base}/main.dart.js`, { headers: { 'if-none-match': etag } });
  assert.equal(rebuilt.status, 200);
  assert.notEqual(rebuilt.headers.get('etag'), etag);
  assert.equal(await rebuilt.text(), 'new build');
});

test('supports root, HEAD and wasm MIME without serving outside the bundle', async (t) => {
  const { root, base } = await fixture(t);
  assert.equal(await (await fetch(base)).text(), '<h1>MyTree</h1>');
  const head = await fetch(`${base}/main.dart.js`, { method: 'HEAD', headers: { 'accept-encoding': 'gzip' } });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('content-encoding'), 'gzip');
  assert.equal((await head.arrayBuffer()).byteLength, 0);
  await fs.writeFile(path.join(root, 'renderer.wasm'), Buffer.from([0, 97, 115, 109]));
  assert.equal((await fetch(`${base}/renderer.wasm`)).headers.get('content-type'), 'application/wasm');
  assert.equal((await fetch(`${base}/missing.js`)).status, 404);
  assert.equal((await fetch(`${base}/%2e%2e%2fsecret.json`)).status, 403);
  assert.equal((await fetch(`${base}/main.dart.js`, { method: 'POST' })).status, 405);
  assert.equal((await fetch(`${base}/bad%zz`)).status, 400);
});

test('respects disabled encodings and keeps identity bytes uncompressed', async (t) => {
  const { source, base } = await fixture(t);
  const response = await fetch(`${base}/main.dart.js`, { headers: { 'accept-encoding': 'br;q=0, gzip;q=0' } });
  assert.equal(response.headers.get('content-encoding'), null);
  assert.equal(Number(response.headers.get('content-length')), Buffer.byteLength(source));
  assert.equal(await response.text(), source);
});
