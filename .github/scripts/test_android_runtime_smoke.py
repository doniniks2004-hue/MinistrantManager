import unittest
from android_runtime_smoke import validate


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


if __name__ == '__main__':
    unittest.main()
