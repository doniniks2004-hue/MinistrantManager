@extends('admin.layouts.app')
@section('title', 'Urządzenia')
@section('content')
<h2>Urządzenia</h2>

<div class="card">
    <form method="GET" style="display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap;">
        <div class="field" style="flex:1;margin:0;min-width:180px;">
            <label>Szukaj</label>
            <input type="text" name="q" value="{{ request('q') }}" placeholder="parafia, model, etykieta">
        </div>
        <div class="field" style="margin:0;">
            <label>Status</label>
            <select name="status">
                <option value="">Wszystkie</option>
                <option value="active" @selected(request('status')==='active')>Aktywne</option>
                <option value="revoked" @selected(request('status')==='revoked')>Odwołane</option>
            </select>
        </div>
        <div class="field" style="margin:0;">
            <label>Platforma</label>
            <select name="platform">
                <option value="">Wszystkie</option>
                <option value="android" @selected(request('platform')==='android')>Android</option>
                <option value="ios" @selected(request('platform')==='ios')>iOS</option>
            </select>
        </div>
        <div class="field" style="margin:0;">
            <label>Ostatnio online</label>
            <select name="seen">
                <option value="">Dowolnie</option>
                <option value="today" @selected(request('seen')==='today')>Dzisiaj</option>
                <option value="7d" @selected(request('seen')==='7d')>7 dni</option>
                <option value="30d" @selected(request('seen')==='30d')>30 dni</option>
                <option value="stale" @selected(request('seen')==='stale')>&gt; 30 dni</option>
            </select>
        </div>
        <button class="btn" type="submit">Filtruj</button>
    </form>
</div>

<div class="card">
    <table>
        <thead><tr><th>Parafia</th><th>Urządzenie</th><th>System</th><th>Wersja</th><th>Ostatnio online</th><th>Status</th><th></th></tr></thead>
        <tbody>
        @foreach ($devices as $device)
            <tr>
                <td>{{ $device->parish->name }}</td>
                <td>{{ $device->device_label ?? $device->device_model ?? '—' }}</td>
                <td>{{ $device->platform }}</td>
                <td>{{ $device->app_version ?? '—' }}</td>
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
    <div style="margin-top:14px;">{{ $devices->links() }}</div>
</div>
@endsection
