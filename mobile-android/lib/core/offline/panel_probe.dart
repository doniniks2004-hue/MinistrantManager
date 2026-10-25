import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

/// One computed-style check: the element matching [selector] must have its CSS
/// [property] differ from [not] (a default value, such as an unset background
/// that means "the stylesheet did not apply"), or equal [equals]. A stylesheet
/// COUNT cannot tell a stylesheet that applied from one that is empty or from
/// another site's; this can.
class StyleCheck {
  const StyleCheck({required this.selector, required this.property, this.not, this.equals});

  final String selector;
  final String property;
  final String? not;
  final String? equals;

  Map<String, Object?> toJson() => {
        'selector': selector,
        'property': property,
        if (not != null) 'not': not,
        if (equals != null) 'equals': equals,
      };
}

/// What "the real panel" is, stated by the owner (never guessed by the app or by
/// the acceptance script): the logical path of the page, elements that must be
/// there AND visible, elements that must not be (a sign-in form, an error
/// banner), styles that must really be applied, and optionally a fragment of the
/// page title.
///
/// It comes in through `--dart-define=MM_PANEL_SPEC=<base64 of JSON>`. [id] is the
/// first 12 hex characters of the SHA-256 of that base64 text, so the acceptance
/// script can require that the build it is looking at was made with THE spec it
/// was given. A build without a spec reports verdict `none`, which the
/// acceptance script does not accept.
class PanelSpec {
  const PanelSpec._({
    required this.id,
    required this.required,
    required this.forbidden,
    required this.styles,
    this.path,
    this.titleContains,
  });

  static const maxEncodedLength = 4096;
  static const maxItems = 20;
  static const maxSelectorLength = 200;

  final String id;
  final String? path;
  final List<String> required;
  final List<String> forbidden;
  final List<StyleCheck> styles;
  final String? titleContains;

  static const _fromDefine = String.fromEnvironment('MM_PANEL_SPEC');

  static PanelSpec? fromEnvironment() => _fromDefine.isEmpty ? null : fromBase64(_fromDefine);

  /// The id of an encoded spec, or null if it is not a plausible one. Matches
  /// what the acceptance script computes from the same text.
  static String idOf(String encoded) => sha256.convert(utf8.encode(encoded.trim())).toString().substring(0, 12);

  /// A spec, or null if the text is not one: not base64, not JSON, over the size
  /// limits, anything that is not a short string where one is expected, or a spec
  /// that does not name at least one required element (it would identify nothing,
  /// and every page would "match").
  static PanelSpec? fromBase64(String encoded) {
    final text = encoded.trim();
    if (text.isEmpty || text.length > maxEncodedLength) return null;
    try {
      final decoded = jsonDecode(utf8.decode(base64.decode(base64.normalize(text))));
      if (decoded is! Map) return null;
      final requiredItems = _strings(decoded['required']);
      final forbiddenItems = _strings(decoded['forbidden']);
      final styleItems = _styles(decoded['styles']);
      if (requiredItems == null || forbiddenItems == null || styleItems == null) return null;
      if (requiredItems.isEmpty) return null;
      final path = decoded['path'];
      if (path != null && (path is! String || !path.startsWith('/') || path.length > maxSelectorLength)) return null;
      final title = decoded['titleContains'];
      if (title != null && (title is! String || title.isEmpty || title.length > maxSelectorLength)) return null;
      return PanelSpec._(
        id: idOf(text),
        required: requiredItems,
        forbidden: forbiddenItems,
        styles: styleItems,
        path: path as String?,
        titleContains: title as String?,
      );
    } catch (_) {
      return null;
    }
  }

  static bool _short(Object? v) =>
      v is String && v.isNotEmpty && v.length <= maxSelectorLength && !RegExp(r'[\x00-\x1f]').hasMatch(v);

  /// null = malformed; an absent key is an empty list.
  static List<String>? _strings(Object? v) {
    if (v == null) return const [];
    if (v is! List || v.length > maxItems) return null;
    if (!v.every(_short)) return null;
    return List<String>.from(v);
  }

