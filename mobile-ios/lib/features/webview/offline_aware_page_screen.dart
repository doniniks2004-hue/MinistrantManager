import 'dart:async';
import 'dart:convert';
import 'dart:io' show pid;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/util/startup_trace.dart';
import '../../core/offline/offline_page_coordinator.dart';
import '../../core/offline/connectivity_monitor.dart';
import '../../core/offline/page_identity.dart';
import '../../core/offline/panel_probe.dart';
import '../../core/security/access_refusals.dart' show HandoffRefusal;
import '../../core/offline/server_reachability.dart';
import '../../core/util/log_safe.dart';

/// Hosts the real PHP page. Offline replays saved views, without writes.
class OfflineAwarePageScreen extends StatefulWidget {
  const OfflineAwarePageScreen({
    super.key,
    required this.title,
    required this.targetPath,
    required this.allowedHost,
    required this.parishId,
    required this.userId,
    required this.coordinator,
    this.onLogout,
    this.forceOffline = false,
    this.panelSpec,
  });
  final String title;
  final String targetPath;
  final String allowedHost;
  final String parishId;
  final String userId;
  final OfflinePageCoordinator coordinator;
  final Future<void> Function()? onLogout;
  final bool forceOffline;

  /// What the real panel is (see PanelSpec). Null: the one the build was made with
  /// (`--dart-define=MM_PANEL_SPEC`), if any. Tests pass one in.
  final PanelSpec? panelSpec;
  @override
  State<OfflineAwarePageScreen> createState() => _OfflineAwarePageScreenState();
}

enum _LoadState { loading, ready, error, noSnapshot }

/// What the user sees when the server refused to open a page. Built only
/// from the sanitized fields of [PageLoadServerError]. The second line is
/// for whoever is helping the user: status, the server's machine code, and
/// the page path (no query, no ids).
String describeServerError(PageLoadServerError e) {
  final lead = e.staleParishAnswer
      ? 'Serwer parafii odmówił autoryzacji urządzenia, ale centrala ją potwierdza.\n'
          'Odpowiedź parafii może być nieaktualna (do 10 minut). Spróbuj ponownie za chwilę.'
      : switch (e.refusal) {
    HandoffRefusal.unknown =>
        'Nie można ustalić, czy dostęp do zapisanych stron jest zablokowany '
            '(nie udało się odczytać zapisu na urządzeniu).\n'
            'Zapisane strony nie są otwierane. Dane nie zostały usunięte. Spróbuj ponownie.',
    HandoffRefusal.module => e.remembered
        ? 'Brak uprawnień do tego modułu (odmowa zapamiętana z poprzedniego połączenia).\n'
            'Zapisana kopia jest zablokowana, dopóki serwer nie potwierdzi uprawnień.'
        : 'Brak uprawnień do tego modułu.\nZapisana kopia jest zablokowana, dopóki serwer nie potwierdzi uprawnień.',
    HandoffRefusal.device => e.remembered
        ? 'Serwer odmówił autoryzacji tego urządzenia (odmowa zapamiętana z poprzedniego połączenia).\n'
            'Zapisane strony są zablokowane, dopóki serwer nie potwierdzi urządzenia.'
        : 'Serwer odmówił autoryzacji tego urządzenia.\nZapisane strony są zablokowane, dopóki serwer nie potwierdzi urządzenia.',
    _ => switch (e.statusCode) {
        401 => 'Sesja wygasła lub została odrzucona przez serwer.',
        403 => 'Serwer odmówił dostępu do tej strony.',
        _ => 'Połączenie z serwerem działa, ale serwer nie otworzył tej strony.',
      },
  };
  final detail = [
    if (e.statusCode != null) 'HTTP ${e.statusCode}',
    if (e.errorCode != null) e.errorCode!,
    if (e.deviceState != null) e.deviceState!,
    e.path,
  ].join(' · ');
  return '$lead\n$detail';
}

