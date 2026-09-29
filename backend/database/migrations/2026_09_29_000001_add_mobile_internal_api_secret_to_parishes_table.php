<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Device-control-plane milestone: a dedicated, PER-PARISH secret for the
 * new server-to-server `POST /internal/mobile/device/validate` endpoint.
 *
 * Deliberately NOT reusing the legacy MINISTRANT_INTERNAL_API_SECRET
 * (that one authenticates a completely different relationship —
 * ministrant.eu's old remember/handoff broker <-> parish — and is a
 * single shared value across the whole fleet). A per-parish secret here
 * means one parish's credential leaking never lets it query about
 * ANOTHER parish's devices, and revoking one parish's access (e.g. if
 * their secret is compromised) never affects anyone else.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('parishes', function (Blueprint $table) {
            $table->string('mobile_internal_api_secret', 64)->nullable()->unique()->after('server_url');
        });
    }

    public function down(): void
    {
        Schema::table('parishes', function (Blueprint $table) {
            $table->dropColumn('mobile_internal_api_secret');
        });
    }
};
