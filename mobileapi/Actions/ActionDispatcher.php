<?php

namespace MinistrantManager\MobileAPI\Actions;

use MinistrantManager\MobileAPI\Contracts\ActionLogRepositoryInterface;
use MinistrantManager\MobileAPI\Contracts\VersionedRecordRepositoryInterface;
use MinistrantManager\MobileAPI\DTO\ActionRequest;
use MinistrantManager\MobileAPI\DTO\ActionResult;
use MinistrantManager\MobileAPI\DTO\DeviceContext;

/**
 * The heart of spec §13/§14. Framework-agnostic on purpose — takes its
 * dependencies as constructor interfaces, so it runs identically against
 * the in-memory Fakes (unit tests) or a real shared-storage adapter
 * (production, and — for the specific concurrency proof this class most
 * needs — Tests/ActionIdempotencyConcurrencyTest.php, which runs it
 * inside two REAL, separate OS processes against a REAL shared SQLite
 * file, not just sequential calls in one process).
 *
 * Iteration 1.1 point 5 fix — processing order is now:
 *   1. findResult() — a client_action_id whose processing already
 *      FINISHED returns the same result again, handler never re-runs.
 *   2. tryClaim() — atomic. Exactly one concurrent caller for the same
 *      client_action_id gets to proceed past this point; every other
 *      caller returns immediately without ever touching the handler.
 *   3. (claim winner only) run the versioned/non-versioned logic.
 *   4. finalize() — writes the result so future findResult() calls (by
 *      anyone, including a caller that lost the claim and is retrying)
 *      see it.
 *
 * A caller that LOSES the claim (step 2 returns false) means another
 * request for the exact same client_action_id is concurrently
 * in-flight — not yet finished (or it would have been caught by
 * findResult() in step 1). It polls briefly for that other request's
 * result rather than either running the handler itself (unsafe) or
 * failing outright (unnecessarily — the winner is usually milliseconds
 * from finishing). If it genuinely times out, it returns a `processing`
 * result telling the client to simply retry the sync later — always
 * safe, since retrying is exactly what idempotency exists to make safe.
 *
 * Review round 2, point 4: if the claim WINNER itself throws (handler or
 * repository exception, DB hiccup, anything), the claim is explicitly
 * marked 'failed' via failClaim() rather than left 'processing' forever —
 * see the try/catch in dispatch(). A 'failed' claim is immediately
 * reclaimable by the client's next retry, no staleness timeout needed.
 */
class ActionDispatcher
{
    /** @var array<string, ActionHandlerInterface> */
    private array $handlers = [];

    public function __construct(
        private readonly ActionLogRepositoryInterface $actionLog,
        private readonly VersionedRecordRepositoryInterface $versionedRecords,
        private readonly int $claimWaitRetries = 20,
        private readonly int $claimWaitMicroseconds = 10_000, // 10ms — 20 retries = 200ms worst case
    ) {
    }

    public function registerHandler(string $type, ActionHandlerInterface $handler): void
    {
        $this->handlers[$type] = $handler;
    }

    public function dispatch(ActionRequest $request, DeviceContext $ctx): ActionResult
    {
        $cached = $this->actionLog->findResult($request->clientActionId);
        if ($cached !== null) {
            // Review round 3, point 4 fix: replay the ORIGINAL status
            // (error/conflict/applied), never blanket already_applied —
            // see ActionResult::fromCached()'s docblock for the exact bug
            // this closes (a terminal error silently becoming a
            // false-positive success on retry).
            return ActionResult::fromCached($cached, $request->clientActionId);
        }

        // Review round 2, point 3: tryClaim() now needs the parish id —
        // the production migration's mobile_action_log.parish_id column
        // is NOT NULL, and a claim genuinely belongs to one parish.
        $wonClaim = $this->actionLog->tryClaim($request->clientActionId, $request->type, $ctx->parishId);
        if (!$wonClaim) {
            // THE fix: we do NOT proceed to run the handler here under any
            // circumstance. Either wait for the winner's result, or report
            // "still processing, retry later" — never a silent duplicate.
            return $this->waitForResultOrReportProcessing($request->clientActionId);
        }

        // Review round 2, point 4 fix: everything between a successful
        // claim and finalize() is now wrapped — a handler or repository
        // exception no longer leaves the row stuck 'processing' forever.
        // failClaim() marks it immediately reclaimable, so the VERY NEXT
        // dispatch() call for this exact client_action_id (the client's
        // own retry — pending_actions is never dropped on anything but
        // applied/already_applied/conflict) can genuinely re-attempt the
        // action instead of waiting out a staleness timeout or polling
        // forever for a result that will never arrive.
        try {
            $result = $this->runClaimedAction($request, $ctx);
        } catch (\Throwable $e) {
            $this->actionLog->failClaim($request->clientActionId, $e->getMessage());
            return ActionResult::error($request->clientActionId, 'handler_exception:' . $e->getMessage());
        }

        $this->actionLog->finalize($request->clientActionId, $result->toArray());
        return $result;
    }

