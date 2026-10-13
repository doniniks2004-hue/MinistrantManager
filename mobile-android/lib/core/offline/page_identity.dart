/// A snapshot identifies a page including its query, never a handoff ticket.
String? snapshotPagePath(Uri uri) {
  final path = uri.path;
  if (!path.startsWith('/') ||
      path.contains('\\') ||
      uri.pathSegments.any((s) => s == '..' || s == '.'))
    return null;
  final leaf = uri.pathSegments.isEmpty
      ? ''
      : uri.pathSegments.last.toLowerCase();
  if (const {
    'mobile_handoff.php',
    'login.php',
    'logout.php',
    'session_login.php',
  }.contains(leaf))
    return null;
  if (uri.queryParameters.keys.any(
    (k) => const {
      'ticket',
      'token',
      'password',
      'code',
      'secret',
    }.contains(k.toLowerCase()),
  ))
    return null;
  return Uri(path: path, query: uri.hasQuery ? uri.query : null).toString();
}

bool isLogoutPath(Uri uri) => const {
  'logout.php',
  'logout',
}.contains(uri.pathSegments.lastOrNull?.toLowerCase());
