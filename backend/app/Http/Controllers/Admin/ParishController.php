<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\MobileActivationCode;
use App\Models\Parish;
use App\Services\AuditLogger;
use App\Services\TokenService;
use Illuminate\Http\Request;
use BaconQrCode\Renderer\ImageRenderer;
use BaconQrCode\Renderer\Image\SvgImageBackEnd;
use BaconQrCode\Renderer\RendererStyle\RendererStyle;
use BaconQrCode\Writer;

class ParishController extends Controller
{
    public function index(Request $request)
    {
        $query = Parish::withCount(['activeDevices as devices_count'])
            ->orderBy('name');

        if ($search = $request->get('q')) {
            $query->where(function ($q) use ($search) {
                $q->where('name', 'like', "%$search%")
                    ->orWhere('slug', 'like', "%$search%")
                    ->orWhere('subdomain', 'like', "%$search%");
            });
        }

        if ($status = $request->get('status')) {
            $query->where('mobile_status', $status);
        }

        $parishes = $query->paginate(25)->withQueryString();

        return view('admin.parishes.index', compact('parishes'));
    }

    /**
     * Was missing entirely before review: with zero parishes seeded, the
     * only way to get one into app.ministrant.eu was manual DB/tinker
     * work. This is a simple manual-entry form; a bulk "import from
     * existing Ministrant Manager" sync (by slug/subdomain) is a
     * reasonable follow-up once there's an agreed single source of truth
     * for the parish list, but isn't implemented here.
     */
    public function create()
    {
        return view('admin.parishes.create');
    }

    public function store(Request $request)
    {
        $data = $request->validate([
            'name' => ['required', 'string', 'max:255'],
            'slug' => ['required', 'string', 'max:100', 'alpha_dash', 'unique:parishes,slug'],
            'subdomain' => ['required', 'string', 'max:255'],
        ]);

        $subdomain = $this->normalizeParishHost($data['subdomain']);

        $request->validate([
            'subdomain' => [
                function (string $attribute, mixed $value, \Closure $fail) use ($subdomain) {
                    if (!preg_match('/^(?:[a-z0-9-]+\.)+ministrant\.eu$/', $subdomain)) {
                        $fail('Podaj host parafii bez protokołu, np. szarlej.ministrant.eu.');
                    }
                    if (Parish::where('subdomain', $subdomain)->exists()) {
                        $fail('Taka subdomena już istnieje.');
                    }
                },
            ],
        ]);

        $parish = Parish::create([
            'name' => $data['name'],
            'slug' => $data['slug'],
            'subdomain' => $subdomain,
            'server_url' => "https://{$subdomain}",
            'mobile_status' => 'active',
            'mobile_internal_api_secret' => bin2hex(random_bytes(32)),
        ]);

        AuditLogger::log('parish.created', 'Parish', $parish->id, ['slug' => $parish->slug]);

        return redirect()->route('admin.parishes.show', $parish)->with('status', 'Parafia została dodana.');
    }

    private function normalizeParishHost(string $value): string
    {
        $value = trim(strtolower($value));
        $value = preg_replace('#^https?://#', '', $value) ?? $value;
        $value = preg_replace('#^www\.#', '', $value) ?? $value;
        return rtrim($value, '/');
    }

    public function show(Parish $parish)
    {
        $parish->load(['devices' => fn ($q) => $q->orderByDesc('last_seen_at')]);
        $codes = $parish->activationCodes()->orderByDesc('created_at')->limit(20)->get();

        return view('admin.parishes.show', compact('parish', 'codes'));
    }

    /**
     * Iteration 1.1 point 4 fix: Parish::effectiveOfflineLeaseHours()
     * already correctly falls back to the global default, and
     * DeviceController now actually calls it — but there was NO way for
     * an admin to set the per-parish override in the first place. Passing
     * an empty value clears the override back to `null` (inherit global).
     */
    public function updateOfflineLease(Request $request, Parish $parish)
    {
        $data = $request->validate([
            'offline_lease_hours' => ['nullable', 'integer', 'min:1', 'max:720'],
        ]);

        $parish->update(['offline_lease_hours' => $data['offline_lease_hours'] ?? null]);

        AuditLogger::log('parish.offline_lease_updated', 'Parish', $parish->id, [
            'offline_lease_hours' => $data['offline_lease_hours'] ?? 'inherit_global',
        ]);

        return back()->with('status', $data['offline_lease_hours']
            ? "Offline lease dla {$parish->name} ustawiony na {$data['offline_lease_hours']}h."
            : "Offline lease dla {$parish->name} dziedziczy teraz wartość globalną.");
    }

