import http from 'node:http';
import { createHash, randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, readdir, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(ROOT, 'public');
const JSON_TYPE = 'application/json; charset=utf-8';
const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
  'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
};

function json(res, status, value, extra = {}) {
  const body = Buffer.from(JSON.stringify(value));
  res.writeHead(status, { ...SECURITY_HEADERS, 'Content-Type': JSON_TYPE, 'Content-Length': body.length, 'Cache-Control': 'no-store', ...extra });
  res.end(body);
}

function safeEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  return left.length === right.length && timingSafeEqual(left, right);
}

function tokenDigest(value) {
  return createHash('sha256').update(String(value), 'utf8').digest('hex');
}

function passwordRecord(password) {
  const salt = randomBytes(16).toString('hex');
  const hash = scryptSync(password, salt, 32).toString('hex');
  return { salt, hash };
}

function passwordMatches(password, record) {
  if (!record?.salt || !record?.hash) return false;
  return safeEqual(scryptSync(password, record.salt, 32).toString('hex'), record.hash);
}

function parseCookies(header = '') {
  return Object.fromEntries(header.split(';').map(v => v.trim()).filter(Boolean).map(part => {
    const index = part.indexOf('=');
    return index < 0 ? [part, ''] : [part.slice(0, index), decodeURIComponent(part.slice(index + 1))];
  }));
}

function readBearer(req) {
  const value = req.headers.authorization || '';
  return value.toLowerCase().startsWith('bearer ') ? value.slice(7).trim() : '';
}

function safeId(value) {
  return /^[A-Za-z0-9._-]{1,96}$/.test(value || '') ? value : null;
}

function finite(value, fallback = null) {
  return Number.isFinite(value) ? value : fallback;
}

function boundedText(value, max = 160) {
  return typeof value === 'string' ? value.slice(0, max) : '';
}

function normalizeSlot(slot = {}) {
  return {
    id: boundedText(slot.id, 32),
    label: boundedText(slot.label, 24),
    material: boundedText(slot.material, 32),
    colorHex: /^#?[0-9a-f]{6}$/i.test(slot.colorHex || '') ? String(slot.colorHex).replace('#', '').toUpperCase() : '777A78',
    remainingPercent: finite(slot.remainingPercent),
    remainingGrams: finite(slot.remainingGrams),
    active: Boolean(slot.active),
    present: slot.present !== false
  };
}

function normalizeSnapshot(raw, routeDeviceId, now = new Date()) {
  if (!raw || raw.protocolVersion !== 1 || !raw.device || !Array.isArray(raw.printers)) {
    throw new Error('Snapshot must use protocolVersion 1 and contain device + printers.');
  }
  const bodyDeviceId = safeId(raw.device.id);
  if (!bodyDeviceId || bodyDeviceId !== routeDeviceId) throw new Error('Device id does not match the URL.');
  if (raw.printers.length > 250) throw new Error('Too many printers in one snapshot.');

  return {
    protocolVersion: 1,
    generatedAt: typeof raw.generatedAt === 'string' ? raw.generatedAt : now.toISOString(),
    receivedAt: now.toISOString(),
    device: {
      id: bodyDeviceId,
      name: boundedText(raw.device.name, 80),
      platform: ['macos', 'windows', 'linux'].includes(raw.device.platform) ? raw.device.platform : 'unknown',
      appVersion: boundedText(raw.device.appVersion, 32)
    },
    printers: raw.printers.map((p, index) => ({
      id: safeId(p.id) || `${bodyDeviceId}-${index}`,
      name: boundedText(p.name, 80) || 'Drukarka',
      model: boundedText(p.model, 64),
      connectionType: boundedText(p.connectionType, 24),
      state: ['printing', 'paused', 'finished', 'error', 'idle', 'offline'].includes(p.state) ? p.state : 'offline',
      job: {
        fileName: boundedText(p.job?.fileName, 220),
        progress: Math.max(0, Math.min(100, finite(p.job?.progress, 0))),
        remainingSeconds: Math.max(0, finite(p.job?.remainingSeconds, 0)),
        eta: typeof p.job?.eta === 'string' ? p.job.eta : null,
        currentLayer: Math.max(0, finite(p.job?.currentLayer, 0)),
        totalLayers: Math.max(0, finite(p.job?.totalLayers, 0))
      },
      temperatures: {
        nozzles: Array.isArray(p.temperatures?.nozzles) ? p.temperatures.nozzles.slice(0, 2).map((n, i) => ({
          label: boundedText(n.label, 4) || (i === 0 ? '' : String(i + 1)), current: finite(n.current), target: finite(n.target)
        })) : [],
        bed: p.temperatures?.bed ? { current: finite(p.temperatures.bed.current), target: finite(p.temperatures.bed.target) } : null,
        chamber: p.temperatures?.chamber ? { current: finite(p.temperatures.chamber.current), target: finite(p.temperatures.chamber.target) } : null
      },
      filamentGroups: Array.isArray(p.filamentGroups) ? p.filamentGroups.slice(0, 8).map(group => ({
        id: boundedText(group.id, 32),
        name: boundedText(group.name, 32),
        kind: group.kind === 'ext' ? 'ext' : (group.kind === 'ams-ht' ? 'ams-ht' : 'ams'),
        humidityPercent: finite(group.humidityPercent),
        temperatureCelsius: finite(group.temperatureCelsius),
        slots: Array.isArray(group.slots) ? group.slots.slice(0, 4).map(normalizeSlot) : []
      })) : []
    }))
  };
}

