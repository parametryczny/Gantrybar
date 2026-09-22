/* Karta floty na stronie: czwarty port tego samego układu, co macOS, Windows i GNU/Linux.
   Kolejność sekcji jest z kontraktu (nagłówek, wiersz stanu, pasek z metrykami, bento temperatur,
   dok filamentów), a kamera siedzi na końcu karty, bo tam jej miejsce w tej wersji.

   Karta powstaje raz i potem jest tylko poprawiana: teksty podmieniamy w miejscu, kafle filamentów
   i przyciski przebudowujemy dopiero, gdy naprawdę się zmieniły, a nową klatkę z kamery wstawiamy
   dopiero, gdy jest już wczytana. Przebudowywanie całej strony co dwie sekundy dawało miganie. */
(function () {
    'use strict';

    var fleet = document.getElementById('fleet');
    var link = document.getElementById('link');
    var modeNote = document.getElementById('mode-note');
    var csrf = fleet.dataset.csrf;

    var POLL_MS = 2500;
    var SHOT_MS = 4000;
    var SEGMENTS = 32;

    var STATES = {
        printing: 'Drukuje', idle: 'Gotowa', paused: 'Wstrzymana',
        finished: 'Skończone', error: 'Błąd', offline: 'Offline'
    };
    var SPEEDS = { 1: 'Cicho', 2: 'Normalnie', 3: 'Szybko', 4: 'Bardzo szybko' };
    var FANS = [['part', 'Chłodzenie', 0], ['aux', 'Boczny', 1], ['chamber', 'Komora', 2]];
    /* Ten sam podpis protokołu, co na karcie w aplikacji. */
    var PROTOCOLS = {
        bambu: 'MQTT', klipper: 'KLIPPER', prusa: 'PRUSALINK', snapmaker: 'HTTP',
        elegoo_cc1: 'SDCP', elegoo_cc2: 'MQTT LAN', anycubic_kobra_s1: 'HTTP'
    };
    /* Skróty nazw grup z kontraktu (filamentGroup.shortName). */
    var GROUP_NAMES = { 'AMS A': 'AMS', 'AMS HT': 'HT', 'MMU': 'MMU', 'EXT': 'EXT' };

    var ICONS = {
        printer: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M4 2h8v3H4zM2.5 6h11A1.5 1.5 0 0 1 15 7.5V11a1 1 0 0 1-1 1h-1V9H3v3H2a1 1 0 0 1-1-1V7.5A1.5 1.5 0 0 1 2.5 6zM4 10h8v4H4z"/></svg>',
        nozzle: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M3 3h10l-3.2 5.2V13l-3.6-1.6V8.2z"/></svg>',
        bed: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M8 2l6 3-6 3-6-3z"/><path d="M2 8.5l6 3 6-3"/><path d="M2 11.5l6 3 6-3"/></svg>',
        chamber: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M8 1.8l5.4 3v6.4L8 14.2 2.6 11.2V4.8z"/><path d="M2.6 4.8L8 7.8l5.4-3M8 7.8v6.4"/></svg>',
        clock: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="8" cy="8" r="6"/><path d="M8 4.6V8l2.6 1.6"/></svg>',
        layers: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M8 2l6 3-6 3-6-3z"/><path d="M2 8.5l6 3 6-3"/></svg>',
        drop: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M8 1.5s4.5 5 4.5 7.8A4.5 4.5 0 0 1 3.5 9.3C3.5 6.5 8 1.5 8 1.5z"/></svg>',
        thermometer: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M8 2.5v7"/><circle cx="8" cy="11.5" r="2.2"/></svg>'
    };

    var cards = {};
    var watching = {};
    var sent = {};
    var shownResults = {};
    var notes = {};
    var latest = null;
    var empty = null;

    function element(tag, className, content) {
        var node = document.createElement(tag);
        if (className) { node.className = className; }
        if (content !== undefined) { node.textContent = content; }
        return node;
    }

    /* Ikona jako samo SVG, z klasą na nim, a nie na opakowaniu: opakowanie zabierało regułę rozmiaru
       i drukarka w nagłówku rozdymała się na całą kartę. */
    function icon(name, className) {
        var holder = document.createElement('span');
        holder.innerHTML = ICONS[name] || '';
        var node = holder.firstChild;
        if (!node) { return holder; }
        if (className) { node.setAttribute('class', className); }
        return node;
    }

    function setText(node, value) {
        if (node.textContent !== value) { node.textContent = value; }
    }

    function setShown(node, shown) {
        var display = shown ? '' : 'none';
        if (node.style.display !== display) { node.style.display = display; }
    }

    function setClass(node, value) {
        if (node.className !== value) { node.className = value; }
    }

    function minutes(value) {
        if (!value || value < 1) { return ''; }
        var h = Math.floor(value / 60), m = value % 60;
        return (h ? h + ' h ' : '') + m + ' min';
    }

    function finishTime(value) {
        if (!value || value < 1) { return ''; }
        return new Date(Date.now() + value * 60000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }

    function temperature(value) {
        return value === null || value === undefined ? null : Math.round(value);
    }

    /* Kontrast tuszu na kaflu filamentu: reguła z kontraktu (filamentSlot.percentInSwatch.inkRule). */
    function inkFor(hex) {
        var clean = String(hex || '').replace('#', '').slice(0, 6);
        if (clean.length < 6) { return 'rgba(255,255,255,0.95)'; }
        var r = parseInt(clean.slice(0, 2), 16) / 255;
        var g = parseInt(clean.slice(2, 4), 16) / 255;
        var b = parseInt(clean.slice(4, 6), 16) / 255;
        var luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        return luma >= 0.5 ? 'rgba(0,0,0,0.82)' : 'rgba(255,255,255,0.95)';
    }

    function send(serial, command) {
        command.csrf = csrf;
        command.serial = serial;
        return fetch('api.php?action=command', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(command)
        }).then(function (response) {
            return response.json().catch(function () { return { ok: false, error: 'Serwer nie odpowiedział' }; });
        }).then(function (answer) {
            if (answer.ok && answer.id) {
                sent[answer.id] = serial;
                notes[serial] = { text: 'Wysłano, czekam na drukarkę…', bad: false };
            } else {
                notes[serial] = { text: answer.error || 'Nie udało się wysłać.', bad: true };
            }
            if (latest) { draw(); }
            refresh();
        });
    }

    function button(label, className, handler) {
        var node = element('button', 'ctl' + (className ? ' ' + className : ''), label);
        node.addEventListener('click', handler);
        return node;
    }

    function refreshShot(entry, serial) {
        if (entry.shotBusy || Date.now() - entry.shotAt < SHOT_MS) { return; }
        entry.shotBusy = true;
        var loader = new Image();
        loader.onload = function () {
            entry.shotAt = Date.now();
            entry.shotBusy = false;
            entry.shot.src = loader.src;
            setShown(entry.shot, true);
        };
        loader.onerror = function () {
            entry.shotBusy = false;
            entry.shotAt = Date.now();
            if (!entry.shot.src) { setShown(entry.shot, false); }
        };
        loader.src = 'api.php?action=camera&serial=' + encodeURIComponent(serial) + '&t=' + Date.now();
    }

    /* --- sterowanie --- */
    function controlSignature(printer, objects) {
        var list = (objects[printer.serial] || {}).objects || [];
        return [
            printer.controllable, printer.signingBlocked, printer.offersSkipping, printer.state, printer.kind,
            list.map(function (object) { return object.id + (object.skipped ? '!' : ''); }).join(',')
        ].join('|');
    }

    function buildControls(entry, printer, objects) {
        var box = element('div', 'controls');
        var serial = printer.serial;
        entry.values = {};

        var actions = element('div', 'row');
        if (printer.state === 'paused') {
            actions.appendChild(button('Wznów', 'wide', function () { send(serial, { type: 'resume' }); }));
        } else {
            actions.appendChild(button('Wstrzymaj', 'wide', function () { send(serial, { type: 'pause' }); }));
        }
        actions.appendChild(button('Zatrzymaj', 'danger', function () {
            if (window.confirm('Zatrzymać wydruk na ' + printer.name + '? Tego nie da się cofnąć.')) {
                send(serial, { type: 'stop' });
            }
        }));
        actions.appendChild(button('Światło', '', function () { send(serial, { type: 'light', value: true }); }));
        actions.appendChild(button('Ciemno', '', function () { send(serial, { type: 'light', value: false }); }));
        box.appendChild(actions);

        [['nozzle', 'Dysza'], ['bed', 'Stół']].forEach(function (pair) {
            var type = pair[0];
            var row = element('div', 'row');
            row.appendChild(element('span', 'label', pair[1]));
            row.appendChild(button('−', '', function () {
                send(serial, { type: type, value: Math.max(0, (entry.targets[type] || 0) - 5) });
            }));
            var value = element('span', 'value mono', '—');
            row.appendChild(value);
            row.appendChild(button('+', '', function () {
                send(serial, { type: type, value: (entry.targets[type] || 0) + 5 });
            }));
            var now = element('span', 'note mono', '');
            row.appendChild(now);
            entry.values[type] = { value: value, now: now };
            box.appendChild(row);
        });

        entry.fanNotes = {};
        FANS.forEach(function (fan) {
            var current = (printer.fans || {})[fan[0]];
            if (current === null || current === undefined) { return; }
            var row = element('div', 'row');
            row.appendChild(element('span', 'label', fan[1]));
            [0, 25, 50, 75, 100].forEach(function (percent) {
                row.appendChild(button(percent + '%', '', function () {
                    send(serial, { type: 'fan', index: fan[2], value: percent });
                }));
            });
            var now = element('span', 'note mono', '');
            row.appendChild(now);
            entry.fanNotes[fan[0]] = now;
            box.appendChild(row);
        });

        entry.speedButtons = null;
        if (printer.kind === 'bambu') {
            var speed = element('div', 'row');
            speed.appendChild(element('span', 'label', 'Prędkość'));
            entry.speedButtons = {};
            [1, 2, 3, 4].forEach(function (level) {
                var node = button(SPEEDS[level], '', function () { send(serial, { type: 'speed', value: level }); });
                entry.speedButtons[level] = node;
                speed.appendChild(node);
            });
            box.appendChild(speed);
        }

        if (printer.offersSkipping && (printer.state === 'printing' || printer.state === 'paused')) {
            var list = (objects[serial] || {}).objects || [];
            var ask = element('div', 'row');
            ask.appendChild(element('span', 'label', 'Obiekty'));
            ask.appendChild(button(list.length ? 'Odśwież listę' : 'Pokaż obiekty', '', function () {
                send(serial, { type: 'objects' });
            }));
            box.appendChild(ask);
            if (list.length) {
                var objectRow = element('div', 'row objects');
                list.forEach(function (object) {
                    var label = object.name || object.id;
                    var node = button(label + (object.current ? ' •' : ''), object.skipped ? 'skipped' : '', function () {
                        if (object.skipped) { return; }
                        if (window.confirm('Pominąć „' + label + '”? Tego nie da się cofnąć.')) {
                            send(serial, { type: 'skip', objects: [object.id] });
                        }
                    });
                    node.disabled = !!object.skipped;
                    objectRow.appendChild(node);
                });
                box.appendChild(objectRow);
            }
        }
        return box;
    }

    function updateControlValues(entry, printer) {
        if (!entry.values) { return; }
        entry.targets = { nozzle: temperature(printer.nozzleTarget) || 0, bed: temperature(printer.bedTarget) || 0 };
        [['nozzle', printer.nozzle, printer.nozzleTarget], ['bed', printer.bed, printer.bedTarget]].forEach(function (row) {
            var node = entry.values[row[0]];
            if (!node) { return; }
            var target = temperature(row[2]);
            setText(node.value, target === null ? '—' : target + '°');
            var current = temperature(row[1]);
            setText(node.now, current === null ? '' : 'teraz ' + current + '°');
        });
        Object.keys(entry.fanNotes || {}).forEach(function (key) {
            var value = (printer.fans || {})[key];
            setText(entry.fanNotes[key], value === null || value === undefined ? '' : value + '%');
        });
        if (entry.speedButtons) {
            Object.keys(entry.speedButtons).forEach(function (level) {
                entry.speedButtons[level].disabled = printer.speedLevel === Number(level);
            });
        }
    }

    /* --- bento temperatur --- */
    function updateBento(entry, printer) {
        var zones = [
            ['nozzle', 'nozzle', printer.nozzle, printer.nozzleTarget],
            ['bed', 'bed', printer.bed, printer.bedTarget],
            ['chamber', 'chamber', printer.chamber, null]
        ];
        var signature = zones.map(function (zone) {
            return temperature(zone[2]) + '/' + temperature(zone[3]);
        }).join('|');
        if (entry.bentoText === signature) { return; }
        entry.bentoText = signature;
        entry.bento.innerHTML = '';
        var shown = 0;
        zones.forEach(function (zone) {
            var current = temperature(zone[2]);
            // Komora pojawia się tylko wtedy, gdy drukarka ją mierzy (chamberShownOnlyIfReading).
            if (current === null && zone[0] === 'chamber') { return; }
            var node = element('div', 'zone ' + zone[1]);
            node.appendChild(icon(zone[0]));
            node.appendChild(element('span', 'value mono', current === null ? '—' : current + '°'));
            var target = temperature(zone[3]);
            if (target) { node.appendChild(element('span', 'target mono', target + '°')); }
            entry.bento.appendChild(node);
            shown += 1;
        });
        setShown(entry.bento, shown > 0);
    }

    /* --- dok filamentów --- */
    function slotSignature(printer) {
        return (printer.groups || []).map(function (group) {
            return [group.name, group.external, group.humidity, group.temp].join('~') + ':'
                + (group.slots || []).map(function (slot) {
                    return [slot.label, slot.material, slot.colorHex, slot.percent, slot.grams, slot.active].join('~');
                }).join(';');
        }).join('|');
    }

    function buildDock(entry, printer) {
        entry.dock.innerHTML = '';
        (printer.groups || []).forEach(function (group) {
            var box = element('div', 'group');
            var head = element('div', 'group-head');
            var name = group.name || '';
            head.appendChild(element('span', 'title', GROUP_NAMES[name] || name));
            if (group.humidity !== null && group.humidity !== undefined) {
                var humid = element('span', 'badge' + (group.humidity >= 40 ? ' warm' : ''));
                humid.appendChild(icon('drop'));
                humid.appendChild(element('span', '', group.humidity + '%'));
                head.appendChild(humid);
            }
            if (group.temp !== null && group.temp !== undefined && group.temp > 0) {
                var warm = element('span', 'badge temp');
                warm.appendChild(icon('thermometer'));
                warm.appendChild(element('span', '', Math.round(group.temp) + '°'));
                head.appendChild(warm);
            }
            box.appendChild(head);

            var slots = element('div', 'slots');
            var list = group.slots || [];
            list.forEach(function (slot) {
                var present = !!(slot.material || slot.percent !== null && slot.percent !== undefined || slot.grams);
                var classes = ['slot'];
                if (group.external) { classes.push('ext'); }
                if (list.length === 1) { classes.push('single'); }
                if (slot.active) { classes.push('active'); }
                if (!present) { classes.push('empty'); }
                var node = element('div', classes.join(' '));

                var swatch = element('div', 'swatch');
                var colour = '#' + String(slot.colorHex || '8E8E93').replace('#', '').slice(0, 6);
                if (present) { swatch.style.background = colour; }
                if (slot.percent !== null && slot.percent !== undefined) {
                    var percent = element('span', 'percent mono', slot.percent + '%');
                    percent.style.color = inkFor(colour);
                    swatch.appendChild(percent);
                } else if (slot.grams) {
                    var grams = element('span', 'percent mono', slot.grams + ' g');
                    grams.style.color = inkFor(colour);
                    swatch.appendChild(grams);
                }
                // Ostrzeżenie o kończącej się rolce: tylko AMS, tylko gdy naprawdę jest w slocie.
                if (present && !group.external && slot.percent !== null && slot.percent !== undefined
                        && slot.percent <= 15) {
                    swatch.appendChild(element('span', 'low'));
                }
                node.appendChild(swatch);

                var meta = element('div', 'slot-meta');
                meta.appendChild(element('span', 'id mono', slot.label || ''));
                meta.appendChild(element('span', 'material', slot.material || ''));
                node.appendChild(meta);
                slots.appendChild(node);
            });
            box.appendChild(slots);
            entry.dock.appendChild(box);
        });
        setShown(entry.dock, (printer.groups || []).length > 0);
    }

    function createCard(printer) {
        var entry = { targets: {}, shotAt: 0, shotBusy: false };
        entry.root = element('article', 'card');

        var head = element('div', 'card-head');
        head.appendChild(icon('printer', 'glyph'));
        entry.name = element('span', 'name', printer.name);
        entry.protocol = element('span', 'protocol', '');
        head.appendChild(entry.name);
        head.appendChild(entry.protocol);
        entry.root.appendChild(head);

        var status = element('div', 'status-row');
        status.appendChild(element('span', 'dot'));
        entry.state = element('span', 'state', '');
        entry.sep = element('span', 'sep', '·');
        entry.job = element('span', 'job', '');
        entry.percent = element('span', 'percent mono', '');
        status.appendChild(entry.state);
        status.appendChild(entry.sep);
        status.appendChild(entry.job);
        status.appendChild(entry.percent);
        entry.root.appendChild(status);

        entry.summary = element('div', 'summary');
        entry.bar = element('div', 'bar');
        for (var i = 0; i < SEGMENTS; i++) { entry.bar.appendChild(document.createElement('i')); }
        entry.eta = element('span', 'metric chip');
        entry.eta.appendChild(icon('clock'));
        entry.etaText = element('span', 'mono', '');
        entry.eta.appendChild(entry.etaText);
        entry.layer = element('span', 'metric');
        entry.layer.appendChild(icon('layers'));
        entry.layerText = element('span', 'mono', '');
        entry.layer.appendChild(entry.layerText);
        entry.summary.appendChild(entry.bar);
        entry.summary.appendChild(entry.eta);
        entry.summary.appendChild(entry.layer);
        entry.root.appendChild(entry.summary);

        entry.bento = element('div', 'bento');
        entry.root.appendChild(entry.bento);

        entry.dock = element('div', 'dock');
        entry.root.appendChild(entry.dock);

        entry.controlsHolder = element('div', '');
        entry.root.appendChild(entry.controlsHolder);

        entry.note = element('p', 'note', '');
        entry.note.style.margin = '0';
        entry.root.appendChild(entry.note);

        // Kamera na końcu karty.
        entry.shot = element('img', 'shot');
        entry.shot.alt = 'Podgląd z ' + printer.name;
        setShown(entry.shot, false);
        entry.root.appendChild(entry.shot);
        return entry;
    }

    function updateCard(entry, printer, mode, objects) {
        setText(entry.name, printer.name);
        setText(entry.protocol, PROTOCOLS[printer.kind] || '');

        setText(entry.state, STATES[printer.state] || printer.state);
        setClass(entry.state, 'state' + (printer.state === 'offline' ? ' stale' : ''));
        var running = printer.state === 'printing' || printer.state === 'paused';
        setText(entry.job, printer.job || '');
        setShown(entry.job, !!printer.job);
        setShown(entry.sep, !!printer.job);
        setText(entry.percent, running ? printer.progress + '%' : '');

        var active = Math.round(Math.max(0, Math.min(100, printer.progress)) / 100 * SEGMENTS);
        if (entry.barActive !== active) {
            entry.barActive = active;
            for (var i = 0; i < SEGMENTS; i++) {
                var on = i < active;
                var segment = entry.bar.childNodes[i];
                if ((segment.className === 'on') !== on) { segment.className = on ? 'on' : ''; }
            }
        }
        var eta = running ? minutes(printer.remainingMinutes) : '';
        setText(entry.etaText, eta ? eta + ' · ' + finishTime(printer.remainingMinutes) : '');
        setShown(entry.eta, !!eta);
        var layers = running && printer.layer && printer.totalLayers
            ? printer.layer + '/' + printer.totalLayers : '';
        setText(entry.layerText, layers);
        setShown(entry.layer, !!layers);
        setShown(entry.summary, running);

        updateBento(entry, printer);

        var slots = slotSignature(printer);
        if (entry.slotText !== slots) {
            entry.slotText = slots;
            buildDock(entry, printer);
        }

        var signature = mode + '|' + controlSignature(printer, objects);
        if (entry.controlText !== signature) {
            entry.controlText = signature;
            entry.controlsHolder.innerHTML = '';
            entry.values = null;
            entry.fanNotes = {};
            entry.speedButtons = null;
            if (mode === 'control' && printer.controllable) {
                entry.controlsHolder.appendChild(buildControls(entry, printer, objects));
            } else if (mode === 'control' && printer.signingBlocked) {
                entry.controlsHolder.appendChild(element('p', 'note bad',
                    'Sterowanie niemożliwe: drukarka przyjmuje tylko polecenia podpisane przez Bambu Connect. Włącz na niej tryb Tylko LAN i Tryb deweloperski.'));
            }
        }
        updateControlValues(entry, printer);

        var note = notes[printer.serial];
        setText(entry.note, note ? note.text : '');
        setClass(entry.note, 'note' + (note && note.bad ? ' bad' : ''));
        setShown(entry.note, !!note);

        if (printer.hasCamera) {
            watching[printer.serial] = true;
            refreshShot(entry, printer.serial);
        } else {
            setShown(entry.shot, false);
        }
    }

    function draw() {
        var state = latest.state || {};
        var printers = state.printers || [];
        var mode = state.mode || 'off';
        var objects = latest.objects || {};
        var seen = {};

        printers.forEach(function (printer, index) {
            var entry = cards[printer.serial];
            if (!entry) {
                entry = createCard(printer);
                cards[printer.serial] = entry;
            }
            seen[printer.serial] = true;
            if (fleet.children[index] !== entry.root) {
                fleet.insertBefore(entry.root, fleet.children[index] || null);
            }
            updateCard(entry, printer, mode, objects);
        });

        Object.keys(cards).forEach(function (serial) {
            if (!seen[serial]) {
                cards[serial].root.remove();
                delete cards[serial];
                delete watching[serial];
            }
        });

        if (!printers.length) {
            if (!empty) { empty = element('p', 'muted', 'Gantry jeszcze nic nie przysłało.'); }
            if (!empty.parentNode) { fleet.appendChild(empty); }
        } else if (empty && empty.parentNode) {
            empty.remove();
        }

        setText(modeNote, mode === 'control'
            ? 'Gantry pozwala tej stronie sterować drukarkami.'
            : 'Gantry pozwala tej stronie tylko patrzeć.');
    }

    function refresh() {
        var serials = Object.keys(watching).join(',');
        fetch('api.php?action=state&watch=' + encodeURIComponent(serials), { headers: { 'Accept': 'application/json' } })
            .then(function (response) {
                if (response.status === 401) { window.location.reload(); return null; }
                return response.json();
            })
            .then(function (answer) {
                if (!answer || !answer.ok) { throw new Error('brak odpowiedzi'); }
                latest = answer;
                (answer.results || []).forEach(function (result) {
                    if (!sent[result.id] || shownResults[result.id]) { return; }
                    shownResults[result.id] = true;
                    notes[sent[result.id]] = result.status === 'done'
                        ? { text: 'Drukarka przyjęła polecenie.', bad: false }
                        : { text: result.reason || 'Drukarka odmówiła.', bad: true };
                    delete sent[result.id];
                });
                if (answer.stale) {
                    setClass(link, 'pill stale');
                    setText(link, 'Gantry milczy od ' + answer.age + ' s');
                } else {
                    setClass(link, 'pill live');
                    setText(link, 'na żywo · ' + answer.age + ' s');
                }
                draw();
            })
            .catch(function () {
                setClass(link, 'pill down');
                setText(link, 'brak łączności ze stroną');
            });
    }

    fleet.innerHTML = '';
    refresh();
    window.setInterval(refresh, POLL_MS);
    document.addEventListener('visibilitychange', function () {
        if (!document.hidden) { refresh(); }
    });
})();
