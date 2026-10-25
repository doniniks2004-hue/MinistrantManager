#!/usr/bin/env python3
"""Offline acceptance of the Android app, measured from OUTSIDE the code that opens the page.

WHAT COUNTS AS "THE PANEL IS THERE". Not that a page finished loading, not that a frame was
drawn, not that a stylesheet exists. The owner states what the real panel is in a spec file
(see panel-spec.example.json): the page, elements that must be there and VISIBLE, elements that
must not be (a sign-in form, an error banner), computed styles that must really be applied. The
build under test is made with that spec (`--print-define` prints the dart-define), the page
checks it after two animation frames, and this script accepts a run only if ALL of these hold
for one report, taken from the log of the app process this script saw start:

  * the report is from THAT process (the process id in the log line, the process id in the
    report and the one found with `pidof` right after the start are the same, and the run
    saw one session id only);
  * it was made after two real animation frames (via=raf). A report made by the 1.5 s fallback
    timer (via=timer) is never accepted: that timer only keeps the app from waiting for ever;
  * the page is visible (visibility=visible, hidden=0), document complete, every image decoded,
    a stylesheet applied, a main area with a size;
  * it was checked against THIS spec (the spec id the build carries equals the one computed
    here from the spec file) and the verdict is ok (every required element shown, no forbidden
    one shown, every style applied) on the page the spec names;
  * it is for the navigation that is current: no later navigation of the same process
    appears in the log after it;
  * it came after the start / the loss of network / the return of network being measured,
    and in the right mode (copy while offline, live when online).

WHAT IS MEASURED, AND FROM WHEN TO WHEN (the requirement is the user's whole wait):

  COLD START   from the moment `am start` is issued (the user's tap, to within the few
               milliseconds it takes the device to run one command) to the accepted report
               above. The process start, the engine and the web view are all inside.
               Before it: the app is force-stopped and confirmed not running, and the network
               is confirmed down. After `am start` it must be confirmed started: the command
               answered, and a process id exists. A start that is not confirmed does not count.
  NETWORK LOSS from the moment BEFORE the commands that switch Wi-Fi and mobile data off are
               issued (so a little longer than the true disconnection: conservative) to the
               accepted report, from the same process that was showing the live panel. The
               loss is confirmed (the system reports no default network) before the result
               counts.
  RETURN       from the moment the network is switched back on to an accepted report of the
               LIVE panel, from the same process, with nobody touching the phone. Reported
               with a generous limit (no 2 s requirement is stated for it): what is checked
               is that it happens by itself.

Both ends are taken from the DEVICE's clock (`date` on the device, `logcat -v epoch`).

THE NETWORK IS PUT BACK as it was found, in a `finally`, however the run ends: an error, a
failed command, Ctrl-C. Whether that worked is in the report.

Needs a build that writes the trace (a debug build, or --dart-define=MM_TRACE=true) made with
--dart-define=MM_PANEL_SPEC=<from --print-define>, a device or emulator with the app signed in
and a saved copy of the panel (open it online once and wait for it), and `adb` on the path.

Usage:
  android_offline_acceptance.py --panel-spec panel-spec.json --print-define
  android_offline_acceptance.py --panel-spec panel-spec.json [--serial emulator-5554] [--runs 5] [--out report]
"""
import argparse
import base64
import json
import re
import subprocess
import sys
import time
from hashlib import sha256
from pathlib import Path

PACKAGE = "eu.ministrant.manager"
ACTIVITY = f"{PACKAGE}/.MainActivity"
LIMIT_MS = 2000
RETURN_LIMIT_MS = 30000
MAX_RUNS = 100
START_CONFIRM_S = 5
NETWORK_CONFIRM_S = 8
SETTLE_S = 1.5  # how long to keep looking for a later navigation after an accepted report


class AdbError(RuntimeError):
    """adb itself failed, or the device is not in a state in which a result means anything."""


# ---- the panel spec -------------------------------------------------------------------------

