import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'page_identity.dart';

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
    this.onlineTimeout = const Duration(milliseconds: 1500),
    this.offlinePlanTimeout = const Duration(milliseconds: 1500),
  });

  final ConnectivityProbe connectivityProbe;

  /// Budget for the CONNECT phase only: minting the handoff ticket. It
  /// deliberately does NOT cover rendering the PHP page afterwards — the
  /// screen owns a separate, longer budget for that, started only once a
  /// ticket actually exists (a slow-but-working server must not be
  /// mistaken for "no network" just because the ticket took a while).
  final Duration onlineTimeout;

  /// Budget for building the LOCAL view (manifest, directory, starting
  /// the loopback server). Normally a few milliseconds; this exists so a
  /// stuck filesystem/server step can never leave the screen waiting
  /// forever on plan() itself.
  final Duration offlinePlanTimeout;

  /// Bumped at the start of every plan() — "a NEWER plan exists".
  int _planGeneration = 0;
  Future<void> _captureQueue = Future<void>.value();
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
    bool forceOffline = false,
  }) async {
    // A plan that is no longer wanted — superseded by a newer one, OR
    // expired by its own deadline — must never repoint the shared
    // loopback server at ITS page when its (still running) local steps
    // finally finish: LocalSnapshotServer.rootDirectory is ONE mutable
    // slot shared by every load. Future.timeout() only changes the
    // Future the caller sees; it does not stop the async work behind it.
    // The expiry is therefore recorded on THIS plan's own ticket, never
    // on _planGeneration: bumping the shared counter on expiry would let
    // an old timeout invalidate a newer, perfectly healthy plan.
    final ticket = _PlanTicket(++_planGeneration);
    final path = snapshotPagePath(Uri.parse(targetPath));
    if (path == null) return const PageLoadOfflineNoSnapshot();
    String? diagnosticMessage;
    var offlineReason = OfflineReason.noNetwork;
    if (!forceOffline) {
      try {
        final handoffUrl = await handoffService
            .requestHandoffUrl(path)
            .timeout(onlineTimeout);
        return PageLoadOnline(url: handoffUrl, targetPath: path);
      } catch (e) {
        final failure = HandoffFailure.of(e);
        // No URLs, response bodies, tickets, or exception messages.
        if (kDebugMode) {
          diagnosticMessage = e is DioException
              ? 'handoff: ${e.type.name}; HTTP ${e.response?.statusCode ?? "none"}'
              : 'handoff: ${e.runtimeType}';
          debugPrint(diagnosticMessage);
        }
        if (failure.kind == HandoffFailureKind.rejected) {
          // The server ANSWERED and said no. That is not "no network":
          // falling back to a snapshot under an OFFLINE banner would tell
          // the user their connection is broken when it is working, and
          // would hide a problem (a rejected path, an expired session)
          // that retrying the snapshot can never fix.
          return PageLoadServerError(
            statusCode: failure.statusCode,
            errorCode: failure.errorCode,
            path: Uri.parse(path).path,
            hasSnapshot: await _hasSnapshot(parishId, userId, path),
          );
        }
        if (failure.kind == HandoffFailureKind.serverUnavailable) {
          offlineReason = OfflineReason.serverUnavailable;
        }
      }
    }

    return _planOffline(
      reason: offlineReason,
      ticket: ticket,
      parishId: parishId,
      userId: userId,
      path: path,
      diagnosticMessage: diagnosticMessage,
    ).timeout(
      offlinePlanTimeout,
      onTimeout: () {
        ticket.expired = true;
        return PageLoadOfflineNoSnapshot(
          diagnosticMessage: kDebugMode ? 'offline plan timed out' : null,
        );
      },
    );
  }

  bool _isStale(_PlanTicket ticket) =>
      ticket.expired || ticket.generation != _planGeneration;

  final _probes = <String, Future<OnlineProbeResult>>{};

  /// Asks, in the background, whether the server can be reached again and
  /// will open [targetPath]: it requests a handoff ticket, which is both the
  /// reachability check and the way into the page, so a success needs no
  /// second request. Used by the screen while it is showing a saved copy.
  ///
  /// At most ONE request per path is ever in flight: a call made while one
  /// is pending gets that same result instead of starting another, so the
  /// retry loop can never pile up parallel requests however it is driven.
  /// [timeout] is longer than the one used to open a page — nobody is
  /// waiting here, and it is what lets a slow server be recognised as
  /// reachable instead of being mistaken for no network.
  Future<OnlineProbeResult> probeOnline({
    required String parishId,
    required String userId,
    required String targetPath,
    Duration timeout = const Duration(seconds: 6),
  }) {
    final path = snapshotPagePath(Uri.parse(targetPath));
    if (path == null) {
      return Future.value(const OnlineProbeUnavailable());
    }
    return _probes[path] ??= _probe(parishId, userId, path, timeout)
        // Block body on purpose: whenComplete WAITS for a Future returned
        // by its callback, and Map.remove would return this very Future.
        .whenComplete(() {
      _probes.remove(path);
    });
  }

  Future<OnlineProbeResult> _probe(
    String parishId,
    String userId,
    String path,
    Duration timeout,
  ) async {
    try {
      final url = await handoffService
          .requestHandoffUrl(path, timeout: timeout)
          .timeout(timeout + const Duration(milliseconds: 500));
      return OnlineProbeRecovered(PageLoadOnline(url: url, targetPath: path));
    } catch (e) {
      final failure = HandoffFailure.of(e);
      if (failure.kind == HandoffFailureKind.rejected) {
        return OnlineProbeRejected(
          PageLoadServerError(
            statusCode: failure.statusCode,
            errorCode: failure.errorCode,
            path: Uri.parse(path).path,
            hasSnapshot: await _hasSnapshot(parishId, userId, path),
          ),
        );
      }
      // No answer, or a transient server problem: try again later.
      return const OnlineProbeUnavailable();
    }
  }

  Future<bool> _hasSnapshot(String parishId, String userId, String path) async {
    try {
      final manifest = await snapshotStore
          .readManifestFor(parishId: parishId, userId: userId, pagePath: path)
          .timeout(offlinePlanTimeout);
      return manifest != null;
    } catch (_) {
      return false;
    }
  }

  Future<PageLoadPlan> _planOffline({
    required OfflineReason reason,
    required _PlanTicket ticket,
    required String parishId,
    required String userId,
    required String path,
    required String? diagnosticMessage,
  }) async {
    final manifest = await snapshotStore.readManifestFor(
      parishId: parishId,
      userId: userId,
      pagePath: path,
    );
    if (manifest == null || _isStale(ticket)) {
      return PageLoadOfflineNoSnapshot(diagnosticMessage: diagnosticMessage);
    }

    final pageDir = await snapshotStore.getPageDirectoryIfReady(
      parishId: parishId,
      userId: userId,
      pagePath: path,
    );
    if (pageDir == null || _isStale(ticket)) {
      // A manifest existed a moment ago but the directory is gone now
      // (e.g. a concurrent clearForUser/clearForParish mid-check) —
      // treat exactly like "no snapshot", never crash on the race.
      return PageLoadOfflineNoSnapshot(diagnosticMessage: diagnosticMessage);
    }

    await localServer.start();
    // Re-checked after the LAST await, immediately before the one
    // assignment that has a side effect outside this plan.
    if (_isStale(ticket)) {
      return PageLoadOfflineNoSnapshot(diagnosticMessage: diagnosticMessage);
    }
    localServer.rootDirectory = pageDir;

    // Each assignment of rootDirectory above rotates LocalSnapshotServer's
    // access token, which is part of this URL's path — so every offline
    // plan already has its own document URL, and the previous plan's URL
    // stops being "owned" by the server. The screen relies on that.
    return PageLoadOffline(
      url: localServer.urlFor('/snapshot.html'),
      capturedAt: manifest.capturedAt,
      reason: reason,
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
    final generation = snapshotStore.generation;
    _captureQueue = _captureQueue.then((_) async {
      try {
        if (snapshotStore.generation != generation) return;
        final serverUrlString = await handoffService.secureStorage.serverUrl;
        if (serverUrlString == null) return;
        await captureService.captureAndSave(
          parishId: parishId,
          userId: userId,
          serverBaseUrl: Uri.parse(serverUrlString),
          targetPath: targetPath,
          renderedHtml: renderedHtml,
          expectedGeneration: generation,
        );
      } catch (_) {
        // A failed capture leaves the previous snapshot intact.
      }
    });
  }
}

