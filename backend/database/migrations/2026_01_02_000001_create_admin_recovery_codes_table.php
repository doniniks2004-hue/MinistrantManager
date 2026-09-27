<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('admin_recovery_codes', function (Blueprint $table) {
            $table->id();
            $table->foreignId('admin_user_id')->constrained('admin_users')->cascadeOnDelete();
            $table->string('code_hash', 255); // Argon2id (~97 chars) — see RecoveryCodeFormatter::hashForStorage(); raw code shown once at generation time, never stored
            $table->timestamp('used_at')->nullable();
            $table->timestamps();

            $table->index(['admin_user_id', 'used_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('admin_recovery_codes');
    }
};