class SpecError(ValueError):
    pass


_SHORT_MAX = 200
_MAX_ITEMS = 20
_MAX_ENCODED = 4096


def _short(v):
    return isinstance(v, str) and 0 < len(v) <= _SHORT_MAX and not re.search(r"[\x00-\x1f]", v)


def load_spec(path):
    """(base64 text, spec id, spec) of a spec file. The same rules as PanelSpec in the app, plus:
    a file that still holds the example's REPLACE_ME placeholders is refused, so that an example
    cannot be accepted as the owner's definition of the panel."""
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except OSError as e:
        raise SpecError(f"cannot read the spec file: {e}")
    if "REPLACE_ME" in raw:
        raise SpecError("the spec still contains REPLACE_ME: it is the example, not the owner's definition of the panel")
    try:
        spec = json.loads(raw)
    except ValueError as e:
        raise SpecError(f"the spec is not JSON: {e}")
    if not isinstance(spec, dict):
        raise SpecError("the spec must be a JSON object")
    required = spec.get("required") or []
    if not (isinstance(required, list) and required and len(required) <= _MAX_ITEMS and all(_short(x) for x in required)):
        raise SpecError("'required' must list 1 to 20 selectors: a spec that names no element identifies nothing")
    for key in ("forbidden",):
        v = spec.get(key) or []
        if not (isinstance(v, list) and len(v) <= _MAX_ITEMS and all(_short(x) for x in v)):
            raise SpecError(f"'{key}' must be a list of at most 20 short selectors")
    styles = spec.get("styles") or []
    if not (isinstance(styles, list) and len(styles) <= _MAX_ITEMS):
        raise SpecError("'styles' must be a list of at most 20 checks")
    for s in styles:
        if not (isinstance(s, dict) and _short(s.get("selector")) and isinstance(s.get("property"), str)
                and re.fullmatch(r"[a-zA-Z-]{1,60}", s["property"]) and (("not" in s) != ("equals" in s))
                and _short(s.get("not", s.get("equals")))):
            raise SpecError("each style check needs a selector, a plain property name and exactly one of 'not' / 'equals'")
    p = spec.get("path")
    if p is not None and not (isinstance(p, str) and p.startswith("/") and len(p) <= _SHORT_MAX):
        raise SpecError("'path' must start with /")
    t = spec.get("titleContains")
    if t is not None and not _short(t):
        raise SpecError("'titleContains' must be a short string")
    encoded = base64.b64encode(json.dumps(spec, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).decode("ascii")
    if len(encoded) > _MAX_ENCODED:
        raise SpecError(f"the spec is too large once encoded ({len(encoded)} > {_MAX_ENCODED})")
    return encoded, spec_id(encoded), spec


def spec_id(encoded):
    return sha256(encoded.strip().encode("utf-8")).hexdigest()[:12]


# ---- reading the log ------------------------------------------------------------------------

# `logcat -v epoch`:  1697450001.500  1234  1234 I flutter : <message>
LOG_LINE = re.compile(r"^\s*(?P<t>\d+\.\d+)\s+(?P<pid>\d+)\s+(?P<tid>\d+)\s+(?P<prio>[VDIWEF])\s+(?P<tag>\S+)\s*:\s(?P<msg>.*)$")
NAV_PREFIX = re.compile(r"\bnav#(?P<nav>\d+)\b")
FACTS = re.compile(r"PAINTED_FACTS\s+(?P<kv>.*)$")
KV = re.compile(r"(?P<k>[A-Za-z_-]+)=(?P<v>\S+)")


def parse_log(logcat):
    """(facts, navs): every PAINTED_FACTS report as a dict, in log order, and every
    (pid, nav id, time_ms) seen on any line that carries a navigation id. Lines that do not parse
    are ignored; nothing is guessed from them."""
    facts, navs = [], []
    for line in logcat.splitlines():
        m = LOG_LINE.match(line)
        if not m:
            continue
        t_ms = round(float(m["t"]) * 1000)
        pid = int(m["pid"])
        msg = m["msg"]
        n = NAV_PREFIX.search(msg)
        if n:
            navs.append({"pid": pid, "nav": int(n["nav"]), "time_ms": t_ms})
        f = FACTS.search(msg)
        if not f:
            continue
        kv = {k["k"]: k["v"] for k in KV.finditer(f["kv"])}
        facts.append({"time_ms": t_ms, "log_pid": pid, "nav": int(n["nav"]) if n else None, "kv": kv})
    return facts, navs


def _int(v, default=-1):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def refusal(fact, want_pid, want_spec_id, want_mode):
    """Why this report is NOT acceptable evidence of the real panel, or None if it is."""
    kv = fact["kv"]
    if want_pid is None or fact["log_pid"] != want_pid:
        return f"it is from process {fact['log_pid']}, not from the app process this run started ({want_pid})"
    if _int(kv.get("pid")) != want_pid:
        return f"the report names process {kv.get('pid', 'none')}, not {want_pid}"
    if kv.get("mode") != want_mode:
        return f"it shows the {kv.get('mode')} page, expected the {want_mode} one"
    if kv.get("via") != "raf":
        return f"it was reported by '{kv.get('via')}', not after two real animation frames: the fallback timer is not evidence that a panel was drawn"
    if kv.get("visibility") != "visible" or kv.get("hidden") != "0":
        return f"the page is not visible (visibility={kv.get('visibility')}, hidden={kv.get('hidden')})"
    if kv.get("drawn") != "1":
        return "no real frame was drawn"
    if kv.get("readyState") != "complete":
        return f"the document is '{kv.get('readyState')}', not complete"
    img = re.fullmatch(r"(\d+)/(\d+)", kv.get("images", ""))
    if not img or img[1] != img[2]:
        return f"images decoded: {kv.get('images')}"
    if _int(kv.get("stylesheets")) < 1:
        return "no stylesheet applied"
    m = re.fullmatch(r"(\d+)x(\d+)px", kv.get("main", ""))
    if not m or int(m[1]) <= 0 or int(m[2]) <= 0:
        return f"the main area is {kv.get('main')}"
    if kv.get("spec") != want_spec_id:
        return f"it was checked against spec {kv.get('spec')}, not {want_spec_id}: the build was not made with this spec"
    if kv.get("verdict") != "ok":
        return f"the panel check failed (verdict={kv.get('verdict')}, failed={kv.get('failed')}): required elements missing or hidden, a forbidden one showing (sign-in or error page), or a required style not applied"
    if kv.get("path_ok") != "1":
        return "it is not the page the spec names"
    if kv.get("panel") != "1":
        return "the app did not count it as the panel"
    return None


def sessions_of(facts, pid):
    return {f["kv"].get("session") for f in facts if f["log_pid"] == pid}


def pick(facts, navs, since_ms, want_pid, want_spec_id, want_mode, min_nav=0):
    """The first report after [since_ms] that is acceptable evidence, as (fact, None); else
    (None, the reason the nearest candidate was refused, or why there were none)."""
    mine = [f for f in facts if f["time_ms"] >= since_ms and f["log_pid"] == want_pid]
    if not mine:
        return None, "no PAINTED_FACTS report from the app process arrived (the page was not drawn, the trace is off, or the build is not this one)"
    if len(sessions_of(facts, want_pid)) > 1:
        return None, "the log of this process holds more than one session id: it is not one process's log"
    first_why = None
    for f in mine:
        why = refusal(f, want_pid, want_spec_id, want_mode)
        if why is None and (f["nav"] or 0) < min_nav:
            why = f"it is for navigation {f['nav']}, before the one being waited for (>= {min_nav})"
        if why is None:
            later = [n for n in navs if n["pid"] == want_pid and n["nav"] > (f["nav"] or 0)]
            if later:
                why = f"navigation {f['nav']} was superseded by navigation {max(n['nav'] for n in later)}: the report is not for the page now on screen"
        if why is None:
            return f, None
        first_why = first_why or f"report at +{f['time_ms'] - since_ms} ms refused: {why}"
    return None, first_why


def evaluate(kind, started_ms, fact, why, limit_ms, pid=None):
    """One run's verdict. Never passes without an accepted report."""
    if fact is None:
        return {"kind": kind, "ok": False, "ms": None, "pid": pid, "why": why or "no accepted report"}
    ms = fact["time_ms"] - started_ms
    if ms > limit_ms:
        return {"kind": kind, "ok": False, "ms": ms, "pid": pid, "why": f"the real panel was shown after {ms} ms, over the limit of {limit_ms} ms"}
    return {"kind": kind, "ok": True, "ms": ms, "pid": pid, "why": f"real panel visible after {ms} ms (nav {fact['nav']}, {fact['kv'].get('images')} images, verdict ok)"}


def summarize(results):
    lines = ["| Run | Result | ms | pid | Detail |", "|---|---|---:|---:|---|"]
    counts = {}
    for r in results:
        counts[r["kind"]] = counts.get(r["kind"], 0) + 1
        lines.append(f"| {r['kind']} {counts[r['kind']]} | {'PASS' if r['ok'] else '**FAIL**'} | {r['ms'] if r['ms'] is not None else ''} | {r.get('pid') or ''} | {r['why']} |")
    return "\n".join(lines)


# ---- network state --------------------------------------------------------------------------

def parse_default_network(dumpsys_connectivity):
    """'up' if the system reports a default network, 'down' if it says there is none, None if the
    text says neither (then nothing is concluded)."""
    m = re.search(r"Active default network:\s*(\S+)", dumpsys_connectivity)
    if not m:
        return None
    return "down" if m[1].lower() == "none" else "up"


# ---- the device -----------------------------------------------------------------------------

BAD_OUTPUT = ("device offline", "no devices/emulators found", "device unauthorized", "device not found", "more than one device", "adb: error", "error: closed")


def subprocess_runner(argv, timeout):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        raise AdbError("adb was not found on the path")
    except subprocess.TimeoutExpired:
        raise AdbError(f"adb did not answer within {timeout} s: {' '.join(argv[:4])}")
    return r.returncode, r.stdout, r.stderr


class Device:
    def __init__(self, serial=None, runner=subprocess_runner, sleep=time.sleep, clock=time.time):
        self.base = ["adb"] + (["-s", serial] if serial else [])
        self.runner = runner
        self.sleep = sleep
        self.clock = clock

    def run_rc(self, *args, timeout=60):
        """(exit code, stdout, stderr) of one adb call. Raises AdbError when adb itself says the
        device is not there (offline, unauthorized, not found...). The exit code is NOT judged here."""
        rc, out, err = self.runner(self.base + list(args), timeout)
        text = (out + "\n" + err).lower()
        for bad in BAD_OUTPUT:
            if bad in text:
                raise AdbError(f"adb: {bad}")
        return rc, out, err

    def run(self, *args, timeout=60):
        """adb's output, or AdbError: a non-zero exit, or adb saying the device is not there. Output
        from a command that did not run is not a measurement."""
        rc, out, err = self.run_rc(*args, timeout=timeout)
        if rc != 0:
            raise AdbError(f"adb {' '.join(args[:3])} exited with {rc}: {(err or out).strip()[:200]}")
        return out

    def shell(self, command, timeout=60):
        return self.run("shell", command, timeout=timeout)

    def now_ms(self):
        out = self.shell("date +%s.%N").strip()
        try:
            return round(float(out) * 1000)
        except ValueError:
            raise AdbError(f"the device did not return its time: {out[:80]!r}")

    def stamped(self, commands):
        """Runs [commands] on the device; returns (the device time taken immediately BEFORE them,
        their output)."""
        out = self.shell(f"date +%s.%N; {commands}")
        first, _, rest = out.partition("\n")
        try:
            return round(float(first.strip()) * 1000), rest
        except ValueError:
            raise AdbError(f"the device did not return its time: {first[:80]!r}")

    def logcat(self):
        return self.run("logcat", "-d", "-v", "epoch", timeout=120)

    def clear_log(self):
        self.run("logcat", "-c")

    def pid(self):
        """The app's process id, or None when there is no such process.

        `pidof` exits with 1 and prints nothing when no process matches: that is the expected answer
        after a force-stop, not a failure. Everything else is a failure: any other exit code, a
        message on stderr, adb saying the device is offline/unauthorized, or output that is not a
        list of process ids."""
        rc, out, err = self.run_rc("shell", f"pidof {PACKAGE}")
        out = out.strip()
        if rc == 1 and not out and not err.strip():
            return None
        if rc != 0:
            raise AdbError(f"adb shell pidof exited with {rc}: {(err or out).strip()[:200]}")
        if not out:
            return None  # an older adb that does not carry the exit code
        if not re.fullmatch(r"\d+(\s+\d+)*", out):
            raise AdbError(f"pidof answered something that is not a process id: {out[:80]!r}")
        return int(out.split()[0])

    def require_installed(self):
        if f"package:{PACKAGE}" not in self.shell("pm list packages"):
            raise AdbError(f"{PACKAGE} is not installed on the device")

    # -- the network, and knowing what state it is really in
    def network_state(self):
        return parse_default_network(self.shell("dumpsys connectivity", timeout=60))

    def wait_network(self, want, timeout_s=NETWORK_CONFIRM_S):
        """True once the system reports [want] ('up'/'down'); False if it never does, or never says."""
        deadline = self.clock() + timeout_s
        while True:
            if self.network_state() == want:
                return True
            if self.clock() >= deadline:
                return False
            self.sleep(0.5)

    def set_network(self, wifi_on, data_on):
        """Switches Wi-Fi and mobile data, and checks both commands exited cleanly. Returns the device
        time taken just before. Raises AdbError if a command failed."""
        w = "enable" if wifi_on else "disable"
        d = "enable" if data_on else "disable"
        t0, out = self.stamped(f"svc wifi {w}; echo RC_WIFI=$?; svc data {d}; echo RC_DATA=$?")
        rc = dict(re.findall(r"RC_(WIFI|DATA)=(\d+)", out))
        if rc.get("WIFI") != "0" or rc.get("DATA") != "0":
            raise AdbError(f"switching the network did not succeed (wifi exit {rc.get('WIFI')}, data exit {rc.get('DATA')}): {out.strip()[:200]}")
        return t0

    def read_network_settings(self):
        wifi = self.shell("settings get global wifi_on").strip()
        data = self.shell("settings get global mobile_data").strip()
        if wifi not in ("0", "1") or data not in ("0", "1"):
            raise AdbError(f"could not read the original network settings (wifi_on={wifi!r}, mobile_data={data!r})")
        return {"wifi": wifi == "1", "data": data == "1"}

    def start_app(self):
        """Starts the app like the user's tap and CONFIRMS it started. Returns (device time before the
        command, process id). Raises AdbError if am said it did not start, or no process appeared."""
        t0, out = self.stamped(f"am start -n {ACTIVITY}")
        low = out.lower()
        if "error" in low or "exception" in low or "not started" in low or "does not exist" in low:
            raise AdbError(f"the app did not start: {out.strip()[:200]}")
        deadline = self.clock() + START_CONFIRM_S
        while True:
            pid = self.pid()
            if pid:
                return t0, pid
            if self.clock() >= deadline:
                raise AdbError("am start answered but no app process exists: the start is not confirmed")
            self.sleep(0.1)

    def stop_app(self):
        self.shell(f"am force-stop {PACKAGE}")
        deadline = self.clock() + START_CONFIRM_S
        while self.pid():
            if self.clock() >= deadline:
                raise AdbError("the app is still running after force-stop")
            self.sleep(0.1)

    def wait_for(self, since_ms, pid, spec, mode, timeout_s, min_nav=0):
        """Polls the log until an accepted report exists or the time is up. Returns (fact, why)."""
        deadline = self.clock() + timeout_s
        why = None
        while True:
            facts, navs = parse_log(self.logcat())
            fact, why = pick(facts, navs, since_ms, pid, spec, mode, min_nav)
            if fact is not None:
                # A later navigation could still supersede it: look a little longer.
                self.sleep(SETTLE_S)
                facts, navs = parse_log(self.logcat())
                again, why2 = pick(facts, navs, since_ms, pid, spec, mode, min_nav)
                return (again, None) if again is not None else (None, why2 or why)
            if self.clock() >= deadline:
                return None, why
            self.sleep(0.3)


# ---- the runs -------------------------------------------------------------------------------

def run_cold_starts(dev, runs, spec):
    results = []
    for _ in range(runs):
        try:
            dev.stop_app()
            dev.set_network(False, False)
            if not dev.wait_network("down"):
                results.append({"kind": "cold start", "ok": False, "ms": None, "why": "the network was not confirmed down: the run does not count"})
                continue
            dev.clear_log()
            t0, pid = dev.start_app()
        except AdbError as e:
            results.append({"kind": "cold start", "ok": False, "ms": None, "why": f"not confirmed: {e}"})
            continue
        fact, why = dev.wait_for(t0, pid, spec, "copy", 15)
        results.append(evaluate("cold start", t0, fact, why, LIMIT_MS, pid))
    return results


def run_cycles(dev, runs, spec):
    results = []
    for _ in range(runs):
        try:
            dev.stop_app()
            dev.set_network(True, True)
            if not dev.wait_network("up", 20):
                results.append({"kind": "cycle (start online)", "ok": False, "ms": None, "why": "the network was not confirmed up: the run does not count"})
                continue
            dev.clear_log()
            t_start, pid = dev.start_app()
        except AdbError as e:
            results.append({"kind": "cycle (start online)", "ok": False, "ms": None, "why": f"not confirmed: {e}"})
            continue
        live, why = dev.wait_for(t_start, pid, spec, "live", 40)
        if live is None:
            results.append({"kind": "cycle (start online)", "ok": False, "ms": None, "pid": pid, "why": f"the live panel was not confirmed before the connection was cut: {why}"})
            continue
        dev.sleep(2)
        try:
            t_cut = dev.set_network(False, False)
            confirmed = dev.wait_network("down")
        except AdbError as e:
            results.append({"kind": "cycle: loss of network -> saved copy", "ok": False, "ms": None, "pid": pid, "why": f"not confirmed: {e}"})
            continue
        if not confirmed:
            results.append({"kind": "cycle: loss of network -> saved copy", "ok": False, "ms": None, "pid": pid, "why": "the loss of network was not confirmed by the system: the run does not count"})
            continue
        copy, why = dev.wait_for(t_cut, pid, spec, "copy", 15, min_nav=(live["nav"] or 0) + 1)
        results.append(evaluate("cycle: loss of network -> saved copy", t_cut, copy, why, LIMIT_MS, pid))
        dev.sleep(2)
        try:
            t_back = dev.set_network(True, True)
        except AdbError as e:
            results.append({"kind": "cycle: network back -> live panel", "ok": False, "ms": None, "pid": pid, "why": f"not confirmed: {e}"})
            continue
        if dev.pid() != pid:
            results.append({"kind": "cycle: network back -> live panel", "ok": False, "ms": None, "pid": pid, "why": "the app process is gone: the return must happen in the same process, without a restart"})
            continue
        floor = (copy["nav"] if copy else live["nav"]) or 0
        back, why = dev.wait_for(t_back, pid, spec, "live", 60, min_nav=floor + 1)
        results.append(evaluate("cycle: network back -> live panel", t_back, back, why, RETURN_LIMIT_MS, pid))
    return results


def restore_network(dev, original):
    """Puts Wi-Fi and mobile data back as they were found. Returns a sentence for the report."""
    if original is None:
        return "the original network settings were never read, so nothing was changed by this tool"
    try:
        dev.set_network(original["wifi"], original["data"])
        want = "up" if (original["wifi"] or original["data"]) else "down"
        ok = dev.wait_network(want, 20)
        return (f"network restored to wifi={'on' if original['wifi'] else 'off'}, data={'on' if original['data'] else 'off'}"
                + ("" if ok else f"; BUT the system did not report it {want} within 20 s: CHECK THE DEVICE"))
    except AdbError as e:
        return f"**COULD NOT RESTORE THE NETWORK: {e}. Check the device by hand.**"


def positive_runs(text):
    try:
        n = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"--runs must be a whole number, got {text!r}")
    if not 1 <= n <= MAX_RUNS:
        raise argparse.ArgumentTypeError(f"--runs must be between 1 and {MAX_RUNS}: 0 runs would 'pass' nothing, a negative number is meaningless")
    return n


