@extends('admin.layouts.app')
@section('title', 'Weryfikacja dwuskładnikowa')
@section('content')
<div style="max-width:380px;margin:60px auto;">
    <div class="card">
        <h2>Kod z aplikacji Authenticator</h2>
        <p style="color:#666;font-size:14px;">Wpisz aktualny 6-cyfrowy kod TOTP.</p>
        @if ($errors->any())
            <div class="flash" style="background:#fdeaea;border-color:#f3b9b9;">{{ $errors->first() }}</div>
        @endif
        <form method="POST" action="{{ route('admin.login.totp') }}">
            @csrf
            <div class="field">
                <label>Kod TOTP</label>
                <input type="text" name="code" inputmode="numeric" pattern="[0-9]*" maxlength="6" required autofocus>
            </div>
            <button class="btn" type="submit" style="width:100%;">Potwierdź</button>
        </form>

        <p style="text-align:center;margin-top:16px;">
            <a href="#" onclick="document.getElementById('recovery-form').style.display='block';this.style.display='none';return false;" style="font-size:13px;color:#666;">
                Straciłem dostęp do aplikacji Authenticator
            </a>
        </p>
        <form id="recovery-form" method="POST" action="{{ route('admin.login.recovery-code') }}" style="display:none;margin-top:10px;">
            @csrf
            <div class="field">
                <label>Kod odzyskiwania</label>
                <input type="text" name="recovery_code" placeholder="7KMF-92QX-P4DT" required>
            </div>
            <button class="btn secondary" type="submit" style="width:100%;">Zaloguj kodem odzyskiwania</button>
        </form>
    </div>
</div>
@endsection
