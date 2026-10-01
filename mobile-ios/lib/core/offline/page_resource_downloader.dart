import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Offline-architecture milestone, P4. Takes an already-rendered legacy
/// PHP page (HTML string + the URL it came from) and produces a
/// SELF-CONTAINED capture: the HTML with every discoverable same-origin
/// resource reference rewritten to `/assets/<key>`, plus the actual
/// bytes of every one of those resources — ready to hand straight to
/// [SnapshotStore.writeSnapshot] (`assets` map keys here are exactly
/// what that method expects).
///
/// Deliberately standalone from WebView/PHP-session concerns (review
/// round: "Nie będę tego łączył z WebView na skróty... downloader ma
/// samodzielnie poprawnie zbudować kompletny snapshot, przejść testy, a
/// dopiero potem podłączymy go do WebView") — [capture] takes plain
/// HTML + a URL, nothing WebView-specific, so it can be fully tested
/// against a real local HTTP server first.
///
/// Review round §6: covers `<link rel="stylesheet">`, inline `<style>`
/// blocks and `style="..."` attributes, `@import`/`url()` inside CSS
/// (recursively, for fonts/images referenced from a stylesheet),
/// `<script src>`, `<img src>` + `srcset`, and `<link rel="icon">` /
/// `rel="shortcut icon"`. Cross-origin resources (a different host than
/// [pageUrl]) are deliberately left untouched and un-rewritten — review
/// round §6 scopes JS capture to "Same-originowe" explicitly, and the
/// same reasoning applies to every other resource type: a third-party
/// CDN is never guaranteed reachable later, so depending on it for an
/// offline-capable snapshot would be self-defeating.
class PageResourceDownloader {
  PageResourceDownloader({HttpClient? httpClient}) : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;

  static final RegExp _cssUrlPattern = RegExp(r'url\(\s*([^)]+?)\s*\)', caseSensitive: false);
  static final RegExp _cssImportPattern =
      RegExp(r'@import\s+(?:url\()?["\x27]?([^"\x27)]+)["\x27]?\)?', caseSensitive: false);

  /// Every resource fetched so far in the current [capture] call —
  /// key -> bytes, the exact shape [SnapshotStore.writeSnapshot] wants.
  /// A fresh map per [capture] call, never reused across captures of
  /// different pages.
  late Map<String, List<int>> _assets;
  late Set<String> _cssAlreadyProcessed;
  late String _currentHost;

  Future<CapturedPage> capture({required Uri pageUrl, required String renderedHtml}) async {
    _assets = <String, List<int>>{};
    _cssAlreadyProcessed = <String>{};
    _currentHost = pageUrl.host;

    final document = html_parser.parse(renderedHtml);

    // <link rel="stylesheet">: downloaded, recursively scanned for its
    // OWN @import/url() references, and rewritten.
    for (final link in document.querySelectorAll('link[rel="stylesheet"]')) {
      final href = link.attributes['href'];
      if (href == null || href.isEmpty) continue;
      final resolved = _resolve(pageUrl, href);
      if (resolved == null) continue;
      final key = await _fetchAndStore(resolved);
      if (key == null) continue;
      await _processCssAsset(key, resolved);
      link.attributes['href'] = '/assets/$key';
    }

    // favicon
    for (final link in [
      ...document.querySelectorAll('link[rel="icon"]'),
      ...document.querySelectorAll('link[rel="shortcut icon"]'),
    ]) {
      final href = link.attributes['href'];
      if (href == null || href.isEmpty) continue;
      final resolved = _resolve(pageUrl, href);
      if (resolved == null) continue;
      final key = await _fetchAndStore(resolved);
      if (key != null) link.attributes['href'] = '/assets/$key';
    }

    // <script src="...">
    for (final script in document.querySelectorAll('script[src]')) {
      final src = script.attributes['src'];
      if (src == null || src.isEmpty) continue;
      final resolved = _resolve(pageUrl, src);
      if (resolved == null) continue;
      final key = await _fetchAndStore(resolved);
      if (key != null) script.attributes['src'] = '/assets/$key';
    }

    // <img src="..."> and srcset="..."
    for (final img in document.querySelectorAll('img')) {
      final src = img.attributes['src'];
      if (src != null && src.isNotEmpty) {
        final resolved = _resolve(pageUrl, src);
        if (resolved != null) {
          final key = await _fetchAndStore(resolved);
          if (key != null) img.attributes['src'] = '/assets/$key';
        }
      }

      final srcset = img.attributes['srcset'];
      if (srcset != null && srcset.isNotEmpty) {
        img.attributes['srcset'] = await _rewriteSrcset(srcset, pageUrl);
      }
    }

    // Inline style="...url(...)..." on any element.
    for (final element in document.querySelectorAll('[style]')) {
      final style = element.attributes['style'];
      if (style == null || !style.contains('url(')) continue;
      element.attributes['style'] = await _rewriteCssUrls(style, pageUrl);
    }

    // Inline <style>...</style> blocks.
    for (final styleTag in document.querySelectorAll('style')) {
      final cssText = styleTag.text;
      if (cssText.isEmpty) continue;
      final rewritten = await _rewriteCssUrls(cssText, pageUrl);
      styleTag.nodes.clear();
      styleTag.append(dom.Text(rewritten));
    }

    return CapturedPage(html: document.outerHtml, assets: _assets);
  }

