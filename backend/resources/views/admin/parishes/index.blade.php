@extends('admin.layouts.app')
@section('title', 'Parafie')
@section('content')
<div style="display:flex;justify-content:space-between;align-items:center;">
    <h2>Parafie</h2>
    <a class="btn" href="{{ route('admin.parishes.create') }}">+ Dodaj parafię</a>
</div>

<div class="card">
    <form method="GET" style="display:flex;gap:10px;align-items:flex-end;">
        <div class="field" style="flex:1;margin:0;">
            <label>Szukaj</label>
            <input type="text" name="q" value="{{ request('q') }}" placeholder="nazwa, slug, subdomena">
        </div>
        <div class="field" style="margin:0;">
            <label>Status</label>
            <select name="status">
                <option value="">Wszystkie</option>
                <option value="active" @selected(request('status')==='active')>Aktywne</option>
                <option value="disabled" @selected(request('status')==='disabled')>Nieaktywne</option>
            </select>
        </div>
        <button class="btn" type="submit">Filtruj</button>
    </form>
</div>

<div class="card">
    <table>
        <thead>
        <tr><th>Parafia</th><th>Subdomena</th><th>Status</th><th>Urządzenia</th><th>Akcje</th></tr>
        </thead>
        <tbody>
        @foreach ($parishes as $parish)
            <tr>
                <td>{{ $parish->name }}</td>
                <td>{{ $parish->subdomain }}</td>
                <td><span class="badge {{ $parish->mobile_status }}">{{ $parish->mobile_status === 'active' ? 'Aktywna' : 'Nieaktywna' }}</span></td>
                <td>{{ $parish->devices_count }}</td>
                <td>
                    <a class="btn secondary" href="{{ route('admin.parishes.show', $parish) }}">Szczegóły</a>
                    @if ($parish->mobile_status === 'active')
                        <form class="inline" method="POST" action="{{ route('admin.parishes.disable', $parish) }}" onsubmit="return confirm('Na pewno dezaktywować parafię {{ $parish->name }}? Wszystkie jej urządzenia stracą dostęp.');">
                            @csrf
                            <button class="btn danger" type="submit">Dezaktywuj</button>
                        </form>
                    @else
                        <form class="inline" method="POST" action="{{ route('admin.parishes.enable', $parish) }}">
                            @csrf
                            <button class="btn" type="submit">Aktywuj</button>
                        </form>
                    @endif
                </td>
            </tr>
        @endforeach
        </tbody>
    </table>
    <div style="margin-top:14px;">{{ $parishes->links() }}</div>
</div>
@endsection
