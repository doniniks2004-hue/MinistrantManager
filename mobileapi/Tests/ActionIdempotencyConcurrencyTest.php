<?php
require __DIR__ . '/autoload.php';

use MinistrantManager\MobileAPI\Repositories\Fake\SqliteActionLogRepository;

/**
 * Iteration 1.1 point 5's required test, verbatim: "prawdziwy test
 * współbieżności dwóch requestów z IDENTYCZNYM client_action_id ...
 * handler/mutation wykonany dokładnie RAZ." Spawns two REAL, separate OS
 * processes (not two calls in one PHP process — a single process can't
 * demonstrate a cross-request race at all) that both dispatch the exact
 * same client_action_id at essentially the same moment, against a shared
 * SQLite-backed ActionLogRepositoryInterface implementation. The handler's
 * mutation (an UPDATE on a shared counter row, deliberately slowed down
 * to widen the race window) must have executed EXACTLY ONCE no matter
 * how the two processes interleave.
 */

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

$dir = sys_get_temp_dir() . '/mobileapi_idempotency_test_' . uniqid();
mkdir($dir);
$dbPath = "$dir/test.sqlite";

SqliteActionLogRepository::createSchema($dbPath);
$setupPdo = new PDO("sqlite:$dbPath");
$setupPdo->exec('CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER)');
$setupPdo->exec('INSERT INTO counter (id, value) VALUES (1, 0)');
$setupPdo = null; // close before children open their own connections

$clientActionId = 'shared-client-action-id-' . uniqid();
$resultA = "$dir/result_a.json";
$resultB = "$dir/result_b.json";

$worker = __DIR__ . '/action_idempotency_concurrency_worker.php';
$procA = proc_open(['php', $worker, $dbPath, $clientActionId, $resultA], [], $pipesA);
$procB = proc_open(['php', $worker, $dbPath, $clientActionId, $resultB], [], $pipesB);

proc_close($procA);
proc_close($procB);

$resA = json_decode(file_get_contents($resultA), true);
$resB = json_decode(file_get_contents($resultB), true);

// THE property that matters most: the mutation ran exactly once.
$finalPdo = new PDO("sqlite:$dbPath");
$finalCounter = (int) $finalPdo->query('SELECT value FROM counter WHERE id = 1')->fetchColumn();
assertEquals(1, $finalCounter, "shared counter is exactly 1 after two concurrent processes both dispatched client_action_id=$clientActionId (pids {$resA['pid']} / {$resB['pid']}, statuses {$resA['status']} / {$resB['status']})");

// Secondary sanity: exactly one process should report having actually
// run the handler (applied); the other lost the claim race (and, given
// our generous wait budget vs. the handler's 30ms artificial delay,
// should see the winner's result as already_applied rather than timing
// out into "processing" — but we don't hard-fail on "processing" since
// it's still a SAFE outcome, just a slower one; the counter check above
// is what actually proves correctness).
$statuses = [$resA['status'], $resB['status']];
assertTrue(in_array('applied', $statuses, true), 'at least one of the two processes reports "applied" (it ran the handler)');
assertTrue(!(($resA['status'] === 'applied') && ($resB['status'] === 'applied')), 'NOT both processes report "applied" — only one may have actually run the handler');

// cleanup
array_map('unlink', glob("$dir/*"));
rmdir($dir);

echo "\nAll ActionIdempotencyConcurrency tests passed (real two-process race, real SQLite-backed atomic claim).\n";
