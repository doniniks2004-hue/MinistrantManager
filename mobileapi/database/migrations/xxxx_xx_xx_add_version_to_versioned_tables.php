<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Rename with a real timestamp prefix. Adjust the table list to whatever
 * the REAL existing MM schema calls its schedule-assignment / event /
 * parish-settings tables (Iteration 2 — see docs/INTEGRATION.md). This is
 * a template, not a guess at your actual table names.
 */
return new class extends Migration
{
    private const TABLES_NEEDING_VERSION = [
        // 'schedule_assignments',
        // 'events',
        // 'parish_settings',
    ];

    public function up(): void
    {
        foreach (self::TABLES_NEEDING_VERSION as $table) {
            if (Schema::hasTable($table) && !Schema::hasColumn($table, 'version')) {
                Schema::table($table, fn (Blueprint $t) => $t->unsignedBigInteger('version')->default(1));
            }
        }
    }

    public function down(): void
    {
        foreach (self::TABLES_NEEDING_VERSION as $table) {
            if (Schema::hasTable($table) && Schema::hasColumn($table, 'version')) {
                Schema::table($table, fn (Blueprint $t) => $t->dropColumn('version'));
            }
        }
    }
};
