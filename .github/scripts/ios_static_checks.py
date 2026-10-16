#!/usr/bin/env python3
"""Static checks of the iOS project and, when given, of a BUILT app bundle.

Nothing here needs a Mac, Xcode or an Apple account: it reads files. It exists so
that the things that fail silently or only at upload time (a missing camera
description, a loosened App Transport Security, an entitlements file the project
does not use, a bundle id or version that is not what was meant, an iPad that
App Store Connect will refuse) are caught by CI on every change.

Verdicts: PASS, FAIL (exits 1), WARN (a decision or a thing only a real signed
build can settle; never hidden, never a pass). `--release-gate` turns the
iPad rule from a warning into a failure, for the workflow that builds the IPA.

Usage:
  ios_static_checks.py --root <repo> [--built <Runner.app>] [--release-gate] [--json out.json]
"""
import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

EXPECTED_BUNDLE_ID = "eu.ministrant.manager"
EXPECTED_ASSOCIATED_DOMAIN = "applinks:app.ministrant.eu"
MIN_IOS = (15, 0)


class Report:
    def __init__(self):
        self.items = []

    def add(self, status, name, detail):
        self.items.append({"status": status, "name": name, "detail": detail})

    def passed(self, name, detail): self.add("PASS", name, detail)
    def warn(self, name, detail): self.add("WARN", name, detail)
    def fail(self, name, detail): self.add("FAIL", name, detail)

    @property
    def failed(self):
        return [i for i in self.items if i["status"] == "FAIL"]


