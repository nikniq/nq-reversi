@extends('layouts.auth')
@section('title', 'Create account')
@section('subtitle', 'Join and track your games.')
@section('form')
<form method="POST" action="{{ route('register') }}" class="form">
    @csrf
    <label>Name<input type="text" name="name" value="{{ old('name') }}" required autofocus autocomplete="name"></label>
    <label>Email<input type="email" name="email" value="{{ old('email') }}" required autocomplete="email"></label>
    <label>Password<input type="password" name="password" required autocomplete="new-password" minlength="8"></label>
    <label>Confirm password<input type="password" name="password_confirmation" required autocomplete="new-password"></label>
    <button class="btn primary" type="submit">Create account</button>
</form>
@endsection
@section('footer')
Already have an account? <a href="{{ route('login') }}">Sign in</a>
@endsection
