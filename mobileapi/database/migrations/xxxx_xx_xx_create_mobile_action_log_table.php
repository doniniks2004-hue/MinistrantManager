<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Rename with a real timestamp prefix. Backs ActionLogRepositoryInterface.
 *
 * Review round 2, point 3 fix: the previous version of this migration had
 * `result_json` and `parish_id` NOT NULL, but the claim-based idempotency
 * mechanism (tryClaim() -> ... -> finalize()/failClaim()) creates a row
 * BEFORE any result exists and REQUIRES parish_id from the moment of
 * claiming — the old schema could not actually satisfy its own contract.
 * `status` + nullable `result_json` + `claimed_at`/`finalized_at`/
 * `failed_at` now match ActionLogRepositoryInterface exactly (see that
 * interface's docblock for the full state machine), and the SQLite-backed
 * test repository used in ActionIdempotencyConcurrencyTest.php uses this
 * SAME shape (see Repositories/Fake/SqliteActionLogRepository.php) rather
 * than a divergent test-only schema.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('mobile_action_log', function (Blueprint $table) {
            $table->id();
            $table->uuid('client_action_id')->unique();
            $table->string('parish_id');
            $table->string('type', 128);
            $table->enum('status', ['processing', 'completed', 'failed'])->default('processing');
            $table->json('result_json')->nullable(); // null while 'processing'; set on 'completed' or 'failed'
            $table->timestamp('claimed_at');
            $table->timestamp('finalized_at')->nullable();
            $table->timestamp('failed_at')->nullable();
            $table->timestamps();

            $table->index(['parish_id', 'status']);
            $table->index(['status', 'claimed_at']); // the stale-claim reclaim query's access path
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('mobile_action_log');
    }
};
