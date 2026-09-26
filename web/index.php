<?php
/** Strona: ekran logowania albo flota. Cała logika widoku siedzi w assets/app.js. */
declare(strict_types=1);

require __DIR__ . '/lib.php';

$config = gantry_config();
$logged = gantry_logged_in();
$csrf = $logged ? gantry_csrf() : '';
$title = $config['title'];
?>
<!doctype html>
<html lang="pl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<meta name="theme-color" content="#0E1012">
<title><?= htmlspecialchars($title, ENT_QUOTES) ?></title>
<link rel="stylesheet" href="assets/style.css?v=1">
</head>
<body>
<?php if (!$logged): ?>
<main class="gate">
    <form class="card gate-card" method="post" action="api.php?action=login">
        <h1><?= htmlspecialchars($title, ENT_QUOTES) ?></h1>
        <p class="muted">Podgląd drukarek przez Gantry.</p>
        <?php if (isset($_GET['blad'])): ?>
            <p class="error">Złe hasło albo za dużo prób. Spróbuj za chwilę.</p>
        <?php endif; ?>
        <label for="password">Hasło</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required autofocus>
        <button type="submit">Wejdź</button>
    </form>
</main>
<?php else: ?>
<header class="top">
    <div class="brand"><span class="logo">G</span><?= htmlspecialchars($title, ENT_QUOTES) ?></div>
    <div class="top-right">
        <span id="link" class="pill">łączenie…</span>
        <a class="pill button" href="api.php?action=logout">Wyloguj</a>
    </div>
</header>
<main id="fleet" class="fleet" data-csrf="<?= htmlspecialchars($csrf, ENT_QUOTES) ?>">
    <p class="muted">Wczytuję flotę…</p>
</main>
<footer class="foot">
    <span id="mode-note" class="muted"></span>
</footer>
<script src="assets/app.js?v=1"></script>
<?php endif; ?>
</body>
</html>
