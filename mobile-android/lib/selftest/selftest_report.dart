/// The outcome of one check of the platform self-test.
///
/// [pass] and [fail] are verdicts. [info] is a measurement or an observation
/// that is NOT a verdict on the app: something that cannot be judged on the
/// machine the test ran on (for example the Keychain of an unsigned simulator
/// build, or the speed of a CPU that is not the target's). It never fails a run
/// and is never presented as a pass.
enum CheckStatus { pass, fail, info }

class CheckResult {
  const CheckResult(this.name, this.status, this.milliseconds, this.detail);

  final String name;
  final CheckStatus status;
  final int milliseconds;
  final String detail;

  Map<String, Object?> toJson() => {
    'name': name,
    'status': status.name,
    'ms': milliseconds,
    'detail': detail,
  };
}

/// Everything one run of the self-test found, in a form a CI job can read from a
/// file without depending on what the platform does with log output.
class SelfTestReport {
  SelfTestReport({required this.mode, required this.run, required this.platform});

  /// "full" (every check, and it seeds the saved page) or "cold" (opens the saved
  /// page from disk in a fresh process and measures how long that takes).
  final String mode;
  final int run;
  final String platform;
  final checks = <CheckResult>[];
  final marks = <String, int>{};
  bool done = false;

  void add(CheckResult result) => checks.add(result);

  int get passed => checks.where((c) => c.status == CheckStatus.pass).length;
  int get failed => checks.where((c) => c.status == CheckStatus.fail).length;
  int get informational => checks.where((c) => c.status == CheckStatus.info).length;

  /// A run passes only when it finished and nothing failed. A run that was cut
  /// short (the process died, the page never loaded) has `done == false` and is
  /// not a pass.
  bool get ok => done && failed == 0;

  Map<String, Object?> toJson() => {
    'mode': mode,
    'run': run,
    'platform': platform,
    'done': done,
    'ok': ok,
    'passed': passed,
    'failed': failed,
    'info': informational,
    'marks': marks,
    'checks': [for (final c in checks) c.toJson()],
  };
}
