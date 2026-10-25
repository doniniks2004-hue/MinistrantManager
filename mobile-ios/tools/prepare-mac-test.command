#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Ten skrypt uruchom na MacBooku.'; exit 1
fi
for command_name in flutter dart pod xcodebuild; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Brakuje: $command_name. Instrukcja: docs/MACBOOK-TEST-START.md"; exit 1
  fi
done
if ! flutter --version | head -1 | grep -q 'Flutter 3.47.3 '; then
  echo 'Wymagana wersja Flutter 3.47.3 (ta sama co w CI).'; exit 1
fi
xcodebuild -version
flutter pub get --enforce-lockfile
dart run flutter_native_splash:create
dart run build_runner build --delete-conflicting-outputs
# Generate the local SDK paths and Flutter Xcode configuration, without signing.
flutter build ios --debug --no-codesign --config-only
(cd ios && pod install)
open ios/Runner.xcworkspace
printf '\nProjekt gotowy w Xcode. Wybierz Runner > Signing & Capabilities > Team, podłącz iPhone i naciśnij Run.\n'
printf 'Dla bezpłatnego Personal Team przeczytaj docs/MACBOOK-TEST-START.md.\n'
