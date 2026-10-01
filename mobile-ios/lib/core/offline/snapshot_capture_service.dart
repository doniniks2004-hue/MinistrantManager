import 'package:path/path.dart' as p;

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

  /// Captures [renderedHtml] (already fetched/rendered from [pageUrl] —
  /// getting that render is a WebView-integration concern, deliberately
  /// not this class's job; review round: "Nie będę tego łączył z
  /// WebView na skróty") and atomically replaces this (parish, user,
  /// page)'s snapshot with it.
  Future<void> captureAndSave({
    required String parishId,
    required String userId,
    required Uri pageUrl,
    required String renderedHtml,
  }) async {
    final captured = await downloader.capture(pageUrl: pageUrl, renderedHtml: renderedHtml);
    await store.writeSnapshot(
      parishId: parishId,
      userId: userId,
      pagePath: _pagePathFor(pageUrl),
      html: captured.html,
      assets: captured.assets,
    );
  }

  /// [SnapshotStore] keys a snapshot by site-relative PATH (review round
  /// layout: `/public/dashboard.php`, never a full URL with scheme/host
  /// baked in — the same page on a parish's http vs https, or reached
  /// via two differently-cased hostnames, is still "the same page" for
  /// snapshotting purposes). Query strings are deliberately dropped too,
  /// matching [PageResourceDownloader]'s own asset-key convention
  /// (`style.css?v=1` and `style.css?v=2` are the same underlying
  /// resource) — a page reached as `/public/dashboard.php?tab=history`
  /// and plain `/public/dashboard.php` share one snapshot slot. If a
  /// real legacy page is ever found where that's actually wrong (the
  /// query string genuinely selects different, worth-caching-separately
  /// content), that's a real product decision to make with Dominik when
  /// such a page is actually identified — not something to guess at
  /// preemptively here.
  String _pagePathFor(Uri pageUrl) => p.normalize(pageUrl.path);
}
