@extends('admin.layouts.app')
@section('title', 'Nowy administrator')
@section('content')
<div style="max-width:420px;margin:0 auto;">
    <div class="card">
        <h2>Nowy administrator</h2>
        @if ($errors->any())
            <div class="flash" style="background:#fdeaea;border-color:#f3b9b9;">{{ $errors->first() }}</div>
        @endif
        <form method="POST" action="{{ route('admin.admins.store') }}">
            @csrf
            <div class="field"><label>Imię i nazwisko</label><input type="text" name="name" required></div>
            <div class="field"><label>E-mail</label><input type="email" name="email" required></div>
            <div class="field"><label>Hasło tymczasowe (min. 12 znaków)</label><input type="password" name="password" required minlength="12"></div>
            <div class="field">
                <label>Rola</label>
                <select name="role">
                    <option value="ADMIN">ADMIN</option>
                    <option value="SUPER_ADMIN">SUPER_ADMIN</option>
                </select>
            </div>
            <p style="color:#666;font-size:13px;">Nowe konto będzie musiało skonfigurować MFA (TOTP) przy pierwszym logowaniu — nie da się tego pominąć.</p>
            <button class="btn" type="submit" style="width:100%;">Utwórz konto</button>
        </form>
    </div>
</div>
@endsection
