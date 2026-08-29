const $ = selector => document.querySelector(selector);
const gate = $('#gate');
const dashboard = $('#dashboard');
const setupForm = $('#setup-form');
const loginForm = $('#login-form');
const fleet = $('#fleet');
const empty = $('#empty');
const errorLabel = $('#gate-error');
let eventSource;

const stateLabels = {
  printing: 'Drukowanie', paused: 'Wstrzymano', finished: 'Zakończono', error: 'Błąd', idle: 'Gotowa', offline: 'Offline'
};

function node(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined && text !== null) element.textContent = text;
  return element;
}

async function api(url, options = {}) {
  const response = await fetch(url, { ...options, headers: { 'Content-Type': 'application/json', ...(options.headers || {}) } });
  let body = {};
  try { body = await response.json(); } catch {}
  if (!response.ok) throw Object.assign(new Error(body.error || `HTTP ${response.status}`), { status: response.status, body });
  return body;
}

function showGate(mode) {
  dashboard.hidden = true;
  gate.hidden = false;
  setupForm.hidden = mode !== 'setup';
  loginForm.hidden = mode !== 'login';
  $('#gate-title').textContent = mode === 'setup' ? 'Połącz własne Gantry' : 'Witaj ponownie';
  $('#gate-copy').textContent = mode === 'setup'
    ? 'Wklej token instalacyjny z serwera i osobny Web Link Key wygenerowany w aplikacji Gantry. Dane drukarek nie zawierają kodów dostępu.'
    : 'Panel jest prywatny. Zaloguj się hasłem ustawionym podczas pierwszego uruchomienia.';
}

function duration(seconds) {
  if (!seconds) return '—';
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.ceil((seconds % 3600) / 60);
  return `${hours ? `${hours}h ` : ''}${minutes}m`;
}

function tempItem(kind, label, value) {
  const item = node('div', `temperature ${kind}`);
  item.append(node('span', 'temp-label', label));
  const current = value?.current;
  item.append(node('span', 'temp-value', current == null ? '—' : `${Math.round(current)}°`));
  item.append(node('span', 'temp-target', value?.target == null ? ' / —' : ` / ${Math.round(value.target)}°`));
  return item;
}

function jobBento(printer) {
  const job = node('section', 'bento job');
  const top = node('div', 'job-top');
  top.append(node('span', 'state-dot'), node('span', '', stateLabels[printer.state] || printer.state));
  const layers = printer.job.totalLayers ? `${printer.job.currentLayer} / ${printer.job.totalLayers}` : '';
  top.append(node('span', 'layers', layers));
  job.append(top, node('div', 'file-name', printer.job.fileName || (printer.state === 'idle' ? 'Brak aktywnego zadania' : '—')));
  const row = node('div', 'progress-row');
  const percent = node('span', 'percent', String(Math.round(printer.job.progress || 0)));
  percent.append(node('small', '', '%'));
  row.append(percent, node('span', 'eta', `ETA ${printer.job.eta ? new Date(printer.job.eta).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '—'} · ${duration(printer.job.remainingSeconds)}`));
  job.append(row);
  const segments = node('div', 'segments');
  const on = Math.round((printer.job.progress || 0) / 100 * 32);
  for (let index = 0; index < 32; index++) segments.append(node('span', `segment${index < on ? ' on' : ''}`));
  job.append(segments);
  return job;
}

function temperatureBento(printer) {
  const grid = node('section', 'bento temperature-grid');
  const nozzles = printer.temperatures?.nozzles || [];
  nozzles.forEach((value, index) => grid.append(tempItem('nozzle', value.label ? `DYSZA ${value.label}` : 'DYSZA', value)));
  grid.append(tempItem('bed', 'STÓŁ', printer.temperatures?.bed));
  grid.append(tempItem('chamber', 'KOMORA', printer.temperatures?.chamber));
  return grid;
}

function materialBento(groups) {
  const container = node('section', 'materials');
  groups.forEach(group => {
    const box = node('div', `bento material-group${groups.length === 1 ? ' wide' : ''}`);
    const head = node('div', 'material-head');
    head.append(node('span', 'material-name', group.name || (group.kind === 'ext' ? 'EXT' : 'AMS')));
    const environment = [group.humidityPercent == null ? null : `◌ ${Math.round(group.humidityPercent)}%`, group.temperatureCelsius == null ? null : `♨ ${Math.round(group.temperatureCelsius)}°`].filter(Boolean).join('  ');
    head.append(node('span', 'material-env', environment));
    box.append(head);
    const slots = node('div', 'slots');
    slots.style.setProperty('--slot-count', Math.max(1, group.slots.length));
    group.slots.forEach(slot => {
      const item = node('div', 'slot');
      const swatch = node('div', `swatch${slot.active ? ' active' : ''}${slot.present ? '' : ' empty'}`);
      if (slot.present) swatch.style.backgroundColor = `#${slot.colorHex}`;
      swatch.title = slot.remainingPercent == null ? '' : `${Math.round(slot.remainingPercent)}%`;
      const copy = node('div', 'slot-copy');
      copy.append(node('span', 'slot-label', slot.label), node('span', 'slot-material', slot.present ? (slot.material || '—') : '—'));
      item.append(swatch, copy); slots.append(item);
    });
    box.append(slots); container.append(box);
  });
  return container;
}

