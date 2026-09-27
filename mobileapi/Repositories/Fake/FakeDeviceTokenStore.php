<?php

namespace MinistrantManager\MobileAPI\Repositories\Fake;

use MinistrantManager\MobileAPI\Contracts\DeviceTokenStoreInterface;

/** TEST IMPLEMENTATION ONLY — see FakeActionLogRepository docblock. */
class FakeDeviceTokenStore implements DeviceTokenStoreInterface
{
    private array $tokens = [];

    public function seed(string $rawToken, string $parishId, string $status = 'active', string $parishStatus = 'active'): void
    {
        $this->tokens[$rawToken] = ['parish_id' => $parishId, 'status' => $status, 'parish_status' => $parishStatus];
    }

    public function lookup(string $rawDeviceToken): ?array
    {
        return $this->tokens[$rawDeviceToken] ?? null;
    }
}
