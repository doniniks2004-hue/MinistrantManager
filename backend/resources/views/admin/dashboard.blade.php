@extends('admin.layouts.app')
@section('title', 'Dashboard')
@section('content')
<h2>Dashboard</h2>
<div class="stat-grid">
    <div class="stat"><div class="value">{{ $stats['active_parishes'] }}</div><div class="label">Aktywne parafie</div></div>
    <div class="stat"><div class="value">{{ $stats['inactive_parishes'] }}</div><div class="label">Nieaktywne parafie</div></div>
    <div class="stat"><div class="value">{{ $stats['active_devices'] }}</div><div class="label">Aktywne urządzenia</div></div>
    <div class="stat"><div class="value">{{ $stats['android_devices'] }}</div><div class="label">Urządzenia Android</div></div>
    <div class="stat"><div class="value">{{ $stats['ios_devices'] }}</div><div class="label">Urządzenia iOS</div></div>
</div>

<div class="card" style="margin-top:20px;">
    <h3>Aktywacje</h3>
    <table>
        <tr><td>Dzisiaj</td><td><strong>{{ $stats['activations_today'] }}</strong></td></tr>
        <tr><td>Ostatnie 7 dni</td><td><strong>{{ $stats['activations_7d'] }}</strong></td></tr>
        <tr><td>Ostatnie 30 dni</td><td><strong>{{ $stats['activations_30d'] }}</strong></td></tr>
        <tr><td>Urządzenia widziane dzisiaj</td><td><strong>{{ $stats['seen_today'] }}</strong></td></tr>
        <tr><td>Urządzenia nieaktywne &gt; 30 dni</td><td><strong>{{ $stats['stale_30d'] }}</strong></td></tr>
    </table>
</div>

<div class="card">
    <h3>Wersje aplikacji (aktywne urządzenia)</h3>
    <table>
        <thead><tr><th>Wersja</th><th>Liczba urządzeń</th></tr></thead>
        <tbody>
        @forelse ($versionBreakdown as $row)
            <tr><td>{{ $row->app_version ?? '—' }}</td><td>{{ $row->total }}</td></tr>
        @empty
            <tr><td colspan="2">Brak danych.</td></tr>
        @endforelse
        </tbody>
    </table>
</div>
@endsection
