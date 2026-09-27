@extends('admin.layouts.app')
@section('title', 'Ustawienia globalne')
@section('content')
<h2>Ustawienia globalne floty</h2>
<p style="color:#666;font-size:13px;">
    Te wartości są zwracane przez publiczny, niewymagający uwierzytelnienia
    endpoint <code>GET /api/client-config</code> — czyta go każda instalacja
    aplikacji, także przed aktywacją.
</p>
<div class="card">
    <form method="POST" action="{{ route('admin.settings.update') }}">
        @csrf
        <div class="field"><label>Minimalna wersja Android</label><input type="text" name="minimum_supported_android_version" value="{{ $values['minimum_supported_android_version'] }}" required></div>
        <div class="field"><label>Minimalna wersja iOS</label><input type="text" name="minimum_supported_ios_version" value="{{ $values['minimum_supported_ios_version'] }}" required></div>
        <div class="field"><label>Najnowsza wersja Android</label><input type="text" name="latest_android_version" value="{{ $values['latest_android_version'] }}" required></div>
        <div class="field"><label>Najnowsza wersja iOS</label><input type="text" name="latest_ios_version" value="{{ $values['latest_ios_version'] }}" required></div>
        <div class="field"><label>Google Play URL (puste = jeszcze nieopublikowana)</label><input type="text" name="android_store_url" value="{{ $values['android_store_url'] }}"></div>
        <div class="field"><label>App Store URL (puste = jeszcze nieopublikowana)</label><input type="text" name="ios_store_url" value="{{ $values['ios_store_url'] }}"></div>
        <div class="field">
            <label><input type="checkbox" name="maintenance_mode" value="1" @checked($values['maintenance_mode'] === '1')> Tryb konserwacji (blokuje działanie aplikacji)</label>
        </div>
        <div class="field"><label>Komunikat konserwacji</label><input type="text" name="maintenance_message" value="{{ $values['maintenance_message'] }}"></div>
        <div class="field"><label>Domyślny offline lease (godziny)</label><input type="text" name="offline_lease_hours" value="{{ $values['offline_lease_hours'] }}" required></div>
        <button class="btn" type="submit">Zapisz</button>
    </form>
</div>
@endsection
