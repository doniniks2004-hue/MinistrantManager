"""Tests of the Android acceptance tool: what it refuses, what it counts, and that it leaves the phone's network as it found it.

The phone is simulated (FakePhone): it answers the adb commands the tool uses, keeps a network state, starts and stops a process,
and writes PAINTED_FACTS lines in the form the app writes them, with whatever defect a test asks for.
"""
import io
import json
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import android_offline_acceptance as acc  # noqa: E402

SPEC_B64 = ("eyJwYXRoIjoiL3B1YmxpYy9kYXNoYm9hcmQucGhwIiwicmVxdWlyZWQiOlsiI3BhbmVsIl0sImZvcmJpZGRlbiI6WyJpbnB1dFt0eXBlPXBhc3N3b3JkXSJdLCJzdHlsZXMiOlt7InNlbGVj"
            "dG9yIjoiYm9keSIsInByb3BlcnR5IjoiYmFja2dyb3VuZC1jb2xvciIsIm5vdCI6InJnYmEoMCwgMCwgMCwgMCkifV19")
SPEC_ID = "08e9cf523dae"  # computed independently of this tool (and the same one the Dart test uses)
SPEC_JSON = {"path": "/public/dashboard.php", "required": ["#panel"], "forbidden": ["input[type=password]"],
             "styles": [{"selector": "body", "property": "background-color", "not": "rgba(0, 0, 0, 0)"}]}


def facts_line(t, pid=1234, nav=3, log_pid=None, **over):
    kv = dict(pid=pid, session="k1x9", mode="copy", via="raf", drawn=1, readyState="complete", visibility="visible", hidden=0,
              images="3/3", stylesheets=1, main="1180x2300px", spec=SPEC_ID, verdict="ok", failed="-", path_ok=1, panel=1)
    kv.update(over)
    body = " ".join(f"{k}={v}" for k, v in kv.items())
    return f"{t:.3f}  {log_pid or pid}  {log_pid or pid} I flutter : nav#{nav} +900ms PAINTED_FACTS {body}"


def nav_line(t, nav, pid=1234):
    return f"{t:.3f}  {pid}  {pid} I flutter : nav#{nav} +5ms load started"


class Spec(unittest.TestCase):
    def write(self, obj, raw=None):
        d = tempfile.mkdtemp()
        p = Path(d) / "spec.json"
        p.write_text(raw if raw is not None else json.dumps(obj), encoding="utf-8")
        return p

    def test_the_id_matches_the_one_computed_outside_this_tool_and_the_app(self):
        encoded, sid, _ = acc.load_spec(self.write(SPEC_JSON))
        self.assertEqual(encoded, SPEC_B64)
        self.assertEqual(sid, SPEC_ID)

    def test_the_example_file_is_refused(self):
        with self.assertRaises(acc.SpecError) as c:
            acc.load_spec(Path(__file__).parent / "panel-spec.example.json")
        self.assertIn("REPLACE_ME", str(c.exception))

    def test_a_spec_that_identifies_nothing_is_refused(self):
        for bad in ({}, {"required": []}, {"forbidden": ["input"]}, {"required": [""]}):
            with self.assertRaises(acc.SpecError, msg=str(bad)):
                acc.load_spec(self.write(bad))

    def test_malformed_specs_are_refused(self):
        cases = [
            {"required": "#a"}, {"required": ["a" * 201]}, {"required": ["#a"] * 21}, {"required": ["#a\nb"]},
            {"required": ["#a"], "path": "nope"},
            {"required": ["#a"], "styles": [{"selector": "body", "property": "color"}]},
            {"required": ["#a"], "styles": [{"selector": "body", "property": "color", "not": "x", "equals": "y"}]},
            {"required": ["#a"], "styles": [{"selector": "body", "property": "color; x", "not": "x"}]},
        ]
        for bad in cases:
            with self.assertRaises(acc.SpecError, msg=str(bad)):
                acc.load_spec(self.write(bad))
        with self.assertRaises(acc.SpecError):
            acc.load_spec(self.write(None, raw="not json"))
        with self.assertRaises(acc.SpecError):
            acc.load_spec(self.write(None, raw="[1]"))
        with self.assertRaises(acc.SpecError):
            acc.load_spec(Path(tempfile.mkdtemp()) / "missing.json")


