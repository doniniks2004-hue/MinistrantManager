@extends('admin.layouts.app')
@section('title', $parish->name)
@section('content')
<h2>{{ $parish->name }}</h2>
<p style="color:#666;">{{ $parish->subdomain }} &middot; <span class="badge {{ $parish->mobile_status }}">{{ $parish->mobile_status === 'active' ? 'Aktywna' : 'Nieaktywna' }}</span></p>

@if (session('generated_code'))
    @php $gc = session('generated_code'); @endphp
    <div class="card" style="border:2px solid #1c2b4a;">
        <h3>Nowy kod aktywacyjny</h3>
        <p>Kod: <strong style="font-size:22px;letter-spacing:2px;">{{ $gc['display_code'] }}</strong></p>
        <div>{!! $gc['qr_svg'] !!}</div>
        <p style="color:#666;font-size:12px;">{{ $gc['qr_url'] }}</p>
    </div>
@endif

<div class="card">
    <h3>Offline lease tej parafii</h3>
    <p style="color:#666;font-size:13px;">
        Ile godzin urządzenie tej parafii może działać całkowicie offline,
        zanim zażąda ponownego potwierdzenia z serwerem. Puste pole =
        dziedziczy globalną wartość ({{ \App\Models\AppConfig::get('offline_lease_hours', 72) }}h).
    </p>
    <form method="POST" action="{{ route('admin.parishes.offline-lease', $parish) }}" style="display:flex;gap:10px;align-items:flex-end;">
        @csrf
        <div class="field" style="margin:0;">
            <label>Godziny (puste = globalna: {{ \App\Models\AppConfig::get('offline_lease_hours', 72) }}h)</label>
            <input type="number" name="offline_lease_hours" min="1" max="720" value="{{ $parish->offline_lease_hours }}" placeholder="dziedzicz globalną">
        </div>
        <button class="btn" type="submit">Zapisz</button>
    </form>
</div>

<div class="card">
    <h3>Generuj kod aktywacyjny</h3>
    <form method="POST" action="{{ route('admin.parishes.codes.generate', $parish) }}" style="display:flex;gap:14px;align-items:flex-end;flex-wrap:wrap;">
        @csrf
        <div class="field" style="margin:0;">
            <label>Ważność</label>
            <select name="expiry">
                <option value="1_hour">1 godzina</option>
                <option value="24_hours">24 godziny</option>
                <option value="7_days" selected>7 dni</option>
                <option value="none">Bez terminu</option>
            </select>
        </div>
        <div class="field" style="margin:0;">
            <label>Liczba aktywacji</label>
            <select name="max_uses">
                <option value="1" selected>1 urządzenie</option>
                <option value="5">5 urządzeń</option>
                <option value="10">10 urządzeń</option>
                <option value="unlimited">Bez limitu</option>
            </select>
        </div>
        <button class="btn" type="submit">Generuj kod</button>
    </form>
</div>

<div class="card">
    <h3>Historia kodów</h3>
    <table>
        <thead><tr><th>Kod</th><th>Utworzono</th><th>Użycia</th><th>Limit</th><th>Ważność</th><th>Status</th><th></th></tr></thead>
        <tbody>
        @foreach ($codes as $code)
            <tr>
                <td>{{ $code->display_code }}</td>
                <td>{{ $code->created_at->format('d.m H:i') }}</td>
                <td>{{ $code->used_count }}</td>
                <td>{{ $code->max_uses ?? '∞' }}</td>
                <td>{{ $code->expires_at?->format('d.m.Y H:i') ?? 'bez terminu' }}</td>
                <td><span class="badge {{ $code->status === 'active' ? 'active' : 'revoked' }}">{{ $code->status }}</span></td>
                <td>
                    @if ($code->status === 'active')
                        <form class="inline" method="POST" action="{{ route('admin.parishes.codes.revoke', [$parish, $code]) }}">
                            @csrf
                            <button class="btn danger" type="submit">Unieważnij</button>
                        </form>
                    @endif
                </td>
            </tr>
        @endforeach
        </tbody>
    </table>
</div>

<div class="card">
    <h3>Urządzenia ({{ $parish->devices->count() }})</h3>
    <table>
        <thead><tr><th>Urządzenie</th><th>System</th><th>Wersja</th><th>Aktywacja</th><th>Ostatnio online</th><th>Status</th><th></th></tr></thead>
        <tbody>
        @foreach ($parish->devices as $device)
            <tr>
                <td>{{ $device->device_label ?? $device->device_model ?? '—' }}</td>
                <td>{{ $device->platform }}</td>
                <td>{{ $device->app_version ?? '—' }}</td>
                <td>{{ $device->activated_at->format('d.m.Y') }}</td>
                <td>{{ $device->last_seen_at?->format('d.m H:i') ?? '—' }}</td>
                <td><span class="badge {{ $device->status }}">{{ $device->status === 'active' ? 'Aktywne' : 'Odwołane' }}</span></td>
                <td>
                    @if ($device->status === 'active')
                        <form class="inline" method="POST" action="{{ route('admin.devices.revoke', $device) }}" onsubmit="return confirm('Dezaktywować to urządzenie?');">
                            @csrf
                            <button class="btn danger" type="submit">Dezaktywuj</button>
                        </form>
                    @endif
                </td>
            </tr>
        @endforeach
        </tbody>
    </table>
</div>
@endsection
