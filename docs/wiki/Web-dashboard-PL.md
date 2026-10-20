# Panel WWW: sieć lokalna i własny hosting

[English](https://github.com/parametryczny/Gantrybar/wiki/Web-dashboard-EN) · [Spis treści](https://github.com/parametryczny/Gantrybar/wiki/Home)

Gantry oferuje dwa różne sposoby podglądu. Adres lokalny nie staje się adresem internetowym po wyjściu z Wi-Fi.

| Tryb | Gdzie działa | Co musi działać |
| --- | --- | --- |
| lokalny serwer podglądu | sieć lokalna | komputer z Gantry i dostęp do jego adresu |
| most do własnego hostingu | również poza Wi-Fi | Gantry, internet i hosting PHP/HTTPS |

## Podgląd w LAN

W Ustawieniach włącz **Serwer podglądu** i użyj adresu pokazanego przez aplikację. Telefon powinien być w sieci, która może połączyć się z komputerem. Lokalny panel służy do odczytu; zapora komputera może blokować połączenie.

Komputer pokazujący karty w aplikacji nie musi mieć otwartego okna szczegółów. Musi jednak pozostawać uruchomiony i osiągalny.

## Generowanie paczki na hosting

Otwórz ustawienia własnej strony i mostu w Gantry.

1. Kliknij **Generuj paczkę WWW…**.
2. Wpisz docelowy adres HTTPS, np. `https://example.com/gantry/`.
3. Zapisz hasło strony w swoim menedżerze haseł. Generator używa klucza mostu z aplikacji lub przygotowuje go, gdy jest potrzebny.
4. Zapisz ZIP i wgraj **rozpakowaną zawartość**, razem z `.htaccess`, na hosting PHP.
5. Zapewnij PHP prawo zapisu do katalogu danych.
6. W Gantry włącz most i na początek wybierz **Tylko podgląd**.
7. Zaloguj się na stronie i sprawdź czas ostatniej synchronizacji.

Generator nie publikuje strony i nie włącza mostu. ZIP zawiera klucz konfiguracji: nie umieszczaj samego archiwum w publicznym katalogu hostingu. Hasło jest zapisane w paczce jako hash, a klucz znajduje się po stronie PHP, nie w JavaScript.

PHP musi mieć wersję co najmniej 7.4. Apache może użyć dołączonych reguł `.htaccess`; na Nginx trzeba skonfigurować odpowiednie blokady dostępu do `config.php` i `data/`.

## Zakres danych i sterowania

Podstawowy stan floty i dodatkowe dane to osobne zakresy. Aby przesłać farmę, historię, koszty, Spoolbase i konserwację, włącz odpowiednią opcję udostępniania. Kamery mogą przesyłać klatki na hosting podczas oglądania Monitoringu przez zalogowanego użytkownika.

Tryb **Tylko podgląd** nie zezwala na polecenia. Opcjonalne sterowanie jest ograniczone tym, co dopuszcza aplikacja i drukarka. Przeglądanie farmy lub Spoolbase w WWW nie oznacza edytowania magazynu lub wysyłania plików z przeglądarki.

Na telefonie menu znajduje się na dole, a karty układają się pionowo. Na komputerze nawigacja jest po boku.

## Aktualizacja i logowanie

Przy aktualizacji zachowaj własne `config.php` i `data/`. Podmień aktualne pliki strony razem — w szczególności `index.php`, `api.php`, `lib.php` i `dashboard.php` — i zaloguj się ponownie.

Jeśli po logowaniu widzisz JSON „Zaloguj się.” pod `api.php?action=login`, sprawdź kompletność aktualizacji oraz zgodność adresu strony i katalogu. Nie publikuj hasła lub klucza w zgłoszeniu błędu.

Safari pokazuje domenę w pasku adresu; strona nie może zastąpić jej własną nazwą. Nazwę aplikacji można wykorzystać przy dodaniu strony do ekranu początkowego.

## Zapamiętanie logowania i ustawienia drukarek

Zaznacz **Zapamiętaj mnie na 30 dni** na stronie logowania. Sesja bez tej opcji ma limit 12 godzin. Wylogowanie lub zmiana hasła unieważniają dostęp. Skrót dodany do ekranu początkowego telefonu może potrzebować pierwszego logowania oddzielnie od Safari; potem działa ten sam mechanizm zapamiętania.

Preferencja ukrywania EXT jest przenoszona z aplikacji zarówno do lokalnego panelu, jak i mostu hostingowego. Aby zobaczyć tę poprawkę, zaktualizuj aplikację oraz pliki hostingu.

Przy włączonym zdalnym sterowaniu żarówka w nagłówku oferuje **Zgaś we wszystkich / Włącz we wszystkich** dla połączonych, obsługiwanych drukarek. Tryb tylko do podglądu nie pozwala wysłać tych poleceń.

Moduł serwisu nie udostępnia jeszcze w WWW formularzy checklist, problemów i części. Status „W serwisie” jest jednak uwzględniany przy zgodności drukarki w Farmie.
