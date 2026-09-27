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
        <p style="font-size:13px;color:#666;">Otwórz w aplikacji mobilnej Ministrant Manager, żeby dokończyć aktywację — ta strona sama jej nie wykonuje.</p>
        <a class="btn primary" href="ministrantmanager://activate/{{ $token }}">OTWÓRZ APLIKACJĘ</a>
    @else
        <p>Ten kod aktywacyjny jest nieprawidłowy, wygasł lub został już wykorzystany.</p>
        <p style="font-size:13px;color:#666;">Poproś administratora parafii o wygenerowanie nowego kodu.</p>
    @endif
    <a class="btn secondary" href="#" onclick="return false;">Pobierz na Androida (wkrótce)</a>
    <a class="btn secondary" href="#" onclick="return false;">Pobierz na iPhone (wkrótce)</a>
</div>
</body>
</html>