def build_report(spec, cold, cycles, runs, restored):
    results = cold + cycles
    text = f"# Android offline acceptance\n\nPanel spec id: `{spec}`\n\n" + summarize(results) + "\n\n"
    cold_ok = sum(1 for r in cold if r["ok"])
    loss = [r for r in cycles if r["kind"].startswith("cycle: loss")]
    back = [r for r in cycles if r["kind"].startswith("cycle: network back")]
    start_failed = [r for r in cycles if r["kind"].startswith("cycle (start")]
    text += (f"Cold starts: {cold_ok}/{runs}. Network loss -> saved copy: {sum(r['ok'] for r in loss)}/{runs}. "
             f"Network back -> live panel: {sum(r['ok'] for r in back)}/{runs}. Cycles that did not get as far as the cut: {len(start_failed)}.\n\n")
    ok = (len(cold) == runs and cold_ok == runs and len(loss) == runs and all(r["ok"] for r in loss)
          and len(back) == runs and all(r["ok"] for r in back) and not start_failed)
    text += ("**" + ("PASS" if ok else "FAIL") + f"**: {runs} of {runs} are required in each set, each within {LIMIT_MS} ms "
             "(the return to live within the limit above), measured on the device's own clock, each accepted only on a report from the "
             "app process that was started or was running, made after real animation frames, of a visible page that is the real panel "
             "by the owner's spec, for the navigation then current.\n\n")
    text += f"{restored}.\n"
    return text, ok


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--panel-spec", required=True, help="the owner's definition of the panel (JSON); see panel-spec.example.json")
    ap.add_argument("--print-define", action="store_true", help="print the --dart-define the build under test needs, and exit")
    ap.add_argument("--serial")
    ap.add_argument("--runs", type=positive_runs, default=5)
    ap.add_argument("--out", default="android-offline-acceptance")
    args = ap.parse_args(argv)

    try:
        encoded, sid, _ = load_spec(args.panel_spec)
    except SpecError as e:
        print(f"panel spec refused: {e}")
        return 2
    if args.print_define:
        print(f"--dart-define=MM_PANEL_SPEC={encoded}\nspec id: {sid}")
        return 0

    dev = Device(args.serial)
    original = None
    cold, cycles = [], []
    restored = ""
    try:
        dev.require_installed()
        original = dev.read_network_settings()
        cold = run_cold_starts(dev, args.runs, sid)
        cycles = run_cycles(dev, args.runs, sid)
    except AdbError as e:
        print(f"stopped: {e}")
        restored = restore_network(dev, original)
        print(restored)
        return 2
    except BaseException:
        restore_network(dev, original)
        raise
    restored = restore_network(dev, original)
    text, ok = build_report(sid, cold, cycles, args.runs, restored)
    Path(args.out + ".md").write_text(text, encoding="utf-8")
    Path(args.out + ".json").write_text(json.dumps(cold + cycles, indent=2), encoding="utf-8")
    print(text)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
