<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

class Parish extends Model
{
    protected $fillable = [
        'name', 'slug', 'subdomain', 'server_url', 'mobile_internal_api_secret',
        'mobile_status', 'offline_lease_hours', 'disabled_at', 'disabled_by',
    ];

    // Device-control-plane milestone: never accidentally serialize this
    // into an admin view/API response — it authenticates
    // server-to-server device-validate calls, same care as a password.
    protected $hidden = [
        'mobile_internal_api_secret',
    ];

    protected $casts = [
        'disabled_at' => 'datetime',
    ];

    public function devices(): HasMany
    {
        return $this->hasMany(MobileDevice::class);
    }

    public function activationCodes(): HasMany
    {
        return $this->hasMany(MobileActivationCode::class);
    }

    public function activeDevices(): HasMany
    {
        return $this->devices()->where('status', 'active');
    }

    public function isActive(): bool
    {
        return $this->mobile_status === 'active';
    }

    public function effectiveOfflineLeaseHours(): int
    {
        return $this->offline_lease_hours ?? (int) AppConfig::get('offline_lease_hours', 72);
    }
}
