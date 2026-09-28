/// Hybrid dashboard milestone. Parses one entry of the `modules` array
/// from `/mobile/config` (or CapabilitiesDashboardAdapter's equivalent
/// fallback shape — both produce identical JSON) into a typed value the
/// dashboard can safely switch on.
///
/// Review round point 23: an unrecognized `type` or a `native` module
/// with an unrecognized `screen` must NEVER crash — [ModuleType.unknown]
/// is the safe-fallback case DashboardScreen renders as "Ten moduł
/// wymaga nowszej wersji aplikacji" instead of a runtime error.
enum ModuleType { native, webview, unknown }

class ModuleDescriptor {
  const ModuleDescriptor({
    required this.id,
    required this.title,
    required this.type,
    required this.icon,
    required this.order,
    required this.enabled,
    required this.requiresOnline,
    required this.requiredRoles,
    this.screen,
    this.path,
  });

  final String id;
  final String title;
  final ModuleType type;
  final String icon;
  final int order;
  final bool enabled;
  final bool requiresOnline;

  /// null = every signed-in role may see this tile. Non-null = only
  /// these role_ids (review round point 22: a DISPLAY filter only — the
  /// actual data/handoff endpoints enforce this independently server-side).
  final List<int>? requiredRoles;

  /// Set when [type] is [ModuleType.native] — which native screen to push.
  final String? screen;

  /// Set when [type] is [ModuleType.webview] — a path relative to
  /// `server_url`, NEVER a full external URL (review round point 1: "nie
  /// chcę pełnych zewnętrznych URL-i przesyłanych dowolnie przez
  /// konfigurację" — this is why the wire format is `path`, not `url`).
  final String? path;

  factory ModuleDescriptor.fromJson(Map<String, dynamic> json) {
    final rawType = json['type'] as String?;
    final type = switch (rawType) {
      'native' => ModuleType.native,
      'webview' => ModuleType.webview,
      _ => ModuleType.unknown,
    };

    final rawRoles = json['required_role'];
    final requiredRoles = (rawRoles is List) ? rawRoles.map((e) => e as int).toList() : null;

    return ModuleDescriptor(
      id: json['id'] as String? ?? 'unknown',
      title: json['title'] as String? ?? '?',
      type: type,
      icon: json['icon'] as String? ?? 'apps',
      order: json['order'] as int? ?? 999,
      enabled: json['enabled'] as bool? ?? true,
      requiresOnline: json['requires_online'] as bool? ?? true,
      requiredRoles: requiredRoles,
      screen: json['screen'] as String?,
      path: json['path'] as String?,
    );
  }

  /// Review round point 22: a display-only filter — [userRoleId] came
  /// from the already-authenticated `/session/login` response, not
  /// something the user can edit. The real enforcement point is
  /// server-side (webview_handoff.php's allowlist, bootstrap.php's own
  /// per-user filtering) — this only decides whether to draw a tile.
  bool visibleFor(int? userRoleId) {
    if (!enabled) return false;
    if (requiredRoles == null) return true;
    if (userRoleId == null) return false;
    return requiredRoles!.contains(userRoleId);
  }

  static List<ModuleDescriptor> parseList(List<dynamic> raw) {
    final list = raw.map((e) => ModuleDescriptor.fromJson(e as Map<String, dynamic>)).toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }
}
