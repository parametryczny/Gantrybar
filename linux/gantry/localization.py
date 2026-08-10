from __future__ import annotations

import locale
import os
from collections.abc import Mapping


SUPPORTED_LANGUAGES = ("pl", "en", "de")


def normalize_language(language: str | None) -> str:
    value = (language or "").strip().lower().replace("_", "-").split("-", 1)[0]
    return value if value in SUPPORTED_LANGUAGES else "en"


def detected_language(locale_name: str | None = None) -> str:
    if locale_name is None:
        locale_name = locale.getlocale()[0] or os.environ.get("LANG", "")
    return normalize_language(locale_name)


CATALOGS: dict[str, dict[str, str]] = {
    "pl": {
        "printers": "drukarek", "online": "online", "collapse": "Zwiń", "expand": "Rozwiń",
        "add": "Dodaj drukarkę", "scan": "Skanuj sieć", "settings": "Ustawienia",
        "quit": "Zakończ", "close": "Zamknij", "save": "Zapisz", "cancel": "Anuluj",
        "edit": "Edytuj drukarkę", "remove": "Usuń drukarkę", "import": "Importuj z Bambu Studio",
        "name": "Nazwa", "host": "Adres IP / host", "serial": "Numer seryjny",
        "code": "Kod dostępu / klucz API", "port": "Port", "found": "Wykryte drukarki",
        "kind": "Typ drukarki", "api_optional": "Klucz API (opcjonalny)",
        "searching": "Szukam drukarek…", "none": "Nie znaleziono drukarek",
        "language": "Język", "theme": "Wygląd", "dark": "Ciemny", "light": "Jasny",
        "targets": "Dodatkowe adresy VPN", "targets_hint": "IP, zakres a-b lub CIDR /n (maks. 1024 adresy)",
        "autostart": "Uruchamiaj po zalogowaniu", "notifications": "Powiadomienia",
        "finished_notice": "Zakończenie druku", "error_notice": "Błędy drukarki",
        "paused_notice": "Wstrzymanie druku", "low_notice": "Niski poziom filamentu",
        "humidity_notice": "Wysoka wilgotność AMS", "quiet": "Godziny ciszy",
        "offline_notice": "Utrata połączenia", "printing": "Drukowanie", "ready": "Gotowa",
        "paused": "Wstrzymana", "finished": "Zakończono", "error": "Błąd", "offline": "Offline",
        "invalid": "Sprawdź wymagane pola i zakres portu.", "secret_error": "Nie udało się zapisać kodu w systemowym pęku kluczy.",
        "studio_missing": "Nie znaleziono konfiguracji Bambu Studio albo zapisanych drukarek.",
        "certificate": "Certyfikat drukarki zmienił się. Połączenie zostało zablokowane.",
        "rejected": "Drukarka odrzuciła kod dostępu.", "moonraker_missing": "Nie znaleziono API Moonraker.", "version": "Wersja",
        "import_consent": "Pozwól odczytać konfigurację Bambu Studio",
        "import_hint": "Przyspiesza dodawanie, ale odczytuje lokalny plik slicera z kodami dostępu. Nic nie jest czytane, dopóki tego nie zaznaczysz.",
        "camera": "Kamera w Bambu Studio", "open_in": "Otwórz w {name}",
        "import_many_csv": "Importuj wiele drukarek z CSV", "import_csv": "Importuj CSV",
        "import_csv_title": "Importuj drukarki z CSV", "imported_count": "Zaimportowano {count} drukarek.",
        "bambu_info": "MQTT/TLS • port 8883. Dodatkowy adres VPN wpisz wyżej i przeskanuj ponownie.",
        "klipper_info": "Moonraker • port 7125. Happy Hare MMU i Creality CFS są wykrywane automatycznie.",
        "prusa_api_key": "Klucz API PrusaLink", "prusa_info": "PrusaLink • port 80 • połączenie lokalne, bez konta Prusy.",
        "legend": "Legenda kolorów", "legend_blue": "Niebieski — drukowanie", "legend_green": "Zielony — zakończono",
        "legend_red": "Czerwony — błąd", "legend_gray": "Szary — offline / bezczynna",
        "low_filament_body": "Niski poziom filamentu: {slot} ({percent}%)",
        "workshop_tag": "WARSZTAT • RASPBERRY PI", "configuration": "Konfiguracja", "monitoring_active": "Monitoring aktywny",
        "kiosk_summary": "{printers} drukarek   •   {online} online   •   {printing} drukuje{errors}",
        "kiosk_errors": "   •   {count} błąd", "attention": "⚠  {names}  •  drukarka wymaga uwagi",
        "remote_unavailable": "Panel zdalny niedostępny • użyj Konfiguracji na ekranie",
        "remote_footer": "Telefon: {url}   •   kod parowania {code}", "screen_configuration": "Konfiguracja ekranu warsztatowego",
        "web_unavailable": "Panel z telefonu jest niedostępny. Sprawdź port 8443 i pakiet openssl.",
        "computer_pairing": "Telefon / komputer:\n<b>{url}</b>\nKod parowania: <b>{code}</b>",
        "csv_template_documents": "Dokumenty: szablon CSV", "reconnect": "Połącz ponownie", "new_pairing_code": "Nowy kod parowania",
        "ssh_hint": "SSH służy tylko do aktualizacji i diagnostyki.", "operation_timeout": "Przekroczono czas operacji.",
        "unknown_error": "Nieznany błąd.", "printer_added": "Drukarka została dodana.",
        "imported_delete_csv": "Zaimportowano {count} drukarek. Usuń plik CSV, ponieważ zawiera kody dostępu.",
        "import_complete": "Import zakończony", "import_failed": "Nie udało się zaimportować CSV",
        "csv_files": "Pliki CSV", "save_template_title": "Zapisz szablon CSV", "template_saved": "Szablon zapisany",
        "template_save_failed": "Nie udało się zapisać szablonu", "printer_not_found": "Nie znaleziono drukarki.",
        "printer_removed": "Drukarka została usunięta.", "web_title": "Gantry Workshop",
        "rpi_configuration": "Konfiguracja Raspberry Pi", "pairing_label": "Kod parowania z ekranu", "connect": "Połącz",
        "certificate_hint": "Połączenie jest szyfrowane lokalnym certyfikatem. Przy pierwszym wejściu przeglądarka może poprosić o zaakceptowanie lokalnego certyfikatu Gantry.",
        "too_many_attempts": "Za dużo prób. Odczekaj minutę.", "invalid_pairing": "Niepoprawny kod parowania.",
        "session_expired": "Sesja wygasła. Sparuj urządzenie ponownie.", "not_found": "Nie znaleziono",
        "unsupported_kind": "Wybierz obsługiwany typ drukarki.",
        "form_required": "Uzupełnij dane wymagane dla wybranego typu drukarki i poprawny port.",
        "form_format": "Adres lub numer seryjny ma niepoprawny format.", "local_panel": "{count} drukarek • panel lokalny",
        "printer_status": "Status drukarek", "no_printers_yet": "Nie dodano jeszcze drukarek.",
        "csv_description": "Pobierz szablon, uzupełnij go na komputerze i wczytaj tutaj. Typy: bambu, klipper, prusa. CSV zawiera kody dostępu — usuń go po imporcie.",
        "download_csv_template": "Pobierz szablon CSV", "import_printers": "Importuj drukarki", "add_manually": "Dodaj drukarkę ręcznie",
        "type": "Typ", "access_api": "Kod dostępu / klucz API", "add_connect": "Dodaj i połącz",
        "csv_no_header": "Plik CSV nie ma nagłówka.", "csv_missing_columns": "Brak kolumn: {columns}",
        "csv_unknown_kind": "Wiersz {line}: nieznany typ drukarki {kind}.", "csv_invalid_port": "Wiersz {line}: niepoprawny port.",
        "csv_missing_data": "Wiersz {line}: brakuje wymaganych danych.", "csv_invalid_address": "Wiersz {line}: niepoprawny adres lub port.",
        "csv_duplicate_serial": "Wiersz {line}: powtórzony numer seryjny {serial}.", "csv_too_many": "Plik zawiera więcej niż {maximum} drukarek.",
        "csv_empty": "Plik CSV nie zawiera drukarek.",
    },
    "en": {
        "printers": "printers", "online": "online", "collapse": "Collapse", "expand": "Expand",
        "add": "Add printer", "scan": "Scan network", "settings": "Settings", "quit": "Quit", "close": "Close",
        "save": "Save", "cancel": "Cancel", "edit": "Edit printer", "remove": "Remove printer", "import": "Import from Bambu Studio",
        "name": "Name", "host": "IP address / host", "serial": "Serial number", "code": "Access code / API key", "port": "Port",
        "found": "Discovered printers", "kind": "Printer type", "api_optional": "API key (optional)",
        "searching": "Scanning for printers…", "none": "No printers found", "language": "Language", "theme": "Appearance",
        "dark": "Dark", "light": "Light", "targets": "Additional VPN targets", "targets_hint": "IP, a-b range or CIDR /n (up to 1024 addresses)",
        "autostart": "Start after login", "notifications": "Notifications", "finished_notice": "Print finished", "error_notice": "Printer errors",
        "paused_notice": "Print paused", "low_notice": "Low filament", "humidity_notice": "High AMS humidity", "quiet": "Quiet hours",
        "offline_notice": "Connection lost", "printing": "Printing", "ready": "Ready", "paused": "Paused", "finished": "Finished",
        "error": "Error", "offline": "Offline", "invalid": "Check the required fields and port range.",
        "secret_error": "Could not store the code in the system keyring.", "studio_missing": "Bambu Studio configuration or stored printers were not found.",
        "certificate": "The printer certificate changed. The connection was blocked.", "rejected": "The printer rejected the access code.",
        "moonraker_missing": "Moonraker API was not found.",
        "version": "Version", "import_consent": "Allow reading the Bambu Studio configuration",
        "import_hint": "Speeds up adding, but reads the local slicer file containing access codes. Nothing is read until you tick this.",
        "camera": "Camera in Bambu Studio", "open_in": "Open in {name}", "import_many_csv": "Import multiple printers from CSV",
        "import_csv": "Import CSV", "import_csv_title": "Import printers from CSV", "imported_count": "Imported {count} printers.",
        "bambu_info": "MQTT/TLS • port 8883. Enter an additional VPN address above and scan again.",
        "klipper_info": "Moonraker • port 7125. Happy Hare MMU and Creality CFS are detected automatically.",
        "prusa_api_key": "PrusaLink API key", "prusa_info": "PrusaLink • port 80 • local connection, no Prusa account required.",
        "legend": "Color legend", "legend_blue": "Blue — printing", "legend_green": "Green — finished", "legend_red": "Red — error",
        "legend_gray": "Gray — offline / idle", "low_filament_body": "Low filament: {slot} ({percent}%)",
        "workshop_tag": "WORKSHOP • RASPBERRY PI", "configuration": "Configuration", "monitoring_active": "Monitoring active",
        "kiosk_summary": "{printers} printers   •   {online} online   •   {printing} printing{errors}",
        "kiosk_errors": "   •   {count} error", "attention": "⚠  {names}  •  printer needs attention",
        "remote_unavailable": "Remote panel unavailable • use on-screen Configuration", "remote_footer": "Phone: {url}   •   pairing code {code}",
        "screen_configuration": "Workshop screen configuration", "web_unavailable": "Phone panel unavailable. Check port 8443 and the openssl package.",
        "computer_pairing": "Phone / computer:\n<b>{url}</b>\nPairing code: <b>{code}</b>", "csv_template_documents": "Documents: CSV template",
        "reconnect": "Reconnect", "new_pairing_code": "New pairing code", "ssh_hint": "SSH is only for updates and diagnostics.",
        "operation_timeout": "The operation timed out.", "unknown_error": "Unknown error.", "printer_added": "Printer added.",
        "imported_delete_csv": "Imported {count} printers. Delete the CSV file because it contains access codes.",
        "import_complete": "Import complete", "import_failed": "Could not import CSV", "csv_files": "CSV files",
        "save_template_title": "Save CSV template", "template_saved": "Template saved", "template_save_failed": "Could not save template",
        "printer_not_found": "Printer not found.", "printer_removed": "Printer removed.", "web_title": "Gantry Workshop",
        "rpi_configuration": "Raspberry Pi configuration", "pairing_label": "Pairing code from the screen", "connect": "Connect",
        "certificate_hint": "The connection is encrypted with a local certificate. On first access, your browser may ask you to accept the local Gantry certificate.",
        "too_many_attempts": "Too many attempts. Wait one minute.", "invalid_pairing": "Invalid pairing code.",
        "session_expired": "Session expired. Pair the device again.", "not_found": "Not found", "unsupported_kind": "Choose a supported printer type.",
        "form_required": "Complete the required data for the selected printer type and enter a valid port.",
        "form_format": "The address or serial number has an invalid format.", "local_panel": "{count} printers • local panel",
        "printer_status": "Printer status", "no_printers_yet": "No printers added yet.",
        "csv_description": "Download the template, complete it on your computer, and upload it here. Types: bambu, klipper, prusa. The CSV contains access codes — delete it after importing.",
        "download_csv_template": "Download CSV template", "import_printers": "Import printers", "add_manually": "Add printer manually",
        "type": "Type", "access_api": "Access code / API key", "add_connect": "Add and connect", "csv_no_header": "The CSV file has no header.",
        "csv_missing_columns": "Missing columns: {columns}", "csv_unknown_kind": "Row {line}: unknown printer type {kind}.",
        "csv_invalid_port": "Row {line}: invalid port.", "csv_missing_data": "Row {line}: required data is missing.",
        "csv_invalid_address": "Row {line}: invalid address or port.", "csv_duplicate_serial": "Row {line}: duplicate serial number {serial}.",
        "csv_too_many": "The file contains more than {maximum} printers.", "csv_empty": "The CSV file contains no printers.",
    },
    "de": {
        "printers": "Drucker", "online": "online", "collapse": "Einklappen", "expand": "Ausklappen",
        "add": "Drucker hinzufügen", "scan": "Netzwerk durchsuchen", "settings": "Einstellungen", "quit": "Beenden", "close": "Schließen",
        "save": "Speichern", "cancel": "Abbrechen", "edit": "Drucker bearbeiten", "remove": "Drucker entfernen", "import": "Aus Bambu Studio importieren",
        "name": "Name", "host": "IP-Adresse / Host", "serial": "Seriennummer", "code": "Zugriffscode / API-Schlüssel", "port": "Port",
        "found": "Gefundene Drucker", "kind": "Druckertyp", "api_optional": "API-Schlüssel (optional)",
        "searching": "Drucker werden gesucht …", "none": "Keine Drucker gefunden", "language": "Sprache", "theme": "Darstellung",
        "dark": "Dunkel", "light": "Hell", "targets": "Zusätzliche VPN-Adressen", "targets_hint": "IP-Adresse, Bereich a-b oder CIDR /n (bis zu 1024 Adressen)",
        "autostart": "Bei der Anmeldung starten", "notifications": "Mitteilungen", "finished_notice": "Druck abgeschlossen", "error_notice": "Druckerfehler",
        "paused_notice": "Druck pausiert", "low_notice": "Niedriger Filamentstand", "humidity_notice": "Hohe AMS-Luftfeuchtigkeit", "quiet": "Ruhezeiten",
        "offline_notice": "Verbindung verloren", "printing": "Druckt", "ready": "Bereit", "paused": "Pausiert", "finished": "Abgeschlossen",
        "error": "Fehler", "offline": "Offline", "invalid": "Prüfe die Pflichtfelder und den Portbereich.",
        "secret_error": "Der Code konnte nicht im Systemschlüsselbund gespeichert werden.", "studio_missing": "Keine Bambu-Studio-Konfiguration oder gespeicherten Drucker gefunden.",
        "certificate": "Das Druckerzertifikat hat sich geändert. Die Verbindung wurde blockiert.", "rejected": "Der Drucker hat den Zugriffscode abgelehnt.",
        "moonraker_missing": "Die Moonraker-API wurde nicht gefunden.",
        "version": "Version", "import_consent": "Lesen der Bambu-Studio-Konfiguration erlauben",
        "import_hint": "Beschleunigt das Hinzufügen, liest aber die lokale Slicer-Datei mit Zugriffscodes. Ohne deine Zustimmung wird nichts gelesen.",
        "camera": "Kamera in Bambu Studio", "open_in": "In {name} öffnen", "import_many_csv": "Mehrere Drucker aus CSV importieren",
        "import_csv": "CSV importieren", "import_csv_title": "Drucker aus CSV importieren", "imported_count": "{count} Drucker importiert.",
        "bambu_info": "MQTT/TLS • Port 8883. Trage oben eine zusätzliche VPN-Adresse ein und suche erneut.",
        "klipper_info": "Moonraker • Port 7125. Happy Hare MMU und Creality CFS werden automatisch erkannt.",
        "prusa_api_key": "PrusaLink-API-Schlüssel", "prusa_info": "PrusaLink • Port 80 • lokale Verbindung, kein Prusa-Konto erforderlich.",
        "legend": "Farblegende", "legend_blue": "Blau — druckt", "legend_green": "Grün — abgeschlossen", "legend_red": "Rot — Fehler",
        "legend_gray": "Grau — offline / inaktiv", "low_filament_body": "Niedriger Filamentstand: {slot} ({percent} %)",
        "workshop_tag": "WERKSTATT • RASPBERRY PI", "configuration": "Konfiguration", "monitoring_active": "Überwachung aktiv",
        "kiosk_summary": "{printers} Drucker   •   {online} online   •   {printing} druckt{errors}",
        "kiosk_errors": "   •   {count} Fehler", "attention": "⚠  {names}  •  Drucker benötigt Aufmerksamkeit",
        "remote_unavailable": "Remote-Panel nicht verfügbar • nutze die Konfiguration auf dem Bildschirm",
        "remote_footer": "Telefon: {url}   •   Kopplungscode {code}", "screen_configuration": "Konfiguration des Werkstattbildschirms",
        "web_unavailable": "Das Panel für das Telefon ist nicht verfügbar. Prüfe Port 8443 und das Paket openssl.",
        "computer_pairing": "Telefon / Computer:\n<b>{url}</b>\nKopplungscode: <b>{code}</b>", "csv_template_documents": "Dokumente: CSV-Vorlage",
        "reconnect": "Neu verbinden", "new_pairing_code": "Neuer Kopplungscode", "ssh_hint": "SSH dient nur für Updates und Diagnose.",
        "operation_timeout": "Zeitüberschreitung beim Vorgang.", "unknown_error": "Unbekannter Fehler.", "printer_added": "Drucker wurde hinzugefügt.",
        "imported_delete_csv": "{count} Drucker importiert. Lösche die CSV-Datei, da sie Zugriffscodes enthält.",
        "import_complete": "Import abgeschlossen", "import_failed": "CSV konnte nicht importiert werden", "csv_files": "CSV-Dateien",
        "save_template_title": "CSV-Vorlage speichern", "template_saved": "Vorlage gespeichert", "template_save_failed": "Vorlage konnte nicht gespeichert werden",
        "printer_not_found": "Drucker nicht gefunden.", "printer_removed": "Drucker wurde entfernt.", "web_title": "Gantry Werkstatt",
        "rpi_configuration": "Raspberry-Pi-Konfiguration", "pairing_label": "Kopplungscode vom Bildschirm", "connect": "Verbinden",
        "certificate_hint": "Die Verbindung ist mit einem lokalen Zertifikat verschlüsselt. Beim ersten Aufruf kann dein Browser verlangen, das lokale Gantry-Zertifikat zu akzeptieren.",
        "too_many_attempts": "Zu viele Versuche. Warte eine Minute.", "invalid_pairing": "Ungültiger Kopplungscode.",
        "session_expired": "Sitzung abgelaufen. Kopple das Gerät erneut.", "not_found": "Nicht gefunden", "unsupported_kind": "Wähle einen unterstützten Druckertyp.",
        "form_required": "Fülle die Pflichtfelder für den gewählten Druckertyp aus und gib einen gültigen Port ein.",
        "form_format": "Die Adresse oder Seriennummer hat ein ungültiges Format.", "local_panel": "{count} Drucker • lokales Panel",
        "printer_status": "Druckerstatus", "no_printers_yet": "Noch keine Drucker hinzugefügt.",
        "csv_description": "Lade die Vorlage herunter, fülle sie am Computer aus und lade sie hier hoch. Typen: bambu, klipper, prusa. Die CSV enthält Zugriffscodes — lösche sie nach dem Import.",
        "download_csv_template": "CSV-Vorlage herunterladen", "import_printers": "Drucker importieren", "add_manually": "Drucker manuell hinzufügen",
        "type": "Typ", "access_api": "Zugriffscode / API-Schlüssel", "add_connect": "Hinzufügen und verbinden", "csv_no_header": "Die CSV-Datei hat keine Kopfzeile.",
        "csv_missing_columns": "Fehlende Spalten: {columns}", "csv_unknown_kind": "Zeile {line}: unbekannter Druckertyp {kind}.",
        "csv_invalid_port": "Zeile {line}: ungültiger Port.", "csv_missing_data": "Zeile {line}: Pflichtangaben fehlen.",
        "csv_invalid_address": "Zeile {line}: ungültige Adresse oder ungültiger Port.", "csv_duplicate_serial": "Zeile {line}: doppelte Seriennummer {serial}.",
        "csv_too_many": "Die Datei enthält mehr als {maximum} Drucker.", "csv_empty": "Die CSV-Datei enthält keine Drucker.",
    },
}


