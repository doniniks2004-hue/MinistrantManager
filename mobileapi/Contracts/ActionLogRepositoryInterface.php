<?php

namespace MinistrantManager\MobileAPI\Contracts;

/**
 * Idempotency ledger (spec §13). Review round 2, points 3+4 fix
 * (superseding the Iteration 1.1 point 5 version of this interface):
 *
 * - point 3: a claim row is created BEFORE any result exists — the
 *   PREVIOUS contract's production migration required `result_json` and
 *   `parish_id` NOT NULL while `tryClaim()` didn't even accept a
 *   parish_id, so a real adapter literally could not satisfy its own
 *   migration. `result_json` is now nullable and `tryClaim()` takes
 *   `parishId`.
 * - point 4: a claim that never gets finalized (handler/repository threw,
 *   process crashed) must not leave the row stuck 'processing' forever —
 *   `failClaim()` gives an explicit, immediate "this attempt failed, the
 *   NEXT attempt may retry" path, and `tryClaim()` itself is responsible
 *   for reclaiming a 'failed' row immediately, or a 'processing' row
 *   older than `$staleAfterSeconds` (covers a crash between claim and
 *   failClaim()).
 *
 * Row lifecycle: processing -> completed (finalize()) | failed
 * (failClaim()). A 'failed' row is always reclaimable by a fresh
 * tryClaim() — failure is a definitive, immediate signal nothing is
 * still working on it, no staleness wait needed. A 'processing' row is
 * only reclaimable once genuinely stale.
 *
 * ⚠ REVIEW ROUND 3, POINT 5 — WHAT THIS MECHANISM DOES NOT GUARANTEE:
 * tryClaim()'s atomicity guarantees at most one ACTIVE claim owner for a
 * given client_action_id at any moment — it prevents two CONCURRENT
 * callers from both running the handler (see
 * Tests/ActionIdempotencyConcurrencyTest.php). It does NOT by itself
 * guarantee the handler's mutation executes exactly once across the
 * action's full lifetime: if a claim winner completes its business
 * mutation but crashes (process killed, DB connection dropped, etc.)
 * before ActionDispatcher reaches finalize(), that claim sits
 * 'processing' until $staleAfterSeconds elapses, after which a LATER,
 * SEQUENTIAL caller reclaims it and calls apply() again — for a
 * genuinely idempotent operation (e.g. "set attendance = present") a
 * second run is harmless, but for a non-idempotent one (e.g. "add +5
 * points") it is a real double-execution bug.
 *
 * Before Iteration 2 wires real, non-versioned handlers (attendance,
 * points, substitutions, ...) against real storage, EACH ONE MUST do one
 * of:
 *   (a) be idempotent with respect to client_action_id on its own terms
 *       (e.g. a "points ledger" row keyed by client_action_id rather than
 *       a running total incremented in place — replaying the same
 *       client_action_id inserts the same row again / is a no-op upsert,
 *       never adds twice), OR
 *   (b) wrap the claim, the mutation, AND finalize() in one database
 *       transaction, when the action log and the business data share the
 *       same storage — so a crash before commit rolls back the claim
 *       AND the mutation together, and a stale-reclaim never finds a
 *       claim whose mutation half silently already happened.
 * This interface does not enforce either — it is a contract obligation on
 * whoever implements ActionHandlerInterface::apply() and whatever
 * ActionLogRepositoryInterface adapter backs it in Iteration 2, not
 * something ActionDispatcher can verify generically.
 */
interface ActionLogRepositoryInterface
{
    /**
     * Returns the FINAL result for this client_action_id — ONLY when its
     * row is 'completed'. Returns null for 'processing' (still in
     * flight, possibly by someone else), 'failed' (the failed attempt's
     * result is not a valid final answer — a fresh retry is what should
     * happen next, not replaying the failure), or genuinely unseen.
     */
    public function findResult(string $clientActionId): ?array;

    /**
     * Atomically attempts to become the sole owner of processing this
     * client_action_id for parish $parishId. Returns true iff THIS call
     * now owns the claim (a brand new row, OR a reclaimed 'failed'
     * row, OR a reclaimed stale 'processing' row) — the caller MUST then
     * run the handler and call finalize() or failClaim(). Returns false
     * if another still-live claim exists; the caller MUST NOT run the
     * handler.
     */
    public function tryClaim(string $clientActionId, string $type, string $parishId, int $staleAfterSeconds = 30): bool;

    /** Marks an owned claim 'completed' with its final result. */
    public function finalize(string $clientActionId, array $result): void;

    /**
     * Marks an owned claim 'failed' (review round 2, point 4) — called
     * from ActionDispatcher's catch block around the handler/repository
     * call, so an exception between claim and finalize never leaves the
     * row stuck 'processing'. Immediately makes the row reclaimable by
     * the next tryClaim() for the same client_action_id, regardless of
     * $staleAfterSeconds.
     */
    public function failClaim(string $clientActionId, string $reason): void;
}
