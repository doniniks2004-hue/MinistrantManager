<?php

namespace MinistrantManager\MobileAPI\Actions;

/**
 * Thrown by a VersionedRecordRepositoryInterface implementation when
 * applyVersionedUpdate() is called with a base_version that no longer
 * matches the record's actual current version. Carries the current record
 * so ActionDispatcher can hand it straight back to the client as the 409
 * payload (spec §14 — client re-fetches, user redoes the edit; server
 * NEVER auto-merges).
 */
class VersionConflictException extends \RuntimeException
{
    public function __construct(public readonly array $currentRecord, public readonly int $currentVersion)
    {
        parent::__construct("Version conflict: expected version does not match current version $currentVersion");
    }
}
