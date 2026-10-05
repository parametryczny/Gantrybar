# Gantry: własna strona w internecie (krok po kroku)

Flota na stronie, którą stawiasz u siebie: na własnym hostingu, pod własnym adresem, bez konta
w cudzej chmurze. Patrzysz na drukarki z telefonu, z pracy, z wakacji — a jeśli tak ustawisz,
także nimi sterujesz.

Ten przewodnik prowadzi od pustego hostingu do działającej strony i mówi, co robić, gdy coś nie
wychodzi. Opis plików i szczegóły techniczne znajdują się w pliku `README.md` wewnątrz pobranej paczki.

---

## 1. Dlaczego to jest bezpieczne (i co to znaczy)

**Gantry dzwoni do strony, a nie odwrotnie.** Aplikacja na Twoim komputerze co kilka sekund sama
łączy się z Twoim serwerem: zostawia stan floty i zabiera polecenia, które strona zakolejkowała.
Ruch idzie wyłącznie od komputera na zewnątrz. Z tego biorą się trzy rzeczy:

1. **Na routerze nie otwierasz żadnego portu.** Nie potrzebujesz stałego adresu IP ani DDNS-a.
2. **Serwer nigdy nie poznaje adresu drukarki ani jej kodu dostępu.** Dostaje gotowe liczby do
   pokazania, nie dostęp do sieci domowej. Nawet gdyby ktoś przejął hosting, do drukarek stamtąd nie
   dojdzie.
3. **Wyłączony komputer to brak nowych danych**, a nie dziura. Strona pokazuje wtedy wprost, że dane
   są nieświeże.

Każda paczka — w obie strony — jest podpisana wspólnym kluczem (HMAC SHA-256). Bez klucza nie da się
ani podstawić danych, ani zakolejkować polecenia.

