/// What may be written to a log about an address.
///
/// Never a query (the handoff ticket is one), a fragment, credentials, a port,
/// or the access token of the local snapshot server. The saved copy is shown
/// as `copy:/path` (its first path segment is the token and is dropped), a live
/// page as `https://host/path`. Anything that looks like a token or an id (a
/// long run of hex digits) is masked wherever it appears. Used by the debug
/// traces only; it changes no behaviour.
String describeUrlForLog(String? raw) {
  if (raw == null) return '<none>';
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme) return '<unparseable>';
  String text;
  if (uri.host == '127.0.0.1' || uri.host == 'localhost' || uri.host == '::1') {
    final rest = uri.pathSegments.length > 1 ? uri.pathSegments.skip(1).join('/') : '';
    text = 'copy:/$rest';
  } else {
    text = '${uri.scheme}://${uri.host}${uri.path.isEmpty ? '/' : uri.path}';
  }
  text = text.replaceAll(RegExp(r'[A-Fa-f0-9]{24,}'), '<hex>');
  return text.length > 120 ? '${text.substring(0, 117)}...' : text;
}
