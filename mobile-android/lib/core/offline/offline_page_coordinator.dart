import 'package:path/path.dart' as p;

import '../../features/webview/webview_handoff_service.dart';
import 'connectivity_probe.dart';
import 'local_snapshot_server.dart';
import 'snapshot_capture_service.dart';
import 'snapshot_store.dart';

/// Offline-architecture milestone, P6 (P10 fix: targetPath/handoffUrl
/// separation). The decision logic connecting every piece built so far
/// (P2-P5) to an actual WebView — deliberately separated from any real
/// `WebViewController` so it can be fully tested without one
/// (webview_flutter has no platform channel in `flutter test`, so
/// anything that genuinely touches a WebViewController cannot be
/// unit-tested here — see the actual WebView screen's own docblock for
/// that honest limit).
///
/// ```
/// ONLINE:  PHP -> WebView -> render -> SnapshotCaptureService -> ... -> SnapshotStore
/// OFFLINE: brak internetu -> LocalSnapshotServer -> 127.0.0.1 -> WebView -> ostatni snapshot
/// ```
///
/// P10 finding, against the REAL Szarlej installation: a WebView never
/// navigates to a legacy page's own path directly — `mobile_handoff.php`
/// mints a short-lived, single-use ticket and the PHP side 302-redirects
/// from there to the real target. [PageLoadOnline] therefore carries TWO
/// separate things, deliberately never conflated: [PageLoadOnline.url]
/// (the one-time handoff URL, for navigation ONLY) and
/// [PageLoadOnline.targetPath] (the page's actual identity — e.g.
/// `/public/dashboard.php` — used for the offline snapshot key AND as
/// the base for resolving that page's own relative resource references,
/// which would resolve to the wrong thing entirely if based on
/// mobile_handoff.php's own location instead).
class OfflinePageCoordinator {
  OfflinePageCoordinator({
    required this.connectivityProbe,
    required this.captureService,
    required this.snapshotStore,
    required this.localServer,
    required this.handoffService,
  });

  final ConnectivityProbe connectivityProbe;
  final SnapshotCaptureService captureService;
  final SnapshotStore snapshotStore;
  final LocalSnapshotServer localServer;

  /// Mints the one-time handoff URL for the online branch — the SAME
  /// service LegacyModuleScreen already uses, so there is exactly one
  /// way this app ever asks the server for a ticket.
  final WebviewHandoffService handoffService;

  /// Decides how [targetPath] (e.g. `/public/dashboard.php` — the
  /// page's own identity, NEVER a handoff URL) should be loaded for
  /// (parishId, userId) right now. Never touches a WebViewController
  /// itself — the caller takes the returned [PageLoadPlan] and performs
  /// the actual `loadRequest` (the one genuinely WebView-specific step
  /// left).
  Future<PageLoadPlan> plan({
    required String parishId,
    required String userId,
    required String targetPath,
  }) async {
    final path = p.normalize(targetPath);

    // The authenticated handoff request is the real online test. Do not
    // perform a separate unauthenticated HEAD first: that creates a second
    // network dependency and can reject a server that is perfectly capable
    // of serving the actual mobile handoff. If the real request succeeds,
    // the WebView gets the real PHP page immediately.
    try {
      final handoffUrl = await handoffService.requestHandoffUrl(path);
      return PageLoadOnline(url: handoffUrl, targetPath: path);
    } catch (_) {
      // Real online handoff failed. Fall through to the last known-good
      // snapshot. This is the only offline decision that matters to the UI.
    }

    final manifest = await snapshotStore.readManifestFor(parishId: parishId, userId: userId, pagePath: path);
    if (manifest == null) {
      return const PageLoadOfflineNoSnapshot();
    }

    final pageDir = await snapshotStore.getPageDirectoryIfReady(parishId: parishId, userId: userId, pagePath: path);
    if (pageDir == null) {
      // A manifest existed a moment ago but the directory is gone now
      // (e.g. a concurrent clearForUser/clearForParish mid-check) —
      // treat exactly like "no snapshot", never crash on the race.
      return const PageLoadOfflineNoSnapshot();
    }

    final port = await localServer.start();
    localServer.rootDirectory = pageDir;

    return PageLoadOffline(
      url: Uri.parse('http://127.0.0.1:$port/snapshot.html'),
      capturedAt: manifest.capturedAt,
    );
  }

  /// Called once an ONLINE page has finished rendering (the caller gets
  /// [renderedHtml] from the WebView itself — see this coordinator's own
  /// docblock on why that extraction step lives outside this class).
  /// [targetPath] is the SAME page identity [plan] returned in
  /// [PageLoadOnline.targetPath] — never the handoff URL the WebView
  /// actually navigated to, which SnapshotCaptureService itself
  /// re-derives into a real, absolute URL (server base + targetPath) for
  /// resolving the page's own relative resource references correctly.
  /// Fire-and-forget by design: a failed background capture must never
  /// surface to the user or interrupt their online session — the
  /// PREVIOUS snapshot (if any) simply remains as next time's offline
  /// fallback. SnapshotCaptureService's own docblock is why this is
  /// safe to ignore here: all-or-nothing, never a partial snapshot.
  void captureInBackground({
    required String parishId,
    required String userId,
    required String targetPath,
    required String renderedHtml,
  }) {
    () async {
      try {
        final serverUrlString = await handoffService.secureStorage.serverUrl;
        if (serverUrlString == null) return;
        await captureService.captureAndSave(
          parishId: parishId,
          userId: userId,
          serverBaseUrl: Uri.parse(serverUrlString),
          targetPath: targetPath,
          renderedHtml: renderedHtml,
        );
      } catch (_) {
        // Best-effort — see this method's own docblock.
      }
    }();
  }
}

/// What [OfflinePageCoordinator.plan] decided — a sealed hierarchy
/// matching this project's existing UserLoginResult pattern, rather
/// than one class with fields that only make sense for some variants.
sealed class PageLoadPlan {
  const PageLoadPlan();
}

/// Load [url] — a one-time handoff URL, for navigation ONLY (P10: never
/// store it, never resolve resources against it — see this file's own
/// class-level docblock for why). [targetPath] is the page's real
/// identity; the caller passes THIS to
/// [OfflinePageCoordinator.captureInBackground] once the page finishes
/// loading, never [url].
class PageLoadOnline extends PageLoadPlan {
  const PageLoadOnline({required this.url, required this.targetPath});
  final Uri url;
  final String targetPath;
}

/// Load [url] — a `LocalSnapshotServer` URL already pointed at the
/// right (parish, user, page) snapshot directory; [capturedAt] is for
/// the "OFFLINE • ostatnia synchronizacja: HH:MM" banner.
class PageLoadOffline extends PageLoadPlan {
  const PageLoadOffline({required this.url, required this.capturedAt});
  final Uri url;
  final DateTime capturedAt;
}

/// Offline AND no snapshot exists yet for this exact page — the caller
/// should show an explanatory empty state rather than attempting to
/// load anything.
class PageLoadOfflineNoSnapshot extends PageLoadPlan {
  const PageLoadOfflineNoSnapshot();
}

/// "OFFLINE • ostatnia synchronizacja: HH:MM" — review round P7: "Jedyny
/// dodatkowy element aplikacji" beyond the real PHP page itself. Local
/// time, zero-padded, nothing more elaborate — this is explicitly NOT a
/// redesign of anything, just the one allowed banner line.
String formatOfflineBannerText(DateTime capturedAt) {
  final local = capturedAt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return 'OFFLINE • ostatnia synchronizacja: $hh:$mm';
}
