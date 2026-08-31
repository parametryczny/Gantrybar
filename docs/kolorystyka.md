# Gantry — kolorystyka interfejsu

Ten dokument definiuje wspólną kolorystykę Gantry dla macOS, Windows, Linux i widoku webowego.
Kolory temperatur opisują **stan**, a nie konkretny czujnik. Dysza, stół i komora korzystają więc
z tej samej mapy stanów. Osobne kolory czujników są używane wyłącznie tam, gdzie trzeba rozróżnić
serie danych, przede wszystkim na wykresach.

## 1. Kolory bazowe

| Token | Wartość | Zastosowanie |
| --- | --- | --- |
| `canvas` | `#0C0D0E` | tło aplikacji |
| `card` | `#151719` | karty i panele |
| `surface` | `rgba(255,255,255,0.052)` | pola i powierzchnie wewnątrz kart |
| `line` | `rgba(255,255,255,0.09)` | obramowania i separatory |
| `text` | `#F2F3F1` | tekst główny |
| `secondary` | `#A7AAA6` | tekst pomocniczy |
| `muted` | `#6D716E` | informacje nieaktywne i brak danych |
| `accent` | `#D4D7D3` | neutralny akcent kontrolek |
| `metric` | `#D4D7D3` | wspólny kolor telemetrii i wartości liczbowych |

## 2. Wspólny kolor metryk

Wszystkie podstawowe dane na karcie drukarki korzystają z jednego neutralnego koloru
`metric = #D4D7D3`. Dotyczy to:

- opisów i wartości dyszy, stołu oraz komory,
- postępu wydruku i wartości procentowej,
- ETA i czasu pozostałego,
- poziomu filamentu w gramach,
- procentu pozostałego filamentu,
- wartości sliderów i pasków postępu.

Nie należy nadawać osobnych stałych kolorów dyszy, stołowi, ETA ani poziomowi filamentu. Dzięki temu
karta ma jeden spokojny język wizualny i nie wygląda jak zestaw niezależnych kontrolek.

Hierarchię budujemy z jednego koloru przez typografię i krycie:

| Element | Kolor bazowy | Krycie / styl |
| --- | --- | --- |
| Etykieta, np. `DYSZA`, `STÓŁ`, `ETA` | `#D4D7D3` | 72%, mały tekst |
| Wartość, np. `220°`, `01:24`, `68%` | `#D4D7D3` | 100%, tekst półgruby |
| Informacja drugorzędna | `#D4D7D3` | 55% |
| Dane niedostępne | `#D4D7D3` | 35%, symbol `—` |

Wyjątkiem jest bieżąca wartość temperatury w trybie dynamicznym: może chwilowo przejąć kolor stanu
`heating`, `cooling` albo `error`. Jej etykieta nadal pozostaje neutralna. Kolor próbki filamentu
identyfikuje materiał, ale tekst z gramami i procentem zawsze pozostaje neutralny.

## 3. Semantyczne kolory temperatur

Mapa obowiązuje identycznie dla dyszy, stołu i komory.

| Stan | Token | Kolor | Reguła |
| --- | --- | --- | --- |
| Bezczynny / zimny | `temperature.idle` | `#6D716E` | cel ≤ 5°C i temperatura ≤ 30°C |
| Nagrzewa | `temperature.heating` | `#D18C82` | cel > 5°C i bieżąca temperatura < cel − 3°C |
| Osiągnął temperaturę | `temperature.ready` | `#D4D7D3` | różnica względem celu nie przekracza 3°C |
| Drukuje / utrzymuje | `temperature.holding` | `#F2F3F1` | druk trwa, a temperatura pozostaje przy celu |
| Stygnie | `temperature.cooling` | `#8BA9C7` | temperatura > cel + 5°C, temperatura > 30°C i trend jest spadkowy |
| Błąd / alarm termiczny | `temperature.error` | `#FF5A4E` | błąd grzałki, termistora albo alarm zgłoszony przez firmware |
| Brak danych / offline | `temperature.unavailable` | `#6D716E` przy 55% krycia | brak aktualnego odczytu |

Progi 3°C i 5°C tworzą histerezę, dzięki której kolor nie przełącza się nerwowo przy niewielkich
wahaniach temperatury.

### Przykładowy przebieg

```text
Dysza:  bezczynna → nagrzewa → utrzymuje podczas druku → stygnie → bezczynna
Stół:   bezczynny → nagrzewa → utrzymuje podczas druku → stygnie → bezczynny
Komora: bezczynna → nagrzewa → stabilna                → stygnie → bezczynna
```

