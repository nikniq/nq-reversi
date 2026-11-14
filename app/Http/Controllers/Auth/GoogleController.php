<?php

namespace App\Http\Controllers\Auth;

use App\Http\Controllers\Controller;
use App\Models\User;
use Illuminate\Http\RedirectResponse;
use Illuminate\Support\Facades\Auth;
use Laravel\Socialite\Facades\Socialite;
use Symfony\Component\HttpFoundation\RedirectResponse as SymfonyRedirect;
use Throwable;

class GoogleController extends Controller
{
    public function redirect(): SymfonyRedirect|RedirectResponse
    {
        if (! config('services.google.client_id')) {
            return redirect()->route('login')->withErrors(['email' => 'Google sign-in is not configured.']);
        }

        return Socialite::driver('google')->redirect();
    }

    public function callback(): RedirectResponse
    {
        try {
            $google = Socialite::driver('google')->user();
        } catch (Throwable) {
            return redirect()->route('login')->withErrors(['email' => 'Google sign-in failed. Please try again.']);
        }

        // Link by Google ID first, then by verified email, otherwise create.
        $user = User::where('google_id', $google->getId())->first()
            ?? User::where('email', $google->getEmail())->first();

        if ($user) {
            $user->forceFill([
                'google_id' => $google->getId(),
                'avatar' => $google->getAvatar(),
                'email_verified_at' => $user->email_verified_at ?? now(),
            ])->save();
        } else {
            $user = User::forceCreate([
                'name' => $google->getName() ?: $google->getEmail(),
                'email' => $google->getEmail(),
                'google_id' => $google->getId(),
                'avatar' => $google->getAvatar(),
                'email_verified_at' => now(),
            ]);
        }

        Auth::login($user, remember: true);
        request()->session()->regenerate();

        return redirect()->intended(route('reversi'));
    }
}
