<?php

namespace MinistrantManager\MobileAPI\DTO;

/**
 * Outcome of dispatching one ActionRequest. `status` is one of:
 *   - applied           — newly executed
 *   - already_applied    — idempotency hit (same client_action_id seen before)
 *   - conflict          — base_version didn't match current server version;
 *                          NOTHING was overwritten (spec §14 — no auto-merge)
 *   - error             — the record didn't exist / payload invalid / etc.
 *   - processing        — lost the idempotency claim race to a concurrent
 *                          identical request that hadn't finished within
 *                          our wait budget (spec §13, Iteration 1.1 point 5)
 */
final class ActionResult
{
    private function __construct(
        public readonly string $clientActionId,
        public readonly string $status,
        public readonly ?int $newVersion = null,
        public readonly ?array $currentRecord = null,
        public readonly ?string $errorReason = null,
    ) {
    }

    public static function applied(string $clientActionId, ?int $newVersion = null): self
    {
        return new self($clientActionId, 'applied', newVersion: $newVersion);
    }

    public static function alreadyApplied(string $clientActionId, ?int $newVersion = null): self
    {
        return new self($clientActionId, 'already_applied', newVersion: $newVersion);
    }

    public static function conflict(string $clientActionId, int $currentVersion, array $currentRecord): self
    {
        return new self($clientActionId, 'conflict', newVersion: $currentVersion, currentRecord: $currentRecord);
    }

    public static function error(string $clientActionId, string $reason): self
    {
        return new self($clientActionId, 'error', errorReason: $reason);
    }

    public static function processing(string $clientActionId): self
    {
        return new self($clientActionId, 'processing');
    }

    /**
     * Review round 3, point 4 fix: reconstructs a REPLAYED result from
     * whatever was actually stored on a completed action-log row —
     * preserving its ORIGINAL status, never collapsing every cache hit
     * into 'already_applied'. The bug this replaces: a terminal 'error'
     * (e.g. unknown_action_type, missing_base_version, record_not_found —
     * all returned normally by runClaimedAction() without throwing, and
     * therefore finalize()'d as a permanent, replayable outcome, same as
     * a success) was being replayed as 'already_applied' on retry — which
     * a client reasonably reads as "this succeeded before", so it deleted
     * the pending_actions row and the operation was NEVER actually
     * applied. A retried 'applied' result SHOULD become 'already_applied'
     * (that IS success, just idempotent) — but 'error' must stay 'error',
     * and 'conflict' must stay 'conflict', every time it's replayed.
     */
    public static function fromCached(array $cached, string $clientActionId): self
    {
        return match ($cached['status'] ?? null) {
            'applied' => self::alreadyApplied($clientActionId, $cached['new_version'] ?? null),
            'conflict' => new self($clientActionId, 'conflict', newVersion: $cached['new_version'] ?? null, currentRecord: $cached['current_record'] ?? []),
            'error' => self::error($clientActionId, $cached['reason'] ?? 'unknown_error'),
            // Defensive default for a status this version doesn't
            // recognize (e.g. an older/newer writer) — replayed as
            // already_applied rather than crashing, but this branch
            // should not be reachable given the state machine above.
            default => self::alreadyApplied($clientActionId, $cached['new_version'] ?? null),
        };
    }

    public function toArray(): array
    {
        return array_filter([
            'client_action_id' => $this->clientActionId,
            'status' => $this->status,
            'new_version' => $this->newVersion,
            'current_record' => $this->currentRecord,
            'reason' => $this->errorReason,
        ], fn ($v) => $v !== null);
    }
}
