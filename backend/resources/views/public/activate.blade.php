<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <title>Aktywuj Ministrant Manager</title>
    <style>
        body { font-family: -apple-system, Segoe UI, Roboto, Arial, sans-serif; background:#1c2b4a; color:#fff; margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center; }
        .box { background:#fff; color:#1c1e21; border-radius:14px; padding:32px 26px; max-width:360px; text-align:center; }
        .btn { display:block; width:100%; padding:12px; border-radius:8px; text-decoration:none; font-weight:600; margin-top:12px; }
        .btn.primary { background:#1c2b4a; color:#fff; }
        .btn.secondary { background:#eee; color:#1c1e21; }
    </style>
</head>
<body>
<div class="box">
    <h2>Ministrant Manager</h2>
    @if ($valid)
        <p>Aktywuj aplikację parafii <strong>{{ $parishName }}</strong>.</p>
        <p style="font-size:13px;color:#666;">Jeśli masz zainstalowaną aplikację Ministrant Manager z poprawnie skonfigurowanym App Link/Universal Link, kliknięcie poniżej otworzy ją bezpośrednio. W przeciwnym razie zeskanuj ten sam kod QR aplikacją.</p>
        {{-- Review round (final micro-round, point 4): was a dead
             `ministrantmanager://activate/{token}` custom scheme that no
             Android/iOS build actually registers — a button whose only
             possible outcome was "nothing happens" or an OS error dialog.
             The canonical, ONLY supported deep-link mechanism is HTTPS
             App Links/Universal Links (spec §35) on this exact URL — if
             the app is installed and its App Link is verified, the OS
             intercepts this https:// link and opens the app directly,
             never even reaching this fallback page. Linking back to the
             same canonical URL is therefore correct: it's a no-op ("you
             are already here") when App Links aren't working yet, and
             the intended deep-link open when they are — never a second,
             unsupported mechanism. --}}
        <a class="btn primary" href="{{ url("/activate/{$token}") }}">OTWÓRZ APLIKACJĘ</a>
    @else
        <p>Ten kod aktywacyjny jest nieprawidłowy, wygasł lub został już wykorzystany.</p>
        <p style="font-size:13px;color:#666;">Poproś administratora parafii o wygenerowanie nowego kodu.</p>
    @endif
    <a class="btn secondary" href="#" onclick="return false;">Pobierz na Androida (wkrótce)</a>
    <a class="btn secondary" href="#" onclick="return false;">Pobierz na iPhone (wkrótce)</a>
</div>
</body>
</html>
