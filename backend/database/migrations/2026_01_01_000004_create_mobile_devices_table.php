<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('mobile_devices', function (Blueprint $table) {
            $table->id();
            $table->uuid('installation_id')->unique();
            $table->foreignId('parish_id')->constrained('parishes')->cascadeOnDelete();
            $table->foreignId('activation_code_id')->nullable()->constrained('mobile_activation_codes')->nullOnDelete();
            $table->enum('platform', ['android', 'ios']);
            $table->string('device_model')->nullable();
            $table->string('device_label')->nullable(); // e.g. "Tablet zakrystia"
            $table->string('os_version')->nullable();
            $table->string('app_version')->nullable();
            $table->string('device_token_hash', 64)->unique(); // SHA-256 of the raw device token
            $table->enum('status', ['active', 'revoked'])->default('active');
            $table->timestamp('activated_at');
            $table->timestamp('last_seen_at')->nullable();
            $table->timestamp('last_sync_at')->nullable();
            $table->timestamp('last_authorization_check')->nullable();
            $table->timestamp('revoked_at')->nullable();
            $table->unsignedBigInteger('revoked_by')->nullable();
            $table->timestamps();

            $table->index(['parish_id', 'status']);
            $table->index('last_seen_at');
            $table->index('platform');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('mobile_devices');
    }
};
