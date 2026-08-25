# Gantry — szczegóły drukarki

Ten dokument opisuje produkcyjny układ widoku `Szczegóły drukarki`. Źródłem geometrii jest wspólny kontrakt, a plik HTML służy jako wzorzec wizualny.

## Pliki referencyjne

- [Demo szczegółów HTML](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-details-demo.html>)
- [Kontrakt layoutu JSON](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-layout.defaults.json>)
- [Tokeny wizualne JSON](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-design-tokens.json>)
- [Główny opis systemu](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/GANTRY-DESIGN-SYSTEM.md>)

## Układ domyślny

Szerokość referencyjna widoku wynosi `640 px`. Status i kamera zajmują pełną szerokość. Pozostałe sekcje tworzą dwie niezależne kolumny, dzięki czemu niższa karta nie zostawia pustej przestrzeni pod sobą.

```text
┌──────────────────────────────────────────┐
│ Status wydruku                           │
├──────────────────────────────────────────┤
│ Kamera                                   │
├────────────────────┬─────────────────────┤
│ Filamenty / AMS    │ Temperatury         │
│                    ├─────────────────────┤
├────────────────────┤ Sterowanie          │
│ Wentylatory        │                     │
└────────────────────┴─────────────────────┘
```

Domyślna kolejność:

1. Status.
2. Kamera.
3. Filamenty / AMS.
4. Temperatury.
5. Wentylatory i prędkość.
6. Sterowanie i automatyzacje.

Status i kamera są pełnoszerokie. Pozostałe sekcje są rozdzielane naprzemiennie między lewą i prawą kolumnę. Wysokości nie są zapisywane — zawsze wynikają z treści.

## Zachowanie

- przeciągnięcie uchwytu zmienia kolejność sekcji;
- kolejność jest wspólna dla wszystkich drukarek na danej platformie;
- stary zapis kolejności jest migrowany do wersji `v2`, aby nowy domyślny układ nie odziedziczył wcześniejszego układu jednokolumnowego;
- brak kamery nie usuwa karty: karta pokazuje komunikat o niedostępnym strumieniu;
- Filamenty / AMS znajdują się bezpośrednio pod kamerą;
- przy szerokości poniżej breakpointu wszystkie sekcje powinny przejść do jednej kolumny;
- temperatura używa tych samych tokenów dyszy, stołu i komory co dashboard;
- aktywny druk używa czerwonego akcentu `#FF6857`; pozostałe stany pozostają neutralne.

## Implementacja

### macOS

- [PrinterDetailWindowController.swift](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/Sources/Gantry/Views/PrinterDetailWindowController.swift>)
- układ: pełnoszerokie karty + dwie niezależne kolumny `NSStackView`;
- kolejność: `detail-card-order-v2` w `UserDefaults`;
- segmentowany postęp i wspólne tokeny `GantryTheme`.

### Windows

- [DetailWindow.cs](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/windows/Gantry.Windows/UI/DetailWindow.cs>)
- układ: pełnoszerokie karty + dwie niezależne kolumny WPF;
- zapis kolejności: prefiks `v2:` w `AppSettings.DetailCardOrder`;
- kamera Bambu/Klipper oraz istniejące sterowanie pozostają podłączone.

### Linux

- [app.py](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/linux/gantry/app.py>)
- dashboard korzysta już z nowego kontraktu kafli;
- osobny produkcyjny widok szczegółów nie istniał wcześniej w kliencie GTK i nadal wymaga dodania. Jego przyszła implementacja ma użyć dokładnie tej kolejności i breakpointów, bez własnych reguł platformowych.

## Kryteria odbioru

- status i kamera mają identyczną szerokość;
- Filamenty / AMS zaczynają pierwszą kolumnę bezpośrednio pod kamerą;
- Temperatury zaczynają drugą kolumnę;
- karty w kolumnach nie wymuszają wspólnej wysokości rzędu;
- zmiana zawartości AMS nie powoduje nakładania kart;
- przeciągnięcie sekcji zapisuje i odtwarza kolejność;
- brak telemetrii wyświetla `—`, bez zmiany geometrii całego widoku.