_STAGE_TRIPLETS: dict[int, tuple[str, str, str]] = {
    0: ("Drukowanie", "Printing", "Druckt"), 1: ("Poziomowanie stołu", "Auto bed leveling", "Automatische Druckbettnivellierung"),
    2: ("Nagrzewanie stołu", "Heating bed", "Druckbett wird aufgeheizt"), 3: ("Kalibracja drgań", "Vibration calibration", "Vibrationskalibrierung"),
    4: ("Zmiana filamentu", "Changing filament", "Filament wird gewechselt"), 5: ("Oczekiwanie", "Waiting", "Wartet"),
    6: ("Brak filamentu", "Filament runout", "Filament aufgebraucht"), 7: ("Nagrzewanie dyszy", "Heating nozzle", "Düse wird aufgeheizt"),
    8: ("Kalibracja ekstruzji", "Calibrating extrusion", "Extrusion wird kalibriert"), 9: ("Skanowanie stołu", "Scanning bed", "Druckbett wird gescannt"),
    10: ("Kontrola pierwszej warstwy", "Inspecting first layer", "Erste Schicht wird geprüft"), 11: ("Rozpoznawanie płyty", "Identifying build plate", "Druckplatte wird erkannt"),
    12: ("Kalibracja LiDAR", "Calibrating LiDAR", "LiDAR wird kalibriert"), 13: ("Bazowanie", "Homing", "Referenzfahrt"),
    14: ("Czyszczenie dyszy", "Cleaning nozzle", "Düse wird gereinigt"), 15: ("Kontrola temperatury dyszy", "Checking nozzle temperature", "Düsentemperatur wird geprüft"),
    16: ("Wstrzymano przez użytkownika", "Paused by user", "Von dir pausiert"), 17: ("Otwarta przednia osłona", "Front cover open", "Frontabdeckung geöffnet"),
    18: ("Kalibracja LiDAR", "Calibrating LiDAR", "LiDAR wird kalibriert"), 19: ("Kalibracja przepływu", "Calibrating flow", "Fluss wird kalibriert"),
    20: ("Błąd temperatury dyszy", "Nozzle temperature issue", "Problem mit der Düsentemperatur"), 21: ("Błąd temperatury stołu", "Bed temperature issue", "Problem mit der Druckbetttemperatur"),
    22: ("Wyładowanie filamentu", "Unloading filament", "Filament wird entladen"), 23: ("Wykryto pominięty krok", "Skipped step detected", "Schrittverlust erkannt"),
    24: ("Ładowanie filamentu", "Loading filament", "Filament wird geladen"), 25: ("Kalibracja silników", "Calibrating motors", "Motoren werden kalibriert"),
    26: ("Utracono połączenie z AMS", "AMS connection lost", "AMS-Verbindung verloren"), 27: ("Niska prędkość wentylatora", "Low heatbreak fan speed", "Heatbreak-Lüfter zu langsam"),
    28: ("Błąd temperatury komory", "Chamber temperature issue", "Problem mit der Bauraumtemperatur"), 29: ("Chłodzenie komory", "Cooling chamber", "Bauraum wird gekühlt"),
    30: ("Pauza z G-code", "Paused by G-code", "Durch G-Code pausiert"), 31: ("Test dźwięku silników", "Motor noise test", "Motorgeräuschtest"),
    32: ("Filament na dyszy", "Filament covering nozzle", "Filament bedeckt die Düse"), 33: ("Błąd obcinaka", "Cutter issue", "Problem mit dem Filamentschneider"),
    34: ("Błąd pierwszej warstwy", "First layer issue", "Problem mit der ersten Schicht"), 35: ("Zatkana dysza", "Nozzle clog", "Düse verstopft"),
    36: ("Kontrola dokładności", "Checking accuracy", "Genauigkeit wird geprüft"), 37: ("Kalibracja dokładności", "Calibrating accuracy", "Genauigkeit wird kalibriert"),
    38: ("Weryfikacja dokładności", "Verifying accuracy", "Genauigkeit wird verifiziert"), 39: ("Kalibracja offsetu dyszy", "Calibrating nozzle offset", "Düsenversatz wird kalibriert"),
    40: ("Poziomowanie na gorąco", "High-temperature bed leveling", "Druckbettnivellierung bei hoher Temperatur"), 41: ("Kontrola szybkozłącza", "Checking quick release", "Schnellverschluss wird geprüft"),
    42: ("Kontrola drzwi i osłon", "Checking doors and covers", "Türen und Abdeckungen werden geprüft"), 43: ("Kalibracja lasera", "Calibrating laser", "Laser wird kalibriert"),
    44: ("Kontrola platformy", "Checking platform", "Plattform wird geprüft"), 45: ("Kontrola kamery BirdEye", "Checking BirdEye camera", "BirdEye-Kamera wird geprüft"),
    46: ("Kalibracja kamery BirdEye", "Calibrating BirdEye camera", "BirdEye-Kamera wird kalibriert"), 47: ("Poziomowanie stołu · 1", "Bed leveling · 1", "Druckbettnivellierung · 1"),
    48: ("Poziomowanie stołu · 2", "Bed leveling · 2", "Druckbettnivellierung · 2"), 49: ("Nagrzewanie komory", "Heating chamber", "Bauraum wird aufgeheizt"),
    50: ("Chłodzenie stołu", "Cooling bed", "Druckbett wird gekühlt"), 51: ("Druk linii kalibracyjnych", "Printing calibration lines", "Kalibrierungslinien werden gedruckt"),
    52: ("Kontrola materiału", "Checking material", "Material wird geprüft"), 53: ("Kalibracja kamery podglądu", "Calibrating live-view camera", "Livebildkamera wird kalibriert"),
    54: ("Oczekiwanie na temperaturę stołu", "Waiting for bed temperature", "Wartet auf Druckbetttemperatur"), 55: ("Kontrola pozycji materiału", "Checking material position", "Materialposition wird geprüft"),
    56: ("Kalibracja offsetu obcinaka", "Calibrating cutter offset", "Versatz des Filamentschneiders wird kalibriert"), 57: ("Pomiar powierzchni", "Measuring surface", "Oberfläche wird vermessen"),
    58: ("Przygotowanie termiczne", "Thermal preconditioning", "Thermische Vorbereitung"), 59: ("Bazowanie uchwytu ostrza", "Homing blade holder", "Referenzfahrt des Klingenhalters"),
    60: ("Kalibracja offsetu kamery", "Calibrating camera offset", "Kameraversatz wird kalibriert"), 61: ("Kalibracja uchwytu ostrza", "Calibrating blade holder", "Klingenhalter wird kalibriert"),
    62: ("Test wymiany hotendu", "Hotend pick-and-place test", "Hotend-Wechseltest"), 63: ("Stabilizacja temperatury komory", "Equalizing chamber temperature", "Bauraumtemperatur wird stabilisiert"),
    64: ("Przygotowanie hotendu", "Preparing hotend", "Hotend wird vorbereitet"), 65: ("Kalibracja wykrywania grudek", "Calibrating clump detection", "Klumpenerkennung wird kalibriert"),
    66: ("Oczyszczanie powietrza", "Purifying chamber air", "Bauraumluft wird gereinigt"), 67: ("Pomiar modułu obrotowego", "Measuring rotary attachment", "Drehmodul wird vermessen"),
    68: ("Przejazd nad zsyp", "Moving above purge chute", "Fährt über den Auswurfschacht"), 69: ("Chłodzenie dyszy", "Cooling nozzle", "Düse wird gekühlt"),
    70: ("Centrowanie głowicy", "Centering toolhead", "Werkzeugkopf wird zentriert"), 71: ("Dopasowanie łuków", "Arc fitting", "Bögen werden angepasst"),
    72: ("Rozpoznawanie hotendu", "Detecting hotend type", "Hotend-Typ wird erkannt"), 73: ("Kontrola ułożenia płyty", "Checking build plate alignment", "Ausrichtung der Druckplatte wird geprüft"),
    74: ("Kontrola powierzchni stołu", "Checking bed surface", "Druckbettoberfläche wird geprüft"), 75: ("Kontrola spodu stołu", "Checking bed underside", "Druckbettunterseite wird geprüft"),
    76: ("Wstępna ekstruzja", "Pre-extrusion", "Vor-Extrusion"), 77: ("Przygotowanie AMS", "Preparing AMS", "AMS wird vorbereitet"),
}

for number, values in _STAGE_TRIPLETS.items():
    for language, value in zip(SUPPORTED_LANGUAGES, values):
        CATALOGS[language][f"stage_{number}"] = value

_EXPECTED_KEYS = set(CATALOGS["en"])
if any(set(catalog) != _EXPECTED_KEYS for catalog in CATALOGS.values()):
    raise RuntimeError("Localization catalogs must contain identical keys")


def catalog(language: str | None) -> Mapping[str, str]:
    return CATALOGS[normalize_language(language)]


def tr(language: str | None, key: str, **values: object) -> str:
    text = CATALOGS[normalize_language(language)][key]
    return text.format(**values) if values else text


def stage_text(language: str | None, stage: int | None) -> str | None:
    key = f"stage_{stage}"
    return tr(language, key) if key in _EXPECTED_KEYS else None
