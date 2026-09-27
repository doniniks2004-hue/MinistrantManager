<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class AdminRecoveryCode extends Model
{
    protected $fillable = ['admin_user_id', 'code_hash', 'used_at'];

    protected $casts = ['used_at' => 'datetime'];

    public function admin(): BelongsTo
    {
        return $this->belongsTo(AdminUser::class, 'admin_user_id');
    }

    public function isUsable(): bool
    {
        return $this->used_at === null;
    }
}
