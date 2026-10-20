# Monitoring SLA i Fiberpunk w sieci lokalnej

Integracje są eksperymentalne. Sprawdziliśmy parsery i symulowane połączenia; nie mieliśmy tych urządzeń do testów sprzętowych. Zgodność zależy od modelu, firmware i trybu połączenia.

## Dodawanie

Wybierz **Dodaj drukarkę → SLA / MSLA** (na macOS: **SLA**), następnie model. Dla Fiberpunk wybierz osobną pozycję **Fiberpunk**. Monitoring działa przez cały czas działania Gantry, także przy zamkniętych szczegółach.

| Model | Połączenie lokalne | Dostępne dane |
|---|---|---|
| Elegoo Saturn 4 Ultra 12K / 16K, Mars 5 Ultra | SDCP v3, WebSocket 3030; wykrywanie UDP 3000 | Stan, plik, postęp według warstw, warstwy i czas |
| Elegoo Saturn 3 Ultra / Mars 4 Ultra | Starsze SDCP, UDP 3000 | Stan, plik, warstwy i czas; postęp z warstw |
| Anycubic Photon Mono X 6K | TCP 6000, `getstatus` | Stan, plik, postęp, warstwy i czas |
| Anycubic Photon P1 / P1 Max | HTTP 18910 → lokalny MQTT TLS 8883 | Stan, plik, postęp, warstwy i czas, jeśli raportowane; P1 Max wymaga osobnego potwierdzenia sprzętowego |
| Prusa SL1 / SL1S SPEED | PrusaLink HTTP 80, starsze API SLA | Stan, plik, postęp, warstwy i czas, jeśli raportowane |
| Formlabs Form 4 / 4B, Form 3 / 3+ / 3L | Komputer z PreForm Server, HTTP 44388 | Tekst statusu, łączność i dostępny czas pozostały; bez udawanego postępu procentowego |
| Phrozen przez OctoPrint / Chituboard | Zewnętrzny zgodny mostek OctoPrint, HTTP 80 | Stan, plik, postęp i czas przekazane przez mostek |
| Fiberpunk Node / Node Pro | API adaptera, HTTP 88 | Stan z `/find`; temperatury, warstwy i postęp z `/status`, jeśli dostępne |

### Elegoo

Dla Saturn 4 Ultra / Mars 5 Ultra podaj IP i **MainboardID** albo wybierz urządzenie z wykrywania. To identyfikator płyty SDCP, nie dowolna nazwa. Starsze Saturn 3 Ultra / Mars 4 Ultra wybierz jako osobny model: wystarczy IP i port UDP 3000. Gantry wysyła tylko zapytanie `M99999`; nie przekierowuje serwera MQTT drukarki i nie wysyła `M66666`.

### Photon P1 / P1 Max

Włącz **LAN** w drukarce i podaj jej IP. Gantry pobiera lokalną konfigurację połączenia z portu 18910, a potem odczytuje status przez MQTT. Zamknij **Photon Workshop**: drukarka używa pojedynczego identyfikatora klienta, więc równoczesne połączenia mogą się rozłączać. Wspólna implementacja rodziny P1 nie jest potwierdzeniem testów P1 Max. Nie uruchamiamy kamery ani nie wysyłamy poleceń sterujących.

### Prusa

Włącz PrusaLink i uwierzytelnianie kluczem API; wpisz klucz w Gantry. SL1 używa `/api/printer` i `/api/job`, a nie endpointów FDM `/api/v1/...`. Klucz trafia do dotychczasowego magazynu sekretów aplikacji.

### Formlabs

Uruchom **PreForm Server** i dodaj drukarkę w PreForm. W Gantry podaj **adres komputera z serwerem**, port 44388 i **PreForm ID drukarki** z odpowiedzi `/v1/device/list/`. To nie jest adres API samej drukarki. Każdą drukarkę dodaj osobno, z jej identyfikatorem. Gantry tylko odczytuje listę: nie loguje do chmury, nie rozpoczyna wykrywania ani zadań. Wpisy oznaczone `REMOTE` są pomijane.

API określa `status` jako tekst dla człowieka, więc nie wyciągamy z jego brzmienia stanu „drukuje”. Nie udostępnia tu wiarygodnego procentu, warstw ani nazwy pliku; Gantry pokazuje status i dostępny czas, bez „0%” ani „czeka na wydruk”.

### Phrozen

To **monitoring przez istniejący mostek**, nie natywna integracja Wi-Fi Sonic Mighty 8K. Wpisz adres i klucz API OctoPrint. Dokumentacja Chituboard wymienia m.in. **Sonic Mighty 4K i Sonic Mini 4K**; zgodność konkretnej drukarki i firmware trzeba sprawdzić po stronie mostka. Gantry nie instaluje mostka ani nie konfiguruje jego sprzętu. Bezpośredni protokół Mighty 8K nadal wymaga potwierdzenia.

### Fiberpunk

Podaj adres **adaptera**, nie drukarki. To nie jest OctoPrint. Gantry odczytuje tylko `/find` i `/status`: nie przejmuje karty SD, nie wysyła G-code i nie resetuje USB. Brak stanu lub ETA pozostaje brakiem odczytu.

## Zakres i ograniczenia

Te typy działają wyłącznie jako monitory: bez Farmy, wysyłania plików, sterowania, AMS/Spoolbase i automatycznej wyceny FDM. Gantry Vision do spaghetti nie analizuje SLA. Dedykowane kamery SLA nie są częścią tej integracji. Ustawienia powiadomień o stanie pozostają wspólne; nieklasyfikowany status tekstowy Formlabs nie uruchamia powiadomień o zakończeniu wydruku.

SDCP SLA i PreForm podają czas w milisekundach, Mono X i Prusa w sekundach, Photon P1 w minutach. Brak danych nie oznacza zera.

## Źródła protokołów

- [SDCP v3](https://github.com/cbd-tech/SDCP-Smart-Device-Control-Protocol-V3.0.0)
- [Starszy protokół Saturn 3 Ultra](https://github.com/JacobZwang/elegoo-saturn-4-ultra)
- [Photon P1: protokół i implementacja LAN](https://github.com/modrzew/hass-anycubic-photon-p1)
- [Mono X](https://github.com/adamoutler/anycubic-python)
- [PrusaLink SL1/SL1S](https://help.prusa3d.com/article/prusalink-sl1-sl1s_146094)
- [Formlabs Local API](https://developer.formlabs.com/api-reference/devices/)
- [OctoPrint / Chituboard: wymagania sprzętowe](https://github.com/rudetrooper/Octoprint-Chituboard)
- [Fiberpunk Node API](https://github.com/fiberpunk1/NodeWebPage/blob/main/NodeWebAPI.md)
