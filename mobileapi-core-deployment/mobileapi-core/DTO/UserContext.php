<?php

namespace MinistrantManager\MobileAPI\DTO;

/**
 * Iteration 2, review point 6: deliberately a SEPARATE object from
 * DeviceContext, never merged into it. A valid device_token proves "this
 * physical device is activated and not revoked" — it says NOTHING about
 * which human is currently using it or what they're allowed to see.
 * Every business-data endpoint (bootstrap, sync, actions) must require
 * BOTH a valid DeviceContext AND a valid UserContext; neither substitutes
 * for the other.
 */
final class UserContext
{
    public function __construct(
        public readonly int $userId,
        public readonly int $roleId,
        public readonly string $roleName,
        public readonly ?int $parentId = null,
        public readonly bool $canRequestSubstitution = true,
        public readonly bool $canAcceptSubstitution = true,
    ) {
    }

    public function isParent(): bool
    {
        // role_id 4 = 'Rodzic' in Witosa's live `roles` data. Not hardcoded
        // as a magic number in call sites — this is the one place that
        // knows it, named for what it means.
        return $this->roleName === 'Rodzic';
    }

    public function isAdmin(): bool
    {
        return $this->roleName === 'Admin';
    }
}