function printerCard(printer) {
  const card = node('article', 'printer-card');
  card.dataset.state = printer.state;
  const head = node('header', 'card-head');
  const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  icon.setAttribute('viewBox', '0 0 24 24'); icon.setAttribute('class', 'printer-glyph'); icon.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('fill', 'currentColor'); path.setAttribute('d', 'M6 2h12v5H6V2Zm1.5 1.5v2h9v-2h-9ZM5 8h14a3 3 0 0 1 3 3v6h-4v5H6v-5H2v-6a3 3 0 0 1 3-3Zm2.5 8.5v4h9v-4h-9ZM18 11a1 1 0 1 0 0 2 1 1 0 0 0 0-2Z');
  icon.append(path);
  head.append(icon, node('span', 'printer-name', printer.name));
  if (printer.connectionType) head.append(node('span', 'connection-pill', printer.connectionType));
  head.append(node('span', 'source', printer.sourceDevice));
  card.append(head, jobBento(printer), temperatureBento(printer));
  if (printer.filamentGroups?.length) card.append(materialBento(printer.filamentGroups));
  return card;
}

function render(data) {
  $('#title').textContent = data.displayName || 'Gantry';
  const printing = data.printers.filter(p => p.state === 'printing').length;
  const online = data.printers.filter(p => p.state !== 'offline').length;
  $('#summary').textContent = `${data.printers.length} drukarek · ${online} online · ${printing} drukuje`;
  fleet.replaceChildren(...data.printers.map(printerCard));
  empty.hidden = data.printers.length > 0;
}

async function refresh() {
  try {
    const data = await api('/api/v1/fleet');
    gate.hidden = true; dashboard.hidden = false; render(data);
    return true;
  } catch (error) {
    if (error.status === 401) showGate('login');
    return false;
  }
}

function liveUpdates() {
  eventSource?.close();
  eventSource = new EventSource('/api/v1/events');
  eventSource.addEventListener('snapshot', refresh);
  eventSource.onopen = () => { $('#connection-dot').style.background = 'var(--ok)'; $('#connection-label').textContent = 'Aktualizacje na żywo'; };
  eventSource.onerror = () => { $('#connection-dot').style.background = 'var(--warning)'; $('#connection-label').textContent = 'Ponowne łączenie…'; };
}

setupForm.addEventListener('submit', async event => {
  event.preventDefault(); errorLabel.textContent = '';
  const body = Object.fromEntries(new FormData(setupForm));
  try { await api('/api/setup', { method: 'POST', body: JSON.stringify(body) }); showGate('login'); }
  catch (error) { errorLabel.textContent = error.body?.message || ({ invalid_setup_token: 'Nieprawidłowy token instalacyjny.', link_key_too_short: 'Klucz aplikacji jest zbyt krótki.', password_too_short: 'Hasło musi mieć co najmniej 10 znaków.' }[error.message] || error.message); }
});

loginForm.addEventListener('submit', async event => {
  event.preventDefault(); errorLabel.textContent = '';
  try {
    await api('/api/auth/login', { method: 'POST', body: JSON.stringify(Object.fromEntries(new FormData(loginForm))) });
    await refresh(); liveUpdates();
  } catch (error) { errorLabel.textContent = error.status === 429 ? 'Za dużo prób. Odczekaj minutę.' : 'Nieprawidłowe hasło.'; }
});

$('#logout').addEventListener('click', async () => { await api('/api/auth/logout', { method: 'POST' }); eventSource?.close(); showGate('login'); });
document.querySelectorAll('[data-density]').forEach(button => button.addEventListener('click', () => {
  document.querySelectorAll('[data-density]').forEach(item => item.classList.toggle('active', item === button));
  fleet.className = `fleet${button.dataset.density === 'normal' ? '' : ` ${button.dataset.density}`}`;
  localStorage.setItem('gantry-density', button.dataset.density);
}));

const savedDensity = localStorage.getItem('gantry-density') || 'normal';
document.querySelector(`[data-density="${savedDensity}"]`)?.click();
const status = await api('/api/setup/status');
if (!status.configured) showGate('setup');
else if (await refresh()) liveUpdates();