class Parse(unittest.TestCase):
    def test_a_report_is_read_with_its_process_and_navigation(self):
        facts, navs = acc.parse_log(facts_line(1697450001.5))
        self.assertEqual((facts[0]["time_ms"], facts[0]["log_pid"], facts[0]["nav"]), (1697450001500, 1234, 3))
        self.assertEqual(navs, [{"pid": 1234, "nav": 3, "time_ms": 1697450001500}])
        self.assertEqual(facts[0]["kv"]["via"], "raf")

    def test_unrelated_and_malformed_lines_are_ignored(self):
        text = "\n".join(["garbage", "1.000 1 1 I flutter : nav#1 +5ms READY mode=copy", "PAINTED_FACTS pid=1 but no log prefix", ""])
        facts, navs = acc.parse_log(text)
        self.assertEqual(facts, [])
        self.assertEqual(len(navs), 1)


def accept(**over):
    """(fact or None, why) for one report with a defect from [over], asked for the process 1234, copy mode."""
    log_pid = over.pop("log_pid", None)
    nav = over.pop("nav", 3)
    facts, navs = acc.parse_log(facts_line(100.0, nav=nav, log_pid=log_pid, **over))
    return acc.pick(facts, navs, 99_000, 1234, SPEC_ID, "copy")


class Refusals(unittest.TestCase):
    def test_a_good_report_is_accepted(self):
        fact, why = accept()
        self.assertIsNone(why)
        self.assertEqual(fact["nav"], 3)

    def refused(self, fragment, **over):
        fact, why = accept(**over)
        self.assertIsNone(fact, over)
        self.assertIn(fragment, why)

    def test_the_fallback_timer_is_never_evidence(self):
        self.refused("fallback timer", via="timer", drawn=0, panel=0)
        self.refused("fallback timer", via="timer")  # even if everything else in the line looked right

    def test_a_hidden_page_is_refused(self):
        self.refused("not visible", visibility="hidden", hidden=1)
        self.refused("not visible", hidden=1)
        self.refused("not visible", visibility="hidden")

    def test_a_login_or_error_page_that_was_drawn_is_refused(self):
        self.refused("panel check failed", verdict="fail", failed="r0,f0", panel=0)

    def test_a_page_with_stylesheets_but_without_the_required_style_is_refused(self):
        self.refused("panel check failed", verdict="fail", failed="s0", stylesheets=4, panel=0)

    def test_a_build_with_no_spec_or_another_spec_is_refused(self):
        self.refused("not made with this spec", spec="-", verdict="none", panel=0)
        self.refused("not made with this spec", spec="ffffffffffff")

    def test_the_wrong_page_is_refused(self):
        self.refused("not the page the spec names", path_ok=0)

    def test_the_app_not_counting_it_as_the_panel_is_refused(self):
        self.refused("did not count it", panel=0)

    def test_each_kind_of_incomplete_page_is_named(self):
        self.refused("'interactive', not complete", readyState="interactive")
        self.refused("images decoded: 1/3", images="1/3")
        self.refused("no stylesheet applied", stylesheets=0)
        self.refused("main area is 0x0px", main="0x0px")

    def test_a_page_with_no_images_is_complete_if_the_rest_is(self):
        fact, why = accept(images="0/0")
        self.assertIsNone(why)

    def test_the_wrong_mode_is_refused(self):
        self.refused("expected the copy one", mode="live")

    def test_another_process_is_refused(self):
        facts, navs = acc.parse_log(facts_line(100.0, pid=999))
        fact, why = acc.pick(facts, navs, 99_000, 1234, SPEC_ID, "copy")
        self.assertIsNone(fact)
        self.assertIn("no PAINTED_FACTS report from the app process", why)

    def test_refusal_itself_checks_the_process_of_the_log_line(self):
        facts, _ = acc.parse_log(facts_line(100.0, pid=999))
        self.assertIn("not from the app process", acc.refusal(facts[0], 1234, SPEC_ID, "copy"))
        self.assertIn("not from the app process", acc.refusal(facts[0], None, SPEC_ID, "copy"))

    def test_a_report_naming_another_process_than_the_log_line_is_refused(self):
        self.refused("names process 999", pid=999, log_pid=1234)

    def test_a_report_from_before_the_measurement_began_is_not_counted(self):
        facts, navs = acc.parse_log(facts_line(100.0))
        fact, why = acc.pick(facts, navs, 101_000, 1234, SPEC_ID, "copy")
        self.assertIsNone(fact)

    def test_a_log_with_two_sessions_is_not_one_process(self):
        text = facts_line(100.0, session="aaaa") + "\n" + facts_line(100.5, session="bbbb")
        facts, navs = acc.parse_log(text)
        fact, why = acc.pick(facts, navs, 99_000, 1234, SPEC_ID, "copy")
        self.assertIsNone(fact)
        self.assertIn("more than one session", why)

    def test_a_report_for_a_navigation_that_was_replaced_is_refused(self):
        text = facts_line(100.0, nav=3) + "\n" + nav_line(100.4, 4)
        facts, navs = acc.parse_log(text)
        fact, why = acc.pick(facts, navs, 99_000, 1234, SPEC_ID, "copy")
        self.assertIsNone(fact)
        self.assertIn("superseded by navigation 4", why)

    def test_a_later_good_report_is_used_when_an_earlier_one_was_the_timer(self):
        text = facts_line(100.0, via="timer", drawn=0, panel=0) + "\n" + facts_line(100.8)
        facts, navs = acc.parse_log(text)
        fact, why = acc.pick(facts, navs, 99_000, 1234, SPEC_ID, "copy")
        self.assertIsNotNone(fact)

    def test_a_report_for_an_earlier_navigation_than_waited_for_is_refused(self):
        facts, navs = acc.parse_log(facts_line(100.0, nav=2, mode="live"))
        fact, why = acc.pick(facts, navs, 99_000, 1234, SPEC_ID, "live", min_nav=3)
        self.assertIsNone(fact)
        self.assertIn("before the one being waited for", why)


