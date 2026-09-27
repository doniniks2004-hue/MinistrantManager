<?php

namespace MinistrantManager\MobileAPI\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * NOT INTEGRATED — Laravel adapter around the framework-free
 * VerifyDeviceTokenService (see that class for the actual, unit-tested
 * logic). This file requires illuminate/http, which needs the full
 * Laravel framework to run — it has NOT been executed in this
 * environment (see MobileAPI/docs/TESTING.md for exactly what was and
 * wasn't run). Wire $tokenStore to a real DeviceTokenStoreInterface
 * implementation in Iteration 2 (either a local synced copy of
 * app.ministrant.eu's device table, or a cached HTTP call to it — see
 * docs/INTEGRATION.md for the tradeoff).
 *
 * Install as route middleware on every /api/v1/mobile/* route, AFTER
 * whatever resolves $request->attributes->get('current_parish_id') from
 * the subdomain (Host header) — that resolution is existing MM
 * infrastructure this package assumes but does not provide.
 */
class VerifyDeviceToken
{
    public function __construct(private readonly VerifyDeviceTokenService $service)
    {
    }

    public function handle(Request $request, Closure $next): Response
    {
        $currentParishId = $request->attributes->get('current_parish_id');
        if (!$currentParishId) {
            throw new \RuntimeException(
                'VerifyDeviceToken requires current_parish_id to already be resolved '
                . '(from the subdomain) before it runs — check middleware order.'
            );
        }

        $result = $this->service->verify($request->bearerToken(), $currentParishId);

        if (!$result->ok) {
            return response()->json(['error' => $result->code], $result->httpStatus());
        }

        $request->attributes->set('device_parish_id', $result->parishId);

        return $next($request);
    }
}