  /// Fetches a same-origin resource if not already fetched this
  /// [capture] call, stores its bytes in [_assets], and returns its
  /// key — or null for cross-origin (left alone, see this class's own
  /// docblock) or genuinely unreachable (left alone so the page still
  /// renders, just without that one resource, same as a browser
  /// showing a broken image rather than failing the whole page).
  Future<String?> _fetchAndStore(Uri resourceUrl) async {
    if (resourceUrl.host != _currentHost) {
      return null;
    }
    final key = _keyFor(resourceUrl);
    if (_assets.containsKey(key)) {
      return key;
    }
    final bytes = await _fetch(resourceUrl);
    if (bytes == null) return null;
    _assets[key] = bytes;
    return key;
  }

  /// Downloads the stylesheet already stored under [key] (fetched by
  /// the caller via [_fetchAndStore]), rewrites its OWN url()/@import
  /// references, and writes the rewritten bytes back into [_assets]
  /// under the SAME key — recursing into any @import'd stylesheet
  /// first, so nested references are resolved bottom-up.
  Future<void> _processCssAsset(String key, Uri cssUrl) async {
    if (_cssAlreadyProcessed.contains(key)) return;
    _cssAlreadyProcessed.add(key);

    final bytes = _assets[key];
    if (bytes == null) return;
    final cssText = utf8.decode(bytes, allowMalformed: true);
    if (!cssText.contains('url(') && !cssText.contains('@import')) return;

    final rewritten = await _rewriteCssUrls(cssText, cssUrl, recurseIntoImports: true);
    _assets[key] = utf8.encode(rewritten);
  }

