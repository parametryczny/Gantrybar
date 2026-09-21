<?php
/**
 * Skopiuj ten plik jako config.php i wpisz swoje wartości.
 * config.php nigdy nie trafia do repozytorium.
 */
return [
    // Ten sam klucz, co w Gantry: Ustawienia > Integracje > Własna strona w internecie > Klucz mostu.
    // Bez niego strona nie przyjmie danych z aplikacji, a aplikacja nie uwierzy stronie.
    'bridge_key' => 'TUTAJ-WKLEJ-KLUCZ-Z-GANTRY',

    // Hasło do strony. Wygeneruj hash i wklej go tutaj (nigdy samego hasła):
    //   php -r "echo password_hash('twoje-haslo', PASSWORD_DEFAULT), PHP_EOL;"
    'password_hash' => '$2y$10$ZAMIEN-NA-WLASNY-HASH',

    // Katalog na stan floty, kolejkę poleceń i ostatnią klatkę z kamery.
    // Domyślnie podkatalog data/ obok tych plików. Najlepiej poza katalogiem publicznym, np.
    // __DIR__ . '/../gantry-dane', jeśli hosting na to pozwala.
    'data_dir' => __DIR__ . '/data',

    // Nazwa widoczna w tytule strony.
    'title' => 'Moje drukarki',

    // Po ilu sekundach bez kontaktu z Gantry strona mówi, że dane są nieświeże.
    'stale_after' => 60,
];
