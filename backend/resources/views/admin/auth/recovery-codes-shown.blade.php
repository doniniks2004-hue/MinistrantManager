@extends('admin.layouts.app')
@section('title', 'Kody odzyskiwania')
@section('content')
<div style="max-width:480px;margin:40px auto;">
    <div class="card" style="border:2px solid #ab2020;">
        <h2>Zapisz swoje kody odzyskiwania</h2>
        <p style="color:#666;font-size:14px;">
            Te kody pokazujemy <strong>tylko raz</strong>. Zapisz je w bezpiecznym miejscu
            (menedżer haseł). Każdy kod można wykorzystać jednorazowo, aby zalogować się
            bez dostępu do aplikacji Authenticator.
        </p>
        <div style="font-family:monospace;font-size:16px;line-height:2;background:#f4f5f7;padding:14px;border-radius:8px;">
            @foreach ($codes as $code)
                {{ $code }}<br>
            @endforeach
        </div>
        <a class="btn" href="{{ route('admin.dashboard') }}" style="margin-top:16px;display:inline-block;">Zapisałem kody, przejdź dalej</a>
    </div>
</div>
@endsection
