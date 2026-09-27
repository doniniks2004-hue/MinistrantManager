<?php
// Driver: spawns two REAL, concurrent OS processes racing to activate the
// same max_uses=1 code, mirroring the fix in
// ActivationController::confirm()/lockCodeForUpdate() (there: MySQL
// `lockForUpdate()` inside `DB::transaction()`; here: SQLite `BEGIN
// IMMEDIATE`, same "lock, re-check, mutate, commit" shape). This exercises
// REAL process-level concurrency and REAL database locking — not a
// single-threaded simulation — which is exactly the class of bug
// (TOCTOU race) that a single-process unit test cannot catch.

$dir = sys_get_temp_dir() . '/ministrant_concurrency_test_' . uniqid();
mkdir($dir);
$dbPath = "$dir/test.sqlite";

$pdo = new PDO("sqlite:$dbPath");
$pdo->exec('CREATE TABLE activation_codes (id INTEGER PRIMARY KEY, used_count INTEGER, max_uses INTEGER)');
$pdo->exec('INSERT INTO activation_codes (id, used_count, max_uses) VALUES (1, 0, 1)'); // single-use code
$pdo = null; // close before children open their own connections

$resultA = "$dir/result_a.json";
$resultB = "$dir/result_b.json";

$workerScript = __DIR__ . '/concurrency_worker.php';
$procA = proc_open(['php', $workerScript, $dbPath, $resultA], [], $pipesA);
$procB = proc_open(['php', $workerScript, $dbPath, $resultB], [], $pipesB);

proc_close($procA);
proc_close($procB);

$resA = json_decode(file_get_contents($resultA), true);
$resB = json_decode(file_get_contents($resultB), true);

function assertTrue(bool $cond, string $msg): void {
    if (!$cond) { fwrite(STDERR, "FAIL: $msg\n"); exit(1); }
    echo "PASS: $msg\n";
}

$activatedCount = ($resA['activated'] ? 1 : 0) + ($resB['activated'] ? 1 : 0);
assertTrue($activatedCount === 1, "exactly one of the two concurrent processes activated the max_uses=1 code (got $activatedCount) — pids " . $resA['pid'] . ' / ' . $resB['pid']);

$finalPdo = new PDO("sqlite:$dbPath");
$finalCount = $finalPdo->query('SELECT used_count FROM activation_codes WHERE id = 1')->fetchColumn();
assertTrue((int) $finalCount === 1, "final used_count in DB is exactly 1, not 2 (no double-activation), got $finalCount");

// cleanup
array_map('unlink', glob("$dir/*"));
rmdir($dir);

echo "\nAll activation-concurrency tests passed (real two-process race, real SQLite locking).\n";
