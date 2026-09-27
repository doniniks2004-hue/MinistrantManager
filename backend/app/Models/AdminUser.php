<?php

namespace App\Models;

use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;
use Illuminate\Database\Eloquent\Relations\HasMany;

class AdminUser extends Authenticatable
{
    use Notifiable;

    public const ROLE_SUPER_ADMIN = 'SUPER_ADMIN';
    public const ROLE_ADMIN = 'ADMIN';

    protected $fillable = ['name', 'email', 'password', 'totp_secret', 'totp_enabled', 'role', 'is_active'];

    protected $hidden = ['password', 'remember_token', 'totp_secret'];

    protected $casts = [
        'totp_enabled' => 'boolean',
        // Iteration 1.1 point 9 fix: $hidden only keeps totp_secret out of
        // JSON/array serialization — it does NOT encrypt the column at
        // rest. A raw DB dump/leak previously exposed every admin's TOTP
        // seed in plaintext. Laravel's 'encrypted' cast transparently
        // encrypts on write / decrypts on read using APP_KEY, so the
        // column itself never stores plaintext.
        'totp_secret' => 'encrypted',
        'is_active' => 'boolean',
        'last_login_at' => 'datetime',
        'locked_until' => 'datetime',
    ];

    public function recoveryCodes(): HasMany
    {
        return $this->hasMany(AdminRecoveryCode::class);
    }

    public function isSuperAdmin(): bool
    {
        return $this->role === self::ROLE_SUPER_ADMIN;
    }

    /**
     * Authorization rules per spec decision #4. Kept centralized here
     * rather than scattered through controllers, so the two-role model
     * can later grow into full permission-based RBAC without touching
     * every call site.
     */
    public function canResetMfaOf(AdminUser $target): bool
    {
        if ($target->is($this)) {
            return false; // use the normal "regenerate recovery codes" flow on yourself
        }
        if ($target->isSuperAdmin() && !$this->isSuperAdmin()) {
            return false;
        }
        return $this->isSuperAdmin();
    }

    public function canChangeRoleOf(AdminUser $target, string $newRole): bool
    {
        if (!$this->isSuperAdmin()) {
            return false;
        }
        if ($target->is($this) && $newRole !== self::ROLE_SUPER_ADMIN) {
            return false; // can't demote yourself out of SUPER_ADMIN — avoids locking out the last one
        }
        return true;
    }

    public function canDeactivate(AdminUser $target): bool
    {
        if (!$this->isSuperAdmin()) {
            return false;
        }
        if ($target->is($this)) {
            return false;
        }
        if ($target->isSuperAdmin() && AdminUser::where('role', self::ROLE_SUPER_ADMIN)
                ->where('is_active', true)->count() <= 1) {
            return false; // never deactivate the last active SUPER_ADMIN
        }
        return true;
    }
}
