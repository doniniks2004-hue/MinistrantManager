@extends('admin.layouts.app')
@section('title', 'Konfiguracja weryfikacji dwuskładnikowej')
@section('content')
<div style="max-width:420px;margin:40px auto;">
    <div class="card">
        <h2>Skonfiguruj Authenticator</h2>
        <p style="color:#666;font-size:14px;">
            Zeskanuj poniższy kod QR aplikacją typu Google Authenticator / Authy,
            a następnie wpisz aktualny 6-cyfrowy kod, żeby potwierdzić konfigurację.
            Bez tego kroku logowanie do panelu nie jest możliwe (obowiązkowe MFA).
        </p>

        <div style="text-align:center;margin:16px 0;">
            {!! $qrSvg !!}
        </div>

        <p style="font-size:13px;color:#666;">
            Nie możesz zeskanować kodu? Wpisz ręcznie w aplikacji Authenticator:
            <br><code style="font-size:14px;letter-spacing:1px;">{{ $secret }}</code>
        </p>

        @if ($errors->any())
            <div class="flash" style="background:#fdeaea;border-color:#f3b9b9;">{{ $errors->first() }}</div>
        @endif

        <form method="POST" action="{{ route('admin.totp.setup') }}">
            @csrf
            <div class="field">
                <label>Kod z aplikacji Authenticator</label>
                <input type="text" name="code" inputmode="numeric" pattern="[0-9]*" maxlength="6" required autofocus>
            </div>
            <button class="btn" type="submit" style="width:100%;">Potwierdź i zaloguj</button>
        </form>
    </div>
</div>
@endsection
