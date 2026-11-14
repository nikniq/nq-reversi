@extends('layouts.auth')
@section('title', 'Welcome back')
@section('subtitle', 'Sign in to keep playing.')
@section('form')
<form method="POST" action="{{ route('login') }}" class="form">
    @csrf
    <label>Email<input type="email" name="email" value="{{ old('email') }}" required autofocus autocomplete="email"></label>
    <label>Password<input type="password" name="password" required autocomplete="current-password"></label>
    <label class="check"><input type="checkbox" name="remember"> Remember me</label>
    <button class="btn primary" type="submit">Sign in</button>
</form>
@endsection
@section('footer')
No account? <a href="{{ route('register') }}">Create one</a>
@endsection
