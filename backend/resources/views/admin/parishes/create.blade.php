@extends('admin.layouts.app')
@section('title', 'Dodaj parafię')
@section('content')
<h2>Dodaj parafię</h2>
<div class="card" style="max-width:480px;">
    @if ($errors->any())
        <div class="flash" style="background:#fdeaea;border-color:#f3b9b9;">{{ $errors->first() }}</div>
    @endif
    <form method="POST" action="{{ route('admin.parishes.store') }}">
        @csrf
        <div class="field">
            <label>Nazwa parafii</label>
            <input type="text" name="name" value="{{ old('name') }}" required placeholder="np. Parafia św. Jana w Chorzowie">
        </div>
        <div class="field">
            <label>Slug</label>
            <input type="text" name="slug" value="{{ old('slug') }}" required placeholder="np. chwk">
        </div>
        <div class="field">
            <label>Subdomena</label>
            <input type="text" name="subdomain" value="{{ old('subdomain') }}" required placeholder="np. chwk.ministrant.eu">
        </div>
        <button class="btn" type="submit">Dodaj parafię</button>
    </form>
</div>
@endsection