  static List<StyleCheck>? _styles(Object? v) {
    if (v == null) return const [];
    if (v is! List || v.length > maxItems) return null;
    final out = <StyleCheck>[];
    for (final item in v) {
      if (item is! Map) return null;
      final selector = item['selector'];
      final property = item['property'];
      final not = item['not'];
      final equals = item['equals'];
      if (!_short(selector) || !_short(property)) return null;
      if (!RegExp(r'^[a-zA-Z-]{1,60}$').hasMatch(property as String)) return null;
      if ((not == null) == (equals == null)) return null; // exactly one of the two
      if ((not != null && !_short(not)) || (equals != null && !_short(equals))) return null;
      out.add(StyleCheck(selector: selector as String, property: property, not: not as String?, equals: equals as String?));
    }
    return out;
  }

  Map<String, Object?> toJson() => {
        'required': required,
        'forbidden': forbidden,
        'styles': [for (final s in styles) s.toJson()],
        if (titleContains != null) 'titleContains': titleContains,
      };
}

/// The script the screen runs in the page once it has finished loading.
///
/// It reports ONCE, to [channel], with what it measured:
///  * `via`: 'raf' if it was called back after two animation frames (the engine
///    really drew), 'timer' if only the 1.5 s fallback fired (a hidden or
///    background page gets no frames). The fallback exists so the screen never
///    waits for ever; it is NEVER evidence that a panel was drawn.
///  * `shown`/`hidden`: the document's visibility.
///  * `ready`, `img`, `sheets`, `w`, `h`: as before.
///  * `spec`, `verdict` ('ok' | 'fail' | 'none') and `failed` (short codes, no
///    page text): the result of the checks of [spec], if there is one.
String buildPanelProbe({required int nav, required String channel, PanelSpec? spec}) {
  final specJson = spec == null ? 'null' : jsonEncode(spec.toJson());
  return panelProbeTemplate
      .replaceAll('__NAV__', '$nav')
      .replaceAll('__CHANNEL__', channel)
      .replaceAll('__SPEC_ID__', spec?.id ?? '-')
      .replaceAll('__SPEC__', specJson);
}

const panelProbeTemplate = r'''
(function () {
  var done = false;
  var spec = __SPEC__;
  function q(sel) { try { return document.querySelector(sel); } catch (e) { return null; } }
  function shown(el) {
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
      var cs = getComputedStyle(n);
      if (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) === 0) return false;
    }
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }
  function judge() {
    if (!spec) return { verdict: 'none', failed: '-' };
    var bad = [], i, req = spec.required || [], forb = spec.forbidden || [], sty = spec.styles || [];
    for (i = 0; i < req.length; i++) { var a = q(req[i]); if (!a || !shown(a)) bad.push('r' + i); }
    for (i = 0; i < forb.length; i++) { var f = q(forb[i]); if (f && shown(f)) bad.push('f' + i); }
    for (i = 0; i < sty.length; i++) {
      var s = sty[i], el = q(s.selector), v = el ? getComputedStyle(el).getPropertyValue(s.property) : null;
      if (v === null || (s.not !== undefined && v === s.not) || (s.equals !== undefined && v !== s.equals)) bad.push('s' + i);
    }
    if (spec.titleContains && document.title.indexOf(spec.titleContains) < 0) bad.push('t');
    return { verdict: bad.length ? 'fail' : 'ok', failed: bad.length ? bad.join(',') : '-' };
  }
  function report(via) {
    if (done) return;
    done = true;
    try {
      var p = null;
      try { p = performance.getEntriesByName('first-contentful-paint')[0]; } catch (e) {}
      var images = document.images, loaded = 0;
      for (var i = 0; i < images.length; i++) {
        if (images[i].complete && images[i].naturalWidth > 0) loaded++;
      }
      var main = document.querySelector('main') || document.body;
      var box = main ? main.getBoundingClientRect() : { width: 0, height: 0 };
      var j = judge();
      __CHANNEL__.postMessage(JSON.stringify({
        nav: __NAV__, via: via, fcp: p ? Math.round(p.startTime) : -1, at: Math.round(performance.now()),
        ready: document.readyState, shown: document.visibilityState, hidden: document.hidden ? 1 : 0,
        img: loaded + '/' + images.length,
        sheets: document.styleSheets.length,
        w: Math.round(box.width), h: Math.round(box.height),
        spec: '__SPEC_ID__', verdict: j.verdict, failed: j.failed
      }));
    } catch (e) {}
  }
  requestAnimationFrame(function () { requestAnimationFrame(function () { report('raf'); }); });
  setTimeout(function () { report('timer'); }, 1500);
})();
''';
