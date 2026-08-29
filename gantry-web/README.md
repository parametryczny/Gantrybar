# Gantry Web

Prywatny, samodzielnie hostowany panel Gantry. Aplikacja macOS, Windows albo Linux odczytuje drukarki w sieci lokalnej i wysyła na serwer wyłącznie gotowy snapshot kafelków. Serwer **nie łączy się z drukarkami** i nigdy nie otrzymuje kodów dostępu, kluczy API ani lokalnych adresów IP.

## Gotowy model działania

```text
drukarki w LAN → aplikacja Gantry → HTTPS → Gantry Web → przeglądarka
                                      ↑
                              osobny Web Link Key
```

- panel jest tylko do odczytu;
- klucz Web Link ma być inny niż token synchronizacji LAN;
- snapshot jest nadpisywany, a nie dopisywany bez końca;
- brak kontaktu z aplikacją przez 45 sekund oznacza `offline`;
- kilka komputerów może wysyłać dane, a nowsza kopia tej samej drukarki wygrywa.

## Wymagania

- serwer VPS z Dockerem i Docker Compose;
- domena wskazująca na serwer;
- HTTPS przez Caddy, Nginx albo usługę reverse proxy;
- otwarte porty 80/443. Port 8788 pozostaje przypięty wyłącznie do `127.0.0.1`.

## Instalacja na VPS

1. Skopiuj cały katalog `gantry-web` na serwer, np. do `/opt/gantry-web`.
2. W katalogu serwera wykonaj:

   ```bash
   cp .env.example .env
   openssl rand -hex 24
   ```

3. W `.env` ustaw:

   ```dotenv
   GANTRY_WEB_PUBLIC_URL=https://gantry.twoja-domena.pl
   GANTRY_WEB_SETUP_TOKEN=wynik-poprzedniego-polecenia
   ```

4. Uruchom usługę:

   ```bash
   docker compose up -d --build
   curl http://127.0.0.1:8788/api/health
   ```

5. Skonfiguruj HTTPS. Dla Caddy skopiuj zawartość `Caddyfile.example`, zmień domenę i przeładuj Caddy.
6. W aplikacji Gantry wygeneruj **Gantry Web Link Key**. Wejdź na domenę, wklej token instalacyjny z `.env`, Web Link Key z aplikacji i ustaw hasło panelu.
7. W aplikacji wpisz publiczny adres, np. `https://gantry.twoja-domena.pl`, włącz wysyłanie i użyj „Testuj połączenie”.

## Instalacja bez Dockera

Wymagany jest Node.js 20 lub nowszy:

```bash
cp .env.example .env
set -a
. ./.env
set +a
node server.mjs
```

Proces należy uruchamiać przez systemd lub inny supervisor. Nadal wymagany jest reverse proxy z HTTPS.

## Aktualizacja

Przed podmianą zachowaj katalog `data/`. Następnie wgraj nowe pliki i wykonaj:

```bash
docker compose up -d --build
```

Konfiguracja, hash klucza i ostatnie snapshoty znajdują się w `data/`. Nie umieszczaj tego katalogu w publicznym katalogu serwera i nie commituj go do Git.

## Backup

Wystarczy kopia katalogu `data/`. Plik `config.json` zawiera hash hasła i hash Web Link Key, ale nadal należy traktować go jak dane prywatne.

## API i integracja aplikacji

- kontrakt: `contract/gantry-web-link.schema.json`;
- przykład: `contract/example-snapshot.json`;
- pełna instrukcja dla Codexa: `docs/CODEX-GANTRY-APP-INTEGRATION.md`;
- opis endpointów: `docs/API.md`.

## Testy

```bash
npm test
```

Projekt nie ma zależności npm; korzysta wyłącznie z modułów wbudowanych w Node.js.
