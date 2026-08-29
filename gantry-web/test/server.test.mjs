import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import http from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { createGantryServer } from '../server.mjs';

const LINK_KEY = 'GW1-0123456789abcdefghijklmnopqrstuvwxyz-TEST';
const SETUP_TOKEN = 'setup-token-with-more-than-24-characters';

async function fixture() {
  const dataDir = await mkdtemp(path.join(tmpdir(), 'gantry-web-test-'));
  const server = await createGantryServer({ dataDir, setupToken: SETUP_TOKEN, snapshotTTL: 45 });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const base = `http://127.0.0.1:${address.port}`;
  return {
    base, dataDir,
    async close() {
      await new Promise(resolve => server.close(resolve));
      await rm(dataDir, { recursive: true, force: true });
    }
  };
}

async function request(base, route, options = {}) {
  const url = new URL(route, base);
  const body = options.body ? Buffer.from(options.body) : null;
  return new Promise((resolve, reject) => {
    const req = http.request(url, {
      method: options.method || 'GET',
      headers: {
        'Content-Type': 'application/json',
        ...(body ? { 'Content-Length': body.length } : {}),
        ...(options.headers || {})
      }
    }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        resolve({
          response: { status: response.statusCode, headers: { get: name => response.headers[name.toLowerCase()] || null } },
          body: text ? JSON.parse(text) : {}
        });
      });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function setup(base) {
  return request(base, '/api/setup', {
    method: 'POST',
    body: JSON.stringify({ setupToken: SETUP_TOKEN, linkKey: LINK_KEY, password: 'correct horse battery staple', displayName: 'Warsztat' })
  });
}

test('first setup is protected, one-shot and never stores plaintext secrets', async () => {
  const app = await fixture();
  try {
    let result = await request(app.base, '/api/setup', {
      method: 'POST', body: JSON.stringify({ setupToken: 'wrong', linkKey: LINK_KEY, password: 'correct horse battery staple' })
    });
    assert.equal(result.response.status, 401);

    result = await setup(app.base);
    assert.equal(result.response.status, 201);
    result = await setup(app.base);
    assert.equal(result.response.status, 409);

    const config = await readFile(path.join(app.dataDir, 'config.json'), 'utf8');
    assert.equal(config.includes(LINK_KEY), false);
    assert.equal(config.includes('correct horse battery staple'), false);
  } finally { await app.close(); }
});

test('publisher requires Web Link Key and dashboard requires a session', async () => {
  const app = await fixture();
  try {
    await setup(app.base);
    const example = JSON.parse(await readFile(new URL('../contract/example-snapshot.json', import.meta.url), 'utf8'));
    const deviceId = example.device.id;

    let result = await request(app.base, `/api/v1/devices/${deviceId}/snapshot`, { method: 'PUT', body: JSON.stringify(example) });
    assert.equal(result.response.status, 401);

    result = await request(app.base, `/api/v1/devices/${deviceId}/snapshot`, {
      method: 'PUT', headers: { Authorization: `Bearer ${LINK_KEY}` }, body: JSON.stringify(example)
    });
    assert.equal(result.response.status, 202);

    result = await request(app.base, '/api/v1/fleet');
    assert.equal(result.response.status, 401);

    result = await request(app.base, '/api/auth/login', { method: 'POST', body: JSON.stringify({ password: 'correct horse battery staple' }) });
    assert.equal(result.response.status, 200);
    const setCookie = result.response.headers.get('set-cookie');
    const cookie = (Array.isArray(setCookie) ? setCookie[0] : setCookie).split(';')[0];
    result = await request(app.base, '/api/v1/fleet', { headers: { Cookie: cookie } });
    assert.equal(result.response.status, 200);
    assert.equal(result.body.displayName, 'Warsztat');
    assert.equal(result.body.printers.length, 1);
    assert.equal(result.body.printers[0].name, 'X1 Carbon');
    assert.equal(result.body.printers[0].filamentGroups[0].slots[1].active, true);
  } finally { await app.close(); }
});

test('server rejects mismatched device ids and strips unknown fields', async () => {
  const app = await fixture();
  try {
    await setup(app.base);
    const example = JSON.parse(await readFile(new URL('../contract/example-snapshot.json', import.meta.url), 'utf8'));
    example.printers[0].host = '192.168.1.10';
    const result = await request(app.base, '/api/v1/devices/different-device/snapshot', {
      method: 'PUT', headers: { Authorization: `Bearer ${LINK_KEY}` }, body: JSON.stringify(example)
    });
    assert.equal(result.response.status, 422);

    const accepted = await request(app.base, `/api/v1/devices/${example.device.id}/snapshot`, {
      method: 'PUT', headers: { Authorization: `Bearer ${LINK_KEY}` }, body: JSON.stringify(example)
    });
    assert.equal(accepted.response.status, 202);
    const stored = JSON.parse(await readFile(path.join(app.dataDir, 'snapshots', `${example.device.id}.json`), 'utf8'));
    assert.equal('host' in stored.printers[0], false);
  } finally { await app.close(); }
});
