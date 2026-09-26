<?php
/**
 * Jedno wejście dla obu stron mostu.
 *
 * Aplikacja Gantry: POST z podpisanym JSON-em (action=sync). Zostawia stan floty i klatki z kamer,
 * zabiera kolejkę poleceń.
 *
 * Przeglądarka: zalogowana sesja i GET/POST z action=state, command, camera, login albo logout.
 */
declare(strict_types=1);

require __DIR__ . '/lib.php';

$action = (string) ($_GET['action'] ?? '');
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

// --- Gantry -> strona -------------------------------------------------------------------------
if ($action === '' && $method === 'POST') {
    $raw = file_get_contents('php://input', false, null, 0, GANTRY_MAX_BODY + 1);
    if ($raw === false || strlen($raw) > GANTRY_MAX_BODY) {
        gantry_fail(413, 'Za duża paczka.');
    }
    if (!gantry_signature_ok($raw)) {
        gantry_fail(401, 'Klucz mostu się nie zgadza.');
    }
    $body = json_decode($raw, true);
    if (!is_array($body) || ($body['action'] ?? '') !== 'sync') {
        gantry_fail(400, 'Nie rozumiem tej paczki.');
    }
    $sentAt = (int) ($body['sentAt'] ?? 0);
    if (abs(time() - $sentAt) > GANTRY_CLOCK_SKEW) {
        gantry_fail(400, 'Zegary komputera i serwera różnią się o więcej niż pięć minut.');
    }

    $now = time();
    gantry_write_json('state.json', [
        'receivedAt' => $now,
        'sentAt' => $sentAt,
        'device' => (string) ($body['device'] ?? ''),
        'deviceName' => (string) ($body['deviceName'] ?? ''),
        'app' => $body['app'] ?? [],
        'mode' => (string) ($body['mode'] ?? 'view'),
        'printers' => array_values((array) ($body['printers'] ?? [])),
    ]);

    // Klatki z kamer: jedna na drukarkę, nadpisywana, nigdy nie zbierana w galerię.
    foreach ((array) ($body['cameras'] ?? []) as $serial => $base64) {
        if (!is_string($serial) || !is_string($base64) || !preg_match('/^[A-Za-z0-9_-]{1,64}$/', $serial)) {
            continue;
        }
        $jpeg = base64_decode($base64, true);
        if ($jpeg !== false && strlen($jpeg) > 100 && strlen($jpeg) < 2 * 1024 * 1024) {
            @file_put_contents(gantry_path('camera-' . $serial . '.jpg'), $jpeg, LOCK_EX);
        }
    }

    // Lista obiektów wydruku, o którą strona poprosiła osobnym poleceniem.
    $objects = gantry_read_json('objects.json', []);
    foreach ((array) ($body['objects'] ?? []) as $serial => $list) {
        if (is_string($serial) && is_array($list)) {
            $objects[$serial] = ['at' => $now, 'objects' => array_values($list)];
        }
    }
    gantry_write_json('objects.json', $objects);

    // Wyniki poleceń z poprzedniej rundy: strona pokazuje je przy przycisku, który je wywołał.
    if (!empty($body['results'])) {
        $results = gantry_read_json('results.json', []);
        foreach ((array) $body['results'] as $result) {
            if (!is_array($result) || empty($result['id'])) {
                continue;
            }
            $results[] = [
                'id' => (string) $result['id'],
                'status' => (string) ($result['status'] ?? 'done'),
                'reason' => isset($result['reason']) ? (string) $result['reason'] : null,
                'at' => $now,
            ];
        }
        gantry_write_json('results.json', array_slice($results, -30));
    }

    // Kolejka: wszystko, co czeka, idzie do Gantry i znika stąd.
    $queue = gantry_read_json('queue.json', []);
    $fresh = array_values(array_filter($queue, static function ($command) use ($now) {
        return ($command['queuedAt'] ?? 0) > $now - GANTRY_QUEUE_TTL;
    }));
    gantry_write_json('queue.json', []);

    $watchers = gantry_watchers();
    gantry_json([
        'commands' => $fresh,
        'watchers' => $watchers['count'],
        'wantCameras' => $watchers['cameras'],
        'serverTime' => $now,
    ]);
}

// --- przeglądarka -----------------------------------------------------------------------------
if ($action === 'login' && $method === 'POST') {
    gantry_session();
    if (gantry_login((string) ($_POST['password'] ?? ''))) {
        header('Location: index.php');
        exit;
    }
    header('Location: index.php?blad=1');
    exit;
}

if ($action === 'logout') {
    gantry_session();
    $_SESSION = [];
    session_destroy();
    header('Location: index.php');
    exit;
}

if (!gantry_logged_in()) {
    gantry_fail(401, 'Zaloguj się.');
}

if ($action === 'state') {
    $cameras = array_filter(explode(',', (string) ($_GET['watch'] ?? '')));
    gantry_touch_watcher($cameras);
    $state = gantry_read_json('state.json', ['printers' => [], 'receivedAt' => 0, 'mode' => 'off']);
    $config = gantry_config();
    $age = time() - (int) ($state['receivedAt'] ?? 0);
    gantry_json([
        'state' => $state,
        'age' => $age,
        'stale' => $age > $config['stale_after'],
        'results' => gantry_read_json('results.json', []),
        'objects' => gantry_read_json('objects.json', []),
        'pending' => count(gantry_read_json('queue.json', [])),
    ]);
}

if ($action === 'command' && $method === 'POST') {
    $input = json_decode((string) file_get_contents('php://input'), true);
    if (!is_array($input) || !gantry_csrf_ok($input['csrf'] ?? null)) {
        gantry_fail(403, 'Odśwież stronę i spróbuj jeszcze raz.');
    }
    $state = gantry_read_json('state.json', ['mode' => 'off']);
    if (($state['mode'] ?? 'off') !== 'control') {
        gantry_fail(409, 'Gantry jest ustawione na sam podgląd.');
    }
    $command = gantry_normalize_command($input);
    if ($command === null) {
        gantry_fail(400, 'Nie znam tego polecenia.');
    }
    $queue = gantry_read_json('queue.json', []);
    if (count($queue) >= GANTRY_MAX_QUEUE) {
        gantry_fail(429, 'Za dużo poleceń naraz.');
    }
    $queue[] = $command;
    gantry_write_json('queue.json', $queue);
    gantry_json(['id' => $command['id']]);
}

if ($action === 'camera') {
    $serial = (string) ($_GET['serial'] ?? '');
    if (!preg_match('/^[A-Za-z0-9_-]{1,64}$/', $serial)) {
        gantry_fail(400, 'Zły numer seryjny.');
    }
    $path = gantry_path('camera-' . $serial . '.jpg');
    if (!is_file($path)) {
        gantry_fail(404, 'Nie ma jeszcze obrazu.');
    }
    header('Content-Type: image/jpeg');
    header('Cache-Control: no-store');
    readfile($path);
    exit;
}

gantry_fail(400, 'Nieznane żądanie.');
