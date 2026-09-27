<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('parishes', function (Blueprint $table) {
            $table->id();
            $table->string('name');
            $table->string('slug')->unique(); // e.g. "chwk"
            $table->string('subdomain')->unique(); // e.g. "chwk.ministrant.eu"
            $table->string('server_url'); // e.g. "https://chwk.ministrant.eu"
            $table->enum('mobile_status', ['active', 'disabled'])->default('active');
            $table->unsignedInteger('offline_lease_hours')->nullable(); // null = inherit global default from app_config
            $table->timestamp('disabled_at')->nullable();
            $table->unsignedBigInteger('disabled_by')->nullable();
            $table->timestamps();

            $table->index('mobile_status');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('parishes');
    }
};
