# Instalacja z przeglądarki i menedżera plików

Wymagania: PHP 8.1+, mysqli, HTTPS, działająca istniejąca konfiguracja `public_html/config/database.php`, zapis w katalogu obok `public_html`. Nie są potrzebne SSH, exec, shell_exec ani passthru. Wspierany jest profil Witosa-compatible. Instalacja nie jest audytem centralnego panelu ani pełną aktualizacją starej strony parafii.

1. W panelu hostingu wykonaj kopię plików i eksport bazy (np. phpMyAdmin → Eksport). Zachowaj obie kopie poza publicznym katalogiem strony.
2. Rozpakuj **właściwy wewnętrzny** `universal-parish-installer.zip` do katalogu `mm-installer` obok `public_html`. Muszą istnieć `mm-installer/install.php` i `mm-installer/browser/controller.php`, a nie dodatkowy zagnieżdżony katalog.
3. W `mm-installer/browser` skopiuj `access.example.php` jako `access.php`. Edytuj wartość `access_key`: wstaw **nowe losowe hasło minimum 32 znaków**, wygenerowane np. menedżerem haseł. Zachowaj cudzysłowy/składnię PHP. Najwygodniejsze są losowe litery i cyfry. To osobny klucz instalatora, nie hasło konta i nie sekret MobileAPI. Plik zostaje poza `public_html`.
4. Skopiuj **tylko** `mm-installer/browser/mm-setup.php` do `public_html/mm-setup.php`. Nie przenoś tam całej paczki, migracji, kopii ani pliku access.php.
5. Otwórz `https://ADRES-PARAFII/mm-setup.php`. Zaloguj się osobnym kluczem instalatora.
6. Kliknij **Sprawdź profil parafii**. To rozpoznanie struktury, nie pełny test produkcji. Jeśli profil nie jest rozpoznany, przerwij.
7. Potwierdź posiadanie kopii plików i bazy. Jeśli sekret MobileAPI nie jest już skonfigurowany, wpisz indywidualny sekret tej parafii. Kliknij **Zainstaluj MobileAPI**. Nie uruchamiaj kilku kopii instalatora i nie odświeżaj strony w trakcie.
8. Po `MOBILEAPI INSTALL OK` zapisz pokazany raport i lokalizację kopii. Instalator zapisze `browser/completed.lock` i odmówi kolejnego uruchomienia. Usuń `public_html/mm-setup.php` oraz `mm-installer/browser/access.php` menedżerem plików. Pozostałą paczkę możesz usunąć po odbiorze; zachowaj kopie.
9. Sprawdź zwykłą stronę parafii, aktywację i logowanie aplikacji na koncie testowym.

Jeśli nie masz dostępu do katalogu obok `public_html`, nie umieszczaj całej paczki w katalogu publicznym — potrzebny jest dostęp przez panel hostingu lub pomoc administratora.

## Błąd / cofnięcie

Błąd instalacji uruchamia przywrócenie kopii plików, o ile PHP może dokończyć obsługę błędu. Twarde przerwanie procesu hostingu może temu przeszkodzić. Migracje bazy nie są cofane automatycznie.

Przy błędzie zachowaj komunikat, nie ponawiaj instalacji w ciemno. Użyj kopii panelu hostingu, aby przywrócić pliki i bazę do tego samego momentu. `rollback.php` jest dodatkowym narzędziem CLI; instalator WWW nie oferuje publicznego endpointu do cofania produkcji.

Klucz instalatora i sekret MobileAPI nie powinny trafiać do logów, zrzutów ekranu ani wiadomości.
