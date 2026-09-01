# Gantry — kontrakt layoutu karty drukarki (port na Windows / Linux)

**Wersja:** 1.0 · **Data:** 2026-08-24 · **Źródło prawdy:** shipped macOS (`Sources/Gantry/App/GantryTheme.swift` + `Sources/Gantry/Views/PrinterDashboardViewController.swift`)

Ten dokument opisuje **dokładne** wartości i reguły, które wersja macOS ma **teraz** (po sesji zagęszczania i neutralizacji koloru). Windows (WPF/C#) i Linux (GTK/Python) mają odtworzyć to 1:1. Gdzie ten dokument różni się od starszego `gantry-design-tokens.json` (v0.2.0), **obowiązuje ten dokument** — tamten opisuje wcześniejszy zamysł, ten opisuje stan wdrożony.

Wizualna referencja: `design/gantry-bento-demo.html`, `design/gantry-details-demo.html`.

---

## 0. Zasady nadrzędne

1. **Layout zależy od dostępnej szerokości i możliwości drukarki — NIGDY od systemu ani liczby drukarek.** Ta sama szerokość → ten sam układ na mac/Win/Linux.
2. **Neutralna paleta.** Karty są szare; jedyny stały akcent koloru to temperatura na wartości i realny kolor filamentu. Status drukarki NIE koloruje karty (patrz §8).
3. **Kolor niosą dane, nie chrom.** Żadnych kolorowych pasków/teł „dla ozdoby".

---

## 1. Tokeny (kolory, promienie, metryki)

Kolory sRGB, hex `RRGGBB`. Alpha podana osobno jako `white α` = biel z kryciem, `token α` = token z kryciem.

### Powierzchnie
| token | wartość |
|---|---|
| `canvas` | `#0C0D0E` |
| `card` | `#151719` |
| `line` | biel α 0.09 |
| `surface` | biel α 0.052 |
| `text` | `#F2F3F1` |
| `secondary` | `#A7AAA6` |
| `muted` | `#6D716E` |
| `accent` (neutralny) | `#D4D7D3` |

### Strefy termiczne / środowisko
| token | wartość |
|---|---|
| `nozzle` | `#FF8A61` |
| `bed` | `#EFBD5F` |
| `chamber` | `#BBA5EF` |
| `humidity` | `#73CFAD` |
| `sensorTemp` | `#EFA25F` |

### Status
| token | wartość | użycie |
|---|---|---|
| `statusPrinting` | `#FF6857` | jedyny zatwierdzony kolor statusu (druk); też: faint error wash |
| `statusDefault` | `#D4D7D3` | wszystkie pozostałe stany (neutralnie) |
| `statusPaused` | `#EBB55C` | rezerwa |

### Promienie i metryki
| token | wartość |
|---|---|
| `cardRadius` | **16** |
| `tileRadius` | **10.5** |
| `gap` (bazowy) | 8 |

---

## 2. Siatka floty (rozmieszczenie kart)

Sterowana **liczbą kolumn** (1 lub 2), którą wybiera user (przełącznik), oraz trybem kompaktowym (lista).

| parametr | wartość |
|---|---|
| kolumny | 1 lub 2 (user, klucz `gantry.dashboard.columns`, domyślnie 2, clamp 1–2) |
| szerokość panelu — 1 kolumna | **380** px |
| szerokość panelu — 2 kolumny | **563** px |
| szerokość panelu — lista (compact) | **512** px |
| szerokość treści | `panelWidth − 24` |
| odstęp poziomy między kolumnami | **10** |
| odstęp pionowy między rzędami kart | **8** (compact: 3) |
| wysokość nagłówka panelu | 36 |

**Reguła spanu:** zwykła karta zawsze zajmuje jedną kolumnę, również gdy jest ostatnia w niepełnym rzędzie. Pełną szerokość dostaje wyłącznie wariant szeroki (podwójna dysza albo co najmniej dwa niezewnętrzne moduły AMS). Pusty „spacer" w rzędzie ma szerokość `unit*remaining + gap*(remaining−1)`.

**Wysokość panelu:** `min(maxHeight, chrome + zmierzona treść)`, gdzie `maxHeight = ekran.visibleFrame.height − 24`. Nagłówek nie może „uciec" nad pasek menu.

---

## 3. Anatomia karty (od góry)

Karta = warstwa `card` α 0.5 + ramka `line` 1px + `cardRadius` 16, `masksToBounds`.

**Wewnętrzny stack pionowy** (3 sekcje): `[jobSurface, tempBento, filamentDock]`
- odstęp między sekcjami: **3**
- insety treści: lewy/prawy **10**, góra/dół **6**
- min. wysokość karty: **90**

### 3a. jobSurface (bento „zadanie")
Warstwa `surface` + ramka `line` 1px + `tileRadius` 10.5. Wewnątrz stack pionowy:
`[header, statusRow, flexibleJobSpace, progressSummary, progress]`
- insety: lewy/prawy **9**, góra **6**, dół **5**
- odstęp elementów: **1**
- `flexibleJobSpace` = elastyczny rozpychacz (spycha progress na dół, gdy karta jest wyższa od sąsiada w rzędzie o równej wysokości)

---

## 4. Nagłówek karty (header)

Stack poziomy, `centerY`, spacing **7**:
`[stateDot, titleCluster, detailsChip, ↔spacer, dragHandle, actionsButton]`

| element | wartość |
|---|---|
| `stateDot` (ikona drukarki) | 14×14, tint = neutralny (`accent`) |
| `titleCluster` | `[nameLabel, manufacturerLabel]`, poziomy, **centerY**, spacing 5 |
| `nameLabel` | 14 pt semibold, `text` |
| `manufacturerLabel` (pill „MQTT" itd.) | 10 pt regular, tło biel α 0.025, radius 5 |
| `detailsChip` (ikona wykresu → Szczegóły) | 20×20, radius 10, tło biel α 0.065, ikona `chart.xyaxis.line` 11px |
| `dragHandle` (⠿) | 20×20, radius 10, tło biel α 0.065, siatka kropek 2 kol × 3 rz (Ø 2.4, krok 6) |
| `actionsButton` (⋯) | 20×20, radius 10, tło biel α 0.065, ikona `ellipsis` |

**Ważne:** `titleCluster` wyrównany `centerY` (NIE firstBaseline) — nazwa, pill i chipy leżą na jednej osi.

---

## 5. Linia statusu (statusRow)

Stack poziomy, `centerY`, spacing **5**:
`[jobStateDot, statusLabel, jobSeparator, jobLabel, ↔spacer]`

| element | wartość |
|---|---|
| `jobStateDot` | 6×6, radius 3, kolor = neutralny |
| `statusLabel` | 10 pt medium; kolor: stale→systemOrange, else neutralny (`accent`); hug required |
| `jobSeparator` (`·`) | 10 pt semibold, tertiary |
| `jobLabel` (nazwa pliku) | 10 pt semibold, `text`, **marquee** (scroll na hover), niski hug/compression → bierze wolną szerokość |

**Licznik warstw NIE jest tu** — przeniesiony do rzędu postępu (§6).

---

## 6. Rząd postępu (progressSummary) + pasek

Stack poziomy, `centerY`, spacing **7**:
`[percentLabel, etaMetric, layerMetric, ↔spacer]`

| element | wartość |
|---|---|
| `percentLabel` (duże %) | **22 pt** mono semibold, kolor neutralny; hug/compression required (nie ucinać „100%") |
| `etaMetric` | chip: ikona `clock` + „`3h 16m · 12:06`" (czas pozostały · godzina końca) |
| `layerMetric` | ikona `square.3.layers.3d` + „`6/377`" (bez chipa) |

**Pasek postępu (segmentowy, „BrutalistProgressView"):**
| parametr | wartość |
|---|---|
| wysokość | **8** |
| liczba segmentów | **32** |
| odstęp segmentów | 2 |
| radius segmentu | 1 |
| segment aktywny | `tintColor` (neutralny) |
| segment nieaktywny | `label` α 0.12 |
| aktywnych = `round(value/100 * 32)` |

---

## 7. Bento temperatur (tempBento)

Kontener: `surface` + ramka `line` 1px, **wysokość 34**, radius `tileRadius`. Wewnątrz rząd stref `fillEqually`, spacing 0.

**Strefy (kolejność):**
- 1 dysza: `[DYSZA, STÓŁ, KOMORA?]`
- 2 dysze: `[DYSZE L, P, STÓŁ, KOMORA?]` — **L przed P** (lewa, potem prawa)
- **KOMORA pokazywana tylko gdy jest odczyt** (chamber ≠ null). Brak czujnika → kafla nie ma, dysza+stół się rozszerzają.

**Kafel strefy (neutralny — kolor tylko na wartości):**
| element | wartość |
|---|---|
| tło kafla | biel α 0.012 |
| „ambient" (delikatny top-light) | gradient biel α 0.03 → 0.008 → 0 (pion) |
| górna linia (accent) | `line` (neutralna, 1px) |
| separator między strefami | `line` 1px (pionowy, od 2. strefy) |
| etykieta | 7 pt mono semibold, `tertiary`, tracking; top 3, lewa 6 |
| **wartość bieżąca** | 14 pt mono semibold, **kolor = token strefy** (nozzle/bed/chamber) |
| wartość docelowa | 8 pt mono regular, tertiary, „`/ 70°`" (jeśli 0/brak → „`/ —`") |

To jedyny kolor w bento temperatur: **liczba** niesie hue, reszta kafla szara.

---

## 8. Kolor statusu — kontrakt

- **Karta:** status NIE koloruje karty ani obwódki. `stateColor` = zawsze `accent` (neutralny). Tekst statusu neutralny; stan czyta się z tekstu i ikony.
- **Lista (compact row):** neutralnie; stan niesie **kształt ikony** (`checkmark.seal`, `wifi.slash`, trójkąt błędu itd.). Tylko `error` dostaje `statusPrinting` na ikonie + faint wash `statusPrinting` α 0.08 na wierszu. Stale → systemOrange.
- **Kolor druku (`statusPrinting` #FF6857)** — dostępny w tokenach, obecnie NIE nakładany na kartę (świadoma decyzja: „bez czerwieni przy druku").

---

## 9. Dok filamentów (filamentDock)

Kolumna rzędów; do 2 grup w rzędzie obok siebie.
| parametr | wartość |
|---|---|
| odstęp pionowy rzędów | **6** |
| odstęp poziomy w rzędzie (AMS↔EXT) | **6** |

**Szerokość grup w rzędzie** = proporcjonalna do `declaredCapacity` (priorytet `defaultHigh`):
- 4-slotowy AMS + EXT(1) → 4:1 (AMS szeroki)
- AMS HT(1) + EXT(1) → 1:1
- **Minima (wymuszone):** grupa external ≥ **58**; grupa z plakietką wilgotności/temperatury ≥ **118** (żeby nagłówek się nie uciął).

### 9a. Grupa (FilamentGroupView)
Kafel: biel α 0.075 + ramka `line` 1px + `tileRadius`.
- insety: lewy/prawy 6, góra/dół **4**
- odstęp nagłówek→sloty: **3**
- **Nagłówek — krótka nazwa** (nie ucinać do „AM…"):
  - `"AMS A"` → **`AMS`** (litera grupy i tak jest przy slocie jako „A1")
  - `"AMS HT"` → **`HT`**
  - `CFS 1`, `MMU`, `EXT` → bez zmian
  - nazwa: 10 pt semibold, `text`
- **Plakietka wilgotności/temperatury** (prawa strona nagłówka): ikona 8px + tekst 9 pt medium
  - wilgotność: ikona `drop.fill`, kolor `humidity`; gdy WYSOKA → `statusPaused`
    - próg „wysoka": skala 0–5 → `≥4`; skala %/inne → `≥40`
  - temperatura: ikona `thermometer.medium`, kolor `sensorTemp`
- **Sloty:** stack poziomy, align top, spacing 5
  - wiele slotów → komórki `fillEqually`, ale sam swatch ma limit **56** (AMS/CFS) / **92** (EXT)
  - **1 slot → wyśrodkowany swatch o szerokości 35% modułu**, minimum **60**, maksimum równe szerokości modułu

### 9b. Slot (FilamentSlotView)
Pionowo: `[swatch, meta(materiał)]` — **procent jest W SWATCHU**, nie osobnym rzędem.
| element | wartość |
|---|---|
| swatch wysokość | **18** |
| swatch max szerokość | wiele slotów: **56** (AMS/CFS) / **92** (EXT); pojedynczy slot: reguła 35% / min. 60 |
| swatch radius | 6 (fill) / 5 (solid/empty) |
| slot present, fill | „FilamentSwatchView": tło = kolor α 0.20, wypełnienie od dołu = `remaining%` w pełnym kolorze |
| slot present, brak fill | lity chip w kolorze, radius 5 |
| slot pusty | „EmptyFilamentSwatchView": tło biel α 0.018, ramka biel α 0.075, ukośna kreskowa 45° biel α 0.035 |
| ramka aktywna | biel α 0.8, **1.5** px |
| ramka present (nieaktywna) | czarny α 0.12, 0.5 px |
| ramka pusta | separator, 0.5 px |
| meta (materiał) wysokość | 11; slotID „A1" 7.5 pt mono muted (lewa), materiał 10 pt semibold `text` (środek, truncate) |

**Procent w swatchu (kontrast auto):**
- font 9 pt mono **bold**, wyśrodkowany, + cień 1.5 blur w przeciwnym kolorze (α 0.4)
- **kolor tuszu zależy od tego, co jest POD tekstem** (środek chipa):
  - `remaining ≥ 50%` → środek jest w litym kolorze → tusz = **kontrast wg luminancji koloru** (patrz §10)
  - `remaining < 50%` (w tym 0%) → środek nad przygaszoną/ciemną częścią → tusz **jasny** (biel α 0.95)
- **Ostrzeżenie niskiego stanu:** czerwona kropka 6×6 w prawym-górnym rogu swatcha, gdy `present && !external && remaining ≤ 15%`.

---

## 10. Reguła kontrastu (contrastingTextColor)

Dla koloru RGB: `luminance = 0.299·R + 0.587·G + 0.114·B` (składowe 0–1).
`luminance > 0.58 → czarny, else → biały.`

Stosowane do procentu w swatchu (przy fill ≥ 50%). Przy fill < 50% pomiń regułę i użyj bieli.

---

## 11. Tryb listy (compact row)

| parametr | wartość |
|---|---|
| radius wiersza | 12 |
| wysokość | 31 |
| układ | `[handle, stateIcon, nameLabel, ↔spacer, statusLabel]`, spacing 7, insety lewy 9 / prawy 10 |
| `stateIcon` | 14×14, tint neutralny (error → `statusPrinting`) |
| `nameLabel` | 11 pt semibold, `text`, szer. 128 |
| `statusLabel` | 10 pt medium, prawy; stale→orange, error→`statusPrinting`, else `secondary` |
| tło wiersza | neutralne (error → `statusPrinting` α 0.08, else brak) |

---

## 12. Okno ustawień (modernizacja)

- Płótno: `canvas` `#0C0D0E`.
- Sekcje jako karty: `card` α 0.5 + ramka `line` 1px + `cardRadius` 16, inset 14/12.
- Nagłówek sekcji: 10 pt semibold, `muted`, WIELKIE LITERY (`WYGLĄD`, `OGÓLNE`, `KARTY DRUKAREK`, `POWIADOMIENIA`, `AKTUALIZACJE`).
- Cała treść w pionowym scrollu; okno 460×640, resizable, min 440×360.
- Typografia: tytuł `text`, etykiety `secondary`, wersja `muted`.

---

## 13. Mapowanie platform

| pojęcie AppKit | WPF / C# | GTK / Python |
|---|---|---|
| `NSStackView` (V/H) | `StackPanel` Orientation | `Gtk.Box` |
| `fillEqually` | `UniformGrid` / `Grid` gwiazdki `*` | `Gtk.Grid` homogeneous / `hexpand` |
| proporcje szer. (multiplier) | `ColumnDefinition Width="4*"/"1*"` | `Gtk.Grid` + `width` ważony / `size_group` |
| `cornerRadius` warstwy | `Border CornerRadius` | CSS `border-radius` (`Gtk.CssProvider`) |
| kolor α | `SolidColorBrush` z `#AARRGGBB` | `rgba()` w CSS |
| `contentHugging`/`compression` | `HorizontalAlignment` + `MinWidth`/`MaxWidth` | `hexpand`/`halign` + `set_size_request` |
| marquee (jobLabel) | `TextBlock` + storyboard/`Trimming` | `Gtk.Label` ellipsize + własny scroll |
| segmentowy pasek | `ItemsControl`/rysunek 32 prostokątów | `Gtk.DrawingArea` (`cairo`) 32 segmenty |
| swatch + % w środku | `Grid` (chip + `TextBlock` na wierzchu) | `Gtk.Overlay` (chip + `Label`) |
| cień tekstu | `DropShadowEffect` | CSS `text-shadow` |

**Uwaga Linux:** GTK3 (nie GTK4). Kolejność `gi.require_version` przed importem `gi.repository`.
Dashboard, tryb listy, Szczegóły i osadzona kamera są zaimplementowane w `linux/gantry/dashboard.py`,
`linux/gantry/details.py` i `linux/gantry/camera.py`; `app.py` pozostaje orkiestratorem usług systemowych.

---

## 14. Checklista portu (Definition of Done)

- [ ] Tokeny (§1) wpięte jako jedno źródło kolorów/promieni.
- [ ] Siatka 1/2 kolumny + span zależny od wyposażenia + szerokości panelu (§2).
- [ ] Karta: sekcje/insety/odstępy/min-height (§3), header centerY (§4), status line z marquee (§5).
- [ ] Rząd postępu z warstwami + segmentowy pasek 32/wys.8 (§6).
- [ ] Bento temp: neutralne kafle, kolor na wartości, ukrycie KOMORA, L→P (§7).
- [ ] Status neutralny wg kontraktu (§8).
- [ ] Dok filamentów: proporcje capacity, minima, krótkie nazwy, 1-slot wyśrodkowany (§9).
- [ ] Procent w swatchu z regułą kontrastu 50% + kropka <15% (§9b, §10).
- [ ] Tryb listy neutralny (§11).
- [ ] Okno ustawień: karty-sekcje + scroll (§12).
