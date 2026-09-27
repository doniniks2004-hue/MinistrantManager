<?php

namespace App\Services;

use App\Models\AuditLog;
use Illuminate\Support\Facades\Request;

class AuditLogger
{
    /**
     * Record an administrative action.
     *
     * @param string      $action      e.g. "device.revoked", "parish.disabled", "code.generated"
     * @param string|null $subjectType e.g. "MobileDevice"
     * @param int|null    $subjectId
     * @param array       $meta        extra context, e.g. ["device_model" => "Samsung SM-A556B"]
     */
    public static function log(string $action, ?string $subjectType = null, ?int $subjectId = null, array $meta = []): void
    {
        $admin = auth('admin')->user();

        AuditLog::create([
            'admin_user_id' => $admin?->id,
            'admin_email' => $admin?->email,
            'action' => $action,
            'subject_type' => $subjectType,
            'subject_id' => $subjectId,
            'meta' => $meta,
            'ip_address' => Request::ip(),
            'created_at' => now(),
        ]);
    }
}
