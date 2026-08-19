# Gantry — Automatyzacje (reguły, komendy, skrypty)

Przewodnik po sekcji **Automatyzacje** (macOS): jak działają wyzwalacze i akcje, oraz gotowe
przykłady **własnych komend MQTT** i **skryptów**.

> ⚠️ **Bezpieczeństwo.** Skrypty uruchamiają się przez `/bin/zsh -c` **z Twoimi uprawnieniami**.
> Regułę tworzysz świadomie, ale reguła warunkowa może odpalić skrypt **bez nadzoru**. Testuj każdy
> skrypt najpierw ręcznie (przycisk **Uruchom**). Komendy MQTT wysyłasz do drukarki po sieci lokalnej —
> nie wszystkie są odwracalne (np. `stop`).

---

## Jak to działa

Otwórz **Szczegóły** drukarki → kafel **Sterowanie i automatyzacje** → **Automatyzacje…**.

Każda automatyzacja to **wyzwalacz → akcja**:

- **Wyzwalacze**
  - **Ręczny** — odpala tylko przyciskiem **Uruchom**.
  - **Po warstwie ≥ N** — gdy `layer_num` osiągnie N.
  - **Po ≥ %** — gdy postęp osiągnie zadany procent.
  - **Gdy stan** — przy wejściu w stan: drukuje / pauza / zakończono / błąd / gotowa.
- **Akcje wbudowane** — Światło wł./wył., Pauza, Wznów, Stop, Powiadomienie (własny tekst).
- **Tworzenie własnych** — **Własna komenda** (surowy JSON MQTT) oraz **Skrypt** (zsh).

**Reguła warunkowa odpala się raz na wydruk** (licznik zeruje się przy nowym zadaniu). „Uruchom"
pozwala odpalić dowolną regułę ręcznie w każdej chwili.

---

## Własne komendy MQTT

Komenda to **surowy JSON**, który Gantry publikuje na `device/<serial>/request`. Pole `sequence_id`
może być dowolne. Komendy siedzą pod kluczem `system` (sprzęt) lub `print` (zadanie/gcode).

> Zestaw komend **zależy od modelu i firmware**. Poniżej sprawdzone/powszechnie używane; każdą
> przetestuj ręcznie na swojej drukarce.

### Oświetlenie komory
```json
{"system":{"sequence_id":"0","command":"ledctrl","led_node":"chamber_light","led_mode":"on"}}
```
`led_mode`: `on` / `off` / `flashing`. `led_node`: `chamber_light` (główne), na części modeli też
`work_light`. Miganie z własnym rytmem:
```json
{"system":{"sequence_id":"0","command":"ledctrl","led_node":"chamber_light","led_mode":"flashing","led_on_time":500,"led_off_time":500,"loop_times":3,"interval_time":1000}}
```

### Sterowanie wydrukiem
```json
{"print":{"sequence_id":"0","command":"pause"}}
{"print":{"sequence_id":"0","command":"resume"}}
{"print":{"sequence_id":"0","command":"stop"}}
```

### Poziom prędkości
```json
{"print":{"sequence_id":"0","command":"print_speed","param":"2"}}
```
`param`: `1` cichy · `2` standard · `3` sport · `4` wariat.

### Dowolny G-code (najmocniejsze — escape hatch)
`gcode_line` wysyła surowy G-code (pamiętaj o `\n` na końcu każdej linii):
```json
{"print":{"sequence_id":"0","command":"gcode_line","param":"M106 P1 S255\n"}}
```
Przydatne linie do `param`:
- Wentylatory (`M106 P<n> S<0-255>`, `M107` = wył): `P1` part · `P2` aux · `P3` komora.
  - Part 100%: `M106 P1 S255\n` · Aux wył: `M107 P2\n`
- Temperatury: dysza `M104 S220\n`, stół `M140 S60\n` (bez czekania), `M109`/`M190` z czekaniem.
- Wiele linii naraz: `M140 S0\nM104 S0\nM106 P1 S0\n` (wychłodzenie po druku).