async function atomicJSON(file, value) {
  const temporary = `${file}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(temporary, JSON.stringify(value, null, 2), { mode: 0o600 });
  await rename(temporary, file);
}

async function requestBody(req, maxBytes) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBytes) throw Object.assign(new Error('Request body too large.'), { status: 413 });
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw Object.assign(new Error('Invalid JSON.'), { status: 400 }); }
}

function contentType(file) {
  return file.endsWith('.html') ? 'text/html; charset=utf-8'
    : file.endsWith('.css') ? 'text/css; charset=utf-8'
      : file.endsWith('.js') ? 'text/javascript; charset=utf-8'
        : file.endsWith('.svg') ? 'image/svg+xml' : 'application/octet-stream';
}

export async function createGantryServer(options = {}) {
  const dataDir = path.resolve(options.dataDir || process.env.GANTRY_WEB_DATA_DIR || path.join(ROOT, 'data'));
  const snapshotsDir = path.join(dataDir, 'snapshots');
  const configFile = path.join(dataDir, 'config.json');
  const setupToken = options.setupToken ?? process.env.GANTRY_WEB_SETUP_TOKEN ?? '';
  const publicURL = options.publicURL ?? process.env.GANTRY_WEB_PUBLIC_URL ?? '';
  const sessionHours = Number(options.sessionHours ?? process.env.GANTRY_WEB_SESSION_HOURS ?? 12);
  const snapshotTTL = Number(options.snapshotTTL ?? process.env.GANTRY_WEB_SNAPSHOT_TTL_SECONDS ?? 45);
  const maxBody = Number(options.maxBody ?? process.env.GANTRY_WEB_MAX_BODY_BYTES ?? 1_048_576);
  const sseClients = new Set();
  const loginAttempts = new Map();

  await mkdir(snapshotsDir, { recursive: true });
  let config = existsSync(configFile) ? JSON.parse(await readFile(configFile, 'utf8')) : null;

  function sessionCookie(req) {
    const token = parseCookies(req.headers.cookie).gantry_session;
    if (!token || !config?.sessions?.[token]) return false;
    const expires = Date.parse(config.sessions[token]);
    if (!Number.isFinite(expires) || expires <= Date.now()) {
      delete config.sessions[token];
      return false;
    }
    return true;
  }

  async function saveConfig() {
    if (config) await atomicJSON(configFile, config);
  }

  function notifySnapshot(deviceId) {
    const payload = `event: snapshot\ndata: ${JSON.stringify({ deviceId, at: new Date().toISOString() })}\n\n`;
    for (const res of sseClients) res.write(payload);
  }

  async function fleetPayload() {
    const files = (await readdir(snapshotsDir)).filter(name => name.endsWith('.json'));
    const devices = [];
    const printers = new Map();
    for (const file of files) {
      try {
        const snapshot = JSON.parse(await readFile(path.join(snapshotsDir, file), 'utf8'));
        const ageSeconds = Math.max(0, (Date.now() - Date.parse(snapshot.receivedAt)) / 1000);
        const sourceOnline = ageSeconds <= snapshotTTL;
        devices.push({ ...snapshot.device, receivedAt: snapshot.receivedAt, online: sourceOnline });
        for (const printer of snapshot.printers || []) {
          const previous = printers.get(printer.id);
          if (!previous || Date.parse(snapshot.receivedAt) > Date.parse(previous.receivedAt)) {
            printers.set(printer.id, { ...printer, state: sourceOnline ? printer.state : 'offline', sourceDevice: snapshot.device.name, receivedAt: snapshot.receivedAt });
          }
        }
      } catch { /* Ignore a partially copied or manually corrupted snapshot. */ }
    }
    return { protocolVersion: 1, serverTime: new Date().toISOString(), displayName: config?.displayName || 'Gantry', devices, printers: [...printers.values()] };
  }

  async function api(req, res, url) {
    if (url.pathname === '/api/health' && req.method === 'GET') {
      return json(res, 200, { ok: true, configured: Boolean(config), version: '0.1.0' });
    }
    if (url.pathname === '/api/setup/status' && req.method === 'GET') {
      return json(res, 200, { configured: Boolean(config), requiresSetupToken: Boolean(setupToken) });
    }
    if (url.pathname === '/api/setup' && req.method === 'POST') {
      if (config) return json(res, 409, { error: 'already_configured' });
      const body = await requestBody(req, maxBody);
      if (!setupToken || !safeEqual(body.setupToken, setupToken)) return json(res, 401, { error: 'invalid_setup_token' });
      if (typeof body.linkKey !== 'string' || body.linkKey.length < 32) return json(res, 400, { error: 'link_key_too_short' });
      if (typeof body.password !== 'string' || body.password.length < 10) return json(res, 400, { error: 'password_too_short' });
      config = {
        version: 1,
        createdAt: new Date().toISOString(),
        displayName: boundedText(body.displayName, 80) || 'Gantry',
        linkKeyDigest: tokenDigest(body.linkKey),
        password: passwordRecord(body.password),
        sessions: {}
      };
      await saveConfig();
      return json(res, 201, { ok: true });
    }
    if (url.pathname === '/api/auth/login' && req.method === 'POST') {
      if (!config) return json(res, 409, { error: 'setup_required' });
      const ip = req.socket.remoteAddress || 'unknown';
      const recent = (loginAttempts.get(ip) || []).filter(time => Date.now() - time < 60_000);
      if (recent.length >= 10) return json(res, 429, { error: 'too_many_attempts' });
      const body = await requestBody(req, maxBody);
      if (!passwordMatches(body.password, config.password)) {
        recent.push(Date.now()); loginAttempts.set(ip, recent);
        return json(res, 401, { error: 'invalid_credentials' });
      }
      loginAttempts.delete(ip);
      const session = randomBytes(32).toString('base64url');
      config.sessions ||= {};
      config.sessions[session] = new Date(Date.now() + sessionHours * 3_600_000).toISOString();
      for (const [key, expiry] of Object.entries(config.sessions)) if (Date.parse(expiry) <= Date.now()) delete config.sessions[key];
      await saveConfig();
      const secure = publicURL.startsWith('https://') || req.headers['x-forwarded-proto'] === 'https';
      return json(res, 200, { ok: true }, { 'Set-Cookie': `gantry_session=${encodeURIComponent(session)}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${Math.round(sessionHours * 3600)}${secure ? '; Secure' : ''}` });
    }
    if (url.pathname === '/api/auth/logout' && req.method === 'POST') {
      const session = parseCookies(req.headers.cookie).gantry_session;
      if (config?.sessions?.[session]) { delete config.sessions[session]; await saveConfig(); }
      return json(res, 200, { ok: true }, { 'Set-Cookie': 'gantry_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0' });
    }

    const snapshotMatch = url.pathname.match(/^\/api\/v1\/devices\/([A-Za-z0-9._-]{1,96})\/snapshot$/);
    if (snapshotMatch && req.method === 'PUT') {
      if (!config || !safeEqual(tokenDigest(readBearer(req)), config.linkKeyDigest)) return json(res, 401, { error: 'invalid_link_key' });
      const body = await requestBody(req, maxBody);
      let snapshot;
      try { snapshot = normalizeSnapshot(body, snapshotMatch[1]); }
      catch (error) { return json(res, 422, { error: 'invalid_snapshot', message: error.message }); }
      await atomicJSON(path.join(snapshotsDir, `${snapshotMatch[1]}.json`), snapshot);
      notifySnapshot(snapshotMatch[1]);
      return json(res, 202, { ok: true, receivedAt: snapshot.receivedAt });
    }

    if (!sessionCookie(req)) return json(res, 401, { error: 'authentication_required' });
    if (url.pathname === '/api/v1/fleet' && req.method === 'GET') return json(res, 200, await fleetPayload());
    if (url.pathname === '/api/v1/events' && req.method === 'GET') {
      res.writeHead(200, { ...SECURITY_HEADERS, 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' });
      res.write(`event: ready\ndata: ${JSON.stringify({ at: new Date().toISOString() })}\n\n`);
      sseClients.add(res);
      req.on('close', () => sseClients.delete(res));
      return;
    }
    if (url.pathname === '/api/v1/link-key' && req.method === 'PUT') {
      const body = await requestBody(req, maxBody);
      if (typeof body.linkKey !== 'string' || body.linkKey.length < 32) return json(res, 400, { error: 'link_key_too_short' });
      config.linkKeyDigest = tokenDigest(body.linkKey);
      await saveConfig();
      return json(res, 200, { ok: true });
    }
    return json(res, 404, { error: 'not_found' });
  }

  async function staticFile(req, res, url) {
    const route = url.pathname === '/' ? '/index.html' : url.pathname;
    const requested = path.resolve(PUBLIC_DIR, `.${route}`);
    if (!requested.startsWith(PUBLIC_DIR + path.sep)) return json(res, 404, { error: 'not_found' });
    try {
      const body = await readFile(requested);
      res.writeHead(200, { ...SECURITY_HEADERS, 'Content-Type': contentType(requested), 'Content-Length': body.length, 'Cache-Control': requested.endsWith('.html') ? 'no-cache' : 'public, max-age=3600' });
      res.end(body);
    } catch { json(res, 404, { error: 'not_found' }); }
  }

  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url || '/', 'http://localhost');
      if (url.pathname.startsWith('/api/')) await api(req, res, url);
      else await staticFile(req, res, url);
    } catch (error) {
      json(res, error.status || 500, { error: error.status ? error.message : 'internal_error' });
    }
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.GANTRY_WEB_PORT || 8788);
  const host = process.env.GANTRY_WEB_HOST || '0.0.0.0';
  const server = await createGantryServer();
  server.listen(port, host, () => console.log(`Gantry Web listening on http://${host}:${port}`));
}
