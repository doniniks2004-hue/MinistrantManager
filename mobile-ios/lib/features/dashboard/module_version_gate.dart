/// Client-side counterpart to MobileAPI's Config\ModuleVersionGate (PHP).
/// Extracted out of DashboardRenderer (Iteration 1.1 point 13) specifically
/// so this comparison — semver-ish major.minor.patch — is unit-testable on
/// its own, the same way the PHP side already is (see
/// mobileapi/Tests/ConfigContractTest.php).
class ModuleVersionGate {
  const ModuleVersionGate._();

  /// True if [deviceVersion] is OLDER than [minVersion] (i.e. the module
  /// should be gated/blocked). A null [minVersion] means "no requirement"
  /// — never gated.
  static bool isOlderThan(String deviceVersion, String? minVersion) {
    if (minVersion == null) return false;

    List<int> parts(String v) => v.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final d = parts(deviceVersion);
    final m = parts(minVersion);

    for (var i = 0; i < 3; i++) {
      final dv = i < d.length ? d[i] : 0;
      final mv = i < m.length ? m[i] : 0;
      if (dv != mv) return dv < mv;
    }
    return false;
  }

  /// The positive framing DashboardRenderer actually needs.
  static bool isSupported(String deviceVersion, String? minVersion) => !isOlderThan(deviceVersion, minVersion);
}
