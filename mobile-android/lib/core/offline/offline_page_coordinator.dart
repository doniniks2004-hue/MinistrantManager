import 'package:path/path.dart' as p;

import 'connectivity_probe.dart';
import 'local_snapshot_server.dart';
import 'snapshot_capture_service.dart';
import 'snapshot_store.dart';

/// Offline-architecture milestone, P6. The decision logic connecting
/// every piece built so far (P2-P5) to an actual WebView — deliberately
/// separated from any real `WebViewController` so it can be fully
/// tested without one (webview_flutter has no platform channel in
/// `flutter test`, so anything that genuinely touches a WebViewController
/// cannot be unit-tested here — see the actual WebView screen's own
/// docblock for that honest limit).
///
/// ```
/// ONLINE:  PHP -> WebView -> render -> SnapshotCaptureService -> ... -> SnapshotStore
/// OFFLINE: brak internetu -> LocalSnapshotServer -> 127.0.0.1 -> WebView -> ostatni snapshot
/// ```
class OfflinePageCoordinator {
  OfflinePageCoordinator({
    required this.connectivityProbe,
    required this.captureService,
    required this.snapshotStore,
    required this.localServer,
  });

  final ConnectivityProbe connectivityProbe;
  final SnapshotCaptureService captureService;
  final SnapshotStore snapshotStore;
  final LocalSnapshotServer localServer;

  /// Decides how [pageUrl] should be loaded for (parishId, userId) right
  /// now. Never touches a WebViewController itself — the caller takes
  /// the returned [PageLoadPlan] and performs the actual `loadRequest`
  /// (the one genuinely WebView-specific step left).
  Future<PageLoadPlan> plan({
    required String parishId,
    required String userId,
    required Uri pageUrl,
  }) async {
    final reachable = await connectivityProbe.canReach(pageUrl);
    if (reachable) {
      return PageLoadOnline(url: pageUrl);
    }

    final pagePath = p.normalize(pageUrl.path);
    final manifest = await snapshotStore.readManifestFor(parishId: parishId, userId: userId, pagePath: pagePath);
    if (manifest == null) {
      return const PageLoadOfflineNoSnapshot();
    }

    final pageDir = await snapshotStore.getPageDirectoryIfReady(parishId: parishId, userId: userId, pagePath: pagePath);
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
  /// Fire-and-forget by design: a failed background capture must never
  /// surface to the user or interrupt their online session — the
  /// PREVIOUS snapshot (if any) simply remains as next time's offline
  /// fallback. SnapshotCaptureService's own docblock is why this is
  /// safe to ignore here: all-or-nothing, never a partial snapshot.
  void captureInBackground({
    required String parishId,
    required String userId,
    required Uri pageUrl,
    required String renderedHtml,
  }) {
    () async {
      try {
        await captureService.captureAndSave(
          parishId: parishId,
          userId: userId,
          pageUrl: pageUrl,
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

/// Load [url] for real — the actual PHP page, via the existing handoff
/// mechanism (unchanged by this milestone). The caller should trigger
/// [OfflinePageCoordinator.captureInBackground] once it finishes loading.
class PageLoadOnline extends PageLoadPlan {
  const PageLoadOnline({required this.url});
  final Uri url;
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
