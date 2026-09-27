<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

class MobileActivationCode extends Model
{
    protected $fillable = [
        'parish_id', 'token_hash', 'display_code', 'expires_at',
        'max_uses', 'used_count', 'status', 'created_by', 'revoked_at',
    ];

    protected $casts = [
        'expires_at' => 'datetime',
        'revoked_at' => 'datetime',
    ];

    public function parish(): BelongsTo
    {
        return $this->belongsTo(Parish::class);
    }

    public function devices(): HasMany
    {
        return $this->hasMany(MobileDevice::class, 'activation_code_id');
    }

    public function isUsable(): bool
    {
        if ($this->status !== 'active') {
            return false;
        }
        if ($this->expires_at && $this->expires_at->isPast()) {
            return false;
        }
        if (!is_null($this->max_uses) && $this->used_count >= $this->max_uses) {
            return false;
        }
        return true;
    }
}
