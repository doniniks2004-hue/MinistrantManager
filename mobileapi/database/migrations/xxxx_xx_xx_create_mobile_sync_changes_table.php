<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Rename with a real timestamp prefix before running against the existing
 * MM database. Backs SyncChangeLogRepositoryInterface (spec decision #7):
 * ANY code path that mutates a business record synced to mobile — the
 * existing MM web app, an admin action, this API's own action handlers —
 * must append one row here per mutation. This is deliberately NOT derived
 * automatically from each table's own timestamps/soft-deletes, because
 * not every existing MM table has them consistently.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('mobile_sync_changes', function (Blueprint $table) {
            $table->id(); // doubles as the opaque sync cursor
            $table->string('parish_id');
            $table->string('entity_type', 64); // "event", "schedule_assignment", "announcement", ...
            $table->string('entity_id');
            $table->enum('operation', ['create', 'update', 'delete']);
            $table->unsignedBigInteger('version')->nullable(); // null for deletes
            $table->json('data')->nullable(); // full current record snapshot; null for deletes
            $table->timestamp('changed_at')->useCurrent();

            $table->index(['parish_id', 'id']); // the actual "changesSince(cursor)" query path
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('mobile_sync_changes');
    }
};
