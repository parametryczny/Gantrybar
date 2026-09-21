/* Widok floty. Odpytuje api.php i rysuje karty w tym samym układzie, co Gantry na komputerze.
   Przyciski pojawiają się tylko wtedy, gdy Gantry jest ustawione na sterowanie, a drukarka je przyjmuje.

   Karta powstaje raz i potem jest tylko poprawiana: teksty podmieniamy w miejscu, kafelki filamentów
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

    var STATES = {
        printing: 'Drukuje', idle: 'Gotowa', paused: 'Wstrzymana',
        finished: 'Skończone', error: 'Błąd', offline: 'Offline'
    };
    var SPEEDS = { 1: 'Cicho', 2: 'Normalnie', 3: 'Szybko', 4: 'Bardzo szybko' };
    var FANS = [['part', 'Chłodzenie', 0], ['aux', 'Boczny', 1], ['chamber', 'Komora', 2]];

    var cards = {};          // numer seryjny -> { root, ... węzły do poprawiania }
    var watching = {};       // kamery, o które prosimy Gantry
    var sent = {};           // id polecenia -> numer seryjny
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

    function setText(node, value) {
        if (node.textContent !== value) { node.textContent = value; }
    }

    function setShown(node, shown) {
        var display = shown ? '' : 'none';
        if (node.style.display !== display) { node.style.display = display; }
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

    /* --- kamera: nową klatkę wstawiamy dopiero, gdy się wczyta, więc obraz nie mruga --- */
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

    /* --- sterowanie: przebudowa tylko wtedy, gdy zmienia się to, co w ogóle da się zrobić --- */
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
                var target = entry.targets[type] || 0;
                send(serial, { type: type, value: Math.max(0, target - 5) });
            }));
            var value = element('span', 'value', '—');
            row.appendChild(value);
            row.appendChild(button('+', '', function () {
                send(serial, { type: type, value: (entry.targets[type] || 0) + 5 });
            }));
            var now = element('span', 'note', '');
            row.appendChild(now);
            entry.values[type] = { value: value, now: now };
            box.appendChild(row);
        });

        entry.fanNotes = {};
        FANS.forEach(function (fan) {
            if ((printer.fans || {})[fan[0]] === null || (printer.fans || {})[fan[0]] === undefined) { return; }
            var row = element('div', 'row');
            row.appendChild(element('span', 'label', fan[1]));
            [0, 25, 50, 75, 100].forEach(function (percent) {
                row.appendChild(button(percent + '%', '', function () {
                    send(serial, { type: 'fan', index: fan[2], value: percent });
                }));
            });
            var now = element('span', 'note', '');
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
            setText(entry.fanNotes[key], value === null || value === undefined ? '' : 'teraz ' + value + '%');
        });
        if (entry.speedButtons) {
            Object.keys(entry.speedButtons).forEach(function (level) {
                entry.speedButtons[level].disabled = printer.speedLevel === Number(level);
            });
        }
    }

    /* --- kafelki filamentów: przebudowa tylko przy zmianie zawartości --- */
    function slotSignature(printer) {
        return (printer.groups || []).map(function (group) {
            return (group.slots || []).map(function (slot) {
                return [slot.label, slot.material, slot.colorHex, slot.percent, slot.grams, slot.active].join('~');
            }).join(';');
        }).join('|');
    }

    function buildSlots(entry, printer) {
        entry.slots.innerHTML = '';
        (printer.groups || []).forEach(function (group) {
            var row = element('div', 'slots');
            (group.slots || []).forEach(function (slot) {
                var chip = element('div', 'slot' + (slot.active ? ' active' : ''));
                var dot = element('span', 'dot');
                dot.style.background = '#' + String(slot.colorHex || '8E8E93').replace('#', '').slice(0, 6);
                chip.appendChild(dot);
                var parts = [slot.label];
                if (slot.material) { parts.push(slot.material); }
                if (slot.percent !== null && slot.percent !== undefined) { parts.push(slot.percent + '%'); }
                else if (slot.grams) { parts.push(slot.grams + ' g'); }
                chip.appendChild(element('span', '', parts.join(' · ')));
                row.appendChild(chip);
            });
            if (row.childNodes.length) { entry.slots.appendChild(row); }
        });
    }

    function createCard(printer) {
        var entry = { targets: {}, shotAt: 0, shotBusy: false };
        entry.root = element('article', 'card');

        var head = element('div', 'card-head');
        entry.name = element('span', 'name', printer.name);
        entry.state = element('span', 'state', '');
        head.appendChild(entry.name);
        head.appendChild(entry.state);
        entry.root.appendChild(head);

        entry.job = element('p', 'job', '');
        entry.root.appendChild(entry.job);

        entry.bar = element('div', 'bar');
        entry.fill = element('span');
        entry.bar.appendChild(entry.fill);
        entry.root.appendChild(entry.bar);

        entry.meta = element('div', 'meta');
        entry.root.appendChild(entry.meta);

        entry.slots = element('div', '');
        entry.root.appendChild(entry.slots);

        entry.shot = element('img', 'shot');
        entry.shot.alt = 'Podgląd z ' + printer.name;
        setShown(entry.shot, false);
        entry.root.appendChild(entry.shot);

        entry.controlsHolder = element('div', '');
        entry.root.appendChild(entry.controlsHolder);

        entry.note = element('p', 'note', '');
        entry.root.appendChild(entry.note);
        return entry;
    }

    function updateCard(entry, printer, mode, objects) {
        setText(entry.name, printer.name);
        setText(entry.state, STATES[printer.state] || printer.state);
        if (entry.state.className !== 'state ' + printer.state) { entry.state.className = 'state ' + printer.state; }

        setText(entry.job, printer.job || '');
        setShown(entry.job, !!printer.job);

        var running = printer.state === 'printing' || printer.state === 'paused';
        setShown(entry.bar, running);
        var width = Math.max(0, Math.min(100, printer.progress)) + '%';
        if (entry.fill.style.width !== width) { entry.fill.style.width = width; }

        var meta = [];
        if (running) {
            meta.push(printer.progress + '%');
            var left = minutes(printer.remainingMinutes);
            if (left) { meta.push(left + ' · ' + finishTime(printer.remainingMinutes)); }
            if (printer.layer && printer.totalLayers) { meta.push('warstwa ' + printer.layer + '/' + printer.totalLayers); }
        }
        if (temperature(printer.nozzle) !== null) { meta.push('dysza ' + temperature(printer.nozzle) + '°'); }
        if (temperature(printer.bed) !== null) { meta.push('stół ' + temperature(printer.bed) + '°'); }
        if (entry.metaText !== meta.join('|')) {
            entry.metaText = meta.join('|');
            entry.meta.innerHTML = '';
            meta.forEach(function (item) { entry.meta.appendChild(element('span', '', item)); });
        }

        var slots = slotSignature(printer);
        if (entry.slotText !== slots) {
            entry.slotText = slots;
            buildSlots(entry, printer);
        }

        if (printer.hasCamera) {
            watching[printer.serial] = true;
            refreshShot(entry, printer.serial);
        } else {
            setShown(entry.shot, false);
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
        entry.note.className = 'note' + (note && note.bad ? ' bad' : '');
        setShown(entry.note, !!note);
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
            // Kolejność z Gantry, bez ruszania kart, które już stoją tam, gdzie trzeba.
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
                    link.className = 'pill stale';
                    setText(link, 'Gantry milczy od ' + answer.age + ' s');
                } else {
                    link.className = 'pill live';
                    setText(link, 'na żywo · ' + answer.age + ' s temu');
                }
                draw();
            })
            .catch(function () {
                link.className = 'pill down';
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
