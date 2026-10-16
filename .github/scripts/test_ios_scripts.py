"""Tests of the two CI helper scripts, on real files and on synthetic results."""
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
import ios_sim_report  # noqa: E402


def run_checks(root, *extra):
    return subprocess.run([sys.executable, str(HERE / "ios_static_checks.py"), "--root", str(root), *extra], capture_output=True, text=True)


class StaticChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        # a copy of just what the checks read
        for rel in ["mobile-ios/ios/Runner", "mobile-ios/ios/Runner.xcodeproj", "backend/public/.well-known"]:
            shutil.copytree(ROOT / rel, self.tmp / rel)
        shutil.copy(ROOT / "mobile-ios/pubspec.yaml", self.tmp / "mobile-ios/pubspec.yaml")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def plist_path(self):
        return self.tmp / "mobile-ios/ios/Runner/Info.plist"

    def edit_plist(self, fn):
        p = self.plist_path()
        d = plistlib.loads(p.read_bytes())
        fn(d)
        p.write_bytes(plistlib.dumps(d))

    def test_the_real_project_has_no_failures(self):
        r = run_checks(ROOT)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_missing_camera_text_fails(self):
        self.edit_plist(lambda d: d.pop("NSCameraUsageDescription"))
        r = run_checks(self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertIn("camera permission text", r.stdout)

    def test_loosened_app_transport_security_fails(self):
        self.edit_plist(lambda d: d["NSAppTransportSecurity"].update({"NSAllowsArbitraryLoads": True}))
        r = run_checks(self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertIn("NSAllowsArbitraryLoads is true", r.stdout)

    def test_missing_loopback_exception_fails(self):
        self.edit_plist(lambda d: d["NSAppTransportSecurity"].pop("NSExceptionDomains"))
        self.assertEqual(run_checks(self.tmp).returncode, 1)

    def test_entitlements_not_applied_to_the_project_fails(self):
        pbx = self.tmp / "mobile-ios/ios/Runner.xcodeproj/project.pbxproj"
        pbx.write_text(pbx.read_text().replace("CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;", ""))
        r = run_checks(self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertIn("entitlements are applied", r.stdout)

    def test_wrong_bundle_id_fails(self):
        pbx = self.tmp / "mobile-ios/ios/Runner.xcodeproj/project.pbxproj"
        pbx.write_text(pbx.read_text().replace("PRODUCT_BUNDLE_IDENTIFIER = eu.ministrant.manager;", "PRODUCT_BUNDLE_IDENTIFIER = com.example.app;", 1))
        self.assertEqual(run_checks(self.tmp).returncode, 1)

    def pbx_path(self):
        return self.tmp / "mobile-ios/ios/Runner.xcodeproj/project.pbxproj"

    def test_the_project_is_iphone_only_and_keeps_portrait(self):
        r = run_checks(self.tmp)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("[PASS] project: device family: iPhone only", r.stdout)
        self.assertIn("[PASS] project: iPhone orientations: Portrait", r.stdout)
        self.assertNotIn("iPad declaration", r.stdout)

    def test_the_iphone_orientations_are_exactly_what_they_were(self):
        # The iPad decision must not have touched what the iPhone supports.
        d = plistlib.loads(self.plist_path().read_bytes())
        self.assertEqual(d["UISupportedInterfaceOrientations"], ["UIInterfaceOrientationPortrait"])
        self.assertNotIn("UISupportedInterfaceOrientations~ipad", d)
        self.assertNotIn("UIDeviceFamily", d)

    def test_an_ipad_declaration_coming_back_fails_in_every_run(self):
        pbx = self.pbx_path()
        pbx.write_text(pbx.read_text().replace("TARGETED_DEVICE_FAMILY = 1;", 'TARGETED_DEVICE_FAMILY = "1,2";'))
        for extra in ([], ["--release-gate"]):
            r = run_checks(self.tmp, *extra)
            self.assertEqual(r.returncode, 1, r.stdout)
            self.assertIn("[FAIL] project: device family", r.stdout)

    def test_one_configuration_left_on_ipad_fails(self):
        pbx = self.pbx_path()
        pbx.write_text(pbx.read_text().replace("TARGETED_DEVICE_FAMILY = 1;", 'TARGETED_DEVICE_FAMILY = "1,2";', 1))
        self.assertEqual(run_checks(self.tmp).returncode, 1)

    def test_a_missing_configuration_fails(self):
        pbx = self.pbx_path()
        pbx.write_text(pbx.read_text().replace("TARGETED_DEVICE_FAMILY = 1;", "", 1))
        self.assertEqual(run_checks(self.tmp).returncode, 1)

    def test_ipad_in_info_plist_fails(self):
        self.edit_plist(lambda d: d.update({"UIDeviceFamily": [1, 2]}))
        self.assertEqual(run_checks(self.tmp).returncode, 1)

    def test_losing_portrait_for_the_iphone_fails(self):
        self.edit_plist(lambda d: d.update({"UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeLeft"]}))
        r = run_checks(self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertIn("iPhone orientations", r.stdout)

    def test_removing_the_orientation_key_fails(self):
        self.edit_plist(lambda d: d.pop("UISupportedInterfaceOrientations"))
        self.assertEqual(run_checks(self.tmp).returncode, 1)

    def test_adding_landscape_to_the_iphone_is_allowed_if_portrait_stays(self):
        self.edit_plist(lambda d: d.update({"UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft"]}))
        self.assertEqual(run_checks(self.tmp).returncode, 0)

    def test_the_release_gate_flag_is_still_accepted(self):
        self.assertEqual(run_checks(self.tmp, "--release-gate").returncode, 0)

    def built_app(self, **overrides):
        app = self.tmp / "Runner.app"
        app.mkdir()
        info = plistlib.loads(self.plist_path().read_bytes())
        info.update({"CFBundleIdentifier": "eu.ministrant.manager", "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "2", "MinimumOSVersion": "15.0"})
        info.update(overrides)
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        (app / "PrivacyInfo.xcprivacy").write_bytes(b"x")
        return app

    def test_a_correct_built_bundle_passes(self):
        r = run_checks(self.tmp, "--built", str(self.built_app()))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("built app: bundle id", r.stdout)

    def test_built_bundle_with_the_wrong_id_version_or_minimum_fails(self):
        for override in [{"CFBundleIdentifier": "x.y"}, {"CFBundleShortVersionString": "9.9.9"}, {"MinimumOSVersion": "12.0"}]:
            app = self.built_app(**override)
            r = run_checks(self.tmp, "--built", str(app))
            self.assertEqual(r.returncode, 1, str(override))
            shutil.rmtree(app)

    def test_built_bundle_without_the_privacy_manifest_fails(self):
        app = self.built_app()
        (app / "PrivacyInfo.xcprivacy").unlink()
        self.assertEqual(run_checks(self.tmp, "--built", str(app)).returncode, 1)


class SimulatorReport(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def write(self, name, data):
        (self.tmp / name).write_text(json.dumps(data))

    def check(self, name, status="pass", detail="ok", ms=5):
        return {"name": name, "status": status, "ms": ms, "detail": detail}

    def good(self):
        self.write("ui_marker.json", {"screen": "activation_screen", "marks": {"main": 0}})
        self.write("full.json", {"done": True, "ok": True, "platform": "ios", "passed": 2, "failed": 0, "info": 1,
                                  "checks": [self.check("crypto.platform_verified"), self.check("webview.loads_loopback_http"), self.check("keychain", "info")]})
        for n, ms in enumerate([700, 650, 900, 800, 750], 1):
            self.write(f"cold_{n}.json", {"done": True, "ok": True, "marks": {"painted_ms": ms}, "checks": []})
        self.write("walltimes.json", {f"cold_{n}": 2500 for n in range(1, 6)})
        self.write("static.json", {"summary": {"PASS": 3, "WARN": 1, "FAIL": 0}, "items": [{"status": "WARN", "name": "iPad", "detail": "x"}]})

    def build(self):
        return ios_sim_report.build(self.tmp)

    def test_all_good_is_a_pass_and_says_what_it_does_not_establish(self):
        self.good()
        text, problems = self.build()
        self.assertEqual(problems, [])
        self.assertIn("**PASS**", text)
        self.assertIn("real iPhone", text)
        self.assertIn("median 750 ms", text)

    def test_timing_over_the_target_is_not_a_failure_but_is_shown(self):
        self.good()
        for n in range(1, 6):
            self.write(f"cold_{n}.json", {"done": True, "ok": True, "marks": {"painted_ms": 3000}, "checks": []})
        text, problems = self.build()
        self.assertEqual(problems, [])
        self.assertIn("0 of 5 within 2000 ms", text)
        self.assertIn("not a verdict", text)

    def test_the_app_never_reaching_its_first_screen_fails(self):
        self.good()
        (self.tmp / "ui_marker.json").unlink()
        self.assertTrue(any("activation screen" in p for p in self.build()[1]))

    def test_another_first_screen_fails(self):
        self.good()
        self.write("ui_marker.json", {"screen": "home", "marks": {}})
        self.assertTrue(self.build()[1])

    def test_a_failed_check_fails_and_is_named(self):
        self.good()
        full = json.loads((self.tmp / "full.json").read_text())
        full["checks"].append(self.check("crypto.interop_dart_and_platform", "fail", "Dart did not open what the platform sealed"))
        full["failed"] = 1
        self.write("full.json", full)
        problems = self.build()[1]
        self.assertTrue(any("crypto.interop_dart_and_platform" in p and "Dart did not open" in p for p in problems))

    def test_a_run_cut_short_is_not_a_pass(self):
        self.good()
        self.write("cold_3.json", {"done": False, "ok": False, "marks": {}, "checks": []})
        self.assertTrue(self.build()[1])

    def test_a_missing_or_unreadable_result_fails(self):
        self.good()
        (self.tmp / "cold_2.json").write_text("{not json")
        (self.tmp / "full.json").unlink()
        problems = self.build()[1]
        self.assertTrue(any("cold_2" in p for p in problems))
        self.assertTrue(any("full self-test" in p for p in problems))

    def test_no_cold_runs_fails(self):
        self.good()
        for n in range(1, 6):
            (self.tmp / f"cold_{n}.json").unlink()
        self.assertTrue(any("no cold runs" in p for p in self.build()[1]))

    def test_informational_checks_never_fail_the_run(self):
        self.good()
        self.assertEqual(self.build()[1], [])

    def test_a_failed_static_check_fails_the_report(self):
        self.good()
        self.write("static.json", {"summary": {"PASS": 1, "WARN": 0, "FAIL": 1}, "items": [{"status": "FAIL", "name": "ATS", "detail": "loosened"}]})
        self.assertTrue(any("ATS" in p for p in self.build()[1]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
