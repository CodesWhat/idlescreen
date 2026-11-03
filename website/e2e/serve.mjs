// Dependency-free static server for website/dist. It sends the headers from vercel.json: the
// site rule for every page, and the /docs rule under /docs, so the production CSP applies here.
// It serves clean URLs like cleanUrls does (/docs/studio -> docs/studio.html).
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const websiteRoot = fileURLToPath(new URL('..', import.meta.url));
const distRoot = join(websiteRoot, 'dist');
const port = Number(process.env.PORT ?? 4792);

const config = JSON.parse(readFileSync(join(websiteRoot, 'vercel.json'), 'utf8'));
const headersFor = source => Object.fromEntries(config.headers.find(entry => entry.source === source).headers.map(({ key, value }) => [key, value]));
const siteHeaders = headersFor('/((?!docs$|docs/).*)');
const docsHeaders = headersFor('/docs/:path*');

const types = {
  '.html': 'text/html; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
  '.ico': 'image/x-icon',
  '.webp': 'image/webp',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.png': 'image/png',
};

const server = createServer(async (request, response) => {
  const send = (status, body, type = 'text/plain; charset=utf-8', headers = siteHeaders) => {
    response.writeHead(status, { ...headers, 'Content-Type': type });
    response.end(request.method === 'HEAD' ? undefined : body);
  };
  try {
    const { pathname } = new URL(request.url, 'http://127.0.0.1');
    const relative = normalize(decodeURIComponent(pathname)).replace(/^[/\\]+/, '');
    const inDocs = pathname === '/docs' || pathname.startsWith('/docs/');
    const headers = inDocs ? docsHeaders : siteHeaders;
    let file = join(distRoot, relative === '' || relative.endsWith(sep) ? join(relative, 'index.html') : relative);
    if (file !== distRoot && !file.startsWith(distRoot + sep)) return send(403, 'Forbidden');
    if (inDocs && !extname(file)) {
      // cleanUrls: /docs/studio is docs/studio.html, /docs is docs/index.html.
      for (const candidate of [`${file}.html`, join(file, 'index.html'), file]) {
        if (await stat(candidate).then(info => info.isFile(), () => false)) { file = candidate; break; }
      }
    }
    send(200, await readFile(file), types[extname(file)] ?? 'application/octet-stream', headers);
  } catch {
    // A missing docs page answers with the export's own 404 page, as the docs app intends.
    const docsNotFound = await readFile(join(distRoot, 'docs', '404.html')).catch(() => null);
    if (docsNotFound && new URL(request.url, 'http://127.0.0.1').pathname.startsWith('/docs/')) {
      send(404, docsNotFound, types['.html'], docsHeaders);
    } else {
      send(404, 'Not found');
    }
  }
});

server.listen(port, '127.0.0.1');
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
