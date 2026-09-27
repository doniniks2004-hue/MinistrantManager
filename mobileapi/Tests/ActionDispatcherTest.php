<?php
require __DIR__ . '/autoload.php';

use MinistrantManager\MobileAPI\Actions\ActionDispatcher;
use MinistrantManager\MobileAPI\DTO\ActionRequest;
use MinistrantManager\MobileAPI\DTO\DeviceContext;
use MinistrantManager\MobileAPI\Repositories\Fake\FakeActionLogRepository;
use MinistrantManager\MobileAPI\Repositories\Fake\FakeAttendanceHandler;
use MinistrantManager\MobileAPI\Repositories\Fake\FakeScheduleEditHandler;
use MinistrantManager\MobileAPI\Repositories\Fake\FakeVersionedRecordRepository;

function assertTrue(bool $cond, string $msg): void {
    if (!$cond) { fwrite(STDERR, "FAIL: $msg\n"); exit(1); }
    echo "PASS: $msg\n";
}
function assertEquals($expected, $actual, string $msg): void {
    if ($expected !== $actual) {
        fwrite(STDERR, "FAIL: $msg (expected " . var_export($expected, true) . ", got " . var_export($actual, true) . ")\n");
        exit(1);
    }
    echo "PASS: $msg\n";
}

$ctx = new DeviceContext(installationId: 'inst-1', parishId: 'p1', parishSlug: 'chwk', platform: 'android');

// ===================== TEST GROUP 1: idempotency =====================
{
    $log = new FakeActionLogRepository();
    $versioned = new FakeVersionedRecordRepository();
    $dispatcher = new ActionDispatcher($log, $versioned);
    $attendanceHandler = new FakeAttendanceHandler();
    $dispatcher->registerHandler('attendance.mark', $attendanceHandler);

    $request = new ActionRequest(
        clientActionId: 'action-abc-123',
        type: 'attendance.mark',
        payload: ['person' => 'Jan Kowalski', 'status' => 'present'],
        baseVersion: null,
        createdAt: new DateTimeImmutable(),
    );

    $result1 = $dispatcher->dispatch($request, $ctx);
    assertEquals('applied', $result1->status, 'first dispatch of a new action is applied');
    assertEquals(1, count($attendanceHandler->applied), 'handler->apply() called exactly once so far');

    // Simulate the exact same action arriving again (e.g. phone retried
    // after a flaky network response it never saw) — spec §13.
    $result2 = $dispatcher->dispatch($request, $ctx);
    assertEquals('already_applied', $result2->status, 'duplicate client_action_id returns already_applied');
    assertEquals(1, count($attendanceHandler->applied), 'handler->apply() was NOT called a second time — no double attendance mark');
}

// ===================== TEST GROUP 2: optimistic concurrency / conflict =====================
{
    $log = new FakeActionLogRepository();
    $versioned = new FakeVersionedRecordRepository();
    $versioned->seed('assignment-42', ['person' => 'Jan Kowalski', 'role' => 'thurifer'], version: 7);

    $dispatcher = new ActionDispatcher($log, $versioned);
    $dispatcher->registerHandler('schedule.edit_assignment', new FakeScheduleEditHandler());

    // Device A read version 7 and tries to edit against it — should succeed.
    $editA = new ActionRequest(
        clientActionId: 'action-A',
        type: 'schedule.edit_assignment',
        payload: ['record_id' => 'assignment-42', 'changes' => ['role' => 'acolyte']],
        baseVersion: 7,
        createdAt: new DateTimeImmutable(),
    );
    $resultA = $dispatcher->dispatch($editA, $ctx);
    assertEquals('applied', $resultA->status, 'edit against the correct base_version=7 is applied');
    assertEquals(8, $resultA->newVersion, 'version is bumped to 8 after a successful versioned edit');

    // Device B ALSO read version 7 (before A's edit landed) and now tries
    // to push its own edit — server is already at version 8. This is
    // EXACTLY spec §14/§39's test: must be 409/conflict, never silently
    // overwritten.
    $editB = new ActionRequest(
        clientActionId: 'action-B',
        type: 'schedule.edit_assignment',
        payload: ['record_id' => 'assignment-42', 'changes' => ['role' => 'crucifer']],
        baseVersion: 7, // stale on purpose
        createdAt: new DateTimeImmutable(),
    );
    $resultB = $dispatcher->dispatch($editB, $ctx);
    assertEquals('conflict', $resultB->status, 'stale base_version=7 (server now at 8) is rejected as a conflict');
    assertEquals(8, $resultB->newVersion, 'conflict response reports the ACTUAL current version (8)');
    assertEquals('acolyte', $resultB->currentRecord['role'], 'conflict response returns the record as A left it — B\'s change was NEVER applied');

    // Prove it directly against the repository too, not just the response object.
    $finalRecord = $versioned->find('assignment-42');
    assertEquals('acolyte', $finalRecord['role'], 'repository state confirms B never overwrote A\'s change');
    assertEquals(8, $finalRecord['version'], 'repository version is still 8, not bumped again by the rejected conflict');
}

