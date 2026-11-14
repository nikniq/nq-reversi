<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Socialite\Facades\Socialite;
use Laravel\Socialite\Two\User as SocialiteUser;
use Tests\TestCase;

class AuthTest extends TestCase
{
    use RefreshDatabase;

    public function test_pages_render(): void
    {
        $this->get('/login')->assertOk()->assertSee('Continue with Google');
        $this->get('/register')->assertOk();
    }

    public function test_user_can_register_and_logout(): void
    {
        $this->post('/register', [
            'name' => 'Ada', 'email' => 'ada@example.com',
            'password' => 'secret-pass-123', 'password_confirmation' => 'secret-pass-123',
        ])->assertRedirect('/');

        $this->assertAuthenticated();
        $this->get('/')->assertSee('Ada');
        $this->post('/logout')->assertRedirect('/');
        $this->assertGuest();
    }

    public function test_user_can_login_with_password(): void
    {
        $user = User::factory()->create(['password' => bcrypt('secret-pass-123')]);

        $this->post('/login', ['email' => $user->email, 'password' => 'wrong'])->assertSessionHasErrors('email');
        $this->assertGuest();

        $this->post('/login', ['email' => $user->email, 'password' => 'secret-pass-123'])->assertRedirect('/');
        $this->assertAuthenticatedAs($user);
    }

    public function test_google_callback_creates_and_links_user(): void
    {
        $existing = User::factory()->create(['email' => 'g@example.com']);

        $google = (new SocialiteUser)->map([
            'id' => 'g-123', 'name' => 'G User', 'email' => 'g@example.com', 'avatar' => 'https://example.com/a.png',
        ]);
        Socialite::shouldReceive('driver->user')->andReturn($google);

        $this->get('/auth/google/callback')->assertRedirect('/');
        $this->assertAuthenticatedAs($existing);
        $this->assertSame('g-123', $existing->fresh()->google_id);
        $this->assertSame(1, User::count());
    }
}
