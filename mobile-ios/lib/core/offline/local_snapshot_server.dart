import 'dart:io';
import 'package:path/path.dart' as p;

/// Offline-architecture milestone, P2. A local-only, read-only static
/// file HTTP server that the app's WebView loads snapshot pages from
/// when offline — see the project's own architecture decision:
/// "Wybieramy lokalny HTTP server na 127.0.0.1, a nie `file://` ani
/// `loadHtmlString()`." This is deliberately the ONLY thing this class
/// does: serve files that already exist on disk under [rootDirectory].
/// It never executes PHP, never proxies anywhere, and never accepts
/// writes.
///
/// Security properties (all of these are REQUIREMENTS, not incidental):
/// - Binds to [InternetAddress.loopbackIPv4] ONLY — never reachable from
///   LAN, never `0.0.0.0`.
/// - Random OS-assigned port (`bind(..., 0)`) — never a fixed, guessable
///   port.
/// - GET/HEAD only — anything else (POST, PUT, DELETE, ...) is 405
///   without touching the filesystem at all.
/// - Every resolved path is checked to still be INSIDE [rootDirectory]
///   after normalization — `..` segments, encoded traversal attempts,
///   and absolute-looking request paths can never escape root. A
///   request that fails this check is 404, indistinguishable from a
///   request for a file that simply doesn't exist (never a distinct
///   "forbidden" response that would confirm the path was understood).
/// - 404 for anything not found, anything outside root, and anything
///   requested while no [rootDirectory] is set yet.
/// - No directory listing — a request that resolves to a directory is
///   404, not an index.
///
/// [rootDirectory] is intentionally mutable and re-read on EVERY request
/// rather than captured once — review round: a snapshot "musi być
/// związany co najmniej z parish_id, user_id" and must never mix across
/// a user/parish switch. Swapping this field (e.g. on logout or parish
/// change) takes effect for the very next request with no server
/// restart and no port change, so the WebView's already-open connection
/// doesn't need to be torn down just to point it at a different
/// snapshot root — though the caller is still responsible for actually
/// navigating the WebView away from the old user/parish's pages at that
/// point; this class only controls what the filesystem underneath can
/// ever answer with.
class LocalSnapshotServer {
  HttpServer? _server;
  Directory? rootDirectory;

  int? get port => _server?.port;
  bool get isRunning => _server != null;

  /// Starts the server if not already running and returns the port it's
  /// listening on. Calling this again while already running is a no-op
  /// that just returns the existing port — callers don't need to track
  /// "did I already start this" themselves.
  Future<int> start() async {
    final existing = _server;
    if (existing != null) {
      return existing.port;
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(
      _handleRequest,
      onError: (_) {
        // A single malformed connection must never bring the whole
        // server down — dart:io's own listen-level error, distinct from
        // the try/catch inside _handleRequest which covers per-request
        // failures once a request object actually exists.
      },
    );
    return server.port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }

      final root = rootDirectory;
      if (root == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final file = _resolveWithinRoot(root, request.uri.path);
      if (file == null || !await file.exists()) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final length = await file.length();
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = _contentTypeFor(file.path);
      response.headers.contentLength = length;
      // Review round: this is a point-in-time snapshot the app manages
      // itself — nothing upstream of this server (the WebView, any
      // platform HTTP cache) should ever serve a stale copy of a page
      // after the app has replaced it with a fresher snapshot.
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');

      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      await response.addStream(file.openRead());
      await response.close();
    } catch (_) {
      // Never let one bad request (a half-closed socket, a file that
      // disappeared mid-read, ...) crash the server or hang the
      // connection open — best-effort 500, swallow any secondary error
      // from trying to even write that.
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {
        // Connection is already unusable — nothing left to do.
      }
    }
  }

  /// Resolves [requestPath] against [root], returning null if the
  /// result would fall OUTSIDE root after normalization — the single
  /// security-critical check in this class. Deliberately simple,
  /// manual string comparison rather than a package helper whose exact
  /// edge-case behavior this codebase hasn't independently verified.
  File? _resolveWithinRoot(Directory root, String requestPath) {
    var relative = requestPath;
    if (relative.startsWith('/')) {
      relative = relative.substring(1);
    }
    if (relative.isEmpty) {
      return null;
    }

    final rootCanonical = p.normalize(root.absolute.path);
    final targetCanonical = p.normalize(p.join(rootCanonical, relative));

    if (!_isWithin(rootCanonical, targetCanonical)) {
      return null;
    }

    return File(targetCanonical);
  }

  bool _isWithin(String rootCanonical, String targetCanonical) {
    if (targetCanonical == rootCanonical) {
      // The root directory itself is never servable — no directory
      // listing, see this class's own docblock.
      return false;
    }
    final rootWithSeparator =
        rootCanonical.endsWith(Platform.pathSeparator) ? rootCanonical : '$rootCanonical${Platform.pathSeparator}';
    return targetCanonical.startsWith(rootWithSeparator);
  }

  static const Map<String, String> _extensionToMimeType = {
    // Review round fix (real bug, caught by CI): snapshot PAGE files
    // keep their ORIGINAL legacy filename — /dashboard.php,
    // /public/schedule.php, etc. — because the whole point of this
    // server is serving them back at the SAME path the WebView already
    // knows. Their content is pure rendered HTML by the time they're
    // captured, so .php must map to text/html here, same as .html
    // itself — this was the one missing entry the test caught
    // (dashboard.php was falling through to the application/
    // octet-stream default, which a WebView won't render as a page).
    '.php': 'text/html',
    '.html': 'text/html',
    '.htm': 'text/html',
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.mjs': 'application/javascript',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
    '.otf': 'font/otf',
    '.eot': 'application/vnd.ms-fontobject',
    '.mp4': 'video/mp4',
    '.webm': 'video/webm',
    '.mp3': 'audio/mpeg',
    '.wav': 'audio/wav',
    '.txt': 'text/plain',
    '.xml': 'application/xml',
  };

  ContentType _contentTypeFor(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    final mimeType = _extensionToMimeType[ext];
    if (mimeType == null) {
      return ContentType('application', 'octet-stream');
    }

    final slash = mimeType.indexOf('/');
    final primary = mimeType.substring(0, slash);
    final sub = mimeType.substring(slash + 1);
    final isText = primary == 'text' || mimeType == 'application/json' || mimeType == 'application/xml';
    return ContentType(primary, sub, charset: isText ? 'utf-8' : null);
  }
}