// ===================== TEST GROUP 3: unknown action type doesn't crash =====================
{
    $log = new FakeActionLogRepository();
    $versioned = new FakeVersionedRecordRepository();
    $dispatcher = new ActionDispatcher($log, $versioned);

    $request = new ActionRequest(
        clientActionId: 'action-unknown',
        type: 'some.future.action.type',
        payload: [],
        baseVersion: null,
        createdAt: new DateTimeImmutable(),
    );
    $result = $dispatcher->dispatch($request, $ctx);
    assertEquals('error', $result->status, 'unknown action type returns a clean error, not a crash');
    assertEquals('unknown_action_type:some.future.action.type', $result->errorReason, 'error reason names the unrecognized type');
}

// ===================== TEST GROUP 4 (review round 2, point 4): a claim
// that throws never gets stuck in 'processing' forever =====================
{
    class FlakyThenSucceedsHandler implements \MinistrantManager\MobileAPI\Actions\ActionHandlerInterface
    {
        public int $callCount = 0;

        public function isVersioned(): bool
        {
            return false;
        }

        public function recordId(ActionRequest $request): string
        {
            throw new \LogicException('non-versioned');
        }

        public function buildChanges(ActionRequest $request, DeviceContext $ctx): array
        {
            throw new \LogicException('non-versioned');
        }

        public function apply(ActionRequest $request, DeviceContext $ctx): void
        {
            $this->callCount++;
            if ($this->callCount === 1) {
                throw new \RuntimeException('simulated transient failure (e.g. DB hiccup)');
            }
            // second call onward: succeeds, no exception.
        }
    }

    $log = new FakeActionLogRepository();
    $versioned = new FakeVersionedRecordRepository();
    $dispatcher = new ActionDispatcher($log, $versioned);
    $handler = new FlakyThenSucceedsHandler();
    $dispatcher->registerHandler('flaky.action', $handler);

    $request = new ActionRequest(
        clientActionId: 'action-flaky-1',
        type: 'flaky.action',
        payload: [],
        baseVersion: null,
        createdAt: new DateTimeImmutable(),
    );

    // First attempt: the handler throws. THE bug being fixed: this must
    // NOT leave the claim stuck 'processing' forever.
    $firstResult = $dispatcher->dispatch($request, $ctx);
    assertEquals('error', $firstResult->status, 'a handler exception surfaces as a clean error result, not an uncaught crash');
    assertEquals(1, $handler->callCount, 'the handler ran exactly once so far');
    assertEquals(null, $log->findResult('action-flaky-1'), 'findResult() is null after a failed claim — a failure is NOT a valid cached final answer');

    // Second attempt — same client_action_id, simulating the client's own
    // retry (pending_actions is never dropped on anything but
    // applied/already_applied/conflict). THE fix under test: tryClaim()
    // must reclaim the 'failed' row immediately (no staleness wait
    // needed) and the handler must genuinely run AGAIN, not just report
    // a stale cached result.
    $secondResult = $dispatcher->dispatch($request, $ctx);
    assertEquals('applied', $secondResult->status, 'the retry succeeds because the handler genuinely ran again (and this time did not throw)');
    assertEquals(2, $handler->callCount, 'the handler ran a SECOND time on retry — proves the claim was reclaimed, not left permanently stuck');

    // Third attempt — now that it's completed, ordinary idempotency
    // applies again: no further handler calls, ever.
    $thirdResult = $dispatcher->dispatch($request, $ctx);
    assertEquals('already_applied', $thirdResult->status, 'once genuinely completed, further retries hit ordinary idempotency, not another handler run');
    assertEquals(2, $handler->callCount, 'the handler was NOT called a third time');
}

