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
    if ui is None:
        problems.append("the production app never wrote its screen marker (it did not reach the activation screen)")
        lines.append("**FAIL** the app did not reach a screen that reports itself (no marker file).")
    elif ui.get("screen") == "activation_screen":
        marks = ui.get("marks", {})
        lines.append(f"PASS the activation screen was reached. Marks (ms since Dart `main()`): `{json.dumps(marks)}`")
    else:
        problems.append(f"the production app reached '{ui.get('screen')}', expected the activation screen")
        lines.append(f"**FAIL** the first screen was '{ui.get('screen')}', expected 'activation_screen'.")
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
