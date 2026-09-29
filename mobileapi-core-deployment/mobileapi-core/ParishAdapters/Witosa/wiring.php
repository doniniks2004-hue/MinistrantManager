<?php
/**
 * Deployment convention: ONLY the files this deployment actually needs
 * (ParishAdapters/, Contracts/{Events,Schedule}RepositoryInterface.php,
 * DTO/{DeviceContext,UserContext}.php, Auth/, Http/JsonResponse.php,
 * Repositories/Legacy/ — see docs/WITOSA-DEPLOYMENT.md for the exact
 * list) are deployed as ONE folder named `mobileapi-core/`, sitting
 * ONE LEVEL ABOVE `public_html/` on the parish's server — e.g.
 * `/home/user/mobileapi-core/...` next to `/home/user/public_html/...`
 * — matching the existing .env-outside-public_html convention already
 * used by config/database.php itself. It is NEVER web-accessible
 * directly.
 *
 * Inside `public_html/api/mobile/`, each real entrypoint
 * (bootstrap.php, session_login.php, config.php) is a ONE-LINE stub:
 *
 *   <?php require __DIR__ . '/../../../mobileapi-core/ParishAdapters/Witosa/bootstrap.php';
 *
 * — a RELATIVE path, nothing to edit per-server — so there is exactly
 * ONE copy of the real logic (here, in the deployed mobileapi-core/
 * folder), never a second copy duplicated inside public_html. See
 * `stubs/` in this same folder for ready-made copies of these
 * one-liners, one per real entrypoint.
 *
 * This file does NOT open its own database connection — it reuses the
 * parish's EXISTING config/database.php (Iteration 2 point 2: "nie
 * przebudowuj istniejącego ... bardziej niż konieczne"), which already
 * gives us `$conn` (mysqli), Redis, and session setup. The mobile
 * endpoints don't need or use the PHP session it starts as a side effect
 * — bearer-token auth only — but there's no reason to fork a second DB
 * connection just to avoid that harmless side effect.
 */

require_once __DIR__ . '/../autoload.php';

// mobileapi-core/ParishAdapters/Witosa/ -> mobileapi-core/ParishAdapters/ ->
// mobileapi-core/ -> (parent, where public_html/ is a sibling) -> public_html/config/database.php
require_once __DIR__ . '/../../../public_html/config/database.php';

use MinistrantManager\MobileAPI\Auth\MobileUserTokenService;
use MinistrantManager\MobileAPI\Auth\InstallationIdValidator;
use MinistrantManager\MobileAPI\DTO\DeviceContext;
use MinistrantManager\MobileAPI\Http\JsonResponse;

/** @var mysqli $conn provided by config/database.php */

function mobileapi_device_context(): DeviceContext
{
    // installation_id is sent by the app on every request (it already
    // knows it from app.ministrant.eu's device activation, Iteration 1).
    // parish_id/parish_slug are trivially "this parish, whichever one this
    // code is running on" — there is exactly one parish per deployment, so
    // no lookup is needed the way app.ministrant.eu needs one across many.
    $installationId = $_SERVER['HTTP_X_INSTALLATION_ID'] ?? '';
    if ($installationId === '') {
        JsonResponse::error('missing_installation_id', 'Brak nagłówka X-Installation-Id.', 400);
    }
    if (!InstallationIdValidator::isValid($installationId)) {
        JsonResponse::error('invalid_installation_id', 'X-Installation-Id musi być poprawnym UUID.', 400);
    }

    $host = str_replace('www.', '', $_SERVER['HTTP_HOST'] ?? '');
    $parishSlug = explode('.ministrant.eu', $host)[0];

    return new DeviceContext(
        installationId: $installationId,
        parishId: $parishSlug,
        parishSlug: $parishSlug,
        platform: $_SERVER['HTTP_X_PLATFORM'] ?? 'unknown',
    );
}

/**
 * Every business-data entrypoint (bootstrap, sync, actions, config) calls
 * this FIRST. Review point 6: a valid device is never enough on its own —
 * this is the mobile_user_token check, entirely separate from whatever
 * device-level trust app.ministrant.eu already established.
 */
function mobileapi_require_user_auth(mysqli $conn, DeviceContext $ctx): \MinistrantManager\MobileAPI\DTO\UserContext
{
    $authHeader = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    if (!str_starts_with($authHeader, 'Bearer ')) {
        JsonResponse::error('missing_token', 'Brak nagłówka Authorization: Bearer <token>.', 401);
    }
    $rawToken = substr($authHeader, strlen('Bearer '));

    $service = new MobileUserTokenService($conn);
    $userContext = $service->validate($rawToken, $ctx->installationId);

    if ($userContext === null) {
        JsonResponse::error('invalid_token', 'Token nieprawidłowy, wygasły lub odwołany.', 401);
    }

    return $userContext;
}

function mobileapi_read_json_body(): array
{
    $raw = file_get_contents('php://input');
    $data = json_decode($raw, true);
    return is_array($data) ? $data : [];
}

/**
 * Device-control-plane milestone: constructs the one
 * DeviceAuthorizationService instance every endpoint that needs it
 * shares (review round point 3: "Nie rozrzucaj requestów do centrali po
 * endpointach"). Reads this parish's OWN central URL + secret from
 * config/mobile_internal_api_secret.php (deployed into the real
 * public_html/config/ — see docs/WITOSA-DEPLOYMENT.md — same convention
 * as the existing config/ministrant_shared_secrets.php for the
 * unrelated legacy handoff mechanism).
 */
function mobileapi_device_authorization_service(\mysqli $conn): \MinistrantManager\MobileAPI\Auth\DeviceAuthorizationService
{
    require_once __DIR__ . '/../../../public_html/config/mobile_internal_api_secret.php';

    return new \MinistrantManager\MobileAPI\Auth\DeviceAuthorizationService(
        $conn,
        MOBILE_CENTRAL_BASE_URL,
        MOBILE_INTERNAL_API_SECRET,
    );
}
