<?php

namespace Tests\Feature;

use App\Models\MobileActivationCode;
use App\Models\Parish;
use App\Services\TokenService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

/**
 * Minimal REAL Laravel feature test (Iteration 1.1 point 12) — exercises
 * actual HTTP routes through the actual framework, unlike the
 * standalone-tests/ (framework-free, pure-PHP) suite. This is the piece
 * that could NOT be executed in the sandbox that produced this codebase
 * (no Packagist access to install Laravel) — see docs-testing notes.
 * `.github/workflows/backend-test.yml` scaffolds a real Laravel app and
 * runs this for real.
 */
class ActivationApiTest extends TestCase
{
    use RefreshDatabase;

    public function test_check_resolves_a_valid_code_to_its_parish(): void
    {
        $parish = Parish::create([
            'name' => 'Parafia CHWK', 'slug' => 'chwk', 'subdomain' => 'chwk.ministrant.eu',
            'server_url' => 'https://chwk.ministrant.eu', 'mobile_status' => 'active',
        ]);

        $raw = TokenService::generateActivationToken();
        MobileActivationCode::create([
            'parish_id' => $parish->id,
            'token_hash' => TokenService::hash($raw),
            'display_code' => '73FK-92MX',
            'max_uses' => 1,
            'status' => 'active',
        ]);

        $response = $this->postJson('/api/activation/check', ['token' => $raw]);

        $response->assertOk()->assertJsonPath('parish.slug', 'chwk');
    }

    public function test_confirm_rejects_a_code_that_has_reached_max_uses(): void
    {
        $parish = Parish::create([
            'name' => 'Parafia CHWK', 'slug' => 'chwk', 'subdomain' => 'chwk.ministrant.eu',
            'server_url' => 'https://chwk.ministrant.eu', 'mobile_status' => 'active',
        ]);

        $raw = TokenService::generateActivationToken();
        MobileActivationCode::create([
            'parish_id' => $parish->id,
            'token_hash' => TokenService::hash($raw),
            'display_code' => '73FK-92MX',
            'max_uses' => 1,
            'used_count' => 1, // already at its limit
            'status' => 'used',
        ]);

        $response = $this->postJson('/api/activation/confirm', [
            'token' => $raw,
            'installation_id' => (string) \Illuminate\Support\Str::uuid(),
            'platform' => 'android',
        ]);

        $response->assertStatus(422); // ValidationException
    }

    public function test_confirm_rejects_a_code_belonging_to_a_disabled_parish(): void
    {
        $parish = Parish::create([
            'name' => 'Parafia XYZ', 'slug' => 'xyz', 'subdomain' => 'xyz.ministrant.eu',
            'server_url' => 'https://xyz.ministrant.eu', 'mobile_status' => 'disabled',
        ]);

        $raw = TokenService::generateActivationToken();
        MobileActivationCode::create([
            'parish_id' => $parish->id,
            'token_hash' => TokenService::hash($raw),
            'display_code' => '11AA-22BB',
            'max_uses' => 1,
            'status' => 'active',
        ]);

        $response = $this->postJson('/api/activation/confirm', [
            'token' => $raw,
            'installation_id' => (string) \Illuminate\Support\Str::uuid(),
            'platform' => 'ios',
        ]);

        $response->assertStatus(422);
    }
}
