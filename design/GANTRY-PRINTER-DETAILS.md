# Gantry — szczegóły drukarki

Ten dokument opisuje produkcyjny układ widoku `Szczegóły drukarki`. Źródłem geometrii jest wspólny kontrakt, a plik HTML służy jako wzorzec wizualny.

## Pliki referencyjne

- [Demo szczegółów HTML](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-details-demo.html>)
- [Kontrakt layoutu JSON](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-layout.defaults.json>)
- [Tokeny wizualne JSON](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-design-tokens.json>)
- [Główny opis systemu](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/GANTRY-DESIGN-SYSTEM.md>)

## Układ domyślny

Aktualny kod macOS ustala widok na `480 × 700 px`. Wszystkie sekcje są pełnoszerokimi kartami w jednej przewijanej kolumnie.

```text
┌──────────────────────────────────────────┐
│ Status wydruku                           │
├──────────────────────────────────────────┤
│ Kamera                                   │
├──────────────────────────────────────────┤
│ Filamenty / AMS                          │
├──────────────────────────────────────────┤
│ Temperatury                              │
├──────────────────────────────────────────┤
│ Wentylatory i prędkość                   │
├──────────────────────────────────────────┤
│ Sterowanie i automatyzacje               │
└──────────────────────────────────────────┘
```

Domyślna kolejność:

1. Status.
2. Kamera.
3. Filamenty / AMS.
4. Temperatury.
5. Wentylatory i prędkość.
6. Sterowanie i automatyzacje.

Wysokości nie są zapisywane — zawsze wynikają z treści. Status pozostaje widoczny; kamerę, AMS, temperatury, wentylatory i sterowanie można ukrywać. Kolejność kart można zmieniać przeciąganiem.

## Zachowanie

- przeciągnięcie uchwytu zmienia kolejność sekcji;
- kolejność jest wspólna dla wszystkich drukarek na danej platformie;
- zapis kolejności jest współdzielony przez wszystkie drukarki na danej platformie;
- brak kamery nie usuwa karty: karta pokazuje komunikat o niedostępnym strumieniu;
- Filamenty / AMS znajdują się bezpośrednio pod kamerą;
- widok zawsze pozostaje w jednej kolumnie;
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

- [dashboard.py](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/linux/gantry/dashboard.py>)
- [details.py](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/linux/gantry/details.py>)
- `DetailPanel` jest podmieniany wewnątrz głównego panelu GTK, bez osobnego okna;
- wszystkie karty są pełnoszerokie w jednej przewijanej kolumnie 480 px, zgodnie z aktualnym `PrinterDetailViewController`;
- `CameraView` osadza istniejący strumień RTSPS/MJPEG bezpośrednio w karcie Szczegółów.

## Kryteria odbioru

- wszystkie karty mają identyczną szerokość w jednej kolumnie;
- Filamenty / AMS znajdują się bezpośrednio pod kamerą;
- Temperatury znajdują się pod Filamentami / AMS;
- zmiana zawartości AMS nie powoduje nakładania kart;
- przeciągnięcie sekcji zapisuje i odtwarza kolejność;
- brak telemetrii wyświetla `—`, bez zmiany geometrii całego widoku.
