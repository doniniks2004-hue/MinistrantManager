<?php

namespace MinistrantManager\MobileAPI\Contracts;

/**
 * Contract for any repository backing a record type that supports
 * optimistic concurrency (spec §14): schedule assignments, events, parish
 * settings, and any other multi-editor business record. A repository NOT
 * implementing this (e.g. read-only reference data) simply isn't used for
 * versioned actions.
 */
interface VersionedRecordRepositoryInterface
{
    /**
     * Returns the record as an associative array (including its current
     * `version` key), or null if it doesn't exist.
     */
    public function find(string $id): ?array;

    /**
     * Applies $changes to the record currently at $expectedVersion,
     * atomically bumping its version by 1. MUST be a no-op / throw
     * VersionConflictException if the record's actual current version
     * does not equal $expectedVersion at the moment of the write — callers
     * (ActionDispatcher) rely on this for correctness under concurrent
     * writers, so a real (Eloquent/DB) implementation MUST do the
     * check-and-write atomically (e.g. `UPDATE ... WHERE version = ?` and
     * checking affected-row count, or `SELECT ... FOR UPDATE` first).
     *
     * @throws VersionConflictException
     */
    public function applyVersionedUpdate(string $id, int $expectedVersion, array $changes): array;
}