def load_plist(path: Path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def is_placeholder(value) -> bool:
    return isinstance(value, str) and value.startswith("$(")


def check_info_plist(r: Report, plist: dict, where: str, built: bool):
    camera = plist.get("NSCameraUsageDescription")
    if isinstance(camera, str) and len(camera.strip()) >= 15:
        r.passed(f"{where}: camera permission text", f"present ({len(camera.strip())} characters): QR activation can ask for the camera")
    else:
        r.fail(f"{where}: camera permission text", "NSCameraUsageDescription is missing or too short: iOS terminates the app the moment the QR scanner opens the camera, and App Store review rejects it")

    ats = plist.get("NSAppTransportSecurity")
    if not isinstance(ats, dict):
        r.fail(f"{where}: App Transport Security", "no NSAppTransportSecurity: cleartext http to 127.0.0.1 (the saved page) would be refused by WKWebView")
    else:
        problems = []
        if ats.get("NSAllowsArbitraryLoads") is True:
            problems.append("NSAllowsArbitraryLoads is true (all cleartext allowed)")
        if ats.get("NSAllowsArbitraryLoadsInWebContent") is True:
            problems.append("NSAllowsArbitraryLoadsInWebContent is true")
        if ats.get("NSAllowsLocalNetworking") is not True:
            problems.append("NSAllowsLocalNetworking is not true")
        exception = ats.get("NSExceptionDomains", {}).get("127.0.0.1", {})
        if exception.get("NSExceptionAllowsInsecureHTTPLoads") is not True:
            problems.append("no cleartext exception for 127.0.0.1")
        if problems:
            r.fail(f"{where}: App Transport Security", "; ".join(problems))
        else:
            r.passed(f"{where}: App Transport Security", "cleartext only for loopback (NSAllowsLocalNetworking + 127.0.0.1); no general cleartext")

    if "ITSAppUsesNonExemptEncryption" not in plist:
        r.warn(f"{where}: export compliance", "ITSAppUsesNonExemptEncryption is not set, so App Store Connect asks about encryption on every upload. The app uses HTTPS and its own AES-GCM; whether that is exempt is the owner's declaration (see IOS-RELEASE-CHECKLIST.md)")
    else:
        r.passed(f"{where}: export compliance", f"ITSAppUsesNonExemptEncryption = {plist['ITSAppUsesNonExemptEncryption']}")

    families = plist.get("UIDeviceFamily")
    portrait_only = set(plist.get("UISupportedInterfaceOrientations", [])) <= {"UIInterfaceOrientationPortrait"}
    return portrait_only


def check_built_plist(r: Report, plist: dict, pubspec_version: str):
    bundle_id = plist.get("CFBundleIdentifier")
    if bundle_id == EXPECTED_BUNDLE_ID:
        r.passed("built app: bundle id", bundle_id)
    else:
        r.fail("built app: bundle id", f"{bundle_id!r}, expected {EXPECTED_BUNDLE_ID!r}")

    name, _, number = pubspec_version.partition("+")
    short, build = plist.get("CFBundleShortVersionString"), plist.get("CFBundleVersion")
    if short == name and (not number or build == number):
        r.passed("built app: version", f"{short} ({build}) matches pubspec.yaml {pubspec_version}")
    else:
        r.fail("built app: version", f"built {short} ({build}) does not match pubspec.yaml {pubspec_version}")

    minimum = plist.get("MinimumOSVersion", "0")
    try:
        parsed = tuple(int(x) for x in minimum.split(".")[:2])
    except ValueError:
        parsed = (0, 0)
    if parsed >= MIN_IOS:
        r.passed("built app: minimum iOS", minimum)
    else:
        r.fail("built app: minimum iOS", f"{minimum}, expected at least {'.'.join(map(str, MIN_IOS))}")


def read_pubspec_version(root: Path) -> str:
    text = (root / "mobile-ios" / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([^\s#]+)", text, re.M)
    return match.group(1) if match else ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--built", help="path to a built Runner.app")
    ap.add_argument("--release-gate", action="store_true")
    ap.add_argument("--json")
    args = ap.parse_args()

    root = Path(args.root)
    ios = root / "mobile-ios" / "ios"
    r = Report()

    # ---- the project's own files ------------------------------------------------
    source_plist = load_plist(ios / "Runner" / "Info.plist")
    portrait_only = check_info_plist(r, source_plist, "Info.plist (source)", built=False)

    pbx = (ios / "Runner.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
    bundle_ids = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", pbx)
    runner_ids = [b for b in bundle_ids if not b.endswith("RunnerTests")]
    if runner_ids and all(b == EXPECTED_BUNDLE_ID for b in runner_ids):
        r.passed("project: bundle id", f"{EXPECTED_BUNDLE_ID} in all {len(runner_ids)} Runner configurations")
    else:
        r.fail("project: bundle id", f"Runner configurations: {runner_ids}")

    uses = len(re.findall(r"CODE_SIGN_ENTITLEMENTS = Runner/Runner\.entitlements;", pbx))
    if uses == 3:
        r.passed("project: entitlements are applied", "CODE_SIGN_ENTITLEMENTS set in Debug, Release and Profile")
    else:
        r.fail("project: entitlements are applied", f"CODE_SIGN_ENTITLEMENTS found {uses} times, expected 3: the file would be ignored when signing")

    entitlements = (ios / "Runner" / "Runner.entitlements").read_text(encoding="utf-8")
    if EXPECTED_ASSOCIATED_DOMAIN in entitlements:
        r.passed("project: Universal Links domain", f"{EXPECTED_ASSOCIATED_DOMAIN} declared")
    else:
        r.fail("project: Universal Links domain", f"{EXPECTED_ASSOCIATED_DOMAIN} not declared in Runner.entitlements")

    privacy_path = ios / "Runner" / "PrivacyInfo.xcprivacy"
    if privacy_path.exists():
        privacy = load_plist(privacy_path)
        if privacy.get("NSPrivacyTracking") is False and "PrivacyInfo.xcprivacy in Resources" in pbx:
            r.passed("project: privacy manifest", "present, bundled, declares no tracking")
        else:
            r.fail("project: privacy manifest", "present but not bundled in Resources, or declares tracking")
    else:
        r.fail("project: privacy manifest", "PrivacyInfo.xcprivacy is missing")

    families = re.findall(r'TARGETED_DEVICE_FAMILY = "?([\d,]+)"?;', pbx)
    ipad = any("2" in f.split(",") for f in families)
    has_ipad_orientations = "UISupportedInterfaceOrientations~ipad" in source_plist
    full_screen = source_plist.get("UIRequiresFullScreen") is True
    if ipad and portrait_only and not has_ipad_orientations and not full_screen:
        message = ("the app declares iPad support (TARGETED_DEVICE_FAMILY includes 2) but supports only Portrait, with no iPad orientations "
                   "and no UIRequiresFullScreen. App Store Connect refuses such an upload. Decide: iPhone only (TARGETED_DEVICE_FAMILY = 1) "
                   "or iPad with all orientations, which needs its layout tested on an iPad")
        (r.fail if args.release_gate else r.warn)("project: iPad declaration", message)
    else:
        r.passed("project: iPad declaration", "consistent (iPhone only, or iPad with orientations / full screen)")

    # ---- the backend's Universal Links association file --------------------------
    aasa_path = root / "backend" / "public" / ".well-known" / "apple-app-site-association"
    if aasa_path.exists():
        try:
            aasa = json.loads(aasa_path.read_text(encoding="utf-8"))
            details = aasa["applinks"]["details"][0]
            if "/activate/*" not in details.get("paths", []):
                r.fail("backend: association file", "no /activate/* path")
            elif "__APPLE_TEAM_ID__" in details.get("appID", ""):
                r.warn("backend: association file", "valid JSON with /activate/*, but the Team ID is still a placeholder: Universal Links cannot work until the Apple Developer Team ID is known and the file is deployed")
            else:
                r.passed("backend: association file", f"valid, appID {details.get('appID')}")
        except Exception as e:  # noqa: BLE001
            r.fail("backend: association file", f"not valid: {e}")
    else:
        r.warn("backend: association file", "not found in this checkout")

    # ---- a built bundle ------------------------------------------------------------
    if args.built:
        app = Path(args.built)
        built_plist_path = app / "Info.plist"
        if not built_plist_path.exists():
            r.fail("built app", f"{built_plist_path} not found")
        else:
            built = load_plist(built_plist_path)
            check_info_plist(r, built, "Info.plist (built app)", built=True)
            check_built_plist(r, built, read_pubspec_version(root))
            if (app / "PrivacyInfo.xcprivacy").exists():
                r.passed("built app: privacy manifest", "is inside the app bundle")
            else:
                r.fail("built app: privacy manifest", "PrivacyInfo.xcprivacy is not in the built bundle")
            frameworks = sorted(p.name for p in (app / "Frameworks").glob("*.framework")) if (app / "Frameworks").exists() else []
            r.passed("built app: frameworks", f"{len(frameworks)} embedded ({', '.join(frameworks[:6])}{'...' if len(frameworks) > 6 else ''})")

    # ---- output --------------------------------------------------------------------
    marks = {"PASS": "PASS", "WARN": "WARN", "FAIL": "FAIL"}
    for item in r.items:
        print(f"[{marks[item['status']]}] {item['name']}: {item['detail']}")
    summary = {s: sum(1 for i in r.items if i["status"] == s) for s in ("PASS", "WARN", "FAIL")}
    print(f"\n{summary['PASS']} passed, {summary['WARN']} warnings, {summary['FAIL']} failed")
    if args.json:
        Path(args.json).write_text(json.dumps({"summary": summary, "items": r.items}, indent=2), encoding="utf-8")
    return 1 if r.failed else 0


if __name__ == "__main__":
    sys.exit(main())
