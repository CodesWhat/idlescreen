// Dependency-free static server for website/dist. It sends the headers from the
// "/(.*)" rule in vercel.json, so the production CSP applies to every page here.
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const websiteRoot = fileURLToPath(new URL('..', import.meta.url));
const distRoot = join(websiteRoot, 'dist');
const port = Number(process.env.PORT ?? 4792);

const config = JSON.parse(readFileSync(join(websiteRoot, 'vercel.json'), 'utf8'));
const rule = config.headers.find(entry => entry.source === '/(.*)');
const headers = Object.fromEntries(rule.headers.map(({ key, value }) => [key, value]));

const types = {
  '.html': 'text/html; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.png': 'image/png',
};

const server = createServer(async (request, response) => {
  const send = (status, body, type = 'text/plain; charset=utf-8') => {
    response.writeHead(status, { ...headers, 'Content-Type': type });
    response.end(request.method === 'HEAD' ? undefined : body);
  };
  try {
    const { pathname } = new URL(request.url, 'http://127.0.0.1');
    const relative = normalize(decodeURIComponent(pathname)).replace(/^[/\\]+/, '');
    const file = join(distRoot, relative === '' || relative.endsWith(sep) ? join(relative, 'index.html') : relative);
    if (file !== distRoot && !file.startsWith(distRoot + sep)) return send(403, 'Forbidden');
    send(200, await readFile(file), types[extname(file)] ?? 'application/octet-stream');
  } catch {
    send(404, 'Not found');
  }
});

server.listen(port, '127.0.0.1');
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
