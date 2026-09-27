<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <title>@yield('title', 'Ministrant Manager — Panel administratora')</title>
    <meta name="csrf-token" content="{{ csrf_token() }}">
    <style>
        :root { color-scheme: light; }
        * { box-sizing: border-box; }
        body { font-family: -apple-system, Segoe UI, Roboto, Arial, sans-serif; margin: 0; background: #f4f5f7; color: #1c1e21; }
        header { background: #1c2b4a; color: #fff; padding: 14px 24px; display: flex; align-items: center; justify-content: space-between; }
        header a { color: #fff; text-decoration: none; font-weight: 600; }
        nav { display: flex; gap: 18px; }
        nav a { color: #cdd6e6; text-decoration: none; font-size: 14px; }
        nav a.active, nav a:hover { color: #fff; }
        main { max-width: 1100px; margin: 24px auto; padding: 0 20px; }
        .card { background: #fff; border-radius: 10px; padding: 20px; margin-bottom: 18px; box-shadow: 0 1px 3px rgba(0,0,0,.06); }
        table { width: 100%; border-collapse: collapse; font-size: 14px; }
        th, td { text-align: left; padding: 10px 8px; border-bottom: 1px solid #eee; }
        th { color: #666; font-weight: 600; font-size: 12px; text-transform: uppercase; }
        .badge { display: inline-block; padding: 2px 9px; border-radius: 20px; font-size: 12px; font-weight: 600; }
        .badge.active { background: #e3f7e9; color: #1c7a34; }
        .badge.disabled, .badge.revoked { background: #fdeaea; color: #ab2020; }
        .stat-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 14px; }
        .stat { background: #fff; border-radius: 10px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,.06); }
        .stat .value { font-size: 28px; font-weight: 700; }
        .stat .label { font-size: 12px; color: #666; margin-top: 4px; }
        .btn { display: inline-block; padding: 7px 14px; border-radius: 6px; border: none; background: #1c2b4a; color: #fff; font-size: 13px; cursor: pointer; text-decoration: none; }
        .btn.danger { background: #ab2020; }
        .btn.secondary { background: #e8e8ec; color: #1c1e21; }
        .flash { background: #eaf3ff; border: 1px solid #b7d4f7; padding: 10px 14px; border-radius: 8px; margin-bottom: 16px; font-size: 14px; }
        form.inline { display: inline; }
        input[type=text], input[type=email], input[type=password], select {
            width: 100%; padding: 9px 10px; border: 1px solid #d6d9e0; border-radius: 6px; font-size: 14px;
        }
        label { font-size: 13px; font-weight: 600; display: block; margin-bottom: 4px; }
        .field { margin-bottom: 14px; }
    </style>
</head>
<body>
@auth('admin')
<header>
    <a href="{{ route('admin.dashboard') }}">Ministrant Manager</a>
    <nav>
        <a href="{{ route('admin.dashboard') }}">Dashboard</a>
        <a href="{{ route('admin.parishes.index') }}">Parafie</a>
        <a href="{{ route('admin.devices.index') }}">Urządzenia</a>
        <a href="{{ route('admin.audit-log.index') }}">Audit Log</a>
        @if (auth('admin')->user()?->isSuperAdmin())
            <a href="{{ route('admin.admins.index') }}">Administratorzy</a>
            <a href="{{ route('admin.settings.edit') }}">Ustawienia</a>
        @endif
        <form class="inline" method="POST" action="{{ route('admin.logout') }}">
            @csrf
            <button class="btn secondary" type="submit">Wyloguj</button>
        </form>
    </nav>
</header>
@endauth
<main>
    @if (session('status'))
        <div class="flash">{{ session('status') }}</div>
    @endif
    @yield('content')
</main>
</body>
</html>