    private function runClaimedAction(ActionRequest $request, DeviceContext $ctx): ActionResult
    {
        $handler = $this->handlers[$request->type] ?? null;
        if (!$handler) {
            return ActionResult::error($request->clientActionId, "unknown_action_type:{$request->type}");
        }

        if ($handler->isVersioned()) {
            if ($request->baseVersion === null) {
                return ActionResult::error($request->clientActionId, 'missing_base_version_for_versioned_action');
            }

            $recordId = $handler->recordId($request);
            $current = $this->versionedRecords->find($recordId);

            if ($current === null) {
                return ActionResult::error($request->clientActionId, 'record_not_found');
            }

            if ((int) $current['version'] !== $request->baseVersion) {
                // spec §14: stop here, no write happens.
                return ActionResult::conflict($request->clientActionId, (int) $current['version'], $current);
            }

            try {
                // Iteration 1.1 point 6 fix: buildChanges() is pure — the
                // ONLY write for a versioned action happens right here, in
                // applyVersionedUpdate(), never inside the handler.
                $changes = $handler->buildChanges($request, $ctx);
                $updated = $this->versionedRecords->applyVersionedUpdate($recordId, $request->baseVersion, $changes);
            } catch (VersionConflictException $e) {
                // Belt-and-braces: even if the pre-check above raced with
                // another writer between find() and applyVersionedUpdate(),
                // the atomic write itself is the real authority.
                return ActionResult::conflict($request->clientActionId, $e->currentVersion, $e->currentRecord);
            }

            return ActionResult::applied($request->clientActionId, (int) $updated['version']);
        }

        // Non-versioned, independently-safe action: apply() is the actual
        // mutation. tryClaim() guarantees at most one ACTIVE owner of
        // this client_action_id at any moment — it does NOT by itself
        // guarantee the mutation executes exactly once across the
        // action's full lifetime. See ActionLogRepositoryInterface's
        // docblock ("Review round 3, point 5") for the specific gap (a
        // crash after this line but before finalize() lets a LATER,
        // sequential claim re-run apply()) and what a real non-versioned
        // handler/repository must do about it.
        $handler->apply($request, $ctx);
        return ActionResult::applied($request->clientActionId);
    }

    private function waitForResultOrReportProcessing(string $clientActionId): ActionResult
    {
        for ($i = 0; $i < $this->claimWaitRetries; $i++) {
            usleep($this->claimWaitMicroseconds);
            $result = $this->actionLog->findResult($clientActionId);
            if ($result !== null) {
                // Same fix as dispatch()'s cache-hit branch — the winner
                // we were waiting on may have finished with an 'error' or
                // 'conflict', not necessarily a success.
                return ActionResult::fromCached($result, $clientActionId);
            }
        }

        // The winner hasn't finished yet after our whole wait budget —
        // rather than block forever (or worse, give up and run the
        // handler ourselves), tell the client this is still in flight.
        // The client's existing retry/backoff on pending_actions (it never
        // deletes an action until it sees applied/already_applied/conflict)
        // means this is always safe, just possibly slower.
        return ActionResult::processing($clientActionId);
    }
}
