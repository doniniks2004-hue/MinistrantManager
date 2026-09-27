<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('mobile_activation_codes', function (Blueprint $table) {
            $table->id();
            $table->foreignId('parish_id')->constrained('parishes')->cascadeOnDelete();
            $table->string('token_hash', 64)->unique(); // SHA-256 of the raw activation token
            $table->string('display_code', 16)->unique(); // human readable e.g. 73FK-92MX
            $table->timestamp('expires_at')->nullable(); // null = no expiry
            $table->unsignedInteger('max_uses')->nullable(); // null = unlimited
            $table->unsignedInteger('used_count')->default(0);
            $table->enum('status', ['active', 'expired', 'revoked', 'used'])->default('active');
            $table->unsignedBigInteger('created_by')->nullable();
            $table->timestamp('revoked_at')->nullable();
            $table->timestamps();

            $table->index(['parish_id', 'status']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('mobile_activation_codes');
    }
};
