<?php
// One "login attempt" trying to consume the same recovery code row.
[$dbPath, $resultPath] = [$argv[1], $argv[2]];

$pdo = new PDO("sqlite:$dbPath");
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$pdo->exec('PRAGMA busy_timeout = 5000;');

// Mirrors RecoveryCodeService::attemptConsume(): SELECT unused rows,
// "verify" (trivial here — the fixture only ever seeds one candidate, the
// real Argon2id password_verify() loop is proven separately in
// test_recovery_code_formatter.php), then attempt the atomic UPDATE and
// trust ONLY its affected-row count.
$row = $pdo->query("SELECT id FROM recovery_codes WHERE used_at IS NULL LIMIT 1")->fetch(PDO::FETCH_ASSOC);

if (!$row) {
    file_put_contents($resultPath, json_encode(['pid' => getmypid(), 'consumed' => false, 'reason' => 'no_unused_row_seen']));
    exit;
}

// Widen the race window deliberately, same technique as the activation
// concurrency test — this is exactly the gap a read-then-write (rather
// than an atomic affected-rows check) implementation would fall into.
usleep(30000);

$stmt = $pdo->prepare("UPDATE recovery_codes SET used_at = datetime('now') WHERE id = ? AND used_at IS NULL");
$stmt->execute([$row['id']]);
$affected = $stmt->rowCount();

file_put_contents($resultPath, json_encode(['pid' => getmypid(), 'consumed' => $affected === 1]));
