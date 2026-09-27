<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\DB;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('app_config', function (Blueprint $table) {
            $table->string('key')->primary();
            $table->text('value'); // TEXT not string(255): maintenance_message allows up to 500 chars, store URLs up to 500 too
            $table->timestamps();
        });

        // Global fleet configuration, exposed read-only via GET /api/client-config.
        // This is DELIBERATELY separate from a parish's own
        // /api/v1/mobile/config (business/dashboard config) — see
        // MobileAPI package. Everything here concerns the app binary /
        // the whole fleet, not one parish's business rules.
        $now = now();
        DB::table('app_config')->insert([
            ['key' => 'minimum_supported_android_version', 'value' => '1.0.0', 'created_at' => $now, 'updated_at' => $now],
            ['key' => 'minimum_supported_ios_version', 'value' => '1.0.0', 'created_at' => $now, 'updated_at' => $now],
            ['key' => 'latest_android_version', 'value' => '1.0.0', 'created_at' => $now, 'updated_at' => $now],
            ['key' => 'latest_ios_version', 'value' => '1.0.0', 'created_at' => $now, 'updated_at' => $now],
            // Placeholders — see spec decision #15/#9: null-safe until apps are published.
            ['key' => 'android_store_url', 'value' => '', 'created_at' => $now, 'updated_at' => $now],
            ['key' => 'ios_store_url', 'value' => '', 'created_at' => $now, 'updated_at' => $now],
            ['key' => 'maintenance_mode', 'value' => '0', 'created_at' => $now, 'updated_at' => $now],
            ['key' => 'maintenance_message', 'value' => '', 'created_at' => $now, 'updated_at' => $now],
            ['key' => 'offline_lease_hours', 'value' => '72', 'created_at' => $now, 'updated_at' => $now],
            ['key' => 'activation_default_expiry', 'value' => '7_days', 'created_at' => $now, 'updated_at' => $now],
            ['key' => 'activation_default_max_uses', 'value' => '1', 'created_at' => $now, 'updated_at' => $now],
        ]);
    }

    public function down(): void
    {
        Schema::dropIfExists('app_config');
    }
};
