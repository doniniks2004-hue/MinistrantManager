@extends('admin.layouts.app')
@section('title', 'Administratorzy')
@section('content')
<h2>Administratorzy</h2>
<div class="card">
    <a class="btn" href="{{ route('admin.admins.create') }}">+ Nowy administrator</a>
</div>
<div class="card">
    <table>
        <thead><tr><th>Nazwa</th><th>E-mail</th><th>Rola</th><th>Status</th><th>MFA</th><th>Ostatnie logowanie</th><th>Akcje</th></tr></thead>
        <tbody>
        @foreach ($admins as $a)
            <tr>
                <td>{{ $a->name }}</td>
                <td>{{ $a->email }}</td>
                <td>
                    <form class="inline" method="POST" action="{{ route('admin.admins.role', $a) }}">
                        @csrf
                        <select name="role" onchange="this.form.submit()" {{ $a->id === auth('admin')->id() ? 'disabled' : '' }}>
                            <option value="ADMIN" @selected($a->role === 'ADMIN')>ADMIN</option>
                            <option value="SUPER_ADMIN" @selected($a->role === 'SUPER_ADMIN')>SUPER_ADMIN</option>
                        </select>
                    </form>
                </td>
                <td><span class="badge {{ $a->is_active ? 'active' : 'disabled' }}">{{ $a->is_active ? 'Aktywne' : 'Dezaktywowane' }}</span></td>
                <td>{{ $a->totp_enabled ? '✓ włączone' : '— nieskonfigurowane' }}</td>
                <td>{{ $a->last_login_at?->format('d.m.Y H:i') ?? '—' }}</td>
                <td>
                    @if ($a->id !== auth('admin')->id())
                        @if ($a->totp_enabled)
                            <form class="inline" method="POST" action="{{ route('admin.admins.reset-mfa', $a) }}" onsubmit="return confirm('Zresetować MFA dla {{ $a->email }}? Przy następnym logowaniu skonfiguruje je od nowa.');">
                                @csrf
                                <button class="btn secondary" type="submit">Resetuj MFA</button>
                            </form>
                        @endif
                        @if ($a->is_active)
                            <form class="inline" method="POST" action="{{ route('admin.admins.deactivate', $a) }}" onsubmit="return confirm('Dezaktywować konto {{ $a->email }}?');">
                                @csrf
                                <button class="btn danger" type="submit">Dezaktywuj</button>
                            </form>
                        @else
                            <form class="inline" method="POST" action="{{ route('admin.admins.reactivate', $a) }}">
                                @csrf
                                <button class="btn" type="submit">Aktywuj</button>
                            </form>
                        @endif
                    @else
                        <span style="color:#999;font-size:13px;">to Ty</span>
                    @endif
                </td>
            </tr>
        @endforeach
        </tbody>
    </table>
</div>
@endsection
