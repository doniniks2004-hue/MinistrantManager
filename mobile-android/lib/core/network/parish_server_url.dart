/// Repair the known duplicate HTTPS prefix, then validate before persisting
/// or sending credentials. A suffix match must include the dot boundary.
String normalizeParishServerUrl(String value) {
  var text = value.trim();
  while (text.toLowerCase().startsWith('https://https://')) {
    text = text.substring(8);
  }
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      !uri.host.endsWith('.ministrant.eu') ||
      uri.host == 'app.ministrant.eu' ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException('Nieprawidłowy adres serwera parafii.');
  }
  return 'https://${uri.host}';
}
