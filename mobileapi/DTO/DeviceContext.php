<?php

namespace MinistrantManager\MobileAPI\DTO;

/**
 * Everything a repository/action handler needs to know about the calling
 * device WITHOUT touching HTTP concerns. Built by VerifyDeviceToken and
 * passed down into every Controller -> Repository call. `userId`/`role`
 * are nullable because Iteration 1 has no real user-identity model yet
 * (spec decision #8 — "nie wymyślajcie nowego systemu autoryzacji"): they
 * exist as fields ready to be filled in by the Iteration 2 adapter once
 * the real Ministrant Manager user model is wired in.
 */
final class DeviceContext
{
    public function __construct(
        public readonly string $installationId,
        public readonly string $parishId,
        public readonly string $parishSlug,
        public readonly string $platform,
        public readonly ?string $userId = null,
        public readonly ?string $role = null,
    ) {
    }
}
