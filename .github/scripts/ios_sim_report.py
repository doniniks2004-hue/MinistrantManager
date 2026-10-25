#!/usr/bin/env python3
"""Turns what the iOS simulator job collected into one report and one verdict.

Reads, from --results:
  full.json          the first run of the self-test app (every check)
  cold_<n>.json      each later run: a fresh process opening the saved page from disk
  walltimes.json     {"cold_1": ms, ...}: milliseconds from the launch command to the
                     moment the result file appeared, measured by the job itself
  ui_marker.json     what the production app wrote when it reached its first screen
  static.json        the output of ios_static_checks.py

The verdict is strict about FUNCTION (a check failed, a run did not finish, the
production app never reached the activation screen) and deliberately not about
SPEED: a CI simulator on a Mac runner is not an iPhone, so the timings are
reported as measurements, with the 2-second target next to them, and never as a
pass or a fail of that target.
"""
import argparse
import json
import statistics
import sys
from pathlib import Path

TARGET_MS = 2000


KEYCHAIN_CHECK = "keychain.secure_storage"  # the self-test check that writes, reads back and deletes a Keychain item

def load(path: Path):
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return {"unreadable": True}


def md_checks(report) -> list:
    rows = ["| Check | Result | ms | Detail |", "|---|---|---:|---|"]
    icon = {"pass": "PASS", "fail": "**FAIL**", "info": "info"}
    for c in report.get("checks", []):
        detail = str(c.get("detail", "")).replace("|", "\\|").replace("\n", " ")
        rows.append(f"| `{c['name']}` | {icon.get(c['status'], c['status'])} | {c.get('ms', '')} | {detail} |")
    return rows


