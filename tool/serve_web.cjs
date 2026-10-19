const http = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { promisify } = require('node:util');
const { brotliCompress, gzip, constants } = require('node:zlib');

const brotli = promisify(brotliCompress);
const gzipAsync = promisify(gzip);
const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.wasm': 'application/wasm', '.ttf': 'font/ttf', '.otf': 'font/otf',
  '.woff2': 'font/woff2', '.ico': 'image/x-icon',
};

function encodingFor(header = '') {
  const qualities = new Map(header.split(',').map((part) => {
    const [name, ...parameters] = part.trim().split(';');
    const quality = parameters.find((value) => value.trim().startsWith('q='));
    return [name, quality ? Number(quality.trim().slice(2)) : 1];
  }));
  const quality = (name) => qualities.get(name) ?? qualities.get('*') ?? 0;
  if (quality('br') > 0 && quality('br') >= quality('gzip')) return 'br';
  return quality('gzip') > 0 ? 'gzip' : 'identity';
}

async function createWebServer(directory) {
  const root = await fs.realpath(directory);
  const cache = new Map();
  return http.createServer(async (request, response) => {
    try {
      if (!['GET', 'HEAD'].includes(request.method)) {
        response.writeHead(405, { Allow: 'GET, HEAD' }).end();
        return;
      }
      const url = new URL(request.url, 'http://localhost');
      const pathname = decodeURIComponent(url.pathname);
      if (pathname.includes('\0') || pathname.includes('\\')) {
        response.writeHead(400).end();
        return;
      }
      const candidate = path.resolve(root, `.${pathname.endsWith('/') ? `${pathname}index.html` : pathname}`);
      if (!candidate.startsWith(`${root}${path.sep}`)) {
        response.writeHead(403).end();
        return;
      }
      const file = await fs.realpath(candidate);
      if (!file.startsWith(`${root}${path.sep}`)) {
        response.writeHead(403).end();
        return;
      }
      const stat = await fs.stat(file);
      if (!stat.isFile()) {
        response.writeHead(404).end();
        return;
      }
      let asset = cache.get(file);
      if (!asset || asset.modified !== stat.mtimeMs || asset.size !== stat.size) {
        const data = await fs.readFile(file);
        asset = { modified: stat.mtimeMs, size: stat.size, data, hash: createHash('sha256').update(data).digest('hex'), variants: new Map() };
        cache.set(file, asset);
      }
      const extension = path.extname(file);
      const compressible = /\.(?:html|js|mjs|json|css|svg|wasm|ttf|otf)$/.test(extension);
      const encoding = compressible && asset.size > 1024 ? encodingFor(request.headers['accept-encoding']) : 'identity';
      const etag = `"${asset.hash}-${encoding}"`;
      response.setHeader('Content-Type', types[extension] || 'application/octet-stream');
      response.setHeader('Cache-Control', 'public, max-age=0, must-revalidate');
      response.setHeader('ETag', etag);
      response.setHeader('Vary', 'Accept-Encoding');
      response.setHeader('X-Content-Type-Options', 'nosniff');
      if ((request.headers['if-none-match'] || '').split(',').some((value) => {
        const tag = value.trim();
        return tag === '*' || tag.replace(/^W\//, '') === etag;
      })) {
        response.writeHead(304).end();
        return;
      }
      let data = asset.data;
      if (encoding !== 'identity') {
        if (!asset.variants.has(encoding)) {
          asset.variants.set(encoding, encoding === 'br'
            ? brotli(asset.data, { params: { [constants.BROTLI_PARAM_QUALITY]: 5 } })
            : gzipAsync(asset.data, { level: 6 }));
        }
        data = await asset.variants.get(encoding);
        response.setHeader('Content-Encoding', encoding);
      }
      response.setHeader('Content-Length', data.length);
      response.writeHead(200).end(request.method === 'HEAD' ? undefined : data);
    } catch (error) {
      const missing = ['ENOENT', 'ENOTDIR', 'EISDIR'].includes(error.code);
      response.writeHead(missing ? 404 : error instanceof URIError ? 400 : 500).end();
    }
  });
}

module.exports = { createWebServer };
if (require.main === module) {
  createWebServer(path.resolve(process.argv[2] || 'build/web')).then((server) => {
    const port = Number(process.argv[3] || 52173);
    server.listen(port, '127.0.0.1', () => console.log(`MyTree is served at http://127.0.0.1:${port} (compressed assets, conditional cache)`));
    for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => server.close());
  }).catch((error) => { console.error(error); process.exitCode = 1; });
}
