import 'page_identity.dart';

import 'page_resource_downloader.dart';
import 'snapshot_store.dart';

/// Offline-architecture milestone, P5. The glue between [PageResourceDownloader]
/// (P4) and [SnapshotStore] (P3) — the first point in this codebase
/// where "an already-rendered PHP page" actually becomes "a complete,
/// atomically-persisted, self-contained offline snapshot".
///
/// Deliberately thin: resource discovery/download (what to fetch, what
/// to skip, how to rewrite) is entirely [PageResourceDownloader]'s job;
/// atomic persistence/isolation (the temp-dir-then-rename sequence,
/// parish/user scoping) is entirely [SnapshotStore]'s job. This class
/// exists only so a caller has ONE method to call rather than needing
/// to know both APIs and get the plumbing between them right itself —
/// and so that plumbing (which field of [CapturedPage] goes to which
/// [SnapshotStore.writeSnapshot] parameter, what "page path" even means)
/// is defined in exactly one place.
///
/// All-or-nothing by construction, not by any extra logic in this
/// class: [PageResourceDownloader.capture] either returns a complete
/// [CapturedPage] or throws (resource-level failures — a 404 image, an
/// unreachable cross-origin script — are already handled gracefully
/// INSIDE that call and never surface here); [SnapshotStore.writeSnapshot]
/// is only ever invoked with that complete result, and is itself atomic
/// (review round: never overwrites a working snapshot with partial
/// data). If [capture] throws, this method's own `await` propagates
/// that exception immediately, writeSnapshot is never called at all,
/// and whatever snapshot already existed for this page is left exactly
/// as it was — no explicit catch/rollback needed in this class, because
/// there is nothing here to roll back.
class SnapshotCaptureService {
  SnapshotCaptureService({required this.downloader, required this.store});

  final PageResourceDownloader downloader;
  final SnapshotStore store;

  /// Captures [renderedHtml] (already fetched/rendered — getting that
  /// render is a WebView-integration concern, deliberately not this
  /// class's job; review round: "Nie będę tego łączył z WebView na
  /// skróty") and atomically replaces this (parish, user, page)'s
  /// snapshot with it.
  ///
  /// P10 finding, against the REAL Szarlej installation: [targetPath] —
  /// e.g. `/public/dashboard.php` — is the page's own identity, NEVER
  /// the one-time `mobile_handoff.php?ticket=...` URL the WebView
  /// actually navigated through to reach it (review round: "targetPath
  /// ≠ handoffUrl... obowiązkowo"). [serverBaseUrl] (just the scheme +
  /// host, e.g. `https://szarlej.ministrant.eu`) combined with
  /// [targetPath] reconstructs the real, absolute URL this page is
  /// actually located at, which is what [PageResourceDownloader] needs
  /// to correctly resolve that page's own relative resource references
  /// — resolving them against the handoff script's location instead
  /// would silently produce wrong paths for every relative reference on
  /// the page.
  Future<void> captureAndSave({
    required String parishId,
    required String userId,
    required Uri serverBaseUrl,
    required String targetPath,
    required String renderedHtml,
    int? expectedGeneration,
  }) async {
    final captureGeneration = expectedGeneration ?? store.generation;
    final path = snapshotPagePath(Uri.parse(targetPath));
    if (path == null) return;
    final pageUrl = serverBaseUrl.resolve(path);
    final captured = await downloader.capture(
      pageUrl: pageUrl,
      renderedHtml: renderedHtml,
    );
    await store.writeSnapshot(
      parishId: parishId,
      userId: userId,
      pagePath: path,
      html: captured.html,
      expectedGeneration: captureGeneration,
      assets: captured.assets,
    );
  }
}