> **Czego to nie zastępuje.** To nie jest tunel do sieci domowej i nie ma być. Jeśli potrzebujesz
> pełnego dostępu do drukarek z zewnątrz, użyj VPN-u (np. Tailscale) — Gantry umie z niego korzystać,
> patrz [README](../README.md#dodawanie-drukarek).

---

## 2. Czego potrzebujesz

| | |
| --- | --- |
| **Hosting** | zwykły, współdzielony wystarczy. PHP 7.4 lub nowszy, rozszerzenia `openssl` i `hash_hmac` (są standardowo). Bazy danych **nie** potrzeba. |
| **HTTPS** | wymagane. Bez niego hasło i klucz jadą przez internet otwartym tekstem. Darmowy Let's Encrypt w zupełności starczy. |
| **Miejsce** | kilka megabajtów. Z kamerą licz ~200 kB na drukarkę, wciąż nadpisywane. |
| **Komputer z Gantry** | musi być włączony, żeby dane się odświeżały. O uśpieniu niżej. |

---

## 3. Instalacja

### 3.1. Wrzuć pliki

Skopiuj **zawartość katalogu `web/`** z Gantry na serwer, na przykład do `public_html/gantry/`.
Paczka `Gantry-<wersja>-web.zip` jest do pobrania przy każdym wydaniu.

Powinno wylądować:

```
gantry/
├── index.php          logowanie i widok floty
├── api.php            jedno wejście: dla Gantry i dla przeglądarki
├── lib.php            konfiguracja, podpisy, sesja
├── config.example.php wzór pliku ustawień
├── assets/            wygląd i obsługa strony
└── data/              tworzy się samo; musi być zapisywalne
```

### 3.2. Zrób `config.php`

Skopiuj `config.example.php` na `config.php`. Ten drugi plik jest Twój i **nigdy nie trafia do
repozytorium** — siedzą w nim sekrety.

### 3.3. Włącz most w Gantry

W aplikacji: **Ustawienia → Integracje → Własna strona w internecie**.

Przestaw **„Strona może"** z `Nic (wyłączone)` na jedno z:

- **`Tylko pokazywać flotę`** — strona wyłącznie pokazuje. Każde polecenie z niej aplikacja odrzuca
  i pisze dlaczego. Od tego zacznij.
- **`Pokazywać i sterować`** — strona może też wysyłać polecenia (temperatury, wentylatory, prędkość,
  pauza/wznów/stop, światło).

Przy pierwszym włączeniu Gantry samo wygeneruje **klucz mostu**. Nie wymyślaj go sam.

### 3.4. Przepisz klucz na serwer

Skopiuj wartość z pola **„Klucz mostu"** i wklej do `config.php` jako `bridge_key`.

### 3.5. Ustaw hasło do strony

Hasło nie leży na serwerze otwartym tekstem — leży jego hash. Wygeneruj go:

```bash
php -r "echo password_hash('twoje-haslo', PASSWORD_DEFAULT), PHP_EOL;"
```

Wynik wklej do `config.php` jako `password_hash`.

> Jeśli nie masz dostępu do powłoki na hostingu, wrzuć ten jeden wiersz do tymczasowego pliku PHP,
> otwórz go w przeglądarce, przepisz wynik — i **skasuj plik**.

### 3.6. Połącz

Wróć do Gantry i w **„Adres api.php"** wpisz pełny adres, na przykład:

```
https://twojastrona.pl/gantry/api.php
```

Naciśnij **Sprawdź**. Powinno pokazać się „Wysłano N drukarek".

### 3.7. Wejdź na stronę

Otwórz `https://twojastrona.pl/gantry/`, zaloguj się hasłem i patrz na flotę.

---

## 4. Co widać na stronie

Strona to **czwarty port tej samej karty floty**, co macOS, Windows i GNU/Linux: nagłówek z nazwą
i protokołem, wiersz stanu z plikiem i procentem, pasek postępu z 32 segmentów, metryki czasu
i warstw, bento temperatur w kolorach dyszy, stołu i komory, dok filamentów z kaflami slotów,
a na dole karty kamera.

Kolory i wymiary nie są tam wpisane z ręki: powstają z tego samego kontraktu wyglądu w `design/`,
co aplikacje. Strona nie może więc „odjechać" wyglądem od programu.

**Obraz z kamery** jedzie na serwer tylko wtedy, gdy ktoś ma stronę otwartą, i na serwerze leży
jedna, wciąż nadpisywana klatka na drukarkę. Zamknięta strona to brak zdjęć na serwerze.

---

## 5. Żeby dane nie przestały przychodzić

Most działa tak długo, jak działa Gantry. Uśpiony komputer przestaje odpowiadać — i strona o tym
powie, zamiast pokazywać stare liczby jako świeże.

W tej samej zakładce Ustawień są dwa przełączniki:

- **„Nie usypiaj tego Maca, gdy most działa"** — trzyma komputer wybudzony, póki most jest włączony.
- **„Przy zamkniętej klapie"** — zamknięty MacBook zasypia mimo wszystko. Ten przycisk instaluje
  jedną regułę systemową dokładnie na to i prosi raz o hasło administratora. Gantry zdejmuje ją,
  gdy przełącznik gaśnie i gdy aplikacja się zamyka.

---

## 6. Bezpieczeństwo w praktyce

- **Hasło** jest trzymane tylko jako hash. Po sześciu błędnych próbach z jednego adresu strona
  przestaje sprawdzać hasło przez pięć minut.
- **Przełącznik w Gantry jest ostateczny.** Przy `Tylko pokazywać flotę` aplikacja odrzuca każde
  polecenie i zapisuje dlaczego — nawet gdyby ktoś przejął stronę i wysyłał poprawnie podpisane
  paczki.
- **Zakresy poleceń** (temperatury, wentylatory, prędkość) są sprawdzane i przycinane dwa razy: na
  serwerze i jeszcze raz w Gantry.
- **Drukarki Bambu** i tak przyjmują polecenia tylko w trybie Tylko LAN z Trybem deweloperskim.
  Strona pokazuje wtedy, czego nie da się zrobić, zamiast wysyłać polecenie, które przepadnie.
- **Strona ma `noindex`**, ale nie licz na to: adres trzymaj dla siebie.
- **Katalog `data/`** lepiej wynieść poza katalog publiczny (ustawienie `data_dir` w `config.php`),
  jeśli hosting na to pozwala. Domyślnie chroni go `.htaccess`, co działa na Apache, ale nie na
  każdym serwerze.

### Gdy klucz wyciekł

Naciśnij **„Nowy klucz"** w Gantry i wklej nową wartość do `config.php`. Stary klucz przestaje
działać w tej samej chwili. Przy okazji zmień hasło do strony.

---

## 7. Gdy coś nie działa

| Objaw | Co to znaczy |
| --- | --- |
| **„Sprawdź" kończy się błędem sieci** | zły adres albo brak HTTPS. Adres musi kończyć się na `api.php` i zaczynać od `https://`. |
| **Odpowiedź 403 albo „zły podpis"** | klucz w `config.php` nie jest tym z Gantry. Przepisz jeszcze raz, w całości, bez spacji na końcu. |
| **Odpowiedź 500** | najczęściej brak praw zapisu do `data/` albo PHP starszy niż 7.4. Zajrzyj do logu błędów hostingu. |
| **Strona prosi o hasło w kółko** | brak HTTPS (ciasteczko sesji nie przeżywa) albo `password_hash` wklejony niecały. |
| **Flota pusta, ale „Wysłano N drukarek"** | zalogowana sesja jest starsza niż pierwsze dane. Odśwież stronę. |
| **Dane stoją w miejscu** | komputer z Gantry śpi albo stracił sieć. Patrz punkt 5. |
| **Kamera pusta** | obraz jedzie tylko przy otwartej stronie i tylko dla drukarek z włączonym podglądem. Daj kilkanaście sekund. |
| **Sterowanie nic nie robi** | „Strona może" stoi na `Tylko pokazywać flotę`, albo drukarka Bambu nie jest w trybie Tylko LAN z Trybem deweloperskim. |

Stan mostu widać na żywo w Ustawieniach, pod polami: ostatnia wysyłka, liczba drukarek, czy ktoś
właśnie patrzy, a przy niepowodzeniu — treść błędu.

---

Zobacz też: `README.md` w pobranej paczce (pliki i szczegóły techniczne),
[telegram-setup.md](telegram-setup.md) (flota na Telegramie),
[automations.md](automations.md) (reguły i sterowanie).
