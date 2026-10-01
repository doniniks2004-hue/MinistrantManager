/// Offline-architecture milestone, P3. One manifest per captured page
/// snapshot, matching the architecture decision's own shape exactly:
///
/// ```json
/// {
///   "parish_id": "...",
///   "user_id": "...",
///   "path": "/public/dashboard.php",
///   "captured_at": "...",
///   "resources": ["/assets/css/style.css", "/assets/js/app.js"]
/// }
/// ```
///
/// This class only models the data — SnapshotStore owns reading/writing
/// it to disk as part of an atomic snapshot update.
class SnapshotManifest {
  const SnapshotManifest({
    required this.parishId,
    required this.userId,
    required this.path,
    required this.capturedAt,
    required this.resources,
  });

  final String parishId;
  final String userId;

  /// The ORIGINAL legacy URL path this snapshot is of — e.g.
  /// `/public/dashboard.php` — never the sanitized on-disk directory
  /// name (see SnapshotStore's own path-to-directory-name mapping).
  final String path;

  final DateTime capturedAt;

  /// Relative paths (as they appear inside the page's own `assets/`
  /// folder, e.g. `assets/css/style.css`) of every resource this
  /// snapshot bundled — informational/diagnostic (e.g. for a future
  /// storage-usage view), not consulted by the local server itself
  /// (which just serves whatever file exists on disk regardless of
  /// whether it's listed here).
  final List<String> resources;

  Map<String, dynamic> toJson() => {
        'parish_id': parishId,
        'user_id': userId,
        'path': path,
        'captured_at': capturedAt.toUtc().toIso8601String(),
        'resources': resources,
      };

  /// Returns null for anything malformed rather than throwing — a
  /// corrupt or partially-written manifest (review round: "Nigdy nie
  /// nadpisujemy działającego snapshotu częściowo pobranymi plikami")
  /// should read back as "no snapshot here" to the caller, never crash
  /// whatever screen is trying to check for one.
  static SnapshotManifest? tryFromJson(Map<String, dynamic> json) {
    try {
      final parishId = json['parish_id'] as String;
      final userId = json['user_id'] as String;
      final path = json['path'] as String;
      final capturedAt = DateTime.parse(json['captured_at'] as String);
      final resources = (json['resources'] as List).cast<String>();
      return SnapshotManifest(
        parishId: parishId,
        userId: userId,
        path: path,
        capturedAt: capturedAt,
        resources: resources,
      );
    } catch (_) {
      return null;
    }
  }
}