/// Identity of ONE plan() call. [generation] is its position in the
/// sequence of plans; [expired] is set only by this plan's own deadline.
class _PlanTicket {
  _PlanTicket(this.generation);
  final int generation;
  bool expired = false;
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
  const PageLoadOffline({
    required this.url,
    required this.capturedAt,
    this.reason = OfflineReason.noNetwork,
  });
  final Uri url;
  final DateTime capturedAt;

  /// Why a snapshot is shown instead of the live page — drives the banner
  /// wording, so a server outage is not reported as "no network".
  final OfflineReason reason;
}

enum OfflineReason {
  /// The request never got an answer (no connection, DNS, timeout).
  noNetwork,

  /// The server answered with a transient failure (5xx, 408, 429).
  serverUnavailable,
}

/// The server answered the handoff and refused it for a reason a snapshot
/// cannot fix (4xx other than 408/429, or a reply that is not a handoff
/// reply at all). Carries ONLY sanitized facts, safe to show on screen in a
/// release build: the HTTP status, the server's short machine error code
/// if it has the expected shape, and the page path without its query.
/// Never a response body, message, URL, ticket or token.
class PageLoadServerError extends PageLoadPlan {
  const PageLoadServerError({
    required this.statusCode,
    required this.errorCode,
    required this.path,
    required this.hasSnapshot,
  });