Stan `drukuje` jest stanem całej drukarki. Nie powinien nadpisywać informacji, że dany element nadal
się nagrzewa albo już stygnie. Kolor `temperature.holding` stosujemy, gdy druk trwa i element utrzymuje
temperaturę docelową.

### Komora bez temperatury docelowej

Jeśli drukarka nie udostępnia celu dla komory, stanu nie należy określać wyłącznie na podstawie
bieżącej temperatury. Preferowana kolejność źródeł to:

1. jawna faza drukarki, np. nagrzewanie lub chłodzenie komory,
2. stan grzałki albo wentylatora komory,
3. trend z kilku ostatnich pomiarów,
4. stan neutralny, jeśli kierunku zmiany nie da się wiarygodnie określić.

## 4. Tryb monochromatyczny

Tryb monochromatyczny usuwa barwy semantyczne, ale zachowuje hierarchię przez jasność, symbole,
grubość tekstu i styl linii. Informacja o stanie nie może zależeć wyłącznie od koloru.

| Stan | Kolor | Symbol | Dodatkowe wyróżnienie |
| --- | --- | --- | --- |
| Bezczynny / zimny | `#6D716E` | `○` | tekst regularny |
| Nagrzewa | `#D4D7D3` | `↑` | tekst regularny |
| Osiągnął temperaturę | `#D4D7D3` | `●` | tekst regularny |
| Drukuje / utrzymuje | `#F2F3F1` | `●` | tekst półgruby |
| Stygnie | `#A7AAA6` | `↓` | tekst regularny |
| Błąd / alarm | `#F2F3F1` | `!` | tekst półgruby i wyraźna ramka |
| Brak danych / offline | `#4B4F4C` | `—` | obniżony kontrast |

Przykład prezentacji:

```text
↑ DYSZA 180/220°
● STÓŁ   60/60°
↓ KOMORA 42°
— DYSZA  —
```

Nie należy stosować migania do sygnalizowania błędu. Ikona, kontrast i ramka zapewniają czytelny
sygnał bez problemów dostępnościowych.

## 5. Wykresy temperatur

Kolory identyfikujące czujniki są zarezerwowane dla wykresów i legend, gdzie trzy serie muszą być
rozpoznawalne jednocześnie.

| Czujnik | Kolor wykresu | Styl w trybie monochromatycznym |
| --- | --- | --- |
| Dysza | `#FF8A61` | linia ciągła |
| Stół | `#EFBD5F` | linia przerywana |
| Komora | `#BBA5EF` | linia kropkowana |

Kolor linii wykresu nie powinien zmieniać się razem ze stanem. Stan pokazuje wartość temperatury,
ikona lub etykieta; kolor wykresu identyfikuje serię.

## 6. Slider i pasek postępu

Slider oraz pasek postępu używają tej samej neutralnej kolorystyki w trybie dynamicznym i
monochromatycznym. Postęp pokazuje ilość, a nie stan drukarki, dlatego nie powinien przejmować koloru
drukowania, nagrzewania ani błędu.

| Element | Token | Wartość |
| --- | --- | --- |
| Aktywna część slidera | `control.active` | `#D4D7D3` |
| Uchwyt slidera | `control.thumb` | `#D4D7D3` |
| Wypełnienie paska postępu | `progress.fill` | `#D4D7D3` |
| Nieaktywna ścieżka | `control.track` | `rgba(255,255,255,0.10)` |
| Stan wyłączony | `control.disabled` | `#6D716E` |

Zmiana trybu kolorów nie może powodować zmiany barwy sliderów ani pasków postępu.

## 7. Reguły stosowania

- Kolor temperatury zawsze opisuje jej aktualny stan.
- Nazwy i podstawowe wartości `DYSZA`, `STÓŁ`, `KOMORA`, `POSTĘP`, `ETA` oraz dane filamentu
  korzystają ze wspólnego tokenu `metric`.
- Etykieta temperatury pozostaje neutralna; tylko jej wartość może sygnalizować aktywny stan kolorem.
- Stałe kolory dyszy, stołu i komory są dozwolone wyłącznie w legendzie i seriach wykresu.
- Kolor próbki filamentu identyfikuje materiał, ale gramy i procent filamentu pozostają neutralne.
- Stan błędu powinien pochodzić z firmware lub walidowanego alarmu, nie tylko z arbitralnego progu.
- Stan musi być zrozumiały również bez widzenia koloru.
- W trybie monochromatycznym pozostają symbole, kontrast, grubość tekstu oraz style linii.
- Progress bar i slider pozostają neutralne w obu trybach.
- Wszystkie platformy powinny używać tych samych wartości HEX i tych samych progów przełączania.
