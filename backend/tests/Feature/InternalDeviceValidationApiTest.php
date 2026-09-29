<?php

namespace Tests\Feature;

use App\Models\MobileDevice;
use App\Models\Parish;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

/**
 * Device-control-plane milestone. Real Laravel feature test — same
 * honest caveat as ActivationApiTest.php's own docblock: this could NOT
 * be executed in the sandbox that wrote it (no Packagist access to
 * scaffold a real Laravel app here either — confirmed via a live
 * `composer create-project` attempt returning HTTP 403 on
 * repo.packagist.org). `.github/workflows/backend-test.yml` is what
 * actually runs this for real. DeviceValidationEvaluator's own pure
 * logic (the actual state-decision rules) IS verified directly —
 * see standalone-tests/test_device_validation_evaluator.php, which
 * this sandbox COULD and did run (7/7 passing).
 */
class InternalDeviceValidationApiTest extends TestCase
{
    use RefreshDatabase;

    private function makeParish(string $slug, string $secret, string $mobileStatus = 'active'): Parish
    {
        return Parish::create([
            'name' => "Parafia $slug", 'slug' => $slug, 'subdomain' => "$slug.ministrant.eu",
            'server_url' => "https://$slug.ministrant.eu", 'mobile_status' => $mobileStatus,
            'mobile_internal_api_secret' => $secret,
        ]);
    }

    public function test_active_device_of_the_authenticated_parish_returns_active(): void
    {
        $parish = $this->makeParish('chwk', 'secret-chwk-123');
        $device = MobileDevice::create([
            'installation_id' => '550e8400-e29b-41d4-a716-446655440000',
            'parish_id' => $parish->id, 'platform' => 'android',
            'device_token_hash' => hash('sha256', 'token-a'), 'status' => 'active',
            'activated_at' => now(),
        ]);

        $response = $this->postJson('/api/internal/mobile/device/validate', [
            'installation_id' => $device->installation_id,
        ], ['Authorization' => 'Bearer secret-chwk-123']);

        $response->assertOk()
            ->assertJsonPath('valid', true)
            ->assertJsonPath('state', 'active')
            ->assertJsonPath('offline_lease_hours', $parish->effectiveOfflineLeaseHours());
    }

    public function test_wrong_secret_is_rejected_before_any_device_lookup(): void
    {
        $this->makeParish('chwk', 'secret-chwk-123');

        $response = $this->postJson('/api/internal/mobile/device/validate', [
            'installation_id' => '550e8400-e29b-41d4-a716-446655440000',
        ], ['Authorization' => 'Bearer totally-wrong-secret']);

        $response->assertStatus(401);
    }

    public function test_a_device_belonging_to_a_different_parish_is_parish_mismatch_never_active(): void
    {
        $owningParish = $this->makeParish('chwk', 'secret-chwk-123');
        $askingParish = $this->makeParish('witosa', 'secret-witosa-456');

        $device = MobileDevice::create([
            'installation_id' => '550e8400-e29b-41d4-a716-446655440000',
            'parish_id' => $owningParish->id, 'platform' => 'android',
            'device_token_hash' => hash('sha256', 'token-b'), 'status' => 'active',
            'activated_at' => now(),
        ]);

        // Witosa's own valid secret, asking about a device that actually
        // belongs to CHWK — this is the exact scenario the review round
        // called out: never trust a self-reported parish_id/hostname.
        $response = $this->postJson('/api/internal/mobile/device/validate', [
            'installation_id' => $device->installation_id,
        ], ['Authorization' => 'Bearer secret-witosa-456']);

        $response->assertOk()
            ->assertJsonPath('valid', false)
            ->assertJsonPath('state', 'parish_mismatch');
    }

    public function test_revoked_device_returns_revoked_not_active(): void
    {
        $parish = $this->makeParish('chwk', 'secret-chwk-123');
        $device = MobileDevice::create([
            'installation_id' => '550e8400-e29b-41d4-a716-446655440000',
            'parish_id' => $parish->id, 'platform' => 'ios',
            'device_token_hash' => hash('sha256', 'token-c'), 'status' => 'revoked',
            'activated_at' => now(), 'revoked_at' => now(),
        ]);

        $response = $this->postJson('/api/internal/mobile/device/validate', [
            'installation_id' => $device->installation_id,
        ], ['Authorization' => 'Bearer secret-chwk-123']);

        $response->assertOk()->assertJsonPath('state', 'revoked');
    }

    public function test_unknown_installation_id_returns_not_found(): void
    {
        $this->makeParish('chwk', 'secret-chwk-123');

        $response = $this->postJson('/api/internal/mobile/device/validate', [
            'installation_id' => '00000000-0000-0000-0000-000000000000',
        ], ['Authorization' => 'Bearer secret-chwk-123']);

        $response->assertOk()->assertJsonPath('state', 'not_found');
    }

    public function test_a_disabled_parish_cannot_validate_even_its_own_device(): void
    {
        $parish = $this->makeParish('chwk', 'secret-chwk-123', mobileStatus: 'disabled');
        $device = MobileDevice::create([
            'installation_id' => '550e8400-e29b-41d4-a716-446655440000',
            'parish_id' => $parish->id, 'platform' => 'android',
            'device_token_hash' => hash('sha256', 'token-d'), 'status' => 'active',
            'activated_at' => now(),
        ]);

        $response = $this->postJson('/api/internal/mobile/device/validate', [
            'installation_id' => $device->installation_id,
        ], ['Authorization' => 'Bearer secret-chwk-123']);

        $response->assertOk()->assertJsonPath('state', 'parish_disabled');
    }
}
