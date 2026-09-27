<?php
// Driver: spawns two REAL, concurrent OS processes both trying to consume
// the SAME recovery code row, mirroring the Iteration 1.1 point 7 fix in
// RecoveryCodeService::attemptConsume() (there: Eloquent
// `->whereNull('used_at')->update(...)` and trusting its affected-row
// count; here: the same `UPDATE ... WHERE used_at IS NULL` pattern via
// raw PDO+SQLite, exercised by two real processes rather than a
// single-threaded simulation).

$dir = sys_get_temp_dir() . '/recovery_code_concurrency_test_' . uniqid();
mkdir($dir);
$dbPath = "$dir/test.sqlite";

$pdo = new PDO("sqlite:$dbPath");
$pdo->exec('CREATE TABLE recovery_codes (id INTEGER PRIMARY KEY, code_hash TEXT, used_at TEXT)');
$pdo->exec("INSERT INTO recovery_codes (id, code_hash, used_at) VALUES (1, 'irrelevant-for-this-test', NULL)");
$pdo = null;

$resultA = "$dir/result_a.json";
$resultB = "$dir/result_b.json";

$worker = __DIR__ . '/recovery_code_concurrency_worker.php';
$procA = proc_open(['php', $worker, $dbPath, $resultA], [], $pipesA);
$procB = proc_open(['php', $worker, $dbPath, $resultB], [], $pipesB);

proc_close($procA);
proc_close($procB);

$resA = json_decode(file_get_contents($resultA), true);
$resB = json_decode(file_get_contents($resultB), true);

function assertTrue(bool $cond, string $msg): void {
    if (!$cond) { fwrite(STDERR, "FAIL: $msg\n"); exit(1); }
    echo "PASS: $msg\n";
}

$consumedCount = ($resA['consumed'] ? 1 : 0) + ($resB['consumed'] ? 1 : 0);
assertTrue($consumedCount === 1, "exactly one of the two concurrent login attempts consumed the recovery code (got $consumedCount) — pids {$resA['pid']} / {$resB['pid']}");

$finalPdo = new PDO("sqlite:$dbPath");
$usedAt = $finalPdo->query('SELECT used_at FROM recovery_codes WHERE id = 1')->fetchColumn();
assertTrue($usedAt !== null, 'recovery code row shows used_at set (not left NULL after being consumed once)');

array_map('unlink', glob("$dir/*"));
rmdir($dir);

echo "\nAll recovery-code-concurrency tests passed (real two-process race, real SQLite atomic UPDATE...WHERE used_at IS NULL).\n";