class _OfflineAwarePageScreenState extends State<OfflineAwarePageScreen>
    with WidgetsBindingObserver {
  static const _captureChannel = 'MMPageCapture';
  static const _bridgeChannel = 'MinistrantBridge';
  static const _paintChannel = 'MM_Paint';
  static const _bridgeShim = '''
(function() {
  if (!window.MinistrantBridge || window.MinistrantBridge.__mmShimmed) return;
  var raw = window.MinistrantBridge;
  window.MinistrantBridge = {
    __mmShimmed: true,
    debugPing: function() {}, onScroll: function() {},
    saveRememberToken: function(token) {
      raw.postMessage(JSON.stringify({type: 'remember_token', token: token}));
    }
  };
})();
''';
  /// Budget for a PHP page to finish rendering ONCE a handoff ticket
  /// exists (and for later in-session navigations). Deliberately separate
  /// from — and much longer than — the connect budget in
  /// OfflinePageCoordinator.onlineTimeout: that one answers "is there a
  /// working connection at all" and must stay short so a truly offline
  /// phone reaches its saved view fast; this one only decides when a
  /// reachable-but-slow page is given up on. Before they were split, one
  /// 1.5 s timer started BEFORE the ticket request and also covered the
  /// page load, so a ticket that took 1.4 s left the page ~100 ms.
  /// Tunable — verify on a real device on a slow mobile connection.
  static const _pageRenderBudget = Duration(seconds: 8);

  /// How long the saved copy may take to appear once the app has DECIDED to
  /// show it, i.e. from the moment planning says "offline". A failure
  /// detector, not a target: a loopback page normally renders in well under
  /// a second.
  ///
  /// It is counted from that decision and NOT from the start of the load. It
  /// used to run from the start, so it also covered the attempt to reach the
  /// server: when the system had not yet noticed the network was gone, that
  /// attempt ran to its own 1.5 s limit and left ~0.5 s for the first,
  /// cold, opening of the copy (server start, decryption, WebView). The
  /// timer then expired, the error appeared, and the copy that was in fact
  /// still loading was ignored; only a manual refresh, when the dead network
  /// failed instantly, left enough time. Reaching the server is bounded by
  /// OfflinePageCoordinator.onlineTimeout; this bounds showing the copy.
  static const _offlineTotalBudget = Duration(seconds: 2);

  // Planning is guarded by OfflinePageCoordinator.planningBudget (the longest it
  // can legitimately take), replaced by [_offlineTotalBudget] as soon as planning
  // decides to show the saved copy.

  /// How often an idle live page checks that the server can still be
  /// reached, and how soon a doubtful result is checked again.
  static const _heartbeatInterval = Duration(milliseconds: 1500);
  static const _heartbeatConfirmDelay = Duration(milliseconds: 400);

  /// How long the page may take to say whether a field was edited.
  static const _unsavedInputCheckLimit = Duration(milliseconds: 800);

  /// True from the moment a handoff ticket is in hand (PageLoadOnline) —
  /// from then on [_offlineTotalBudget] no longer applies.
  bool _onlineRendering = false;
  Timer? _totalDeadline;

  /// The loopback document the screen is CURRENTLY waiting for or showing
  /// — null whenever no offline navigation is current (a new load began,
  /// the load was abandoned by its deadline, or it failed). Callbacks for
  /// anything else are stale: the engine keeps running a navigation the
  /// screen has given up on, and its onPageFinished arrives later.
  /// _loadGeneration cannot guard that (callbacks carry no generation), so
  /// the navigation is identified by its URL instead. Every offline plan
  /// has its own: LocalSnapshotServer rotates its access token, which is
  /// part of the URL path, on each rootDirectory assignment. That alone is
  /// not enough — an abandoned load whose plan was never replaced keeps a
  /// URL the server still owns, which is exactly the late callback this
  /// field exists to reject.
  Uri? _offlineLoadUrl;

  bool _isCurrentOfflineDocument(Uri uri) {
    final current = _offlineLoadUrl;
    // Scheme/host/port/token prefix are checked by LocalSnapshotServer.ownsUrl.
    return current != null &&
        uri.path == current.path &&
        uri.query == current.query;
  }

  late final WebViewController _controller;
  _LoadState _state = _LoadState.loading;
  String? _errorText;

  /// Set while the error state on screen is "the server answered and
  /// refused" (as opposed to a local failure). Drives the extra actions and
  /// the icon: a Wi-Fi-off icon over a message about a working connection
  /// would contradict itself.
  PageLoadServerError? _serverError;

  // ---- automatic return to the live page ---------------------------------
  //
  // While a saved copy is shown because the server could not be reached (or
  // answered with a transient failure), the screen asks again in the
  // background with growing delays, and when the server answers it switches
  // to the live page itself. Every async step is tied to [_loadGeneration]:
  // a new load, a logout and dispose all bump it, so a late answer for a
  // load that is no longer the current one can neither switch the page nor
  // reschedule anything on its behalf.

  /// Delay before attempt N (the last value repeats). Growing, so a server
  /// that answers but keeps failing the page cannot make the screen flap
  /// between modes every couple of seconds.
  static const _recoveryBackoff = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  /// Longer than the limit used to open a page: nobody is waiting here, and
  /// it is what tells a slow server (answers within this) from a missing one.
  static const _probeTimeout = Duration(seconds: 6);

  Timer? _recoveryTimer;
  bool _recoveryInFlight = false;

  /// Attempts since the live page last loaded successfully — NOT since the
  /// last fallback. Resetting it per fallback would let "ticket works, page
  /// fails, fall back" repeat every 2 s indefinitely.
  int _recoveryAttempts = 0;

  /// The current load ended on a saved copy (or "no copy") for a reason that
  /// can go away. False for an auth-driven offline state
  /// ([OfflineAwarePageScreen.forceOffline]) and after the server refused.
  bool _recoverable = false;
  bool _appInBackground = false;

  /// Why the saved copy on screen is shown (drives the banner wording).
  /// Carried across offline link taps so they do not reset it.
  OfflineReason _offlineReason = OfflineReason.noNetwork;

  /// Why the last load ended with no saved copy and no live page: decides what the
  /// screen says (no connection, a server that does not answer, a slow server).
  OfflineReason _noSnapshotReason = OfflineReason.noNetwork;

  // ---- which ONLINE navigation a callback belongs to ------------------------
  //
  // The engine reports starts, finishes and errors without saying which
  // navigation they are about, and may report them late. A navigation that was
  // REPLACED by a newer one before it finished is remembered here, and what
  // arrives for it afterwards is ignored. A redirect is not a replaced
  // navigation (its target never had a start of its own to be replaced), so
  // it still goes through: ignoring it would leave the page loading forever.

  /// The page whose navigation started most recently, and whether it has
  /// finished.
  String? _lastStartedPath;
  bool _lastStartedFinished = true;

  /// Pages whose navigation was replaced before it finished.
  final _supersededPaths = <String>{};

  // ---- navigation diagnostics ---------------------------------------------------
  //
  // One id per load attempt and the time since it began, on every line, so that
  // a log can be read as a story: which load, what the engine reported, what was
  // ignored and why, and what ended it. Debug builds only (the coordinator's
  // trace); changes no behaviour.

  int _navId = 0;
  final _navWatch = Stopwatch();

  void _tr(String message) {
    widget.coordinator.trace('nav#$_navId +${_navWatch.elapsedMilliseconds}ms $message');
  }

  /// Why a finished/started address is, or is not, the document this screen is
  /// waiting for, without printing the token.
  String _whyNotCurrent(Uri uri) {
    final server = widget.coordinator.localServer;
    if (!_online) {
      return 'owns=${server.ownsUrl(uri)} '
          'pathMatches=${_offlineLoadUrl != null && uri.path == _offlineLoadUrl!.path} '
          'queryMatches=${_offlineLoadUrl != null && uri.query == _offlineLoadUrl!.query} '
          'expecting=${describeUrlForLog(_offlineLoadUrl?.toString())}';
    }
    return 'trusted=${_trusted(uri)}';
  }

  /// Automatic retries of a FAILED first opening of the saved copy. The
  /// first opening is cold (server just started, nothing cached) and the
  /// second, with the same data, worked every time a person tried it, so
  /// one retry is made without waiting for a tap. One only: a copy that
  /// fails twice is reported.
  int _offlineAutoRetries = 0;

  /// The loopback document's navigation has actually begun. An error that
  /// reports no address and arrives before this is the abandoned live
  /// navigation's, not this one's.
  bool _offlineDocStarted = false;

  // ---- what the operating system says about the connection ----------------
  StreamSubscription<ConnectivityEvent>? _connectivitySub;

  /// Running from the moment a loss of connection was reported until the
  /// saved copy is visible (debug log only).
  Stopwatch? _lossWatch;

  // ---- noticing a lost connection on an idle live page --------------------
  Timer? _heartbeat;
  bool _heartbeatInFlight = false;
  int _heartbeatMisses = 0;
  bool _connectionLostDeferred = false;
  OfflineReason _lostReason = OfflineReason.noNetwork;

  /// Times in a row the PHP session was found expired and silently renewed.
  /// One renewal per expiry; a second login page right after it means the
  /// renewal did not help, and only then is the user signed out.
  int _sessionRenewals = 0;

  /// The server is reachable again but the page holds input the user has not
  /// saved, so the screen did not switch by itself.
  bool _onlineAvailableDeferred = false;

  /// Set when the server answered a recovery attempt with a refusal.
  String? _recoveryRejection;
  bool _online = true;
  bool _loggingOut = false;
  String? _banner;
  late String _currentPath;
  Timer? _navigationDeadline;
  Timer? _captureTimer;
  int _loadGeneration = 0;
  String? _afterHandoffPath;
  final Set<String> _failedDocuments = {};

  @override
  void initState() {
    super.initState();
    StartupTrace.mark('screen_init');
    _currentPath = widget.targetPath;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(_captureChannel, onMessageReceived: _onCapture)
      ..addJavaScriptChannel(_bridgeChannel, onMessageReceived: _onBridge)
      ..addJavaScriptChannel(_paintChannel, onMessageReceived: _onPaint)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: _onStarted,
          onHttpError: (error) {
            final uri = error.request?.uri;
            if (!mounted || _loggingOut || uri == null) return;
            _tr(
              'http-error status=${error.response?.statusCode} ${describeUrlForLog(uri.toString())} '
              'mode=${_online ? 'live' : 'copy'}',
            );
            if (!_online) {
              // LocalSnapshotServer answers 5xx when a stored file cannot
              // be decrypted (corrupt cache / lost key). Without this the
              // WebView just renders an empty error body and the screen
              // reports "ready" over a blank page.
              if (_state == _LoadState.loading &&
                  widget.coordinator.localServer.ownsUrl(uri) &&
                  uri.path.endsWith('/snapshot.html') &&
                  _isCurrentOfflineDocument(uri)) {
                _offlineLoadUrl = null;
                _navigationDeadline?.cancel();
                _navigationDeadline = null;
                _totalDeadline?.cancel();
                _totalDeadline = null;
                _failedDocuments.add(uri.toString());
                if (_retryOfflineOnce()) return;
                setState(() {
                  _state = _LoadState.error;
                  _errorText =
                      'Zapisana kopia strony jest uszkodzona. Otwórz ją ponownie przy połączeniu z internetem.';
                });
              }
              return;
            }
            if (!_trusted(uri)) return;
            final path = snapshotPagePath(uri);
            if (path != _currentPath &&
                uri.path != '/public/mobile_handoff.php')
              return;
            _failedDocuments.add(uri.toString());
            final status = error.response?.statusCode;
            if (status != null &&
                status >= 400 &&
                status < 500 &&
                status != 408 &&
                status != 429) {
              // The server ANSWERED and refused this page (no permission,
              // gone, bad request). Not a server problem and not "offline":
              // saying so, and hiding the real cause behind a saved copy,
              // is exactly the false OFFLINE this must not produce.
              unawaited(_showPageRefusal(uri, status));
            } else {
              unawaited(
                _loadPage(
                  forceOffline: true,
                  offlineReason: OfflineReason.serverUnavailable,
                ),
              );
            }
          },
          onPageFinished: _onFinished,
          onWebResourceError: (e) {
            if (!mounted || _loggingOut) return;
            // Every failure the engine reports, including those of sub-resources
            // (which used to be dropped without a word): a stylesheet or an image
            // of the saved copy that fails is exactly what a log must show.
            _tr(
              'resource-error code=${e.errorCode} type=${e.errorType?.name} main=${e.isForMainFrame} '
              '${describeUrlForLog(e.url)} mode=${_online ? 'live' : 'copy'}',
            );
            if (e.isForMainFrame != true) return;
            if (!_online) {
              // An error for a navigation that is no longer the current
              // one (abandoned, or replaced by a retry) must not fail the
              // load that IS current.
              final failed = e.url == null ? null : Uri.tryParse(e.url!);
              if (_offlineLoadUrl == null) return;
              if (failed != null) {
                if (!_isCurrentOfflineDocument(failed)) return;
              } else if (!_offlineDocStarted) {
                // An error that names no address and comes before OUR
                // document even started belongs to the live navigation that
                // was just abandoned (its failure is what sent us offline).
                return;
              }
            }
            if (_online) {
              // Only the failure of the CURRENT live navigation counts.
              final failed = e.url == null ? null : Uri.tryParse(e.url!);
              if (failed != null) {
                // An address that is not this host over https is not a live
                // page: typically the old saved copy (localhost) whose error
                // arrives after the switch back online. Treating it as a
                // lost connection sent the screen back to the copy.
                if (!_trusted(failed)) return;
                final failedPath = snapshotPagePath(failed);
                if (failedPath != null && _supersededPaths.contains(failedPath)) {
                  return; // a navigation that was already replaced
                }
              }
            }
            _navigationDeadline?.cancel();
            _totalDeadline?.cancel();
            _totalDeadline = null;
            if (_online) {
              // A genuine failure to connect: not the "slow page" or
              // "server error" an earlier fallback may have been.
              unawaited(
                _loadPage(
                  forceOffline: true,
                  offlineReason: OfflineReason.noNetwork,
                ),
              );
            } else {
              _offlineLoadUrl = null;
              if (_retryOfflineOnce()) return;
              setState(() {
                _state = _LoadState.error;
                _errorText = 'Nie udało się otworzyć zapisanej kopii strony.';
              });
            }
          },
          onNavigationRequest: _navigate,
        ),
      );
    WidgetsBinding.instance.addObserver(this);
    // Before the first plan: the loopback server must already be listening
    // when the first fallback needs it. Not awaited, never fails.
    unawaited(widget.coordinator.warmUp());
    // While the live page loads (the phone is idle and online) decrypt the saved
    // copy of this page, so that if the connection is lost soon after a cold
    // start, opening it costs nothing.
    unawaited(
      widget.coordinator.prewarmPage(
        parishId: widget.parishId,
        userId: widget.userId,
        pagePath: widget.targetPath,
      ),
    );
    unawaited(_hideScrollBars());
    widget.coordinator.connectivity.start();
    _connectivitySub = widget.coordinator.connectivity.events.listen(
      _onConnectivity,
    );
    unawaited(_firstLoad());
  }

  Future<void> _loadRequestTraced(Uri url) {
    StartupTrace.mark('load_request');
    _tr('loadRequest ${describeUrlForLog(url.toString())} mode=${_online ? 'live' : 'copy'}');
    return _controller.loadRequest(url);
  }

  /// What the screen says when there is no saved copy and the live page could not
  /// be had. The three causes are different things for the user: no connection
  /// (go somewhere with one), a server that is down or slow (nothing to do on the
  /// phone, and it will be tried again by itself), so they are said differently.
  String _noSnapshotText() {
    final again = _recoverable ? ' Spróbujemy ponownie automatycznie.' : '';
    return switch (_noSnapshotReason) {
      OfflineReason.noNetwork => 'Brak zapisanej wersji tej strony. Otwórz ją przy połączeniu z internetem.',
      OfflineReason.serverUnavailable =>
        'Serwer parafii chwilowo nie odpowiada, a tej strony nie ma jeszcze w pamięci telefonu.$again',
      OfflineReason.slowServer =>
        'Serwer parafii odpowiada zbyt wolno, a tej strony nie ma jeszcze w pamięci telefonu.$again',
    };
  }

  /// How long the first load may wait, BEFORE it has begun, to learn whether a saved
  /// copy exists (see [_firstLoad]). That wait is part of what the user waits for.
  /// A manifest that is not read within this time is "not known", which is neither
  /// "no copy" nor "no network": the load then goes the way that does not depend on the
  /// answer (the server is tried, within the same start budget), and the saved copy remains
  /// the fallback if that fails.
  static const _savedCopyCheckBudget = Duration(milliseconds: 400);

  /// True if the answer to something awaited by the first load is no longer
  /// wanted: the screen is gone or signing out, a newer load has begun, or it is
  /// another parish or user now. A decision made from an old answer must never
  /// start a load.
  bool _decisionIsStale(int generation, String parishId, String userId) =>
      !mounted ||
      _loggingOut ||
      generation != _loadGeneration ||
      parishId != widget.parishId ||
      userId != widget.userId;

  /// The first load of this screen. If the system ALREADY says there is no
  /// network (the app was opened offline) AND a saved copy is known to exist, the
  /// attempt to reach the server is skipped: it cannot succeed, and until it fails
  /// the user waits for a copy that is already there.
  ///
  /// The system's report is not the server's answer, and a slow read of the saved-copy
  /// manifest is not a missing network. So:
  ///  - a copy is known to exist: straight to it (reason: no network, as reported);
  ///  - known not to exist: the server is tried, with the time a first handoff needs;
  ///  - NOT KNOWN (the read did not finish in [_savedCopyCheckBudget], or failed): the server
  ///    is tried, for what is left of the same start budget (the coordinator subtracts what
  ///    the check already took; it does not read the manifest a second time with a timeout
  ///    of its own). If that fails, the copy is shown with the reason the failure gives.
  ///    "No network" is never concluded from the store's slowness.
  ///
  /// Everything awaited here happens BEFORE the load and is therefore part of the
  /// user's wait: it is bounded, timed (the trace line "start: decided in N ms" and the
  /// start-up mark `start_decided`), and its answer is discarded if it arrives after the
  /// screen, the user, or the attempt it was asked for has changed ([_decisionIsStale]).
  Future<void> _firstLoad() async {
    final generation = _loadGeneration;
    final parishId = widget.parishId;
    final userId = widget.userId;
    final watch = Stopwatch()..start();
    var forceOffline = widget.forceOffline;
    OfflineReason? reason;
    var copyFact = SavedCopyFact.unchecked;
    var how = 'online attempt';
    if (!forceOffline) {
      final state = await widget.coordinator.connectivity.currentState();
      if (_decisionIsStale(generation, parishId, userId)) return;
      if (state != null && !state.hasInterface) {
        // Skipping the attempt only buys something when a saved copy is waiting to be
        // shown instead. With no copy (the first run, right after an activation and a
        // sign-in) there is nothing to show, and the system's report may be a moment's
        // flicker: the attempt is made, and if it fails the reason it gives is the
        // true one. Asking the system "is there a network" instead of the server was
        // what showed "no internet" to a user whose connection was fine.
        var fact = SavedCopyFact.unknown;
        try {
          fact = await widget.coordinator
              .savedCopyFact(parishId: parishId, userId: userId, pagePath: widget.targetPath)
              .timeout(_savedCopyCheckBudget);
        } on TimeoutException {
          fact = SavedCopyFact.unknown;
        } catch (_) {
          fact = SavedCopyFact.unknown;
        }
        if (_decisionIsStale(generation, parishId, userId)) {
          widget.coordinator.trace('start: the saved-copy answer arrived after the screen, the user or the attempt had changed; ignored (${watch.elapsedMilliseconds} ms)');
          return;
        }
        copyFact = fact;
        if (fact == SavedCopyFact.exists) {
          forceOffline = true;
          reason = OfflineReason.noNetwork;
          how = 'saved copy exists';
          widget.coordinator.trace('start: the system reports no network and a saved copy exists; skipping the online attempt');
        } else if (fact == SavedCopyFact.absent) {
          how = 'no saved copy yet';
          widget.coordinator.trace('start: the system reports no network but there is no saved copy yet; trying the server anyway');
        } else {
          how = 'saved copy not established within ${_savedCopyCheckBudget.inMilliseconds} ms';
          widget.coordinator.trace('start: the system reports no network and whether a saved copy exists is NOT known (${watch.elapsedMilliseconds} ms); '
              'trying the server within the same start budget, the copy stays the fallback');
        }
      }
    }
    StartupTrace.mark('start_decided');
    widget.coordinator.trace(
      'start: decided in ${watch.elapsedMilliseconds} ms before the load began (${forceOffline ? 'offline' : 'online'}: $how)',
    );
    await _loadPage(
      forceOffline: forceOffline,
      offlineReason: reason,
      copyFact: copyFact,
      spentBeforeLoad: watch.elapsed,
    );
  }

  /// The owner's definition of the real panel (see PanelSpec); null if the build
  /// was made without one, in which case the report says verdict=none.
  static final PanelSpec? _envPanelSpec = PanelSpec.fromEnvironment();
  PanelSpec? get _panelSpec => widget.panelSpec ?? _envPanelSpec;

  /// Names this run of the process in the trace, next to the operating system's
  /// process id: a log line is evidence for THIS process only if both match what
  /// the acceptance script saw start.
  static final String _processSession = DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// Asks the page to say when a frame has actually been drawn after it
  /// finished loading: two animation frames (the first commits the layout, the
  /// second is the one after it was painted), whether the page is visible, and
  /// whether the real panel (PanelSpec) is on it, with the required styles
  /// applied. "The page finished loading" is not "the user sees the panel":
  /// this is the second one. The 1.5 s timer in the probe only keeps the screen
  /// from waiting for ever; its report is labelled via=timer and is not a drawn
  /// frame. Reports short words and numbers and the id of the load, nothing else.
  void _probePaint() {
    final nav = _navId;
    unawaited(
      _controller
          .runJavaScript(buildPanelProbe(nav: nav, channel: _paintChannel, spec: _panelSpec))
          .catchError((_) {}),
    );
  }

  /// The page says what was on it. A trace line (PAINTED_FACTS) and, only when a
  /// real frame was drawn of a visible page that is the real panel, a start-up
  /// mark. The message is from a web page and changes no state.
  void _onPaint(JavaScriptMessage message) {
    if (!mounted || _loggingOut) return;
    try {
      final data = jsonDecode(message.message);
      if (data is! Map) return;
      if (data['nav'] != _navId) return; // a load that is no longer the current one
      final fcp = data['fcp'];
      final at = data['at'];
      final mode = _online ? 'live' : 'copy';
      // What was actually on the page when the frame was drawn. Only short
      // words and numbers are repeated; anything else from the page is dropped.
      String word(Object? v) => v is String && RegExp(r'^[A-Za-z]{1,12}$').hasMatch(v) ? v : 'n/a';
      String count(Object? v) => v is String && RegExp(r'^\d{1,4}/\d{1,4}$').hasMatch(v) ? v : 'n/a';
      String num0(Object? v) => v is num ? '${v.toInt().clamp(0, 100000)}' : 'n/a';
      String codes(Object? v) =>
          v is String && RegExp(r'^(-|[rfs]\d{1,2}|t)(,([rfs]\d{1,2}|t)){0,60}$').hasMatch(v) ? v : 'n/a';
      String specId(Object? v) => v is String && RegExp(r'^([0-9a-f]{12}|-)$').hasMatch(v) ? v : 'n/a';

      final via = word(data['via']);
      final shown = word(data['shown']);
      final hidden = data['hidden'] == 0 || data['hidden'] == 1 ? '${data['hidden']}' : 'n/a';
      final visible = shown == 'visible' && hidden == '0';
      // A drawn frame is one the engine called back for, on a page that is visible.
      // The fallback timer is neither.
      final drawn = via == 'raf' && visible;

      final expectedId = _panelSpec?.id ?? '-';
      final reportedId = specId(data['spec']);
      final verdict = reportedId == expectedId ? word(data['verdict']) : 'n/a';
      final specPath = _panelSpec?.path;
      final pathOk = specPath == null || Uri.tryParse(_currentPath)?.path == specPath;
      // With a spec, "the panel" means the checks passed on the right page. Without
      // one nothing says what the panel is, so no mark claims it.
      final isPanel = drawn && _panelSpec != null && verdict == 'ok' && pathOk;
      if (isPanel) StartupTrace.mark(_online ? 'panel_painted_live' : 'panel_painted_copy');

      _tr(
        'PAINTED_FACTS pid=$pid session=$_processSession mode=$mode via=$via drawn=${drawn ? 1 : 0} '
        'first-contentful-paint=${fcp is num ? '${fcp.toInt().clamp(-1, 600000)} ms' : 'n/a'} '
        'page-clock=${at is num ? '${at.toInt().clamp(0, 600000)} ms' : 'n/a'} '
        'readyState=${word(data['ready'])} visibility=$shown hidden=$hidden '
        'images=${count(data['img'])} stylesheets=${num0(data['sheets'])} '
        'main=${num0(data['w'])}x${num0(data['h'])}px '
        'spec=$reportedId verdict=$verdict failed=${codes(data['failed'])} path_ok=${pathOk ? 1 : 0} panel=${isPanel ? 1 : 0}',
      );
    } catch (_) {
      // Not ours: ignore.
    }
  }

  /// The page has its own scrolling; the native scroll bar drawn over the
  /// right edge of the web view is only noise. Scrolling by gesture is not
  /// affected: only whether the bar is DRAWN.
  Future<void> _hideScrollBars() async {
    try {
      await _controller.setVerticalScrollBarEnabled(false);
      await _controller.setHorizontalScrollBarEnabled(false);
    } catch (_) {
      // A platform without the setting keeps its bar; nothing else depends on it.
    }
  }

  @override
  void didUpdateWidget(covariant OfflineAwarePageScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.parishId != widget.parishId ||
        oldWidget.userId != widget.userId) {
      // Another parish or user: nothing of the previous identity may reach
      // this one, neither a page, nor a copy, nor a late callback.
      _failedDocuments.clear();
      _afterHandoffPath = null;
      _sessionRenewals = 0;
      _currentPath = widget.targetPath;
      unawaited(_loadPage(forceOffline: widget.forceOffline));
      return;
    }
    if (oldWidget.forceOffline != widget.forceOffline) {
      unawaited(_loadPage(forceOffline: widget.forceOffline));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadGeneration++;
    _navigationDeadline?.cancel();
    _totalDeadline?.cancel();
    _recoveryTimer?.cancel();
    _heartbeat?.cancel();
    _connectivitySub?.cancel();
    _captureTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appInBackground = false;
      // The network very likely changed while the app was away: ask now
      // instead of waiting out the rest of the delay.
      if (_recoverable && !_recoveryInFlight) {
        _recoveryTimer?.cancel();
        unawaited(_attemptRecovery(_loadGeneration));
      }
      // A live page checked nothing while the app was away.
      if (_online && _state == _LoadState.ready) _startHeartbeat();
    } else {
      _appInBackground = true;
      _recoveryTimer?.cancel();
      _heartbeat?.cancel();
    }
  }

  bool _trusted(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == widget.allowedHost &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;

  void _onCapture(JavaScriptMessage message) {
    if (!_online || _loggingOut || !mounted) return;
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final uri = Uri.parse(data['url'] as String);
      final path = snapshotPagePath(uri);
      if (!_trusted(uri) || path == null || path != _currentPath) return;
      widget.coordinator.captureInBackground(
        parishId: widget.parishId,
        userId: widget.userId,
        targetPath: path,
        renderedHtml: data['html'] as String,
      );
    } catch (_) {
      // Ignore malformed or stale messages.
    }
  }

  void _onBridge(JavaScriptMessage message) {
    if (!_online || _loggingOut || !mounted) return;
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      if (data['type'] == 'remember_token' && data['token'] is String) {
        unawaited(
          widget.coordinator.handoffService.secureStorage
              .setLegacyRememberToken(data['token'] as String)
              .catchError((_) {}),
        );
      }
    } catch (_) {}
  }

  void _startDeadline() {
    if (_navigationDeadline != null) return;
    _navigationDeadline = Timer(_pageRenderBudget, () {
      if (mounted && _online && !_loggingOut) {
        _tr(
          'deadline page-render ${_pageRenderBudget.inSeconds}s expired: the LIVE page did not finish; '
          'leaving it for the saved copy (reason=slowServer)',
        );
        unawaited(
          _loadPage(forceOffline: true, offlineReason: OfflineReason.slowServer),
        );
      }
    });
  }

  /// The first opening of the saved copy failed (error, or it did not finish
  /// in time). Opens it once more, at once, with a fresh plan and a fresh
  /// address. Returns whether a retry was started.
  bool _retryOfflineOnce() {
    if (_offlineAutoRetries >= 1) {
      _tr('no automatic retry left');
      return false;
    }
    _offlineAutoRetries++;
    _tr('automatic retry of the saved copy');
    unawaited(_loadPage(forceOffline: true));
    return true;
  }

  /// Expiry of [_offlineTotalBudget]. Gives up on THIS load completely —
  /// including bumping [_loadGeneration] — so a plan, loadRequest or page
  /// callback that finishes late cannot bring the abandoned load back
  /// and flip the screen under the user after the error is already shown.
  Future<void> _expireOfflineBudget(int generation) async {
    if (!mounted || _loggingOut || generation != _loadGeneration) return;
    // A timer and a platform callback that are both due in the same instant
    // run in the order they reached the queue, and after a stretch in which the
    // event loop was busy the timer can reach it first: the page had finished
    // (its callback is already waiting) and was nevertheless declared late,
    // abandoned, and opened a second time from scratch. One turn of the event
    // loop lets what has ALREADY arrived run. This is not extra time: nothing
    // that had not happened by the deadline can happen in it.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (!mounted || _loggingOut || generation != _loadGeneration) return;
    if (_onlineRendering || _state != _LoadState.loading) return;
    _loadGeneration++;
    final wasOpeningACopy = _offlineLoadUrl != null;
    _tr(
      'deadline expired phase=${wasOpeningACopy ? 'copy-render' : 'planning'} '
      'offlineDocStarted=$_offlineDocStarted',
    );
    // The engine is still running the navigation we are giving up on; its
    // late onPageFinished must not turn this error back into "ready".
    _offlineLoadUrl = null;
    _navigationDeadline?.cancel();
    _navigationDeadline = null;
    if (wasOpeningACopy) {
      widget.coordinator.trace('offline-render: deadline expired; retry=$_offlineAutoRetries');
    }
    if (wasOpeningACopy && _retryOfflineOnce()) return;
    setState(() {
      _state = _LoadState.error;
      // Said honestly: during PLANNING no copy has been opened (there may be
      // none), so "the saved copy did not open" would be a different failure.
      _errorText = wasOpeningACopy
          ? 'Zapisana kopia strony nie otworzyła się na czas. Spróbuj ponownie.'
          : 'Nie udało się przygotować strony na czas. Spróbuj ponownie.';
    });
    // The bump above invalidated the generation a pending recovery was
    // bound to; without this the screen would stop trying to reconnect.
    if (_recoverable) _scheduleRecovery();
  }

  void _onStarted(String url) {
    if (!mounted || _loggingOut) return;
    _captureTimer?.cancel();
    final uri = Uri.tryParse(url);
    _tr('started ${describeUrlForLog(url)} mode=${_online ? 'live' : 'copy'}');
    if (!_online &&
        uri != null &&
        widget.coordinator.localServer.ownsUrl(uri) &&
        _isCurrentOfflineDocument(uri)) {
      _offlineDocStarted = true;
    }
    if (!_online && uri != null && widget.coordinator.localServer.ownsUrl(uri)) {
      widget.coordinator.trace('offline-render: started; current=');
    }
    if (_online && uri != null && _trusted(uri)) {
      _failedDocuments.remove(uri.toString());
      final path = snapshotPagePath(uri);
      if (path != null && _afterHandoffPath == null) _currentPath = path;
      if (path != null) {
        final previous = _lastStartedPath;
        if (previous != null && previous != path && !_lastStartedFinished) {
          _supersededPaths.add(previous); // replaced before it finished
        }
        _supersededPaths.remove(path); // started again: it is current now
        _lastStartedPath = path;
        _lastStartedFinished = false;
      }
      _startDeadline();
    }
    unawaited(_controller.runJavaScript(_bridgeShim).catchError((_) {}));
  }

  void _onFinished(String url) {
    if (!mounted || _loggingOut) return;
    final uri = Uri.tryParse(url);
    _tr('finished ${describeUrlForLog(url)} mode=${_online ? 'live' : 'copy'}');
    if (uri == null ||
        (_online
            ? !_trusted(uri)
            : !(widget.coordinator.localServer.ownsUrl(uri) &&
                  _isCurrentOfflineDocument(uri)))) {
      // Until now this return said nothing, so "the callback never came" and
      // "it came for an address we did not expect" looked the same in a log.
      _tr('finished IGNORED: not the document being waited for (${uri == null ? 'unparseable' : _whyNotCurrent(uri)})');
      return;
    }
    if (!_online) widget.coordinator.trace('offline-render: finish callback');
    if (_failedDocuments.contains(uri.toString())) {
      _tr('finished IGNORED: that document had already failed');
      return;
    }
    if (_online) {
      final finishedPath = snapshotPagePath(uri);
      // The late finish of a navigation that was replaced: not this page.
      if (finishedPath != null && _supersededPaths.contains(finishedPath)) {
        _tr('finished IGNORED: its navigation had been replaced ($finishedPath)');
        return;
      }
      if (finishedPath != null && finishedPath == _lastStartedPath) {
        _lastStartedFinished = true;
      }
    }
    if (_online && _afterHandoffPath != null && snapshotPagePath(uri) != null) {
      final target = _afterHandoffPath!;
      _afterHandoffPath = null;
      if (snapshotPagePath(uri) != target) {
        _currentPath = target;
        unawaited(
          _controller.loadRequest(
            Uri.parse('https://${widget.allowedHost}').resolve(target),
          ),
        );
        return;
      }
    }
    _navigationDeadline?.cancel();
    _navigationDeadline = null;
    _totalDeadline?.cancel();
    _totalDeadline = null;
    // A login redirect means the PHP session expired; never cache it.
    if (_online && uri.pathSegments.lastOrNull?.toLowerCase() == 'login.php') {
      // The PHP session ended (the mobile sign-in is separate and, if it
      // were not valid, the handoff itself would have answered 401). Get a
      // new PHP session the way the first one was obtained, once, and
      // return to the page the user was on — _currentPath is not touched by
      // the login page, which is never recorded as a page. Signing out here
      // used to throw away a perfectly good sign-in.
      if (_sessionRenewals < 1) {
        _sessionRenewals++;
        unawaited(_loadPage());
      } else {
        unawaited(_logout());
      }
      return;
    }
    setState(() => _state = _LoadState.ready);
    _tr('READY mode=${_online ? 'live' : 'copy'}');
    _probePaint();
    StartupTrace.mark(_online ? 'page_ready_online' : 'page_ready_offline');
    if (!_online) {
      widget.coordinator.trace('offline-render: finished');
      _offlineAutoRetries = 0;
    }
    final lossWatch = _lossWatch;
    if (!_online && lossWatch != null) {
      widget.coordinator.trace(
        'net: connection lost -> saved copy visible after ${lossWatch.elapsedMilliseconds} ms',
      );
      _lossWatch = null;
    }
    if (!_online) {
      unawaited(
        _controller
            .runJavaScript(r"""
        document.querySelectorAll('form input,form textarea,form select,form button').forEach(function(e) {
          e.disabled = true; e.title = 'Dostępne po połączeniu z internetem';
        });
        document.addEventListener('submit', function(e) {
          e.preventDefault(); e.stopImmediatePropagation();
        }, true);
      """)
            .catchError((_) {}),
      );
    }
    if (_online) {
      _recoveryAttempts = 0;
      _sessionRenewals = 0;
      _startHeartbeat();
      final path = snapshotPagePath(uri);
      if (path == null) return;
      _currentPath = path;
      // The saved copy of the page that is on screen is the one a switch would
      // open next: have it decrypted while the phone is idle and online (a
      // no-op when it already is in memory).
      unawaited(
        widget.coordinator.prewarmPage(
          parishId: widget.parishId,
          userId: widget.userId,
          pagePath: path,
        ),
      );
      _capture();
      // Capture again after typical async DOM updates; navigation cancels this.
      // Cancel any earlier one first: only the LAST reference is cancelled
      // on dispose, so an overwritten timer would otherwise outlive the
      // screen. (_onStarted usually cancels it, but nothing guarantees a
      // start event between two finishes.)
      _captureTimer?.cancel();
      _captureTimer = Timer(const Duration(milliseconds: 750), _capture);
    }
  }

  void _capture() {
    if (!mounted || !_online || _loggingOut) return;
    unawaited(
      _controller
          .runJavaScript('''
$_captureChannel.postMessage(JSON.stringify({
  url: location.href, html: document.documentElement.outerHTML
}));
''')
          .catchError((_) {}),
    );
  }

  NavigationDecision _navigate(NavigationRequest request) {
    if (_loggingOut) return NavigationDecision.prevent;
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    if (_trusted(uri)) {
      if (isLogoutPath(uri)) {
        unawaited(_logout());
        return NavigationDecision.prevent;
      }
      if (_online) {
        final path = snapshotPagePath(uri);
        if (request.isMainFrame && path != null && _afterHandoffPath == null) {
          _currentPath = path;
          _startDeadline();
        }
        return NavigationDecision.navigate;
      }
      if (request.isMainFrame) {
        final path = snapshotPagePath(uri);
        if (path != null) {
          _currentPath = path;
          unawaited(_loadPage(forceOffline: true));
        }
      }
      return NavigationDecision.prevent;
    }
    if (!_online && widget.coordinator.localServer.ownsUrl(uri))
      return NavigationDecision.navigate;
    if (_online &&
        request.isMainFrame &&
        const {'https', 'http', 'mailto', 'tel'}.contains(uri.scheme)) {
      unawaited(
        launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        ).catchError((_) => false),
      );
    }
    return NavigationDecision.prevent;
  }

  Future<void> _logout() async {
    if (_loggingOut || widget.onLogout == null) return;
    _loggingOut = true;
    _loadGeneration++;
    _recoverable = false;
    _recoveryTimer?.cancel();
    _heartbeat?.cancel();
    _offlineLoadUrl = null;
    _navigationDeadline?.cancel();
    _totalDeadline?.cancel();
    _captureTimer?.cancel();
    if (mounted) setState(() => _state = _LoadState.loading);
    widget.coordinator.localServer.rootDirectory = null;
    try {
      await _controller.loadHtmlString('<html><body></body></html>');
      await _controller.clearCache();
      await _controller.clearLocalStorage();
    } catch (_) {}
    await widget.onLogout!();
  }

  /// The system reports a change of connection. Reacting here is what makes
  /// the saved copy appear within moments of a loss instead of after the next
  /// check. It decides nothing about the SERVER: a returned network starts a
  /// check of the server, and only an answer from the server brings the live
  /// page back.
  void _onConnectivity(ConnectivityEvent event) {
    if (!mounted || _loggingOut) return;
    // The monitor also emits the initial offline baseline after its 250 ms grace.
    // Until the first plan starts, _firstLoad owns the bounded saved-copy decision.
    // A baseline event must not replace its 400 ms read with an unconditional
    // offline load and discard the eventual unknown/absent result.
    if (_loadGeneration == 0) return;
    switch (event.kind) {
      case ConnectivityEventKind.lost:
        if (!_online) return; // already on the copy, or about to be
        _lossWatch = Stopwatch()..start();
        widget.coordinator.trace('net: connection lost');
        if (_state == _LoadState.ready) {
          // In the background the screen does nothing; on return the
          // periodic check finds the loss within seconds.
          if (_appInBackground) return;
          unawaited(_connectionLost(OfflineReason.noNetwork, _loadGeneration));
        } else if (_state == _LoadState.loading) {
          unawaited(
            _loadPage(
              forceOffline: true,
              offlineReason: OfflineReason.noNetwork,
            ),
          );
        }
      case ConnectivityEventKind.doubtful:
        // Connected, but the system doubts the internet is reachable: ask the
        // server now rather than at the next interval.
        if (_online && _state == _LoadState.ready && !_appInBackground) {
          _heartbeat?.cancel();
          _heartbeatMisses = 0;
          unawaited(_heartbeatTick(_loadGeneration));
        }
      case ConnectivityEventKind.returned:
        if (_online) {
          _heartbeatMisses = 0;
          return;
        }
        // Ask the server at once instead of waiting out the back-off. The
        // answer, not the network, decides; a server that does not answer
        // keeps the saved copy and the usual back-off.
        if (_recoverable && !_recoveryInFlight) {
          _recoveryTimer?.cancel();
          _recoveryAttempts = 0;
          unawaited(_attemptRecovery(_loadGeneration));
        }
    }
  }

  // ---- noticing a lost connection on an idle live page ----------------------
  //
  // Nothing else notices it: a page that is already loaded makes no request,
  // so without this the app sat on the live page until the user happened to
  // navigate or refresh. A quick TCP connection to the server, repeated
  // while a live page is on screen, tells "no network" from "slow server"
  // from "fine" within a moment, and the saved copy then opens by itself.

  void _startHeartbeat() {
    _heartbeatMisses = 0;
    _scheduleHeartbeat(_heartbeatInterval);
  }

  void _scheduleHeartbeat(Duration delay) {
    _heartbeat?.cancel();
    if (!mounted ||
        _loggingOut ||
        !_online ||
        _state != _LoadState.ready ||
        _appInBackground ||
        _connectionLostDeferred) {
      return;
    }
    final generation = _loadGeneration;
    _heartbeat = Timer(delay, () => unawaited(_heartbeatTick(generation)));
  }

  Future<Reachability> _checkOnce() async {
    try {
      return await widget.coordinator.checkReachability(widget.allowedHost);
    } catch (_) {
      return Reachability.timedOut;
    }
  }

  bool _liveAndCurrent(int generation) =>
      mounted &&
      !_loggingOut &&
      !_appInBackground &&
      generation == _loadGeneration &&
      _online &&
      _state == _LoadState.ready;

  /// A check that finished for a page that is no longer the current one must
  /// not take the watch with it: if a live page is on screen now, keep
  /// checking it. (The timer of the new page may have fired while the old
  /// check was still running and been dropped as "already in flight".)
  void _resumeHeartbeatIfLive() {
    if (mounted && !_loggingOut && _online && _state == _LoadState.ready) {
      _scheduleHeartbeat(_heartbeatInterval);
    }
  }

  Future<void> _heartbeatTick(int generation) async {
    if (!_liveAndCurrent(generation) || _heartbeatInFlight) return;
    _heartbeatInFlight = true;
    final verdict = await _checkOnce().whenComplete(() {
      _heartbeatInFlight = false;
    });
    if (!_liveAndCurrent(generation)) {
      _resumeHeartbeatIfLive();
      return;
    }

    switch (verdict) {
      case Reachability.reachable:
        _heartbeatMisses = 0;
        _scheduleHeartbeat(_heartbeatInterval);
      case Reachability.noRoute:
        // The system itself says there is no way out: act at once.
        await _connectionLost(OfflineReason.noNetwork, generation);
      case Reachability.dnsFailure ||
          Reachability.refused ||
          Reachability.timedOut:
        // Doubtful on its own (a DNS hiccup, a busy server): confirm
        // shortly, and only act on a repeat.
        _heartbeatMisses++;
        if (_heartbeatMisses >= 2) {
          await _connectionLost(
            verdict == Reachability.dnsFailure
                ? OfflineReason.noNetwork
                : OfflineReason.serverUnavailable,
            generation,
          );
        } else {
          _scheduleHeartbeat(_heartbeatConfirmDelay);
        }
    }
  }

  Future<void> _connectionLost(OfflineReason reason, int generation) async {
    _tr('connection lost cause=${reason.name}: deciding whether to swap to the saved copy');
    // Never swap a page the user is typing into for a copy on their own:
    // offer it instead.
    final dirty = await _hasUnsavedInput();
    if (!_liveAndCurrent(generation)) {
      // The page changed, or the app left, while the page was being asked.
      _resumeHeartbeatIfLive();
      return;
    }
    if (dirty) {
      setState(() {
        _connectionLostDeferred = true;
        _lostReason = reason;
      });
      return;
    }
    await _loadPage(forceOffline: true, offlineReason: reason);
  }

  void _scheduleRecovery() {
    _recoveryTimer?.cancel();
    if (!mounted || _loggingOut || !_recoverable || _appInBackground) return;
    final generation = _loadGeneration;
    final index = _recoveryAttempts < _recoveryBackoff.length
        ? _recoveryAttempts
        : _recoveryBackoff.length - 1;
    _recoveryTimer = Timer(
      _recoveryBackoff[index],
      () => unawaited(_attemptRecovery(generation)),
    );
  }

  Future<void> _attemptRecovery(int generation) async {
    if (!mounted || _loggingOut || !_recoverable) return;
    if (generation != _loadGeneration) return;
    // One request at a time. The attempt already running reschedules when it
    // ends, so skipping here loses nothing.
    if (_recoveryInFlight) return;
    _recoveryInFlight = true;
    _recoveryAttempts++;
    final result = await _probeOnce().whenComplete(() {
      _recoveryInFlight = false;
    });

    if (!mounted || _loggingOut) return;
    if (generation != _loadGeneration || !_recoverable) {
      // The load this attempt belonged to is gone. Its answer must not
      // switch anything; but if the CURRENT load is waiting to recover, make
      // sure someone is still asking.
      if (_recoverable) _scheduleRecovery();
      return;
    }

    switch (result) {
      case OnlineProbeRecovered():
        await _switchOnline(result.plan, generation);
      case OnlineProbeUnavailable():
        _scheduleRecovery();
      case OnlineProbeRejected():
        // The server is there and refuses: asking again cannot fix it.
        _recoverable = false;
        final e = result.error;
        if (e.refusal != null) {
          // An unambiguous refusal (the device is not authorized, or the role has no access to this
          // module): the copy that is on screen must not stay on screen as though nothing had been said.
          _applyServerError(e);
          return;
        }
        setState(() {
          _recoveryRejection =
              'Serwer odrzucił otwarcie strony • ${[
                if (e.statusCode != null) 'HTTP ${e.statusCode}',
                if (e.errorCode != null) e.errorCode!,
              ].join(' · ')}. Użyj odświeżenia, aby zobaczyć szczegóły.';
        });
    }
  }

  Future<OnlineProbeResult> _probeOnce() async {
    try {
      // Always through the entry page: the one path the server is known to
      // hand off to. The page the user is on is opened after the handoff.
      return await widget.coordinator.probeOnline(
        parishId: widget.parishId,
        userId: widget.userId,
        targetPath: widget.targetPath,
        timeout: _probeTimeout,
      );
    } catch (_) {
      return const OnlineProbeUnavailable();
    }
  }

  Future<void> _switchOnline(PageLoadOnline plan, int generation) async {
    // Only a saved copy that is actually on screen can hold input worth
    // protecting; while it is still loading, or showing an error, there is
    // nothing to lose.
    if (_state == _LoadState.ready && await _hasUnsavedInput()) {
      if (!mounted || _loggingOut || generation != _loadGeneration) return;
      // Deliberate deferral: no timer, no further probing. The user chooses.
      setState(() => _onlineAvailableDeferred = true);
      return;
    }
    if (!mounted || _loggingOut || generation != _loadGeneration) return;
    await _loadPage(prepared: plan);
  }

  /// Whether the page holds input the user has changed and not submitted.
  /// Forms in a saved copy are already disabled, so in practice this guards
  /// fields outside a form (filters, search boxes). If it cannot be
  /// determined it answers yes: a banner costs a tap, a lost entry costs
  /// the user's work.
  Future<bool> _hasUnsavedInput() async {
    try {
      // A web view that never answers must not freeze both automatic
      // directions: no answer is treated like "there may be unsaved data".
      final result = await _controller
          .runJavaScriptReturningResult(_unsavedInputScript)
          .timeout(_unsavedInputCheckLimit);
      return result == true || result.toString().toLowerCase() == 'true';
    } catch (_) {
      return true;
    }
  }

  static const _unsavedInputScript = r'''
(function () {
  try {
    var skip = /^(hidden|submit|button|reset|image|file)$/i;
    var a = document.activeElement;
    if (a && (a.tagName === 'TEXTAREA' ||
        (a.tagName === 'INPUT' && !skip.test(a.type || '') &&
         !/^(checkbox|radio)$/i.test(a.type || '')))) return true;
    var els = document.querySelectorAll('input, textarea, select');
    for (var i = 0; i < els.length; i++) {
      var e = els[i], t = (e.type || '').toLowerCase();
      if (skip.test(t)) continue;
      if (e.tagName === 'SELECT') {
        for (var j = 0; j < e.options.length; j++) {
          if (e.options[j].selected !== e.options[j].defaultSelected) return true;
        }
        continue;
      }
      if (t === 'checkbox' || t === 'radio') {
        if (e.checked !== e.defaultChecked) return true;
        continue;
      }
      if (e.value !== e.defaultValue) return true;
    }
    return false;
  } catch (err) { return true; }
})()
''';

  /// A page the server refused with a 4xx: stop everything that is waiting,
  /// abandon the load, and show the refusal with its code, plus the saved
  /// copy as an explicit choice when there is one.
  Future<void> _showPageRefusal(Uri uri, int status) async {
    final generation = ++_loadGeneration;
    _navigationDeadline?.cancel();
    _navigationDeadline = null;
    _totalDeadline?.cancel();
    _totalDeadline = null;
    _recoveryTimer?.cancel();
    _heartbeat?.cancel();
    _recoverable = false;
    final path = snapshotPagePath(uri) ?? _currentPath;
    final hasCopy = await widget.coordinator.hasSavedCopy(
      parishId: widget.parishId,
      userId: widget.userId,
      pagePath: path,
    );
    if (!mounted || _loggingOut || generation != _loadGeneration) return;
    final refusal = PageLoadServerError(
      statusCode: status,
      errorCode: null,
      path: uri.path,
      hasSnapshot: hasCopy,
    );
    _online = false;
    _offlineLoadUrl = null;
    _afterHandoffPath = null;
    _banner = null;
    _serverError = refusal;
    _errorText = describeServerError(refusal);
    setState(() => _state = _LoadState.error);
  }

  /// The server answered and refused (or a refusal received earlier still stands): stop every pending
  /// wait and say what the server said (sanitized), with the ways out. After an unambiguous refusal
  /// ([PageLoadServerError.refusal]) the loopback server stops serving the copy as well, so that
  /// nothing already on its way to the screen can still show it.
  void _applyServerError(PageLoadServerError plan) {
    // The server answered, so this is neither "offline" nor a load
    // still in progress.
    _online = false;
    _afterHandoffPath = null;
    _banner = null;
    _offlineLoadUrl = null;
    _navigationDeadline?.cancel();
    _navigationDeadline = null;
    _totalDeadline?.cancel();
    _totalDeadline = null;
    if (plan.refusal != null) {
      _recoveryTimer?.cancel();
      _heartbeat?.cancel();
      _recoverable = false;
      _captureTimer?.cancel();
      widget.coordinator.localServer.rootDirectory = null;
      _loadGeneration++; // whatever was still loading belongs to a screen that is no longer shown
    }
    _serverError = plan;
    _errorText = describeServerError(plan);
    if (mounted) setState(() => _state = _LoadState.error);
  }

  /// [prepared] is a handoff ticket already obtained by the background
  /// check; the load then skips planning and uses it, instead of asking the
  /// server for a second ticket right after it just issued one.
  Future<void> _loadPage({
    bool forceOffline = false,
    PageLoadOnline? prepared,
    OfflineReason? offlineReason,
    SavedCopyFact copyFact = SavedCopyFact.unchecked,
    Duration spentBeforeLoad = Duration.zero,
  }) async {
    final generation = ++_loadGeneration;
    _navId++;
    _navWatch
      ..reset()
      ..start();
    _tr(
      'load-start forceOffline=$forceOffline '
      'reason=${forceOffline ? (offlineReason ?? _offlineReason).name : 'n/a(online attempt first)'} '
      'prepared=${prepared != null} path=${describeUrlForLog('https://x$_currentPath')} '
      'wasOnline=$_online autoRetries=$_offlineAutoRetries',
    );
    _navigationDeadline?.cancel();
    _navigationDeadline = null;
    _captureTimer?.cancel();
    // A new load supersedes any pending reconnect attempt; if this load also
    // ends on a saved copy it schedules its own.
    _recoveryTimer?.cancel();
    _recoverable = false;
    _onlineAvailableDeferred = false;
    _recoveryRejection = null;
    if (!mounted || _loggingOut) return;
    setState(() => _state = _LoadState.loading);
    _onlineRendering = false;
    _heartbeat?.cancel();
    _connectionLostDeferred = false;
    _offlineDocStarted = false;
    // Nothing reported from here on belongs to the previous load.
    _supersededPaths.clear();
    _lastStartedPath = null;
    _lastStartedFinished = true;
    // A load the user asked for starts with a fresh allowance of automatic
    // retries; a retry itself (forced offline) does not.
    if (!forceOffline) _offlineAutoRetries = 0;
    // From here on any offline navigation that was still pending belongs
    // to an abandoned load.
    _offlineLoadUrl = null;
    _serverError = null;
    _totalDeadline?.cancel();
    // Covers PLANNING only; replaced by the saved copy's own 2 s below as
    // soon as planning has decided to show it.
    _totalDeadline = Timer(
      widget.coordinator.planningBudget,
      () => _expireOfflineBudget(generation),
    );
    try {
      // No page deadline here on purpose: plan() is itself bounded
      // (handoff by onlineTimeout, local view by offlinePlanTimeout), and
      // the page-render budget must only start once a ticket exists.
      // A forced-offline load leaves online mode IMMEDIATELY, not when the
      // plan returns: otherwise an online page the screen just gave up on
      // could still finish inside that window and flip the screen back.
      _online = !forceOffline;
      StartupTrace.mark('plan_start');
      final PageLoadPlan plan = prepared ?? await widget.coordinator.plan(
        parishId: widget.parishId,
        userId: widget.userId,
        targetPath: _currentPath,
        // Always through the entry page — see OfflinePageCoordinator.plan.
        handoffPath: widget.targetPath,
        forceOffline: forceOffline,
        offlineReason: offlineReason ?? _offlineReason,
        copyFact: copyFact,
        alreadySpent: spentBeforeLoad,
      );
      if (!mounted || _loggingOut || generation != _loadGeneration) {
        _tr('plan-result DISCARDED (a newer load exists or the screen is gone): ${plan.runtimeType}');
        return;
      }
      StartupTrace.mark('plan_done');
      _tr('plan-result ${plan.runtimeType}');
      switch (plan) {
        case PageLoadOnline():
          _online = true;
          // The ticket is always for the entry page (the one the server is
          // known to hand off to), so any other page the user is on —
          // with or without a query — is opened right after the handoff
          // lands, using the session the ticket just created.
          _afterHandoffPath = _currentPath != widget.targetPath
              ? _currentPath
              : null;
          // With a setState: the live page is being requested NOW, so the
          // OFFLINE label must go now, not at the next rebuild — which used
          // to be the end of the page load, leaving "OFFLINE" over a page
          // that was loading from the server.
          setState(() => _banner = null);
          _errorText = null;
          // A ticket exists: the server answered, so this is no longer
          // "is the network there" but "is the page slow" — it gets its
          // own, longer budget instead of the 2 s offline one.
          _onlineRendering = true;
          _offlineLoadUrl = null;
          _totalDeadline?.cancel();
          _totalDeadline = null;
          _startDeadline();
          await _loadRequestTraced(plan.url);
        case PageLoadOffline():
          _online = false;
          _afterHandoffPath = null;
          _offlineReason = plan.reason;
          _banner = formatOfflineBannerText(
            plan.capturedAt,
            reason: plan.reason,
          );
          _errorText = null;
          // A previous attempt at this very URL may have been marked
          // failed (corrupt copy); the entry must not swallow the
          // onPageFinished of a legitimate retry.
          _failedDocuments.removeWhere((u) => u.startsWith('http://'));
          _offlineLoadUrl = plan.url;
          _recoverable = !widget.forceOffline;
          _scheduleRecovery();
          // The decision to show the copy is made: from NOW it has 2 s.
          _totalDeadline?.cancel();
          _totalDeadline = Timer(
            _offlineTotalBudget,
            () => _expireOfflineBudget(generation),
          );
          await _loadRequestTraced(plan.url);
        case PageLoadOfflineNoSnapshot():
          _online = false;
          _errorText = null;
          _recoverable = !widget.forceOffline;
          _noSnapshotReason = plan.reason;
          if (plan.timedOut) {
            // Preparing the view ran out of time. A copy may well exist (a slow
            // moment is not "there is none"): try once more, and if that fails
            // too say what happened instead of saying there is no copy.
            _tr('plan timed out: not "no saved copy"');
            if (_retryOfflineOnce()) return;
            _scheduleRecovery();
            setState(() {
              _state = _LoadState.error;
              _errorText = 'Przygotowanie zapisanej kopii trwało zbyt długo. Spróbuj ponownie.';
            });
            return;
          }
          _scheduleRecovery();
          setState(() => _state = _LoadState.noSnapshot);
        case PageLoadServerError():
          _applyServerError(plan);
      }
    } catch (_) {
      if (mounted && generation == _loadGeneration)
        setState(() => _state = _LoadState.error);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      if (_online && await _controller.canGoBack()) {
        _startDeadline();
        await _controller.goBack();
      } else if (_currentPath != widget.targetPath) {
        _currentPath = widget.targetPath;
        await _loadPage(forceOffline: !_online);
      } else if (context.mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    },
    child: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (_banner != null)
              Container(
                color: Colors.orange.shade100,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$_banner • tylko podgląd',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Spróbuj połączyć',
                      icon: const Icon(Icons.refresh),
                      onPressed: () => _loadPage(),
                    ),
                  ],
                ),
              ),
            if (_connectionLostDeferred)
              Container(
                color: Colors.orange.shade100,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Utracono połączenie z serwerem. Na stronie są niezapisane dane — pokaż zapisaną wersję, gdy będziesz gotowy.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(
                        _loadPage(forceOffline: true, offlineReason: _lostReason),
                      ),
                      child: const Text('POKAŻ ZAPISANĄ WERSJĘ'),
                    ),
                  ],
                ),
              ),
            if (_onlineAvailableDeferred)
              Container(
                color: Colors.green.shade100,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Połączenie wróciło. Na stronie są niezapisane dane — wróć online, gdy będziesz gotowy.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(_loadPage()),
                      child: const Text('WRÓĆ ONLINE'),
                    ),
                  ],
                ),
              ),
            if (_recoveryRejection != null)
              Container(
                color: Colors.red.shade50,
                padding: const EdgeInsets.all(8),
                width: double.infinity,
                child: Text(
                  _recoveryRejection!,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            Expanded(
              // The WebView is ALWAYS part of the tree (it used to be added
              // only once onPageFinished had set `ready`, i.e. the page
              // had to finish loading in a view that did not exist yet).
              // Loading / no-snapshot / error are an opaque overlay on top,
              // so a rebuild can never tear the platform view down in the
              // middle of a navigation.
              child: Stack(
                children: [
                  WebViewWidget(controller: _controller),
                  if (_state != _LoadState.ready)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: _state == _LoadState.loading
                            ? const Center(child: CircularProgressIndicator())
                            : Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _serverError != null
                                            ? Icons.error_outline
                                            : (_state == _LoadState.noSnapshot &&
                                                      _noSnapshotReason != OfflineReason.noNetwork
                                                  ? Icons.cloud_off
                                                  : Icons.wifi_off),
                                        size: 48,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        _state == _LoadState.noSnapshot
                                            ? _noSnapshotText()
                                            : (_errorText ??
                                                  'Nie udało się otworzyć strony.'),
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 16),
                                      FilledButton(
                                        onPressed: () => _loadPage(),
                                        child: const Text('SPRÓBUJ PONOWNIE'),
                                      ),
                                      if (_serverError?.hasSnapshot ?? false)
                                        OutlinedButton(
                                          onPressed: () => unawaited(
                                            _loadPage(forceOffline: true),
                                          ),
                                          child: const Text(
                                            'OTWÓRZ ZAPISANĄ KOPIĘ',
                                          ),
                                        ),
                                      if (_serverError?.statusCode == 401 &&
                                          widget.onLogout != null)
                                        OutlinedButton(
                                          onPressed: () =>
                                              unawaited(widget.onLogout!()),
                                          child: const Text('ZALOGUJ PONOWNIE'),
                                        ),
                                      if (_currentPath != widget.targetPath)
                                        TextButton(
                                          onPressed: () {
                                            _currentPath = widget.targetPath;
                                            unawaited(
                                              _loadPage(forceOffline: !_online),
                                            );
                                          },
                                          child: const Text('WRÓĆ DO PANELU'),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
