<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Cache;

class AppConfig extends Model
{
    // Review round: migration creates 'app_config' (singular) — without
    // this, Eloquent's default pluralization would look for 'app_configs'
    // instead, and every AppConfig::get()/set() call (client-config,
    // maintenance mode, min versions, store URLs, global offline lease,
    // SettingsController) would fail against a table that doesn't exist.
    protected $table = 'app_config';
    protected $primaryKey = 'key';
    public $incrementing = false;
    protected $keyType = 'string';
    protected $fillable = ['key', 'value'];

    public static function get(string $key, $default = null)
    {
        return Cache::remember("app_config.$key", 60, function () use ($key, $default) {
            $row = static::find($key);
            return $row ? $row->value : $default;
        });
    }

    public static function set(string $key, $value): void
    {
        static::updateOrCreate(['key' => $key], ['value' => $value]);
        Cache::forget("app_config.$key");
    }
}
