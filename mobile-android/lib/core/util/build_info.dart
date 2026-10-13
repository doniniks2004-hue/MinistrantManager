/// The commit this build was made from. Set by CI with
/// `--dart-define=GIT_SHA=<sha>`; empty for a local `flutter run`/`build`.
/// Shown in the device settings so that "which build is on this phone" has
/// one unambiguous answer instead of being inferred from file names.
const String kBuildCommit = String.fromEnvironment('GIT_SHA');

String buildCommitLabel([String commit = kBuildCommit]) {
  if (commit.isEmpty) return 'build lokalny (bez SHA)';
  return commit.length > 7 ? commit.substring(0, 7) : commit;
}
