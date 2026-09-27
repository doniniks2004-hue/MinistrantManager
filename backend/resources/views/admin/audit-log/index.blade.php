@extends('admin.layouts.app')
@section('title', 'Audit Log')
@section('content')
<h2>Audit Log</h2>
@unless ($isSuperAdmin)
    <p style="color:#666;font-size:13px;">Widzisz wyłącznie własne działania. Pełny dziennik jest dostępny dla SUPER_ADMIN.</p>
@endunless

<div class="card">
    <form method="GET" style="display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap;">
        @if ($isSuperAdmin)
            <div class="field" style="margin:0;">
                <label>Administrator</label>
                <select name="admin_id">
                    <option value="">Wszyscy</option>
                    @foreach ($admins as $a)
                        <option value="{{ $a->id }}" @selected(request('admin_id') == $a->id)>{{ $a->name }} ({{ $a->email }})</option>
                    @endforeach
                </select>
            </div>
        @endif
        <div class="field" style="margin:0;">
            <label>Typ akcji (fragment)</label>
            <input type="text" name="action" value="{{ request('action') }}" placeholder="np. device.revoked">
        </div>
        <div class="field" style="margin:0;">
            <label>Od</label>
            <input type="date" name="date_from" value="{{ request('date_from') }}">
        </div>
        <div class="field" style="margin:0;">
            <label>Do</label>
            <input type="date" name="date_to" value="{{ request('date_to') }}">
        </div>
        <button class="btn" type="submit">Filtruj</button>
        <a class="btn secondary" href="{{ route('admin.audit-log.index') }}">Wyczyść</a>
    </form>
</div>

<div class="card">
    <table>
        <thead>
        <tr><th>Data</th><th>Administrator</th><th>Akcja</th><th>Podmiot</th><th>IP</th><th>Meta</th></tr>
        </thead>
        <tbody>
        @forelse ($entries as $entry)
            <tr>
                <td>{{ $entry->created_at->format('d.m.Y H:i:s') }}</td>
                <td>{{ $entry->admin_email ?? '—' }}</td>
                <td>{{ $entry->action }}</td>
                <td>{{ $entry->subject_type ? class_basename($entry->subject_type) . ' #' . $entry->subject_id : '—' }}</td>
                <td>{{ $entry->ip_address ?? '—' }}</td>
                <td style="max-width:320px;font-size:12px;color:#666;word-break:break-word;">
                    {{ $entry->meta ? json_encode($entry->meta, JSON_UNESCAPED_UNICODE) : '—' }}
                </td>
            </tr>
        @empty
            <tr><td colspan="6">Brak wpisów spełniających kryteria.</td></tr>
        @endforelse
        </tbody>
    </table>
    <div style="margin-top:14px;">{{ $entries->links() }}</div>
</div>
@endsection
