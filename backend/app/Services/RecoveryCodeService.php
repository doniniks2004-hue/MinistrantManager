<?php

namespace App\Services;

use App\Models\AdminRecoveryCode;
use App\Models\AdminUser;

/**
 * Spec decision #5: 10 single-use codes, shown only at generation time and
 * never persisted in plaintext — only their Argon2id hash. Regeneration
 * always replaces the whole set.
 */
class RecoveryCodeService
{
    public function regenerate(AdminUser $admin): array
    {
        $admin->recoveryCodes()->delete();

        $rawCodes = [];
        foreach (range(1, 10) as $_) {
            $raw = RecoveryCodeFormatter::generateOne();
            $rawCodes[] = $raw;
            AdminRecoveryCode::create([
                'admin_user_id' => $admin->id,
                'code_hash' => RecoveryCodeFormatter::hashForStorage($raw),
            ]);
        }

        return $rawCodes;
    }

    /**
     * Iteration 1.1 points 7+10 fix, combined:
     *
     *   - point 10: Argon2id hashes can't be looked up by exact value the
     *     way SHA-256 could, so the old `where('code_hash', $hash)->first()`
     *     query is gone — we fetch the (at most 10) unused hashes for this
     *     admin and check each with password_verify() until one matches.
     *   - point 7: the actual "consume" is now a single atomic
     *     `UPDATE ... WHERE id = ? AND used_at IS NULL`, and we trust ONLY
     *     its affected-row count (1 = we won, 0 = someone else consumed
     *     this exact row between our SELECT and our UPDATE) — never the
     *     earlier `whereNull('used_at')->first()` SELECT result, which
     *     left a real read-then-write race window two concurrent logins
     *     with the same recovery code could both pass through.
     */
    public function attemptConsume(AdminUser $admin, string $rawCode): bool
    {
        $candidates = $admin->recoveryCodes()->whereNull('used_at')->get();

        foreach ($candidates as $candidate) {
            if (!RecoveryCodeFormatter::verify($rawCode, $candidate->code_hash)) {
                continue;
            }

            $affected = AdminRecoveryCode::where('id', $candidate->id)
                ->whereNull('used_at')
                ->update(['used_at' => now()]);

            // affected === 0 here means another concurrent request consumed
            // THIS SAME candidate row in the gap between our SELECT (get())
            // and this UPDATE — correctly reported as "not consumed by us",
            // never silently treated as success.
            return $affected === 1;
        }

        return false;
    }

    public function remainingCount(AdminUser $admin): int
    {
        return $admin->recoveryCodes()->whereNull('used_at')->count();
    }
}
