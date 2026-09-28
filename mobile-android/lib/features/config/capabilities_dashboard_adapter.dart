/// Review round, point 9: the Legacy snapshot adapter's `/mobile/config`
/// (Iteration 2) returns `{schema_version, adapter_version, capabilities,
/// updated_at}` — a flat map of module-name -> bool. DashboardRenderer
/// (Iteration 1) expects a richer `{dashboard: {columns, items: [...]}, 
/// modules: [...]}` shape. Rather than forking DashboardRenderer or
/// inventing a second, parallel config contract, this is the ONE small,
/// pure, independently-testable client-side transform between them — the
/// wire contract stays exactly `capabilities` (simple, matches what a
/// plain-PHP legacy adapter can actually produce); this class is what
/// turns that into something DashboardRenderer can render.
///
/// Deliberately excludes any module whose capability is `false` — the app
/// never shows a tile for something this parish's adapter doesn't
/// actually support yet (Iteration 2 point 9's own principle, applied
/// here too).
class CapabilitiesDashboardAdapter {
  const CapabilitiesDashboardAdapter._();

  /// Order controls the tile order simple: first supported capability in
  /// this list order wins position 1. Kept as a fixed list, not derived
  /// from the (unordered) capabilities map, so tile order doesn't
  /// silently depend on PHP's json_encode key ordering.
  static const _knownModules = [
    _ModuleDef(key: 'schedule', title: 'Mój grafik', icon: 'calendar', component: 'event_list'),
    _ModuleDef(key: 'attendance', title: 'Obecności', icon: 'calendar', component: 'list'),
    _ModuleDef(key: 'points', title: 'Punkty', icon: 'star', component: 'stat_card'),
    _ModuleDef(key: 'ranking', title: 'Ranking', icon: 'star', component: 'list'),
    _ModuleDef(key: 'substitutions', title: 'Zastępstwa', icon: 'swap', component: 'list'),
    _ModuleDef(key: 'announcements', title: 'Ogłoszenia', icon: 'megaphone', component: 'list'),
  ];

  static Map<String, dynamic> toDashboardConfig(Map<String, dynamic> mobileApiConfig) {
    final capabilities = (mobileApiConfig['capabilities'] as Map<String, dynamic>?) ?? {};

    final supported = _knownModules.where((m) => capabilities[m.key] == true).toList();

    final items = <Map<String, dynamic>>[];
    final modules = <Map<String, dynamic>>[];

    for (var i = 0; i < supported.length; i++) {
      final m = supported[i];
      items.add({
        'module_id': m.key,
        'title': m.title,
        'icon': m.icon,
        'order': i + 1,
        'enabled': true,
      });
      modules.add({
        'id': m.key,
        'component': m.component,
        'min_app_version': null,
      });
    }

    return {
      'dashboard': {'columns': 2, 'items': items},
      'modules': modules,
    };
  }
}

class _ModuleDef {
  const _ModuleDef({required this.key, required this.title, required this.icon, required this.component});
  final String key;
  final String title;
  final String icon;
  final String component;
}
