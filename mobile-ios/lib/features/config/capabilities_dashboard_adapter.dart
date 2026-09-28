/// Review round, point 9 (original) / hybrid dashboard milestone
/// (rewritten): backward-compatibility bridge for a parish backend that
/// only speaks the OLD `capabilities: {module: bool}` contract and has
/// no `modules` array yet. Produces module descriptors in EXACTLY the
/// same shape a real `modules` array from the server would use — so
/// DashboardScreen has only ONE shape to ever consume, never two.
///
/// Deliberately excludes any module whose capability is `false` — the
/// app never shows a tile for something this parish's adapter doesn't
/// actually support yet.
class CapabilitiesDashboardAdapter {
  const CapabilitiesDashboardAdapter._();

  /// Order controls tile order: first supported capability in this list
  /// order wins position 1. Kept as a fixed list, not derived from the
  /// (unordered) capabilities map, so tile order doesn't silently depend
  /// on PHP's json_encode key ordering.
  static const _knownModules = [
    _ModuleDef(key: 'schedule', title: 'Mój grafik', screen: 'my_schedule', icon: 'calendar'),
    _ModuleDef(key: 'attendance', title: 'Obecności', screen: 'attendance', icon: 'check'),
    _ModuleDef(key: 'points', title: 'Historia punktów', screen: 'points_history', icon: 'star'),
    _ModuleDef(key: 'ranking', title: 'Ranking', screen: 'ranking', icon: 'trophy'),
    _ModuleDef(key: 'substitutions', title: 'Zastępstwa', screen: 'substitutions', icon: 'swap'),
    _ModuleDef(key: 'announcements', title: 'Ogłoszenia', screen: 'announcements', icon: 'megaphone'),
  ];

  /// Returns a `modules` list — the SAME shape build_modules() on the
  /// backend produces (see modules_builder.php), so DashboardScreen
  /// never needs to know which source it came from.
  static List<Map<String, dynamic>> toModuleList(Map<String, dynamic> mobileApiConfig) {
    final capabilities = (mobileApiConfig['capabilities'] as Map<String, dynamic>?) ?? {};
    final supported = _knownModules.where((m) => capabilities[m.key] == true).toList();

    return [
      for (var i = 0; i < supported.length; i++)
        {
          'id': supported[i].key,
          'title': supported[i].title,
          'type': 'native',
          'screen': supported[i].screen,
          'icon': supported[i].icon,
          'order': (i + 1) * 10,
          'enabled': true,
          'requires_online': false,
          'required_role': null,
        },
      {
        'id': 'profile', 'title': 'Moje konto', 'type': 'native', 'screen': 'profile',
        'icon': 'user', 'order': 900, 'enabled': true, 'requires_online': false, 'required_role': null,
      },
    ];
  }
}

class _ModuleDef {
  const _ModuleDef({required this.key, required this.title, required this.screen, required this.icon});
  final String key;
  final String title;
  final String screen;
  final String icon;
}
