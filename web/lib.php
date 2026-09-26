<?php
/**
 * Wspólne części strony Gantry: konfiguracja, pliki ze stanem, podpisy i sesja.
 *
 * Strona nigdy nie łączy się z drukarką ani z komputerem. Aplikacja Gantry sama dzwoni tutaj, zostawia
 * stan floty i zabiera polecenia z kolejki. Dzięki temu na routerze nie trzeba niczego otwierać, a na
 * serwerze nie ma żadnego adresu ani kodu dostępu do drukarki.
 */
declare(strict_types=1);

const GANTRY_MAX_BODY = 4 * 1024 * 1024;   // 4 MB: stan floty z jedną klatką z kamery
const GANTRY_CLOCK_SKEW = 300;             // sekundy różnicy zegarów, jakie jeszcze przyjmujemy
const GANTRY_WATCHER_TTL = 25;             // jak długo otwarta strona liczy się jako oglądająca
const GANTRY_QUEUE_TTL = 120;              // polecenie nieodebrane przez tyle sekund przepada
const GANTRY_MAX_QUEUE = 40;
const GANTRY_LOGIN_ATTEMPTS = 6;           // próby logowania w oknie poniżej
const GANTRY_LOGIN_WINDOW = 300;

function gantry_config(): array
{
    static $config = null;
    if ($config !== null) {
        return $config;
    }
    $path = __DIR__ . '/config.php';
    if (!is_file($path)) {
        gantry_fail(500, 'Brak config.php. Skopiuj config.example.php i uzupełnij.');
    }
    $config = require $path;
    foreach (['bridge_key', 'password_hash', 'data_dir'] as $key) {
        if (empty($config[$key])) {
            gantry_fail(500, "Brak ustawienia {$key} w config.php.");
        }
    }
    $config['title'] = $config['title'] ?? 'Gantry';
    $config['stale_after'] = (int) ($config['stale_after'] ?? 60);
    return $config;
}

function gantry_data_dir(): string
{
    $dir = gantry_config()['data_dir'];
    if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
        gantry_fail(500, 'Nie mogę utworzyć katalogu na dane.');
    }
    // Gdyby katalog leżał w części publicznej, zamykamy do niego drogę z przeglądarki.
    $guard = $dir . '/.htaccess';
    if (!is_file($guard)) {
        @file_put_contents($guard, "Require all denied\n<IfModule !mod_authz_core.c>\nDeny from all\n</IfModule>\n");
    }
    return $dir;
}

function gantry_path(string $name): string
{
    return gantry_data_dir() . '/' . $name;
}

function gantry_read_json(string $name, $fallback)
{
    $path = gantry_path($name);
    if (!is_file($path)) {
        return $fallback;
    }
    $raw = @file_get_contents($path);
    if ($raw === false || $raw === '') {
        return $fallback;
    }
    $value = json_decode($raw, true);
    return is_array($value) ? $value : $fallback;
}

/** Zapis przez plik tymczasowy i rename, żeby czytający nigdy nie trafił na połowę pliku. */
function gantry_write_json(string $name, $value): void
{
    $path = gantry_path($name);
    $temp = $path . '.' . getmypid() . '.tmp';
    $encoded = json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if ($encoded === false || @file_put_contents($temp, $encoded, LOCK_EX) === false) {
        return;
    }
    @chmod($temp, 0600);
    @rename($temp, $path);
}

function gantry_fail(int $code, string $message): void
{
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['ok' => false, 'error' => $message], JSON_UNESCAPED_UNICODE);
    exit;
}

