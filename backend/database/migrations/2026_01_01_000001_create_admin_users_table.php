<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('admin_users', function (Blueprint $table) {
            $table->id();
            $table->string('name');
            $table->string('email')->unique();
            $table->string('password');
            $table->text('totp_secret')->nullable(); // encrypted at rest via AdminUser's 'encrypted' cast (Iteration 1.1 point 9) — TEXT because Laravel's encrypted payload is longer than a raw base32 TOTP secret
            $table->enum('role', ['SUPER_ADMIN', 'ADMIN'])->default('ADMIN');
            $table->boolean('is_active')->default(true);
            $table->boolean('totp_enabled')->default(false);
            $table->timestamp('last_login_at')->nullable();
            $table->string('last_login_ip', 64)->nullable();
            $table->unsignedInteger('failed_login_count')->default(0);
            $table->timestamp('locked_until')->nullable();
            $table->rememberToken();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('admin_users');
    }
};