  /// Null when the reply was not an HTTP error at all but was unusable.
  final int? statusCode;
  final String? errorCode;
  final String path;

  /// A saved copy of this exact page exists, so the screen can offer it
  /// explicitly instead of silently pretending to be offline.
  final bool hasSnapshot;
}

/// Outcome of [OfflinePageCoordinator.probeOnline].
sealed class OnlineProbeResult {
  const OnlineProbeResult();
}

/// The server answered and issued a ticket: [plan] opens the page online.
class OnlineProbeRecovered extends OnlineProbeResult {
  const OnlineProbeRecovered(this.plan);
  final PageLoadOnline plan;
}

/// No usable answer (no network, timeout, transient server problem). The
/// caller should try again later; nothing here says the user did anything
/// wrong.
class OnlineProbeUnavailable extends OnlineProbeResult {
  const OnlineProbeUnavailable();
}

/// The server answered and refused. Retrying will not change that, so the
/// caller should stop and say so, not keep asking.
class OnlineProbeRejected extends OnlineProbeResult {
  const OnlineProbeRejected(this.error);
  final PageLoadServerError error;
}

enum HandoffFailureKind {
  /// No answer from the server: connection, DNS, TLS, timeout, or a local
  /// precondition (e.g. not activated). Falling back to a snapshot is right.
  transport,

  /// The server answered with a transient failure (5xx, 408, 429).
  serverUnavailable,

  /// The server answered and refused, or answered something unusable.
  rejected,
}

class HandoffFailure {
  const HandoffFailure._(this.kind, this.statusCode, this.errorCode);

  final HandoffFailureKind kind;
  final int? statusCode;
  final String? errorCode;

  static final _codeShape = RegExp(r'^[a-z][a-z0-9_]{0,47}$');

  /// Sorts any error thrown by the handoff request into what it means for
  /// the user. [error] is whatever requestHandoffUrl threw.
  static HandoffFailure of(Object error) {
    if (error is DioException) {
      final response = error.response;
      if (response == null) {
        return const HandoffFailure._(HandoffFailureKind.transport, null, null);
      }
      final status = response.statusCode;
      final data = response.data;
      final raw = data is Map ? data['error'] : null;
      // Only a short machine code is kept; anything else the server sent
      // (a message, markup, a longer string) is dropped.
      final code = raw is String && _codeShape.hasMatch(raw) ? raw : null;
      final transient =
          status == null || status >= 500 || status == 408 || status == 429;
      return HandoffFailure._(
        transient
            ? HandoffFailureKind.serverUnavailable
            : HandoffFailureKind.rejected,
        status,
        code,
      );
    }
    // The request returned, but not a handoff reply (e.g. an HTML page
    // where JSON was expected): the server answered, so this is not the
    // network, and a saved copy will not make it go away. ONLY the
    // FormatException the handoff service raises for exactly this case
    // counts; a TypeError or NoSuchMethodError is a defect in this app and
    // must not be presented to the user as the server's refusal.
    if (error is FormatException) {
      return const HandoffFailure._(
        HandoffFailureKind.rejected,
        null,
        'invalid_response',
      );
    }
    return const HandoffFailure._(HandoffFailureKind.transport, null, null);
  }
}

/// Offline AND no snapshot exists yet for this exact page — the caller
/// should show an explanatory empty state rather than attempting to
/// load anything.
class PageLoadOfflineNoSnapshot extends PageLoadPlan {
  const PageLoadOfflineNoSnapshot({this.diagnosticMessage});

  /// K12 diagnostic round 3: why the online attempt (if one was even
  /// made) failed — null when this page was never actually attempted
  /// online at all (shouldn't normally happen given plan() always tries
  /// the handoff first, but kept nullable rather than assuming). Shown
  /// directly on screen by the caller, specifically so this doesn't
  /// depend on logcat being readable on the real device at all.
  final String? diagnosticMessage;
}

/// "OFFLINE • ostatnia synchronizacja: HH:MM" — review round P7: "Jedyny
/// dodatkowy element aplikacji" beyond the real PHP page itself. Local
/// time, zero-padded, nothing more elaborate — this is explicitly NOT a
/// redesign of anything, just the one allowed banner line.
String formatOfflineBannerText(
  DateTime capturedAt, {
  OfflineReason reason = OfflineReason.noNetwork,
}) {
  final local = capturedAt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  final label = reason == OfflineReason.serverUnavailable
      ? 'SERWER NIEDOSTĘPNY'
      : 'OFFLINE';
  return '$label • ostatnia synchronizacja: $hh:$mm';
}
