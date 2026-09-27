<?php
require __DIR__ . '/../app/Services/RecoveryCodeFormatter.php';
use App\Services\RecoveryCodeFormatter;

function assertTrue(bool $cond, string $msg): void {
    if (!$cond) { fwrite(STDERR, "FAIL: $msg\n"); exit(1); }
    echo "PASS: $msg\n";
}

$seen = [];
for ($i = 0; $i < 50; $i++) {
    $code = RecoveryCodeFormatter::generateOne();
    assertTrue((bool) preg_match('/^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/', $code), "code '$code' matches XXXX-XXXX-XXXX / correct alphabet");
    assertTrue(!isset($seen[$code]), "code '$code' not a duplicate within this batch");
    $seen[$code] = true;
}

// Iteration 1.1 point 10: Argon2id via hashForStorage()/verify() — no
// exact-match lookup possible (unlike the old SHA-256), so correctness
// is checked through verify(), same as production code must.
$raw = '7KMF-92QX-P4DT';
$stored = RecoveryCodeFormatter::hashForStorage($raw);

assertTrue(str_starts_with($stored, '$argon2id$'), 'hashForStorage() actually produces an Argon2id hash, not something weaker');
assertTrue(RecoveryCodeFormatter::verify($raw, $stored), 'verify() accepts the exact original code against its own stored hash');

$variants = ['7kmf-92qx-p4dt', '7KMF92QXP4DT', ' 7KMF-92QX-P4DT ', '7KMF 92QX P4DT'];
foreach ($variants as $v) {
    assertTrue(RecoveryCodeFormatter::verify($v, $stored), "verify('$v') still matches regardless of case/dashes/spaces — normalization applied on both sides");
}

assertTrue(!RecoveryCodeFormatter::verify('7KMF-92QX-P4DX', $stored), 'verify() correctly REJECTS a code that differs by one character');

// Two hashes of the SAME code must differ (Argon2id salts each hash) —
// this is the property that makes exact-match lookup impossible and is
// exactly why RecoveryCodeService iterates + verify()s instead.
$stored2 = RecoveryCodeFormatter::hashForStorage($raw);
assertTrue($stored !== $stored2, 'two hashForStorage() calls on the identical raw code produce DIFFERENT hashes (salted) — this is why exact-match DB lookup is no longer possible/used');
assertTrue(RecoveryCodeFormatter::verify($raw, $stored2), 'the second (different) hash still verifies correctly against the same raw code');

echo "\nAll RecoveryCodeFormatter tests passed (format + Argon2id hashing/verification, replacing the old plain-SHA-256 approach).\n";
