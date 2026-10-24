# Bambuddy: monitoring w Gantry

Otwórz **Ustawienia → Integracje → Połączenie Bambuddy**. Funkcja jest dostępna w macOS, Windows i Linux, w PL/EN.

1. Podaj adres, np. `http://bambuddy.local:8000`. Końcówka `/api/v1` jest opcjonalna; prefiks reverse proxy pozostaje zachowany.
2. W Bambuddy utwórz klucz z uprawnieniem **Read Status**. Wklej go w ukryte pole w Gantry. Puste pole zachowuje klucz zapisany dla tego samego serwera.
3. **Sprawdź API** odczytuje listę bez zapisywania. **Zapisz** uruchamia odświeżanie listy i stanu w tle co 10 sekund.
4. Drukarki pojawią się na głównej liście i w topbarze Gantry z oznaczeniem **Bambuddy**. Nieaktywne i niepołączone urządzenia są widoczne jako offline; Gantry nie wymyśla dla nich postępu ani temperatur.

Odczytywane są: stan, postęp, nazwa zadania, warstwy, pozostały czas i dostępne temperatury. Dane pochodzą z API Bambuddy; Gantry nie nawiązuje dla tych urządzeń osobnych połączeń MQTT. AMS jest widoczny na kartach i w sekcji **AMS / Filamenty**: materiały, kolory, poziomy, aktywny slot, wilgotność i temperatura modułu, również AMS HT oraz EXT. Puste sloty zachowują swoje miejsca; brak pomiaru pozostaje nieznany. API nie udostępnia masy nominalnej szpuli, więc Gantry nie wylicza z niej fikcyjnych gramów. Kamera i import magazynu Bambuddy pozostają poza zakresem tej wersji integracji. Przy identycznym numerze seryjnym istniejąca drukarka połączona bezpośrednio ma pierwszeństwo, więc nie tworzymy drugiej karty tego samego urządzenia.

**Usuń połączenie** usuwa lokalny adres i klucz, przerywa bieżące odczyty oraz usuwa karty pochodzące z Bambuddy. Drukarki skonfigurowane bezpośrednio w Gantry pozostają. Serwer, jego baza i klucz po stronie Bambuddy nie są usuwane.

**Demo bez serwera** pokazuje dane przykładowe tylko w panelu konfiguracji; nie dodaje fikcyjnych drukarek do głównej listy. Karty źródła są odtwarzane z serwera po uruchomieniu Gantry i nie trafiają do zapisanej listy bezpośrednich połączeń.

Drukarki z Bambuddy mają ikonę API `{}`: zieloną, gdy połączenie działa, i szarą, gdy drukarka lub API nie odpowiada. Kolor opisuje połączenie, a nie wynik wydruku. Pauza i błąd druku nie oznaczają utraty API. Znacznik jest widoczny w kartach, liście kompaktowej i Gantry CLI.

## Zużycie i bezpieczeństwo

Gantry wykonuje tylko żądania GET, używa nagłówka `X-API-Key` i odrzuca przekierowania. Odczyt kompaktowego stanu korzysta z `remaining_seconds`, bez zgadywania jednostek. Dla kart Bambuddy nie wykonujemy sterowania ani rozliczania zużycia. Aktywny magazyn i rozliczanie drukarek bezpośrednich pozostają zgodne z ich ustawieniami.

Listę i uwierzytelnianie sprawdzono z lokalnym Bambuddy 1.2.5.7. Pięć drukarek TEST na lokalnym serwerze działa jako aktywne symulacje z wydrukami i AMS. Moduł testowy nie nawiązuje MQTT ani nie wysyła zdarzeń zużycia. Odczyt potwierdzono przez rzeczywiste API i interfejs Gantry; weryfikacja z fizyczną drukarką pozostaje do wykonania.

Źródła: [API Bambuddy](https://wiki.bambuddy.cool/reference/api/), [uprawnienia](https://wiki.bambuddy.cool/features/api-keys/).
