#!/usr/bin/env python3
"""Run only on a disposable emulator: reinstalls the test package and clears its data."""
import argparse
import json
from pathlib import Path
import subprocess
import time

PACKAGE = 'eu.ministrant.manager'
RESULT = 'app_flutter/mm_selftest/result.json'


def validate(report, mode, run):
    if not isinstance(report, dict) or report.get('done') is not True or report.get('ok') is not True:
        raise ValueError('self-test did not finish successfully')
    if report.get('mode') != mode or report.get('run') != run:
        raise ValueError('stale result or unexpected run mode')
    checks = report.get('checks', [])
    if any(c.get('status') == 'fail' for c in checks):
        raise ValueError('self-test contains a failed check')
    required = ['cold.opens_saved_page_from_disk'] if mode == 'cold' else [
        'crypto.platform_verified', 'crypto.openssl_vector_dart_opens',
        'crypto.interop_dart_and_platform', 'store.encrypted_roundtrip',
        'server.loopback_http', 'keychain.secure_storage', 'webview.loads_loopback_http',
        'webview.csp_blocks_requests', 'webview.recovers_after_listener_loss',
    ]
    statuses = {c.get('name'): c.get('status') for c in checks}
    if any(statuses.get(name) != 'pass' for name in required):
        raise ValueError('required native checks missing or not passing: ' + repr(statuses))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', default='emulator-5554')
    parser.add_argument('--selftest-apk', required=True)
    parser.add_argument('--production-apk', required=True)
    parser.add_argument('--out', default='android-runtime-results')
    parser.add_argument('--expected-page-size', type=int, choices=(4096, 16384))
    args = parser.parse_args()
    if not args.serial.startswith('emulator-'):
        parser.error('this destructive fresh-install test only accepts an emulator serial')
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    def adb(*command, check=True):
        return subprocess.run(['adb', '-s', args.serial, *command], capture_output=True,
                              text=True, timeout=60, check=check)

    def wait_json(path, final=lambda value: value.get('done') is True):
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            result = adb('shell', 'run-as', PACKAGE, 'cat', path, check=False)
            try:
                value = json.loads(result.stdout)
                if isinstance(value, dict) and final(value):
                    return value
            except (ValueError, TypeError):
                pass
            time.sleep(0.5)
        raise TimeoutError('no completed result in ' + path)

    def launch():
        adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity')

    try:
        page_size = int(adb('shell', 'getconf', 'PAGE_SIZE').stdout.strip())
        (out / 'environment.json').write_text(json.dumps({'page_size': page_size}))
        if args.expected_page_size is not None and page_size != args.expected_page_size:
            raise ValueError(f'expected {args.expected_page_size}-byte pages, emulator has {page_size}')
        adb('uninstall', PACKAGE, check=False)
        adb('install', args.selftest_apk)
        for run in range(1, 7):
            adb('shell', 'am', 'force-stop', PACKAGE)
            adb('shell', 'run-as', PACKAGE, 'rm', '-f', RESULT)
            start = time.monotonic()
            launch()
            report = wait_json(RESULT)
            report['host_launch_to_result_ms'] = round((time.monotonic() - start) * 1000)
            name = 'full' if run == 1 else 'cold_' + str(run - 1)
            (out / (name + '.json')).write_text(json.dumps(report, indent=2))
            validate(report, 'full' if run == 1 else 'cold', run)
        adb('uninstall', PACKAGE)
        adb('install', args.production_apk)
        launch()
        marker = wait_json('app_flutter/mm_ui_marker.json',
                           lambda value: value.get('screen') in ('activation_screen', 'startup_error'))
        (out / 'ui_marker.json').write_text(json.dumps(marker, indent=2))
        if marker.get('screen') != 'activation_screen':
            raise ValueError('production app failed to reach activation: ' + repr(marker))
        (out / 'verdict.txt').write_text('PASS: native self-test, five cold page opens, fresh activation.\n'
                                       'No live parish login or device performance acceptance.\n')
    finally:
        logs = adb('logcat', '-d', '-t', '3000', check=False)
        (out / 'logcat.txt').write_text(logs.stdout)


if __name__ == '__main__':
    main()