function gantry_json(array $payload): void
{
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode(['ok' => true] + $payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

/**
 * Czy to naprawdę Gantry. Podpis liczymy z dokładnie tych bajtów, które przyszły, więc nikt po drodze
 * nie dopisze drukarki ani nie zmieni temperatury.
 */
function gantry_signature_ok(string $raw): bool
{
    $sent = $_SERVER['HTTP_X_GANTRY_SIGNATURE'] ?? '';
    if ($sent === '' || strlen($sent) !== 64) {
        return false;
    }
    $expected = hash_hmac('sha256', $raw, gantry_config()['bridge_key']);
    return hash_equals($expected, strtolower($sent));
}

function gantry_session(): void
{
    if (session_status() === PHP_SESSION_ACTIVE) {
        return;
    }
    $secure = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
        || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
    session_set_cookie_params([
        'lifetime' => 0,
        'path' => '/',
        'httponly' => true,
        'samesite' => 'Lax',
        'secure' => $secure,
    ]);
    session_name('gantry');
    session_start();
}

function gantry_logged_in(): bool
{
    gantry_session();
    return !empty($_SESSION['gantry_ok']);
}

function gantry_csrf(): string
{
    gantry_session();
    if (empty($_SESSION['gantry_csrf'])) {
        $_SESSION['gantry_csrf'] = bin2hex(random_bytes(16));
    }
    return $_SESSION['gantry_csrf'];
}

function gantry_csrf_ok(?string $token): bool
{
    gantry_session();
    return is_string($token) && !empty($_SESSION['gantry_csrf']) && hash_equals($_SESSION['gantry_csrf'], $token);
}

/**
 * Logowanie z prostym hamulcem: po kilku pomyłkach z jednego adresu strona przestaje sprawdzać hasło
 * na kilka minut, żeby nikt nie zgadywał go w nieskończoność.
 */
function gantry_login(string $password): bool
{
    gantry_session();
    $now = time();
    $ip = $_SERVER['REMOTE_ADDR'] ?? '?';
    $attempts = gantry_read_json('logins.json', []);
    $mine = array_values(array_filter($attempts[$ip] ?? [], static function ($at) use ($now) {
        return $at > $now - GANTRY_LOGIN_WINDOW;
    }));
    if (count($mine) >= GANTRY_LOGIN_ATTEMPTS) {
        return false;
    }
    if (password_verify($password, gantry_config()['password_hash'])) {
        unset($attempts[$ip]);
        gantry_write_json('logins.json', $attempts);
        session_regenerate_id(true);
        $_SESSION['gantry_ok'] = true;
        return true;
    }
    $mine[] = $now;
    $attempts[$ip] = $mine;
    gantry_write_json('logins.json', $attempts);
    return false;
}

/** Kto teraz patrzy i na które kamery czeka. Z tego Gantry wie, czy w ogóle robić zdjęcie. */
function gantry_touch_watcher(array $cameraSerials): void
{
    gantry_session();
    $now = time();
    $token = session_id();
    $watchers = gantry_read_json('watchers.json', []);
    foreach ($watchers as $id => $entry) {
        if (($entry['at'] ?? 0) < $now - GANTRY_WATCHER_TTL) {
            unset($watchers[$id]);
        }
    }
    $watchers[$token] = ['at' => $now, 'cameras' => array_values(array_slice($cameraSerials, 0, 8))];
    gantry_write_json('watchers.json', $watchers);
}

function gantry_watchers(): array
{
    $now = time();
    $watchers = gantry_read_json('watchers.json', []);
    $live = array_filter($watchers, static function ($entry) use ($now) {
        return ($entry['at'] ?? 0) >= $now - GANTRY_WATCHER_TTL;
    });
    $cameras = [];
    foreach ($live as $entry) {
        foreach ($entry['cameras'] ?? [] as $serial) {
            $cameras[$serial] = true;
        }
    }
    return ['count' => count($live), 'cameras' => array_keys($cameras)];
}

/**
 * Co strona wolno zakolejkować. Zakresy są sprawdzane tutaj i jeszcze raz w Gantry, bo o tym, co
 * dostanie drukarka, decyduje komputer przy drukarce, a nie strona w internecie.
 */
function gantry_normalize_command(array $input): ?array
{
    $types = ['pause', 'resume', 'stop', 'light', 'nozzle', 'bed', 'fan', 'speed', 'objects', 'skip'];
    $type = (string) ($input['type'] ?? '');
    $serial = (string) ($input['serial'] ?? '');
    if (!in_array($type, $types, true) || $serial === '' || strlen($serial) > 64) {
        return null;
    }
    $command = [
        'id' => bin2hex(random_bytes(8)),
        'serial' => $serial,
        'type' => $type,
        'queuedAt' => time(),
    ];
    $clamp = static function ($value, int $low, int $high): int {
        return max($low, min($high, (int) $value));
    };
    switch ($type) {
        case 'nozzle':
            $command['value'] = $clamp($input['value'] ?? 0, 0, 300);
            break;
        case 'bed':
            $command['value'] = $clamp($input['value'] ?? 0, 0, 120);
            break;
        case 'fan':
            $command['value'] = $clamp($input['value'] ?? 0, 0, 100);
            $command['index'] = $clamp($input['index'] ?? 0, 0, 2);
            break;
        case 'speed':
            $command['value'] = $clamp($input['value'] ?? 2, 1, 4);
            break;
        case 'light':
            $command['value'] = !empty($input['value']);
            break;
        case 'skip':
            $objects = array_slice(array_filter((array) ($input['objects'] ?? []), 'is_string'), 0, 64);
            if (!$objects) {
                return null;
            }
            $command['objects'] = array_values($objects);
            break;
    }
    return $command;
}
