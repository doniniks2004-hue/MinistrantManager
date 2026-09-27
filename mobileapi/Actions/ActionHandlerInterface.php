<?php

namespace MinistrantManager\MobileAPI\Actions;

use MinistrantManager\MobileAPI\DTO\ActionRequest;
use MinistrantManager\MobileAPI\DTO\DeviceContext;

/**
 * One handler per `type` string the mobile app can send in a pending
 * action. ActionDispatcher looks up the right handler by type and
 * delegates to it — the dispatcher itself only owns idempotency-claim +
 * optimistic-concurrency plumbing, never domain logic.
 *
 * Iteration 1.1 point 6 fix: the previous single `apply()` method was
 * ambiguous for versioned actions — its docblock said "performs the
 * actual mutation" but ActionDispatcher then ALSO passed its return value
 * to VersionedRecordRepositoryInterface::applyVersionedUpdate(), which
 * performs its OWN write. A handler author following the old docblock
 * literally could mutate storage directly inside apply() AND have
 * ActionDispatcher perform a second, redundant (or conflicting) write.
 * Splitting into two distinctly-named, mutually exclusive methods removes
 * that ambiguity structurally rather than relying on a comment:
 *
 *   - buildChanges() — ONLY for versioned actions. MUST be pure (no
 *     storage side effects at all). Returns the field changes;
 *     ActionDispatcher passes them verbatim to
 *     VersionedRecordRepositoryInterface::applyVersionedUpdate(), which is
 *     the ONLY place the atomic write happens.
 *   - apply() — ONLY for non-versioned actions. Performs the actual
 *     mutation directly; there is no separate atomic-write step for
 *     these — ActionDispatcher's claim-based idempotency (tryClaim()) is
 *     what guarantees single execution instead of a version check.
 *
 * A handler implements exactly one of the two (matching isVersioned())
 * and throws LogicException from the other, mirroring the existing
 * pattern for recordId() on non-versioned handlers.
 */
interface ActionHandlerInterface
{
    public function isVersioned(): bool;

    /** Only for versioned actions: the entity id base_version applies to. */
    public function recordId(ActionRequest $request): string;

    /**
     * ONLY for versioned actions (isVersioned() === true). MUST be pure —
     * no reads-then-writes, no side effects. Throws LogicException if
     * called on a non-versioned handler.
     *
     * @return array the changes to apply, passed as-is to
     *   VersionedRecordRepositoryInterface::applyVersionedUpdate()
     */
    public function buildChanges(ActionRequest $request, DeviceContext $ctx): array;

    /**
     * ONLY for non-versioned actions (isVersioned() === false). Performs
     * the real mutation. Throws LogicException if called on a versioned
     * handler.
     */
    public function apply(ActionRequest $request, DeviceContext $ctx): void;
}
