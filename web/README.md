# Gantry w internecie: strona na Twoim serwerze

Ta strona pokazuje flotę z Gantry i, jeśli tak ustawisz, pozwala nią sterować przez przeglądarkę.
Działa na zwykłym hostingu z PHP, bez bazy danych.

## Jak to działa

Gantry na komputerze co kilka sekund samo dzwoni do `api.php`: zostawia stan floty i zabiera polecenia,
które zakolejkowała strona. Cały ruch idzie **od komputera do serwera**, więc:

- na routerze nie otwierasz żadnego portu i nie potrzebujesz stałego adresu IP,
- serwer nigdy nie zna adresu drukarki ani jej kodu dostępu,
- gdy Gantry jest wyłączone, strona po prostu pokazuje, że dane są nieświeże.

Obie strony podpisują każdą paczkę wspólnym kluczem (HMAC SHA-256). Bez klucza nie da się ani podstawić
danych, ani zakolejkować polecenia.

## Instalacja, krok po kroku

1. Wrzuć zawartość katalogu `web/` na serwer, na przykład do `public_html/gantry/`.
2. Skopiuj `config.example.php` na `config.php`.
3. W Gantry otwórz Ustawienia, zakładkę Integracje, sekcję **Własna strona w internecie**.
   Przestaw „Strona może” na Tylko podgląd albo Podgląd i sterowanie. Gantry samo wygeneruje klucz.
4. Skopiuj klucz z Gantry do `config.php` jako `bridge_key`.
5. Wygeneruj hash hasła do strony i wklej go jako `password_hash`:

   ```bash
   php -r "echo password_hash('twoje-haslo', PASSWORD_DEFAULT), PHP_EOL;"
   ```

6. W Gantry wpisz pełny adres `api.php`, na przykład `https://twojastrona.pl/gantry/api.php`,
   i naciśnij **Sprawdź**. Powinno pokazać się „Wysłano N drukarek”.
7. Wejdź na `https://twojastrona.pl/gantry/`, zaloguj się hasłem i patrz na flotę.

## Wymagania

- PHP 7.4 lub nowszy, `openssl` i `hash_hmac` (są standardowo).
- HTTPS. Bez niego hasło i klucz jadą otwartym tekstem.
- Katalog na dane z prawem zapisu. Domyślnie `data/` obok plików; lepiej dać `data_dir` poza katalog
  publiczny, jeśli hosting na to pozwala.

## Bezpieczeństwo

- Hasło jest trzymane tylko jako hash, a po kilku błędnych próbach z jednego adresu strona przestaje
  sprawdzać hasło na pięć minut.
- Przełącznik w Gantry jest ostateczny: przy „Tylko podgląd” aplikacja odrzuca każde polecenie ze strony
  i pisze dlaczego, nawet gdyby ktoś przejął stronę.
- Zakresy poleceń (temperatury, wentylatory, prędkość) są sprawdzane i przycinane dwa razy: na serwerze
  i jeszcze raz w Gantry.
- Drukarki Bambu i tak przyjmują polecenia tylko w trybie Tylko LAN z Trybem deweloperskim. Strona
  pokazuje wtedy, czego nie da się zrobić, zamiast wysyłać polecenie, które przepadnie.
- Obraz z kamery jest wysyłany tylko wtedy, gdy ktoś ma stronę otwartą, i na serwerze leży jedna, wciąż
  nadpisywana klatka na drukarkę.
- Strona ma `noindex`, ale nie licz na to: adres trzymaj dla siebie.

## Pliki

| Plik | Do czego |
|---|---|
| `index.php` | logowanie i widok floty |
| `api.php` | jedno wejście: dla Gantry (podpisany POST) i dla przeglądarki |
| `lib.php` | konfiguracja, pliki ze stanem, podpisy, sesja |
| `assets/app.js` | rysowanie kart i przyciski sterowania |
| `assets/style.css` | wygląd, ten sam co karty w Gantry |
| `data/` | stan floty, kolejka, wyniki, ostatnia klatka z kamery |