// ===================== TEST GROUP 5 (review round 3, point 4): a
// terminal error must replay as the SAME error, never as already_applied
// =====================
{
    $log = new FakeActionLogRepository();
    $versioned = new FakeVersionedRecordRepository();
    $dispatcher = new ActionDispatcher($log, $versioned);
    // Deliberately NO handler registered for 'some.unknown.type' — this
    // is the exact scenario from the review report.

    $request = new ActionRequest(
        clientActionId: 'action-replay-error-1',
        type: 'some.unknown.type',
        payload: [],
        baseVersion: null,
        createdAt: new DateTimeImmutable(),
    );

    $firstResult = $dispatcher->dispatch($request, $ctx);
    assertEquals('error', $firstResult->status, 'first dispatch of an unknown action type is an error, as before');

    // THE bug, reproduced verbatim from the review report: dispatching
    // the EXACT SAME client_action_id again used to come back as
    // "already_applied" — which the Flutter client reads as "this
    // succeeded, safe to delete from pending_actions" — even though the
    // action was NEVER actually applied.
    $secondResult = $dispatcher->dispatch($request, $ctx);
    assertEquals('error', $secondResult->status, 'retrying the SAME client_action_id still reports error — NEVER already_applied for an action that was never applied');
    assertEquals($firstResult->errorReason, $secondResult->errorReason, 'the replayed error carries the exact same reason as the original');

    // A third retry, for good measure — this must stay stable forever,
    // not flip after some number of attempts.
    $thirdResult = $dispatcher->dispatch($request, $ctx);
    assertEquals('error', $thirdResult->status, 'a third retry is still error, indefinitely stable');
}

// ===================== TEST GROUP 6 (review round 3, point 4): a
// replayed conflict stays a conflict, never becomes already_applied
// =====================
{
    $log = new FakeActionLogRepository();
    $versioned = new FakeVersionedRecordRepository();
    $versioned->seed('assignment-99', ['role' => 'lector'], version: 3);
    $dispatcher = new ActionDispatcher($log, $versioned);
    $dispatcher->registerHandler('schedule.edit_assignment', new FakeScheduleEditHandler());

    $staleEdit = new ActionRequest(
        clientActionId: 'action-replay-conflict-1',
        type: 'schedule.edit_assignment',
        payload: ['record_id' => 'assignment-99', 'changes' => ['role' => 'thurifer']],
        baseVersion: 1, // stale on purpose — server is already at version 3
        createdAt: new DateTimeImmutable(),
    );

    $firstResult = $dispatcher->dispatch($staleEdit, $ctx);
    assertEquals('conflict', $firstResult->status, 'a stale base_version is a conflict, as before');

    $secondResult = $dispatcher->dispatch($staleEdit, $ctx);
    assertEquals('conflict', $secondResult->status, 'retrying the SAME client_action_id replays conflict, NOT already_applied');
    assertEquals('lector', $secondResult->currentRecord['role'], 'replayed conflict still carries the correct (unapplied) current record');
}

// ===================== TEST GROUP 7 (final micro-round, point 1):
// ActionResult::fromCached() must fail CLOSED on an unrecognized cached
// status, never silently report success =====================
{
    $result = \MinistrantManager\MobileAPI\DTO\ActionResult::fromCached(
        ['status' => 'some_future_status_this_version_does_not_know'],
        'action-unknown-cached-status',
    );
    assertEquals('error', $result->status, 'an unrecognized cached status is replayed as error, NEVER already_applied');
    assertEquals('unknown_cached_status', $result->errorReason, 'the error reason names exactly what happened');

    // Same for a cached row with NO status key at all (defensive — should
    // not be reachable given ActionLogRepositoryInterface's contract, but
    // must still fail safe rather than crash or silently succeed).
    $resultNoStatus = \MinistrantManager\MobileAPI\DTO\ActionResult::fromCached([], 'action-no-status');
    assertEquals('error', $resultNoStatus->status, 'a cached row with no status at all is also replayed as error');
}

echo "\nAll ActionDispatcher tests passed (idempotency + optimistic concurrency + unknown-type safety).\n";
