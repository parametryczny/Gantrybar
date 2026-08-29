# Gantry Web Link API v1

Bazowy adres: publiczny adres HTTPS bez końcowego ukośnika.

## Autoryzacja

Publisher aplikacji używa:

```http
Authorization: Bearer GW1-...
```

Panel przeglądarkowy używa ciasteczka `gantry_session` z flagami `HttpOnly`, `SameSite=Strict` oraz `Secure` pod HTTPS. Web Link Key nie jest zapisywany na serwerze jawnie — przechowywany jest jego SHA-256. Hasło jest hashowane przez `scrypt` z osobną solą.

## Endpointy

### `GET /api/health`

Publiczny health check. Nie zwraca danych drukarek.

### `GET /api/setup/status`

Informuje frontend, czy wykonano pierwszą konfigurację.

### `POST /api/setup`

Jednorazowa konfiguracja. Wymaga `setupToken`, `linkKey`, hasła długości co najmniej 10 znaków i opcjonalnej nazwy panelu. Po skonfigurowaniu zawsze zwraca `409`.

### `PUT /api/v1/devices/{deviceId}/snapshot`

Endpoint aplikacji Gantry. Wymaga Bearer Web Link Key. Body musi być zgodne z `gantry-web-link.schema.json`. Poprawna odpowiedź to `202 Accepted`.

Idempotencja: jeden `deviceId` ma jeden aktualny snapshot. Kolejny PUT zastępuje poprzedni.

### `POST /api/auth/login` / `POST /api/auth/logout`

Logowanie i wylogowanie panelu. Logowanie jest ograniczone do 10 błędnych prób na minutę i adres IP.

### `GET /api/v1/fleet`

Zalogowany panel pobiera zmergowaną flotę. Jeśli ta sama drukarka występuje w snapshotach kilku urządzeń, wygrywa najnowszy snapshot.

### `GET /api/v1/events`

Strumień Server-Sent Events. Zdarzenie `snapshot` informuje panel, że należy ponownie pobrać `/api/v1/fleet`.

### `PUT /api/v1/link-key`

Rotacja klucza przez zalogowaną sesję. Po zmianie wszystkie aplikacje muszą dostać nowy klucz.

## Kody odpowiedzi publishera

- `202` — snapshot zapisany;
- `401` — błędny lub nieaktualny Web Link Key;
- `413` — przekroczono limit body;
- `422` — body nie spełnia kontraktu;
- `500` — błąd serwera; aplikacja powinna ponowić wysyłkę z backoffem.

## Częstotliwość

Zalecenie: wysyłka najwyżej raz na 2 sekundy, tylko gdy snapshot się zmienił, oraz heartbeat co 20 sekund. Przy błędzie stosować backoff `2, 5, 10, 30, 60` sekund z losowym jitterem. Tylko jeden request może być aktywny naraz.
