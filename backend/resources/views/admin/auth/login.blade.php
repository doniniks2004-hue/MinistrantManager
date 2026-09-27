@extends('admin.layouts.app')
@section('title', 'Logowanie — Ministrant Manager')
@section('content')
<div style="max-width:380px;margin:60px auto;">
    <div class="card">
        <h2>Ministrant Manager</h2>
        <p style="color:#666;font-size:14px;">Panel administratora</p>
        @if ($errors->any())
            <div class="flash" style="background:#fdeaea;border-color:#f3b9b9;">{{ $errors->first() }}</div>
        @endif
        <form method="POST" action="{{ route('admin.login') }}">
            @csrf
            <div class="field">
                <label>E-mail</label>
                <input type="email" name="email" value="{{ old('email') }}" required autofocus>
            </div>
            <div class="field">
                <label>Hasło</label>
                <input type="password" name="password" required>
            </div>
            <button class="btn" type="submit" style="width:100%;">Zaloguj</button>
        </form>
    </div>
</div>
@endsection