  /// Rewrites every `url(...)` AND `@import "..."` / `@import url(...)`
  /// reference in a chunk of CSS text (or a `style="..."` attribute
  /// value, which only ever uses `url()`, never `@import`) — [baseUrl]
  /// is whatever document this CSS text came FROM (the page itself for
  /// an inline `<style>` block or `style=""` attribute; the stylesheet's
  /// own URL for an external `.css` file, since THAT is what its
  /// relative references resolve against, not the page's URL).
  /// [recurseIntoImports] is only true when called from
  /// [_processCssAsset] on an actual stylesheet — a `style=""` attribute
  /// or inline `<style>` block can't legally contain `@import` at all,
  /// so there's nothing to recurse into there.
  Future<String> _rewriteCssUrls(String cssText, Uri baseUrl, {bool recurseIntoImports = false}) async {
    var result = cssText;

    // Review round fix (real bug, caught by CI): the ORIGINAL site's own
    // paths very commonly start with "/assets/" too (it's about the
    // most common static-resource folder name there is) — a plain
    // `rawUrl.startsWith('/assets/')` guard to skip "already rewritten
    // by the @import pass above" also incorrectly skipped perfectly
    // legitimate, never-before-touched references that simply happened
    // to share that prefix (exactly what the fixture's inline <style>
    // block does: `url('/assets/img/inline-bg.png')`). Tracks the EXACT
    // replacement strings this method itself just inserted instead of
    // guessing from a prefix — only a url() whose raw target is
    // byte-for-byte one of THESE is skipped, never anything merely
    // similar-looking.
    final alreadyRewrittenByImportPass = <String>{};

    final importMatches = _cssImportPattern.allMatches(cssText).toList();
    for (final match in importMatches.reversed) {
      final rawUrl = _stripQuotes(match.group(1)!.trim());
      final resolved = _resolve(baseUrl, rawUrl);
      if (resolved == null) continue;
      final key = await _fetchAndStore(resolved);
      if (key == null) continue;
      if (recurseIntoImports) {
        await _processCssAsset(key, resolved);
      }
      alreadyRewrittenByImportPass.add('/assets/$key');
      result = result.replaceRange(match.start, match.end, '@import url(/assets/$key)');
    }

    final urlMatches = _cssUrlPattern.allMatches(result).toList();
    for (final match in urlMatches.reversed) {
      var rawUrl = match.group(1)!.trim();
      rawUrl = _stripQuotes(rawUrl);
      if (rawUrl.startsWith('data:')) continue; // already self-contained, nothing to fetch
      if (alreadyRewrittenByImportPass.contains(rawUrl)) continue;
      final resolved = _resolve(baseUrl, rawUrl);
      if (resolved == null) continue;
      final key = await _fetchAndStore(resolved);
      if (key == null) continue;
      result = result.replaceRange(match.start, match.end, 'url(/assets/$key)');
    }

    return result;
  }

  Future<String> _rewriteSrcset(String srcset, Uri pageUrl) async {
    final parts = srcset.split(',');
    final rewrittenParts = <String>[];
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final spaceIndex = trimmed.indexOf(RegExp(r'\s'));
      final urlPart = spaceIndex == -1 ? trimmed : trimmed.substring(0, spaceIndex);
      final descriptor = spaceIndex == -1 ? '' : trimmed.substring(spaceIndex);
      final resolved = _resolve(pageUrl, urlPart);
      if (resolved == null) {
        rewrittenParts.add(trimmed);
        continue;
      }
      final key = await _fetchAndStore(resolved);
      rewrittenParts.add(key == null ? trimmed : '/assets/$key$descriptor');
    }
    return rewrittenParts.join(', ');
  }

  Uri? _resolve(Uri base, String reference) {
    if (reference.startsWith('data:') || reference.startsWith('javascript:') || reference.startsWith('#')) {
      return null;
    }
    try {
      return base.resolve(reference);
    } catch (_) {
      return null;
    }
  }

  String _stripQuotes(String value) {
    if (value.length >= 2 &&
        (value.startsWith('"') && value.endsWith('"') || value.startsWith("'") && value.endsWith("'"))) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  /// The SnapshotStore asset key for a resource URL — its site-relative
  /// path, query string stripped (so `style.css?v=1` and `style.css?v=2`
  /// correctly map to the ONE stored copy rather than two). Rewritten
  /// HTML/CSS references always become `/assets/<this key>`, which is
  /// exactly where SnapshotStore's own `assets/` folder convention puts
  /// the file — the two sides of this contract are deliberately defined
  /// together, in this one method, rather than duplicated.
  String _keyFor(Uri resourceUrl) {
    final path = resourceUrl.path.startsWith('/') ? resourceUrl.path.substring(1) : resourceUrl.path;
    return path.isEmpty ? 'index' : path;
  }

  Future<List<int>?> _fetch(Uri url) async {
    try {
      final request = await _httpClient.getUrl(url);
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      return bytes;
    } catch (_) {
      // Unreachable resource (404, timeout, DNS, ...) — the caller
      // leaves the original reference in place rather than rewriting to
      // a local path that would never resolve to anything; the page
      // still renders, just without that one resource, same as a
      // browser would show a broken image rather than fail the whole
      // page load.
      return null;
    }
  }
}

/// The result of [PageResourceDownloader.capture] — html is ready to
/// write as `snapshot.html`, assets is ready to pass straight to
/// [SnapshotStore.writeSnapshot]'s own `assets` parameter.
class CapturedPage {
  const CapturedPage({required this.html, required this.assets});

  final String html;
  final Map<String, List<int>> assets;
}
