/* Widok floty. Odpytuje api.php i rysuje karty w tym samym układzie, co Gantry na komputerze.
   Przyciski pojawiają się tylko wtedy, gdy Gantry jest ustawione na sterowanie, a drukarka je przyjmuje. */
(function () {
    'use strict';

    var fleet = document.getElementById('fleet');
    var link = document.getElementById('link');
    var modeNote = document.getElementById('mode-note');
    var csrf = fleet.dataset.csrf;

    var STATES = {
        printing: 'Drukuje', idle: 'Gotowa', paused: 'Wstrzymana',
        finished: 'Skończone', error: 'Błąd', offline: 'Offline'
    };
    var SPEEDS = { 1: 'Cicho', 2: 'Normalnie', 3: 'Szybko', 4: 'Bardzo szybko' };
    var FANS = [['part', 'Chłodzenie', 0], ['aux', 'Boczny', 1], ['chamber', 'Komora', 2]];

    /* Karty, które mają otwarty podgląd. Tylko o te kamery prosimy Gantry. */
    var watching = {};
    /* Co wysłaliśmy i na co jeszcze czekamy: id polecenia -> numer seryjny. */
    var sent = {};
    var notes = {};
    var shownResults = {};

    function text(value) {
        return String(value === null || value === undefined ? '' : value);
    }

    function minutes(value) {
        if (!value || value < 1) { return ''; }
        var h = Math.floor(value / 60), m = value % 60;
        return (h ? h + ' h ' : '') + m + ' min';
    }

    function finishTime(value) {
        if (!value || value < 1) { return ''; }
        var end = new Date(Date.now() + value * 60000);
        return end.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }

    function element(tag, className, content) {
        var node = document.createElement(tag);
        if (className) { node.className = className; }
        if (content !== undefined) { node.textContent = content; }
        return node;
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
            render();
            refresh();
        });
    }

    function button(label, className, handler) {
        var node = element('button', 'ctl' + (className ? ' ' + className : ''), label);
        node.addEventListener('click', handler);
        return node;
    }

    function stepper(serial, type, label, current, target, step, unit) {
        var row = element('div', 'row');
        row.appendChild(element('span', 'label', label));
        row.appendChild(button('−', '', function () {
            send(serial, { type: type, value: Math.max(0, Math.round((target || 0) - step)) });
        }));
        var shown = text(target === null || target === undefined ? '—' : Math.round(target) + unit);
        row.appendChild(element('span', 'value', shown));
        row.appendChild(button('+', '', function () {
            send(serial, { type: type, value: Math.round((target || 0) + step) });
        }));
        var now = current === null || current === undefined ? '' : 'teraz ' + Math.round(current) + unit;
        row.appendChild(element('span', 'note', now));
        return row;
    }

    function controlsFor(printer, objects) {
        var box = element('div', 'controls');
        var serial = printer.serial;

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

        box.appendChild(stepper(serial, 'nozzle', 'Dysza', printer.nozzle, printer.nozzleTarget, 5, '°'));
        box.appendChild(stepper(serial, 'bed', 'Stół', printer.bed, printer.bedTarget, 5, '°'));

        FANS.forEach(function (fan) {
            var value = (printer.fans || {})[fan[0]];
            if (value === null || value === undefined) { return; }
            var row = element('div', 'row');
            row.appendChild(element('span', 'label', fan[1]));
            [0, 25, 50, 75, 100].forEach(function (percent) {
                row.appendChild(button(percent + '%', '', function () {
                    send(serial, { type: 'fan', index: fan[2], value: percent });
                }));
            });
            row.appendChild(element('span', 'note', 'teraz ' + value + '%'));
            box.appendChild(row);
        });

        if (printer.kind === 'bambu') {
            var speed = element('div', 'row');
            speed.appendChild(element('span', 'label', 'Prędkość'));
            [1, 2, 3, 4].forEach(function (level) {
                var node = button(SPEEDS[level], '', function () { send(serial, { type: 'speed', value: level }); });
                if (printer.speedLevel === level) { node.disabled = true; }
                speed.appendChild(node);
            });
            box.appendChild(speed);
        }

        if (printer.offersSkipping && (printer.state === 'printing' || printer.state === 'paused')) {
            var list = (objects[serial] || {}).objects || [];
            var skip = element('div', 'row');
            skip.appendChild(element('span', 'label', 'Obiekty'));
            skip.appendChild(button(list.length ? 'Odśwież listę' : 'Pokaż obiekty', '', function () {
                send(serial, { type: 'objects' });
            }));
            box.appendChild(skip);
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

    function card(printer, mode, objects) {
        var node = element('article', 'card');
        node.dataset.serial = printer.serial;

        var head = element('div', 'card-head');
        head.appendChild(element('span', 'name', printer.name));
        head.appendChild(element('span', 'state ' + printer.state, STATES[printer.state] || printer.state));
        node.appendChild(head);

        if (printer.job) { node.appendChild(element('p', 'job', printer.job)); }

        if (printer.state === 'printing' || printer.state === 'paused') {
            var bar = element('div', 'bar');
            var fill = element('span');
            fill.style.width = Math.max(0, Math.min(100, printer.progress)) + '%';
            bar.appendChild(fill);
            node.appendChild(bar);
        }

        var meta = element('div', 'meta');
        if (printer.state === 'printing' || printer.state === 'paused') {
            meta.appendChild(element('span', '', printer.progress + '%'));
            var left = minutes(printer.remainingMinutes);
            if (left) { meta.appendChild(element('span', '', left + ' · ' + finishTime(printer.remainingMinutes))); }
            if (printer.layer && printer.totalLayers) {
                meta.appendChild(element('span', '', 'warstwa ' + printer.layer + '/' + printer.totalLayers));
            }
        }
        if (printer.nozzle !== null && printer.nozzle !== undefined) {
            meta.appendChild(element('span', '', 'dysza ' + Math.round(printer.nozzle) + '°'));
        }
        if (printer.bed !== null && printer.bed !== undefined) {
            meta.appendChild(element('span', '', 'stół ' + Math.round(printer.bed) + '°'));
        }
        node.appendChild(meta);

        (printer.groups || []).forEach(function (group) {
            var slots = element('div', 'slots');
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
                slots.appendChild(chip);
            });
            if (slots.childNodes.length) { node.appendChild(slots); }
        });

        if (printer.hasCamera) {
            var shot = element('img', 'shot');
            shot.alt = 'Podgląd z ' + printer.name;
            shot.loading = 'lazy';
            shot.src = 'api.php?action=camera&serial=' + encodeURIComponent(printer.serial) + '&t=' + Date.now();
            shot.addEventListener('error', function () { shot.remove(); });
            node.appendChild(shot);
            watching[printer.serial] = true;
        }

        if (mode === 'control') {
            if (printer.controllable) {
                node.appendChild(controlsFor(printer, objects));
            } else if (printer.signingBlocked) {
                node.appendChild(element('p', 'note bad', 'Sterowanie niemożliwe: drukarka przyjmuje tylko polecenia podpisane przez Bambu Connect. Włącz na niej tryb Tylko LAN i Tryb deweloperski.'));
            }
        }

        var note = notes[printer.serial];
        if (note) { node.appendChild(element('p', 'note' + (note.bad ? ' bad' : ''), note.text)); }
        return node;
    }

    var latest = null;

    function render() {
        if (!latest) { return; }
        var state = latest.state || {};
        var printers = state.printers || [];
        var mode = state.mode || 'off';
        fleet.innerHTML = '';
        if (!printers.length) {
            fleet.appendChild(element('p', 'muted', 'Gantry jeszcze nic nie przysłało.'));
        }
        printers.forEach(function (printer) {
            fleet.appendChild(card(printer, mode, latest.objects || {}));
        });
        modeNote.textContent = mode === 'control'
            ? 'Gantry pozwala tej stronie sterować drukarkami.'
            : 'Gantry pozwala tej stronie tylko patrzeć.';
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
                    link.textContent = 'Gantry milczy od ' + answer.age + ' s';
                } else {
                    link.className = 'pill live';
                    link.textContent = 'na żywo · ' + answer.age + ' s temu';
                }
                render();
            })
            .catch(function () {
                link.className = 'pill down';
                link.textContent = 'brak łączności ze stroną';
            });
    }

    refresh();
    window.setInterval(refresh, 2500);
    document.addEventListener('visibilitychange', function () {
        if (!document.hidden) { refresh(); }
    });
})();