> **Uwaga:** `gcode_line` w trakcie druku ingeruje w zadanie — używaj świadomie (np. schłodzenie po
> zakończeniu, nie w środku warstwy).

---

## Skrypty (zsh)

W akcji **Skrypt** wklejasz treść. Uruchamia się przez `/bin/zsh -c "…"`. Gdy skrypt odpali się
automatycznie, Gantry wysyła powiadomienie „Uruchomiono skrypt".

### Powiadomienie systemowe macOS
```zsh
osascript -e 'display notification "Osiągnięto warstwę 20" with title "Gantry" sound name "Glass"'
```

### Mowa
```zsh
say "Wydruk zakończony"
```

### Dziennik do pliku
```zsh
echo "$(date '+%Y-%m-%d %H:%M:%S')  zdarzenie druku" >> "$HOME/gantry-druk.log"
```

### Discord / Slack (webhook)
```zsh
curl -sS -X POST -H "Content-Type: application/json" \
  -d '{"content":"✅ Druk gotowy"}' \
  "https://discord.com/api/webhooks/XXXX/YYYY"
```

### Home Assistant (np. zgaś wtyczkę/światło)
```zsh
curl -sS -X POST \
  -H "Authorization: Bearer TWÓJ_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"entity_id":"switch.drukarka"}' \
  "http://HA_IP:8123/api/services/switch/turn_off"
```

### Wysłanie e-maila (przez skonfigurowany `mail`)
```zsh
printf "Druk zakończony o %s\n" "$(date)" | mail -s "Gantry: druk gotowy" ty@example.com
```

### Odtworzenie dźwięku
```zsh
afplay /System/Library/Sounds/Hero.aiff
```

---

## Przepisy (gotowe reguły)

| Cel | Wyzwalacz | Akcja |
|---|---|---|
| Zgaś LED po rozgrzaniu | **Po warstwie** `3` | **Światło wył.** |
| Świeć tylko na starcie | **Gdy stan** `drukuje` | **Światło wł.** |
| Powiadom o końcu | **Gdy stan** `zakończono` | **Powiadomienie** „Druk gotowy 🎉" |
| Mów przy błędzie | **Gdy stan** `błąd` | **Skrypt** `say "Uwaga, błąd drukarki"` |
| Schłodź po druku | **Gdy stan** `zakończono` | **Własna komenda** `gcode_line` `M140 S0\nM104 S0\n` |
| Zgaś wtyczkę po druku | **Gdy stan** `zakończono` | **Skrypt** (webhook / HA jak wyżej) |
| Log co wydruk | **Gdy stan** `drukuje` | **Skrypt** `echo "$(date) start" >> ~/druk.log` |

### Twój przypadek: LED gaśnie po warstwie N
1. **＋ Dodaj automatyzację**
2. Wyzwalacz: **Po warstwie** → `20`
3. Akcja: **Światło wył.**

Odpali się raz, po osiągnięciu warstwy 20. Chcesz świecić od startu i zgasić na N? Zrób **dwie**
reguły: `Gdy stan drukuje → Światło wł.` oraz `Po warstwie 20 → Światło wył.`

---

## Rozwiązywanie problemów

- **Komenda nic nie robi** — drukarka musi być połączona (widzisz telemetrię). Sprawdź `led_node`
  i format JSON. Część komend istnieje tylko na niektórych modelach/firmware.
- **Reguła nie odpala** — warunkowe działają tylko przy zmianie wartości w trakcie druku i **raz na
  zadanie**. Do testów użyj wyzwalacza **Ręczny** + **Uruchom**.
- **Skrypt nie działa** — przetestuj tę samą linię w Terminalu. Ścieżki bezwzględne, cudzysłowy
  ostrożnie. `PATH` może być minimalny — podawaj pełne ścieżki do narzędzi, jeśli trzeba.