    public function rotateMobileSecret(Request $request, Parish $parish)
    {
        $secret = bin2hex(random_bytes(32));
        $parish->update(['mobile_internal_api_secret' => $secret]);

        AuditLogger::log('parish.mobile_secret_rotated', 'Parish', $parish->id, [
            'parish' => $parish->slug,
        ]);

        return back()->with('generated_mobile_secret', $secret)
            ->with('status', 'Wygenerowano nowy sekret MobileAPI. Zapisz go teraz — będzie pokazany tylko raz.');
    }

    public function generateCode(Request $request, Parish $parish)
    {
        $data = $request->validate([
            'expiry' => ['required', 'in:1_hour,24_hours,7_days,none'],
            'max_uses' => ['required', 'in:1,5,10,unlimited'],
        ]);

        $expiresAt = match ($data['expiry']) {
            '1_hour' => now()->addHour(),
            '24_hours' => now()->addDay(),
            '7_days' => now()->addDays(7),
            'none' => null,
        };

        $maxUses = $data['max_uses'] === 'unlimited' ? null : (int) $data['max_uses'];

        $rawToken = TokenService::generateActivationToken();
        $displayCode = TokenService::generateDisplayCode();

        // Practically unique on first try; loop guards the astronomically rare collision.
        while (MobileActivationCode::where('display_code', $displayCode)->exists()) {
            $displayCode = TokenService::generateDisplayCode();
        }

        $code = MobileActivationCode::create([
            'parish_id' => $parish->id,
            'token_hash' => TokenService::hash($rawToken),
            'display_code' => $displayCode,
            'expires_at' => $expiresAt,
            'max_uses' => $maxUses,
            'status' => 'active',
            'created_by' => auth('admin')->id(),
        ]);

        AuditLogger::log('code.generated', 'MobileActivationCode', $code->id, [
            'parish' => $parish->slug,
            'expiry' => $data['expiry'],
            'max_uses' => $data['max_uses'],
        ]);

        // QR encodes app.ministrant.eu/activate/{raw token} — never the parish password.
        $qrUrl = url("/activate/{$rawToken}");

        // Was flagged in review: only the raw URL was shown before, no
        // actual scannable image. Rendered server-side as inline SVG so no
        // extra JS/client library is needed in the panel.
        $renderer = new ImageRenderer(new RendererStyle(240), new SvgImageBackEnd());
        $qrSvg = (new Writer($renderer))->writeString($qrUrl);

        return redirect()->route('admin.parishes.show', $parish)
            ->with('generated_code', [
                'display_code' => $code->display_code,
                'qr_url' => $qrUrl,
                'qr_svg' => $qrSvg,
            ]);
    }

    public function revokeCode(Parish $parish, MobileActivationCode $code)
    {
        abort_unless($code->parish_id === $parish->id, 404);

        $code->update(['status' => 'revoked', 'revoked_at' => now()]);

        AuditLogger::log('code.revoked', 'MobileActivationCode', $code->id, ['parish' => $parish->slug]);

        return back()->with('status', 'Kod został unieważniony.');
    }

    public function disable(Parish $parish)
    {
        $parish->update([
            'mobile_status' => 'disabled',
            'disabled_at' => now(),
            'disabled_by' => auth('admin')->id(),
        ]);

        AuditLogger::log('parish.disabled', 'Parish', $parish->id, ['parish' => $parish->slug]);

        return back()->with('status', "Parafia {$parish->name} została dezaktywowana.");
    }

    public function enable(Parish $parish)
    {
        $parish->update([
            'mobile_status' => 'active',
            'disabled_at' => null,
            'disabled_by' => null,
        ]);

        AuditLogger::log('parish.enabled', 'Parish', $parish->id, ['parish' => $parish->slug]);

        return back()->with('status', "Parafia {$parish->name} została ponownie aktywowana.");
    }
}
