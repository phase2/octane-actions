// Stub for test-sync.sh: plays both the Actions OIDC token endpoint and a
// Coder static site, answering /_hooks/deploy with whichever response the
// test selected. Listens on 127.0.0.1 only and prints its port on stdout.
//
// Control routes (test only):
//   POST /__case        body: case name for the next /_hooks/deploy answers
//   POST /__oidc        body: ok | error | notjwt
//   GET  /__log         JSON of requests seen since the last /__log, then reset
'use strict';

const http = require('node:http');

const REQUEST_TOKEN = process.env.STUB_REQUEST_TOKEN;
const ID_TOKEN = process.env.STUB_ID_TOKEN;
const COMMIT = 'a'.repeat(40);
const OTHER = 'b'.repeat(40);

const json = (status, body) => ({ status, type: 'application/json; charset=utf-8', body: JSON.stringify(body) });
const html = (status, body, headers = {}) => ({ status, type: 'text/html', body, headers });

const CASES = {
  synced: json(200, { status: 'synced', commit: COMMIT }),
  synced_upper: json(200, { status: 'synced', commit: COMMIT.toUpperCase() }),
  mismatch: json(200, { status: 'synced', commit: OTHER }),
  synced_bad_commit: json(200, { status: 'synced', commit: 'nothex' }),
  syncing: json(202, { status: 'syncing' }),
  bad_request: json(400, { error: 'bad_request' }),
  invalid_token: json(401, { error: 'invalid_token' }),
  wrong_audience: json(403, { error: 'wrong_audience' }),
  wrong_repository: json(403, { error: 'wrong_repository' }),
  not_enabled: json(404, { error: 'not_enabled' }),
  method_not_allowed: json(405, { error: 'method_not_allowed' }),
  sync_failed: json(500, { error: 'sync_failed', detail: 'fatal: couldn\'t find remote ref prototypes-site 100%' }),
  sync_failed_inject: json(500, { error: 'sync_failed', detail: 'line one\n::error::injected\r\n::add-mask::x' }),
  sync_failed_markdown: json(500, { error: 'sync_failed', detail: '<img src=x onerror=alert(1)> **bold** [link](https://evil.example) `code`' }),
  jwks_unavailable: json(503, { error: 'jwks_unavailable' }),
  redirect_302: html(302, '<a href="/login">Found</a>', { Location: '/login' }),
  // Absolute, to another host name for the same stub, as the Site Access
  // gate does when it sends the browser to its login service.
  redirect_302_cross_host: html(302, 'Found', { Location: 'CROSS_HOST_LOGIN' }),
  auth_401_html: html(401, '<html><body>Sign in</body></html>'),
  auth_403_html: html(403, '<html><body>Forbidden</body></html>'),
  nginx_404_html: html(404, '<html><center>nginx</center></html>'),
  nginx_405_html: html(405, '<html><center>405 Not Allowed</center></html>'),
  html_200: html(200, '<html><body>index</body></html>'),
  gateway_502: html(502, '<html>Bad Gateway</html>'),
  gateway_503: html(503, '<html>Workspace is not running</html>'),
  gateway_504: html(504, '<html>Gateway Timeout</html>'),
  // JSON, but not the trigger's: right content type, unknown shape.
  foreign_json_404: json(404, { message: 'Not Found' }),
  // Our error word on the wrong status code is not ours either.
  wrong_code_json: json(500, { error: 'invalid_token' }),
  // A gateway that answers JSON while the workspace is down.
  gateway_503_json: json(503, { message: 'workspace stopped' }),
  json_array: json(200, ['synced']),
  json_broken: { status: 200, type: 'application/json', body: '{"status":"synced",' },
  slow: { ...json(200, { status: 'synced', commit: COMMIT }), delayMs: 3000 },
};

let current = 'synced';
let oidcMode = 'ok';
let log = [];

const readBody = (req) => new Promise((resolve) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
});

const server = http.createServer(async (req, res) => {
  const body = await readBody(req);
  const url = new URL(req.url, 'http://stub');

  if (url.pathname === '/__case') { current = body.trim(); res.end('ok'); return; }
  if (url.pathname === '/__oidc') { oidcMode = body.trim(); res.end('ok'); return; }
  if (url.pathname === '/__log') {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(log));
    log = [];
    return;
  }

  log.push({
    method: req.method,
    path: url.pathname,
    query: Object.fromEntries(url.searchParams),
    authorization: req.headers.authorization || '',
    bodyLength: body.length,
  });

  if (url.pathname === '/oidc') {
    if (req.headers.authorization !== `Bearer ${REQUEST_TOKEN}`) {
      res.writeHead(401).end('bad request token');
      return;
    }
    if (oidcMode === 'error') { res.writeHead(500).end('boom'); return; }
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ value: oidcMode === 'notjwt' ? 'not a jwt' : ID_TOKEN }));
    return;
  }

  if (url.pathname === '/_hooks/deploy') {
    const c = CASES[current];
    if (!c) { res.writeHead(599).end(`unknown case ${current}`); return; }
    const send = () => {
      const headers = { ...(c.headers || {}) };
      if (headers.Location === 'CROSS_HOST_LOGIN') {
        headers.Location = `http://localhost:${server.address().port}/login`;
      }
      res.writeHead(c.status, { 'Content-Type': c.type, ...headers });
      res.end(c.body);
    };
    if (c.delayMs) setTimeout(send, c.delayMs); else send();
    return;
  }

  // Anything else, including the /login a 302 points at.
  res.writeHead(200, { 'Content-Type': 'text/html' }).end('<html>login</html>');
});

server.listen(0, '127.0.0.1', () => {
  process.stdout.write(`${server.address().port}\n`);
});
