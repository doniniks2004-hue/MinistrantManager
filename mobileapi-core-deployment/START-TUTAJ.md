# Instalacja MobileAPI na drugiej parafii — File Manager

## Co przygotować

Działającą stronę Ministrant Manager z istniejącą bazą i public_html/config/database.php, PHP 8.1 lub nowsze z mysqli i Argon2id, HTTPS oraz dostęp do katalogu nadrzędnego public_html. Wymagany jest cURL albo allow_url_fopen do komunikacji z centralą. Sam File Manager wystarczy; SSH nie jest potrzebne.

W panelu app.ministrant.eu przygotuj wpis właściwej parafii, jej poprawną subdomenę, aktywną obsługę mobilną, indywidualny sekret MobileAPI i kod aktywacji. Nie używaj sekretu parafii testowej. Zgodność sekretu po obu stronach jest konieczna; jego ponowne wygenerowanie wymaga aktualizacji konfiguracji na hostingu.

## Kolejność

1. Zrób w panelu hostingu kopię plików oraz eksport bazy. Instalator tworzy własne kopie zmienianych plików, ale nie robi pełnego eksportu bazy.
2. Utwórz katalog mm-installer obok public_html. Wgraj ZIP i rozpakuj jego zawartość w mm-installer. Sprawdź, że istnieje mm-installer/install.php.
3. W mm-installer/browser skopiuj access.example.php do access.php. Wstaw własny losowy klucz instalatora minimum 32 znaków. To osobne hasło, inne niż sekret MobileAPI i hasło użytkownika.
4. Skopiuj mm-installer/browser/mm-setup.php do public_html/mm-setup.php.
5. Otwórz https://ADRES-PARAFII/mm-setup.php i zaloguj się kluczem instalatora.
6. Wybierz „Sprawdź profil parafii”. Brak zgodnego profilu oznacza zatrzymanie; nie omijaj tego sprawdzenia.
7. Potwierdź kopię plików i bazy, podaj sekret MobileAPI tej parafii i wybierz „Zainstaluj MobileAPI”. Nie odświeżaj strony w trakcie.
8. Po komunikacie MOBILEAPI INSTALL OK zachowaj raport. Usuń public_html/mm-setup.php oraz mm-installer/browser/access.php.
9. Sprawdź zwykłe logowanie na stronie parafii, a następnie test telefonu opisany poniżej.

Cała paczka, kopie i plik access.php pozostają poza public_html. Jeśli nie widzisz katalogu nadrzędnego w File Managerze, nie rozpakowuj całości do public_html — potrzebny jest dostęp do katalogu domeny.

## Test nowego użytkownika na telefonie

1. Utwórz zwykłe konto testowe w istniejącym panelu tej parafii.
2. W aplikacji wybierz zmianę parafii lub rozpocznij od czystej konfiguracji.
3. Aktywuj właściwą parafię jej kodem QR.
4. Zaloguj się loginem i hasłem nowo utworzonego konta. Jeśli wymagane, wykonaj pierwszą zmianę hasła.
5. Sprawdź nazwę parafii, użytkownika i dostępne dane.
6. Wyloguj się, zamknij i otwórz aplikację; sprawdź, że pozostaje ekran logowania.
7. Ponownie się zaloguj i sprawdź ponowne otwarcie aplikacji oraz podstawowe działanie offline po pobraniu danych.

Sam kod QR identyfikuje/aktywuje parafię i urządzenie; nie zastępuje logowania użytkownika.

## Gdy instalacja się nie powiedzie

Zachowaj komunikat błędu i nie ponawiaj w ciemno. Instalator próbuje przywrócić zmienione pliki, lecz migracje bazy pozostają. Twarde przerwanie przez hosting może uniemożliwić automatyczne przywrócenie. Pełny powrót do poprzedniego stanu wymaga zgodnych kopii plików i bazy. Narzędzie rollback.php wymaga CLI.

## Pochodzenie i granice weryfikacji

Źródło: commit ab3c6832c56c9c13c31e24c6922a7d5c6b05099a repozytorium MinistrantManager. Paczka zawiera instalator WWW, migracje 001–006, poprawki routingu i zgodności logowania obecne w tej rewizji. Nie zawiera danych ani sekretów parafii.

Nie porównano tej paczki z plikami działającymi na parafii testowej ani z bazą drugiej parafii. Zgodność profilu nie oznacza pełnego testu produkcji. Wyniki testów tej paczki są podane osobno; test telefonu na drugiej parafii pozostaje wymagany.