class Evaluate(unittest.TestCase):
    def fact(self, at_ms):
        return {"time_ms": at_ms, "nav": 3, "kv": {"images": "3/3"}}

    def test_never_passes_without_an_accepted_report(self):
        r = acc.evaluate("cold start", 0, None, "nothing", 2000)
        self.assertFalse(r["ok"])
        self.assertIsNone(r["ms"])

    def test_time_is_from_the_start_to_the_report_and_the_limit_is_inclusive(self):
        self.assertTrue(acc.evaluate("x", 1000, self.fact(3000), None, 2000)["ok"])
        r = acc.evaluate("x", 1000, self.fact(3001), None, 2000)
        self.assertFalse(r["ok"])
        self.assertEqual(r["ms"], 2001)


class DefaultNetwork(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(acc.parse_default_network("foo\nActive default network: 100\nbar"), "up")
        self.assertEqual(acc.parse_default_network("Active default network: none"), "down")
        self.assertIsNone(acc.parse_default_network("nothing about it"))


class Adb(unittest.TestCase):
    def dev(self, runner):
        return acc.Device(runner=runner, sleep=lambda s: None)

    def test_a_non_zero_exit_is_an_error_not_an_empty_answer(self):
        with self.assertRaises(acc.AdbError):
            self.dev(lambda argv, t: (1, "", "boom")).shell("x")

    def test_device_offline_is_an_error_even_with_exit_zero(self):
        for text in ("error: device offline", "error: no devices/emulators found", "error: device unauthorized"):
            with self.assertRaises(acc.AdbError, msg=text):
                self.dev(lambda argv, t, text=text: (0, "", text)).shell("x")

    def test_adb_missing_or_hanging_is_an_error(self):
        def missing(argv, t):
            raise acc.AdbError("adb was not found on the path")
        with self.assertRaises(acc.AdbError):
            self.dev(missing).shell("x")

    def test_a_device_that_returns_no_time_is_an_error(self):
        with self.assertRaises(acc.AdbError):
            self.dev(lambda argv, t: (0, "not a time\n", "")).stamped("x")

    def test_unreadable_original_settings_are_an_error(self):
        with self.assertRaises(acc.AdbError):
            self.dev(lambda argv, t: (0, "null\n", "")).read_network_settings()


class ProcessLookup(unittest.TestCase):
    """`pidof` exits with 1 and prints nothing when there is no process. That is an answer."""

    def dev(self, runner):
        return acc.Device(runner=runner, sleep=lambda s: None)

    def test_no_process_is_none_not_an_error(self):
        self.assertIsNone(self.dev(lambda argv, t: (1, "", "")).pid())
        self.assertIsNone(self.dev(lambda argv, t: (1, "\n", "")).pid())

    def test_an_older_adb_that_loses_the_exit_code_gives_none_for_an_empty_answer(self):
        self.assertIsNone(self.dev(lambda argv, t: (0, "\n", "")).pid())

    def test_a_running_process_is_its_id(self):
        self.assertEqual(self.dev(lambda argv, t: (0, "4321\n", "")).pid(), 4321)
        self.assertEqual(self.dev(lambda argv, t: (0, "4321 4400\n", "")).pid(), 4321)

    def test_real_failures_are_not_read_as_no_process(self):
        cases = [
            (1, "", "error: device offline"),
            (1, "", "error: device unauthorized."),
            (1, "", "error: no devices/emulators found"),
            (1, "", "adb: error: closed"),
            (1, "", "some other failure"),         # exit 1 WITH a message is not the empty answer
            (2, "", ""),
            (127, "", "pidof: not found"),
            (255, "", ""),
            (0, "", "error: device offline"),
        ]
        for rc, out, err in cases:
            with self.assertRaises(acc.AdbError, msg=(rc, out, err)):
                self.dev(lambda argv, t, r=(rc, out, err): r).pid()

    def test_output_that_is_not_a_process_id_is_an_error(self):
        with self.assertRaises(acc.AdbError):
            self.dev(lambda argv, t: (0, "permission denied\n", "")).pid()

    def test_the_fake_phone_answers_like_the_real_pidof(self):
        phone = FakePhone()
        dev = phone.device()
        rc, out, _ = phone.runner(["adb", "shell", "pidof eu.ministrant.manager"], 5)
        self.assertEqual((rc, out.strip()), (1, ""))
        dev.start_app()
        rc, out, _ = phone.runner(["adb", "shell", "pidof eu.ministrant.manager"], 5)
        self.assertEqual(rc, 0)
        self.assertTrue(out.strip().isdigit())

    def test_a_force_stopped_app_is_a_stopped_app(self):
        phone = FakePhone()
        dev = phone.device()
        dev.start_app()
        dev.stop_app()          # was: am force-stop -> pidof exit 1 -> AdbError
        self.assertIsNone(dev.pid())

    def test_a_process_that_appears_only_after_several_reads_is_still_found(self):
        phone = FakePhone(pid_after_reads=4)
        t0, pid = phone.device().start_app()
        self.assertEqual(pid, 4000)
        self.assertEqual(phone.pid_reads_empty, 4)

    def test_a_process_that_never_appears_is_not_a_confirmed_start(self):
        phone = FakePhone(pid_after_reads=10**6)
        with self.assertRaises(acc.AdbError) as cm:
            phone.device().start_app()
        self.assertIn("no app process", str(cm.exception))

    def test_an_unreachable_device_is_not_a_stopped_app(self):
        phone = FakePhone(pidof_failure=(1, "error: device offline"))
        with self.assertRaises(acc.AdbError):
            phone.device().pid()
        with self.assertRaises(acc.AdbError):
            phone.device().stop_app()

    def test_a_device_lost_while_waiting_for_the_start_is_an_error_not_a_timeout_of_none(self):
        calls = {"n": 0}
        phone = FakePhone()
        real = phone.runner
        def flaky(argv, t):
            if "pidof" in " ".join(argv):
                calls["n"] += 1
                if calls["n"] >= 2:
                    return 1, "", "error: device offline"
            return real(argv, t)
        dev = acc.Device(runner=flaky, sleep=phone.sleep, clock=phone.clock)
        phone.nonconfirmed_pid = True
        with self.assertRaises(acc.AdbError) as cm:
            dev.start_app()
        self.assertIn("offline", str(cm.exception))

    def test_a_whole_run_survives_the_force_stop_between_cold_starts(self):
        cold, _, restored = run_all(FakePhone(), runs=3, cold_only=True)
        self.assertEqual([r["ok"] for r in cold], [True, True, True])
        self.assertTrue(restored)

    def test_a_device_that_goes_away_during_a_run_is_a_failed_run_with_the_reason(self):
        for n in (3, 6, 9, 14):
            phone = FakePhone(die_after_calls=n)
            try:
                cold, _, _ = run_all(phone, runs=1, cold_only=True)
            except acc.AdbError:
                continue   # refused outright is also not a pass
            self.assertFalse(any(r["ok"] for r in cold), msg=n)
            self.assertTrue(all(r["why"] for r in cold), msg=n)


class RunsArgument(unittest.TestCase):
    def test_zero_negative_and_non_numbers_are_refused(self):
        spec = Path(tempfile.mkdtemp()) / "s.json"
        spec.write_text(json.dumps(SPEC_JSON))
        for bad in ("0", "-1", "abc", "101", "2.5"):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as c:
                acc.main(["--panel-spec", str(spec), f"--runs={bad}"])
            self.assertEqual(c.exception.code, 2, bad)

    def test_the_example_spec_stops_the_run_before_anything_touches_the_phone(self):
        called = []
        orig = acc.Device
        acc.Device = lambda *a, **k: called.append(1) or orig(*a, **k)
        try:
            rc = acc.main(["--panel-spec", str(Path(__file__).parent / "panel-spec.example.json")])
        finally:
            acc.Device = orig
        self.assertEqual(rc, 2)
        self.assertEqual(called, [])

    def test_print_define_gives_the_exact_define_and_id(self):
        spec = Path(tempfile.mkdtemp()) / "s.json"
        spec.write_text(json.dumps(SPEC_JSON))
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = acc.main(["--panel-spec", str(spec), "--print-define"])
        self.assertEqual(rc, 0)
        self.assertIn(f"--dart-define=MM_PANEL_SPEC={SPEC_B64}", buf.getvalue())
        self.assertIn(SPEC_ID, buf.getvalue())


# ---- a simulated phone --------------------------------------------------------------------------

class FakePhone:
    """Answers the adb commands the tool issues. Time is simulated; the tool's sleep() advances it."""

    def __init__(self, wifi=True, data=False, paint_ms=900, back_ms=1500, defect=None, start_error=None,
                 network_stuck_up=False, svc_rc=0, die_after_calls=None, nonconfirmed_pid=False,
                 pid_after_reads=0, pidof_failure=None):
        self.now = 1_700_000_000.0
        self.wifi, self.data = wifi, data
        self.original = (wifi, data)
        self.pid_value = None
        self.next_pid = 4000
        self.log = []  # (due_time, text)
        self.nav = 0
        self.paint_ms, self.back_ms = paint_ms, back_ms
        self.defect = defect or {}
        self.start_error = start_error
        self.network_stuck_up = network_stuck_up
        self.svc_rc = svc_rc
        self.calls = 0
        self.die_after_calls = die_after_calls
        self.nonconfirmed_pid = nonconfirmed_pid
        self.rc = 0
        self.history = []
        # The process shows up in `pidof` only after this many reads that found nothing (a slow start).
        self.pid_after_reads = pid_after_reads
        self.pid_reads_empty = 0
        # (exit code, stderr) that `pidof` answers INSTEAD of the real one: a broken adb, not a missing process.
        self.pidof_failure = pidof_failure

    # simulated time
    def sleep(self, s):
        self.now += s

    def clock(self):
        return self.now

    @property
    def net_up(self):
        return (self.wifi or self.data) or self.network_stuck_up

    def paint(self, delay_s, mode):
        if self.pid_value is None:
            return
        self.nav += 1
        d = dict(self.defect)
        t = self.now + delay_s
        self.log.append((t - 0.9, nav_line(t - 0.9, self.nav, self.pid_value)))
        self.log.append((t, facts_line(t, pid=self.pid_value, nav=self.nav, mode=mode, **d)))

    def runner(self, argv, timeout):
        self.calls += 1
        if self.die_after_calls is not None and self.calls > self.die_after_calls:
            return 1, "", "error: device offline"
        cmd = argv[argv.index("shell") + 1] if "shell" in argv else None
        if cmd is None:
            if "logcat" in argv:
                if "-c" in argv:
                    self.log = []
                    return 0, "", ""
                return 0, "\n".join(text for due, text in self.log if due <= self.now) + "\n", ""
            return 0, "", ""
        out = []
        last_rc = 0
        for part in [p.strip() for p in cmd.split(";")]:
            last_rc = 0
            if part == "date +%s.%N":
                out.append(f"{self.now:.9f}")
            elif part.startswith("echo RC_"):
                out.append(f"{part.split()[1].split('=')[0]}={self.rc}")
            elif part.startswith("svc wifi"):
                self.rc = self.svc_rc
                if self.rc == 0:
                    was = self.net_up
                    self.wifi = part.endswith("enable")
                    self.history.append(("wifi", self.wifi))
            elif part.startswith("svc data"):
                self.rc = self.svc_rc
                if self.rc == 0:
                    self.data = part.endswith("enable")
                    self.history.append(("data", self.data))
                    if self.net_up and self.pid_value:
                        self.paint(self.back_ms / 1000, "live")
                    elif not self.net_up and self.pid_value:
                        self.paint(self.paint_ms / 1000, "copy")
            elif part.startswith("am force-stop"):
                self.pid_value = None
            elif part.startswith("am start"):
                if self.start_error:
                    out.append(self.start_error)
                else:
                    out.append("Starting: Intent { cmp=eu.ministrant.manager/.MainActivity }")
                    if not self.nonconfirmed_pid:
                        self.pid_value = self.next_pid
                        self.next_pid += 1
                        self.nav = 0
                        self.paint(self.paint_ms / 1000, "live" if self.net_up else "copy")
            elif part.startswith("pidof"):
                # Like the real command: prints the ids and exits 0; with no process it prints nothing and exits 1.
                if self.pidof_failure:
                    return self.pidof_failure[0], "", self.pidof_failure[1]
                shown = self.pid_value
                if shown and self.pid_reads_empty < self.pid_after_reads:
                    self.pid_reads_empty += 1
                    shown = None
                if shown:
                    out.append(str(shown))
                else:
                    last_rc = 1
            elif part.startswith("dumpsys connectivity"):
                out.append("Active default network: " + ("100" if self.net_up else "none"))
            elif part.startswith("pm list packages"):
                out.append("package:eu.ministrant.manager")
            elif part == "settings get global wifi_on":
                out.append("1" if self.original[0] else "0")
            elif part == "settings get global mobile_data":
                out.append("1" if self.original[1] else "0")
            else:
                raise AssertionError(f"FakePhone does not know: {part!r}")
        # adb (shell protocol v2) hands back the exit code of the LAST command on the device.
        return last_rc, ("\n".join(out) + "\n") if out else "", ""

    def device(self):
        return acc.Device(runner=self.runner, sleep=self.sleep, clock=self.clock)


def run_all(phone, runs=2, cold_only=False):
    dev = phone.device()
    original = dev.read_network_settings()
    try:
        cold = acc.run_cold_starts(dev, runs, SPEC_ID)
        cycles = [] if cold_only else acc.run_cycles(dev, runs, SPEC_ID)
    finally:
        restored = acc.restore_network(dev, original)
    return cold, cycles, restored


class EndToEnd(unittest.TestCase):
    def test_a_phone_that_shows_the_real_panel_in_time_passes(self):
        phone = FakePhone()
        cold, cycles, restored = run_all(phone)
        self.assertTrue(all(r["ok"] for r in cold + cycles), [r["why"] for r in cold + cycles if not r["ok"]])
        self.assertEqual(len(cold), 2)
        self.assertEqual(len(cycles), 4)
        text, ok = acc.build_report(SPEC_ID, cold, cycles, 2, restored)
        self.assertTrue(ok)
        self.assertIn("PASS", text)

    def test_the_time_is_the_user_s_wait_from_the_start_command(self):
        cold, _, _ = run_all(FakePhone(paint_ms=1234), runs=1, cold_only=True)
        self.assertTrue(1230 <= cold[0]["ms"] <= 1240, cold[0])

    def test_over_two_seconds_fails(self):
        cold, _, _ = run_all(FakePhone(paint_ms=2600), runs=1, cold_only=True)
        self.assertFalse(cold[0]["ok"])
        self.assertIn("over the limit", cold[0]["why"])

    def test_the_network_is_put_back_as_found(self):
        for original in ((True, False), (False, True), (True, True)):
            phone = FakePhone(wifi=original[0], data=original[1])
            run_all(phone, runs=1)
            self.assertEqual((phone.wifi, phone.data), original, "restored to exactly the state it was found in")

    # --- the pages that must NOT pass

    def assert_fails(self, defect, fragment):
        cold, cycles, _ = run_all(FakePhone(defect=defect), runs=1)
        self.assertFalse(all(r["ok"] for r in cold), defect)
        self.assertIn(fragment, cold[0]["why"])
        text, ok = acc.build_report(SPEC_ID, cold, cycles, 1, "restored")
        self.assertFalse(ok)

    def test_a_hidden_page_does_not_pass(self):
        self.assert_fails({"visibility": "hidden", "hidden": 1}, "not visible")

    def test_a_page_reported_only_by_the_fallback_timer_does_not_pass(self):
        self.assert_fails({"via": "timer", "drawn": 0, "panel": 0}, "fallback timer")

    def test_a_login_or_error_screen_does_not_pass(self):
        self.assert_fails({"verdict": "fail", "failed": "r0,f0", "panel": 0}, "panel check failed")

    def test_a_page_without_the_required_css_does_not_pass(self):
        self.assert_fails({"verdict": "fail", "failed": "s0", "stylesheets": 3, "panel": 0}, "panel check failed")

    def test_a_build_made_with_another_spec_does_not_pass(self):
        self.assert_fails({"spec": "000000000000"}, "not made with this spec")

    # --- what must not be counted when adb or the phone did not do what was asked

    def test_a_start_that_is_not_confirmed_is_not_counted(self):
        cold, _, _ = run_all(FakePhone(start_error="Error type 3\nError: Activity class does not exist."), runs=1, cold_only=True)
        self.assertFalse(cold[0]["ok"])
        self.assertIn("not confirmed", cold[0]["why"])

    def test_am_start_that_answers_but_leaves_no_process_is_not_counted(self):
        cold, _, _ = run_all(FakePhone(nonconfirmed_pid=True), runs=1, cold_only=True)
        self.assertFalse(cold[0]["ok"])
        self.assertIn("no app process", cold[0]["why"])

    def test_a_network_that_the_system_still_reports_up_is_not_counted_as_cut(self):
        cold, _, _ = run_all(FakePhone(network_stuck_up=True), runs=1, cold_only=True)
        self.assertFalse(cold[0]["ok"])
        self.assertIn("not confirmed down", cold[0]["why"])

    def test_a_failed_svc_command_is_not_counted(self):
        cold, _, _ = run_all(FakePhone(svc_rc=1), runs=1, cold_only=True)
        self.assertFalse(cold[0]["ok"])
        self.assertIn("switching the network did not succeed", cold[0]["why"])

    def test_a_cycle_whose_live_panel_never_appeared_is_not_cut_and_counted(self):
        cold, cycles, _ = run_all(FakePhone(defect={"verdict": "fail", "failed": "r0", "panel": 0}), runs=1)
        self.assertEqual([r["kind"] for r in cycles], ["cycle (start online)"])
        self.assertFalse(cycles[0]["ok"])

    def test_the_device_going_offline_stops_the_run_with_an_error_and_still_tries_to_restore(self):
        phone = FakePhone(die_after_calls=60)
        dev = phone.device()
        original = dev.read_network_settings()
        with self.assertRaises(acc.AdbError):
            try:
                acc.run_cold_starts(dev, 1, SPEC_ID)
                acc.run_cycles(dev, 3, SPEC_ID)
                dev.pid()
                for _ in range(80):
                    dev.pid()
            finally:
                message = acc.restore_network(dev, original)
        self.assertIn("COULD NOT RESTORE", message)

    def test_an_exception_in_the_middle_still_restores_the_network(self):
        phone = FakePhone(wifi=True, data=False)
        dev = phone.device()
        original = dev.read_network_settings()
        original_wait = dev.wait_for

        def boom(*a, **k):
            raise KeyboardInterrupt()

        dev.wait_for = boom
        with self.assertRaises(KeyboardInterrupt):
            try:
                acc.run_cold_starts(dev, 1, SPEC_ID)
            finally:
                restored = acc.restore_network(dev, original)
        self.assertEqual((phone.wifi, phone.data), (True, False))
        self.assertIn("network restored", restored)

    def test_two_runs_use_two_processes_and_a_stale_process_s_reports_are_not_accepted(self):
        phone = FakePhone()
        dev = phone.device()
        acc.run_cold_starts(dev, 1, SPEC_ID)
        first_pid = phone.next_pid - 1
        cold = acc.run_cold_starts(dev, 1, SPEC_ID)
        self.assertEqual(cold[0]["pid"], first_pid + 1)

    def test_the_report_never_passes_when_a_set_is_short(self):
        cold, cycles, restored = run_all(FakePhone(), runs=2)
        text, ok = acc.build_report(SPEC_ID, cold[:1], cycles, 2, restored)
        self.assertFalse(ok)


if __name__ == "__main__":
    unittest.main()
