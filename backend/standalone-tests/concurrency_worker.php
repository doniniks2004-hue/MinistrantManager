<?php
// One "device" trying to consume the activation code. Run as a separate
// OS process (via proc_open in the driver script) so the two attempts are
// genuinely concurrent, not just interleaved coroutines in one process.
[$dbPath, $resultPath] = [$argv[1], $argv[2]];

$pdo = new PDO("sqlite:$dbPath");
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$pdo->exec('PRAGMA busy_timeout = 5000;');

// BEGIN IMMEDIATE acquires SQLite's write lock up front — the closest
// single-file-DB equivalent to MySQL's `SELECT ... FOR UPDATE` inside a
// transaction: the second process genuinely blocks here until the first
// commits, rather than both reading a stale used_count.
$pdo->exec('BEGIN IMMEDIATE');

$row = $pdo->query('SELECT used_count, max_uses FROM activation_codes WHERE id = 1')->fetch(PDO::FETCH_ASSOC);

// Simulate real work happening while holding the lock (network-adjacent
// code, hashing, etc.) — this is exactly the window where the ORIGINAL,
// unfixed code (check outside the transaction) would let both processes
// pass the check before either incremented.
usleep(50000);

$activated = false;
if ($row['used_count'] < $row['max_uses']) {
    $pdo->exec('UPDATE activation_codes SET used_count = used_count + 1 WHERE id = 1');
    $activated = true;
}

$pdo->exec('COMMIT');

file_put_contents($resultPath, json_encode(['pid' => getmypid(), 'activated' => $activated]));