def build(results: Path):
    problems = []
    lines = ["# iOS simulator run", ""]

    full = load(results / "full.json")
    ui = load(results / "ui_marker.json")
    static = load(results / "static.json")
    walls = load(results / "walltimes.json") or {}
    colds = [(p.stem, load(p)) for p in sorted(results.glob("cold_*.json"), key=lambda p: int(p.stem.split("_")[1]))]

    # ---- production app reached its first screen ---------------------------------
    lines += ["## 1. The app itself, fresh install, launched on the simulator", ""]
    last = ui.get("screen") if isinstance(ui, dict) else None
    detail = ui.get("detail", "") if isinstance(ui, dict) else ""
    history = ui.get("screens") if isinstance(ui, dict) and isinstance(ui.get("screens"), list) else ([last] if last else [])
    if ui is None:
        problems.append("the production app wrote no marker at all: it drew no frame, or the reporting failed (see crashes/ and logs/)")
        lines.append("**FAIL** the app wrote no marker file at all: no frame was drawn (a crash, or it never started), or the reporting itself failed. "
                     "See `crashes/` and `logs/`.")
    elif last == "activation_screen":
        marks = ui.get("marks", {})
        lines.append(f"PASS the activation screen was reached (screens in order: {' -> '.join(history)}). "
                     f"Marks (ms since Dart `main()`): `{json.dumps(marks)}`")
    elif last == "startup_error":
        hint = ""
        if "-34018" in detail:
            hint = (" **-34018 is the Keychain refusing for want of an entitlement**: the app reads the Keychain before it draws any screen, "
                    "so a build with no signature stops here. Check `logs/build-signing.txt` and `logs/codesign-production.txt`.")
        problems.append(f"the production app stopped at its startup error screen: {detail or 'no detail'}")
        lines.append(f"**FAIL** the app ran, drew a frame (screens: {' -> '.join(history)}) and stopped at its **startup error screen**: "
                     f"`{detail or 'no detail'}`.{hint}")
    elif last == "first_frame":
        # first_frame says only that something was drawn. It does not say the app is
        # hung: it is also what the file holds while the app is still starting, while
        # the activation screen is drawn but its report has not been written yet,
        # and when a later write failed. The report says what is known.
        problems.append("the production app reached only 'first_frame' in 120 s: neither the activation screen nor the startup error screen was reported. "
                        "Cause not established (slow start, a screen that was not reported, or a failed marker write)")
        lines.append("**FAIL (cause not established)** the marker file shows a first frame and nothing after it within 120 s. That does **not** show "
                     "the app is hung: it is equally what a slow start, a screen whose report was not written, or a failed marker write leaves behind. "
                     "Next evidence to read: the screenshot, `logs/production-app.log` (startup lines and any exception), `logs/simulator-os-log.txt`, and the marks above.")
    else:
        problems.append(f"the production app reached '{last}', expected the activation screen")
        lines.append(f"**FAIL** the last screen was '{last}', expected 'activation_screen'.")
    lines.append("")

    # ---- signing: an attempt until a run confirms it ----------------------------------
    # That an unsigned simulator build is refused by the Keychain (-34018) is a HYPOTHESIS, and ad hoc
    # signing is an ATTEMPT to test it. It is called confirmed only when this very run shows it: the build
    # was not the --no-codesign fallback, the production app (which reads the Keychain before it draws any
    # screen) reached the activation screen, AND the self-test's Keychain write/read/delete check PASSED.
    # The absence of one particular error number is not a success: any other Keychain failure, a check
    # that is missing, or one that only reports information, leaves it unconfirmed.
    signing_log = results / "logs" / "build-signing.txt"
    signing_text = signing_log.read_text(encoding="utf-8", errors="replace").strip() if signing_log.exists() else ""
    fallback = "FALLBACK" in signing_text
    keychain = next((c for c in (full or {}).get("checks", []) if c.get("name") == KEYCHAIN_CHECK), None)
    keychain_detail = str(keychain.get("detail", "")) if keychain else ""
    keychain_status = str(keychain.get("status", "")) if keychain else ""
    keychain_passed = keychain is not None and keychain_status == "pass"
    reached = isinstance(ui, dict) and ui.get("screen") == "activation_screen"
    confirmed = bool(signing_text) and not fallback and reached and keychain_passed
    lines += ["## 1b. Signing of the simulator build (an attempt, not a result)", ""]
    lines.append(f"Build log: `{signing_text or 'no build-signing.txt was recorded'}`")
    lines.append("")
    lines.append(f"- built without the unsigned fallback: **{'yes' if signing_text and not fallback else 'no / not recorded'}**")
    lines.append(f"- production app reached the activation screen (it reads the Keychain first): **{'yes' if reached else 'no'}**")
    if keychain is None:
        lines.append(f"- self-test Keychain write/read/delete (`{KEYCHAIN_CHECK}`): **not present**, so nothing shows the Keychain works")
    else:
        lines.append(f"- self-test Keychain write/read/delete (`{KEYCHAIN_CHECK}`): **{'passed' if keychain_passed else 'NOT passed (' + (keychain_status or 'no status') + ')'}** "
                     f"`{keychain_detail.replace(chr(10), ' ')[:200]}`")
    lines.append("")
    if confirmed:
        lines.append("**Ad hoc signing: CONFIRMED by this run** for the simulator (Keychain usable, activation screen reached). "
                     "This says nothing about a signed build on an iPhone.")
    else:
        lines.append("**Ad hoc signing: NOT CONFIRMED by this run.** It stays an attempt; that the unsigned build was refused for want of "
                     "an entitlement (-34018) remains a hypothesis until a run shows it. A confirmation needs a passed Keychain write/read/delete; "
                     "the absence of one particular error number is not enough.")
    lines.append("")

    # ---- full run ------------------------------------------------------------------
    lines += ["## 2. Self-test, full run (native crypto, encrypted store, loopback server, real WebView)", ""]
    if full is None:
        problems.append("the full self-test run produced no result file")
        lines.append("**FAIL** no result file.")
    else:
        lines.append(f"Platform: `{full.get('platform')}`. {full.get('passed')} passed, {full.get('failed')} failed, {full.get('info')} informational. "
                     f"Finished: {full.get('done')}.")
        lines.append("")
        lines += md_checks(full)
        if not full.get("done"):
            problems.append("the full run did not finish")
        for c in full.get("checks", []):
            if c["status"] == "fail":
                problems.append(f"full run: {c['name']}: {c['detail']}")
    lines.append("")

    # ---- cold runs -----------------------------------------------------------------
    lines += ["## 3. Cold opens of the saved page, one fresh process each", ""]
    painted, found = [], 0
    if not colds:
        problems.append("no cold runs were recorded")
        lines.append("**FAIL** no cold run results.")
    else:
        lines += ["| Run | Result | Drawn after open began (ms) | Launch command to result file (ms) |", "|---|---|---:|---:|"]
        for name, rep in colds:
            if rep is None or rep.get("unreadable"):
                problems.append(f"{name}: no readable result")
                lines.append(f"| {name} | **FAIL** (no result) | | {walls.get(name, '')} |")
                continue
            ok = rep.get("ok") is True
            ms = rep.get("marks", {}).get("painted_ms")
            if not ok:
                bad = [c for c in rep.get("checks", []) if c["status"] == "fail"]
                problems.append(f"{name}: {bad[0]['detail'] if bad else 'did not finish'}")
            if ok and isinstance(ms, int):
                painted.append(ms)
            found += 1
            lines.append(f"| {name} | {'PASS' if ok else '**FAIL**'} | {ms if ms is not None else ''} | {walls.get(name, '')} |")
        lines.append("")
        if painted:
            within = sum(1 for p in painted if p <= TARGET_MS)
            lines.append(f"Drawn after the open began: min {min(painted)} ms, median {int(statistics.median(painted))} ms, max {max(painted)} ms; "
                         f"{within} of {len(painted)} within {TARGET_MS} ms.")
        lines.append("")
        lines.append(f"> **This is a measurement, not a verdict on the {TARGET_MS} ms target.** It is a CI simulator on a Mac runner, "
                     "counted from the moment the page began to be opened (not from the launch of the process), with a stand-in page of "
                     "the size of a real dashboard. It says whether the chain works on iOS and roughly how long its parts take. "
                     "Whether an iPhone shows a complete panel within 2 s of the user starting the app has to be measured on an iPhone.")
    lines.append("")

    # ---- static --------------------------------------------------------------------
    lines += ["## 4. Project and built-bundle checks", ""]
    if static is None:
        problems.append("the static checks produced no result")
        lines.append("**FAIL** no result.")
    else:
        s = static.get("summary", {})
        lines.append(f"{s.get('PASS')} passed, {s.get('WARN')} warnings, {s.get('FAIL')} failed.")
        lines.append("")
        for item in static.get("items", []):
            lines.append(f"- **{item['status']}** {item['name']}: {item['detail']}")
            if item["status"] == "FAIL":
                problems.append(f"static: {item['name']}: {item['detail']}")
    lines.append("")

    lines += ["## Verdict", ""]
    if problems:
        lines.append("**FAIL**")
        lines += [f"- {p}" for p in problems]
    else:
        lines.append("**PASS** for everything this job can establish. It does not establish: behaviour on a real iPhone, a signed build, "
                     "Universal Links, the camera, real network switching, or the 2 s target on device (see docs/IOS-RUNTIME-VERIFICATION.md).")
    return "\n".join(lines) + "\n", problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    text, problems = build(Path(args.results))
    Path(args.out).write_text(text, encoding="utf-8")
    print(text)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
