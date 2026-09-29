<?php

namespace App\Http\Controllers\Internal;

use App\Http\Controllers\Controller;
use App\Models\MobileDevice;
use App\Models\Parish;
use App\Services\DeviceValidationEvaluator;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;

/**
 * POST /internal/mobile/device/validate
 *
 * Device-control-plane milestone (review round). Called by a PARISH's
 * own MobileAPI server — never by the Flutter app directly, never
 * publicly reachable as a device-existence oracle. Authenticated via
 * `Authorization: Bearer <parish's own mobile_internal_api_secret>` —
 * the secret's mere validity resolves WHICH parish is asking; nothing
 * in the request body is trusted to say who the caller is (review
 * round: "Nie opieraj bezpieczeństwa na hostname przesłanym przez
 * klienta" applies equally to a self-reported parish_id).
 *
 * `app.ministrant.eu` remains the ONLY source of truth for device
 * state — this endpoint answers a question, it never hands the parish
 * a copy of the device record to store long-term (the parish's own
 * DeviceAuthorizationService caches only the {state, checked_at} answer
 * for a short lease — see that class's own docblock).
 */
class InternalDeviceValidationController extends Controller
{
    public function check(Request $request)
    {
        $secret = $this->extractBearerToken($request);
        if ($secret === null) {
            return response()->json(['error' => 'missing_secret'], 401);
        }

        // Constant-time-safe lookup: hash_equals happens implicitly via
        // the unique-column WHERE match plus the fact that we don't
        // branch on partial matches — a timing side-channel here would
        // need the DB layer itself to leak timing, which is out of
        // scope for what we can control at this layer.
        $requestingParish = Parish::where('mobile_internal_api_secret', $secret)->first();
        if ($requestingParish === null) {
            Log::warning('internal.device.validate: unknown secret presented');
            return response()->json(['error' => 'invalid_secret'], 401);
        }

        $data = $request->validate([
            'installation_id' => ['required', 'uuid'],
            // parish_id in the body is NEVER trusted for authorization —
            // see DeviceValidationEvaluator's docblock — it's accepted
            // only so the CALLER can sanity-check the response matches
            // what they asked about; the actual comparison uses
            // $requestingParish->id, resolved from the secret above.
            'parish_id' => ['sometimes', 'integer'],
        ]);

        $device = MobileDevice::where('installation_id', $data['installation_id'])->first();

        $result = DeviceValidationEvaluator::evaluate(
            device: $device === null ? null : ['parish_id' => $device->parish_id, 'status' => $device->status],
            requestingParishId: $requestingParish->id,
            requestingParishActive: $requestingParish->isActive(),
            offlineLeaseHours: $requestingParish->effectiveOfflineLeaseHours(),
        );

        return response()->json([
            'valid' => $result['state'] === 'active',
            'state' => $result['state'],
            'installation_id' => $data['installation_id'],
            'parish_id' => $requestingParish->id,
            'offline_lease_hours' => $result['offline_lease_hours'],
        ]);
    }

    private function extractBearerToken(Request $request): ?string
    {
        $header = $request->header('Authorization', '');
        if (!str_starts_with($header, 'Bearer ')) {
            return null;
        }
        $token = substr($header, 7);
        return $token !== '' ? $token : null;
    }
}
