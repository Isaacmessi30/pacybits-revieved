import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { request } from 'node:http';
import { createTradingHTTPServer } from '../src/http-server.js';
let calls = 0;
const server = createTradingHTTPServer(async input => {
  calls++;
  return { status: 200, body: { ok: true, action: input.body.action } };
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;
after(() => new Promise(resolve => server.close(resolve)));
const headers = { 'Content-Type': 'application/json', Authorization: 'Bearer test-token' };
test('health route works without Firebase and unknown paths are not exposed', async () => {
  assert.equal((await fetch(base + '/healthz')).status, 200);
  assert.equal((await fetch(base + '/')).status, 404);
});
test('HTTP server enforces method, media type, authorization and valid JSON', async () => {
  assert.equal((await fetch(base + '/trading')).status, 405);
  assert.equal((await fetch(base + '/trading', { method: 'POST', body: '{}' })).status, 415);
  assert.equal((await fetch(base + '/trading', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })).status, 401);
  assert.equal((await fetch(base + '/trading', { method: 'POST', headers, body: '{' })).status, 400);
  assert.equal(calls, 0);
  const response = await fetch(base + '/trading', { method: 'POST', headers, body: '{"action":"register"}' });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('access-control-allow-origin'), null);
  assert.equal((await response.json()).action, 'register');
});
test('oversized bodies are rejected for both fixed and chunked transfers', async () => {
  const body = 'x'.repeat(270000);
  assert.equal((await fetch(base + '/trading', { method: 'POST', headers, body })).status, 413);
  const code = await new Promise((resolve, reject) => {
    const req = request(base + '/trading', { method: 'POST', headers }, res => {
      res.resume(); res.on('end', () => resolve(res.statusCode));
    });
    req.on('error', reject);
    req.write(body.slice(0, 130000)); req.end(body.slice(130000));
  });
  assert.equal(code, 413);
});
