#!/bin/bash
# Uruchom na prawdziwej Witosie:
#   ./smoke_test.sh https://parafia-witosa.ministrant.eu mobile_test_witosa
#
# Hasło NIE jest argumentem CLI (nie może trafić do historii powłoki ani
# do listy procesów, np. `ps aux`) — skrypt zapyta o nie interaktywnie,
# bez echa na ekranie (read -s).

set -uo pipefail

DOMAIN="${1:?Podaj domenę, np. https://parafia-witosa.ministrant.eu}"
USERNAME="${2:?Podaj username konta testowego}"

read -r -s -p "Hasło dla $USERNAME: " PASSWORD
echo
if [ -z "$PASSWORD" ]; then
  echo "Puste hasło — przerywam." >&2
  exit 1
fi

INSTALLATION_ID="550e8400-e29b-41d4-a716-446655440000"
WRONG_INSTALLATION_ID="660e8400-e29b-41d4-a716-446655440001"

PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS  [$name] HTTP $actual"
    PASS=$((PASS+1))
  else
    echo "FAIL  [$name] oczekiwano HTTP $expected, dostano $actual"
    FAIL=$((FAIL+1))
  fi
}

echo "=== Test 1: GET /config ==="
CODE=$(curl -s -o /tmp/smoke_config.json -w "%{http_code}" "$DOMAIN/api/v1/mobile/config" -H "X-Installation-Id: $INSTALLATION_ID")
check "config" 200 "$CODE"
echo "  odpowiedź: $(cat /tmp/smoke_config.json)"

echo
echo "=== Test 2: POST /session/login (poprawne dane) ==="
LOGIN_RESPONSE=$(curl -s -X POST "$DOMAIN/api/v1/mobile/session/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\",\"installation_id\":\"$INSTALLATION_ID\"}")
echo "  odpowiedź: $LOGIN_RESPONSE"
TOKEN=$(echo "$LOGIN_RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null)
if [ -n "$TOKEN" ]; then
  echo "PASS  [login] token otrzymany"
  PASS=$((PASS+1))
else
  echo "FAIL  [login] brak tokenu w odpowiedzi"
  FAIL=$((FAIL+1))
fi

echo
echo "=== Test 3: GET /bootstrap (poprawny token + installation_id) ==="
CODE=$(curl -s -o /tmp/smoke_bootstrap.json -w "%{http_code}" "$DOMAIN/api/v1/mobile/bootstrap" \
  -H "Authorization: Bearer $TOKEN" -H "X-Installation-Id: $INSTALLATION_ID")
check "bootstrap" 200 "$CODE"
echo "  odpowiedź (zapisana w /tmp/smoke_bootstrap.json):"
python3 -m json.tool /tmp/smoke_bootstrap.json 2>/dev/null || cat /tmp/smoke_bootstrap.json

echo
echo "=== Test 4: brak tokenu -> 401 ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$DOMAIN/api/v1/mobile/bootstrap" -H "X-Installation-Id: $INSTALLATION_ID")
check "brak tokenu" 401 "$CODE"

echo
echo "=== Test 5: zły token -> 401 ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$DOMAIN/api/v1/mobile/bootstrap" -H "Authorization: Bearer zly-token-xxxxx" -H "X-Installation-Id: $INSTALLATION_ID")
check "zły token" 401 "$CODE"

echo
echo "=== Test 6: brak X-Installation-Id -> 400 ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$DOMAIN/api/v1/mobile/bootstrap" -H "Authorization: Bearer $TOKEN")
check "brak X-Installation-Id" 400 "$CODE"

echo
echo "=== Test 7: poprawny token, INNY installation_id -> odmowa (401) ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$DOMAIN/api/v1/mobile/bootstrap" -H "Authorization: Bearer $TOKEN" -H "X-Installation-Id: $WRONG_INSTALLATION_ID")
check "inny installation_id" 401 "$CODE"

echo
echo "=== Test 8: złe hasło -> 401 ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$DOMAIN/api/v1/mobile/session/login" \
  -H "Content-Type: application/json" -d "{\"username\":\"$USERNAME\",\"password\":\"zle-haslo-na-pewno\",\"installation_id\":\"$INSTALLATION_ID\"}")
check "złe hasło" 401 "$CODE"

echo
echo "=== Test 9: zły UUID installation_id -> 400 ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$DOMAIN/api/v1/mobile/session/login" \
  -H "Content-Type: application/json" -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\",\"installation_id\":\"nie-jest-to-uuid\"}")
check "zły UUID" 400 "$CODE"

echo
echo "========================================="
echo "WYNIK: $PASS PASS, $FAIL FAIL"
echo "========================================="
[ "$FAIL" -eq 0 ]
