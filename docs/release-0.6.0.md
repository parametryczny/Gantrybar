# Gantry 0.6.0 — nowa nazwa, modularny filament i pełna telemetria

To pierwszy release pod nazwą **Gantry** (dawniej BambuBar / PrismBar) — z przeprojektowanym widokiem filamentu, dwiema dyszami, temperaturą komory i tym samym układem na macOS, Windows i GNU/Linux.

## ✨ Nowa marka
- Nazwa **Gantry**, logo **G** na pasku menu / w zasobniku i jako ikona aplikacji (macOS `.icns`, Windows `.ico`).
- Zapisane drukarki, kody i uprawnienia **zostają** — aktualizacja niczego nie gubi.

## 🧩 Modularny filament (AMS / AMS HT / CFS / MMU / EXT)
- Każdy fizyczny moduł to **osobna grupa** z własną nazwą, **wilgotnością i temperaturą** — koniec jednej wspólnej listy.
- **AMS HT** i pojedyncze szpule pokazują 1 slot (nie udają czterech); standardowy AMS trzyma 4 pozycje, puste zostają szare na swoim miejscu.
- **Creality CFS** — każdy box to osobny zestaw (`CFS 1`, `CFS 2`), szpula zewnętrzna jako `EXT`.
- **Klipper / Happy Hare (MMU)** — dowolna liczba bramek `T0…Tn`, bez sztucznego dzielenia po cztery.
- Duże, czytelne kafelki koloru z etykietą pod spodem; aktywny slot z białym pierścieniem.

## 🌡 Dwie dysze i komora
- Drukarki dwudyszowe (H2D) pokazują jawnie **L / P** (PL) lub **L / R** (EN) — koniec sklejonego `245°·42°`.
- **Temperatura komory** tylko dla drukarek z realnym czujnikiem (bez sztucznych `0°`).

## 🔒 Prywatność — import ze slicera za zgodą
- Konfiguracja Bambu Studio (zawiera kody dostępu) **nie jest czytana**, dopóki nie zaznaczysz zgody. Jasny komunikat + checkbox przy dodawaniu drukarki.

## 📡 Wykrywanie
- SSDP wysyłane na **każdej karcie sieciowej** (lepsze wykrywanie przy wielu podsieciach/NIC).
- **Własny port** dla Bambu (domyślnie 8883) — dla tuneli socat/VPN kierujących kilka drukarek na różne porty jednego hosta.

## 🐧 GNU/Linux (beta, GTK)
- Ten sam model danych i układ: grupy filamentu, druga dysza, komora, opt-in na slicery.

## 🛠 Poprawki
- Naprawiono **znikanie białej ramki** aktywnego slotu AMS po połączeniu (częściowy raport MQTT nie kasuje już aktywnego slotu ani grup).
- Kafle w wierszu mają **równą wysokość** (niższy dopasowuje się do wyższego).
- Windows: menu „…" karty odbija się w górę przy dolnych kartach; panel nie rośnie w nieskończoność.

## ⬆️ Aktualizacja z wcześniejszej wersji (BambuBar)

Twoje **drukarki i kody dostępu przenoszą się automatycznie** — nic nie trzeba przepisywać.

- **macOS:** przy pierwszym uruchomieniu Gantry kliknij **Zezwól** w oknie „Sieć lokalna" (Gantry ma nową tożsamość, więc pyta od nowa). Jeśli okno się nie pojawi, **uruchom Maca ponownie** i odpal Gantry jeszcze raz. Starą aplikację **BambuBar** możesz usunąć — przeciągnij ją z Programów do Kosza (Gantry ją zastępuje).
- **Windows / GNU/Linux:** instalator/aktualizacja podmienia aplikację; ustawienia przenoszą się same. Starego skrótu „BambuBar" (jeśli został) możesz się pozbyć ręcznie.

## 🖥 Zgodność
macOS, Windows i GNU/Linux pokazują **te same dane** i interpretują je tak samo.
