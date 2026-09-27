<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class MobileDevice extends Model
{
    protected $fillable = [
        'installation_id', 'parish_id', 'activation_code_id', 'platform',
        'device_model', 'device_label', 'os_version', 'app_version',
        'device_token_hash', 'status', 'activated_at', 'last_seen_at',
        'last_sync_at', 'last_authorization_check', 'revoked_at', 'revoked_by',
    ];

    protected $casts = [
        'activated_at' => 'datetime',
        'last_seen_at' => 'datetime',
        'last_sync_at' => 'datetime',
        'last_authorization_check' => 'datetime',
        'revoked_at' => 'datetime',
    ];

    public function parish(): BelongsTo
    {
        return $this->belongsTo(Parish::class);
    }

    public function activationCode(): BelongsTo
    {
        return $this->belongsTo(MobileActivationCode::class, 'activation_code_id');
    }

    public function isActive(): bool
    {
        return $this->status === 'active' && $this->parish->isActive();
    }
}
