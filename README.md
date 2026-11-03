# Ministrant Manager — punkt startowy dla programisty

Ta gałąź `release/parish-installer-2026-11-03` zbiera kod aplikacji oraz instalator MobileAPI do istniejącej parafii. Bazuje na commicie `ab3c6832c56c9c13c31e24c6922a7d5c6b05099a`, użytym do poprawki menu sesji Androida.

## Gdzie zacząć

- [Instalacja na kolejnej parafii przez File Manager](mobileapi-core-deployment/START-TUTAJ.md)
- [Szczegóły instalatora WWW](mobileapi-core-deployment/browser/README-PL.md)
- [Silnik instalatora](mobileapi-core-deployment/install.php)
- [Testy instalatora](mobileapi-core-deployment/tests/)
- [Android](mobile-android/) i [iOS](mobile-ios/)
- [Panel centralny](backend/)

Gałąź główna może być starsza. Nie zakładaj, że aktualny kod działającego hostingu lub telefonów jest identyczny z main. Ta paczka jest odtworzona z repozytorium, bez porównania bajt po bajcie z działającą parafią testową.

## Zakres paczki

Instalator dodaje MobileAPI do już działającego Ministrant Managera. Nie instaluje całej strony parafii od zera i nie zastępuje panelu app.ministrant.eu. Profil nazywa się Witosa-compatible, lecz nie zawiera sekretu konkretnej parafii. Poprawki legacy z katalogu scripts są opcjonalne i nie są automatycznie wykonywane przez instalator WWW.

## Zbudowanie ZIP-a

Z katalogu repozytorium:
```sh
cd mobileapi-core-deployment
zip -r ../MM-instalator-parafii.zip .
```

Wersję źródła odnotuj wraz z archiwum. ZIP rozpakowuje się do mm-installer obok public_html, a do public_html kopiuje się tylko browser/mm-setup.php.

## Weryfikacja i przekazanie

Workflow `.github/workflows/mobileapi-test.yml` zawiera testy PHP i instalacji na MySQL, w tym instalację przez HTTP z wyłączonymi funkcjami powłoki, migracje, rollback i blokadę powtórnej instalacji. Przed uznaniem wydania za produkcyjne należy uzyskać zielony wynik tych testów dla konkretnego commita oraz odbiór na docelowym hostingu i telefonie.

Nie dodawaj do repozytorium access.php, sekretów MobileAPI, danych baz, kont użytkowników ani kluczy podpisywania aplikacji. Przykładowa konfiguracja pozostaje z placeholderami.
