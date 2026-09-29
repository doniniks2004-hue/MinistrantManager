<?php

namespace MinistrantManager\MobileAPI\Http;

/**
 * Iteration 2, point 3A ("plain-PHP foundation: ... JSON request/response,
 * błędy"). Every parish entrypoint file (api/mobile/*.php) ends in exactly
 * one call to either JsonResponse::success() or JsonResponse::error() —
 * never a bare `echo json_encode(...)` scattered inline, so every
 * endpoint's error SHAPE is identical no matter which one fails.
 */
final class JsonResponse
{
    public static function success(array $data, int $status = 200)
    {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        exit;
    }

    /**
     * $code is a short, stable machine-readable string (e.g.
     * "invalid_credentials", "missing_installation_id") — the client can
     * safely switch on it; $message is a human string that may change
     * wording over time and should never be pattern-matched on.
     *
     * $extra (device-control-plane milestone): additional machine-
     * readable fields merged into the response alongside error/message
     * — e.g. `device_state` so a client can distinguish WHICH of several
     * reasons a 403 covers, without parsing $message. Never overrides
     * the `error`/`message` keys themselves, even if $extra happens to
     * contain those keys.
     */
    public static function error(string $code, string $message, int $status = 400, array $extra = [])
    {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
        $payload = array_merge($extra, ['error' => $code, 'message' => $message]);
        echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        exit;
    }
}
