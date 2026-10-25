import unittest
from types import SimpleNamespace
from unittest.mock import patch
from android_runtime_smoke import validate, wait_for_emulator


class VerdictTests(unittest.TestCase):
    def report(self):
        return dict(done=True, ok=True, mode='cold', run=2,
                    checks=[dict(name='cold.opens_saved_page_from_disk', status='pass')])

    def test_accepts_complete_expected_run(self):
        validate(self.report(), 'cold', 2)

    def test_rejects_stale_file(self):
        with self.assertRaises(ValueError):
            validate(self.report(), 'cold', 3)

    def test_rejects_incomplete_run(self):
        report = self.report()
        report['done'] = False
        with self.assertRaises(ValueError):
            validate(report, 'cold', 2)

    def test_rejects_missing_native_check(self):
        report = self.report()
        report.update(mode='full', run=1)
        with self.assertRaises(ValueError):
            validate(report, 'full', 1)

    def test_rejects_failed_check_even_if_ok_claimed(self):
        report = self.report()
        report['checks'].append(dict(name='extra', status='fail'))
        with self.assertRaises(ValueError):
            validate(report, 'cold', 2)


class EmulatorReadinessTests(unittest.TestCase):
    def run_readiness(self, states, timeout=10):
        clock = [0]
        probes = []

        def adb(*command, check=True):
            if command == ('get-state',):
                ready = states[min(len(probes), len(states) - 1)]
                probes.append(ready)
                return SimpleNamespace(returncode=0 if ready else 1,
                                       stdout='device' if ready else 'offline')
            if command[-1] == 'sys.boot_completed':
                return SimpleNamespace(returncode=0, stdout='1\n')
            return SimpleNamespace(returncode=0, stdout='package:/system/framework/framework-res.apk\n')

        def sleep(seconds):
            clock[0] += seconds

        with patch('android_runtime_smoke.time.monotonic', side_effect=lambda: clock[0]), \
             patch('android_runtime_smoke.time.sleep', side_effect=sleep):
            wait_for_emulator(adb, timeout=timeout)
        return probes

    def test_temporary_adb_disconnect_resets_readiness(self):
        self.assertEqual(self.run_readiness([True, False, True, True, True]),
                         [True, False, True, True, True])

    def test_offline_device_never_starts_app_tests(self):
        with self.assertRaisesRegex(TimeoutError, 'before installation'):
            self.run_readiness([False], timeout=3)


if __name__ == '__main__':
    unittest.main()
